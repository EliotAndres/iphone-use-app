//
//  ScreenText.swift
//  iPhoneUse
//
//  On-device OCR (Vision, accurate mode) of a screenshot: the text Jev picks tap targets from.
//  About 125 ms for an iPhone screenshot on an M-series Mac; logged per step on the phone.
//

import Foundation
import Vision

enum ScreenText {
    struct Item {
        let text: String
        /// Normalized, origin top-left.
        let rect: CGRect
    }

    /// Text lines top to bottom, then left to right.
    static func read(_ imageData: Data) throws -> [Item] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(data: imageData).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox // origin bottom-left
            return Item(text: text, rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        .sorted { abs($0.rect.minY - $1.rect.minY) < 0.01 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
    }
}
