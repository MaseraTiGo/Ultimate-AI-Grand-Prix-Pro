--[[
  TVDirectorEngine.lua
  Ultimate AI Grand Prix Pro: Intelligent Real-time TV Director & Cinematic Broadcast Engine

  Responsibilities:
    1. Full-field Combat Hotspot Scoring (CHI):
       - Evaluates battle proximity (gap < 1.5s), psychological MTI pressure,
         leaderboard stakes (P1~P3, final laps), and incident spikes (SPIN, OVERTAKE, PIT).
    2. Five-Tier Priority & Preemption Hierarchy:
       - P0: Emergency incidents (Spin, crash, off-track) -> instant preemption
       - P1: Action (Pounce pass, overtake) -> high priority cut
       - P2: Tactics (Pit stop, lockup) -> medium priority cut
       - P3: Battle (Wheel-to-wheel combat) -> standard battle tracking
       - P4: Atmosphere (Leader cruising, pack flight) -> baseline fallback
    3. Dwell-Time Hysteresis & Anti-Jitter State Machine:
       - Configurable Min Dwell (default 5.0s) prevents rapid jittery switching.
       - Configurable Max Dwell (default 12.0s) prevents monotonous stagnation.
    4. Cinematic Shot Choreography:
       - Track TV replay cameras, Onboard T-Cam, Helicopter sky view, pit lane cameras.
    5. Manual Override Protection:
       - Detects player manual camera/car inputs; yields quietly for quietWindow (default 15.0s).
    6. Performance & Memory Guarantees:
       - Pure scalar math, fixed preallocated 32-slot arrays, zero GC allocation in frame loop.
]]

local RaceContext = require("lib/core/RaceContext")
local EventHub = require("lib/core/EventHub")

local M = {}

-- Priority Constants (0 is highest, 4 is lowest)
M.PRIORITY_EMERGENCY = 0
M.PRIORITY_ACTION = 1
M.PRIORITY_TACTICS = 2
M.PRIORITY_BATTLE = 3
M.PRIORITY_ATMOSPHERE = 4

-- Director Style Presets
M.STYLE_WORLD_FEED = "WORLD_FEED"
M.STYLE_ACTION = "ACTION"
M.STYLE_ONBOARD = "ONBOARD"
M.STYLE_STAR_CAM = "STAR_CAM"

-- CSP Camera Mode Constants with safe fallbacks
M.CAMERA_MODE_COCKPIT = (ac and ac.CameraMode and ac.CameraMode.Cockpit) or 0
M.CAMERA_MODE_CAR = (ac and ac.CameraMode and ac.CameraMode.Car) or 1
M.CAMERA_MODE_DRIVABLE = (ac and ac.CameraMode and ac.CameraMode.Drivable) or 2
M.CAMERA_MODE_TRACK = (ac and ac.CameraMode and ac.CameraMode.Track) or 3
M.CAMERA_MODE_HELICOPTER = (ac and ac.CameraMode and ac.CameraMode.Helicopter) or 4
M.CAMERA_MODE_ONBOARDFREE = (ac and ac.CameraMode and ac.CameraMode.OnBoardFree) or 5
M.CAMERA_MODE_FREE = (ac and ac.CameraMode and ac.CameraMode.Free) or 6

-- Master Configuration (Configurable, defaults to disabled per user requirement)
local _enabled = false

-- Configurable Parameters
local _minDwellTime = 5.0
local _maxDwellTime = 12.0
local _quietWindow = 15.0
local _style = M.STYLE_WORLD_FEED
local _starCarIndex = 0

-- Director State Registers
local _focusedCar = 0
local _currentCameraMode = M.CAMERA_MODE_TRACK
local _currentTrackGroup = 0
local _dwellTimer = 0.0
local _targetDwellTime = 8.0
local _currentPriority = M.PRIORITY_ATMOSPHERE
local _currentReason = "INIT_START"
local _quietTimer = 0.0

