//
//  Live.swift
//  iPhoneUse
//
//  Live voice: an open mic + speaker on OpenAI's GPT-Live (wss /v1/live/sessions). GPT-Live
//  only talks; it delegates to a Responses "tool model", whose run_task / stop_task /
//  answer_question calls drive PhoneAgent (the screenshot -> tap loop). The loop's questions and
//  outcome come back as commentary GPT-Live says aloud. Plan: docs/REALTIME_VOICE.md.
//

import AVFoundation
import Combine

@MainActor
final class LiveVoice: ObservableObject {
    static let shared = LiveVoice()

    enum State { case off, connecting, live }
    @Published private(set) var state = State.off
    /// What the model is saying (or last said).
    @Published private(set) var caption = ""
    @Published private(set) var error: String?
    let meter = LevelMeter()

    nonisolated private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    nonisolated private static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private var socket: URLSessionWebSocketTask?
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var observers: Set<AnyCancellable> = []
    private var wasRunning = false
    /// Audio sent before `session.started` is dropped by the server.
    private var started = false
    /// Delegations the backend already answered for; see `session.delegation.created`.
    private var answered: Set<String> = []

    private static let instructions = """
    You are the voice of an assistant that operates this iPhone for its owner. Speak briefly, \
    one or two sentences, in the user's language. Delegate anything to do on the phone, any stop \
    or cancel, and any answer to the agent's question. When you are told the agent asks \
    something, ask the user. When told a task ended, tell the user the result in one sentence.
    """

    private static let backendInstructions = """
    You route a voice conversation to a phone agent that operates this iPhone (it sees the \
    screen and taps; you can't). When the user wants something done on the phone, call run_task \
    with a complete, self-contained task in English including every detail they gave. If they \
    say stop or cancel, call stop_task. If the agent asked a question and the user replies, call \
    answer_question. Otherwise answer briefly yourself. Keep replies to one short sentence.
    """

