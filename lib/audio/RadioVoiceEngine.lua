--[[
  RadioVoiceEngine.lua
  Ultimate AI Grand Prix Pro: Anthropomorphic Team Radio Voice Engine
  
  Responsibilities:
    1. Bilingual High-Fidelity Radio Chatter (English & Chinese):
       - Authentic F1 Pit Wall radio protocol: Chirp-In -> Speech -> Chirp-Out
       - Pre-rendered bandpass filtered audio clips with radio static envelope
    2. Multi-Tier Preemption & Priority Queue:
       - P0_EMERGENCY (3): Safety Car, Serious Puncture, Collision Hazard
       - P1_COMMAND (2): Team Radio Orders (BOX, PUSH, SAVE, ATTACK, DEFEND, UNDERCUT)
       - P2_INFO (1): Tactical Notifications (Blue Flag, Tyre Cliff, Overtake)
    3. Non-Overlapping Audio Dispatch & Preemptive State Machine:
       - IDLE -> BEEP_OPEN -> PLAYING_VOICE -> BEEP_CLOSE -> COOLDOWN -> IDLE
       - Strict anti-spam debounce (12.0s per key)
    4. Zero Runtime Dynamic Allocation:
       - Preallocated fixed audio handles, scalar state registers, zero GC pressure
]]

local M = {}

M.PRIORITY_EMERGENCY = 3
M.PRIORITY_COMMAND = 2
M.PRIORITY_INFO = 1

M.STATE_IDLE = 0
M.STATE_BEEP_OPEN = 1
M.STATE_PLAYING_VOICE = 2
M.STATE_BEEP_CLOSE = 3
M.STATE_COOLDOWN = 4

local _enabled = true
local _language = "en" -- "en" or "zh"
local _volume = 0.85

local _currentState = M.STATE_IDLE
local _stateTimer = 0.0

-- Audio duration estimates (seconds)
local DURATION_BEEP_OPEN = 0.12
local DURATION_BEEP_CLOSE = 0.09
local DURATION_COOLDOWN = 0.25

-- Accurate duration tables (seconds, measured exactly from master wav assets)
local _clipDurations = {
  en = {
    cmd_attack = 3.50,
    cmd_box = 3.59,
    cmd_defend = 3.75,
    cmd_push = 2.64,
    cmd_save = 3.99,
    info_blue_flag = 3.82,
    info_overtake = 2.62,
    info_safety_car = 4.81,
    info_tyre_cliff = 3.71,
    info_undercut = 3.93,
    info_yellow_flag = 2.96,
  },
  zh = {
    cmd_attack = 4.20,
    cmd_box = 3.14,
    cmd_defend = 3.70,
    cmd_push = 3.78,
    cmd_save = 3.60,
    info_blue_flag = 3.77,
    info_overtake = 3.27,
    info_safety_car = 4.60,
    info_tyre_cliff = 4.03,
    info_undercut = 3.94,
    info_yellow_flag = 3.77,
  }
}

local function getClipDuration(key, lang)
  local l = lang or _language or "en"
  local langTable = _clipDurations[l] or _clipDurations.en
  if langTable and langTable[key] then
    return langTable[key]
  end
  return (_clipDurations.en and _clipDurations.en[key]) or 2.5
end

-- Preallocated Audio Event handles
local _audioEvents = {
  common = {},
  en = {},
  zh = {}
}

-- Debounce tracking
local _lastPlayedTimes = {}
local _sessionTime = 0.0

-- Fixed-slot Queue (max 4 slots, scalar tables)
local MAX_QUEUE = 4
local _queue = {}
local _queueCount = 0

for i = 1, MAX_QUEUE do
  _queue[i] = { key = "NONE", priority = 0, duration = 0.0 }
end

local _activeKey = "NONE"
local _activePriority = 0
local _activeDuration = 0.0
local _lastPlayedKey = "NONE"

local _baseDir = "apps/lua/Ultimate-AI-Grand-Prix-Pro/audio/radio"
local _activeAudioEvent = nil