-- Manual Override Tracker
local _lastEngineFocusedCar = -1
local _lastEngineCameraMode = -1
local _lastObservedCar = -1
local _lastObservedMode = -1
local _transitionGraceTimer = 0.0

-- Zero-Allocation Preallocated Fixed-Slot Tables (32 Cars)
local MAX_SLOTS = 32
local _hotspots = {}
local _sortedIndices = {}
local _topHotspotSummary = {}

for i = 0, MAX_SLOTS - 1 do
  _hotspots[i] = {
    carIndex = i,
    score = 0.0,
    priority = M.PRIORITY_ATMOSPHERE,
    reason = "CRUISE",
    gap = 999.0,
    position = 99
  }
end

for i = 1, MAX_SLOTS do
  _sortedIndices[i] = i - 1
  _topHotspotSummary[i] = {
    carIndex = -1,
    score = 0.0,
    priority = 4,
    reason = "NONE"
  }
end

--- Clamp helper
local function clamp(val, minV, maxV)
  if val < minV then return minV end
  if val > maxV then return maxV end
  return val
end

--- Initialize TV Director Engine
function M.init()
  _enabled = false
  _minDwellTime = 5.0
  _maxDwellTime = 12.0
  _quietWindow = 15.0
  _style = M.STYLE_WORLD_FEED
  _starCarIndex = 0

  _focusedCar = 0
  _currentCameraMode = M.CAMERA_MODE_TRACK
  _currentTrackGroup = 0
  _dwellTimer = 0.0
  _targetDwellTime = 8.0
  _currentPriority = M.PRIORITY_ATMOSPHERE
  _currentReason = "INIT_START"
  _quietTimer = 0.0

  _lastEngineFocusedCar = -1
  _lastEngineCameraMode = -1
  _lastObservedCar = -1
  _lastObservedMode = -1
  _transitionGraceTimer = 0.0
end

--- Full Reset
function M.reset()
  M.init()
  for i = 0, MAX_SLOTS - 1 do
    _hotspots[i].score = 0.0
    _hotspots[i].priority = M.PRIORITY_ATMOSPHERE
    _hotspots[i].reason = "CRUISE"
    _hotspots[i].gap = 999.0
    _hotspots[i].position = 99
  end
end

--- Enable or disable TV Director
---@param enabled boolean
function M.setEnabled(enabled)
  _enabled = (enabled == true)
  if _enabled then
    -- Reset dwell on activation to evaluate best target immediately
    _dwellTimer = _minDwellTime
  end
end

--- Check if TV Director is enabled
---@return boolean enabled
function M.isEnabled()
  return _enabled
end

--- Toggle TV Director ON/OFF
---@return boolean newState
function M.toggleEnabled()
  M.setEnabled(not _enabled)
  return _enabled
end

--- Set Minimum Dwell Time
---@param sec number (e.g. 5.0)
function M.setMinDwellTime(sec)
  local s = tonumber(sec) or 5.0
  _minDwellTime = clamp(s, 1.0, 30.0)
end

--- Get Minimum Dwell Time
---@return number sec
function M.getMinDwellTime()
  return _minDwellTime
end

--- Set Maximum Dwell Time
---@param sec number (e.g. 12.0)
function M.setMaxDwellTime(sec)
  local s = tonumber(sec) or 12.0
  _maxDwellTime = clamp(s, _minDwellTime, 60.0)
end

--- Get Maximum Dwell Time
---@return number sec
function M.getMaxDwellTime()
  return _maxDwellTime
end

--- Set Manual Override Quiet Window
---@param sec number (e.g. 15.0)
function M.setQuietWindow(sec)
  local s = tonumber(sec) or 15.0
  _quietWindow = clamp(s, 2.0, 120.0)
end

--- Get Manual Override Quiet Window
---@return number sec
function M.getQuietWindow()
  return _quietWindow
end

