//
//  SettingsView.swift
//  iPhoneUse
//
//  A setup checklist first (what the agent needs to run), then agent options.
//  Each checklist row opens the screen that fixes it.
//

import CoreLocation
import SwiftUI

private enum Links {
    static let repo = URL(string: "https://github.com/EliotAndres/iphone-use-app")!
    static let pairingFileGuide = URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!
    static let openRouterKeys = URL(string: "https://openrouter.ai/settings/keys")!
}

struct SettingsView: View {
    @ObservedObject private var llm = LLMSettings.shared
    @ObservedObject private var connection = Connection.shared
    @ObservedObject private var location = BackgroundLocationManager.shared
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasPairingFile = Connection.shared.hasPairingFile
    @State private var isShowingPairingFilePicker = false
    @State private var pairingMessage: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { LLMSettingsView(settings: llm) } label: {
                        CheckRow("Model API Key", detail: llm.problem ?? "\(llm.provider.title) · \(llm.model)",
                                 state: llm.problem == nil ? .done : .error)
                    }
                    Button { isShowingPairingFilePicker = true } label: {
                        CheckRow("Pairing file", detail: hasPairingFile ? "Imported. Tap to replace." : "Tap to import.",
                                 state: hasPairingFile ? .done : .error)
                    }
                    .buttonStyle(.plain)
                    if let pairingMessage {
                        Text(pairingMessage.text)
                            .font(.caption)
                            .foregroundStyle(pairingMessage.isError ? .red : .secondary)
                    }
                    NavigationLink { ConnectionSettingsView(connection: connection) } label: {
                        CheckRow("Phone connection", detail: connection.step.summary, state: connection.step.checkState)
                    }
                    NavigationLink { BackgroundSettingsView(location: location) } label: {
                        CheckRow("Run in background", detail: backgroundDetail, state: backgroundState)
                    }
                } header: {
                    Text("Setup")
                } footer: {
                    Link("How to get a pairing file", destination: Links.pairingFileGuide)
                }

                Section {
                    Picker("Model", selection: $llm.voiceModel) {
                        ForEach(Set(LLMSettings.voiceModels + [llm.voiceModel]).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Language", selection: $llm.voiceLanguage) {
                        Text("Auto-detect").tag("")
                        ForEach(LLMSettings.voiceLanguages, id: \.self) {
                            Text(Locale.current.localizedString(forLanguageCode: $0) ?? $0).tag($0)
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(llm.provider == .openRouter
                         ? "Transcribed by OpenRouter with your API key. Setting the language is faster and more accurate than auto-detect."
                         : "Voice input only works with the OpenRouter provider.")
                }
                .disabled(llm.provider != .openRouter)

                Section("Agent") {
                    Stepper("Max steps: \(llm.maxSteps)", value: $llm.maxSteps, in: 5...200, step: 5)
                    NavigationLink("System Prompt") { SystemPromptEditor(settings: llm) }
                    NavigationLink("Shortcuts & Deep Link") { ShortcutsGuideView() }
                }

                Section("About") {
                    Link("GitHub", destination: Links.repo)
                    NavigationLink("Credits") { CreditsView() }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .scrollDismissesKeyboard(.interactively)
        }
        .task { await connection.connect() } // no-op when connected; retries after a failure
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { hasPairingFile = connection.hasPairingFile }
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes
        ) { result in
            do {
                try PairingFileStore.importFromPicker(result.get())
                hasPairingFile = true
                pairingMessage = ("Imported. Connecting…", false)
                Task { await connection.connect(force: true) }
            } catch {
                pairingMessage = ("Import failed: \(error.localizedDescription)", true)
            }
        }
    }

    // Amber, not red: silent audio still keeps most runs alive.
    private var backgroundState: CheckState {
        if !keepAliveLocation && location.authorization != .denied { return .done } // audio only, chosen
        return location.authorization == .authorizedAlways ? .done : .warning
    }

    private var backgroundDetail: String {
        if !keepAliveLocation && location.authorization != .denied { return "Silent audio" }
        switch location.authorization {
        case .authorizedAlways: return "Silent audio + location"
        case .notDetermined: return "Allow location access for reliability"
        case .authorizedWhenInUse: return "Set location access to Always"
        default: return "Location refused: silent audio only"
        }
    }
}

enum CheckState { case done, warning, error, working }

private struct CheckRow: View {
    let title: String
    let detail: String
    let state: CheckState

    init(_ title: String, detail: String, state: CheckState) {
        self.title = title
        self.detail = detail
        self.state = state
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warning: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .working: ProgressView()
                }
            }
            .font(.title3)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private extension Connection.Step {
    var summary: String {
        switch self {
        case .idle: "Not connected"
        case .working(let message): message
        case .ready: "Connected to this iPhone"
        case .failed(let message): message
        }
    }

    var checkState: CheckState {
        switch self {
        case .idle: .warning
        case .working: .working
        case .ready: .done
        case .failed: .error
        }
    }
}

