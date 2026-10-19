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
local BattleTracker = require("lib/driver/BattleTracker")

local M = {}

-- Priority Constants (0 is highest, 4 is lowest)
M.PRIORITY_EMERGENCY = 0
M.PRIORITY_ACTION = 1
M.PRIORITY_TACTICS = 2
M.PRIORITY_BATTLE = 3
M.PRIORITY_ATMOSPHERE = 4

-- Tactical Situation Codes (Contextual Perspective Mappings)
M.SITUATION_WORLD_FEED = "WORLD_FEED"
M.SITUATION_STRAIN_COCKPIT = "STRAIN_COCKPIT"
M.SITUATION_ATTACK_NOSE = "ATTACK_NOSE"
M.SITUATION_DEFEND_REAR = "DEFEND_REAR"
M.SITUATION_SIDE_HELICOPTER = "SIDE_HELICOPTER"
M.SITUATION_MISTAKE_ACTION = "MISTAKE_ACTION"
M.SITUATION_PIT_UNDERCUT = "PIT_UNDERCUT"

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

-- CSP Drivable Sub-Camera Constants
M.DRIVABLE_CHASE = (ac and ac.DrivableCamera and ac.DrivableCamera.Chase) or 0
M.DRIVABLE_CHASE2 = (ac and ac.DrivableCamera and ac.DrivableCamera.Chase2) or 1
M.DRIVABLE_BONNET = (ac and ac.DrivableCamera and ac.DrivableCamera.Bonnet) or 2
M.DRIVABLE_BUMPER = (ac and ac.DrivableCamera and ac.DrivableCamera.Bumper) or 3
M.DRIVABLE_DASH = (ac and ac.DrivableCamera and ac.DrivableCamera.Dash) or 4

-- Master Configuration (Configurable, defaults to disabled per user requirement)
local _enabled = false

-- Configurable Parameters
local _minDwellTime = 5.0
local _maxDwellTime = 12.0
local _quietWindow = 15.0
local _style = M.STYLE_WORLD_FEED
local _starCarIndex = 0

-- Contextual Perspective Preferences (Defaults to true for full cinematic immersion)
local _prefStrainCockpit = true
local _prefAttackNose = true
local _prefDefendRear = true
local _prefSideHelicopter = true
local _prefStorytelling = true

-- Director State Registers
local _focusedCar = 0
local _currentCameraMode = M.CAMERA_MODE_TRACK
local _currentSubMode = 0
local _currentSituation = M.SITUATION_WORLD_FEED
local _currentDuelRival = -1
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
    position = 99,
    situation = M.SITUATION_WORLD_FEED,
    cameraMode = M.CAMERA_MODE_TRACK,
    subMode = 0,
    duelRival = -1,
    targetDuration = 8.0
  }
end

