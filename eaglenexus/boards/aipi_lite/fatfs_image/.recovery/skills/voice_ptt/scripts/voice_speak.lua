-- --------------------------------------------------------------
-- Speaks an agent reply on the AiPi Lite speaker.
--
-- Launched by the voice_agent_reply_speak router rule whenever the
-- agent answers a message that arrived on the "voice" channel. The
-- reply text is synthesized through an OpenAI-compatible
-- /v1/audio/speech endpoint (binary response saved straight to
-- FATFS by the http_request capability) and played locally.
--
-- A single click on the right button while idle makes voice_ptt.lua
-- write /fatfs/tmp/voice_stop.flag; this script polls for that flag
-- and stops playback when it appears.
-- --------------------------------------------------------------

local audio = require("audio")
local board_manager = require("board_manager")
local storage = require("storage")
local json = require("json")
local capability = require("capability")
local delay = require("delay")

local SKILL_DIR = "/fatfs/skills/voice_ptt"
local STOP_FLAG = "/fatfs/tmp/voice_stop.flag"

local cfg = {
  tts = {
    enabled = true,
    endpoint = "https://api.openai.com/v1/audio/speech",
    api_key = "",
    model = "gpt-4o-mini-tts",
    voice = "alloy",
    response_format = "mp3",
    speaker_volume = 70,
    timeout_ms = 45000,
  },
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
    if ok and type(parsed) == "table" then merge(cfg, parsed) end
  end
end

local text = args and args.text or nil
if type(text) ~= "string" or text == "" then
  print("[voice_speak] no text to speak")
  return
end
if not cfg.tts.enabled or cfg.tts.api_key == "" then
  print("[voice_speak] TTS disabled or unconfigured; reply was: " .. text:sub(1, 200))
  return
end

-- 1. Fetch speech audio -----------------------------------------
local reply_path = "/fatfs/tmp/voice_reply." .. cfg.tts.response_format

local function fetch_speech()
  local ok, out, err = capability.call("http_request", {
    url = cfg.tts.endpoint,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. cfg.tts.api_key,
    },
    body = json.encode({
      model = cfg.tts.model,
      voice = cfg.tts.voice,
      input = text,
      response_format = cfg.tts.response_format,
    }),
    timeout_ms = cfg.tts.timeout_ms,
    save_path = reply_path,
    max_file_bytes = 2 * 1024 * 1024,
  })
  if not ok then
    return nil, "http_request failed: " .. tostring(err or out)
  end
  local status = out:match("^HTTP (%d+)")
  if tonumber(status) ~= 200 then
    return nil, "TTS endpoint returned HTTP " .. tostring(status)
  end
  return true
end

-- 2. Play it, watching the stop flag ----------------------------
local output = nil
local player = nil

local function cleanup()
  if player then
    pcall(player.stop, player)
    pcall(player.close, player)
    player = nil
  end
  if output then
    pcall(output.close, output)
    output = nil
  end
  pcall(storage.remove, reply_path)
end

local function run()
  storage.mkdir("/fatfs/tmp")

  local ok, err = fetch_speech()
  if not ok then
    print("[voice_speak] ERROR: " .. tostring(err))
    return
  end

  -- Only honor stop requests made after synthesis started; a stale
  -- flag from before this reply would silence it for no reason.
  pcall(storage.remove, STOP_FLAG)

  local codec, rate, ch, bits = board_manager.get_audio_codec_output_params("audio_dac")
  output = audio.new_output({ codec, rate, ch, bits, volume = cfg.tts.speaker_volume })
  player = audio.player({ output = output })

  player:play(reply_path)
  print("[voice_speak] speaking " .. tostring(#text) .. " chars")

  while true do
    local st = player:poll()
    if not st or not st.running then
      break
    end
    if storage.exists(STOP_FLAG) then
      print("[voice_speak] stop requested by button")
      pcall(storage.remove, STOP_FLAG)
      player:stop()
      break
    end
    delay.delay_ms(200)
  end
end

local ok, err = xpcall(run, debug.traceback)
cleanup()
if not ok then
  print("[voice_speak] FATAL: " .. tostring(err))
  error(err)
end
