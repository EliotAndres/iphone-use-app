# TODO

## Strip the app down to the agent

The app is a StikDebug fork. Keep what the agent needs, delete the rest.

Keep:
- Tunnel + pairing: `Services/TunnelManager.swift`, `Support/PairingFileStore.swift`, `Device/JITEnableContext.swift`, `Device/IdeviceFFIBridge.swift`, `Device/DeviceConnectionContext.swift`
- Developer disk image mount: `Device/mountDDI.swift`, `Device/MountingProgress.swift`, `Services/DeveloperDiskImageService.swift`
- Background keep-alive: `Services/BackgroundAudioManager.swift` (check whether `BackgroundLocationManager` is still needed)
- `Agent/`, `AgentWidget/`, a minimal Settings screen (pairing file import, model picker)

Remove:
- [ ] JIT enabling and its intents (`EnableJITIntent`, `KillProcessIntent`, `DebugKeepAliveLease`)
- [ ] JS scripts and the script editor (`JSSupport/`, `Scripts/`, `ScriptStore`, `AutoScriptAssignments`, the CodeEditorView package)
- [ ] Tools tab: console, process inspector, profiles, location simulation, device info, system log stream
- [ ] Installed apps list / App Store icon fetcher (the agent gets app names from `getAllApps()`)
- [ ] Home tab, `stikdebug://` / `stikjit://` URL schemes, Bonjour services, `.stiktool` document type
- [ ] Build idevice with only the features the agent needs. Measured: `--no-default-features --features
      "ring,obfuscate,core_device,tunnel_tcp_stack,tcp,installation_proxy,mobile_image_mounter,tss,heartbeat"`
      gives a 45 MB .a (vs 74 MB) and 4.9 MB of machine code (vs 8.2 MB). Only possible once the Swift code
      that calls the other features (JIT, debug proxy, syslog, location, profiles...) is deleted.
      `ring` instead of `aws-lc` needs checking that pairing/TLS still work.
- [ ] Rename the Xcode project/target/module from StikDebug, and pick a new bundle id
      (the current one, `blog.eliot.stikdebug`, holds the imported pairing file: re-import after the change)

## Ship our own loopback VPN

Users currently have to install LocalDevVPN from the App Store and switch it on.

1. [ ] 10-min test first: Settings > Target IP = `127.0.0.1`, LocalDevVPN off, connect. The tunnel's only
       kernel socket is the RPPairing connection to `<ip>:49152` (`tunnel_create_rppairing`); everything
       else runs in idevice's userspace TCP stack inside it. If remotepairingd accepts a loopback peer, no VPN
       is needed at all. Expected to fail (daemons treat loopback peers differently), but it's free.
2. [ ] Otherwise add a packet-tunnel Network Extension (`blog.eliot.stikdebug.TunnelProv`), ~0.5-1 day:
   - Provider, ~30 lines, from jkcoxson/LocalDevVPN `TunnelProv/PacketTunnelProvider.swift` (after PR #23):
     interface `10.7.1.1/32`, included route `10.7.0.1/32`, `excludedRoutes = [.default()]`; loop
     `packetFlow.readPackets` -> swap IPv4 src/dst (bytes 12-15 <-> 16-19; checksums stay valid) ->
     `writePackets`. The kernel then delivers the packet to the phone's own daemons as if from a peer.
   - Entitlement `com.apple.developer.networking.networkextension = [packet-tunnel-provider]` on app and
     extension. Paid team only; automatic signing should provision it (untested on RK6WTG7E65).
   - App side, ~40 lines in `TunnelManager`: `NETunnelProviderManager.loadAllFromPreferences`, create if
     missing, `saveToPreferences` (one-time "Add VPN Configuration" prompt), `startVPNTunnel`, wait for
     `.connected`, then the existing RPPairing connect. On-demand rule for `10.7.0.1` so it auto-starts.
   - License: StosVPN license (MIT + attribution "based on StosVPN"). Credit it in the app.
   - Upstream StikDebug shipped this until Dec 2025 (`TunnelProv/`, removed in 6a6411a1) because
     free-account sideloaders can't get the entitlement.
   - Risks: takes the single enterprise-VPN slot (stops Tailscale etc. while on). Maintainers report the
     loopback VPN does NOT work on cellular-only on iOS 26.6/27 (LocalDevVPN issue #31): needs Wi-Fi on
     (joined to a network?) -- verify. Apple tightened this path in 26.4 and may again.

## Other

- [ ] Full LLM run on the 16 Pro (iOS 27); Gemini 3.5 Flash Lite quality
- [ ] Log when `Activity.request` fails (it's silent today)
- [ ] Reboot test and 30 min soak (Notion plan T7/T8)