for i = 1, MAX_SLOTS do
  _sortedIndices[i] = i - 1
  _topHotspotSummary[i] = {
    carIndex = -1,
    score = 0.0,
    priority = 4,
    reason = "NONE",
    situation = "WORLD_FEED",
    cameraMode = 3,
    subMode = 0,
    duelRival = -1
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

  _prefStrainCockpit = true
  _prefAttackNose = true
  _prefDefendRear = true
  _prefSideHelicopter = true
  _prefStorytelling = true

  _focusedCar = 0
  _currentCameraMode = M.CAMERA_MODE_TRACK
  _currentSubMode = 0
  _currentSituation = M.SITUATION_WORLD_FEED
  _currentDuelRival = -1
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
    _hotspots[i].situation = M.SITUATION_WORLD_FEED
    _hotspots[i].cameraMode = M.CAMERA_MODE_TRACK
    _hotspots[i].subMode = 0
    _hotspots[i].duelRival = -1
    _hotspots[i].targetDuration = 8.0
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

--- Get Current Sub-Camera Mode
---@return integer subMode
function M.getCurrentSubMode()
  return _currentSubMode
end

--- Get Current Situation Code
---@return string situation
function M.getCurrentSituation()
  return _currentSituation
end

--- Get Current Duel Rival Index (-1 if not in active duel)
---@return integer rivalIdx
function M.getCurrentDuelRival()
  return _currentDuelRival
end

--- Contextual Perspective Preferences Getters & Setters
function M.getPrefStrainCockpit() return _prefStrainCockpit end
function M.setPrefStrainCockpit(val) _prefStrainCockpit = (val == true) end
function M.togglePrefStrainCockpit() _prefStrainCockpit = not _prefStrainCockpit return _prefStrainCockpit end

function M.getPrefAttackNose() return _prefAttackNose end
function M.setPrefAttackNose(val) _prefAttackNose = (val == true) end
function M.togglePrefAttackNose() _prefAttackNose = not _prefAttackNose return _prefAttackNose end

function M.getPrefDefendRear() return _prefDefendRear end
function M.setPrefDefendRear(val) _prefDefendRear = (val == true) end
function M.togglePrefDefendRear() _prefDefendRear = not _prefDefendRear return _prefDefendRear end

function M.getPrefSideHelicopter() return _prefSideHelicopter end
function M.setPrefSideHelicopter(val) _prefSideHelicopter = (val == true) end
function M.togglePrefSideHelicopter() _prefSideHelicopter = not _prefSideHelicopter return _prefSideHelicopter end

function M.getPrefStorytelling() return _prefStorytelling end
function M.setPrefStorytelling(val) _prefStorytelling = (val == true) end
function M.togglePrefStorytelling() _prefStorytelling = not _prefStorytelling return _prefStorytelling end

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
---@param mode integer?
---@param subMode integer?
---@param trackGroup integer?
local function applyCspCamera(carIndex, mode, subMode, trackGroup)
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

  -- 3. Set sub-camera mode or track camera group THIRD
  if mode == M.CAMERA_MODE_DRIVABLE and subMode and ac and ac.setCurrentDrivableCamera then
    pcall(ac.setCurrentDrivableCamera, subMode)
  elseif mode == M.CAMERA_MODE_CAR and subMode and ac and ac.setCurrentCarCamera then
    pcall(ac.setCurrentCarCamera, subMode)
  elseif mode == M.CAMERA_MODE_TRACK and trackGroup and ac and ac.setCurrentTrackCamera then
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
---@param subMode integer?
---@param situation string?
---@param duelRival integer?
function M.forceCut(carIndex, mode, reason, priority, duration, subMode, situation, duelRival)
  _focusedCar = carIndex or 0
  _currentCameraMode = mode or M.CAMERA_MODE_TRACK
  _currentSubMode = subMode or 0
  _currentSituation = situation or M.SITUATION_WORLD_FEED
  _currentDuelRival = duelRival or -1
  _currentReason = reason or "MANUAL_DIRECTOR_CUT"
  _currentPriority = priority or M.PRIORITY_ACTION
  _targetDwellTime = duration or _minDwellTime
  _dwellTimer = 0.0
  _quietTimer = 0.0 -- Explicit director cut clears quiet window

  applyCspCamera(_focusedCar, _currentCameraMode, _currentSubMode, _currentTrackGroup)
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

  -- Query hottest active duel pair from BattleTracker
  local hotDuel = BattleTracker.getHottestDuel and BattleTracker.getHottestDuel()
  local hotCarA = (hotDuel and hotDuel.active and hotDuel.carA) or -1
  local hotCarB = (hotDuel and hotDuel.active and hotDuel.carB) or -1

  for i = 0, carsCount - 1 do
    local slot = _hotspots[i]
    slot.carIndex = i
    slot.score = 0.0
    slot.priority = M.PRIORITY_ATMOSPHERE
    slot.reason = "CRUISE"
    slot.situation = M.SITUATION_WORLD_FEED
    slot.cameraMode = M.CAMERA_MODE_TRACK
    slot.subMode = 0
    slot.duelRival = -1
    slot.targetDuration = 8.0

    local cState = RaceContext.getCarState(i)
    if not cState or not cState.isConnected or cState.isRetired then
      slot.score = -999.0
      slot.gap = 999.0
      slot.position = 99
    else
      local pos = cState.racePosition or (i + 1)
      slot.position = pos

      local aheadIdx, aheadDist, behindIdx, behindDist = RaceContext.getNeighbors(i)

      -- 1. Position weight
      local wPos = 0.85
      if pos <= 3 then
        wPos = 1.50
      elseif pos <= 10 then
        wPos = 1.20
      end

      -- 2. Battle Proximity Gap Score (with physical distance fallback)
      local gap = cState.gapAheadSec or cState.gapToAhead or 999.0
      local gapBehind = cState.gapBehindSec or 999.0
      if gap >= 900.0 and aheadDist > 0.0 and aheadDist < 50.0 then
        -- Synthesize proxy gap from physical distance if time delta not yet converged
        local speedMs = math.max(10.0, (cState.speedKmh or 100.0) / 3.6)
        gap = aheadDist / speedMs
      end
      if gapBehind >= 900.0 and behindDist > 0.0 and behindDist < 50.0 then
        local speedMs = math.max(10.0, (cState.speedKmh or 100.0) / 3.6)
        gapBehind = behindDist / speedMs
      end
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
      local sit = M.SITUATION_WORLD_FEED
      local camMode = (_style == M.STYLE_ONBOARD) and M.CAMERA_MODE_CAR or M.CAMERA_MODE_TRACK
      local subMode = 0
      local rivalIdx = -1
      local dur = 8.0

      local tact = cState.tacticalState
      local skill = cState.activeSkill
      local lastMistake = cState.lastMistakeType

      -- 5. Contextual Perspective & Tactical Situation Resolution
      if lastMistake == "SPIN" or lastMistake == "OFFTRACK" or tact == "MISTAKE" then
        sit = M.SITUATION_MISTAKE_ACTION
        prio = M.PRIORITY_EMERGENCY
        reason = "SPIN_INCIDENT"
        camMode = M.CAMERA_MODE_TRACK
        subMode = 0
        dur = 5.0
        baseScore = baseScore + 60.0
      elseif lastMistake == "LOCKUP" or lastMistake == "MISSED_APEX" or lastMistake == "TRAIL_UNDERSTEER" then
        sit = M.SITUATION_MISTAKE_ACTION
        prio = M.PRIORITY_ACTION
        reason = "LOCKUP_MISTAKE"
        camMode = M.CAMERA_MODE_TRACK
        subMode = 0
        dur = 5.5
        baseScore = baseScore + 30.0
      elseif _prefSideHelicopter and ((aheadDist > 0.1 and aheadDist < 4.2) or (behindDist > 0.1 and behindDist < 4.2)) and (cState.speedKmh or 0) > 35.0 and (tact == "OVERTAKING" or tact == "ATTACK" or skill == "POUNCE_PASS" or gap < 0.25 or gapBehind < 0.25) then
        -- Dual Side-by-Side Corner Apex Battle (Helicopter Aerial View)
        sit = M.SITUATION_SIDE_HELICOPTER
        prio = M.PRIORITY_ACTION
        reason = "SIDE_BY_SIDE_DUEL"
        camMode = M.CAMERA_MODE_HELICOPTER
        subMode = 0
        rivalIdx = (aheadDist < behindDist) and aheadIdx or behindIdx
        dur = 6.0
        baseScore = baseScore + 42.0
      elseif _prefAttackNose and (skill == "POUNCE_PASS" or skill == "DIVEBOMB" or tact == "POUNCE_PASS" or (tact == "ATTACK" and aheadDist < 16.0 and (cState.gapAheadSec or 999.0) < 0.75)) then
        -- Attacker Front Bumper / Nose Cam Charging into Apex
        sit = M.SITUATION_ATTACK_NOSE
        prio = M.PRIORITY_ACTION
        reason = "ATTACK_NOSE_CAM"
        camMode = M.CAMERA_MODE_DRIVABLE
        subMode = M.DRIVABLE_BUMPER
        rivalIdx = aheadIdx
        dur = 5.5
        baseScore = baseScore + 38.0
      elseif _prefStrainCockpit and (stress >= 6.5 or mti >= 1.6) and (behindDist < 20.0 or gapBehind < 1.0) then
        -- High Psychological Strain Cockpit / Dash Micro-correction View
        sit = M.SITUATION_STRAIN_COCKPIT
        prio = M.PRIORITY_BATTLE
        reason = "PSYCHOLOGICAL_STRAIN"
        camMode = M.CAMERA_MODE_DRIVABLE
        subMode = M.DRIVABLE_DASH
        rivalIdx = behindIdx
        dur = 5.5
        baseScore = baseScore + 36.0
      elseif _prefDefendRear and (skill == "DEFENSIVE_COVER" or skill == "WEAVING_DEFENSE" or tact == "DEFEND" or (tact == "DEFENDING" and behindDist < 16.0)) then
        -- Defender Rear Mirror / Chase Dual-Car Framing View
        sit = M.SITUATION_DEFEND_REAR
        prio = M.PRIORITY_BATTLE
        reason = "DEFENSIVE_REAR_MIRROR"
        camMode = M.CAMERA_MODE_DRIVABLE
        subMode = M.DRIVABLE_CHASE
        rivalIdx = behindIdx
        dur = 6.0
        baseScore = baseScore + 26.0
      elseif cState.pitState == "RELEASED" or (cState.isInPitlane and (cState.speedKmh or 0) > 55.0) then
        sit = M.SITUATION_PIT_UNDERCUT
        prio = M.PRIORITY_TACTICS
        reason = "PIT_EXIT_UNDERCUT"
        camMode = M.CAMERA_MODE_TRACK
        subMode = 0
        dur = 6.5
        baseScore = baseScore + 24.0
      elseif cState.isInPitlane or cState.pitStage == "STOP" then
        sit = M.SITUATION_WORLD_FEED
        prio = M.PRIORITY_TACTICS
        reason = "PIT_STOP_BOX"
        camMode = M.CAMERA_MODE_TRACK
        subMode = 0
        dur = 7.0
        baseScore = baseScore + 22.0
      else
        sit = M.SITUATION_WORLD_FEED
        if sGap > 2.0 then
          prio = M.PRIORITY_BATTLE
          reason = string.format("BATTLE_P%d (Gap %.2fs)", pos, gap)
          camMode = (_style == M.STYLE_ONBOARD) and M.CAMERA_MODE_CAR or M.CAMERA_MODE_TRACK
          subMode = 0
          rivalIdx = aheadIdx
          dur = 8.0
        else
          prio = M.PRIORITY_ATMOSPHERE
          reason = "CRUISE"
          camMode = (_style == M.STYLE_ONBOARD) and M.CAMERA_MODE_CAR or M.CAMERA_MODE_TRACK
          subMode = 0
          dur = 9.0
        end
      end

      -- 5b. Tactical Skill Duel Priority Boost (Ensure intense AI battles get camera spotlight)
      if tact == "ATTACK" or tact == "OVERTAKING" or skill == "POUNCE_PASS" or skill == "SWITCHBACK" or skill == "LATE_BRAKE_DIVE" then
        baseScore = baseScore + 25.0
      elseif tact == "DEFEND" or tact == "DEFENDING" or skill == "GENTLE_SQUEEZE" or skill == "TOW_WEAVE" or skill == "DEFENSIVE_COVER" then
        baseScore = baseScore + 20.0
      end

      -- 5c. Hottest Active Duel Spotlight Bonus
      if i == hotCarA or i == hotCarB then
        baseScore = baseScore + 22.0
        if prio > M.PRIORITY_BATTLE then prio = M.PRIORITY_BATTLE end
        if rivalIdx < 0 then
          rivalIdx = (i == hotCarA) and hotCarB or hotCarA
        end
      end

      -- 5d. Player Cruise Bias Equalizer:
      -- If car 0 (human player) is in a pure cruise without close rival, reduce its base weight
      -- so active duels across the AI field receive prominent TV coverage
      if i == 0 and prio == M.PRIORITY_ATMOSPHERE and _style ~= M.STYLE_STAR_CAM then
        baseScore = baseScore * 0.5
      end

      -- 6. Narrative Coherence Bonus (Storytelling Arc)
      if _prefStorytelling and _currentDuelRival >= 0 then
        if (i == _focusedCar and rivalIdx == _currentDuelRival) or (i == _currentDuelRival and rivalIdx == _focusedCar) then
          -- Give ongoing battle a storyline retention bonus so director doesn't jump away mid-fight
          baseScore = baseScore + 18.0
        end
      end

      -- 7. Star Cam Boost
      if _style == M.STYLE_STAR_CAM and i == _starCarIndex then
        baseScore = baseScore + 40.0
      end

      slot.score = baseScore
      slot.priority = prio
      slot.reason = reason
      slot.situation = sit
      slot.cameraMode = camMode
      slot.subMode = subMode
      slot.duelRival = rivalIdx
      slot.targetDuration = dur
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
---@return integer cameraMode, integer subMode
local function selectCameraMode(carIndex, priority, reason, raceState)
  local slot = _hotspots[carIndex]
  if slot and slot.cameraMode then
    return slot.cameraMode, (slot.subMode or 0)
  end
  return M.CAMERA_MODE_TRACK, 0
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
      _topHotspotSummary[i].situation = h.situation or M.SITUATION_WORLD_FEED
      _topHotspotSummary[i].cameraMode = h.cameraMode or M.CAMERA_MODE_TRACK
      _topHotspotSummary[i].subMode = h.subMode or 0
      _topHotspotSummary[i].duelRival = h.duelRival or -1
    else
      _topHotspotSummary[i].carIndex = -1
      _topHotspotSummary[i].score = 0.0
      _topHotspotSummary[i].priority = 4
      _topHotspotSummary[i].reason = "NONE"
      _topHotspotSummary[i].situation = "NONE"
      _topHotspotSummary[i].cameraMode = M.CAMERA_MODE_TRACK
      _topHotspotSummary[i].subMode = 0
      _topHotspotSummary[i].duelRival = -1
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
  local targetDuration = bestHotspot.targetDuration or 8.0

  -- 3. Preemption Check: Higher priority event preempts immediately!
  if bestHotspot.priority < _currentPriority then
    -- Strictly higher priority (e.g. EMERGENCY preempts BATTLE, ACTION preempts CRUISE)
    shouldCut = true
    if bestHotspot.priority == M.PRIORITY_EMERGENCY then
      targetDuration = 5.0
    elseif bestHotspot.priority == M.PRIORITY_ACTION then
      targetDuration = 6.0
    else
      targetDuration = _minDwellTime
    end
  elseif _dwellTimer >= _minDwellTime then
    -- Min dwell time satisfied:
    -- Check if this is a perspective escalation inside an ongoing duel or on focused car
    local isOngoingDuel = (_currentDuelRival >= 0 and (bestHotspot.duelRival == _focusedCar or bestCarIdx == _currentDuelRival or (bestCarIdx == _focusedCar and bestHotspot.duelRival == _currentDuelRival)))
    local isSituationEvolved = (bestHotspot.situation ~= _currentSituation) and (isOngoingDuel or bestCarIdx == _focusedCar)

    if isSituationEvolved then
      -- Situation inside ongoing duel or focused car escalated (e.g. Approach -> Attack Nose or Side Helicopter)!
      shouldCut = true
    elseif bestCarIdx ~= _focusedCar and bestHotspot.score > (_hotspots[_focusedCar].score + 4.0) then
      shouldCut = true
    elseif _dwellTimer >= _maxDwellTime then
      -- Max dwell exceeded: Must switch or rotate camera angle to maintain dynamic feel
      shouldCut = true
    end
  end

  -- 4. Execute Cut if warranted
  if shouldCut then
    _focusedCar = bestCarIdx
    _currentPriority = bestHotspot.priority
    _currentReason = bestHotspot.reason
    _currentSituation = bestHotspot.situation
    _currentCameraMode = bestHotspot.cameraMode
    _currentSubMode = bestHotspot.subMode or 0
    _currentDuelRival = bestHotspot.duelRival or -1
    _dwellTimer = 0.0
    _targetDwellTime = targetDuration

    -- Alternate track camera group if staying on same car in track mode
    if bestCarIdx == _focusedCar and _currentCameraMode == M.CAMERA_MODE_TRACK then
      _currentTrackGroup = (_currentTrackGroup + 1) % 3
    else
      _currentTrackGroup = 0
    end

    applyCspCamera(_focusedCar, _currentCameraMode, _currentSubMode, _currentTrackGroup)
  end
end

return M
