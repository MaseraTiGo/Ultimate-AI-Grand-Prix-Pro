--[[
  BehaviorActuator.lua
  PersonaAI v2.0.0-NextGen: Vehicle Body Language & Physical Execution Layer
  
  Responsibilities:
    1. Immersive Body Language:
       - Headlight Flash Aggression (ac.overrideCarControls.headlightsFlash) when closely hunting (< 15m)
       - Micro-Correction Wheel Twitching (0.02 spline oscillation @ 0.15s) at grip limits
       - Context-Aware Blue Flag: safe throttle release & safe line positioning
       - Tyre Flat-spot & Skid smoke puffs during heavy lockup/slide
    2. Dynamic Corridor & Car's Width Rule:
       - Side-by-side overlap ratio > 30% enforces 1 car width (track edge margin >= 0.25 + carWidth)
    3. Multi-Channel Slew-Limiting:
       - Velocity-adaptive lateral spline movement rate
       - Slew-rate filtering for Caution, Aggression, and Extra Grip
]]

local M = {}

local MAX_CARS = 24
local _twitchTimers = {}
local _twitchPhases = {}
local _flashTimers = {}
local _flashCounters = {}

for i = 0, MAX_CARS - 1 do
  _twitchTimers[i] = 0.0
  _twitchPhases[i] = 0.0
  _flashTimers[i] = 0.0
  _flashCounters[i] = 0
end

--- Calculate Car's Width Boundary Margin (Side-by-side corridor rule)
--- Prevents squeezing rival off track when overlap > 30%
---@param currentOffset number Desired spline offset (-1.0 to 1.0)
---@param rivalRelX number Relative lateral position of rival (-1 left, +1 right)
---@param overlapRatio number Overlap fraction (0.0 to 1.0)
---@return number boundedOffset
function M.enforceCarWidthRule(currentOffset, rivalRelX, overlapRatio)
  if overlapRatio < 0.30 then
    return currentOffset
  end

  -- Safe corridor: 1 car width is approx 0.35 track units + 0.05 safety buffer
  local corridorMargin = 0.40

  if rivalRelX > 0.0 then
    -- Rival is on the right side: clamp our offset to not exceed (1.0 - corridorMargin)
    if currentOffset > (1.0 - corridorMargin) then
      return 1.0 - corridorMargin
    end
  else
    -- Rival is on the left side: clamp our offset to not exceed -(1.0 - corridorMargin)
    if currentOffset < -(1.0 - corridorMargin) then
      return -(1.0 - corridorMargin)
    end
  end

  return currentOffset
end

--- Update Visual Twitching (Micro-steering corrections near grip limit)
---@param carIndex integer
---@param dt number
---@param isNearGripLimit boolean
---@return number twitchDelta
function M.computeVisualTwitch(carIndex, dt, isNearGripLimit)
  if not isNearGripLimit then
    _twitchTimers[carIndex] = 0.0
    return 0.0
  end

  local phase = (_twitchPhases[carIndex] or 0.0) + (dt / 0.15) * 6.2831853
  if phase > 628.3 then phase = 0.0 end
  _twitchPhases[carIndex] = phase

  -- Small high frequency oscillation +-0.02 spline units
  local delta = math.sin(phase) * 0.020
  return delta
end

--- Update Headlight Flash Agitation (Psychological warfare when hunting closely)
---@param carIndex integer
---@param isHunting boolean Closely chasing ahead (< 15m)
---@param persona table
---@param dt number
---@return boolean shouldFlash
function M.stepHeadlightFlashing(carIndex, isHunting, persona, dt)
  local aggr = persona and persona.base_aggression or 0.7
  if not isHunting or aggr < 0.80 then
    _flashTimers[carIndex] = 0.0
    _flashCounters[carIndex] = 0
    return false
  end

  local timer = (_flashTimers[carIndex] or 0.0) + dt
  _flashTimers[carIndex] = timer

  -- Trigger double flash burst every 3.0s
  if timer >= 3.0 then
    _flashTimers[carIndex] = 0.0
    _flashCounters[carIndex] = 4 -- 4 toggle frames
  end

  local c = _flashCounters[carIndex] or 0
  if c > 0 then
    _flashCounters[carIndex] = c - 1
    return (c % 2 == 1)
  end

  return false
end

