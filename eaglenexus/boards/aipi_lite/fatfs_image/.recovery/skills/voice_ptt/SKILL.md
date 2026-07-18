# voice_ptt

Push-to-talk voice interaction for the AiPi Lite. The right-hand button
replaces a wake word.

## Interaction

- **Double click**: start listening (LED turns cyan, high beep).
- **Single click while listening**: stop recording; the audio is transcribed
  and handed to the agent as a normal chat message on channel `voice`.
- **Long press while listening**: cancel without sending.
- **Single click while idle**: interrupt a reply that is currently being
  spoken.

## How it works

- `scripts/voice_ptt.lua` runs persistently (autostarted by the
  `voice_ptt_autostart` router rule on `boot_completed`). It owns the button,
  the status LED, and the microphone. Recorded PCM is wrapped into WAV,
  base64-encoded, and sent to the configured STT endpoint (default: Gemini
  `generateContent`, which accepts inline base64 audio in a plain JSON body).
  The transcript is published with `event_publisher`, and the stock
  `im_any_message_agent` rule routes it to the agent.
- `scripts/voice_speak.lua` is launched by the `voice_agent_reply_speak`
  router rule when the agent answers on the `voice` channel. It synthesizes
  the reply through an OpenAI-compatible `/v1/audio/speech` endpoint (binary
  response saved to `/fatfs/tmp` by `http_request`) and plays it on the
  speaker, polling `/fatfs/tmp/voice_stop.flag` so a button press can cut it
  off.

## Configuration

Edit `/fatfs/skills/voice_ptt/config.json`:

- `stt.api_key` — required for listening (Gemini API key by default).
- `tts.api_key` — required for spoken replies (OpenAI-compatible); leave
  empty to run the node silent.
- `record.max_ms` — hard cap per utterance (default 10 s).
- Endpoints, model names, voice, volumes, GPIO, and LED settings are all
  overridable.

The STT and TTS hosts must be added to the HTTP allowlist
(`search_http_allowlist`) before the capability will call them, e.g.
`generativelanguage.googleapis.com` and `api.openai.com`.
