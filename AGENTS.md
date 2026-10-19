# iphone-use-app

An iPhone app where an LLM controls the phone it runs on: type a prompt (or run
the "Run Agent" Shortcut) and it loops CoreDevice screenshot -> chat completion tool
call -> CoreDevice tap/swipe/type/open-app until done. No Mac or board at run
time. Background, design notes and gotchas live in Notion: "Controlling iphone".

It reaches its own phone's developer services through a loopback VPN (our `TunnelProvider`
extension, based on LocalDevVPN/StosVPN) + an RP pairing file, using the Rust lib
[idevice](https://github.com/jkcoxson/idevice). Feature scope: `docs/FEATURES.md`.

## Layout

- `iPhoneUse/Agent/`: agent tab (`AgentView`), loop + history (`PhoneAgent`), `LLMSettings` (provider, Keychain key, model), `RunAgentIntent`
- `iPhoneUse/Settings/`: Settings tab, model picker
- `iPhoneUse/Device/`: `Connection` (VPN -> tunnel -> DDI), `DeviceSession` (tunnel, heartbeat), `DeviceSession+Services.swift` (apps, DDI, `agentScreenshot/Touch/Home/Type/Launch`)
- `TunnelProvider/`: loopback packet-tunnel extension
- `AgentWidget/`: Live Activity; `Shared/`: files compiled into both app and widget (`StopAgentIntent` uses `#if WIDGET`)
- `idevice-patch/`: our additions to idevice's FFI (`probe.rs`: screenshot, touch, buttons, keyboard)

## Build

1. `scripts/build-idevice.sh` (once, or after changing `idevice-patch/`): builds `iPhoneUse/idevice/libidevice_ffi.a`, which is gitignored (45 MB).
2. `xcodebuild -project iPhoneUse.xcodeproj -scheme iPhoneUse -destination id=<udid> -allowProvisioningUpdates build`, then `xcrun devicectl device install app`.

On the phone, once: Developer Mode on, import a pairing file
(`idevice-tools rppairing pair <name> <out>` over USB), allow the VPN configuration prompt,
add an API key in Settings. The DDI downloads and mounts on its own.

## Testing without an LLM

`DEV=<udid> scripts/runscript.sh "open com.apple.Preferences; wait 1.5; tap 0.5 0.9; shot a" a`
launches the app with `-agentScript`, waits for "script done" in `Documents/agent.log`, and pulls the screenshots.
`-agentPrompt "..."` as a launch argument starts a real LLM run.

## Decisions

- (2026-10-19) idevice is not vendored: `idevice-patch/` + `scripts/build-idevice.sh` rebuild it from jkcoxson/idevice @ 3854a5d.
- (2026-10-19) Display name is "iphone-use-app". Project/target/module `iPhoneUse`, bundle id `blog.eliot.iphoneuse` (re-import the pairing file after a bundle id change).
- (2026-10-19) Don't describe this repo as a fork of StikDebug; it is credited in the README only.
- (2026-10-19) Two tabs only, Agent + Settings (see `docs/FEATURES.md`). The loopback VPN ships in the app; no LocalDevVPN, no target IP / port settings (peer is always `10.7.0.1`, port via Bonjour).
- (2026-10-19) idevice is built with only the features the app calls, and `ring` instead of `aws-lc` (see `scripts/build-idevice.sh`).
