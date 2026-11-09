//
//  Jev.swift
//  iPhoneUse
//
//  TypeSafe's Jev is a "decisions" model: no chat, no tool calls, no free text. It answers
//  typed questions (choice, box) about a state. Each step asks which action to take, where
//  on the screenshot (box) and which app, then returns a reply shaped like a chat tool call
//  so the agent loop doesn't care which kind of model it talks to.
//  API: https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request.md
//

import Foundation

enum Jev {
    /// `box` questions need jev-1.14 or later; 1.13 answers them with a 400.
    static let model = "typesafe/jev-1.14"
    static let url = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    static func handles(_ model: String) -> Bool { model.contains("typesafe/jev") }

    private static let actions = [
        "tap": "tap the target element",
        "long_press": "touch and hold the target element, e.g. for a context menu",
        "scroll_down": "swipe up to reveal content further down",
        "scroll_up": "swipe down to reveal content further up",
        "type": "type text into the focused text field (the keyboard is up)",
        "open_app": "launch an installed app directly",
        "home": "go to the home screen",
        "done": "the task is complete",
    ]

    /// One decision for the current screenshot, returned as an assistant message with one tool call.
    static func decide(task: String, messages: [[String: Any]], image: (data: Data, size: CGSize),
                       apps: [String: String], config: LLMConfig) async throws -> [String: Any] {
        let calls = messages.compactMap { ($0["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any] }
        let done = calls.enumerated().map { "\($0.offset + 1). \($0.element["name"] ?? "") \($0.element["arguments"] ?? "")" }
        let state: [Any] = [
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.data.base64EncodedString()]],
            "You operate this iPhone for its owner. The image is the current screen.\nTask: \(task)\n"
                + "Actions taken so far:\n" + (done.isEmpty ? "none" : done.joined(separator: "\n")),
        ]
        var questions: [String: Any] = [
            "action": ["type": "choice", "instructions": "Which single next action best moves toward the task?",
                       "criteria": actions],
            "target": ["type": "box", "instructions": "The element on the screen to act on next (for tap or long_press)."],
        ]
        // A choice takes at most 255 options: with more apps, pick one only when the action is open_app.
        if apps.count <= maxChoices { questions["app"] = appQuestion(apps) }
        let answers = try await ask(state: state, questions: questions, config: config)
        guard let action = answers["action"]?["choice"] as? String else {
            throw NSError(domain: "jev", code: 0, userInfo: [NSLocalizedDescriptionKey: "No action in Jev's answer."])
        }
        let box = answers["target"]?["box"] as? [String: Double] ?? [:]
        let x = ((box["left"] ?? 0.5) + (box["right"] ?? 0.5)) / 2 * image.size.width
        let y = ((box["top"] ?? 0.5) + (box["bottom"] ?? 0.5)) / 2 * image.size.height
        let w = image.size.width, h = image.size.height
        let confidence = answers["action"]?["confidence"] as? Double ?? 0

        let (name, args): (String, [String: Any])
        switch action {
        case "tap", "long_press": (name, args) = (action, ["x": Int(x), "y": Int(y)])
        case "scroll_down": (name, args) = ("swipe", ["x1": Int(w / 2), "y1": Int(h * 0.7), "x2": Int(w / 2), "y2": Int(h * 0.3)])
        case "scroll_up": (name, args) = ("swipe", ["x1": Int(w / 2), "y1": Int(h * 0.3), "x2": Int(w / 2), "y2": Int(h * 0.7)])
        case "open_app":
            var app = answers["app"]?["choice"] as? String
            if app == nil { app = try await pickApp(apps, state: state, config: config) }
            (name, args) = ("open_app", ["bundle_id": app ?? ""])
        case "done": (name, args) = ("done", ["summary": "Jev considers the task done."])
        case "type":
            // Jev can't write text: ask the owner, then type their answer the next time it picks `type`.
            let lastAsk = messages.lastIndex { ($0["content"] as? String)?.hasPrefix("The user answered: ") == true }
            let lastType = messages.lastIndex { message in
                ((message["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String == "type"
            }
            if let lastAsk, lastAsk > (lastType ?? -1), let answer = messages[lastAsk]["content"] as? String {
                (name, args) = ("type", ["text": String(answer.dropFirst("The user answered: ".count))])
            } else {
                (name, args) = ("ask_user_question", ["question": "What should I type? (Jev can't write text)"])
            }
        default: (name, args) = ("home", [:])
        }
        let arguments = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
        return [
            "role": "assistant",
            "content": String(format: "%@ (%.0f%% sure)", action, confidence * 100),
            "tool_calls": [["id": UUID().uuidString, "type": "function", "function": ["name": name, "arguments": arguments]]],
        ]
    }

    static let maxChoices = 255

    private static func appQuestion(_ apps: [String: String]) -> [String: Any] {
        ["type": "choice", "instructions": "Which installed app is most useful for the task?",
         "criteria": apps.isEmpty ? ["none": "no apps"] : apps] // bundle id: name
    }

    /// Picks an app from more than `maxChoices`: the best of each batch, then the best of those.
    private static func pickApp(_ apps: [String: String], state: [Any], config: LLMConfig) async throws -> String {
        if apps.count <= maxChoices {
            return try await ask(state: state, questions: ["app": appQuestion(apps)], config: config)["app"]?["choice"] as? String ?? ""
        }
        let ids = apps.keys.sorted()
        var winners: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: maxChoices) {
            let batch = ids[start..<min(start + maxChoices, ids.count)]
            let id = try await pickApp(Dictionary(uniqueKeysWithValues: batch.map { ($0, apps[$0]!) }), state: state, config: config)
            if let name = apps[id] { winners[id] = name }
        }
        return try await pickApp(winners, state: state, config: config)
    }

    private static func ask(state: [Any], questions: [String: Any], config: LLMConfig) async throws -> [String: [String: Any]] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "state": state, "questions": questions,
        ] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let answers = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["answers"] as? [String: [String: Any]] else {
            throw NSError(domain: "jev", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String((String(data: data, encoding: .utf8) ?? "").prefix(400))])
        }
        return answers
    }
}
