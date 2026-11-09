//
//  Jev.swift
//  iPhoneUse
//
//  TypeSafe's Jev is a "decisions" model: no chat, no tool calls, no free text. It answers
//  typed questions (choice, box) about a state. Each step asks which action, which on-screen
//  text (from on-device OCR) or box, which text from the task and which app, then returns a
//  reply shaped like a chat tool call so the agent loop doesn't care which model it talks to.
//  When Jev is unsure, Decide.next hands that step to a chat model (`handoverModel`).
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

    /// Below these, the step goes to the chat model instead (see `handover`).
    static let minActionConfidence = 0.6
    static let minTargetConfidence = 0.5
    /// Chat model that takes over a step Jev is unsure about; same OpenRouter key.
    static let handoverModel = "anthropic/claude-haiku-5.5"

    /// One decision for the current screenshot: an assistant message with one tool call, or
    /// `["handover": reason]` when Jev is unsure and the chat model should take this step.
    /// `screenText` is the on-device OCR of the screenshot (see ScreenText).
    static func decide(task: String, messages: [[String: Any]], image: (data: Data, size: CGSize),
                       screenText: [ScreenText.Item], apps: [String: String], config: LLMConfig) async throws -> [String: Any] {
        let calls = messages.compactMap { ($0["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any] }
        let done = calls.enumerated().map { "\($0.offset + 1). \($0.element["name"] ?? "") \($0.element["arguments"] ?? "")" }
        let state: [Any] = [
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.data.base64EncodedString()]],
            "You operate this iPhone for its owner. The image is the current screen.\nTask: \(task)\n"
                + "Actions taken so far (don't repeat one that changed nothing):\n" + (done.isEmpty ? "none" : done.joined(separator: "\n")),
        ]
        // Text on screen, top to bottom, as the tap/long_press targets Jev picks from.
        let items = Array(screenText.prefix(maxChoices - 1))
        var elements = ["icon": "an element with no text (icon, image, empty field): use the box answer"]
        for (i, item) in items.enumerated() {
            elements["e\(i)"] = String(format: "\"%@\" at %.0f%% across, %.0f%% down", item.text, item.rect.midX * 100, item.rect.midY * 100)
        }
        let typeOptions = typeCandidates(task)
        var questions: [String: Any] = [
            "action": ["type": "choice", "instructions": "Which single next action best moves toward the task?",
                       "criteria": actions],
            "element": ["type": "choice", "instructions": "Which element on the screen should be tapped or held next?",
                        "criteria": elements],
            "target": ["type": "box", "instructions": "The element on the screen to act on next (for tap or long_press)."],
        ]
        if !typeOptions.isEmpty {
            questions["text"] = ["type": "choice", "instructions": "If text is typed next, which text?",
                                 "criteria": Dictionary(uniqueKeysWithValues: typeOptions.enumerated().map { ("t\($0.offset)", $0.element) })]
        }
        // A choice takes at most 255 options: with more apps, pick one only when the action is open_app.
        if apps.count <= maxChoices { questions["app"] = appQuestion(apps) }
        let answers = try await ask(state: state, questions: questions, config: config)
        guard let action = answers["action"]?["choice"] as? String else {
            throw NSError(domain: "jev", code: 0, userInfo: [NSLocalizedDescriptionKey: "No action in Jev's answer."])
        }
        let confidence = sure(answers["action"])
        if confidence < minActionConfidence {
            return ["handover": String(format: "Jev %.0f%% sure of %@", confidence * 100, action)]
        }
        let w = image.size.width, h = image.size.height

        let (name, args): (String, [String: Any])
        var detail = ""
        switch action {
        case "tap", "long_press":
            let element = answers["element"]?["choice"] as? String ?? "icon"
            if let i = Int(element.dropFirst()), element.hasPrefix("e"), i < items.count {
                guard sure(answers["element"]) >= minTargetConfidence else {
                    return ["handover": String(format: "Jev %.0f%% sure of \"%@\"", sure(answers["element"]) * 100, items[i].text)]
                }
                (name, args) = (action, ["x": Int(items[i].rect.midX * w), "y": Int(items[i].rect.midY * h)])
                detail = " \"\(items[i].text)\""
            } else {
                guard let box = answers["target"]?["box"] as? [String: Double], sure(answers["target"]) >= minTargetConfidence else {
                    return ["handover": "Jev unsure where to tap"]
                }
                let x = ((box["left"] ?? 0.5) + (box["right"] ?? 0.5)) / 2 * w
                let y = ((box["top"] ?? 0.5) + (box["bottom"] ?? 0.5)) / 2 * h
                (name, args) = (action, ["x": Int(x), "y": Int(y)])
                detail = " (box)"
            }
        case "scroll_down": (name, args) = ("swipe", ["x1": Int(w / 2), "y1": Int(h * 0.7), "x2": Int(w / 2), "y2": Int(h * 0.3)])
        case "scroll_up": (name, args) = ("swipe", ["x1": Int(w / 2), "y1": Int(h * 0.3), "x2": Int(w / 2), "y2": Int(h * 0.7)])
        case "open_app":
            var app = answers["app"]?["choice"] as? String
            if app == nil { app = try await pickApp(apps, state: state, config: config) }
            (name, args) = ("open_app", ["bundle_id": app ?? ""])
        case "type":
            // Jev only picks text from the task; anything else is the chat model's to write.
            guard let key = answers["text"]?["choice"] as? String, let i = Int(key.dropFirst()), i < typeOptions.count,
                  sure(answers["text"]) >= minTargetConfidence else {
                return ["handover": "text to type isn't in the task"]
            }
            (name, args) = ("type", ["text": typeOptions[i]])
        case "done":
            // The chat model checks the screen and writes the summary.
            return ["handover": "Jev says done"]
        default: (name, args) = ("home", [:])
        }
        // Same call a third time in a row: Jev is stuck.
        let arguments = String(data: try JSONSerialization.data(withJSONObject: args, options: .sortedKeys), encoding: .utf8) ?? "{}"
        if calls.suffix(2).count == 2, calls.suffix(2).allSatisfy({ $0["name"] as? String == name && $0["arguments"] as? String == arguments }) {
            return ["handover": "Jev repeating \(name)"]
        }
        return [
            "role": "assistant",
            "content": String(format: "%@%@ (Jev %.0f%%)", action, detail, confidence * 100),
            "tool_calls": [["id": UUID().uuidString, "type": "function", "function": ["name": name, "arguments": arguments]]],
        ]
    }

    /// Probability of the chosen answer (choice) or its confidence (box).
    private static func sure(_ answer: [String: Any]?) -> Double {
        if let c = answer?["confidence"] as? Double { return c }
        guard let choice = answer?["choice"] as? String else { return 0 }
        return (answer?["probabilities"] as? [String: Double])?[choice] ?? 0
    }

    /// What Jev may type: quoted strings in the task first, then its 1-3 word phrases (at most 200).
    static func typeCandidates(_ task: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !t.isEmpty, !out.contains(t), out.count < 200 { out.append(t) }
        }
        let quoted = try! NSRegularExpression(pattern: "[\"“”«»]([^\"“”«»]+)[\"“”«»]|(?:^|\\s)'([^']+)'")
        for m in quoted.matches(in: task, range: NSRange(task.startIndex..., in: task)) {
            for g in 1...2 { if let r = Range(m.range(at: g), in: task) { add(String(task[r])) } }
        }
        let rest = quoted.stringByReplacingMatches(in: task, range: NSRange(task.startIndex..., in: task), withTemplate: " ")
        let words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        for n in [3, 2, 1] where words.count >= n {
            for i in 0...(words.count - n) { add(words[i..<i + n].joined(separator: " ")) }
        }
        return out
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
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        Decide.spent += (json?["usage"] as? [String: Any])?["cost"] as? Double ?? 0
        guard let answers = json?["answers"] as? [String: [String: Any]] else {
            throw NSError(domain: "jev", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: String((String(data: data, encoding: .utf8) ?? "").prefix(400))])
        }
        return answers
    }
}
