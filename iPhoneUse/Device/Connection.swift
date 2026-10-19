//
//  Connection.swift
//  iPhoneUse
//
//  Brings up everything the agent needs, in order: loopback VPN -> CoreDevice
//  tunnel -> developer disk image. Replaces StikDebug's TunnelManager and
//  MountingProgress, and LocalDevVPN (the VPN now ships in TunnelProvider/).
//

import Foundation
import NetworkExtension

@MainActor
final class Connection: ObservableObject {
    static let shared = Connection()

    enum Step: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    private var connecting: Task<Void, Never>?

    var isReady: Bool { step == .ready }
    var hasPairingFile: Bool { FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) }

    /// Connects if needed; concurrent callers share one attempt.
    func connect(force: Bool = false) async {
        if isReady && !force { return }
        if let connecting { return await connecting.value }
        let task = Task { await run() }
        connecting = task
        await task.value
        connecting = nil
    }

    private func run() async {
        guard hasPairingFile else {
            step = .failed("Import a pairing file in Settings.")
            return
        }
        do {
            step = .working("Starting VPN…")
            try await LoopbackVPN.start()

            step = .working("Connecting to this iPhone…")
            try await Task.detached(priority: .userInitiated) { try DeviceSession.shared.startTunnel() }.value

            if !DeveloperDiskImageService.filesAreReady {
                step = .working("Downloading developer disk image…")
                try await DeveloperDiskImageService.shared.downloadMissingFiles()
            }
            step = .working("Mounting developer disk image…")
            try await Task.detached(priority: .userInitiated) { try Self.mountDDIIfNeeded() }.value

            step = .ready
        } catch {
            let nsError = error as NSError
            let message = nsError.code == -9
                ? "The pairing file is invalid or expired. Import a new one in Settings."
                : "\(error.localizedDescription)\nTarget: \(RemotePairingPortResolver.lastAttemptDescription)"
            appLog.error("Connection failed: \(message, privacy: .public)")
            step = .failed(message)
        }
    }

    nonisolated private static func mountDDIIfNeeded() throws {
        let device = DeviceSession.shared
        if try device.isDeveloperDiskImageMounted() { return }
        let directory = DeveloperDiskImageService.directoryURL
        if DeveloperDiskImageService.usesCryptexDDI {
            try device.installCryptexDDI(from: directory.path)
        } else {
            try device.mountPersonalDDI(
                withImagePath: directory.appendingPathComponent("Image.dmg").path,
                trustcachePath: directory.appendingPathComponent("Image.dmg.trustcache").path,
                manifestPath: directory.appendingPathComponent("BuildManifest.plist").path
            )
        }
    }
}

/// Configures and starts the packet tunnel in TunnelProvider/. The first start
/// shows iOS's one-time "Add VPN Configuration" prompt.
enum LoopbackVPN {
    private static let providerID = "blog.eliot.iphoneuse.TunnelProvider"

    static func start() async throws {
        let manager = try await loadManager()
        let connection = manager.connection
        if connection.status == .connected { return }
        try connection.startVPNTunnel()
        for _ in 0..<50 {
            if connection.status == .connected { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(domain: "iPhoneUse", code: -20, userInfo: [
            NSLocalizedDescriptionKey: "The loopback VPN did not connect (status \(connection.status.rawValue)). Is Wi-Fi on?",
        ])
    }

    private static func loadManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        } ?? NETunnelProviderManager()
        if manager.protocolConfiguration == nil || !manager.isEnabled {
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerID
            proto.serverAddress = "This iPhone"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "iphone-use-app"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        return manager
    }
}
