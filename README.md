# iphone-use-app

An iPhone app where an LLM controls the phone it runs on. Type a prompt (or run the
"Run Agent" Shortcut) and the agent loops: screenshot → model picks a tool call →
tap / swipe / type / open an app, until it is done. No Mac or extra hardware at run time.

It reaches the phone's own developer services (screenshots, touch, keyboard, app launch)
over a CoreDevice tunnel, through a loopback VPN that ships inside the app.

## Requirements

- iOS 17.4+, Developer Mode on, Wi-Fi on
- A paid Apple developer team (the built-in VPN needs the Network Extension entitlement)
- A remote pairing file for the phone (see below)
- An API key for [OpenRouter](https://openrouter.ai/settings/keys), or any OpenAI-compatible
  endpoint whose model takes images and tool calls

## Pairing file

The phone only opens its developer services (screenshots, touch, keyboard) to a trusted
host. The pairing file holds the keys of such a host, so the app can act as one for its own
phone. Make it once from a Mac with the phone plugged in over USB and unlocked (tap Trust if asked):

```sh
git clone https://github.com/jkcoxson/idevice && cd idevice
cargo build --release -p idevice-tools --bin idevice-tools
./target/release/idevice-tools rppairing pair my-mac pairingFile.plist
```

Then import it in the app (below), or, once the app is installed, copy it into its Documents folder:

```sh
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \
  --domain-identifier blog.eliot.iphoneuse --source pairingFile.plist --destination Documents/pairingFile.plist
```

Make a new one if the app says the pairing file is invalid or expired.

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

1. Settings (gear, top right) → Import Pairing File (skip if you copied it over).
2. Allow the "Add VPN Configuration" prompt. The VPN only routes `10.7.0.1` back to the phone.
3. Settings → Model: pick a provider, paste the API key, pick a model.
4. Back in the chat: wait until the "not connected" line above the input disappears (the developer disk image downloads on first run), then type a prompt and send it.

Feature scope: [docs/FEATURES.md](docs/FEATURES.md).

## Known technical issues

<details>
<summary>Heartbeat connection closes right after connecting (fixed: runs used to get killed)</summary>

**Symptom (before the fix):** a run froze on a step after about a minute in the background, and the
Live Activity stayed on that step. The app had been killed: the phone's crash logs held an
`iPhoneUse.cpu_resource_fatal-*.ips` report ("exceeding limit of 80% cpu over 60 seconds", "Process killed").

**Cause:** the heartbeat thread (`Heartbeat.run()` in `DeviceSession.swift`) keeps CoreDevice services
alive during a run. Its connection is closed right after the handshake; idevice's userspace TCP stack
(jktcp) then answers every read with `BrokenPipe` in microseconds, and the loop retried with no delay,
about 45k times a second. iOS kills background apps above 80% CPU over 60 seconds.

Two things made it worse:
- The idevice log was written to `Documents/idevice_log.txt` at Debug level, which prints every XPC
  message, screenshots included, as decimal byte lists: 178 MB of log and ~1 GB of memory in a minute.
- The loop matched errors by the strings `HeartbeatTimeout` / `HeartbeatSleepyTime`, which never
  appear in idevice's messages ("heartbeat timeout", "device went to sleep").

**Fix:** timeouts are matched on the error code (100, sub-code 2) and the loop waits again; any other
error ends the loop. The file log is at Info.

**Still open:** why the heartbeat connection closes. Runs work without it (a 17-step, 2.5-minute run
finished fine); if CoreDevice services start dropping on long runs, reconnecting the heartbeat
(with backoff) is the next step.

**Debugging a killed run:** `idevicecrashreport -u <udid> -k <dir>` pulls the crash logs. Symbolicate
with `atos` against the dSYM of the exact build (the UUID in the report must match
`dwarfdump --uuid`).
</details>

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
