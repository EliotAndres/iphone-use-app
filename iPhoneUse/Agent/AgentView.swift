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
    @State private var drag: CGFloat = 0
    @State private var showSettings = false
    @State private var showShortcutsGuide = false

    var body: some View {
        GeometryReader { geo in
            let menuWidth = min(geo.size.width * 0.8, 340)
            let offset = min(max((menuOpen ? menuWidth : 0) + drag, 0), menuWidth)
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
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { g in
                                if abs(g.translation.width) > abs(g.translation.height) { drag = g.translation.width }
                            }
                            .onEnded { _ in
                                let open = drag > 80 || (menuOpen && drag > -80)
                                withAnimation(.snappy) { menuOpen = open; drag = 0 }
                                if open { composerFocused = false }
                            }
                    )
            }
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
        return run.entries ?? [ChatEntry(kind: .user, text: run.prompt), ChatEntry(kind: .step, text: run.log)]
    }

    private var chat: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { ChatRow(entry: $0) }
                    if agent.isRunning && openRun == nil { PulsingDots() }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if entries.isEmpty {
                    Text("What should I do?").font(.title2.weight(.semibold))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !isConnected {
                        ConnectionStatus(connection: connection, openSettings: { showSettings = true }).padding(.horizontal, 20)
                    }
                    if let error = voice.error {
                        Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20)
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
        openRun = id
        setMenu(false)
    }

    private var canSend: Bool {
        voice.state == .recording || voice.state == .idle && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if voice.state == .idle {
                TextField("Ask anything", text: $prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.vertical, 10)
                    .padding(.leading, 6)
            } else {
                Waveform(levels: voice.levels, transcribing: voice.state == .transcribing)
            }
            if !agent.isRunning {
                MicButton(voice: voice, enabled: llm.voiceAvailable) { finishVoice(send: false) }
            }
            Button(action: sendOrStop) {
                Image(systemName: agent.isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(agent.isRunning || canSend ? Color.primary : Color.secondary.opacity(0.4)))
            }
            .disabled(!agent.isRunning && !canSend)
            .accessibilityLabel(agent.isRunning ? "Stop" : "Send")
            .animation(.easeInOut(duration: 0.2), value: agent.isRunning)
        }
        .padding(6)
        .padding(.leading, 8)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { composerFocused = true }
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .sensoryFeedback(.start, trigger: voice.state) { _, new in new == .recording }
        .sensoryFeedback(.stop, trigger: voice.state) { old, _ in old == .recording }
        .sensoryFeedback(.error, trigger: voice.error) { _, new in new != nil }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // Every run starts fresh for the model, so sending always opens the live chat.
    private func sendOrStop() {
        if agent.isRunning { return agent.stop() }
        if voice.state == .recording { return finishVoice(send: true) }
        guard canSend else { return }
        openRun = nil
        agent.run(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        prompt = ""
        composerFocused = false
    }

    private func finishVoice(send: Bool) {
        composerFocused = false
        Task {
            guard let text = await voice.finish(), !text.isEmpty else { return }
            prompt = prompt.isEmpty ? text : prompt + " " + text
            if send { sendOrStop() }
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
            .frame(height: 40)
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
                                    run.id == openRun ? Color(.secondarySystemFill) : .clear,
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