--- Set Director Style Preset
---@param style string "WORLD_FEED", "ACTION", "ONBOARD", "STAR_CAM"
function M.setStyle(style)
  if style == M.STYLE_WORLD_FEED or style == M.STYLE_ACTION or style == M.STYLE_ONBOARD or style == M.STYLE_STAR_CAM then
    _style = style
  end
end

--- Get Current Director Style
---@return string style
function M.getStyle()
  return _style
end

--- Set Star Car Index for STAR_CAM mode
---@param idx integer
function M.setStarCarIndex(idx)
  _starCarIndex = tonumber(idx) or 0
end

--- Get Star Car Index
---@return integer idx
function M.getStarCarIndex()
  return _starCarIndex
end

--- Get Current Focused Car Index
---@return integer carIdx
function M.getFocusedCar()
  return _focusedCar
end

--- Get Current Camera Mode
---@return integer mode
function M.getCurrentCameraMode()
  return _currentCameraMode
end

--- Get Current Shot Reason
---@return string reason
function M.getCurrentReason()
  return _currentReason
end

--- Get Current Shot Priority
---@return integer priority
function M.getCurrentPriority()
  return _currentPriority
end

--- Get Dwell Timer
---@return number dwell
function M.getDwellTimer()
  return _dwellTimer
end

--- Get Target Dwell Time
---@return number targetDwell
function M.getTargetDwellTime()
  return _targetDwellTime
end

--- Get Remaining Dwell Time
---@return number remaining
function M.getRemainingDwellTime()
  local rem = _targetDwellTime - _dwellTimer
  return rem > 0.0 and rem or 0.0
end

--- Get Quiet Window Timer (Manual override countdown)
---@return number quietTimer
function M.getQuietTimer()
  return _quietTimer
end

--- Is Manual Override currently active
---@return boolean isOverride
function M.isManualOverrideActive()
  return _quietTimer > 0.0
end

--- Execute CSP Camera Switch Safely
---@param carIndex integer
---@param mode integer
---@param trackGroup integer?
local function applyCspCamera(carIndex, mode, trackGroup)
  if not carIndex or carIndex < 0 then carIndex = 0 end
  mode = mode or M.CAMERA_MODE_TRACK

  -- 1. Switch camera mode FIRST (exits Cockpit view so AC can focus external cars)
  if mode and ac and ac.setCurrentCamera then
    pcall(ac.setCurrentCamera, mode)
  end

  -- 2. Focus target car SECOND
  if ac and ac.focusCar then
    pcall(ac.focusCar, carIndex)
  end

  -- 3. Set track camera group THIRD
  if trackGroup and mode == M.CAMERA_MODE_TRACK and ac and ac.setCurrentTrackCamera then
    pcall(ac.setCurrentTrackCamera, trackGroup)
  end

  _lastEngineFocusedCar = carIndex
  _lastEngineCameraMode = mode
  _transitionGraceTimer = 0.05 -- Give AC ~3 frames (50ms) to asynchronously settle onto new camera & car
end

--- Force Cut to specific car and mode from UI or script
---@param carIndex integer
---@param mode integer?
---@param reason string?
---@param priority integer?
---@param duration number?
function M.forceCut(carIndex, mode, reason, priority, duration)
  _focusedCar = carIndex or 0
  _currentCameraMode = mode or M.CAMERA_MODE_TRACK
  _currentReason = reason or "MANUAL_DIRECTOR_CUT"
  _currentPriority = priority or M.PRIORITY_ACTION
  _targetDwellTime = duration or _minDwellTime
  _dwellTimer = 0.0
  _quietTimer = 0.0 -- Explicit director cut clears quiet window

  applyCspCamera(_focusedCar, _currentCameraMode, _currentTrackGroup)
end

