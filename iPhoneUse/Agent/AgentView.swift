//
//  AgentView.swift
//  iPhoneUse
//
//  ChatGPT-style layout, after github.com/PallavAg/Apple-Intelligence-Chat:
//  bubbles for the user, plain text for the agent, a floating glass composer,
//  and past runs in a chat list that slides in from the left.
//

import SwiftUI

struct AgentView: View {
    @ObservedObject private var agent = PhoneAgent.shared
    @ObservedObject private var connection = Connection.shared
    @ObservedObject private var llm = LLMSettings.shared
    @ObservedObject private var voice = VoiceRecorder.shared
    @State private var prompt = ""
    @FocusState private var composerFocused: Bool
    @State private var openRun: RunRecord.ID? // nil = the live chat
    @State private var menuOpen = false
    @State private var drag: CGFloat = 0 // swipe-to-close only; opening is the button's job
    @State private var showSettings = false
    @State private var showShortcutsGuide = false

    var body: some View {
        GeometryReader { geo in
            let menuWidth = min(geo.size.width * 0.8, 340)
            let offset = menuOpen ? max(menuWidth + drag, 0) : 0
            ZStack(alignment: .leading) {
                ChatList(agent: agent, width: menuWidth, openRun: openRun, select: select,
                         reuse: { prompt = $0; select(nil) }, needsSetup: needsSetup, openSettings: { showSettings = true },
                         openShortcutsGuide: { showShortcutsGuide = true })
                    .accessibilityHidden(!menuOpen)
                // The mask reaches the screen edges, so the rounded corners follow the
                // display's instead of clipping the toolbar buttons.
                chat
                    .background(Color(.systemBackground))
                    .mask { RoundedRectangle(cornerRadius: offset > 0 ? 44 : 0, style: .continuous).ignoresSafeArea() }
                    .shadow(color: .black.opacity(offset > 0 ? 0.15 : 0), radius: 12)
                    .overlay {
                        if menuOpen { Color.black.opacity(0.001).onTapGesture { setMenu(false) } }
                    }
                    .offset(x: offset)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { g in
                        if abs(g.translation.width) > abs(g.translation.height) { drag = min(g.translation.width, 0) }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy) { menuOpen = drag > -80; drag = 0 }
                    },
                including: menuOpen ? .all : .subviews
            )
            // Distinct from the chat's systemBackground so the panels separate in dark mode,
            // where the shadow is invisible.
            .background(Color(.secondarySystemBackground))
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showShortcutsGuide) {
            NavigationStack {
                ShortcutsGuideView().toolbar { Button("Done") { showShortcutsGuide = false } }
            }
        }
        // iphoneuse://run?prompt=... starts a new session, like the Run Agent intent.
        .onOpenURL { url in
            guard let linked = DeepLink.prompt(from: url), !agent.isRunning else { return }
            showSettings = false
            showShortcutsGuide = false
            openRun = nil
            setMenu(false)
            agent.run(prompt: linked)
        }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "demoChat") { return agent.runDemo() }
            #endif
            await connection.connect()
            // Test hooks: `devicectl device process launch ... -agentScript "..."` (no LLM, see
            // scripts/runscript.sh) or `-agentPrompt "..."` (real run).
            let launchArgs = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard !agent.isRunning, agent.log.isEmpty else { return }
            if let script = launchArgs["agentScript"] as? String {
                agent.runScript(script)
            } else if let auto = launchArgs["agentPrompt"] as? String, !auto.isEmpty {
                agent.run(prompt: auto)
            }
        }
    }

    private var entries: [ChatEntry] {
        guard let openRun else { return agent.entries }
        guard let run = agent.history.first(where: { $0.id == openRun }) else { return [] }
        return run.entries ?? [ChatEntry(kind: .user, text: run.prompt), ChatEntry(kind: .assistant, text: run.log)]
    }

    /// Consecutive steps collapse into one carousel row.
    private var rows: [[ChatEntry]] {
        entries.reduce(into: []) { rows, entry in
            if entry.kind == .step, rows.last?.first?.kind == .step { rows[rows.count - 1].append(entry) } else { rows.append([entry]) }
        }
    }

    private var chat: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.first!.id) { row in
                        if row[0].kind == .step { StepCarousel(steps: row) } else { ChatRow(entry: row[0]) }
                    }
                    if agent.isRunning && agent.question == nil && openRun == nil { PulsingDots() }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if entries.isEmpty { suggestions }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !isConnected {
                        ConnectionStatus(connection: connection, openSettings: { showSettings = true }).padding(.horizontal, 20)
                    }
                    if let error = voice.error {
                        Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20)
                    }
                    if agent.isRunning {
                        Button { agent.stop() } label: {
                            Label("Stop Session", systemImage: "stop.fill")
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.red)
                        .padding(.horizontal, 12)
                    }
                    composer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Chats", systemImage: "line.3.horizontal") { setMenu(true) }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") { select(nil) }
                        .disabled(openRun == nil && (agent.entries.isEmpty || agent.isRunning))
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").overlay(alignment: .topTrailing) { if needsSetup { BadgeDot() } }
                    }
                    .accessibilityLabel(needsSetup ? "Settings, setup needed" : "Settings")
                }
            }
        }
    }

    private static let suggestions = [
        ("message.fill", Color.green, "List my unread WhatsApp conversations (don't open them)"),
        ("car.fill", Color.primary, "Get me an Uber to the closest supermarket"),
        ("creditcard.fill", Color.blue, "Show me my Apple subscriptions, recommend which ones to cancel"),
    ]

    /// Starter prompts on a new chat, sitting just above the composer.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.suggestions, id: \.2) { icon, tint, text in
                Button {
                    prompt = text
                    send()
                } label: {
                    Label { Text(text).foregroundStyle(.secondary).multilineTextAlignment(.leading) } icon: {
                        Image(systemName: icon).foregroundStyle(tint)
                    }
                    .font(.body)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }

    /// Red dot on the gear: something in the Settings checklist stops the agent from running.
    private var needsSetup: Bool {
        if llm.problem != nil { return true }
        if case .failed = connection.step { return true }
        return false
    }

    private var isConnected: Bool {
        if case .ready = connection.step { true } else { false }
    }

    private func setMenu(_ open: Bool) {
        if open { composerFocused = false }
        withAnimation(.snappy) { menuOpen = open }
    }

    /// Shows a past run, or for nil the live chat (cleared when nothing is running).
    private func select(_ id: RunRecord.ID?) {
        if id == nil, openRun == nil, !agent.isRunning { agent.entries = [] }
        openRun = id == agent.liveRun?.id ? nil : id // the live run shows as the live chat
        setMenu(false)
    }

    /// While running, the composer only answers the agent's question.
    private var composerEnabled: Bool { !agent.isRunning || agent.question != nil }

    private var canSend: Bool {
        composerEnabled && (voice.state == .recording || voice.state == .idle && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if voice.state == .idle {
                TextField(agent.question == nil ? "Ask anything" : "Answer", text: $prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .frame(minHeight: 34)
                    .padding(.leading, 6)
            } else {
                Waveform(levels: voice.levels, transcribing: voice.state == .transcribing)
            }
            if composerEnabled {
                MicButton(voice: voice, enabled: llm.voiceAvailable) { finishVoice(send: false) }
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(canSend ? Color.primary : Color.secondary.opacity(0.4)))
            }
            .disabled(!canSend)
            .accessibilityLabel(agent.question == nil ? "Send" : "Send answer")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .padding(.leading, 8)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { composerFocused = true }
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .sensoryFeedback(.start, trigger: voice.state) { _, new in new == .recording }
        .sensoryFeedback(.stop, trigger: voice.state) { old, _ in old == .recording }
        .sensoryFeedback(.error, trigger: voice.error) { _, new in new != nil }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: agent.question) { _, question in
            if question != nil { openRun = nil; setMenu(false); composerFocused = true }
        }
    }

    // Every run starts fresh for the model, so sending always opens the live chat.
    // Mid-run, sending answers the agent's question instead.
    private func send() {
        if voice.state == .recording { return finishVoice(send: true) }
        guard canSend else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        openRun = nil
        if agent.isRunning { agent.answer(text) } else { agent.run(prompt: text) }
        prompt = ""
        composerFocused = false
    }

    private func finishVoice(send: Bool) {
        composerFocused = false
        Task {
            guard let text = await voice.finish(), !text.isEmpty else { return }
            prompt = prompt.isEmpty ? text : prompt + " " + text
            if send { self.send() }
        }
    }
}