local function resolveBaseDir()
  local candidates = {}
  if ac and ac.getFolder and ac.FolderID and ac.FolderID.ScriptOrigin then
    local ok, p = pcall(ac.getFolder, ac.FolderID.ScriptOrigin)
    if ok and p and p ~= "" then
      table.insert(candidates, (p:gsub("\\", "/") .. "/audio/radio"))
    end
  end
  if ac and ac.getFolder and ac.FolderID and ac.FolderID.ACApps then
    local ok, p = pcall(ac.getFolder, ac.FolderID.ACApps)
    if ok and p and p ~= "" then
      table.insert(candidates, (p:gsub("\\", "/") .. "/lua/Ultimate-AI-Grand-Prix-Pro/audio/radio"))
    end
  end
  if __dirname then
    local clean = __dirname:gsub("\\", "/")
    table.insert(candidates, clean .. "/../../audio/radio")
    table.insert(candidates, clean .. "/audio/radio")
  end
  table.insert(candidates, "apps/lua/Ultimate-AI-Grand-Prix-Pro/audio/radio")
  table.insert(candidates, "audio/radio")

  if io and io.open then
    for _, dir in ipairs(candidates) do
      local testFile = dir .. "/common/beep_open.wav"
      local f = io.open(testFile, "rb")
      if f then
        f:close()
        return dir
      end
    end
  end
  return candidates[1] or "apps/lua/Ultimate-AI-Grand-Prix-Pro/audio/radio"
end

local function getClipPath(lang, key)
  return string.format("%s/%s/%s.wav", _baseDir, lang, key)
end

local function getCommonPath(key)
  return string.format("%s/common/%s.wav", _baseDir, key)
end

--- Stop active AudioEvent safely
local function stopActiveAudio()
  if _activeAudioEvent then
    pcall(function()
      if _activeAudioEvent.stop then
        _activeAudioEvent:stop()
      end
    end)
    _activeAudioEvent = nil
  end
end

--- Play specific audio file via fresh CSP AudioEvent (prevent one-shot invalidation)
local function playClipFile(path, vol)
  if not path or path == "" then return nil end
  stopActiveAudio()

  if ac and ac.AudioEvent and ac.AudioEvent.fromFile then
    local ok, evt = pcall(ac.AudioEvent.fromFile, {
      filename = path,
      stream   = { name = "", size = 0 },
      use3D    = false,
      loop     = false
    }, false)
    if ok and evt then
      _activeAudioEvent = evt
      local v = vol or _volume or 0.85
      pcall(function()
        if evt.setVolumeMultipliers then
          evt:setVolumeMultipliers(1.0, 1.0, 1.0)
        end
        if evt.volume ~= nil then
          evt.volume = v
        end
        if evt.cameraInteriorMultiplier ~= nil then
          evt.cameraInteriorMultiplier = 1.0
        end
        if evt.cameraExteriorMultiplier ~= nil then
          evt.cameraExteriorMultiplier = 1.0
        end
        if evt.start then
          evt:start()
        end
      end)
      return evt
    end
  end
  return nil
end

--- Initialize Audio Event Engine
---@param baseDir string? Custom base directory for audio assets
function M.init(baseDir)
  if baseDir and baseDir ~= "" then
    _baseDir = baseDir
  else
    _baseDir = resolveBaseDir()
  end
  _activeAudioEvent = nil
end

--- Configure active spoken language
---@param lang string "en" or "zh"
function M.setLanguage(lang)
  if lang == "zh" or lang == "en" then
    _language = lang
  end
end

--- Get current active language
---@return string "en" or "zh"
function M.getLanguage()
  return _language
end

--- Configure master radio volume
---@param vol number 0.0 to 1.0
function M.setVolume(vol)
  local v = vol or 0.85
  if v < 0.0 then v = 0.0 end
  if v > 1.0 then v = 1.0 end
  _volume = v
end

--- Get master radio volume
---@return number vol
function M.getVolume()
  return _volume
end