private struct LLMSettingsView: View {
    @ObservedObject var settings: LLMSettings
    @State private var isTesting = false
    @State private var testMessage: (text: String, isError: Bool)?

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
                }
                if settings.provider == .custom {
                    TextField("Base URL", text: $settings.customURL, prompt: Text(verbatim: "https://…/v1"))
                        .keyboardType(.URL)
                }
                SecureField("API key", text: $settings.apiKey,
                            prompt: Text(settings.provider == .custom ? "API key (optional)" : "API key"))
                ModelPicker(settings: settings)
            } footer: {
                if settings.provider == .openRouter {
                    Link("Get an OpenRouter key", destination: Links.openRouterKeys)
                } else {
                    Text("Any OpenAI-compatible endpoint with vision and tool calls. Voice input won't work: it needs OpenRouter.")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Section {
                Button(settings.provider == .openRouter ? "Test OpenRouter Connection" : "Test Connection") {
                    isTesting = true
                    testMessage = nil
                    Task {
                        testMessage = await settings.testConnection()
                        isTesting = false
                    }
                }
                .disabled(isTesting)
                if isTesting {
                    ProgressView()
                } else if let testMessage {
                    Text(testMessage.text)
                        .font(.caption)
                        .foregroundStyle(testMessage.isError ? .red : .green)
                }
            }
        }
        .navigationTitle("Model API Key")
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var connection: Connection
    @State private var showDDIConfirmation = false
    @State private var isRedownloadingDDI = false
    @State private var ddiProgress = 0.0
    @State private var ddiMessage: (text: String, isError: Bool)?

    var body: some View {
        Form {
            Section {
                CheckRow("Status", detail: connection.step.summary, state: connection.step.checkState)
                Button("Reconnect") { Task { await connection.connect(force: true) } }
                    .disabled(connection.step.checkState == .working || !connection.hasPairingFile)
            } footer: {
                Text("Starts the built-in VPN, connects to this iPhone's developer services and mounts the developer disk image.")
            }
            Section {
                Button("Redownload Developer Disk Image") { showDDIConfirmation = true }
                    .disabled(isRedownloadingDDI)
                if isRedownloadingDDI {
                    ProgressView(value: ddiProgress)
                } else if let ddiMessage {
                    Text(ddiMessage.text)
                        .font(.caption)
                        .foregroundStyle(ddiMessage.isError ? .red : .secondary)
                }
            } footer: {
                Text("Only if mounting keeps failing, e.g. after an iOS update.")
            }
        }
        .navigationTitle("Phone Connection")
        .confirmationDialog("Redownload the developer disk image?", isPresented: $showDDIConfirmation, titleVisibility: .visible) {
            Button("Redownload", role: .destructive) { redownloadDDI() }
        }
    }

    private func redownloadDDI() {
        isRedownloadingDDI = true
        ddiMessage = nil
        Task {
            do {
                try await DeveloperDiskImageService.shared.redownload { progress, _ in
                    Task { @MainActor in ddiProgress = progress }
                }
                ddiMessage = ("Developer disk image downloaded.", false)
            } catch {
                ddiMessage = ("Download failed: \(error.localizedDescription)", true)
            }
            isRedownloadingDDI = false
        }
    }
}

private struct BackgroundSettingsView: View {
    @ObservedObject var location: BackgroundLocationManager
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Location access", value: authorizationText)
                if location.authorization == .notDetermined {
                    Button("Allow Location Access") { location.requestAuthorizationIfNeeded() }
                } else if location.authorization != .authorizedAlways {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } footer: {
                Text("Background location only keeps the agent alive with \"Always\" access.")
            }
            Section {
                Toggle("Silent Audio", isOn: $keepAliveAudio)
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if !enabled, !keepAliveLocation { keepAliveLocation = true }
                        keepAliveDidChange()
                    }
                Toggle("Background Location", isOn: $keepAliveLocation)
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if enabled {
                            location.requestAuthorizationIfNeeded()
                        } else if !keepAliveAudio {
                            keepAliveAudio = true
                        }
                        keepAliveDidChange()
                    }
            } footer: {
                Text("Keeps the agent running while it uses other apps. At least one stays on.")
            }
        }
        .navigationTitle("Run in Background")
    }

    private var authorizationText: String {
        switch location.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While Using"
        case .notDetermined: "Not asked"
        default: "Refused"
        }
    }

    private func keepAliveDidChange() {
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
    }
}

private struct SystemPromptEditor: View {
    @ObservedObject var settings: LLMSettings

    var body: some View {
        TextEditor(text: $settings.systemPrompt)
            .font(.callout)
            .padding(.horizontal)
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Reset") { settings.systemPrompt = LLMSettings.defaultSystemPrompt }
                    .disabled(settings.systemPrompt == LLMSettings.defaultSystemPrompt)
            }
    }
}

private struct CreditsView: View {
    private let credits: [(name: String, detail: String, url: String)] = [
        ("StikDebug", "The tunnel, pairing file and developer disk image code is based on StikDebug by Stephen and contributors.",
         "https://github.com/StephenDev0/StikDebug"),
        ("idevice", "Rust library that talks to the iPhone's developer services.",
         "https://github.com/jkcoxson/idevice"),
        ("LocalDevVPN / StosVPN", "The loopback VPN is based on StosVPN by the SideStore Team, via LocalDevVPN.",
         "https://github.com/jkcoxson/LocalDevVPN"),
        ("esp32-iphone-agent", "Model provider and model picker design.",
         "https://github.com/onehumanbeing/esp32-iphone-agent"),
        ("DeveloperDiskImage", "Developer disk images downloaded at first launch.",
         "https://github.com/doronz88/DeveloperDiskImage"),
    ]

    var body: some View {
        List(credits, id: \.name) { credit in
            Link(destination: URL(string: credit.url)!) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credit.name).foregroundStyle(.primary)
                    Text(credit.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Credits")
    }
}