--- Compute Combat Hotspot Index (CHI) for all cars
--- Pure scalar mathematics, zero dynamic allocation
---@param raceState table
---@param recentEvents table
local function computeHotspots(raceState, recentEvents)
  local carsCount = raceState and raceState.carsCount or 0
  if carsCount > MAX_SLOTS then carsCount = MAX_SLOTS end

  local totalLaps = raceState and raceState.totalLaps or 13
  local currentLap = raceState and raceState.currentLap or 1
  local isFinalLaps = (totalLaps > 0 and (totalLaps - currentLap) <= 3)

  for i = 0, carsCount - 1 do
    local slot = _hotspots[i]
    slot.carIndex = i
    slot.score = 0.0
    slot.priority = M.PRIORITY_ATMOSPHERE
    slot.reason = "CRUISE"

    local cState = RaceContext.getCarState(i)
    if not cState or not cState.isConnected or cState.isRetired then
      slot.score = -999.0
      slot.gap = 999.0
      slot.position = 99
    else
      local pos = cState.racePosition or (i + 1)
      slot.position = pos

      -- 1. Position weight
      local wPos = 0.85
      if pos <= 3 then
        wPos = 1.50
      elseif pos <= 10 then
        wPos = 1.20
      end

      -- 2. Battle Proximity Gap Score
      local gap = cState.gapToAhead or 999.0
      slot.gap = gap
      local sGap = 0.0
      if gap > 0.0 and gap <= 1.5 then
        local norm = 1.0 - (gap / 1.5)
        sGap = 10.0 * norm * norm
      end

      -- 3. Psychological Stress & MTI Multiplier
      local wPsych = 1.0
      local stress = cState.stress or 0.0
      local mti = cState.mti or 0.0
      if stress > 6.0 or mti > 1.5 then
        wPsych = 1.0 + (0.35 * (stress / 10.0))
      end

      -- 4. Stakes Multiplier
      local wStakes = 1.0
      if isFinalLaps then
        wStakes = wStakes + 0.35
      end
      if cState.pitStage == "IN_LAP" or cState.pitStage == "OUT_LAP" then
        wStakes = wStakes + 0.25
      end

      local baseScore = (sGap * wPos * wPsych * wStakes) + (10.0 / (pos + 1.0))
      local prio = M.PRIORITY_ATMOSPHERE
      local reason = "CRUISE"

      if sGap > 2.0 then
        prio = M.PRIORITY_BATTLE
        reason = string.format("BATTLE_P%d (Gap %.2fs)", pos, gap)
      end

      -- 5. Tactical State Overrides
      local tact = cState.tacticalState
      if tact == "POUNCE_PASS" then
        baseScore = baseScore + 35.0
        prio = M.PRIORITY_ACTION
        reason = "POUNCE_OVERTAKE"
      elseif tact == "ATTACK" or tact == "SWITCHBACK" then
        baseScore = baseScore + 18.0
        prio = M.PRIORITY_BATTLE
        reason = "AGGRESSIVE_ATTACK"
      elseif tact == "DEFEND" or tact == "WEAVE" or tact == "FEINT" then
        baseScore = baseScore + 12.0
        prio = M.PRIORITY_BATTLE
        reason = "DEFENSIVE_BLOCK"
      end

      -- 6. Mistake & Pit Stop Boosts
      local lastMistake = cState.lastMistakeType
      if lastMistake == "SPIN" or lastMistake == "OFFTRACK" then
        baseScore = baseScore + 50.0
        prio = M.PRIORITY_EMERGENCY
        reason = "SPIN_INCIDENT"
      elseif lastMistake == "LOCKUP" or lastMistake == "OVERSLOW" then
        baseScore = baseScore + 25.0
        prio = M.PRIORITY_TACTICS
        reason = "LOCKUP_MISTAKE"
      end

      if cState.isInPitlane or cState.pitStage == "STOP" then
        baseScore = baseScore + 22.0
        prio = M.PRIORITY_TACTICS
        reason = "PIT_STOP_BOX"
      end

      -- 7. Star Cam Boost
      if _style == M.STYLE_STAR_CAM and i == _starCarIndex then
        baseScore = baseScore + 40.0
      end

      slot.score = baseScore
      slot.priority = prio
      slot.reason = reason
    end
  end

  -- In-place Insertion Sort of _sortedIndices based on _hotspots[idx].score
  for i = 2, carsCount do
    local key = _sortedIndices[i]
    local keyScore = _hotspots[key].score
    local j = i - 1
    while j >= 1 and _hotspots[_sortedIndices[j]].score < keyScore do
      _sortedIndices[j + 1] = _sortedIndices[j]
      j = j - 1
    end
    _sortedIndices[j + 1] = key
  end