--- Enable or disable radio engine
---@param enabled boolean
function M.setEnabled(enabled)
  _enabled = (enabled ~= false)
  if not _enabled then
    M.stop()
  end
end

--- Check if radio engine is enabled
---@return boolean
function M.isEnabled()
  return _enabled
end

--- Get current state of state machine
---@return integer state
function M.getState()
  return _currentState
end

--- Get current queue size
---@return integer count
function M.getQueueSize()
  return _queueCount
end

--- Get last played clip key
---@return string key
function M.getLastPlayedKey()
  return _lastPlayedKey
end

--- Clear queue and stop current audio
function M.stop()
  stopActiveAudio()

  _currentState = M.STATE_IDLE
  _stateTimer = 0.0
  _activeKey = "NONE"
  _activePriority = 0
  _activeDuration = 0.0
  _queueCount = 0
end

--- Full reset
function M.reset()
  M.stop()
  _sessionTime = 0.0
  _lastPlayedKey = "NONE"
  for k, _ in pairs(_lastPlayedTimes) do
    _lastPlayedTimes[k] = -999.0
  end
  for i = 1, MAX_QUEUE do
    _queue[i].key = "NONE"
    _queue[i].priority = 0
    _queue[i].duration = 0.0
  end
end

--- Queue or play a team radio message
---@param clipKey string Key corresponding to audio clip (e.g. "cmd_box", "cmd_push")
---@param priority integer? Priority level (P0_EMERGENCY, P1_COMMAND, P2_INFO)
---@return boolean wasAccepted
function M.playRadio(clipKey, priority)
  if not _enabled then return false end
  if not clipKey or clipKey == "NONE" then return false end

  local prio = priority or M.PRIORITY_INFO
  local clipDur = getClipDuration(clipKey, _language)

  -- Debounce check: 12.0s cooldown per key unless Emergency priority
  local lastT = _lastPlayedTimes[clipKey] or -999.0
  if prio < M.PRIORITY_EMERGENCY and (_sessionTime - lastT) < 12.0 then
    return false
  end

  -- Preemption check: If currently playing lower priority, interrupt immediately
  if _currentState ~= M.STATE_IDLE and prio > _activePriority and prio >= M.PRIORITY_COMMAND then
    M.stop()
    _activeKey = clipKey
    _activePriority = prio
    _activeDuration = clipDur
    _currentState = M.STATE_BEEP_OPEN
    _stateTimer = DURATION_BEEP_OPEN
    _lastPlayedTimes[clipKey] = _sessionTime
    _lastPlayedKey = clipKey
    playClipFile(getCommonPath("beep_open"), _volume)
    return true
  end

  -- If idle, start immediately
  if _currentState == M.STATE_IDLE then
    _activeKey = clipKey
    _activePriority = prio
    _activeDuration = clipDur
    _currentState = M.STATE_BEEP_OPEN
    _stateTimer = DURATION_BEEP_OPEN
    _lastPlayedTimes[clipKey] = _sessionTime
    _lastPlayedKey = clipKey
    playClipFile(getCommonPath("beep_open"), _volume)
    return true
  end

  -- Otherwise, enqueue if space available
  if _queueCount < MAX_QUEUE then
    _queueCount = _queueCount + 1
    local slot = _queue[_queueCount]
    slot.key = clipKey
    slot.priority = prio
    slot.duration = clipDur
    return true
  end

  return false
end

--- Preview a radio clip immediately (bypasses debounce guard, used for UI test)
---@param clipKey string? Optional clip key (default: "cmd_push")
---@return boolean success
function M.preview(clipKey)
  local key = (clipKey and clipKey ~= "") and clipKey or "cmd_push"
  local clipDur = getClipDuration(key, _language)

  M.stop()
  _activeKey = key
  _activePriority = M.PRIORITY_COMMAND
  _activeDuration = clipDur
  _currentState = M.STATE_BEEP_OPEN
  _stateTimer = DURATION_BEEP_OPEN
  _lastPlayedTimes[key] = _sessionTime
  _lastPlayedKey = key
  playClipFile(getCommonPath("beep_open"), _volume)
  return true
