//
//  Decide.swift
//  iPhoneUse
//
//  One agent step without the device: (task, chat history, screenshot, apps) -> one tool call.
//  PhoneAgent.loop calls it on the phone; scripts/eval.sh calls the same code on the Mac against
//  saved screenshots (evals/). Keep it free of UIKit and device code so both can compile it.
//

import Foundation
import ImageIO

enum Decide {
    struct Decision {
        /// Assistant message with (usually) one tool call; already appended to `messages`.
        var reply: [String: Any]
        /// The screenshot as the model saw it; tool call coordinates are pixels in `image.size`.
        var image: (data: Data, size: CGSize)
        var timing: String
        /// Why Jev handed this step to `Jev.handoverModel`, if it did.
        var handover: String?
    }

    static let imageWidth: CGFloat = 450

    /// OpenRouter cost of every request so far, in USD, from each response's `usage.cost`.
    // ponytail: unsynchronized global, fine while decisions run one at a time; per-call results if they go parallel.
    nonisolated(unsafe) static var spent = 0.0

    /// The conversation a run starts with.
    static func firstMessages(task: String, apps: [String: String], config: LLMConfig) -> [[String: Any]] {
        let appList = apps.map { "\($0.value): \($0.key)" }.sorted().joined(separator: "\n")
        return [
            ["role": "system", "content": config.systemPrompt + "\n\nInstalled apps (name: bundle id):\n" + appList],
            ["role": "user", "content": "Task: \(task)"],
        ]
    }

    /// Adds the screenshot (full-size PNG/JPEG) to `messages`, asks the model, appends its reply.
    static func next(task: String, messages: inout [[String: Any]], screenshot raw: Data, step: Int,
                     apps: [String: String], config: LLMConfig) async throws -> Decision {
        let image = try shrink(raw)
        dropOldImages(&messages, keep: 2)
        messages.append(["role": "user", "content": [
            ["type": "text", "text": "Step \(step). Screenshot is \(Int(image.size.width))x\(Int(image.size.height)) px."],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.data.base64EncodedString()]],
        ]])

        let t0 = Date()
        var reply: [String: Any]
        var timing = ""
        var handover: String?
        if Jev.handles(config.model) {
            let screenText = (try? ScreenText.read(raw)) ?? []
            let tJev = Date()
            reply = try await Jev.decide(task: task, messages: messages, image: image,
                                         screenText: screenText, apps: apps, config: config)
            timing = String(format: "ocr %.2fs (%d lines), jev %.2fs", tJev.timeIntervalSince(t0),
                            screenText.count, Date().timeIntervalSince(tJev))
            if let reason = reply["handover"] as? String {
                handover = reason
                let tLLM = Date()
                var fallback = config
                fallback.model = Jev.handoverModel
                reply = try await complete(messages: messages, config: fallback)
                reply["content"] = "[\(reason), \(Jev.handoverModel) took over] " + (reply["content"] as? String ?? "")
                timing += String(format: ", llm %.1fs", Date().timeIntervalSince(tLLM))
            }
        } else {
            reply = try await complete(messages: messages, config: config)
            timing = String(format: "llm %.1fs", Date().timeIntervalSince(t0))
        }
        messages.append(reply)
        return Decision(reply: reply, image: image, timing: timing, handover: handover)
    }

    /// Downscale so the model sees a small image; returns JPEG + its pixel size.
    static func shrink(_ data: Data) throws -> (data: Data, size: CGSize) {
        let fail = NSError(domain: "agent", code: 2, userInfo: [NSLocalizedDescriptionKey: "undecodable screenshot"])
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw fail }
        let size = CGSize(width: imageWidth, height: (CGFloat(image.height) * imageWidth / CGFloat(image.width)).rounded())
        let out = NSMutableData()
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { throw fail }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let small = context.makeImage() else { throw fail }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw fail }
        return (out as Data, size)
    }

    /// Old screenshots cost tokens and add nothing; keep only the latest few.
    static func dropOldImages(_ messages: inout [[String: Any]], keep: Int) {
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

    static func complete(messages: [[String: Any]], config: LLMConfig) async throws -> [String: Any] {
        var request = URLRequest(url: config.chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
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
        spent += (json?["usage"] as? [String: Any])?["cost"] as? Double ?? 0
        // Echo back only what the API accepts in history.
        var reply: [String: Any] = ["role": "assistant", "content": message["content"] as? String ?? ""]
        if let calls = message["tool_calls"] { reply["tool_calls"] = calls }
        return reply
    }

    static let tools: [[String: Any]] = {
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
            tool("long_press", "Touch and hold a point, e.g. for a context menu.", ["x": "x pixel", "y": "y pixel"]),
            tool("swipe", "Drag from (x1,y1) to (x2,y2); swipe up to scroll down.",
                 ["x1": "start x", "y1": "start y", "x2": "end x", "y2": "end y"]),
            tool("type", "Type text into the focused field.", ["text": "text to type"], ["text": "string"]),
            tool("home", "Go to the home screen.", [:]),
            tool("open_app", "Launch an installed app by bundle id.", ["bundle_id": "bundle id"], ["bundle_id": "string"]),
            tool("ask_user_question", "Ask the phone's owner for missing information or a decision, then wait for the answer. "
                 + "This app comes to the front while waiting, so reopen the app you were using afterwards.",
                 ["question": "the question to show the user"], ["question": "string"]),
            tool("done", "Finish.", ["summary": "what happened"], ["summary": "string"]),
        ]
    }()
}
