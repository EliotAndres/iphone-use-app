//
//  Realtime.swift
//  iPhoneUse
//
//  Live voice: an open mic + speaker on OpenAI's Realtime API over a WebSocket. The voice
//  model only talks; it hands phone work to PhoneAgent (the screenshot -> tap loop) with
//  run_task, relays the loop's questions, and announces the outcome. Plan: docs/REALTIME_VOICE.md.
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

    private static let instructions = """
    You are the voice of an assistant that operates this iPhone for its owner. Speak briefly, \
    one or two sentences, in the user's language. When the user wants something done on the \
    phone, call run_task with a complete, self-contained task in English (include every detail \
    the user gave). A separate agent then works the screen; you can't see it. Say in a few words \
    that you're on it. You'll get system messages: if the agent asks a question, ask the user, \
    then pass the reply with answer_question. When it finishes, tell the user the result. \
    If the user says stop or cancel during a task, call stop_task.
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
        let model = settings.realtimeModel.trimmingCharacters(in: .whitespaces)
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(settings.openAIKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        self.socket = socket
        socket.resume()
        send(["type": "session.update", "session": [
            "type": "realtime",
            "instructions": Self.instructions,
            "tools": Self.tools,
            "tool_choice": "auto",
            "audio": [
                "input": ["format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": ["type": "semantic_vad"]],
                "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": "marin"],
            ],
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
                    self.send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
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
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = event["delta"] as? String, let pcm = Data(base64Encoded: b64) { play(pcm) }
        case "response.created":
            caption = ""
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            caption += event["delta"] as? String ?? ""
        case "input_audio_buffer.speech_started":
            // Barge-in: the server cancels its reply; drop what's still queued to play.
            // ponytail: no conversation.item.truncate, so the model believes it said the whole reply.
            player.stop()
            player.play()
        case "response.function_call_arguments.done":
            let args = (event["arguments"] as? String)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            call(event["name"] as? String ?? "", args, id: event["call_id"] as? String ?? "")
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "\(event)"
            appLog.error("realtime: \(message, privacy: .public)")
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
            if agent.isRunning {
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
        send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": id, "output": output]])
        send(["type": "response.create"])
    }

    /// A system note for the model, which then speaks.
    private func tell(_ text: String) {
        guard state == .live else { return }
        send(["type": "conversation.item.create", "item": [
            "type": "message", "role": "system", "content": [["type": "input_text", "text": text]],
        ] as [String: Any]])
        send(["type": "response.create"])
    }
}
