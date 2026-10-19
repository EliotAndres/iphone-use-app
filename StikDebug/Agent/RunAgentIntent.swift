import AppIntents

// Shortcuts / Siri entry point: same as typing the prompt and tapping Run.
// Opens the app because starting a Live Activity and the tunnel need the foreground.
struct RunAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Agent"
    static let description = IntentDescription("Let the agent control this iPhone to do a task.")
    static let openAppWhenRun = true

    @Parameter(title: "Prompt", requestValueDialog: "What should I do?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        await ensureTunnel()
        let model = UserDefaults.standard.string(forKey: "agentModelID") ?? "anthropic/claude-sonnet-5.5"
        PhoneAgent.shared.run(prompt: prompt, model: model)
        return .result()
    }
}
