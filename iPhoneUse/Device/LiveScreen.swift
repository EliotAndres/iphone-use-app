//
//  LiveScreen.swift
//  iPhoneUse
//
//  The phone's screen as live video: the DisplayService stream (the one iOS 27 needs open for touches anyway)
//  stays open for a run, Rust hands over one HEVC frame at a time, VideoToolbox decodes it, and the latest frame
//  replaces the 0.9 s CoreDevice PNG screenshot. Any decode failure drops the frame, so callers fall back to it.
//

import CoreMedia
import Foundation
import UIKit
import VideoToolbox
import idevice

final class LiveScreen: @unchecked Sendable {
    static let shared = LiveScreen()

    private let lock = NSLock()
    private var latest: CVPixelBuffer? // guarded by lock
    private var frames = 0, errors = 0, lastError: OSStatus = 0, keyframeRequests = 0 // guarded by lock
    private var reader: Thread?

    /// Starts streaming; throws when the device refuses a stream (pre-iOS 27 refuses remote control).
    func start(_ device: DeviceSession) throws {
        stop()
        try device.agentStartStream()
        lock.withLock { frames = 0; errors = 0; keyframeRequests = 0 }
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "LiveScreen"
        reader = thread
        thread.start()
        for _ in 0..<20 where lock.withLock({ latest }) == nil { Thread.sleep(forTimeInterval: 0.05) } // first frame
    }

    /// Stops streaming; returns a one-line summary for the log.
    @discardableResult
    func stop() -> String {
        let summary = lock.withLock {
            let size = latest.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none"
            return "live: \(frames) frames, \(errors) decode errors (last \(lastError)), \(keyframeRequests) keyframe requests, last \(size)"
        }
        probe_stream_stop()
        reader = nil
        lock.withLock { latest = nil }
        return summary
    }

    /// The latest frame as JPEG, or nil when there's none (not started, not decodable yet, or broken).
    func jpeg() -> Data? {
        guard let buffer = lock.withLock({ latest }) else { return nil }
        return Self.jpeg(buffer)
    }

    private func readLoop() {
        var decoder = HEVCDecoder()
        var askedKeyframe = Date.distantPast
        while true {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = UInt(0)
            let result = probe_stream_next(1000, &bytes, &length)
            if result < 0 { break }
            guard result == 1, let bytes else { continue }
            let frame = Data(bytes: bytes, count: Int(length))
            idevice_data_free(bytes, length)
            let buffer = decoder.decode(frame)
            if decoder.needsKeyframe, Date().timeIntervalSince(askedKeyframe) > 0.5 {
                probe_stream_keyframe()
                askedKeyframe = Date()
                lock.withLock { keyframeRequests += 1 }
            }
            lock.withLock {
                if let buffer { latest = buffer; frames += 1 } else if decoder.ready { latest = nil; errors += 1; lastError = decoder.lastStatus }
            }
        }
        lock.withLock { latest = nil }
    }

    private static let screen = UIScreen.main.nativeBounds.size // portrait pixels

    private static func jpeg(_ buffer: CVPixelBuffer) -> Data? {
        // CPU only: the app is in the background while it drives other apps.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            // The encoder pads right and bottom to 16 px blocks (1216x2656 for a 1206x2622 screen) and the stream
            // carries no crop, but this is the phone being streamed: crop to its own screen.
            let image = context.makeImage()?.cropping(to: CGRect(origin: .zero, size: screen)) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}

/// Annex-B HEVC access units in, BGRA pixel buffers out.
struct HEVCDecoder {
    private var parameterSets: [Data] = [] // VPS, SPS, PPS
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Has seen parameter sets, so a failed frame is a real error (not just waiting for the first keyframe).
    var ready: Bool { session != nil }
    /// A fresh session has no reference picture: frames until the next keyframe would decode to gray.
    private(set) var needsKeyframe = true
    private(set) var lastStatus: OSStatus = noErr

    mutating func decode(_ annexB: Data) -> CVPixelBuffer? {
        var sets: [UInt8: Data] = [:]
        var sample = Data()
        var keyframe = false
        for nal in Self.nalUnits(annexB) {
            let type = (nal.first! >> 1) & 0x3f
            if (16...23).contains(type) { keyframe = true }
            switch type {
            case 32, 33, 34: sets[(nal.first! >> 1) & 0x3f] = nal
            case 0...31: // slices, 4-byte big-endian length prefixed
                withUnsafeBytes(of: UInt32(nal.count).bigEndian) { sample.append(contentsOf: $0) }
                sample.append(nal)
            default: break // AUD, SEI
            }
        }
        if let vps = sets[32], let sps = sets[33], let pps = sets[34], [vps, sps, pps] != parameterSets {
            parameterSets = [vps, sps, pps]
            makeSession()
        }
        guard let session, let format, !sample.isEmpty else { return nil }
        if keyframe { needsKeyframe = false }
        if needsKeyframe { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        _ = sample.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: sample.count)
        }
        var buffer: CMSampleBuffer?
        var size = sample.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }

        var output: CVPixelBuffer?
        // No async flag: the handler runs before DecodeFrame returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            if status == noErr { output = image }
        }
        lastStatus = status != noErr ? status : output == nil ? -1 : noErr
        if status == kVTInvalidSessionErr { makeSession() } // e.g. after the app went to the background
        return status == noErr ? output : nil
    }

    private mutating func makeSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        needsKeyframe = true
        guard parameterSets.count == 3 else { return }
        let sets = parameterSets.map { $0 as NSData }
        let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = sets.map(\.length)
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { return }
        // Software decoder: VideoToolbox's hardware one drops every frame once the app is in the background,
        // which is where it is while driving other apps.
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary, imageBufferAttributes: attributes,
            outputCallback: nil, decompressionSessionOut: &session
        ) == noErr else { return }
        self.format = format
        self.session = session
    }

    /// Splits on 4-byte start codes (the depacketizer only writes those; emulation prevention keeps them out of NALs).
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append(i + 4); i += 4 } else { i += 1 }
        }
        return starts.enumerated().compactMap { n, start in
            let end = n + 1 < starts.count ? starts[n + 1] - 4 : bytes.count
            return end > start ? Data(bytes[start..<end]) : nil
        }
    }
}
