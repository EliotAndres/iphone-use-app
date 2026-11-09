# Live voice (OpenAI Realtime): plan

Goal: talk to the phone with an open mic and speaker, and have it act through tool calls.
Branch: `gpt-live-voice-iphone-pla-9d72dda1`. Status: built on GPT-Live (`gpt-live-1`, `iPhoneUse/Agent/Live.swift`) instead of the Realtime API described below; untested on a phone.

## Can the connection stay open?

It should:
- `UIBackgroundModes` already lists `audio`. While an `AVAudioSession` in `.playAndRecord`
  is recording, iOS keeps the app running in the background, the same way call and voice
  memo apps stay alive. The orange mic dot stays on. A `URLSessionWebSocketTask` keeps working
  because the process is never suspended.
- Echo: use `.voiceChat` mode, which turns on Apple's echo cancellation, so the model does not
  hear its own voice from the speaker. This also makes barge-in work.
- One conflict to fix: `BackgroundAudioManager` switches the session to `.playback` +
  `mixWithOthers`, and `VoiceRecorder.stopEngine` deactivates the session. While live mode is
  on, the voice session owns the audio session. The silent-audio keep-alive is not needed
  then, because the open mic already keeps the app alive.
- Known limits: OpenAI caps a realtime session at about 60 min (reconnect when it ends). A phone
  call or Siri interrupts the session; on `interruptionNotification` with type `.ended`, restart
  the engine.

## Architecture: the voice model talks, the existing loop acts

The realtime model is the conversation layer. The proven screenshot → vision LLM → tap loop
(`PhoneAgent.loop`, `Decide`, evals) stays as it is and does the clicking.

```
mic ─PCM16 24k─▶ WebSocket (gpt-realtime-2) ─audio─▶ speaker
                      │ tool calls
                      ▼
   run_task(task) ─▶ PhoneAgent.run(prompt:)  (OpenRouter vision model, unchanged)
   stop_task()    ─▶ PhoneAgent.stop()
   answer(text)   ─▶ PhoneAgent.answer(_:)
                      ▲
   loop events ───────┘  ask_user_question / done / error → conversation item + response.create
```

Why the voice model doesn't tap directly: realtime models are weak at pixel coordinates,
each screenshot costs a lot of context, and audio tokens are expensive. Delegating also
reuses the evals and the model picker. Direct control (sending a screenshot as `input_image`
after each action) is a phase-2 experiment, not the first build.

## Tools given to the realtime model

| tool | does |
|---|---|
| `run_task(task)` | Starts `PhoneAgent.run`. The result returns no output right away; when the run ends, its outcome is sent as `function_call_output` + `response.create`, so the model announces it. |
| `stop_task()` | `PhoneAgent.stop()` ("stop", "never mind") |
| `answer_question(text)` | Answers a pending `ask_user_question` from the loop |

The loop's `ask_user_question` is sent to the model as a system item ("The agent asks: …"),
and the model reads it aloud. The loop already brings the app to the front on a question.
Optional: speak each step briefly ("opening Lyft"). Leave it out at first; the model would
talk too much.

## Code (small diff)

- **New `iPhoneUse/Agent/Realtime.swift`** (~250 lines), `@MainActor final class LiveVoice`:
  - `URLSessionWebSocketTask` to `wss://api.openai.com/v1/realtime?model=<model>`, Bearer key.
    No WebRTC SDK, no new dependency.
  - `session.update`: instructions, voice, `audio.input.format` pcm16 24 kHz,
    `turn_detection: semantic_vad`, the 3 tools.
  - Mic: the `VoiceRecorder.installTap` converter pattern at 24 kHz → base64 →
    `input_audio_buffer.append` (make `installTap` take a format and reuse it).
  - Speaker: `AVAudioPlayerNode` on the same engine, fed with `response.output_audio.delta`.
  - Barge-in: on `input_audio_buffer.speech_started`, stop the player and send
    `conversation.item.truncate`.
  - Tool dispatch: `response.function_call_arguments.done` → the 3 calls above.
- **`PhoneAgent`**: one optional hook, `var onEvent: ((Event) -> Void)?` with
  `.question(String)` / `.finished(String)`, called from the existing `waitForAnswer` and
  at the end of `run`. Nothing else changes.
- **`LLMSettings`**: OpenAI key in the Keychain (account `apiKey.openai`; OpenRouter has no
  realtime endpoint), realtime model (default `gpt-realtime-2`, free text), and voice.
- **`AgentView`**: a "Talk" button next to the mic. It toggles live mode and shows the
  existing `LevelMeter` waveform plus a "Listening / Speaking / Working" state.
- **`BackgroundAudioManager`**: skip the start while `LiveVoice` is active.
- No pbxproj edits: the project uses synchronized folders.

## Steps

1. WebSocket + audio echo test: connect, talk, hear replies, interrupt the model, with no tools.
   Check: lock the phone or switch apps for 5 min while the conversation keeps going.
2. Add `run_task` / `stop_task` and the PhoneAgent hook ("open Settings" end to end).
3. `ask_user_question` ↔ `answer_question` round trip (the Starbucks demo flow).
4. Settings rows for the key, model and voice; the setup checklist row; update FEATURES.md.
5. Phase 2, optional: try direct control by giving the realtime model the tap tools plus
   `input_image` screenshots, and compare speed and accuracy with the delegated build.

## Open questions

- Cost: gpt-realtime-2 lists $32 / $64 per M audio tokens (in / out). With an open mic and
  server VAD, silence isn't billed as turns, but long sessions add up. Add an idle auto-hangup
  (e.g. 2 min with no speech).
- Siri / Shortcut entry ("Hey Siri, talk to my phone") opening live mode directly: easy with an
  `openAppWhenRun` intent; add it once the basic flow works.
