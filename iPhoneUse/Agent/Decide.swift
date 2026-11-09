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
        /// Service tier OpenRouter reports it used ("fast" when the fast tier served the request).
        var tier: String
    }

    static let imageWidth: CGFloat = 450

    /// OpenRouter cost of every request so far, in USD, from each response's `usage.cost`.
    // ponytail: unsynchronized global, fine while decisions run one at a time; per-call results if they go parallel.
    nonisolated(unsafe) static var spent = 0.0
    nonisolated(unsafe) static var reasoningRequired: Set<String> = []

    /// The conversation a run starts with. The installed apps are not listed (706 apps were ~13k
    /// tokens a step); `open_app` takes a name and `appBundleID` resolves it on the phone.
    static func firstMessages(task: String, config: LLMConfig) -> [[String: Any]] {
        [
            ["role": "system", "content": config.systemPrompt],
            ["role": "user", "content": "Task: \(task)"],
        ]
    }

    /// Bundle id for an app name as the model wrote it: exact, then prefix, then substring
    /// (case-insensitive), or a bundle id itself. nil if nothing matches.
    static func appBundleID(_ name: String, in apps: [String: String]) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if apps[name] != nil { return name }
        for match in [{ (a: String) in a == n }, { $0.hasPrefix(n) }, { $0.contains(n) }] {
            if let hit = apps.filter({ match($0.value.lowercased()) }).min(by: { $0.value.count < $1.value.count }) { return hit.key }
        }
        return nil
    }

    /// For the error when `appBundleID` finds nothing: names sharing a word with `name`.
    static func similarApps(_ name: String, in apps: [String: String]) -> [String] {
        let words = Set(name.lowercased().split(separator: " ").map(String.init))
        return apps.values.filter { !words.isDisjoint(with: $0.lowercased().split(separator: " ").map(String.init)) }.sorted().prefix(10).map { $0 }
    }

    /// Adds the screenshot (full-size PNG/JPEG) to `messages`, asks the model, appends its reply.
    static func next(task: String, messages: inout [[String: Any]], screenshot raw: Data, step: Int,
                     config: LLMConfig) async throws -> Decision {
        let image = try shrink(raw)
        dropOldImages(&messages, keep: 2)
        messages.append(["role": "user", "content": [
            ["type": "text", "text": "Step \(step). Screenshot is \(Int(image.size.width))x\(Int(image.size.height)) px."],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.data.base64EncodedString()]],
        ]])

        let t0 = Date()
        let (reply, tier) = try await complete(messages: messages, config: config)
        let timing = String(format: "llm %.1fs%@", Date().timeIntervalSince(t0), tier == "fast" ? " fast" : "")
        messages.append(reply)
        return Decision(reply: reply, image: image, timing: timing, tier: tier)
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

    /// One chat completion; returns the assistant message and the service tier that served it.
    static func complete(messages: [[String: Any]], config: LLMConfig) async throws -> (reply: [String: Any], tier: String) {
        var request = URLRequest(url: config.chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "max_tokens": 1024,
        ]
        // Faster, pricier serving where the model has it (e.g. Claude Opus 5); ignored elsewhere.
        if config.fastTier { body["service_tier"] = "fast" }
        // Reasoning models think before each tool call; off is faster (see README "Benchmark").
        // Some (e.g. Sonnet 5.5) refuse to turn it off: retry with it on and remember the model.
        let noReasoning = config.noReasoning && !reasoningRequired.contains(config.model)
        if noReasoning { body["reasoning"] = ["effort": "none"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = ((json?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if noReasoning && body.contains("Reasoning is mandatory") {
                reasoningRequired.insert(config.model)
                return try await complete(messages: messages, config: config)
            }
            throw NSError(domain: "agent", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String(body.prefix(400))])
        }
        // With a BYOK provider key OpenRouter's own cost is 0 and the provider's is in cost_details.
        let usage = json?["usage"] as? [String: Any]
        spent += (usage?["cost"] as? Double ?? 0)
            + ((usage?["cost_details"] as? [String: Any])?["upstream_inference_cost"] as? Double ?? 0)
        // Echo back only what the API accepts in history.
        var reply: [String: Any] = ["role": "assistant", "content": message["content"] as? String ?? ""]
        if let calls = message["tool_calls"] { reply["tool_calls"] = calls }
        // OpenRouter reports the fast tier as "priority".
        let tier = json?["service_tier"] as? String ?? "default"
        return (reply, tier == "default" ? "default" : "fast")
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
            tool("open_app", "Launch an installed app by its name as shown on the home screen.",
                 ["name": "app name, e.g. Settings, Lyft"], ["name": "string"]),
            tool("ask_user_question", "Ask the phone's owner for missing information or a decision, then wait for the answer. "
                 + "This app comes to the front while waiting, so reopen the app you were using afterwards.",
                 ["question": "the question to show the user"], ["question": "string"]),
            tool("done", "Finish.", ["summary": "what happened"], ["summary": "string"]),
        ]
    }()
}