end

--- Tick Radio Voice State Machine (Runs at 10Hz or 60Hz)
--- Pure scalar mathematics, zero dynamic memory allocation
---@param dt number Delta time in seconds
function M.step(dt)
  _sessionTime = _sessionTime + dt

  if not _enabled then return end
  if _currentState == M.STATE_IDLE then return end

  _stateTimer = _stateTimer - dt
  if _stateTimer > 0.0 then return end

  -- State transitions
  if _currentState == M.STATE_BEEP_OPEN then
    -- Open beep finished -> start speech clip
    _currentState = M.STATE_PLAYING_VOICE
    local dur = _activeDuration
    local evt = playClipFile(getClipPath(_language, _activeKey), _volume)
    if evt and evt.getDuration then
      local okD, dSec = pcall(evt.getDuration, evt)
      if okD and type(dSec) == "number" and dSec > 0.5 then
        dur = dSec + 0.15 -- 150ms natural cadence safety margin
      end
    end
    _stateTimer = dur

  elseif _currentState == M.STATE_PLAYING_VOICE then
    -- Speech clip finished -> start close beep
    _currentState = M.STATE_BEEP_CLOSE
    _stateTimer = DURATION_BEEP_CLOSE
    playClipFile(getCommonPath("beep_close"), _volume)

  elseif _currentState == M.STATE_BEEP_CLOSE then
    -- Close beep finished -> cooldown
    stopActiveAudio()
    _currentState = M.STATE_COOLDOWN
    _stateTimer = DURATION_COOLDOWN

  elseif _currentState == M.STATE_COOLDOWN then
    -- Cooldown finished -> advance queue or return to IDLE
    if _queueCount > 0 then
      -- Dequeue head
      local nextSlot = _queue[1]
      _activeKey = nextSlot.key
      _activePriority = nextSlot.priority
      _activeDuration = nextSlot.duration

      -- Shift remaining slots in-place (no table creation)
      for i = 1, _queueCount - 1 do
        _queue[i].key = _queue[i + 1].key
        _queue[i].priority = _queue[i + 1].priority
        _queue[i].duration = _queue[i + 1].duration
      end
      _queue[_queueCount].key = "NONE"
      _queue[_queueCount].priority = 0
      _queueCount = _queueCount - 1

      _currentState = M.STATE_BEEP_OPEN
      _stateTimer = DURATION_BEEP_OPEN
      _lastPlayedTimes[_activeKey] = _sessionTime
      _lastPlayedKey = _activeKey
      playClipFile(getCommonPath("beep_open"), _volume)
    else
      stopActiveAudio()
      _currentState = M.STATE_IDLE
      _activeKey = "NONE"
      _activePriority = 0
      _activeDuration = 0.0
    end
  end
end

--- Play standalone chirp cue (used by driver chatter to signal incoming transmission)
--- Does not disturb speech state machine if a speech clip is actively playing
---@param chirpType string? "open" or "close"
---@return boolean success
function M.playChirp(chirpType)
  if not _enabled then return false end
  local cName = (chirpType == "close") and "beep_close" or "beep_open"
  -- If radio is already playing speech, don't interrupt speech with a beep
  if _currentState == M.STATE_PLAYING_VOICE then
    return false
  end
  playClipFile(getCommonPath(cName), _volume)
  return true
end

--- Map Radio Command String to Clip Key
---@param radioCmd string "BOX_THIS_LAP", "PUSH", "SAVE", "ATTACK", "DEFEND"
---@return string? clipKey
function M.mapRadioCommandToClip(radioCmd)
  if radioCmd == "BOX_THIS_LAP" then
    return "cmd_box"
  elseif radioCmd == "PUSH" then
    return "cmd_push"
  elseif radioCmd == "SAVE" then
    return "cmd_save"
  elseif radioCmd == "ATTACK" then
    return "cmd_attack"
  elseif radioCmd == "DEFEND" then
    return "cmd_defend"
  end
  return nil
end

return M
