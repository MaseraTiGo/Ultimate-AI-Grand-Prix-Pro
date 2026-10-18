--[[
  MistakeEngine.lua
  PersonaAI v2.0.0-NextGen: Micro-Mistake Matrix & Multiaxial Error Dynamics
  
  Responsibilities:
    1. Multi-axial Micro-Mistakes (Human 80% subtle performance losses vs 20% macro failures):
       - OVERSLOW (入弯迟疑): Braking 5-15m early under intense pressure, entry speed -5~10 km/h.
       - TRAIL_UNDERSTEER (循迹刹车释放过慢): Front axle overloaded, extended understeer push wide.
       - BRAKE_LOCKUP (入弯抱死): Front tyre flat-spot / smoke puff under high deceleration.
       - TRACTION_SLIDE (出弯甩尾): Throttle oversteer wiggle on corner exit acceleration.
       - MISSED_APEX (走大走宽): Spline overshoot into marble dust.
    2. Standing Start Blunders (发车格起步失误):
       - Gaussian reaction delay (0.2s - 0.6s).
       - WHEELSPIN (起步过载打滑): Aggressive drivers 8% chance.
       - BOG_DOWN (掉转速顿挫): Conservative drivers 5% chance.
    3. Multi-Factorial Anthropomorphic Error Scaling:
       - Joint evaluation of Driver DNA (mistake_resistance [0..0.96], pressure_handling, error_probability).
       - Environmental stress (chaser distance, track hotspot danger, rivalry grievance).
       - Thermal & tyre degradation (cold out-lap warmup, cooked overheated tyres, high tyre wear).
       - Real-time telemetry gating (high deceleration for lockups, low-to-mid corner exit throttle for traction snaps).
       - Opening lap / pack protection (lap 0 / speed < 75 km/h strictly suppresses mistakes).
       - Pitlane silence (zero interference inside pitlane / pit box).
       - Anti-immunization guarantee: mistake_resistance strictly capped at 0.96 (no driver is 100% immune).
       - 25s per-car cooldown for physical mistake actuations.
    4. Flat preallocated data tables, zero dynamic memory allocation.
]]

local M = {}

M.TYPE_NONE = "NONE"
M.TYPE_OVERSLOW = "OVERSLOW"
M.TYPE_TRAIL_UNDERSTEER = "TRAIL_UNDERSTEER"
M.TYPE_BRAKE_LOCKUP = "BRAKE_LOCKUP"
M.TYPE_TRACTION_SLIDE = "TRACTION_SLIDE"
M.TYPE_MISSED_APEX = "MISSED_APEX"
M.TYPE_START_WHEELSPIN = "START_WHEELSPIN"
M.TYPE_START_BOGDOWN = "START_BOGDOWN"

M.TIER_NONE = 0
M.TIER_1_OVERSLOW = 1
M.TIER_2_TECHNICAL = 2
M.TIER_3_SEVERE = 3

local MAX_CARS = 24
local PHYSICAL_COOLDOWN_SEC = 20.0

local _startHandled = {}     -- [carIdx] = true/false
local _startDelayTimer = {}   -- [carIdx] = delay remaining
local _startBlunderType = {}  -- [carIdx] = type
local _mistakeCooldown = {}   -- [carIdx] = seconds remaining before next physical mistake

for i = 0, MAX_CARS - 1 do
  _startHandled[i] = false
  _startDelayTimer[i] = 0.0
  _startBlunderType[i] = M.TYPE_NONE
  _mistakeCooldown[i] = 0.0
end

--- Box-Muller transform for lightweight pseudo-Gaussian random numbers without tables
local function randomGaussian(mean, stdDev)
  local u1 = math.random()
  local u2 = math.random()
  if u1 < 1e-6 then u1 = 1e-6 end
  local z0 = math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * 3.1415926535 * u2)
  return mean + z0 * stdDev
end

