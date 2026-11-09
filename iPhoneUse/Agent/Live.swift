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

    private var socket: URLSessionWebSocketTask?
    private var audio: VoiceIO?
    private var observers: Set<AnyCancellable> = []
    private var wasRunning = false
    private var started = false
    /// Mic chunks sent / output audio chunks received / loudest mic level, logged every 5 s.
    private var sentChunks = 0, gotChunks = 0, peak: Float = 0
    nonisolated private static let logURL = URL.documentsDirectory.appending(path: "live.log")
    /// Delegations the backend already answered for; see `session.delegation.created`.
    private var answered: Set<String> = []
    /// The chat this call's tasks go into, so a call is one chat.
    private var callRun: RunRecord.ID?

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

    /// Launch arg `-liveMicTest YES`: mic only, no socket, 6 s, then see Documents/live.log.
    func micTest() {
        try? FileManager.default.removeItem(at: Self.logURL)
        log("mic test")
        do {
            BackgroundAudioManager.shared.suspended = true
            try startAudio()
            state = .live
        } catch {
            log("startAudio failed: \(error)")
        }
        Task {
            try? await Task.sleep(for: .seconds(6))
            log("mic test end: \(sentChunks) chunks, peak \(peak)")
            stop()
        }
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
        callRun = nil
        (sentChunks, gotChunks, peak) = (0, 0, 0)
        try? FileManager.default.removeItem(at: Self.logURL)
        log("connecting, voice \(settings.liveModel), tools \(settings.liveBackendModel)")
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
        audio?.stop()
        audio = nil
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
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let audio = VoiceIO { [weak self] chunk, level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state == .live else { return }
                    // GPT-Live wants the mic streamed continuously, silence included. Not gated on
                    // session.started: the server drops early audio anyway.
                    self.send(["type": "session.input_audio.append", "audio": chunk.base64EncodedString()])
                    self.sentChunks += 1
                    self.peak = max(self.peak, level)
                    if self.sentChunks % 100 == 0 {
                        self.log("mic: sent \(self.sentChunks) chunks, peak level \(self.peak), got \(self.gotChunks) audio chunks, started \(self.started)")
                        self.peak = 0
                    }
                    self.meter.levels = (self.meter.levels + [level]).suffix(VoiceRecorder.levelCount)
                }
            }
        }
        try audio.start()
        self.audio = audio
        log("audio started, route \(session.currentRoute.inputs.map(\.portName)) -> \(session.currentRoute.outputs.map(\.portName))")
    }

    private func resumeAudio() {
        guard state != .off else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? audio?.start()
    }

    private func play(_ pcm: Data) {
        audio?.enqueue(pcm)
    }

    func log(_ line: String) {
        let stamped = Data("\(Date().formatted(date: .omitted, time: .standard)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            handle.seekToEndOfFile()
            handle.write(stamped)
            try? handle.close()
        } else {
            try? stamped.write(to: Self.logURL)
        }
    }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.log("send failed: \(error)"); self?.fail(error.localizedDescription) }
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
                self.log("socket closed: \(error), close code \(socket.closeCode.rawValue), reason \(socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "")")
                self.fail("Connection closed: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if type == "session.output_audio.delta" { gotChunks += 1 } else {
            log("<- " + String((String(data: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), encoding: .utf8) ?? type).prefix(600)))
        }
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
                agent.run(prompt: args["task"] as? String ?? "", continuing: callRun)
                callRun = agent.liveRun?.id
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

/// The VoiceProcessingIO audio unit (echo cancellation, as in FaceTime / WebRTC), with mic and
/// speaker both 24 kHz mono PCM16 so no conversion is needed. AVAudioEngine's voice processing
/// mode delivered no mic buffers at all on iOS 26/27 (tested on a 16 Pro), hence the raw unit.
final class VoiceIO: @unchecked Sendable {
    private var unit: AudioUnit?
    private let onMic: @Sendable (Data, Float) -> Void
    // ponytail: a lock on the render thread, fine at 24 kHz; a lock-free ring if it ever glitches.
    private let lock = NSLock()
    private var queue = Data()
    private let micBuffer = UnsafeMutableRawPointer.allocate(byteCount: 16_384, alignment: 2)

    init(onMic: @escaping @Sendable (Data, Float) -> Void) { self.onMic = onMic }
    deinit { stop(); micBuffer.deallocate() }

    func start() throws {
        if let unit { return try check(AudioOutputUnitStart(unit), "start") }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw Self.error("no voice processing unit") }
        var made: AudioUnit?
        try check(AudioComponentInstanceNew(component, &made), "new")
        guard let unit = made else { throw Self.error("no unit") }
        self.unit = unit
        var on: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable mic")
        var format = AudioStreamBasicDescription(mSampleRate: 24_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                 mBitsPerChannel: 16, mReserved: 0)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size), "mic format")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size), "speaker format")
        let me = Unmanaged.passUnretained(self).toOpaque()
        var mic = AURenderCallbackStruct(inputProc: Self.micCallback, inputProcRefCon: me)
        var speaker = AURenderCallbackStruct(inputProc: Self.speakerCallback, inputProcRefCon: me)
        let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &mic, callbackSize), "mic callback")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &speaker, callbackSize), "speaker callback")
        try check(AudioUnitInitialize(unit), "initialize")
        try check(AudioOutputUnitStart(unit), "start")
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    func enqueue(_ pcm: Data) {
        lock.lock()
        queue.append(pcm)
        lock.unlock()
    }

    private static let micCallback: AURenderCallback = { refCon, flags, time, bus, frames, _ in
        let io = Unmanaged<VoiceIO>.fromOpaque(refCon).takeUnretainedValue()
        guard let unit = io.unit else { return noErr }
        let bytes = min(Int(frames) * 2, 16_384)
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: io.micBuffer))
        let status = AudioUnitRender(unit, flags, time, bus, frames, &list)
        guard status == noErr else { return status }
        let count = Int(list.mBuffers.mDataByteSize) / 2
        let samples = UnsafeBufferPointer(start: io.micBuffer.assumingMemoryBound(to: Int16.self), count: count)
        guard count > 0 else { return noErr }
        let rms = sqrt(samples.reduce(0) { $0 + Float($1) * Float($1) } / Float(count)) / Float(Int16.max)
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50)) // -50...0 dB, as in VoiceRecorder
        io.onMic(Data(buffer: samples), level)
        return noErr
    }

    private static let speakerCallback: AURenderCallback = { refCon, _, _, _, frames, data in
        let io = Unmanaged<VoiceIO>.fromOpaque(refCon).takeUnretainedValue()
        guard let buffer = UnsafeMutableAudioBufferListPointer(data)?.first, let out = buffer.mData else { return noErr }
        let want = Int(buffer.mDataByteSize)
        io.lock.lock()
        let n = min(want, io.queue.count)
        io.queue.copyBytes(to: out.assumingMemoryBound(to: UInt8.self), count: n)
        io.queue = io.queue.dropFirst(n)
        io.lock.unlock()
        if n < want { memset(out + n, 0, want - n) }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw Self.error("\(what) failed (\(status))")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "voiceio", code: 0, userInfo: [NSLocalizedDescriptionKey: "Audio: \(message)"])
    }
}
