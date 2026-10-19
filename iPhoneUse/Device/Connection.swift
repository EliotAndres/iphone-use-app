//
//  Connection.swift
//  iPhoneUse
//
//  Brings up everything the agent needs, in order: loopback VPN -> CoreDevice
//  tunnel -> developer disk image. The VPN ships in TunnelProvider/, or is the
//  LocalDevVPN app (see VPNMode).
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
            var notice = ""
            if VPNMode.current == .builtIn {
                step = .working("Starting VPN…")
                do {
                    try await LoopbackVPN.start()
                } catch let error as NSError where error.domain == NEVPNErrorDomain {
                    // No Network Extension entitlement (BUILTIN_VPN=NO build) or the VPN prompt was refused.
                    VPNMode.current = .localDevVPN
                    notice = "Built-in VPN unavailable (\(error.localizedDescription)), switched to LocalDevVPN.\n"
                }
            }

            step = .working("Connecting to this iPhone…")
            do {
                try await Task.detached(priority: .userInitiated) { try DeviceSession.shared.startTunnel() }.value
            } catch where VPNMode.current == .localDevVPN && (error as NSError).code != -9 {
                throw NSError(domain: "iPhoneUse", code: -21, userInfo: [
                    NSLocalizedDescriptionKey: notice + "Can't reach this iPhone. Install LocalDevVPN from the App Store, turn it on, then Reconnect.",
                ])
            }

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

/// What routes 10.7.0.1 back to this phone: our TunnelProvider/, or the LocalDevVPN app for
/// builds that can't sign the Network Extension entitlement (free Apple ID, `BUILTIN_VPN=NO`).
enum VPNMode: String, CaseIterable {
    case builtIn, localDevVPN

    static let key = "vpnMode"
    static let localDevVPNURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    static var current: VPNMode {
        get { UserDefaults.standard.string(forKey: key).flatMap(VPNMode.init) ?? .builtIn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
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
