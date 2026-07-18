# AiPi Lite board for ESP-Claw (EagleNexus)

Prototype board definition that runs the [EagleNexus](https://github.com/eduddy/EagleNexus)
fork of Espressif's **ESP-Claw** edge-agent framework on the Xorigin AiPi Lite
(ESP32-S3, ES8311 audio codec, ST7735 128x128 LCD, WS2812 LED). Pin mapping
comes from the traced-out ESPHome template in this repo (`aipi.yaml`).

## Installing the board into EagleNexus

The AiPi wiring is nearly identical to the `movecall_moji_esp32s3` board that
already ships with ESP-Claw (same ES8311/I2S/I2C/SPI pins) — the differences
are the ST7735 display, the LED on GPIO46, and the button on GPIO42.

```bash
# 1. ESP-IDF v5.5.4 environment active, then:
pip install esp-bmgr-assist

# 2. Get EagleNexus
git clone https://github.com/eduddy/EagleNexus
cd EagleNexus/application/edge_agent

# 3. Drop this board in
cp -r <this-repo>/eaglenexus/boards/aipi_lite boards/community/aipi_lite

# 4. Select it and build
idf.py bmgr -c ./boards -b aipi_lite
idf.py build

# 5. Flash (hold BOOT under the back cover on first flash if needed)
idf.py flash monitor
```

## Pin map

| Function            | GPIO | Notes                                   |
|---------------------|------|-----------------------------------------|
| I2C SDA / SCL       | 5 / 4 | ES8311 control (addr 0x30 8-bit)       |
| I2S MCLK/BCLK/WS    | 6 / 14 / 12 | Shared in/out bus                |
| I2S DOUT (speaker)  | 11   | via ES8311 DAC                          |
| I2S DIN (mic)       | 13   | via ES8311 ADC                          |
| Speaker enable (PA) | 9    | active high                             |
| SPI SCLK / MOSI     | 16 / 17 | LCD bus                              |
| LCD CS / DC / RESET | 15 / 7 / 18 | ST7735, 128x128                  |
| LCD backlight       | 3    | LEDC PWM                                |
| WS2812 LED          | 46   | single pixel, GRB                       |
| Right button        | 42   | active low                              |

## First-boot checklist

1. **PSRAM** — the config assumes an N16R8 module (8MB octal PSRAM). Watch the
   boot log: if PSRAM init fails, switch `CONFIG_SPIRAM_MODE_OCT` to
   `CONFIG_SPIRAM_MODE_QUAD` in `sdkconfig.defaults.board`. ESP-Claw needs
   8MB PSRAM; if the module turns out to have less, this port is a no-go.
2. **Display orientation** — `swap_xy`/`mirror_y` in `board_devices.yaml`
   reproduce the ESPHome template's `rotation: 90`. Tune those flags if the
   image is rotated/mirrored, and the `AIPI_LCD_GAP_X/Y` offsets in
   `setup_device.c` (2/3, 2/1, or 0/0) if the image is shifted.
3. **Colors** — the template needed `invert_colors: true`, carried over as
   `invert_color: true`. If red/blue are swapped, change `rgb_ele_order`
   to `LCD_RGB_ELEMENT_ORDER_RGB`.
4. **Audio** — speaker distorts above ~75% volume (hardware limit observed
   under ESPHome). Mic and speaker share one I2S port, as on the Moji board.

## Voice interaction (button push-to-talk)

The board ships a `voice_ptt` skill that uses the right button as the wake
word, since ESP-Claw has no wake-word engine:

- **Double click** — start listening (LED cyan, high beep)
- **Single click while listening** — stop; audio is transcribed and handed to
  the agent as a chat message on channel `voice`
- **Long press while listening** — cancel without sending
- **Single click while idle** — interrupt a reply that is being spoken

Flow: `voice_ptt.lua` (autostarted at boot by a seeded router rule) records
mic PCM, wraps it in WAV, base64s it into a JSON request to the configured
STT endpoint (default Gemini `generateContent` — chosen because the
`http_request` capability has no multipart support), and publishes the
transcript so the stock router rule hands it to the agent. The agent's reply
is matched by the seeded `voice_agent_reply_speak` rule and spoken by
`voice_speak.lua` through an OpenAI-compatible `/v1/audio/speech` endpoint
(binary response saved to `/fatfs/tmp`, played on the ES8311 speaker).

Setup after first boot:

1. Put your keys in `/fatfs/skills/voice_ptt/config.json` (`stt.api_key`,
   `tts.api_key`; leave `tts.api_key` empty for a silent node).
2. Allowlist the endpoints via the agent chat (`search_http_allowlist`):
   `generativelanguage.googleapis.com` and `api.openai.com`.

These files are seeded through `/system/.recovery`, so they land in `/fatfs`
on first boot (or whenever missing) and your on-device edits survive
reflashes. The seeded `router_rules.json` is a copy of the stock rules plus
the two voice rules — if upstream changes its defaults, refresh the copy.

## Known limitations

- The **left button** is a sleep/wake circuit, not a plain GPIO — not exposed.
- ESP-Claw is chat/event-driven; it has audio record/play modules but no
  wake-word engine, so this is an edge-agent node, not a voice assistant.
- Board YAML is written against the ESP Board Manager schema used by the
  in-tree boards as of EagleNexus master (July 2026); `idf.py bmgr` will
  validate it at generation time.