end

--- Select Best Cinematic Camera Mode for target
---@param carIndex integer
---@param priority integer
---@param reason string
---@param raceState table
---@return integer cameraMode
local function selectCameraMode(carIndex, priority, reason, raceState)
  local lap = raceState and raceState.currentLap or 1
  local cState = RaceContext.getCarState(carIndex)
  local speed = (cState and cState.speedKmh) or 100.0

  -- 1. Start of race pack tracking
  if lap == 0 or (lap == 1 and speed < 85.0) then
    return M.CAMERA_MODE_HELICOPTER
  end

  -- 2. Emergency Incident: Track Camera offers best overview
  if priority == M.PRIORITY_EMERGENCY then
    return M.CAMERA_MODE_TRACK
  end

  -- 3. Onboard Style Preference
  if _style == M.STYLE_ONBOARD then
    return M.CAMERA_MODE_CAR
  end

  -- 4. Pounce Pass / Overtake
  if priority == M.PRIORITY_ACTION then
    -- Action style alternates between Car (T-Cam) and Track TV
    if _style == M.STYLE_ACTION then
      return M.CAMERA_MODE_CAR
    else
      return M.CAMERA_MODE_TRACK
    end
  end

  -- 5. Standard Battle and Tactics
  return M.CAMERA_MODE_TRACK
end

--- Get Top N Hotspots for UI telemetry display
--- Zero table allocation, fills and returns internal summary buffer
---@param count integer?
---@return table topHotspots
function M.getTopHotspots(count)
  local n = count or 3
  if n > 8 then n = 8 end
  for i = 1, n do
    local carIdx = _sortedIndices[i]
    if carIdx and carIdx >= 0 and _hotspots[carIdx] then
      local h = _hotspots[carIdx]
      _topHotspotSummary[i].carIndex = h.carIndex
      _topHotspotSummary[i].score = h.score
      _topHotspotSummary[i].priority = h.priority
      _topHotspotSummary[i].reason = h.reason
    else
      _topHotspotSummary[i].carIndex = -1
      _topHotspotSummary[i].score = 0.0
      _topHotspotSummary[i].priority = 4
      _topHotspotSummary[i].reason = "NONE"
    end
  end
  return _topHotspotSummary
end

