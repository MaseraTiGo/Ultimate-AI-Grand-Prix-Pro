--[[
  tyre_model.lua
  Tyre degradation, compound characteristics and stint life modeling.
  Provides degradation curves, grip loss per lap, and pit stop tyre advantage.
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

-- Default compound specifications
-- basePaceDelta: delta to reference compound in seconds per lap (Soft = 0.0s, Medium = +0.5s, Hard = +1.1s)
-- degRatePerLap: lap time loss in seconds per lap of tyre age
-- cliffLap: lap at which exponential drop-off starts
-- maxUsefulLaps: maximum recommended stint length
M.DEFAULT_COMPOUNDS = {
  SOFT = {
    name = "Soft",
    basePaceDelta = 0.0,
    degRatePerLap = 0.075, -- loses ~0.75s per 10 laps
    cliffLap = 16,
    cliffDegMultiplier = 3.0,
    maxUsefulLaps = 20,
    freshTyreWarmupLaps = 1,
    freshTyreAdvantage = 1.2, -- initial out-lap/flying-lap grip advantage (s)
  },
  MEDIUM = {
    name = "Medium",
    basePaceDelta = 0.45,
    degRatePerLap = 0.040, -- loses ~0.4s per 10 laps
    cliffLap = 26,
    cliffDegMultiplier = 2.5,
    maxUsefulLaps = 32,
    freshTyreWarmupLaps = 1,
    freshTyreAdvantage = 0.9,
  },
  HARD = {
    name = "Hard",
    basePaceDelta = 0.95,
    degRatePerLap = 0.022, -- loses ~0.22s per 10 laps
    cliffLap = 38,
    cliffDegMultiplier = 2.0,
    maxUsefulLaps = 48,
    freshTyreWarmupLaps = 2,
    freshTyreAdvantage = 0.6,
  },
  INTERMEDIATE = {
    name = "Intermediate",
    basePaceDelta = 2.5,
    degRatePerLap = 0.05,
    cliffLap = 22,
    cliffDegMultiplier = 2.5,
    maxUsefulLaps = 28,
    freshTyreWarmupLaps = 1,
    freshTyreAdvantage = 1.0,
  },
  WET = {
    name = "Wet",
    basePaceDelta = 5.0,
    degRatePerLap = 0.04,
    cliffLap = 28,
    cliffDegMultiplier = 2.0,
    maxUsefulLaps = 35,
    freshTyreWarmupLaps = 1,
    freshTyreAdvantage = 1.0,
  }
}

function M.createCarTyreState(compoundName)
  local cName = compoundName or "MEDIUM"
  return {
    compound = cName,
    lapsOnTyre = 0,
    tyreWearPct = 0.0, -- 0.0 (fresh) to 1.0 (dead)
    currentPaceLoss = 0.0, -- seconds per lap slower than fresh reference
    isPastCliff = false,
  }
end

--[[
  calculateTyrePaceLoss:
  Calculates the current lap time penalty (seconds) of a tyre set based on compound, age, and driver preservation.
  @param compoundName: "SOFT", "MEDIUM", "HARD" etc.
  @param lapsOnTyre: Integer, number of laps completed on this set
  @param personaTyrePreservation: 0.0 (aggressive wear) to 1.0 (smooth tyre nurse)
]]
function M.calculateTyrePaceLoss(compoundName, lapsOnTyre, personaTyrePreservation)
  local spec = M.DEFAULT_COMPOUNDS[compoundName] or M.DEFAULT_COMPOUNDS.MEDIUM
  lapsOnTyre = math.max(0, toNum(lapsOnTyre, 0))
  personaTyrePreservation = math.max(0, math.min(1, toNum(personaTyrePreservation, 0.5)))

  -- Preservation modifier: 0.0 -> 1.25x wear rate, 1.0 -> 0.75x wear rate
  local wearMod = 1.25 - (personaTyrePreservation * 0.5)
  local effectiveAge = lapsOnTyre * wearMod

  local paceLoss = spec.basePaceDelta

  if effectiveAge <= spec.cliffLap then
    paceLoss = paceLoss + (effectiveAge * spec.degRatePerLap)
  else
    -- Linear deg up to cliff, then accelerated deg past cliff
    local cliffAge = spec.cliffLap
    local postCliffAge = effectiveAge - cliffAge
    local linearPart = cliffAge * spec.degRatePerLap
    local cliffPart  = postCliffAge * (spec.degRatePerLap * spec.cliffDegMultiplier)
    paceLoss = paceLoss + linearPart + cliffPart
  end

  local isPastCliff = effectiveAge >= spec.cliffLap
  return math.floor(paceLoss * 1000 + 0.5) / 1000, isPastCliff
end

--[[
  estimateFreshTyreDelta:
  Calculates the lap time delta (seconds) gained by pitting for fresh tyres compared to staying out on current tyres.
  Positive return means fresh tyres are faster by X seconds.
]]
function M.estimateFreshTyreDelta(currentCompound, currentLaps, nextCompound, personaTyrePreservation)
  local currentLoss = M.calculateTyrePaceLoss(currentCompound, currentLaps, personaTyrePreservation)
  local nextLoss    = M.calculateTyrePaceLoss(nextCompound, 0, personaTyrePreservation)
  local freshAdvantage = (M.DEFAULT_COMPOUNDS[nextCompound] or M.DEFAULT_COMPOUNDS.MEDIUM).freshTyreAdvantage or 0.8

  local delta = (currentLoss - nextLoss) + freshAdvantage
  return math.floor(delta * 100 + 0.5) / 100
end

return M
