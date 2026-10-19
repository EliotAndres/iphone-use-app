//
//  AgentView.swift
//  StikDebug
//
//  Prompt in, then an LLM drives this phone: CoreDevice screenshot -> OpenRouter
//  tool call -> CoreDevice tap/type/launch, until it calls `done`.
//

import ActivityKit
import SwiftUI
import UIKit

struct AgentView: View {
    @StateObject private var agent = PhoneAgent.shared
    @AppStorage("agentModelID") private var model = "anthropic/claude-sonnet-5.5"
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("What should I do?", text: $prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Picker("Model", selection: $model) {
                    Text("Claude Sonnet 5.5").tag("anthropic/claude-sonnet-5.5")
                    Text("Gemini 3.5 Flash Lite").tag("google/gemini-3.5-flash-lite")
                }
                .pickerStyle(.segmented)
                if agent.isRunning {
                    Button("Stop", role: .destructive) { agent.stop() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Run") { agent.run(prompt: prompt, model: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(agent.log)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: agent.log) { proxy.scrollTo("end") }
                }
            }
            .padding()
            .navigationTitle("Agent")
        }
        .onAppear {
            // Test hook: `devicectl device process launch ... -agentPrompt "..."`
            let launchArgs = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            // `-agentScript "open com.apple.Preferences; wait 2; tap 0.26 0.2; shot a"`: no LLM, shots land in Documents.
            if let script = launchArgs["agentScript"] as? String, !agent.isRunning, agent.log.isEmpty {
                agent.runScript(script)
            } else if let auto = launchArgs["agentPrompt"] as? String,
               !auto.isEmpty, !agent.isRunning, agent.log.isEmpty {
                prompt = auto
                agent.run(prompt: auto, model: model)
            }
        }
    }
}

@MainActor
final class PhoneAgent: ObservableObject {
    static let shared = PhoneAgent()

    @Published var log = ""
    @Published var isRunning = false
    private var task: Task<Void, Never>?
    private var activity: Activity<AgentActivityAttributes>?
    private var activityState = AgentActivityAttributes.ContentState(step: 0, line: "Starting", running: true)

    private static let maxSteps = 40
    private static let imageWidth: CGFloat = 450
    private static let logURL = URL.documentsDirectory.appending(path: "agent.log")

