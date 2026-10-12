--[[
  safety_car.lua
  Safety Car (SC), Virtual Safety Car (VSC) & Full Course Yellow (FCY) condition detection and strategy scoring.
  Under SC/FCY, normal pit loss is halved (effective pit delta is dramatically reduced because the pack is driving slowly).
]]

local M = {}

local function toNum(v, def)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
  end
  return def
end

-- Normal green flag pit loss vs Safety Car pit loss ratio
-- Green: full-speed field passes while you pit (~22-26s net track loss)
-- SC: field is travelling at ~50-60% speed, so you lose only ~11-14s net track position
M.SC_PIT_LOSS_DISCOUNT = 0.55

function M.createSafetyCarState()
  return {
    phase = "GREEN", -- "GREEN", "YELLOW", "VSC", "SC"
    phaseStartClock = 0,
    lapsUnderSc = 0,
    leaderSpeedKmh = 200.0,
    scDetectedThisFrame = false,
  }
end

--[[
  detectSafetyCarCondition:
  Detects SC/Yellow state based on AC flags or average field speed anomalies.
  @param sim: ac.getSim()
  @param carsList: active cars speeds
  @param normalRaceSpeedKmh: baseline racing speed (e.g. 180 km/h)
]]
function M.detectSafetyCarCondition(sim, carsList, normalRaceSpeedKmh)
  local baseline = toNum(normalRaceSpeedKmh, 180.0)

  -- Check direct CSP flags if present
  if sim then
    if sim.isYellowFlag or sim.hasYellowFlag then
      return "YELLOW", 0.85
    end
    if sim.safetyCarActive or sim.isSafetyCar then
      return "SC", 0.55
    end
  end

  -- Speed anomaly detection across the field
  if carsList and #carsList >= 3 then
    local sumSpeed = 0
    local count = 0
    for _, c in ipairs(carsList) do
      if c.speedKmh and c.speedKmh > 10 then
        sumSpeed = sumSpeed + c.speedKmh
        count = count + 1
      end
    end
    if count >= 3 then
      local avgSpeed = sumSpeed / count
      -- If field average speed dropped by more than 40% while session is running
      if avgSpeed < (baseline * 0.55) then
        return "SC", 0.55
      elseif avgSpeed < (baseline * 0.75) then
        return "YELLOW", 0.80
      end
    end
  end

  return "GREEN", 1.0
end

--[[
  evaluateScPitBonus:
  Scores whether boxing under Safety Car is advantageous for a car.
  @param carState: { currentStint, currentLap, plannedPitLap, fuelLapsRemain, tyreAgeLaps }
  @param personaScReaction: 0.0 to 1.0
]]
function M.evaluateScPitBonus(carState, personaScReaction)
  local plannedLap = toNum(carState.plannedPitLap, 20)
  local currentLap = toNum(carState.currentLap, 1)
  local lapsToPlanned = plannedLap - currentLap
  local fuelRemaining = toNum(carState.fuelLapsRemain, 10)
  local tyreAge = toNum(carState.tyreAgeLaps, 10)
  local reaction = toNum(personaScReaction, 0.5)

  -- If planned stop is within next 8 laps, "cheap pit stop" under SC is enormous time saver
  local windowProximityBonus = 0
  if lapsToPlanned <= 3 then
    windowProximityBonus = 12.0 -- huge bonus, ~12 seconds saved
  elseif lapsToPlanned <= 7 then
    windowProximityBonus = 7.0
  elseif lapsToPlanned <= 12 then
    windowProximityBonus = 3.0
  else
    -- Stop was planned much later; pitting now might force an extra stop
    windowProximityBonus = -4.0
  end

  -- Tyre age bonus: worn tyres benefit more from free swap
  local tyreBonus = math.max(0, (tyreAge - 8) * 0.4)

  -- Persona influence
  local personaBonus = (reaction - 0.5) * 4.0

  local netScore = windowProximityBonus + tyreBonus + personaBonus
  local shouldBoxUnderSc = netScore > 4.0

  return {
    shouldBoxUnderSc = shouldBoxUnderSc,
    score = math.floor(netScore * 10 + 0.5) / 10,
    timeSavedSeconds = shouldBoxUnderSc and 10.5 or 0.0,
    reason = shouldBoxUnderSc and "Safety Car discount pit window" or "SC too early for target fuel window",
  }
end

return M
