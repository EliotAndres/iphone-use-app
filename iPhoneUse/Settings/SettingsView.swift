//
//  SettingsView.swift
//  iPhoneUse
//

import SwiftUI

private enum Links {
    static let repo = URL(string: "https://github.com/EliotAndres/iphone-use-app")!
    static let pairingFileGuide = URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!
    static let openRouterKeys = URL(string: "https://openrouter.ai/settings/keys")!
}

struct SettingsView: View {
    @ObservedObject private var llm = LLMSettings.shared
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true

    @State private var hasPairingFile = Connection.shared.hasPairingFile
    @State private var isShowingPairingFilePicker = false
    @State private var pairingMessage: (text: String, isError: Bool)?
    @State private var showDDIConfirmation = false
    @State private var isRedownloadingDDI = false
    @State private var ddiProgress = 0.0
    @State private var ddiMessage: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $llm.provider) {
                        ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
                    }
                    if llm.provider == .custom {
                        TextField("Base URL", text: $llm.customURL, prompt: Text(verbatim: "https://…/v1"))
                            .keyboardType(.URL)
                    }
                    SecureField("API key", text: $llm.apiKey,
                                prompt: Text(llm.provider == .custom ? "API key (optional)" : "API key"))
                    ModelPicker(settings: llm)
                } header: {
                    Text("Model")
                } footer: {
                    if llm.provider == .openRouter {
                        Link("Get an OpenRouter key", destination: Links.openRouterKeys)
                    } else {
                        Text("Any OpenAI-compatible endpoint with vision and tool calls.")
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section("Agent") {
                    Stepper("Max steps: \(llm.maxSteps)", value: $llm.maxSteps, in: 5...200, step: 5)
                    NavigationLink("System Prompt") { SystemPromptEditor(settings: llm) }
                }

                Section {
                    LabeledContent("Pairing file") {
                        Label(hasPairingFile ? "Imported" : "Missing",
                              systemImage: hasPairingFile ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hasPairingFile ? .green : .red)
                    }
                    Button("Import Pairing File") { isShowingPairingFilePicker = true }
                    if let pairingMessage {
                        Text(pairingMessage.text)
                            .font(.caption)
                            .foregroundStyle(pairingMessage.isError ? .red : .secondary)
                    }
                    Button("Redownload Developer Disk Image") { showDDIConfirmation = true }
                        .disabled(isRedownloadingDDI)
                    if isRedownloadingDDI {
                        ProgressView(value: ddiProgress)
                    } else if let ddiMessage {
                        Text(ddiMessage.text)
                            .font(.caption)
                            .foregroundStyle(ddiMessage.isError ? .red : .secondary)
                    }
                    Link("Pairing File Guide", destination: Links.pairingFileGuide)
                } header: {
                    Text("Connection")
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
                                BackgroundLocationManager.shared.requestAuthorizationIfNeeded()
                            } else if !keepAliveAudio {
                                keepAliveAudio = true
                            }
                            keepAliveDidChange()
                        }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Keeps the agent running while it uses other apps.")
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
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes
        ) { result in
            do {
                try PairingFileStore.importFromPicker(result.get())
                hasPairingFile = true
                pairingMessage = ("Imported. Connecting…", false)
                Task { await Connection.shared.connect(force: true) }
            } catch {
                pairingMessage = ("Import failed: \(error.localizedDescription)", true)
            }
        }
        .confirmationDialog("Redownload the developer disk image?", isPresented: $showDDIConfirmation, titleVisibility: .visible) {
            Button("Redownload", role: .destructive) { redownloadDDI() }
        }
    }

    private func keepAliveDidChange() {
        BackgroundAudioManager.shared.configurationDidChange()
        BackgroundLocationManager.shared.configurationDidChange()
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
        ("StikDebug", "This app started as a fork of StikDebug (AGPL-3.0): tunnel, pairing and disk image code.",
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
