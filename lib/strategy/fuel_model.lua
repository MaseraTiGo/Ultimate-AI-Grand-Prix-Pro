--[[
  fuel_model.lua
  Dynamic fuel consumption estimation model for AI Race Strategy Layer.
  Computes real-time estimatedFuelPerLap based on:
    - Base measured consumption (from practice / historical baseline)
    - Race pace (delta to typical lap time)
    - Traffic density (following cars closely increases fuel saving / lifts & coasts)
    - Fuel mass load penalty (heavier fuel load burns slightly more per lap)
    - Safety Car / Full Course Yellow pacing
    - Driver persona (pushing vs fuel saving mode)
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

-- Typical mass fuel sensitivity in circuit racing (~0.003 to 0.005 L/lap per 10L of fuel)
local MASS_FACTOR_PER_10L = 0.008

function M.createCarFuelState()
  return {
    baseFuelPerLap = 2.0,
    currentEstimatedFpl = 2.0,
    historyLaps = {}, -- circular buffer of last N lap burn values
    lastLapFuel = nil,
    lastLapCount = nil,
    savingMode = "NORMAL", -- "PUSH", "NORMAL", "SAVE", "EXTREME_SAVE"
  }
end

--[[
  calculateDynamicFuelPerLap:
  @param baseFpl: Base measured burn rate (L/lap)
  @param fuelInTank: Current fuel in tank (litres)
  @param tankCapacity: Max fuel capacity (litres, for mass ratio)
  @param racePhase: "RACE_START", "GREEN", "TRAFFIC", "SC", "VSC"
  @param trafficFactor: 0.0 (clean air) to 1.0 (heavy traffic / drafting)
  @param personaFuelSaving: 0.0 (aggressive, pushes) to 1.0 (disciplined saver)
  @param paceDeltaPct: percentage pace difference (e.g. +0.05 for 5% slower, -0.02 for pushing)
]]
function M.calculateDynamicFuelPerLap(baseFpl, fuelInTank, tankCapacity, racePhase, trafficFactor, personaFuelSaving, paceDeltaPct)
  baseFpl = toNum(baseFpl, 2.0)
  if baseFpl <= 0 then baseFpl = 2.0 end

  local fuel = toNum(fuelInTank, 30.0)
  local cap  = toNum(tankCapacity, 100.0)
  trafficFactor = math.max(0, math.min(1, toNum(trafficFactor, 0)))
  personaFuelSaving = math.max(0, math.min(1, toNum(personaFuelSaving, 0.5)))
  paceDeltaPct = toNum(paceDeltaPct, 0.0)

  -- 1. Safety Car / Yellow Flag effect: fuel consumption drops by 45% - 60%
  if racePhase == "SC" or racePhase == "SAFETY_CAR" or racePhase == "FCY" then
    return math.max(0.4, baseFpl * 0.45)
  end

  local multiplier = 1.0

  -- 2. Fuel load / Mass effect: heavier car burns slightly more
  if cap > 0 then
    local fuelOverHalf = (fuel - (cap * 0.5)) / 10.0
    multiplier = multiplier + (fuelOverHalf * MASS_FACTOR_PER_10L)
  end

  -- 3. Pace / Pushing effect (-5% burn when cruising, +6% burn when pushing flat out)
  -- paceDeltaPct: negative is faster lap time (pushing)
  if paceDeltaPct < 0 then
    -- Pushing hard: burns more
    multiplier = multiplier + math.min(0.08, math.abs(paceDeltaPct) * 1.2)
  elseif paceDeltaPct > 0 then
    -- Paced lap / cruising: burns less
    multiplier = multiplier - math.min(0.12, paceDeltaPct * 0.8)
  end

  -- 4. Traffic / Slipstreaming & Lift-and-Coast:
  -- Following in dirty air / traffic leads to short-shifting, lifting, or slipstream tow: up to -5% burn
  if trafficFactor > 0 then
    multiplier = multiplier - (trafficFactor * 0.05)
  end

  -- 5. Driver Persona fuel saving mode:
  -- High fuel_saving persona reduces consumption by up to 6% (via lift-and-coast, engine maps)
  local personaOffset = (personaFuelSaving - 0.5) * -0.06
  multiplier = multiplier + personaOffset

  -- Safety clamp multiplier between 0.70x and 1.30x of base
  if multiplier < 0.70 then multiplier = 0.70 end
  if multiplier > 1.30 then multiplier = 1.30 end

  local dynFpl = baseFpl * multiplier
  return math.floor(dynFpl * 1000 + 0.5) / 1000
end

-- Estimates remaining laps capable on current fuel load with dynamic burn rate
function M.estimateLapsRemaining(fuelInTank, dynamicFpl, safetyReserveLaps)
  local fuel = toNum(fuelInTank, 0)
  local fpl  = toNum(dynamicFpl, 2.0)
  local res  = toNum(safetyReserveLaps, 0.8)

  if fuel <= 0 or fpl <= 0 then return 0 end
  local usableFuel = math.max(0, fuel - (res * fpl))
  return math.floor((usableFuel / fpl) * 10 + 0.5) / 10
end

return M
