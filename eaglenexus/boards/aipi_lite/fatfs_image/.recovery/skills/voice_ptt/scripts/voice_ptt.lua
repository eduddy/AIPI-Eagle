-- --------------------------------------------------------------
-- Push-to-talk voice front-end for the AiPi Lite.
--
-- The AiPi has no wake-word engine, so the right button is the
-- "wake word":
--   * double click        -> start listening (LED cyan, high beep)
--   * single click while
--     listening           -> stop, transcribe, hand text to the agent
--   * long press while
--     listening           -> cancel without sending
--   * single click while
--     idle                -> ask voice_speak.lua to stop talking
--
-- The transcript is published as a normal message event on channel
-- "voice"; the stock im_any_message_agent router rule forwards it to
-- the agent, and the voice_agent_reply_speak rule (seeded by this
-- board) routes the agent's reply to voice_speak.lua for playback.
-- --------------------------------------------------------------

local button = require("button")
local led_strip = require("led_strip")
local audio = require("audio")
local board_manager = require("board_manager")
local storage = require("storage")
local json = require("json")
local capability = require("capability")
local event_publisher = require("event_publisher")
local delay = require("delay")

-- 1. Config -----------------------------------------------------
local SKILL_DIR = "/fatfs/skills/voice_ptt"
local STOP_FLAG = "/fatfs/tmp/voice_stop.flag"

local cfg = {
  button_gpio = 42,
  active_level = 0,
  long_press_ms = 1200,
  led = { io = 46, count = 1, brightness = 60 },
  record = { sample_rate = 16000, max_ms = 10000, chunk_ms = 100, mic_volume = 85 },
  stt = { endpoint = "", api_key = "", prompt = "Transcribe this audio.", timeout_ms = 30000 },
  chat_id = "aipi_voice",
}

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

do
  local raw = storage.read_file(SKILL_DIR .. "/config.json")
  if raw then
    local ok, parsed = pcall(json.decode, raw)
    if ok and type(parsed) == "table" then
      merge(cfg, parsed)
    else
      print("[voice_ptt] WARNING: config.json is invalid, using defaults")
    end
  end
end

-- 2. LED helpers ------------------------------------------------
local strip = nil

