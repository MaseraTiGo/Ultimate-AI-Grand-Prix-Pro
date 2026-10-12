--[[
  driver_persona.lua
  Driver Persona and Behavioral Profile for AI Pit Strategy.
  Instead of binary aggressive/conservative flags, models multi-dimensional driver strategy traits:
    - aggression (0.0 to 1.0)
    - risk_tolerance (0.0 to 1.0)
    - fuel_saving (0.0 to 1.0)
    - tyre_preservation (0.0 to 1.0)
    - undercut_preference (0.0 to 1.0)
    - overcut_preference (0.0 to 1.0)
    - safety_car_reaction (0.0 = cautious wait, 1.0 = instant opportunist box)
    - traffic_tolerance (0.0 = hates traffic, boxes early; 1.0 = patient in dirty air)
]]

local M = {}

-- Generates a deterministic but distinct persona based on car index or driver name seed
function M.generatePersona(carIndex, driverName)
  local seed = (tonumber(carIndex) or 0) * 37
  if driverName and type(driverName) == "string" then
    for i = 1, #driverName do
      seed = (seed + driverName:byte(i) * i) % 65535
    end
  end

  local function pseudoRand(offset, minVal, maxVal)
    local val = math.sin(seed + offset) * 10000
    local norm = val - math.floor(val) -- 0.0 to 1.0
    return minVal + norm * (maxVal - minVal)
  end

  local aggression          = pseudoRand(1.1, 0.20, 0.90)
  local risk_tolerance      = pseudoRand(2.2, 0.15, 0.85)
  local fuel_saving         = pseudoRand(3.3, 0.20, 0.80)
  local tyre_preservation   = pseudoRand(4.4, 0.25, 0.85)
  local undercut_preference = pseudoRand(5.5, 0.30, 0.90)
  local overcut_preference  = pseudoRand(6.6, 0.20, 0.80)
  local safety_car_reaction = pseudoRand(7.7, 0.35, 0.95)
  local traffic_tolerance   = pseudoRand(8.8, 0.20, 0.80)

  -- Normalize slightly based on aggression
  if aggression > 0.70 then
    undercut_preference = math.min(1.0, undercut_preference + 0.15)
    risk_tolerance = math.min(1.0, risk_tolerance + 0.15)
    overcut_preference = math.max(0.1, overcut_preference - 0.10)
  end

  return {
    carIndex = carIndex,
    aggression = math.floor(aggression * 100 + 0.5) / 100,
    risk_tolerance = math.floor(risk_tolerance * 100 + 0.5) / 100,
    fuel_saving = math.floor(fuel_saving * 100 + 0.5) / 100,
    tyre_preservation = math.floor(tyre_preservation * 100 + 0.5) / 100,
    undercut_preference = math.floor(undercut_preference * 100 + 0.5) / 100,
    overcut_preference = math.floor(overcut_preference * 100 + 0.5) / 100,
    safety_car_reaction = math.floor(safety_car_reaction * 100 + 0.5) / 100,
    traffic_tolerance = math.floor(traffic_tolerance * 100 + 0.5) / 100,
  }
end

-- Pre-defined archetype presets for testing / explicit assignments
M.ARCHETYPES = {
  ATTACKER = {
    aggression = 0.85,
    risk_tolerance = 0.80,
    fuel_saving = 0.30,
    tyre_preservation = 0.40,
    undercut_preference = 0.90,
    overcut_preference = 0.20,
    safety_car_reaction = 0.90,
    traffic_tolerance = 0.25,
  },
  TACTICIAN = {
    aggression = 0.55,
    risk_tolerance = 0.50,
    fuel_saving = 0.70,
    tyre_preservation = 0.85,
    undercut_preference = 0.45,
    overcut_preference = 0.80,
    safety_car_reaction = 0.75,
    traffic_tolerance = 0.75,
  },
  BALANCED = {
    aggression = 0.50,
    risk_tolerance = 0.50,
    fuel_saving = 0.50,
    tyre_preservation = 0.50,
    undercut_preference = 0.50,
    overcut_preference = 0.50,
    safety_car_reaction = 0.50,
    traffic_tolerance = 0.50,
  }
}

return M
