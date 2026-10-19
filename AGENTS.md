# iphone-use-app

An iPhone app where an LLM controls the phone it runs on: type a prompt (or run
the "Run Agent" Shortcut) and it loops CoreDevice screenshot -> OpenRouter tool
call -> CoreDevice tap/swipe/type/open-app until done. No Mac or board at run
time. Background, design notes and gotchas live in Notion: "Controlling iphone".

Fork of [StikDebug](https://github.com/StephenDev0/StikDebug) (remote `upstream`),
which reaches its own phone's developer services through a loopback VPN
(LocalDevVPN) + an RP pairing file, using the Rust lib
[idevice](https://github.com/jkcoxson/idevice).

## Layout

- `StikDebug/Agent/`: agent tab (`AgentView.swift`, `PhoneAgent`), `RunAgentIntent`
- `AgentWidget/`: Live Activity (widget extension; `AgentActivityAttributes.swift` is shared with the app)
- `StikDebug/Device/IdeviceFFIBridge.swift`: `agentScreenshot/Touch/Home/Type/Launch`
- `idevice-patch/`: our additions to idevice's FFI (`probe.rs`: screenshot, touch, buttons, keyboard)

## Build

1. `scripts/build-idevice.sh` (once, or after changing `idevice-patch/`): builds `StikDebug/idevice/libidevice_ffi.a`, which is gitignored (204 MB).
2. Put an OpenRouter key in `StikDebug/Agent/openrouter.txt` (gitignored, bundled into the app).
3. `xcodebuild -project StikDebug.xcodeproj -scheme StikDebug -destination id=<udid> -allowProvisioningUpdates build`, then `xcrun devicectl device install app`.

On the phone, once: Developer Mode on, LocalDevVPN on, import a pairing file
(`idevice-tools rppairing pair <name> <out>` over USB), mount the developer disk image.

## Testing without an LLM

`DEV=<udid> scripts/runscript.sh "open com.apple.Preferences; wait 1.5; tap 0.5 0.9; shot a" a`
launches the app with `-agentScript`, waits for "script done" in `Documents/agent.log`, and pulls the screenshots.
`-agentPrompt "..."` as a launch argument starts a real LLM run.

## Decisions

- (2026-10-19) Repo started from the StikDebug fork with its history; `upstream` = StephenDev0/StikDebug. idevice is not vendored: `idevice-patch/` + `scripts/build-idevice.sh` rebuild it from jkcoxson/idevice @ 3854a5d.
- (2026-10-19) Display name is "iphone-use-app"; bundle id stays `blog.eliot.stikdebug` for now so installed phones keep their pairing file.