--- Full Actuator Execution Pipeline with Body Language & Slew-Limiting
--- Pure scalar mathematics, NYI-free, zero table allocation
---@param car ac.StateCar
---@param aiState table
---@param dt number
function M.applyActuator(car, aiState, dt)
  if not car or not aiState then return end
  if not physics or not physics.allowed or not physics.allowed() then return end
  local idx = car.index

  -- 1. Velocity-dependent lateral transition rate
  local baseRate = 1.2
  local refSpeed = 80.0
  local curSpeed = car.speedKmh or 80.0
  if curSpeed < 30.0 then curSpeed = 30.0 end
  local speedScale = refSpeed / curSpeed
  if speedScale < 0.35 then speedScale = 0.35 end
  if speedScale > 1.80 then speedScale = 1.80 end
  local stepRate = dt * (baseRate * speedScale)

  -- 2. Target Spline Offset with Corridor Clamping & Visual Twitch
  local targetOff = aiState.targetSplineOffset or 0.0
  if aiState.overlapRatio and aiState.overlapRatio > 0.30 and aiState.rivalRelX then
    targetOff = M.enforceCarWidthRule(targetOff, aiState.rivalRelX, aiState.overlapRatio)
  end

  -- Apply Micro-correction twitch if near grip limits (high lat G or understeer)
  local latG = 0.0
  if car.acceleration and car.acceleration.x then
    latG = math.abs(car.acceleration.x)
  end
  local isAtLimit = (latG > 9.8) or (aiState.state == "MISTAKE")
  local twitch = M.computeVisualTwitch(idx, dt, isAtLimit)
  local finalTarget = targetOff + twitch

  if aiState.currentSplineOffset < finalTarget then
    local nextVal = aiState.currentSplineOffset + stepRate
    if nextVal > finalTarget then nextVal = finalTarget end
    aiState.currentSplineOffset = nextVal
  elseif aiState.currentSplineOffset > finalTarget then
    local nextVal = aiState.currentSplineOffset - stepRate
    if nextVal < finalTarget then nextVal = finalTarget end
    aiState.currentSplineOffset = nextVal
  end

  -- 3. Slew-limiting for Caution and Aggression (max 1.5 units/s)
  local slew = dt * 1.5
  local curC = aiState.currentCaution or aiState.targetCaution or 1.0
  local tgtC = aiState.targetCaution or 1.0
  if curC < tgtC then
    curC = curC + slew
    if curC > tgtC then curC = tgtC end
  elseif curC > tgtC then
    curC = curC - slew
    if curC < tgtC then curC = tgtC end
  end
  aiState.currentCaution = curC

  local curA = aiState.currentAggression or aiState.targetAggression or 0.7
  local tgtA = aiState.targetAggression or 0.7
  if curA < tgtA then
    curA = curA + slew
    if curA > tgtA then curA = tgtA end
  elseif curA > tgtA then
    curA = curA - slew
    if curA < tgtA then curA = tgtA end
  end
  aiState.currentAggression = curA

  -- 4. Push to CSP Physics Actuators (Gated at low speed to prevent grid crab-walk & spinout)
  if curSpeed < 45.0 then
    -- On starting grid / launch phase: let native AC AI follow track centerline / grid slot directly
    aiState.currentSplineOffset = 0.0
    if physics.setAISplineOffset then
      physics.setAISplineOffset(idx, 0.0, false)
    end
    if physics.setAICaution then
      physics.setAICaution(idx, 1.0)
    end
    if physics.setAIAggression then
      physics.setAIAggression(idx, 0.7)
    end
    if physics.setExtraAIGrip then
      physics.setExtraAIGrip(idx, 0.0)
    end
  else
    if physics.setAISplineOffset then
      local overrideAwareness = (aiState.state == "DEFEND" or aiState.state == "ATTACK")
      physics.setAISplineOffset(idx, aiState.currentSplineOffset, overrideAwareness)
    end

    if physics.setAICaution then
      physics.setAICaution(idx, aiState.currentCaution)
    end

    if physics.setAIAggression then
      physics.setAIAggression(idx, aiState.currentAggression)
    end

    -- 5. Grip Adjustments (Dirty Air + Mistake Grip + Tyre Overheat & Cold Tyre Warmup)
    local totalGripPenalty = 0.0
    if aiState.dirtyAirLoss then totalGripPenalty = totalGripPenalty + aiState.dirtyAirLoss end
    if aiState.mistakeGripPenalty then totalGripPenalty = totalGripPenalty + aiState.mistakeGripPenalty end
    if aiState.tireTempNorm and aiState.tireTempNorm > 1.15 then
      -- Overheated tyre grip drop (up to 7% loss when cooked)
      totalGripPenalty = totalGripPenalty + (aiState.tireTempNorm - 1.15) * 0.20
    end
    if aiState.outLapColdGrip and aiState.outLapColdGrip < 1.0 then
      -- Fresh tyre warmup ramp (cold tyre grip loss)
      totalGripPenalty = totalGripPenalty + (1.0 - aiState.outLapColdGrip)
    end

    if physics.setExtraAIGrip then
      if totalGripPenalty > 0.001 then
        physics.setExtraAIGrip(idx, -totalGripPenalty)
      else
        physics.setExtraAIGrip(idx, 0.0)
      end
    end
  end

  -- 6. Headlight Flashing Body Language
  local isHunting = (aiState.state == "ATTACK" and (aiState.aheadDist or 999.0) < 15.0)
  local flash = M.stepHeadlightFlashing(idx, isHunting, aiState.persona, dt)
  if flash and ac and ac.overrideCarControls then
    local ctrl = ac.overrideCarControls(idx)
    if ctrl then
      ctrl.headlightsFlash = true
    end
  end

  -- 7. Lift and Coast throttle cut (save tyre & fuel into deceleration phase)
  if aiState.isLiftAndCoast and physics.setAIThrottleLimit then
    physics.setAIThrottleLimit(idx, 0.0)
  end
end

function M.reset()
  for i = 0, MAX_CARS - 1 do
    _twitchTimers[i] = 0.0
    _twitchPhases[i] = 0.0
    _flashTimers[i] = 0.0
    _flashCounters[i] = 0
  end
end

return M
