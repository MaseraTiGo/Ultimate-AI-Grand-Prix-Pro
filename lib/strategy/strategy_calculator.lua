--[[
  strategy_calculator.lua
  Deterministic pit strategy calculation, stint planning, risk classification,
  and 5-group F1 offset modeling.
  Pure computation domain logic without UI or direct hardware I/O.
]]

local M = {}

M.MAX_PIT_STOPS        = 8
M.MIN_VALID_TOTAL_LAPS = 1
M.MAX_VALID_TOTAL_LAPS = 999

M.DIST_WINDOW_PCT      = 0.75
M.DIST_TARGET_PCT      = 0.80
M.DIST_ESCALATE_PCT    = 0.95
M.DEFAULT_RESERVE_LAPS = 0.8

M.START_PENALTY_L         = 1.0
M.FINAL_MIN_EXTRA_LAPS    = 0.4
M.FINAL_TARGET_EXTRA_LAPS = 0.8

local function toNum(v, defaultVal)
  if v == nil then return defaultVal end
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n ~= nil then return n end
  end
  return defaultVal
end

local function isPositive(v)
  return type(v) == "number" and v > 0
end

local function clamp(v, lo, hi)
  if v == nil then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function roundN(v, places)
  if type(v) ~= "number" then return v end
  local mult = 10 ^ (places or 0)
  return math.floor(v * mult + 0.5) / mult
end

function M.normalizePlannedStops(rawStops)
  local n = toNum(rawStops, 0)
  n = math.floor(n + 0.5)
  if n < 0 then return 0 end
  if n > M.MAX_PIT_STOPS then return M.MAX_PIT_STOPS end
  return n
end

function M.computeStintCount(stopCount, totalLaps)
  local n = M.normalizePlannedStops(stopCount) + 1
  local laps = math.floor(toNum(totalLaps, 0) or 0)
  if laps > 0 and n > laps then
    n = laps
  end
  if n < 1 then n = 1 end
  return n
end

function M.splitTotalLapsAcrossStints(totalLaps, stintCount)
  local total = math.floor(toNum(totalLaps, 0) or 0)
  local count = math.floor(toNum(stintCount, 1) or 1)

  if total <= 0 then return {} end
  if count <= 0 then count = 1 end
  if count > total then count = total end

  local base = math.floor(total / count)
  local rem  = total % count
  local stints = {}

  for i = 1, count do
    local extra = (i <= rem) and 1 or 0
    stints[i] = base + extra
  end

  return stints
end

function M.computePitWindowForStint(stintIndex, startLap, endLap, stintLaps, totalLaps)
  local sLaps = math.max(1, math.floor(toNum(stintLaps, 1) or 1))
  local sLap  = math.floor(toNum(startLap, 1) or 1)
  local tLaps = math.floor(toNum(totalLaps, endLap) or endLap)

  local openOffset     = math.max(1, math.floor(sLaps * M.DIST_WINDOW_PCT + 0.5))
  local targetOffset   = math.max(openOffset, math.floor(sLaps * M.DIST_TARGET_PCT + 0.5))
  local escalateOffset = math.max(targetOffset, math.floor(sLaps * M.DIST_ESCALATE_PCT + 0.5))

  local openLap     = sLap + openOffset - 1
  local targetLap   = sLap + targetOffset - 1
  local escalateLap = sLap + escalateOffset - 1

  openLap     = clamp(openLap, sLap, tLaps)
  targetLap   = clamp(targetLap, openLap, tLaps)
  escalateLap = clamp(escalateLap, targetLap, tLaps)

  return {
    openLap     = openLap,
    targetLap   = targetLap,
    escalateLap = escalateLap,
    windowLaps  = math.max(1, escalateLap - openLap + 1)
  }
end

function M.computeStintFuelNeed(stintIndex, isFinalStint, stintLaps, fuelPerLap, reserveLaps)
  local laps = math.max(0, toNum(stintLaps, 0) or 0)
  local fpl  = toNum(fuelPerLap, nil)
  local res  = toNum(reserveLaps, M.DEFAULT_RESERVE_LAPS)

  if not isPositive(fpl) or laps <= 0 then
    return {
      usable         = false,
      fuelPerLap     = fpl,
      requiredLiters = nil,
      targetLiters   = nil,
      reserveLiters  = nil
    }
  end

  local requiredLiters = laps * fpl
  local reserveLiters  = res * fpl
  local targetLiters   = requiredLiters + reserveLiters

  if stintIndex == 1 then
    targetLiters = targetLiters + M.START_PENALTY_L
  end

  return {
    usable         = true,
    fuelPerLap     = roundN(fpl, 4),
    requiredLiters = roundN(requiredLiters, 3),
    targetLiters   = roundN(targetLiters, 3),
    reserveLiters  = roundN(reserveLiters, 3)
  }