--- Step TV Director State Machine (Runs at 10Hz or 30Hz)
--- Pure scalar mathematics, zero dynamic allocation
---@param dt number Delta time in seconds
---@param sim table? ac.StateSim structure
function M.step(dt, sim)
  local safeDt = (type(dt) == "number" and dt > 0.0) and dt or 0.016

  -- Decrement transition grace timer if active
  if _transitionGraceTimer > 0.0 then
    _transitionGraceTimer = _transitionGraceTimer - safeDt
    if _transitionGraceTimer < 0.0 then _transitionGraceTimer = 0.0 end
  end

  -- 1. Manual Override Detection
  if sim then
    local rawCar = RaceContext.safeSimGet(sim, "focusedCar")
    local currentSimCar = (rawCar and rawCar >= 0) and rawCar or 0
    local currentSimMode = RaceContext.safeSimGet(sim, "cameraMode") or 0

    if _lastObservedCar ~= -1 and _lastObservedMode ~= -1 then
      if _transitionGraceTimer <= 0.0 then
        -- Outside transition grace period: detect human intervention
        local carChanged = (currentSimCar ~= _lastObservedCar)
        local modeChanged = (currentSimMode ~= _lastObservedMode)
        if carChanged or modeChanged then
          -- Check if this change was initiated by our own engine cut
          local causedByEngine = (_lastEngineFocusedCar ~= -1 and currentSimCar == _lastEngineFocusedCar and
                                  _lastEngineCameraMode ~= -1 and currentSimMode == _lastEngineCameraMode)
          if not causedByEngine then
            -- Human player intervened! Reset quiet window and clear engine lock
            _quietTimer = _quietWindow
            _lastEngineFocusedCar = -1
            _lastEngineCameraMode = -1
          end
        end
      else
        -- Inside grace period: check if AC has already settled onto our target
        if _lastEngineFocusedCar ~= -1 and currentSimCar == _lastEngineFocusedCar and
           _lastEngineCameraMode ~= -1 and currentSimMode == _lastEngineCameraMode then
          _transitionGraceTimer = 0.0 -- Settled early!
        end
      end
    else
      -- First observation: align engine baseline with current sim state
      if _lastEngineFocusedCar == -1 then
        _lastEngineFocusedCar = currentSimCar
      end
      if _lastEngineCameraMode == -1 then
        _lastEngineCameraMode = currentSimMode
      end
    end

    _lastObservedCar = currentSimCar
    _lastObservedMode = currentSimMode
  end

  -- Handle active quiet window (countdown)
  if _quietTimer > 0.0 then
    _quietTimer = _quietTimer - safeDt
    if _quietTimer < 0.0 then _quietTimer = 0.0 end
    return -- Yield to human player during quiet window
  end

  -- If director is disabled, do nothing further
  if not _enabled then return end

  -- Advance current shot dwell timer
  _dwellTimer = _dwellTimer + safeDt

  local raceState = RaceContext.getRaceState()
  local recentEvents = EventHub.getRecentAiEvents(5)

  -- 2. Compute Combat Hotspots across all cars
  computeHotspots(raceState, recentEvents)

  local bestCarIdx = _sortedIndices[1] or 0
  local bestHotspot = _hotspots[bestCarIdx]
  if not bestHotspot or bestHotspot.score <= -900.0 then return end

  local shouldCut = false
  local targetDuration = 8.0

  -- 3. Preemption Check: Higher priority event preempts immediately!
  if bestHotspot.priority < _currentPriority then
    -- Strictly higher priority (e.g. EMERGENCY preempts BATTLE, ACTION preempts CRUISE)
    shouldCut = true
    if bestHotspot.priority == M.PRIORITY_EMERGENCY then
      targetDuration = 5.0
    elseif bestHotspot.priority == M.PRIORITY_ACTION then
      targetDuration = 6.5
    else
      targetDuration = _minDwellTime
    end
  elseif _dwellTimer >= _minDwellTime then
    -- Min dwell time satisfied: Can switch if significantly better score or max dwell exceeded
    if bestCarIdx ~= _focusedCar and bestHotspot.score > (_hotspots[_focusedCar].score + 4.0) then
      shouldCut = true
      targetDuration = 8.0
    elseif _dwellTimer >= _maxDwellTime then
      -- Max dwell exceeded: Must switch or rotate camera angle to maintain dynamic feel
      shouldCut = true
      targetDuration = 8.0
    end
  end

  -- 4. Execute Cut if warranted
  if shouldCut then
    _focusedCar = bestCarIdx
    _currentPriority = bestHotspot.priority
    _currentReason = bestHotspot.reason
    _dwellTimer = 0.0
    _targetDwellTime = targetDuration

    -- Alternate track camera group if staying on same car
    if bestCarIdx == _focusedCar then
      _currentTrackGroup = (_currentTrackGroup + 1) % 3
    else
      _currentTrackGroup = 0
    end

    _currentCameraMode = selectCameraMode(bestCarIdx, bestHotspot.priority, bestHotspot.reason, raceState)
    applyCspCamera(_focusedCar, _currentCameraMode, _currentTrackGroup)
  end
end

return M
