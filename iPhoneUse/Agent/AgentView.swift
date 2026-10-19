//
//  AgentView.swift
//  iPhoneUse
//

import SwiftUI

struct AgentView: View {
    @ObservedObject private var agent = PhoneAgent.shared
    @ObservedObject private var connection = Connection.shared
    @State private var prompt = ""
    @State private var showingHistory = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                ConnectionStatus(connection: connection)
                TextField("What should I do?", text: $prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                if agent.isRunning {
                    Button("Stop", role: .destructive) { agent.stop() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Run") { agent.run(prompt: prompt) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(agent.log)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: agent.log) { proxy.scrollTo("end") }
                }
            }
            .padding()
            .navigationTitle("Agent")
            .toolbar {
                Button("History", systemImage: "clock.arrow.circlepath") { showingHistory = true }
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView(agent: agent) { prompt = $0 }
            }
        }
        .task {
            await connection.connect()
            // Test hooks: `devicectl device process launch ... -agentScript "..."` (no LLM, see
            // scripts/runscript.sh) or `-agentPrompt "..."` (real run).
            let launchArgs = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            guard !agent.isRunning, agent.log.isEmpty else { return }
            if let script = launchArgs["agentScript"] as? String {
                agent.runScript(script)
            } else if let auto = launchArgs["agentPrompt"] as? String, !auto.isEmpty {
                prompt = auto
                agent.run(prompt: auto)
            }
        }
    }
}

private struct ConnectionStatus: View {
    @ObservedObject var connection: Connection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch connection.step {
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Not connected").foregroundStyle(.secondary)
            case .working(let message):
                ProgressView().controlSize(.mini)
                Text(message).foregroundStyle(.secondary)
            case .ready:
                Image(systemName: "circle.fill").foregroundStyle(.green)
                Text("Connected to this iPhone")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
            }
            Spacer()
            if showsConnect {
                Button("Connect") { Task { await connection.connect(force: true) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.footnote)
    }

    private var showsConnect: Bool {
        switch connection.step {
        case .idle, .failed: true
        case .working, .ready: false
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var agent: PhoneAgent
    let reuse: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(agent.history) { run in
                NavigationLink {
                    ScrollView {
                        Text(run.log)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle(run.date.formatted(date: .abbreviated, time: .shortened))
                    .toolbar {
                        Button("Use Prompt") {
                            reuse(run.prompt)
                            dismiss()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.prompt).lineLimit(2)
                        Text(run.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("\(run.date.formatted(date: .abbreviated, time: .shortened)) · \(run.model)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .overlay {
                if agent.history.isEmpty {
                    ContentUnavailableView("No runs yet", systemImage: "clock")
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) { agent.clearHistory() }
                        .disabled(agent.history.isEmpty)
                }
            }
        }
    }
}
