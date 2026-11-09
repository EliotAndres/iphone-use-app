//
//  Eval.swift
//  Offline eval: runs Decide.next (the app's own step) on evals/cases/*, one decision per case,
//  and scores it against the case's acceptable actions. Built and run by scripts/eval.sh.
//

import Foundation

struct Case: Decodable {
    struct Action: Decodable {
        var name: String
        var args: [String: JSONValue]?
        var thought: String?
    }
    struct Expected: Decodable {
        var action: String // tap, long_press, open_app, type, scroll, home, done, ask_user_question
        var rects: [[Double]]? // tap / long_press: [x0, y0, x1, y1], normalized, any one
        var bundle_id: String?
        var text: String? // type: must contain, case-insensitive
        var direction: String? // scroll: down (finger moves up) or up
    }
    var task: String
    var history: [Action]?
    var apps: [String: String]?
    var expected: [Expected]
}

/// Just enough JSON to round-trip tool arguments.
enum JSONValue: Decodable {
    case number(Double), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .string(try c.decode(String.self)) }
    }
    var any: Any { switch self { case .number(let d): d; case .string(let s): s } }
}

struct Row {
    var model, name, got, why: String
    var pass, fast: Bool
    var seconds, cost: Double
}

@main
enum Eval {
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        // "<model>+fast" asks for the fast service tier, "+nothink" turns reasoning off (LLMConfig).
        let models = args.isEmpty ? LLMSettings.quickModels.map(\.id) : Array(args)
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else {
            fatalError("Set OPENROUTER_API_KEY (scripts/eval.sh reads it from ~/.credentials).")
        }
        let root = URL(fileURLWithPath: "evals")
        let defaultApps = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appending(path: "apps.json")))
        let only = ProcessInfo.processInfo.environment["CASES"].map { $0.split(separator: ",").map(String.init) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "cases").path)
            .filter { only?.contains($0) ?? !$0.hasPrefix(".") }.sorted()

        var rows: [Row] = []
        for model in models {
            let config = LLMConfig(chatURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, apiKey: key,
                                   model: String(model.split(separator: "+")[0]), maxSteps: 1,
                                   systemPrompt: LLMSettings.defaultSystemPrompt, fastTier: model.contains("+fast"),
                                   noReasoning: model.contains("+nothink"))
            for name in names {
                let dir = root.appending(path: "cases/\(name)")
                let c = try JSONDecoder().decode(Case.self, from: Data(contentsOf: dir.appending(path: "case.json")))
                let shot = try ["png", "jpg"].map { dir.appending(path: "screenshot.\($0)") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }.map { try Data(contentsOf: $0) }
                guard let shot else { print("skip \(name): no screenshot"); continue }
                let row = await run(c, name: name, screenshot: shot, apps: c.apps ?? defaultApps, config: config)
                print(String(format: "%@ %@ %@ %5.1fs $%.4f %@ %@  %@", row.pass ? "PASS" : "FAIL",
                             name.padding(toLength: 28, withPad: " ", startingAt: 0), short(model).padding(toLength: 22, withPad: " ", startingAt: 0),
                             row.seconds, row.cost, row.fast ? "fast" : "    ", row.got, row.why))
                rows.append(Row(model: model, name: row.name, got: row.got, why: row.why, pass: row.pass, fast: row.fast,
                                seconds: row.seconds, cost: row.cost))
            }
        }
        report(rows, models: models)
    }

    static func run(_ c: Case, name: String, screenshot: Data, apps: [String: String], config: LLMConfig) async -> Row {
        var messages = Decide.firstMessages(task: c.task, config: config)
        // Prior steps as the app would have them, minus their screenshots.
        for (i, action) in (c.history ?? []).enumerated() {
            let arguments = try! JSONSerialization.data(withJSONObject: (action.args ?? [:]).mapValues(\.any), options: .sortedKeys)
            messages.append(["role": "user", "content": "Step \(i + 1). (screenshot not kept)"])
            messages.append(["role": "assistant", "content": action.thought ?? "", "tool_calls": [[
                "id": "h\(i)", "type": "function",
                "function": ["name": action.name, "arguments": String(decoding: arguments, as: UTF8.self)],
            ]]])
            messages.append(["role": "tool", "tool_call_id": "h\(i)", "content": "ok"])
        }
        let spent = Decide.spent
        let t0 = Date()
        var row = Row(model: config.model, name: name, got: "", why: "", pass: false, fast: false, seconds: 0, cost: 0)
        do {
            let d = try await Decide.next(task: c.task, messages: &messages, screenshot: screenshot,
                                          step: (c.history?.count ?? 0) + 1, config: config)
            row.seconds = Date().timeIntervalSince(t0)
            row.fast = d.tier == "fast"
            let function = (d.reply["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any]
            let tool = function?["name"] as? String ?? "(no tool call)"
            let args = (function?["arguments"] as? String)
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            row.got = tool + " " + args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            (row.pass, row.why) = score(tool, args, size: d.image.size, apps: apps, expected: c.expected)
        } catch {
            row.seconds = Date().timeIntervalSince(t0)
            row.got = "error"
            row.why = error.localizedDescription
        }
        row.cost = Decide.spent - spent
        return row
    }

    /// Passes if the call matches any one expected action.
    static func score(_ tool: String, _ args: [String: Any], size: CGSize, apps: [String: String],
                      expected: [Case.Expected]) -> (Bool, String) {
        func num(_ k: String) -> Double { (args[k] as? NSNumber)?.doubleValue ?? Double(args[k] as? String ?? "") ?? -1 }
        var why = "wanted " + expected.map(\.action).joined(separator: "|")
        for e in expected {
            switch (e.action, tool) {
            case ("tap", "tap"), ("long_press", "long_press"):
                let x = num("x") / size.width, y = num("y") / size.height
                if (e.rects ?? []).contains(where: { x >= $0[0] && y >= $0[1] && x <= $0[2] && y <= $0[3] }) { return (true, "") }
                why = String(format: "%@ at (%.2f, %.2f) outside rects", tool, x, y)
            case ("open_app", "open_app"):
                if Decide.appBundleID(args["name"] as? String ?? "", in: apps) == e.bundle_id { return (true, "") }
                why = "wrong app"
            case ("type", "type"):
                let text = (args["text"] as? String ?? "").lowercased()
                if text.contains((e.text ?? "").lowercased()) { return (true, "") }
                why = "wrong text"
            case ("scroll", "swipe"):
                let down = num("y2") < num("y1")
                if (e.direction == "up") != down { return (true, "") }
                why = "scrolled the wrong way"
            case ("home", "home"), ("done", "done"), ("ask_user_question", "ask_user_question"):
                return (true, "")
            default: continue
            }
        }
        return (false, why)
    }

    static func short(_ model: String) -> String {
        return String(model.split(separator: "/").last ?? "")
    }

    /// Markdown summary on stdout, every row in .build/evals/results.csv.
    static func report(_ rows: [Row], models: [String]) {
        func pct(_ xs: [Double], _ p: Double) -> Double {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
        }
        print("\n| model | cases | accuracy | median s | p90 s | $/decision | served fast | errors |")
        print("|---|---|---|---|---|---|---|---|")
        for model in models.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } {
            let r = rows.filter { $0.model == model }
            guard !r.isEmpty else { continue }
            let n = Double(r.count)
            print(String(format: "| %@ | %d | %.0f%% | %.1f | %.1f | %.4f | %.0f%% | %d |", model, r.count,
                         Double(r.filter(\.pass).count) / n * 100,
                         pct(r.map(\.seconds), 0.5), pct(r.map(\.seconds), 0.9), r.map(\.cost).reduce(0, +) / n,
                         Double(r.filter(\.fast).count) / n * 100, r.filter { $0.got == "error" }.count))
        }
        print(String(format: "\nTotal spent: $%.4f", Decide.spent))
        func field(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = ["model,case,pass,fast,seconds,cost,got,why"] + rows.map {
            [field($0.model), $0.name, "\($0.pass)", "\($0.fast)",
             String(format: "%.2f", $0.seconds), String(format: "%.5f", $0.cost), field($0.got), field($0.why)].joined(separator: ",")
        }
        let out = URL(fileURLWithPath: ".build/evals/results.csv")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? csv.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("Rows: \(out.path)")
    }
}
