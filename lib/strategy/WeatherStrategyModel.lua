--[[
  WeatherStrategyModel.lua
  Ultimate AI Grand Prix Pro: Dynamic Weather Perception & Wet Tyre Strategy Engine
  
  Responsibilities:
    1. CSP Rain & Track Surface Perception:
       - Reads rainIntensity and roadGrip via RaceContext.safeSimGet
       - Continuous 1Hz differential model for track water accumulation and drainage
    2. 3-Band Track Surface Classification:
       - BAND_DRY (Wetness < 0.20) -> Slicks (Soft / Medium / Hard)
       - BAND_INTER (0.20 <= Wetness < 0.60) -> Intermediate Rain Tyres
       - BAND_WET (Wetness >= 0.60) -> Full Wet Tyres
    3. Crossover Window & Net-Gain Pit Arbitration:
       - Computes tyre pace deficit delta (seconds/lap)
       - Triggers emergency pit stop if net time saved over remaining laps > 22.0s pit delta
    4. Driver Actuator Rain Adaptation:
       - Caution multiplier (up to 1.65x in heavy rain)
       - Lateral corridor clamp (tightened from 0.55 down to 0.22 to avoid slippery kerbs)
    5. Pure scalar mathematics, zero dynamic memory allocation
]]

local RaceContext = require("lib/core/RaceContext")

local M = {}

M.BAND_DRY = 1
M.BAND_INTER = 2
M.BAND_WET = 3

local _trackWetness = 0.0      -- 0.0 to 1.0
local _rainIntensity = 0.0     -- 0.0 to 1.0
local _roadGrip = 1.0          -- 0.0 to 1.0
local _activeBand = M.BAND_DRY

local RATE_ACCUMULATION = 0.05 -- Wetness gain per second at 1.0 rain intensity
local RATE_DRAINAGE = 0.015    -- Wetness drainage per second when rain stops

--- Update real-time weather conditions from sim state
---@param sim any ac.StateSim struct or mock
---@param dt number Delta time in seconds
function M.updateConditions(sim, dt)
  local rain = 0.0
  local grip = 1.0
  if sim then
    rain = RaceContext.safeSimGet(sim, "rainIntensity") or 0.0
    grip = RaceContext.safeSimGet(sim, "roadGrip") or 1.0
  end

  _rainIntensity = rain
  _roadGrip = grip

  -- Water depth differential accumulation / drainage
  local stepDt = (dt and dt > 0.0) and dt or 0.1
  if rain > 0.01 then
    _trackWetness = _trackWetness + (rain * RATE_ACCUMULATION * stepDt)
  else
    _trackWetness = _trackWetness - (RATE_DRAINAGE * stepDt)
  end

  if _trackWetness < 0.0 then _trackWetness = 0.0 end
  if _trackWetness > 1.0 then _trackWetness = 1.0 end

  -- Classify Track Band
  if _trackWetness < 0.20 then
    _activeBand = M.BAND_DRY
  elseif _trackWetness < 0.60 then
    _activeBand = M.BAND_INTER
  else
    _activeBand = M.BAND_WET
  end
end

--- Get current track surface wetness (0.0 to 1.0)
---@return number
function M.getTrackWetness()
  return _trackWetness
end

--- Manually set track wetness (for testing / simulated weather)
---@param wetness number
function M.setTrackWetness(wetness)
  local w = wetness or 0.0
  if w < 0.0 then w = 0.0 end
  if w > 1.0 then w = 1.0 end
  _trackWetness = w

  if _trackWetness < 0.20 then
    _activeBand = M.BAND_DRY
  elseif _trackWetness < 0.60 then
    _activeBand = M.BAND_INTER
  else
    _activeBand = M.BAND_WET
  end
end

--- Get current rain intensity (0.0 to 1.0)
---@return number
function M.getRainIntensity()
  return _rainIntensity
end

--- Get active track surface band
---@return integer M.BAND_DRY | M.BAND_INTER | M.BAND_WET
function M.getActiveBand()
  return _activeBand
end

--- Get semantic string for active track condition
---@return string "DRY" | "INTERMEDIATE" | "WET"
function M.getActiveBandName()
  if _activeBand == M.BAND_WET then
    return "WET"
  elseif _activeBand == M.BAND_INTER then
    return "INTERMEDIATE"
  end
  return "DRY"
end