end

function M.classifyStintRisk(requiredFuel, providedFuel)
  local required = toNum(requiredFuel, nil)
  local provided = toNum(providedFuel, nil)

  if not isPositive(required) or provided == nil then
    return { level = "UNKNOWN", label = "unknown", marginPct = nil }
  end

  local marginLiters = provided - required
  local marginPct    = (required > 0) and ((marginLiters / required) * 100.0) or 0

  if marginLiters < 0 then
    return { level = "HIGH", label = "high", marginPct = roundN(marginPct, 1) }
  elseif marginPct < 3.0 then
    return { level = "MED", label = "medium", marginPct = roundN(marginPct, 1) }
  else
    return { level = "LOW", label = "low", marginPct = roundN(marginPct, 1) }
  end
end

function M.buildPlanStints(totalLaps, stopCount, fuelPerLap)
  local requestedStops = M.normalizePlannedStops(stopCount)
  local stintCount     = M.computeStintCount(requestedStops, totalLaps)
  local stintLapCounts = M.splitTotalLapsAcrossStints(totalLaps, stintCount)
  local stints         = {}
  local currentStart   = 1

  for i = 1, #stintLapCounts do
    local laps         = stintLapCounts[i]
    local endLap       = currentStart + laps - 1
    local isFinalStint = (i == #stintLapCounts)

    local pitWindow = nil
    if not isFinalStint then
      pitWindow = M.computePitWindowForStint(i, currentStart, endLap, laps, totalLaps)
    end

    local fuel = M.computeStintFuelNeed(i, isFinalStint, laps, fuelPerLap, M.DEFAULT_RESERVE_LAPS)
    local risk = M.classifyStintRisk(fuel.requiredLiters, fuel.targetLiters)

    stints[i] = {
      index        = i,
      startLap     = currentStart,
      endLap       = endLap,
      stintLaps    = laps,
      isFinalStint = isFinalStint,
      pitWindow    = pitWindow,
      fuel         = fuel,
      risk         = risk
    }

    currentStart = endLap + 1
  end

  return stints, stintCount
end

function M.getF1PitSpreadGroupOffset(carIndex, playerIndex)
  local pIdx = tonumber(playerIndex) or 0
  local i = tonumber(carIndex) or 0

  if i == pIdx then
    return 0.0, "P"
  end

  local aiOrdinal = i
  if i > pIdx then
    aiOrdinal = i - 1
  end

  local group = aiOrdinal % 5
  if group == 0 then return -0.30, "A" end
  if group == 1 then return -0.15, "B" end
  if group == 2 then return  0.00, "C" end
  if group == 3 then return  0.15, "D" end
  return 0.30, "E"
end

function M.applyF1PitSpreadFuel(carIndex, playerIndex, baseLiters, fuelPerLap, activeMode)
  if not isPositive(baseLiters) or not isPositive(fuelPerLap) then
    return baseLiters
  end

  if activeMode ~= "f1_only" and activeMode ~= "independent" then
    return baseLiters
  end

  local lapOffset, group = M.getF1PitSpreadGroupOffset(carIndex, playerIndex)
  local adjusted = baseLiters + (lapOffset * fuelPerLap)

  local minLiters = baseLiters - (0.30 * fuelPerLap)
  local maxLiters = baseLiters + (0.30 * fuelPerLap)

  return clamp(adjusted, minLiters, maxLiters), lapOffset, group
end

function M.computeAutoPlannedStops(totalLaps, fuelPerLap, tankCapacity)
  local laps = toNum(totalLaps, nil)
  local fpl  = toNum(fuelPerLap, nil)
  local tank = toNum(tankCapacity, nil)

  if not isPositive(laps) then
    return nil, "Missing valid total laps"
  end

  if not isPositive(fpl) or not isPositive(tank) then
    if laps <= 15 then return 0, "Default sprint AUTO plan (short race)" end
    if laps <= 35 then return 1, "Default standard AUTO plan" end
    return 2, "Default endurance AUTO plan"
  end

  local usableTank = tank * 0.90
  local maxLapsPerStint = math.max(1, math.floor(usableTank / fpl))
  local neededStints = math.ceil(laps / maxLapsPerStint)
  local stops = math.max(0, math.min(M.MAX_PIT_STOPS, neededStints - 1))

  return stops, string.format("AUTO calculated (%d laps/stint)", maxLapsPerStint)
end

-- =========================================================================
-- Strategy Layer Dynamic Extension Attachments
-- =========================================================================

-- Dynamically loads strategy sub-modules relative to script location
local _subModules = {}
local function getSubModule(name)
  if _subModules[name] then return _subModules[name] end
  local currentDir = ac and ac.getFolder and ac.getFolder(ac.FolderID.AppData) or "."
  -- Attempt loadfile from relative path
  local tryPaths = {
    "AI Pit Control PRO/lib/strategy/" .. name .. ".lua",
    "AI Pit Control Lite PRO/lib/strategy/" .. name .. ".lua",
    "lib/strategy/" .. name .. ".lua",
    "apps/lua/AI Pit Control PRO/lib/strategy/" .. name .. ".lua",
    "apps/lua/AI Pit Control Lite PRO/lib/strategy/" .. name .. ".lua",
    "../lib/strategy/" .. name .. ".lua"
  }
  for _, p in ipairs(tryPaths) do
    local chunk = loadfile(p)
    if chunk then
      _subModules[name] = chunk()
      return _subModules[name]
    end
  end
  return nil
end

M.getSubModule = getSubModule

--[[
  recomputeStintWindowDynamic:
  Real-time dynamic adjustment of pit window for a specific car.
  Combines:
    - Fuel remaining (from dynamic fuel model)
    - Tyre degradation & pace loss
    - Traffic gaps (gap ahead, exit window)
    - Safety Car bonus
    - Driver Persona preferences
]]
function M.recomputeStintWindowDynamic(carRuntime, params)
  local fuelMod    = getSubModule("fuel_model")
  local tyreMod    = getSubModule("tyre_model")
  local trafficMod = getSubModule("traffic_model")
  local scMod      = getSubModule("safety_car")
  local pitMod     = getSubModule("pit_strategy")
  local personaMod = getSubModule("driver_persona")

  local curLap     = toNum(params.currentLap, 1)
  local baseWindow = params.basePitWindow or {}
  local baseTarget = toNum(baseWindow.targetLap, curLap + 5)
  local fuelLaps   = toNum(params.fuelLapsRemaining, 10.0)
  local persona    = params.persona or (personaMod and personaMod.generatePersona(params.carIndex or 0)) or {}

  -- 1. Check Safety Car opportunism
  if scMod and params.scActive then
    local scEval = scMod.evaluateScPitBonus({
      plannedPitLap = baseTarget,
      currentLap = curLap,
      fuelLapsRemain = fuelLaps,
      tyreAgeLaps = toNum(params.tyreAgeLaps, 10),
    }, persona.safety_car_reaction or 0.5)

    if scEval.shouldBoxUnderSc then
      return {
        targetLap = curLap,
        openLap = curLap,
        escalateLap = curLap + 1,
        tactic = "SAFETY_CAR_BOX",
        reason = scEval.reason,
      }
    end
  end

  -- 2. Check Undercut / Overcut timing
  if pitMod then
    local pitEval = pitMod.evaluatePitTimingOptions({
      currentLap = curLap,
      plannedPitLap = baseTarget,
      fuelLapsRemaining = fuelLaps,
      currentTyrePaceLoss = toNum(params.currentTyrePaceLoss, 0.4),
      freshTyreAdvantage = toNum(params.freshTyreAdvantage, 1.0),
      gapAheadSec = toNum(params.gapAheadSec, 999.0),
      gapBehindSec = toNum(params.gapBehindSec, 999.0),
      exitTrafficPenaltyNow = toNum(params.exitTrafficPenaltyNow, 0.0),
      exitTrafficPenaltyLater = toNum(params.exitTrafficPenaltyLater, 0.0),
      persona = persona,
      scActive = params.scActive or false,
    })

    if pitEval.bestAction == "PIT_NOW" and (baseTarget - curLap) <= 3 then
      return {
        targetLap = curLap,
        openLap = curLap,
        escalateLap = curLap + 1,
        tactic = pitEval.bestTactic,
        reason = "Undercut triggered against traffic ahead",
      }
    elseif pitEval.bestAction == "PIT_PLUS_2" and fuelLaps >= 2.5 then
      return {
        targetLap = math.max(baseTarget, curLap + 2),
        openLap = math.max(baseWindow.openLap or curLap, curLap + 1),
        escalateLap = math.max(baseWindow.escalateLap or (curLap + 3), curLap + 3),
        tactic = "OVERCUT",
        reason = "Extending stint in clean air",
      }
    end
  end

  -- Return unadjusted base window if no dynamic trigger fired
  return {
    targetLap = baseTarget,
    openLap = toNum(baseWindow.openLap, baseTarget - 1),
    escalateLap = toNum(baseWindow.escalateLap, baseTarget + 1),
    tactic = "PLANNED_WINDOW",
    reason = "Running nominal strategy",
  }
end

return M
