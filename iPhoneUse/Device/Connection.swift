//
//  Connection.swift
//  iPhoneUse
//
//  Brings up everything the agent needs, in order: loopback VPN -> CoreDevice
//  tunnel -> developer disk image. The VPN ships in TunnelProvider/, or is the
//  LocalDevVPN app (see VPNMode).
//

import Foundation
import Network
import NetworkExtension
import UIKit

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
    /// The last attempt failed because iOS refuses new connections to the VPN peer while
    /// cellular data is on and no Wi-Fi network is joined (LocalDevVPN issue #31).
    @Published private(set) var blockedByCellular = false
    /// Set by the sheet's "Connect with Shortcut": run CellularShortcut around new tunnels.
    @Published var usesCellularShortcut = UserDefaults.standard.bool(forKey: "usesCellularShortcut") {
        didSet { UserDefaults.standard.set(usesCellularShortcut, forKey: "usesCellularShortcut") }
    }
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
        blockedByCellular = false
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
            // Keep a tunnel that still answers: on cellular only, iOS refuses new
            // connections to the VPN peer but leaves established ones alone.
            let alive = await Task.detached(priority: .userInitiated) {
                let device = DeviceSession.shared
                return device.adapterHandle != nil && (try? device.isDeveloperDiskImageMounted()) != nil
            }.value
            if !alive {
                let cellularOnly = await CellularShortcut.isCellularOnly()
                if cellularOnly {
                    guard usesCellularShortcut else {
                        step = .failed("On cellular data: turn it off to connect, or join Wi-Fi.")
                        blockedByCellular = true
                        return
                    }
                    step = .working("Turning cellular data off…")
                    guard await CellularShortcut.turnOff() else {
                        step = .failed("Cellular data is still on. Is the shortcut installed?")
                        blockedByCellular = true
                        return
                    }
                    step = .working("Connecting to this iPhone…")
                }
                defer { if cellularOnly { CellularShortcut.turnOn() } }
                do {
                    try await Task.detached(priority: .userInitiated) { try DeviceSession.shared.startTunnel() }.value
                } catch where VPNMode.current == .localDevVPN && (error as NSError).code != -9 {
                    throw NSError(domain: "iPhoneUse", code: -21, userInfo: [
                        NSLocalizedDescriptionKey: notice + "Can't reach this iPhone. Install LocalDevVPN from the App Store, turn it on, then Reconnect.",
                    ])
                }
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

/// Runs the "iPhone Use Cellular" shortcut, which sets Cellular Data to its input ("on",
/// anything else = off), the way SideStore's Cellular Refresh does. x-success brings the app back.
enum CellularShortcut {
    static let name = "iPhone Use Cellular"
    static let installURL = URL(string: "https://www.icloud.com/shortcuts/26b48e4bbcc34caea4b4e64c8759ab35")!

    /// True when traffic goes over cellular data with no Wi-Fi network joined.
    static func isCellularOnly() async -> Bool {
        let path = await currentPath()
        return path.status == .satisfied && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
    }

    /// Runs the shortcut with "off", then waits up to 20 s for cellular data to go away.
    @MainActor
    static func turnOff() async -> Bool {
        run("off")
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if !(await isCellularOnly()) {
                try? await Task.sleep(for: .seconds(1)) // ponytail: fixed settle time, as SideStore does
                return true
            }
        }
        return false
    }

    @MainActor
    static func turnOn() { run("on") }

    @MainActor
    private static func run(_ input: String) {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: input),
            URLQueryItem(name: "x-success", value: "iphoneuse://"),
            URLQueryItem(name: "x-error", value: "iphoneuse://"),
        ]
        UIApplication.shared.open(components.url!)
    }

    private static func currentPath() async -> Network.NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: .global(qos: .userInitiated))
        }
    }
}