--- Get optimal recommended tyre compound name for current surface
---@return string "Soft" | "Intermediate" | "Wet"
function M.getOptimalTyreCompound()
  if _activeBand == M.BAND_WET then
    return "Wet"
  elseif _activeBand == M.BAND_INTER then
    return "Intermediate"
  end
  return "Soft"
end

--- Check if specific compound is a rain tyre
---@param compoundName string?
---@return boolean isRainTyre, boolean isFullWet
function M.isRainTyre(compoundName)
  if not compoundName then return false, false end
  local lower = string.lower(compoundName)
  if string.find(lower, "wet") or string.find(lower, "heavy") then
    return true, true
  elseif string.find(lower, "inter") or string.find(lower, "rain") then
    return true, false
  end
  return false, false
end

--- Compute pace delta penalty (seconds lost per lap) for given tyre on current wetness
---@param compoundName string?
---@param wetness number? 0.0 to 1.0
---@return number pacePenaltySec
function M.getTyrePacePenalty(compoundName, wetness)
  local w = wetness or _trackWetness
  local isRain, isWet = M.isRainTyre(compoundName)

  if isWet then
    -- Full Wet Tyre: optimal at wetness >= 0.60; melts on dry (+20s)
    if w >= 0.60 then
      return 0.0
    elseif w >= 0.30 then
      return (0.60 - w) * 15.0 -- +0s ~ +4.5s
    else
      return 4.5 + (0.30 - w) * 50.0 -- +4.5s ~ +19.5s on dry
    end
  elseif isRain then
    -- Intermediate Tyre: optimal at 0.20 <= wetness < 0.60; suffers on dry (+9s) or heavy flooding (+15s)
    if w >= 0.20 and w < 0.60 then
      return 0.0
    elseif w < 0.20 then
      return (0.20 - w) * 45.0 -- up to +9s on dry
    else
      return (w - 0.60) * 35.0 -- up to +14s in heavy wet
    end
  else
    -- Dry Slick Tyres: optimal at wetness < 0.20; catastrophic time loss in rain
    if w < 0.20 then
      return w * 10.0 -- 0 ~ 2s
    elseif w < 0.60 then
      return 2.0 + (w - 0.20) * 40.0 -- up to +18s
    else
      return 18.0 + (w - 0.60) * 45.0 -- up to +36s
    end
  end
end

--- Evaluate if car needs an urgent pit stop for weather crossover
---@param currentCompound string?
---@param curLap integer
---@param totalLaps integer
---@return boolean shouldBox, string targetCompound, number netBenefitSec
function M.evaluateWeatherPit(currentCompound, curLap, totalLaps)
  local remLaps = (totalLaps and totalLaps > curLap) and (totalLaps - curLap) or 5
  if remLaps <= 1 then
    -- On the final lap, pitting costs 22s which cannot be recovered
    return false, "NONE", 0.0
  end

  local curPenalty = M.getTyrePacePenalty(currentCompound, _trackWetness)
  local targetCompound = M.getOptimalTyreCompound()
  local targetPenalty = M.getTyrePacePenalty(targetCompound, _trackWetness)

  local lapGain = curPenalty - targetPenalty
  local totalGain = lapGain * remLaps
  local PIT_STOP_LOSS_SEC = 22.0

  -- If remaining lap gains exceed pit stop loss, trigger crossover stop
  if totalGain > PIT_STOP_LOSS_SEC and lapGain > 2.5 then
    return true, targetCompound, totalGain - PIT_STOP_LOSS_SEC
  end

  return false, targetCompound, 0.0
end

--- Caution scaling multiplier for BehaviorActuator under rain
--- Increases caution up to 1.65x in heavy rain
---@return number
function M.getWeatherCautionMultiplier()
  return 1.0 + (_trackWetness * 0.65)
end

--- Lateral tactical corridor clamp for BehaviorActuator under rain
--- Restricts corridor from 0.55 down to 0.22 on soaked tracks to prevent kerb spins
---@return number
function M.getWeatherCorridorClamp()
  local c = 0.55 - (_trackWetness * 0.33)
  if c < 0.22 then c = 0.22 end
  return c
end

--- Reset weather state
function M.reset()
  _trackWetness = 0.0
  _rainIntensity = 0.0
  _roadGrip = 1.0
  _activeBand = M.BAND_DRY
end

return M