local function led(r, g, b)
  if not strip then return end
  local s = cfg.led.brightness
  strip:set_pixel(0, r * s // 255, g * s // 255, b * s // 255)
  strip:refresh()
end

local LED_OFF = function() led(0, 0, 0) end
local LED_LISTEN = function() led(0, 180, 255) end   -- cyan
local LED_THINK = function() led(160, 0, 255) end    -- purple
local LED_ERROR = function() led(255, 0, 0) end      -- red

local function flash_error()
  for _ = 1, 3 do
    LED_ERROR(); delay.delay_ms(150)
    LED_OFF(); delay.delay_ms(150)
  end
end

-- 3. Beep helper ------------------------------------------------
-- Opens the speaker only for the duration of the tone so it does not
-- fight voice_speak.lua for the codec. Failure just means no beep.
local function beep(freq)
  pcall(function()
    local codec, rate, ch, bits = board_manager.get_audio_codec_output_params("audio_dac")
    local out = audio.new_output({ codec, rate, ch, bits, volume = 60 })
    out:play_tone(freq, 120)
    out:close()
  end)
end

-- 4. WAV + base64 -----------------------------------------------
local function wav_encode(pcm, sample_rate)
  local byte_rate = sample_rate * 2
  return "RIFF" .. string.pack("<I4", 36 + #pcm) .. "WAVE" ..
         "fmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sample_rate, byte_rate, 2, 16) ..
         "data" .. string.pack("<I4", #pcm) .. pcm
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LUT = {}
for i = 0, 63 do B64_LUT[i] = B64:sub(i + 1, i + 1) end

-- Encodes in bounded blocks so peak memory stays small even for
-- multi-hundred-KB recordings.
local function base64_encode(data)
  local blocks = {}
  local parts = {}
  local n = #data
  local full = n - (n % 3)
  local byte = string.byte
  local lut = B64_LUT
  local j = 1
  for i = 1, full, 3 do
    local a, b, c = byte(data, i, i + 2)
    local v = a * 65536 + b * 256 + c
    parts[j] = lut[v // 262144] .. lut[(v // 4096) % 64] .. lut[(v // 64) % 64] .. lut[v % 64]
    j = j + 1
    if j > 1024 then
      blocks[#blocks + 1] = table.concat(parts)
      parts = {}
      j = 1
    end
  end
  local rem = n % 3
  if rem == 1 then
    local a = byte(data, n)
    parts[j] = lut[a // 4] .. lut[(a % 4) * 16] .. "=="
  elseif rem == 2 then
    local a, b = byte(data, n - 1, n)
    parts[j] = lut[a // 4] .. lut[(a % 4) * 16 + b // 16] .. lut[(b % 16) * 4] .. "="
  end
  blocks[#blocks + 1] = table.concat(parts)
  return table.concat(blocks)
end

-- 5. Speech to text ---------------------------------------------
-- Default endpoint is Gemini generateContent, which accepts inline
-- base64 audio in a plain JSON body (the http_request capability has
-- no multipart support, which rules out Whisper-style endpoints).
local function transcribe(pcm)
  if cfg.stt.api_key == "" or cfg.stt.endpoint == "" then
    return nil, "STT is not configured: set stt.api_key in " .. SKILL_DIR .. "/config.json"
  end

  local wav = wav_encode(pcm, cfg.record.sample_rate)
  local b64 = base64_encode(wav)

  local body = json.encode({
    contents = {
      {
        parts = {
          { inline_data = { mime_type = "audio/wav", data = b64 } },
          { text = cfg.stt.prompt },
        },
      },
    },
    generationConfig = { temperature = 0 },
  })

  local ok, out, err = capability.call("http_request", {
    url = cfg.stt.endpoint,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["x-goog-api-key"] = cfg.stt.api_key,
    },
    body = body,
    timeout_ms = cfg.stt.timeout_ms,
    max_body_bytes = 65536,
  }, { max_output_bytes = 131072 })

  if not ok then
    return nil, "http_request failed: " .. tostring(err or out)
  end

  -- Output shape: "HTTP <status>\n<body>"
  local status, resp = out:match("^HTTP (%d+)[^\n]*\n(.*)$")
  if not status then
    return nil, "unexpected http_request output"
  end
  if tonumber(status) ~= 200 then
    return nil, "STT endpoint returned HTTP " .. status .. ": " .. resp:sub(1, 200)
  end

  local ok2, parsed = pcall(json.decode, resp)
  if not ok2 or type(parsed) ~= "table" then
    return nil, "STT response is not valid JSON"
  end
  local text
  pcall(function()
    text = parsed.candidates[1].content.parts[1].text
  end)
  if type(text) ~= "string" or text == "" then
    return nil, "STT response contained no transcript"
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 6. State machine ----------------------------------------------
local state = "idle"          -- "idle" | "listening"
local want_start = false
local want_stop = false
local want_cancel = false

local btn = nil
local input = nil
local chunks = nil
local recorded_bytes = 0
local bytes_per_ms = cfg.record.sample_rate * 2 // 1000
local chunk_bytes = bytes_per_ms * cfg.record.chunk_ms
local max_bytes = bytes_per_ms * cfg.record.max_ms

local function start_listening()
  local codec, rate, ch, bits = board_manager.get_audio_codec_input_params("audio_adc")
  local opened, dev = pcall(audio.new_input, { codec, rate, ch, bits, volume = cfg.record.mic_volume })
  if not opened or not dev then
    print("[voice_ptt] ERROR: failed to open microphone: " .. tostring(dev))
    flash_error()
    return
  end
  input = dev
  chunks = {}
  recorded_bytes = 0
  state = "listening"
  -- Interrupt any reply that is still being spoken.
  storage.write_file(STOP_FLAG, "1")
  beep(880)
  LED_LISTEN()
  print("[voice_ptt] listening (double-click detected)")
end

local function close_input()
  if input then
    pcall(input.close, input)
    input = nil
  end
end

local function finish_listening(send)
  close_input()
  state = "idle"
  if not send then
    beep(330)
    LED_OFF()
    print("[voice_ptt] recording cancelled")
    return
  end

  beep(440)
  LED_THINK()
  local pcm = table.concat(chunks)
  chunks = nil
  print(string.format("[voice_ptt] recorded %d bytes, transcribing...", #pcm))

  local text, err = transcribe(pcm)
  if not text then
    print("[voice_ptt] ERROR: " .. tostring(err))
    flash_error()
    LED_OFF()
    return
  end

  print("[voice_ptt] transcript: " .. text)
  event_publisher.publish_message({
    source_cap = "lua_script",
    channel = "voice",
    chat_id = cfg.chat_id,
    text = text,
  })
  -- Brief "handed to the agent" cue; the reply itself arrives through
  -- the router and voice_speak.lua.
  delay.delay_ms(1500)
  LED_OFF()
end

-- 7. Run --------------------------------------------------------
local function run()
  storage.mkdir("/fatfs/tmp")
  pcall(storage.remove, STOP_FLAG)

  local s, s_err = led_strip.new(cfg.led.io, cfg.led.count)
  if s then strip = s else print("[voice_ptt] WARNING: no LED: " .. tostring(s_err)) end
  LED_OFF()

  local b, b_err = button.new(cfg.button_gpio, cfg.active_level, cfg.long_press_ms, 0)
  if not b then
    error("button.new failed: " .. tostring(b_err))
  end
  btn = b

  button.on(btn, "double_click", function() want_start = true end)
  button.on(btn, "single_click", function()
    if state == "listening" then
      want_stop = true
    else
      -- Idle single click = shut up request for voice_speak.lua.
      storage.write_file(STOP_FLAG, "1")
    end
  end)
  button.on(btn, "long_press_start", function()
    if state == "listening" then want_cancel = true end
  end)

  print("[voice_ptt] ready: double-click to talk, click to stop")

  while true do
    button.dispatch()

    if want_start then
      want_start = false
      want_stop = false
      want_cancel = false
      if state == "idle" then start_listening() end
    end

    if state == "listening" then
      if want_cancel then
        want_cancel = false
        want_stop = false
        finish_listening(false)
      elseif want_stop then
        want_stop = false
        finish_listening(true)
      else
        local ok_read, pcm = pcall(input.read, input, chunk_bytes)
        if ok_read and pcm and #pcm > 0 then
          chunks[#chunks + 1] = pcm
          recorded_bytes = recorded_bytes + #pcm
          if recorded_bytes >= max_bytes then
            print("[voice_ptt] max recording length reached")
            finish_listening(true)
          end
        else
          delay.delay_ms(10)
        end
      end
    else
      delay.delay_ms(30)
    end
  end
end

local function cleanup()
  close_input()
  if btn then pcall(button.close, btn) end
  if strip then
    pcall(function()
      strip:clear()
      strip:refresh()
      strip:close()
    end)
  end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
  print("[voice_ptt] FATAL: " .. tostring(err))
  error(err)
end