    func run(prompt: String, model: String) {
        guard !isRunning else { return }
        isRunning = true
        log = ""
        BackgroundAudioManager.shared.requestStart() // keeps us alive while other apps are in front
        startActivity(prompt: prompt)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loop(prompt: prompt, model: model)
            await MainActor.run {
                BackgroundAudioManager.shared.requestStop()
                self?.isRunning = false
                self?.endActivity()
            }
        }
    }

    // Lock Screen / Dynamic Island mirror of the log. At most one: any leftover
    // activity (from a crash or an earlier run) is ended before a new one starts.
    private func startActivity(prompt: String) {
        for old in Activity<AgentActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        activityState = .init(step: 0, line: "Starting", running: true)
        activity = try? Activity.request(
            attributes: AgentActivityAttributes(prompt: prompt, startedAt: .now),
            content: ActivityContent(state: activityState, staleDate: nil)
        )
    }

    private func updateActivity(line: String, step: Int?) {
        guard let activity else { return }
        activityState.line = line
        if let step { activityState.step = step }
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endActivity() {
        guard let activity else { return }
        activityState.running = false
        let content = ActivityContent(state: activityState, staleDate: nil)
        self.activity = nil
        Task { await activity.end(content, dismissalPolicy: .after(.now + 600)) }
    }

    func runScript(_ script: String) {
        isRunning = true
        BackgroundAudioManager.shared.requestStart()
        task = Task.detached { [weak self] in
            let device = JITEnableContext.shared
            for line in script.split(separator: ";").map({ $0.split(separator: " ").map(String.init) }) where !line.isEmpty {
                let n = line.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
                do {
                    switch line[0] {
                    case "open": try device.agentLaunch(bundleID: line[1])
                    case "tap": try device.agentTouch(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[0], y: n[1]))
                    case "swipe": try device.agentTouch(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]))
                    case "type": try device.agentType(line.dropFirst().joined(separator: " "))
                    case "home": try device.agentHome()
                    case "wait": try? await Task.sleep(for: .seconds(n[0]))
                    case "shot":
                        try device.agentScreenshot(jpeg: false)
                            .write(to: URL.documentsDirectory.appending(path: "\(line[1]).png"))
                    default: break
                    }
                    await self?.say("ok: \(line.joined(separator: " "))")
                } catch {
                    await self?.say("failed: \(line.joined(separator: " ")): \(error.localizedDescription)")
                }
            }
            await self?.say("script done")
            await MainActor.run {
                BackgroundAudioManager.shared.requestStop()
                self?.isRunning = false
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    nonisolated private func say(_ line: String, step: Int? = nil) async {
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        await MainActor.run {
            self.log += stamped
            self.updateActivity(line: line, step: step)
        }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: Self.logURL)
        }
    }

    nonisolated private func loop(prompt: String, model: String) async {
        let device = JITEnableContext.shared
        await say("task: \(prompt)")
        guard let key = Bundle.main.url(forResource: "openrouter", withExtension: "txt")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            await say("error: openrouter.txt missing from the app bundle")
            return
        }

        let apps: [String: String]
        do {
            apps = try device.getAllApps()
        } catch {
            await say("error: no tunnel (is LocalDevVPN on and the pairing file imported?): \(error.localizedDescription)")
            return
        }
        let appList = apps.map { "\($0.value): \($0.key)" }.sorted().joined(separator: "\n")

        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt + "\n\nInstalled apps (name: bundle id):\n" + appList],
            ["role": "user", "content": "Task: \(prompt)"],
        ]

        for step in 1...Self.maxSteps {
            if Task.isCancelled { await say("stopped"); return }
            let t0 = Date()
            let image: (data: Data, size: CGSize)
            do {
                image = try Self.shrink(device.agentScreenshot(jpeg: false))
            } catch {
                await say("screenshot failed: \(error.localizedDescription)")
                return
            }
            let tShot = Date().timeIntervalSince(t0)

            Self.dropOldImages(&messages, keep: 2)
            messages.append(["role": "user", "content": [
                ["type": "text", "text": "Step \(step). Screenshot is \(Int(image.size.width))x\(Int(image.size.height)) px."],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.data.base64EncodedString()]],
            ]])

            let reply: [String: Any]
            do {
                reply = try await Self.complete(messages: messages, model: model, key: key)
            } catch {
                await say("LLM error: \(error.localizedDescription)")
                return
            }
            let tLLM = Date().timeIntervalSince(t0) - tShot
            messages.append(reply)

            guard let call = (reply["tool_calls"] as? [[String: Any]])?.first,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let callID = call["id"] as? String else {
                await say("model replied without an action: \(reply["content"] as? String ?? "")")
                messages.append(["role": "user", "content": "Call exactly one tool."])
                continue
            }
            let args = (function["arguments"] as? String)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            if let thought = reply["content"] as? String, !thought.isEmpty { await say("· \(thought)", step: step) }
            await say(String(format: "%d %@ %@  (shot %.1fs, llm %.1fs)", step, name, Self.compact(args), tShot, tLLM), step: step)

            if name == "done" {
                await say("done: \(args["summary"] as? String ?? "")")
                try? device.agentLaunch(bundleID: Bundle.main.bundleIdentifier ?? "")
                return
            }
            let result: String
            do {
                try Self.perform(name, args, imageSize: image.size, device: device)
                result = "ok"
            } catch {
                result = "error: \(error.localizedDescription)"
                await say(result)
            }
            messages.append(["role": "tool", "tool_call_id": callID, "content": result])
            try? await Task.sleep(for: .milliseconds(name == "open_app" ? 2000 : 1000))
        }
        await say("gave up after \(Self.maxSteps) steps")
    }

    nonisolated private static func perform(_ name: String, _ args: [String: Any], imageSize: CGSize, device: JITEnableContext) throws {
        func point(_ x: String, _ y: String) -> CGPoint {
            CGPoint(x: num(args[x]) / imageSize.width, y: num(args[y]) / imageSize.height)
        }
        switch name {
        case "tap":
            let p = point("x", "y")
            try device.agentTouch(from: p, to: p)
        case "swipe":
            try device.agentTouch(from: point("x1", "y1"), to: point("x2", "y2"))
        case "type":
            try device.agentType(args["text"] as? String ?? "")
        case "home":
            try device.agentHome()
        case "open_app":
            try device.agentLaunch(bundleID: args["bundle_id"] as? String ?? "")
        default:
            throw NSError(domain: "agent", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown tool \(name)"])
        }
    }

    nonisolated private static func num(_ value: Any?) -> CGFloat {
        if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
        if let s = value as? String, let d = Double(s) { return CGFloat(d) }
        return 0
    }

    nonisolated private static func compact(_ args: [String: Any]) -> String {
        args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    /// Downscale so the model sees a small image; returns JPEG + its pixel size.
    nonisolated private static func shrink(_ data: Data) throws -> (data: Data, size: CGSize) {
        guard let image = UIImage(data: data) else {
            throw NSError(domain: "agent", code: 2, userInfo: [NSLocalizedDescriptionKey: "undecodable screenshot"])
        }
        let w = imageWidth
        let size = CGSize(width: w, height: (image.size.height * w / image.size.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return (small.jpegData(compressionQuality: 0.7) ?? data, size)
    }

    /// Old screenshots cost tokens and add nothing; keep only the latest few.
    nonisolated private static func dropOldImages(_ messages: inout [[String: Any]], keep: Int) {
        var seen = 0
        for i in messages.indices.reversed() {
            guard let parts = messages[i]["content"] as? [[String: Any]],
                  parts.contains(where: { $0["type"] as? String == "image_url" }) else { continue }
            seen += 1
            if seen > keep {
                messages[i]["content"] = parts.filter { $0["type"] as? String != "image_url" }
                    + [["type": "text", "text": "(older screenshot removed)"]]
            }
        }
    }

    nonisolated private static func complete(messages: [[String: Any]], model: String, key: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "max_tokens": 1024,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = ((json?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "agent", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String(body.prefix(400))])
        }
        // Echo back only what the API accepts in history.
        var reply: [String: Any] = ["role": "assistant", "content": message["content"] as? String ?? ""]
        if let calls = message["tool_calls"] { reply["tool_calls"] = calls }
        return reply
    }

    private static let systemPrompt = """
    You operate an iPhone on behalf of its owner. Every step you get a fresh screenshot and \
    must call exactly one tool. Coordinates are pixels in that screenshot (origin top-left). \
    Prefer open_app over hunting for icons. To type, first tap the text field so the keyboard \
    is up, then call type (ASCII only; "\\n" presses return). Before acting, write one short \
    sentence of reasoning. Call done when the task is complete or impossible, with a summary.
    """

    nonisolated private static let tools: [[String: Any]] = {
        func tool(_ name: String, _ description: String, _ props: [String: String], _ types: [String: String] = [:]) -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": [
                        "type": "object",
                        "properties": props.reduce(into: [String: Any]()) { out, prop in
                            out[prop.key] = ["type": types[prop.key] ?? "number", "description": prop.value]
                        },
                        "required": Array(props.keys),
                    ] as [String: Any],
                ] as [String: Any],
            ]
        }
        return [
            tool("tap", "Tap a point.", ["x": "x pixel", "y": "y pixel"]),
            tool("swipe", "Drag from (x1,y1) to (x2,y2); swipe up to scroll down.",
                 ["x1": "start x", "y1": "start y", "x2": "end x", "y2": "end y"]),
            tool("type", "Type text into the focused field.", ["text": "text to type"], ["text": "string"]),
            tool("home", "Go to the home screen.", [:]),
            tool("open_app", "Launch an installed app by bundle id.", ["bundle_id": "bundle id"], ["bundle_id": "string"]),
            tool("done", "Finish.", ["summary": "what happened"], ["summary": "string"]),
        ]
    }()
}