--- Standing Start Simulation (Triggered on Green flag / race launch)
---@param carIndex integer
---@param persona table
---@param sessionTime number
---@return number delaySec, string blunderType
function M.evaluateStandingStart(carIndex, persona, sessionTime)
  if _startHandled[carIndex] then
    return _startDelayTimer[carIndex] or 0.0, _startBlunderType[carIndex] or M.TYPE_NONE
  end

  _startHandled[carIndex] = true

  -- Mean reaction time: 0.35s, stdDev: 0.08s, clamped between 0.18s and 0.65s
  local aggr = persona and persona.base_aggression or 0.7
  local meanReact = 0.40 - (aggr * 0.15)
  local delay = randomGaussian(meanReact, 0.06)
  if delay < 0.18 then delay = 0.18 end
  if delay > 0.65 then delay = 0.65 end
  _startDelayTimer[carIndex] = delay

  local roll = math.random()
  if aggr > 0.85 and roll < 0.08 then
    -- Aggressive driver wheelspin blunder
    _startBlunderType[carIndex] = M.TYPE_START_WHEELSPIN
  elseif aggr < 0.60 and roll < 0.05 then
    -- Conservative driver bog-down blunder
    _startBlunderType[carIndex] = M.TYPE_START_BOGDOWN
  else
    _startBlunderType[carIndex] = M.TYPE_NONE
  end

  return _startDelayTimer[carIndex], _startBlunderType[carIndex]
end

--- Tick standing start timer
---@param carIndex integer
---@param dt number
---@return boolean isLaunchDelayed
function M.stepStandingStart(carIndex, dt)
  local t = _startDelayTimer[carIndex]
  if t and t > 0.0 then
    t = t - dt
    _startDelayTimer[carIndex] = t
    return true
  end
  return false
end

--- Check if car is currently under standing start launch reaction delay
---@param carIndex integer
---@return boolean isDelayed
function M.isLaunchDelayed(carIndex)
  local t = _startDelayTimer[carIndex]
  return (t and t > 0.0) or false
end

--- Get remaining standing start launch delay
---@param carIndex integer
---@return number delaySec
function M.getStartDelay(carIndex)
  return _startDelayTimer[carIndex] or 0.0
end

--- Tick per-car mistake cooldown
---@param carIndex integer
---@param dt number
function M.stepCooldown(carIndex, dt)
  local cd = _mistakeCooldown[carIndex]
  if cd and cd > 0.0 then
    cd = cd - dt
    if cd < 0.0 then cd = 0.0 end
    _mistakeCooldown[carIndex] = cd
  end
end

--- Get remaining physical mistake cooldown
---@param carIndex integer
---@return number
function M.getMistakeCooldown(carIndex)
  return _mistakeCooldown[carIndex] or 0.0
end

--- Set explicit physical mistake cooldown (for testing or external controls)
---@param carIndex integer
---@param seconds number
function M.setMistakeCooldown(carIndex, seconds)
  _mistakeCooldown[carIndex] = seconds or 0.0
end

