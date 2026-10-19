<div align="center">

<img src="docs/images/logo.png" alt="iphone-use-app icon" width="160">

# iphone-use-app

**Let an AI model use your iPhone, from the iPhone itself. No Mac, no extra hardware, no jailbreak.**

![iOS](https://img.shields.io/badge/iOS-26%2B-black)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
![Swift + Rust](https://img.shields.io/badge/Swift%20%2B%20Rust-orange)

<p>
  <a href="docs/demo.mp4"><img src="docs/images/demo.gif" alt="Demo: the agent opens Notes and writes hello world" width="30%"></a>
  <img src="docs/images/screen-steps.jpg" alt="The finished run: each step with its screenshot, then the agent's summary" width="30%">
  <img src="docs/images/screen-home.jpg" alt="A new chat with suggested prompts" width="30%">
</p>

*Left: "Open notes, write "hello world"" (4× speed): the agent leaves its own app, opens Notes, creates a note,
types the text and taps Done. Middle: the finished run, each step with its screenshot. Right: a new chat.*

</div>

## Features

- **No computer needed:** the agent runs on the iPhone and controls that same iPhone.
- **No extra hardware, no jailbreak:** it uses the phone's own developer services, the same ones Xcode uses.
- **Works across apps:** taps, swipes, types, presses Home and opens any installed app.
- **Runs in the background:** the Live Activity and Dynamic Island show the current step, with a Stop button.
- **Start it from anywhere:** the chat, Siri, the "Run Agent" Shortcut or an `iphoneuse://run?prompt=…` link.
- **Bring your own model:** OpenRouter or any compatible endpoint; the key stays in the Keychain.
- **Free or paid Apple account:** the built-in VPN with a paid team, or the free LocalDevVPN app with a free Apple ID.

## Requirements

| Part | Notes |
|---|---|
| **iPhone** | iOS 26 or later, Developer Mode on. |
| **Apple account** | **Paid team:** the app uses its own built-in VPN (needs the Network Extension entitlement).<br>**Free Apple ID:** build with `BUILTIN_VPN=NO` (Xcode build setting or `xcodebuild` argument) and install [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044); re-sign every 7 days. |
| **Pairing file** | Made once from a Mac over USB (below). |
| **Vision model** | An [OpenRouter](https://openrouter.ai/settings/keys) key, or any OpenAI-compatible endpoint whose model takes images and tool calls. |
| **Mac with Xcode + rustup** | Only to build the app and make the pairing file. Not needed at run time. |

## Limitations

- Requires a convenience shortcut when on cellular: iOS refuses new loopback VPN connections on cellular data,
  so the app runs a Cellular Toggle shortcut that turns data off while it connects, then back on (or turn it off by hand).
- Requires a loopback VPN (the built-in one, or [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)),
  so you can't use another VPN while the agent runs: iOS allows one at a time, and Tailscale and similar stop
  while it is on.
- Pairing files expire; make a new one when the app says so.
- Sideloaded build only (Developer Mode, developer services): not App Store material.
- Each step takes a few seconds, most of it the model.

## How it works

```mermaid
flowchart LR
  P["Prompt, Siri or Shortcut"] --> A["Agent loop<br/>(iphone-use-app)"]
  A -- "image + history" --> M["Vision model"]
  M -- "tool call: tap, swipe,<br/>type, open_app, done" --> A
  A <-- "screenshot / input" --> V["Loopback VPN<br/>10.7.0.1"]
  V <-- "pairing file = trusted host" --> C["CoreDevice services<br/>of the same iPhone"]
```

- **Eyes: CoreDevice screenshots.** The app asks the phone's developer services for a screenshot.
- **Hands: CoreDevice input.** Taps, swipes, typing, Home and app launches go through the same channel.
  No AssistiveTouch, no pointer calibration.
- **The link: a loopback VPN + pairing file.** A packet-tunnel extension inside the app (or LocalDevVPN) routes
  `10.7.0.1` back to the phone; the pairing file lets the app act as a trusted host for its own phone.
- **Brain: the agent loop.** Screenshot → model picks a tool call → act, until `done`. Up to 40 steps by default.
- **In the background.** The Live Activity shows the current step and has a Stop button.
- **History.** Every run is a chat in the drawer, with its steps and screenshots.

## Quick start

### 1. Make a pairing file

The phone only opens its developer services to a trusted host. The pairing file holds the keys of such a host,
so the app can act as one for its own phone. Plug the phone into the Mac, unlock it (tap Trust if asked), then:

```sh
git clone https://github.com/jkcoxson/idevice && cd idevice
cargo build --release -p idevice-tools --bin idevice-tools
./target/release/idevice-tools rppairing pair my-mac pairingFile.plist
```

Make a new one if the app says the pairing file is invalid or expired.

### 2. Build and install the app

```sh
scripts/build-idevice.sh        # once: builds iPhoneUse/idevice/libidevice_ffi.a (needs the aarch64-apple-ios target)
open iPhoneUse.xcodeproj        # set your team, run the iPhoneUse scheme on the phone
```

### 3. Set up (once, in the app)

1. Settings (gear, top right) → **Import Pairing File**.<sup>1</sup>
2. Allow the **Add VPN Configuration** prompt. It only routes `10.7.0.1` back to the phone.
   With LocalDevVPN instead: turn it on, and pick LocalDevVPN in Settings → Phone Connection
   (picked for you if the built-in VPN fails).
3. Settings → **Model**: pick a provider, paste the key, pick a model.
4. Wait for the "not connected" line above the input to go away (the developer disk image downloads on first run).

<sup>1</sup> Or copy it over once the app is installed:
`xcrun devicectl device copy to --device <udid> --domain-type appDataContainer --domain-identifier blog.eliot.iphoneuse --source pairingFile.plist --destination Documents/pairingFile.plist`

### 4. Give it a task

Type a goal, for example *"Open Settings and turn on Dark Mode"*, and send it. Stop it from the Dynamic Island
or the chat.

<details>
<summary><h2>Development</h2></summary>

#### Scripted runs (no LLM)

```sh
DEV=<udid> scripts/runscript.sh "open com.apple.Preferences; wait 1.5; tap 0.5 0.9; shot a" a
```

Launches the app with `-agentScript`, waits for "script done" in `Documents/agent.log` and pulls the screenshots.
`-agentPrompt "..."` as a launch argument starts a real run.

#### Simulator (layout checks only)

The simulator can't reach a device, but it shows the UI. `-demoChat YES` plays a fake run
(placeholder screenshots, a question to answer), Debug builds only.

1. `rustup target add aarch64-apple-ios-sim && scripts/build-idevice.sh sim`: the libs are
   single-arch, so the simulator needs its own, in `iPhoneUse/idevice/sim/`.
2. Build Debug (the scheme defaults to Release, which drops `-demoChat`) against that lib:
   `xcodebuild -project iPhoneUse.xcodeproj -scheme iPhoneUse -configuration Debug -destination id=<sim udid> LIBRARY_SEARCH_PATHS='$(PROJECT_DIR)/iPhoneUse/idevice/sim' build`
3. Install the `.app` from DerivedData and launch it with `-demoChat YES`.

Feature scope: [docs/FEATURES.md](docs/FEATURES.md).

</details>

## Known issues

- **"Device Hub: This device was viewed remotely from Mac" shows on every run.** iOS shows it when its
  developer services are used, even though the "Mac" here is the app itself. Nothing leaves the phone.

<details>
<summary><b>Technical details</b></summary>

### Heartbeat connection closes right after connecting (fixed: runs used to get killed)

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

## Responsible use

Only automate devices and accounts you own or may use, and respect the terms of the apps involved. The agent acts
with your hands: watch it, and keep Stop within reach.

## Credits

| Project | Repo | Used for |
|---|---|---|
| StikDebug, by Stephen and contributors | [StikDebug/StikDebug](https://github.com/StikDebug/StikDebug) | The tunnel, pairing file and developer disk image code is based on it |
| idevice, by jkcoxson | [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | The Rust library behind every device call |
| StosVPN, by the SideStore Team and Stossy11 | [SideStore/StosVPN](https://github.com/SideStore/StosVPN) | The loopback VPN (`TunnelProvider/`) is based on it |
| LocalDevVPN, by jkcoxson | [jkcoxson/LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | The VPN app for free Apple IDs; our tunnel came from StosVPN through it |
| esp32-iphone-agent, by Henry Yuan | [onehumanbeing/esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent) | The model provider and model picker design, and the layout of this README |
| DeveloperDiskImage, by doronz88 | [doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) | Developer disk images |

## License

AGPL-3.0. See [`LICENSE`](LICENSE).