/// Tap to start (it becomes a stop button), or hold and release.
private struct MicButton: View {
    @ObservedObject var voice: VoiceRecorder
    let enabled: Bool
    let stop: () -> Void
    @State private var pressStart: Date?
    @State private var startedByPress = false

    var body: some View {
        Image(systemName: voice.state == .recording ? "stop.fill" : "mic")
            .font(.system(size: voice.state == .recording ? 13 : 17, weight: .semibold))
            .foregroundStyle(enabled && voice.state != .transcribing ? Color.primary : .secondary)
            .frame(width: 34, height: 34)
            .background(Circle().fill(voice.state == .recording ? Color(.secondarySystemFill) : .clear))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, pressStart == nil else { return }
                    pressStart = .now
                    startedByPress = voice.state == .idle
                    if startedByPress { Task { await voice.start() } }
                }
                .onEnded { _ in
                    guard let start = pressStart else { return }
                    pressStart = nil
                    let held = Date.now.timeIntervalSince(start) > 0.4
                    if voice.state == .recording, !startedByPress || held { stop() }
                })
            .accessibilityLabel(voice.state == .recording ? "Stop recording" : "Record voice prompt")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if voice.state == .recording { stop() } else if enabled { Task { await voice.start() } }
            }
    }
}

/// Live input levels in place of the text field while recording, newest on the right.
private struct Waveform: View {
    let levels: [Float]
    let transcribing: Bool