    private static let tools: [[String: Any]] = [
        ["type": "function", "name": "run_task", "description": "Have the phone agent do a task on this iPhone.",
         "parameters": ["type": "object", "properties": ["task": ["type": "string", "description": "the full task"]], "required": ["task"]]],
        ["type": "function", "name": "stop_task", "description": "Stop the running task.",
         "parameters": ["type": "object", "properties": [String: Any]()]],
        ["type": "function", "name": "answer_question", "description": "Answer the agent's pending question.",
         "parameters": ["type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"]]],
    ]

    private init() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                MainActor.assumeIsolated { self?.resumeAudio() }
            }
            .store(in: &observers)
        // The loop's questions and outcome go to the model as system messages.
        let agent = PhoneAgent.shared
        agent.$question.compactMap { $0 }.sink { [weak self] question in
            self?.tell("The agent asks the user: \(question)")
        }.store(in: &observers)
        agent.$isRunning.sink { [weak self] running in
            guard let self else { return }
            defer { wasRunning = running }
            guard wasRunning, !running, let outcome = agent.history.first?.outcome else { return }
            tell("The task ended. Outcome: \(outcome)")
        }.store(in: &observers)
    }

    func toggle() async {
        if state == .off { await start() } else { stop() }
    }

    func start() async {
        guard state == .off else { return }
        error = nil
        caption = ""
        let settings = LLMSettings.shared
        guard !settings.openAIKey.isEmpty else { error = "Add an OpenAI API key."; return }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Allow microphone access in Settings to use voice."
            return
        }
        state = .connecting
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer \(settings.openAIKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        self.socket = socket
        socket.resume()
        started = false
        answered = []
        send(["type": "session.start", "session": [
            "model": settings.liveModel.trimmingCharacters(in: .whitespaces),
            "instructions": Self.instructions,
            "audio": ["format": ["type": "audio/pcm", "rate": 24_000], "output": ["voice": "marin"]],
            "delegation": ["type": "responses", "responses": [
                "model": settings.liveBackendModel.trimmingCharacters(in: .whitespaces),
                "instructions": Self.backendInstructions,
                "tools": Self.tools,
                "tool_choice": "auto",
                "parallel_tool_calls": false,
            ] as [String: Any]],
        ] as [String: Any]])
        receive(socket)
        do {
            BackgroundAudioManager.shared.suspended = true // before we take the session
            try startAudio()
            state = .live
        } catch {
            fail("Audio: \(error.localizedDescription)")
        }
    }

    func stop() {
        send(["type": "session.close"])
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        BackgroundAudioManager.shared.suspended = false
        meter.levels = []
        state = .off
    }

    private func fail(_ message: String) {
        guard state != .off else { return }
        error = message
        stop()
    }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat = Apple's echo cancellation, so the model doesn't hear itself on the speaker.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        try engine.inputNode.setVoiceProcessingEnabled(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playFormat)
        try VoiceRecorder.installTap(on: engine.inputNode, format: Self.format) { [weak self] chunk, level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state == .live else { return }
                    // GPT-Live wants the mic streamed continuously, silence included.
                    if self.started { self.send(["type": "session.input_audio.append", "audio": chunk.base64EncodedString()]) }
                    self.meter.levels = (self.meter.levels + [level]).suffix(VoiceRecorder.levelCount)
                }
            }
        }
        try engine.start()
        player.play()
    }

    private func resumeAudio() {
        guard state != .off else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    private func play(_ pcm: Data) {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.playFormat, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            for (i, sample) in raw.bindMemory(to: Int16.self).enumerated() { out[i] = Float(Int16(littleEndian: sample)) / 32768 }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.fail(error.localizedDescription) }
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        Task { [weak self] in
            do {
                while true {
                    let message = try await socket.receive()
                    guard case .string(let text) = message,
                          let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                    self?.handle(event)
                }
            } catch {
                guard let self, self.socket === socket else { return }
                self.fail("Connection closed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.started":
            started = true
        case "session.output_audio.delta":
            // A continuous track, silence included; GPT-Live handles barge-in itself.
            if let b64 = event["delta"] as? String, let pcm = Data(base64Encoded: b64) { play(pcm) }
        case "session.output_transcript.delta":
            caption = String((caption + (event["delta"] as? String ?? "")).suffix(200))
        case "session.input_transcript.delta":
            caption = "" // the user is talking
        case "session.delegation.created":
            // The docs disagree on whether the client must send response.create to run the
            // backend; send it only if the backend hasn't started on its own.
            guard let id = (event["delegation"] as? [String: Any])?["id"] as? String else { break }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.state == .live, !self.answered.contains(id) else { return }
                self.send(["type": "response.create"])
            }
        case "response.event":
            if let id = event["delegation_id"] as? String { answered.insert(id) }
            guard let inner = event["event"] as? [String: Any], inner["type"] as? String == "response.output_item.done",
                  let item = inner["item"] as? [String: Any], item["type"] as? String == "function_call" else { break }
            let args = (item["arguments"] as? String)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            call(item["name"] as? String ?? "", args, id: item["call_id"] as? String ?? "")
        case "session.closed":
            fail("Session ended: \(event["reason"] as? String ?? "closed")")
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "\(event)"
            appLog.error("live: \(message, privacy: .public)")
            error = message
        default:
            break
        }
    }

    private func call(_ name: String, _ args: [String: Any], id: String) {
        let agent = PhoneAgent.shared
        let output: String
        switch name {
        case "run_task":
            if agent.question != nil {
                // The backend can't tell a reply to the agent's question from a new request.
                agent.answer(args["task"] as? String ?? "")
                output = "Passed to the agent as the answer to its question."
            } else if agent.isRunning {
                output = "A task is already running."
            } else {
                agent.run(prompt: args["task"] as? String ?? "")
                output = "Started. You'll get a system message when the agent asks something or finishes."
            }
        case "stop_task":
            agent.stop()
            output = agent.isRunning ? "Stopping." : "Nothing was running."
        case "answer_question":
            if agent.question != nil {
                agent.answer(args["answer"] as? String ?? "")
                output = "Answer sent, the agent continues."
            } else {
                output = "The agent has no pending question."
            }
        default:
            output = "Unknown tool \(name)."
        }
        send(["type": "response.item.create", "item": ["type": "function_call_output", "call_id": id, "output": output]])
        send(["type": "response.create"]) // results alone don't resume the backend
    }

    /// Something for GPT-Live to say (it may paraphrase).
    private func tell(_ text: String) {
        guard state == .live, started else { return }
        send(["type": "session.commentary.append", "delegation_id": NSNull(), "content": text])
    }
}
