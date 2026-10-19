# iphone-use-app

An iPhone app where an LLM controls the phone it runs on. Type a prompt (or run the
"Run Agent" Shortcut) and the agent loops: screenshot → model picks a tool call →
tap / swipe / type / open an app, until it is done. No Mac or extra hardware at run time.

It reaches the phone's own developer services (screenshots, touch, keyboard, app launch)
over a CoreDevice tunnel, through a loopback VPN that ships inside the app.

## Requirements

- iOS 17.4+, Developer Mode on, Wi-Fi on
- A paid Apple developer team (the built-in VPN needs the Network Extension entitlement)
- A remote pairing file for the phone, made once over USB:
  `idevice-tools rppairing pair <name> <out>` ([guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md))
- An API key for [OpenRouter](https://openrouter.ai/settings/keys), or any OpenAI-compatible
  endpoint whose model takes images and tool calls

## Build

1. `scripts/build-idevice.sh` (once, or after changing `idevice-patch/`): builds
   `iPhoneUse/idevice/libidevice_ffi.a` (gitignored). Needs rustup with the `aarch64-apple-ios` target.
2. Open `iPhoneUse.xcodeproj`, set your team, run the `iPhoneUse` scheme on the phone.

### Simulator (layout checks only)

The simulator can't reach a device, but it shows the UI. `-demoChat YES` plays a fake run
(placeholder screenshots, a question to answer), Debug builds only.

1. `rustup target add aarch64-apple-ios-sim && scripts/build-idevice.sh sim`: the libs are
   single-arch, so the simulator needs its own, in `iPhoneUse/idevice/sim/`.
2. Build Debug (the scheme defaults to Release, which drops `-demoChat`) against that lib:
   `xcodebuild -project iPhoneUse.xcodeproj -scheme iPhoneUse -configuration Debug -destination id=<sim udid> LIBRARY_SEARCH_PATHS='$(PROJECT_DIR)/iPhoneUse/idevice/sim' build`
3. Install the `.app` from DerivedData and launch it with `-demoChat YES`.

## First run

1. Settings (gear, top right) → Import Pairing File.
2. Allow the "Add VPN Configuration" prompt. The VPN only routes `10.7.0.1` back to the phone.
3. Settings → Model: pick a provider, paste the API key, pick a model.
4. Back in the chat: wait until the "not connected" line above the input disappears (the developer disk image downloads on first run), then type a prompt and send it.

Feature scope: [docs/FEATURES.md](docs/FEATURES.md).

## Credits

- [StikDebug](https://github.com/StephenDev0/StikDebug) by Stephen and contributors: the tunnel, pairing file
  and developer disk image code is based on it.
- [idevice](https://github.com/jkcoxson/idevice) by jkcoxson: the Rust library behind every device call.
- [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) / StosVPN by the SideStore Team and Stossy11:
  the loopback VPN (`TunnelProvider/`) is based on StosVPN.
- [esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent) by Henry Yuan: the model provider
  and model picker design.
- [DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) by doronz88: developer disk images.

## License

AGPL-3.0. See [`LICENSE`](LICENSE).
