--[[
  MistakeEngine.lua
  PersonaAI v2.0.0-NextGen: Micro-Mistake Matrix & Multiaxial Error Dynamics
  
  Responsibilities:
    1. Multi-axial Micro-Mistakes (Human 80% subtle performance losses vs 20% macro failures):
       - OVERSLOW (入弯迟疑): Braking 5-15m early under intense pressure, entry speed -5~10 km/h.
       - TRAIL_UNDERSTEER (循迹刹车释放过慢): Front axle overloaded, extended understeer push wide.
       - BRAKE_LOCKUP (入弯抱死): Front tyre flat-spot / smoke puff.
       - TRACTION_SLIDE (出弯甩尾): Throttle oversteer wiggle.
       - MISSED_APEX (走大走宽): Spline overshoot into marble dust.
    2. Standing Start Blunders (发车格起步失误):
       - Gaussian reaction delay (0.2s - 0.6s).
       - WHEELSPIN (起步过载打滑): Aggressive drivers 8% chance.
       - BOG_DOWN (掉转速顿挫): Conservative drivers 5% chance.
    3. Flat preallocated data tables, zero dynamic memory allocation.
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

local MAX_CARS = 64
local _startHandled = {} -- [carIdx] = true/false
local _startDelayTimer = {} -- [carIdx] = delay remaining
local _startBlunderType = {} -- [carIdx] = type

for i = 0, MAX_CARS - 1 do
  _startHandled[i] = false
  _startDelayTimer[i] = 0.0
  _startBlunderType[i] = M.TYPE_NONE
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

--- Roll for micro-mistake or macro-mistake when under psychological stress
--- Returns mistake type, duration, targetSplineOffset, cautionMod, gripMod
---@param carIndex integer
---@param stress number Current stress (0 ~ 10)
---@param persona table Driver persona
---@param rivalryScore number Rivalry grievance
---@param hotspotDanger number Danger level (0 ~ 1)
---@param dt number
---@return string mistakeType, number duration, number offset, number caution, number gripMod
function M.rollMistake(carIndex, stress, persona, rivalryScore, hotspotDanger, dt)
  local stressThreshold = 6.0 * (persona.pressure_resist or 0.6)
  if stress <= stressThreshold then
    return M.TYPE_NONE, 0, 0, 1.0, 0.0
  end

  local errProb = (persona.error_probability or 0.1) * (1.0 + (rivalryScore or 0) * 0.1) * (1.0 - (hotspotDanger or 0) * 0.5)
  local roll = math.random()

  -- Check if mistake triggered this tick
  if roll >= (errProb * (dt * 2.5)) then
    return M.TYPE_NONE, 0, 0, 1.0, 0.0
  end

  -- Distribute across full spectrum:
  -- 1. Micro-Mistakes (50%):
  --    - 25% OVERSLOW: Early braking, enter corner hesitant
  --    - 25% TRAIL_UNDERSTEER: Released trail-brake too late, understeer push
  -- 2. Macro-Mistakes (50%):
  --    - 20% MISSED_APEX: Run wide
  --    - 15% BRAKE_LOCKUP: Front lockup
  --    - 15% TRACTION_SLIDE: Rear slide
  local mRoll = math.random()

  if mRoll < 0.25 then
    -- OVERSLOW: Caution elevated to 2.8, vehicle brakes early
    return M.TYPE_OVERSLOW, 1.8, 0.0, 2.8, 0.0
  elseif mRoll < 0.50 then
    -- TRAIL_UNDERSTEER: Front grip penalty -8%, pushes car 0.4 wide
    return M.TYPE_TRAIL_UNDERSTEER, 2.2, 0.40, 0.5, -0.08
  elseif mRoll < 0.70 then
    -- MISSED_APEX: Spline offset +0.65 overshoot, caution dropped to 0.2
    return M.TYPE_MISSED_APEX, 2.5, 0.65, 0.2, 0.0
  elseif mRoll < 0.85 then
    -- BRAKE_LOCKUP: Classic wheel lock
    return M.TYPE_BRAKE_LOCKUP, 1.2, 0.0, 1.8, -0.15
  else
    -- TRACTION_SLIDE: Rear slide, throttle oversteer
    return M.TYPE_TRACTION_SLIDE, 1.6, 0.0, 1.6, -0.10
  end
end

function M.reset()
  for i = 0, MAX_CARS - 1 do
    _startHandled[i] = false
    _startDelayTimer[i] = 0.0
    _startBlunderType[i] = M.TYPE_NONE
  end
end

return M
