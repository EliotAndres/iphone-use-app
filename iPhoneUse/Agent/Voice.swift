//
//  Voice.swift
//  iPhoneUse
//
//  Voice prompts: records the mic to 16 kHz mono PCM in memory (no file, no encoder) and
//  transcribes it in one call to OpenRouter's /audio/transcriptions.
//

import AVFoundation

@MainActor
final class LevelMeter: ObservableObject {
    /// Recent input levels, 0...1, newest last.
    @Published var levels: [Float] = []
}

@MainActor
final class VoiceRecorder: ObservableObject {
    static let shared = VoiceRecorder()

    enum State { case idle, recording, transcribing }
    @Published private(set) var state = State.idle
    /// Input levels live apart from `state` so only the waveform redraws on each audio chunk.
    let meter = LevelMeter()
    @Published private(set) var error: String?

    static let levelCount = 60
    nonisolated private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private var engine = AVAudioEngine()
    private var pcm = Data()

    private init() {}

    func start() async {
        guard state == .idle else { return }
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Allow microphone access in Settings to use voice."
            return
        }
        // Open the TLS connection now so the upload doesn't pay for it.
        var warmUp = URLRequest(url: URL(string: LLMSettings.openRouterURL)!)
        warmUp.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: warmUp).resume()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: .defaultToSpeaker)
            try session.setActive(true)
            engine = AVAudioEngine()
            pcm = Data()
            meter.levels = []
            try Self.installTap(on: engine.inputNode) { [weak self] chunk, level in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.state == .recording else { return }
                        self.pcm.append(chunk)
                        self.meter.levels = (self.meter.levels + [level]).suffix(Self.levelCount)
                    }
                }
            }
            try engine.start()
            state = .recording
        } catch {
            self.error = error.localizedDescription
            stopEngine()
        }
    }

    /// Stops recording and returns the transcript, or nil on failure (see `error`).
    func finish() async -> String? {
        guard state == .recording else { return nil }
        stopEngine()
        state = .transcribing
        defer { state = .idle }
        let settings = LLMSettings.shared
        do {
            let text = try await Self.transcribe(wav: Self.wav(pcm), apiKey: settings.apiKey,
                                                 model: settings.voiceModel, language: settings.voiceLanguage)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = "Transcription failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Runs on the audio thread, so it must not inherit the main actor.
    nonisolated private static func installTap(on input: AVAudioInputNode,
                                               onChunk: @escaping @Sendable (Data, Float) -> Void) throws {
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw NSError(domain: "voice", code: 0, userInfo: [NSLocalizedDescriptionKey: "No microphone input."])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            let samples = UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))
            guard !samples.isEmpty else { return }
            let rms = sqrt(samples.reduce(0) { $0 + Float($1) * Float($1) } / Float(samples.count)) / Float(Int16.max)
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50)) // -50...0 dB
            onChunk(Data(buffer: samples), level)
        }
    }

    nonisolated private static func wav(_ pcm: Data) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let rate = UInt32(format.sampleRate)
        var data = Data("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16))
        return data + Data("data".utf8) + le(UInt32(pcm.count)) + pcm
    }

    nonisolated private static func transcribe(wav: Data, apiKey: String, model: String, language: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]
        if !language.isEmpty { body["language"] = language }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "voice", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String(body.prefix(400))])
        }
        return text
    }
}