    var body: some View {
        // Bars sit in an overlay so a full row can't widen the composer.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                        Capsule().frame(width: 3, height: 3 + CGFloat(level) * 24)
                    }
                }
                .foregroundStyle(transcribing ? .tertiary : .primary)
            }
            .clipped()
            .overlay { if transcribing { ProgressView() } }
            .animation(.linear(duration: 0.08), value: levels)
    }
}

/// The drawer behind the chat: past runs, newest first, plus new chat and settings.
private struct ChatList: View {
    @ObservedObject var agent: PhoneAgent
    let width: CGFloat
    let openRun: RunRecord.ID?
    let select: (RunRecord.ID?) -> Void
    let reuse: (String) -> Void
    let needsSetup: Bool
    let openSettings: () -> Void
    let openShortcutsGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History")
                .font(.largeTitle.bold())
                .padding(.horizontal, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(agent.history) { run in
                        Button { select(run.id) } label: {
                            Text(run.prompt)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    run.id == (openRun ?? agent.liveRun?.id) ? Color(.secondarySystemFill) : .clear,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Use Prompt", systemImage: "arrow.uturn.left") { reuse(run.prompt) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                if openRun == run.id { select(nil) }
                                agent.deleteRun(run.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .overlay {
                if agent.history.isEmpty { Text("No sessions yet").foregroundStyle(.secondary) }
            }
            Button(action: openShortcutsGuide) {
                HStack {
                    Label("Connect shortcuts, deeplink", systemImage: "link")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            HStack {
                Button { select(nil) } label: {
                    Label("Chat", systemImage: "square.and.pencil")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 50, height: 50)
                        .glass(in: Circle())
                        .overlay(alignment: .topTrailing) { if needsSetup { BadgeDot().padding(6) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(needsSetup ? "Settings, setup needed" : "Settings")
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
    }
}

private struct ChatRow: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .textSelection(.enabled)
        case .assistant:
            Text(entry.text).textSelection(.enabled)
        case .step:
            Text(entry.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// A run's steps side by side, newest on the right and kept in view.
private struct StepCarousel: View {
    let steps: [ChatEntry]
    @State private var viewing: ChatEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps").font(.headline)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // ponytail: non-lazy so cards keep their fade state; fine for maxSteps-sized runs.
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(steps) { step in StepCard(entry: step, open: { viewing = step.id }).id(step.id) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, -16) // bleed to the screen edges
                .onAppear { proxy.scrollTo(steps.last?.id, anchor: .trailing) }
                .onChange(of: steps.count) {
                    withAnimation(.easeOut(duration: 0.4)) { proxy.scrollTo(steps.last?.id, anchor: .trailing) }
                }
            }
        }
        .padding(.vertical, 12)
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            ShotViewer(shots: steps.filter { $0.shot == true }, selection: $viewing)
        }
    }
}

/// Full screen screenshots of a run, swiped left and right, dots on top for position.
private struct ShotViewer: View {
    let shots: [ChatEntry]
    @Binding var selection: ChatEntry.ID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView(selection: $selection) {
            ForEach(shots) { shot in
                Group {
                    if let image = UIImage(contentsOfFile: shot.shotURL.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .tag(Optional(shot.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(.black)
        .overlay(alignment: .top) {
            HStack {
                let index = shots.firstIndex { $0.id == selection } ?? 0
                if shots.count <= 20 {
                    HStack(spacing: 6) {
                        ForEach(shots.indices, id: \.self) { i in
                            Circle().fill(.white.opacity(i == index ? 1 : 0.35)).frame(width: 7, height: 7)
                        }
                    }
                } else {
                    Text("\(index + 1) / \(shots.count)").font(.footnote.monospacedDigit()).foregroundStyle(.white)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white).padding(10)
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal)
        }
        .statusBarHidden()
    }
}

private struct StepCard: View {
    let entry: ChatEntry
    let open: () -> Void
    @State private var image: UIImage?
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.shot == true {
                Group {
                    if let image { Image(uiImage: image).resizable() } else { Color(.secondarySystemFill) }
                }
                .aspectRatio(9 / 19.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
                .onTapGesture(perform: open)
            }
            Text(entry.text)
                .font(.caption.monospaced())
                .lineLimit(3)
            if let thought = entry.thought {
                Text(thought).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .frame(width: 150, alignment: .leading)
        .textSelection(.enabled)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .scaleEffect(shown ? 1 : 0.95)
        .onAppear { withAnimation(.easeOut(duration: 0.45)) { shown = true } }
        .task { if entry.shot == true { image = UIImage(contentsOfFile: entry.shotURL.path) } }
    }
}

private struct BadgeDot: View {
    var body: some View {
        Circle().fill(.red).frame(width: 9, height: 9).offset(x: 3, y: -3)
    }
}

/// Typing indicator shown while the agent works.
private struct PulsingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundStyle(.secondary)
                    .scaleEffect(on ? 1 : 0.5)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }
        .padding(.vertical, 6)
        .onAppear { on = true }
    }
}

private extension View {
    /// Liquid Glass on iOS 26+, frosted material before. Glass sits behind the
    /// content so it doesn't wash out solid controls (the black send button).
    @ViewBuilder func glass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

private struct ConnectionStatus: View {
    @ObservedObject var connection: Connection
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch connection.step {
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Not connected").foregroundStyle(.secondary)
            case .working(let message):
                ProgressView().controlSize(.mini)
                Text(message).foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "circle.fill").foregroundStyle(.green)
                Text("Connected to this iPhone")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
            }
            Spacer()
            if showsConnect {
                // Without a pairing file, connecting fails instantly with the same message: send to Settings instead.
                if connection.hasPairingFile {
                    Button("Connect") { Task { await connection.connect(force: true) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Set Up", action: openSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .font(.footnote)
    }

    private var showsConnect: Bool {
        switch connection.step {
        case .idle, .failed: true
        case .working, .ready: false
        }
    }
}