--- Multi-Factorial Driving Mistake Evaluation
--- Jointly evaluates driver DNA persona, environmental race stress, tyre thermals & telemetry gating.
--- Pure scalar mathematics, zero dynamic memory allocation.
---@param carIndex integer
---@param stress number Current stress (0 ~ 10)
---@param persona table Driver persona
---@param rivalryScore number Rivalry grievance
---@param hotspotDanger number Danger level (0 ~ 1)
---@param dt number Tick time step
---@param car ac.StateCar|table|nil Real-time telemetry car state
---@param raceContext table|nil Race context (tyreWear, tyreTempNorm, isInPitlane, etc.)
---@return string mistakeType, number duration, number offset, number caution, number gripMod, string? physicalType, number physicalDur, number physicalSev
function M.rollMistake(carIndex, stress, persona, rivalryScore, hotspotDanger, dt, car, raceContext)
  -- 1. Safety Gates: Opening lap & crawl protection, pitlane absolute authority
  if car then
    local speed = car.speedKmh or 0.0
    local lapCount = car.lapCount or 0
    if lapCount == 0 or speed < 75.0 then
      return M.TYPE_NONE, 0, 0, 1.0, 0.0, nil, 0, 0, M.TIER_NONE
    end
    if car.isInPitlane or car.isInPit then
      return M.TYPE_NONE, 0, 0, 1.0, 0.0, nil, 0, 0, M.TIER_NONE
    end
  end
  if raceContext and (raceContext.isInPitlane or raceContext.isInPit) then
    return M.TYPE_NONE, 0, 0, 1.0, 0.0, nil, 0, 0, M.TIER_NONE
  end

  local p = persona or {}

  -- 2. Driver Persona Factor (mistake_resistance & pressure_handling)
  local pResist = p.mistake_resistance
  if not pResist then
    pResist = p.pressure_resist or 0.70
  end
  -- Anti-immunization rule: strictly capped at 0.96 (no driver is 100% immune)
  if pResist > 0.96 then pResist = 0.96 end
  if pResist < 0.0 then pResist = 0.0 end

  local pHandling = p.pressure_handling or p.pressure_resist or 0.70
  if pHandling > 1.0 then pHandling = 1.0 end
  if pHandling < 0.0 then pHandling = 0.0 end

  local baseErrProb = p.error_probability or 0.10
  if baseErrProb < 0.02 then baseErrProb = 0.02 end

  -- Driver vulnerability factor:
  -- Verstappen (resist=0.95, baseErr=0.03): (1 - 0.95) * (0.03 / 0.10) = 0.015
  -- Colapinto  (resist=0.62, baseErr=0.16): (1 - 0.62) * (0.16 / 0.10) = 0.608
  local personaFactor = (1.0 - pResist) * (baseErrProb / 0.10)

  -- 3. Dynamic Environmental & Psychological Stress Evaluation
  -- Stress threshold scaled by pressure handling (higher handling requires more stress to start inducing mistakes)
  local stressThreshold = 3.5 + (pHandling * 3.5) -- 3.5 to 7.0 threshold
  local curStress = stress or 0.0
  if curStress <= stressThreshold then
    return M.TYPE_NONE, 0, 0, 1.0, 0.0, nil, 0, 0, M.TIER_NONE
  end

  local excessStress = curStress - stressThreshold

  -- Track hotspot danger and rivalry score multipliers
  local envMult = 1.0 + ((rivalryScore or 0.0) * 0.15) + ((hotspotDanger or 0.0) * 0.40)

  -- Tyre degradation and thermal condition multipliers
  local tyreMult = 1.0
  if raceContext then
    local wear = raceContext.tyreWear or 0.0
    if wear > 0.50 then
      tyreMult = tyreMult + (wear - 0.50) * 1.5
    end
    local temp = raceContext.tyreTempNorm or 1.0
    if temp > 1.20 then
      tyreMult = tyreMult + (temp - 1.20) * 2.0 -- Overheated surface slip
    elseif temp < 0.85 then
      tyreMult = tyreMult + (0.85 - temp) * 1.2 -- Cold tyre surface slip
    end
    local warmup = raceContext.tyreWarmupProgress
    if warmup and warmup < 0.90 then
      tyreMult = tyreMult + (0.90 - warmup) * 0.8
    end
  end

  -- Combined trigger probability per tick
  local triggerProb = personaFactor * (excessStress * 0.25) * envMult * tyreMult * ((dt or 0.1) * 2.5)
  if triggerProb > 0.85 then triggerProb = 0.85 end

  local roll = math.random()
  if roll >= triggerProb then
    return M.TYPE_NONE, 0, 0, 1.0, 0.0, nil, 0, 0, M.TIER_NONE
  end

  -- 4. Three-Tier Progressive Physical & Tactical Mistake Mapping:
  local cIdx = carIndex or 0
  local cd = _mistakeCooldown[cIdx] or 0.0
  local canPhysical = (cd <= 0.0)

  local isHeavyBraking = false
  local isCornerExitThrottle = false

  if car then
    local spd = car.speedKmh or 0.0
    local accelZ = (car.acceleration and car.acceleration.z) or 0.0
    local accelX = (car.acceleration and car.acceleration.x) or 0.0
    local brakePedal = car.brake or 0.0
    local gasPedal = car.gas or 0.0

    -- Brake Lock-up zone: high speed (> 120 km/h), heavy braking / deceleration
    if spd > 120.0 and (accelZ < -6.0 or brakePedal > 0.75) then
      isHeavyBraking = true
    end

    -- Traction loss snap zone: 50~130 km/h, corner exit acceleration, lateral turning
    if spd >= 50.0 and spd <= 130.0 and (accelZ > 2.0 or gasPedal > 0.70) and math.abs(accelX) > 1.8 then
      isCornerExitThrottle = true
    end
  end

  local mRoll = math.random()

  -- Tier 1: Micro-Hesitation & Overslow (Stress < 7.8) - zero physical damage, stays on line
  if curStress < 7.8 then
    return M.TYPE_OVERSLOW, 1.5, 0.0, 2.2, 0.0, nil, 0, 0, M.TIER_1_OVERSLOW
  end

  -- If in heavy braking zone and physical cooldown ready -> BRAKE_LOCKUP
  if isHeavyBraking and canPhysical then
    _mistakeCooldown[cIdx] = PHYSICAL_COOLDOWN_SEC
    local dur = 0.25 + math.random() * 0.20
    local tier = (curStress >= 9.2) and M.TIER_3_SEVERE or M.TIER_2_TECHNICAL
    return M.TYPE_BRAKE_LOCKUP, 1.6, 0.55, 1.6, -0.15, "BRAKE", dur, 0.0, tier
  -- If in corner exit throttle zone and physical cooldown ready -> TRACTION_SLIDE
  elseif isCornerExitThrottle and canPhysical then
    _mistakeCooldown[cIdx] = PHYSICAL_COOLDOWN_SEC
    local dur = 0.25 + math.random() * 0.20
    local sev = (curStress >= 9.2) and (1.25 + math.random() * 0.15) or (1.15 + math.random() * 0.15)
    local tier = (curStress >= 9.2) and M.TIER_3_SEVERE or M.TIER_2_TECHNICAL
    return M.TYPE_TRACTION_SLIDE, 1.8, 0.0, 1.8, -0.20, "TRACTION", dur, sev, tier
  end

  -- Spectrum of micro/macro mistakes by Stress Tier if not in specific telemetry zone or physical on cooldown:
  -- Tier 3: Severe Panic Breakdown (Stress >= 9.2)
  if curStress >= 9.2 then
    if canPhysical then
      _mistakeCooldown[cIdx] = PHYSICAL_COOLDOWN_SEC
      local dur = 0.35 + math.random() * 0.20
      local sev = 1.25 + math.random() * 0.15
      return M.TYPE_TRACTION_SLIDE, 2.0, 0.0, 1.8, -0.25, "TRACTION", dur, sev, M.TIER_3_SEVERE
    else
      return M.TYPE_MISSED_APEX, 2.5, 0.65, 0.2, -0.10, nil, 0, 0, M.TIER_3_SEVERE
    end
  end

  -- Tier 2: Technical Blunder - Lockup / Missed Apex (Stress >= 7.8)
  if curStress >= 7.8 then
    if canPhysical and mRoll < 0.50 then
      _mistakeCooldown[cIdx] = PHYSICAL_COOLDOWN_SEC
      local dur = 0.25 + math.random() * 0.20
      return M.TYPE_BRAKE_LOCKUP, 1.6, 0.55, 1.6, -0.15, "BRAKE", dur, 0.0, M.TIER_2_TECHNICAL
    elseif mRoll < 0.75 then
      return M.TYPE_MISSED_APEX, 2.2, 0.55, 0.4, -0.08, nil, 0, 0, M.TIER_2_TECHNICAL
    else
      return M.TYPE_TRAIL_UNDERSTEER, 2.0, 0.45, 0.6, -0.08, nil, 0, 0, M.TIER_2_TECHNICAL
    end
  end

  -- Tier 1: Micro-Hesitation & Overslow (Stress >= 6.0 or default triggered)
  return M.TYPE_OVERSLOW, 1.5, 0.0, 2.2, 0.0, nil, 0, 0, M.TIER_1_OVERSLOW
end

function M.reset()
  for i = 0, MAX_CARS - 1 do
    _startHandled[i] = false
    _startDelayTimer[i] = 0.0
    _startBlunderType[i] = M.TYPE_NONE
    _mistakeCooldown[i] = 0.0
  end
end

return M
