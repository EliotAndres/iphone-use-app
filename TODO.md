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
- [ ] Unused idevice FFI features, to shrink `libidevice_ffi.a` (204 MB)
- [ ] Rename the Xcode project/target/module from StikDebug, and pick a new bundle id
      (the current one, `blog.eliot.stikdebug`, holds the imported pairing file: re-import after the change)

## Ship our own loopback VPN

Users currently have to install LocalDevVPN from the App Store and switch it on.
Embed a packet-tunnel Network Extension instead. Findings: see "Built-in loopback VPN" below.

## Other

- [ ] Full LLM run on the 16 Pro (iOS 27); Gemini 3.5 Flash Lite quality
- [ ] Log when `Activity.request` fails (it's silent today)
- [ ] Reboot test and 30 min soak (Notion plan T7/T8)
