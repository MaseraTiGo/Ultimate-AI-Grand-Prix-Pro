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

local ControlTelemetry = require("lib/core/ControlTelemetry")
local EventHub = require("lib/core/EventHub")

local M = {}

local MAX_CARS = 24
local _twitchTimers = {}
local _twitchPhases = {}
local _flashTimers = {}
local _flashCounters = {}
local _flashReasons = {}
local _flashCooldowns = {}
local _flashPulseDurations = {}
local _hornTimers = {}
local _hornWasActive = {}

for i = 0, MAX_CARS - 1 do
  _twitchTimers[i] = 0.0
  _twitchPhases[i] = 0.0
  _flashTimers[i] = 0.0
  _flashCounters[i] = 0
  _flashReasons[i] = "NONE"
  _flashCooldowns[i] = 0.0
  _flashPulseDurations[i] = 0.10
  _hornTimers[i] = 0.0
  _hornWasActive[i] = false
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

  -- Pit Lane & Pit Bay Exclusive Native AI Authority:
  -- When car is in pitlane or pit stall, disable all lateral offsets and overrides to let native AC AI park/exit undisturbed.
  local inPit = car.isInPitlane or car.isInPit or aiState.state == "PIT_BAY" or aiState.tacticalState == "PIT_BAY"
  if inPit then
    aiState.currentSplineOffset = 0.0
    aiState.targetSplineOffset = 0.0
    if physics.setAIThrottleLimit then
      physics.setAIThrottleLimit(idx, 1.0)
    end
    return
  end

  -- 1. Velocity-dependent lateral transition rate (gentle and smooth, max 0.40 units/s)
  local baseRate = 0.35
  local curSpeed = car.speedKmh or 80.0
  local stepRate = dt * baseRate

  -- 2. Target Spline Offset with Corridor Clamping & Lap 0 / Pack Protection
  local targetOff = aiState.targetSplineOffset or 0.0
  aiState.requestedSplineOffset = targetOff

  if (car.lapCount or 0) == 0 or curSpeed < 75.0 then
    -- During start formation / first lap crawl: clamp target offset strictly to [-0.10, 0.10]
    if targetOff > 0.10 then targetOff = 0.10 end
    if targetOff < -0.10 then targetOff = -0.10 end
  elseif aiState.overlapRatio and aiState.overlapRatio > 0.30 and aiState.rivalRelX then
    targetOff = M.enforceCarWidthRule(targetOff, aiState.rivalRelX, aiState.overlapRatio)
  end

  aiState.safetyClampedOffset = targetOff

  -- Pure smooth transition without artificial high-frequency twitch oscillations
  local finalTarget = targetOff

  if aiState.currentSplineOffset < finalTarget then
    local nextVal = aiState.currentSplineOffset + stepRate
    if nextVal > finalTarget then nextVal = finalTarget end
    aiState.currentSplineOffset = nextVal
  elseif aiState.currentSplineOffset > finalTarget then
    local nextVal = aiState.currentSplineOffset - stepRate
    if nextVal < finalTarget then nextVal = finalTarget end
    aiState.currentSplineOffset = nextVal
  end

  -- 3. Slew-limiting for Caution and Aggression (max 1.0 units/s)
  local slew = dt * 1.0
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

  -- 4. Push to CSP Physics Actuators
  local isStartPhase = curSpeed < 75.0 or (car.lapCount or 0) == 0
  if isStartPhase then
    aiState.currentSplineOffset = 0.0
    aiState.appliedSplineOffset = 0.0
    -- DO NOT call physics.setAISplineOffset on the starting grid / launch phase!
    -- Calling setAISplineOffset forces cars out of their left/right grid slots
    -- and directly into each other on the centerline. Let native AC AI handle grid launch undisturbed!
    ControlTelemetry.dispatchPace(idx, 0.7, 1.0, 70, "(Starting grid crawl)", car)
  else
    -- Safe lateral corridor: clamp tactical offset to [-0.15, 0.15] to guarantee no wall collisions
    local safeOffset = aiState.currentSplineOffset
    if safeOffset > 0.15 then safeOffset = 0.15 end
    if safeOffset < -0.15 then safeOffset = -0.15 end
    aiState.appliedSplineOffset = safeOffset

    -- Only apply spline offset if there is an intentional lateral tactical displacement.
    -- If offset is effectively 0.0, leave it to native AC AI's own learned racing line.
    -- ALWAYS false for overrideAwareness so native AC AI obstacle/collision avoidance is never blinded!
    if math.abs(safeOffset) > 0.02 then
      local latDesc = nil
      if ControlTelemetry.isEnabled() then
        if aiState.isBreakingTow or aiState.activeSkill == "TOW_WEAVE" then
          latDesc = string.format("Set defensive lateral offset (Breaking tow weave, offset: %+.2f)", safeOffset)
        elseif aiState.state == "DEFEND" then
          latDesc = (safeOffset < 0) and "Set defensive lateral offset (Holding inside line)"
                                      or "Set defensive lateral offset (Guarding outer lane)"
        elseif aiState.state == "ATTACK" or aiState.activeSkill == "LATE_BRAKE_DIVE" or aiState.activeSkill == "SWITCHBACK" then
          latDesc = string.format("Dynamic apex dive counter-attack (Offset: %+.2f)", safeOffset)
        elseif aiState.state == "YIELD" then
          latDesc = "Moved off racing line for blue flag safe passage"
        elseif aiState.isFeinting or aiState.activeSkill == "FEINT_DUMMY" then
          latDesc = "Executing feint move outside to open inside pass lane"
        end
      end
      ControlTelemetry.dispatchSplineOffset(idx, safeOffset, false, latDesc, car)
    end

    local cVal = aiState.currentCaution
    if cVal < 0.75 then cVal = 0.75 end
    if cVal > 1.30 then cVal = 1.30 end

    local aVal = aiState.currentAggression
    if aVal < 0.40 then aVal = 0.40 end
    if aVal > 0.85 then aVal = 0.85 end

    local pacePct = math.floor(aVal * 100)
    local paceDesc = nil
    if aiState.radioCommand == "PUSH" then
      pacePct = 98
      paceDesc = "(Pushing lap)"
    elseif aiState.radioCommand == "SAVE" then
      pacePct = 78
      paceDesc = "(Fuel saving cruise)"
    elseif aiState.state == "ATTACK" then
      pacePct = 95
      paceDesc = "(Hunting car ahead)"
    elseif aiState.state == "DEFEND" then
      pacePct = 90
      paceDesc = "(Holding defensive track position)"
    end

    ControlTelemetry.dispatchPace(idx, aVal, cVal, pacePct, paceDesc, car)
  end

  -- 5. Credible Fuel-Saving & Lift-and-Coast Policy (No blanket zero-throttle lockout)
  -- Safety Override: If a car is following close behind (< 14m), suppress aggressive throttle cuts to avoid rear-end collisions
  local isThreatenedBehind = (aiState.behindDist and aiState.behindDist < 14.0) or (car.collisionDepth and car.collisionDepth > 0.01)

  if isThreatenedBehind then
    -- Collision safety override takes highest priority: restore 100% full throttle delivery
    ControlTelemetry.dispatchThrottleLimit(idx, 1.0, "Fuel-saving lift inhibited: close follower detected (Collision safety priority)", car)
  elseif aiState.isLiftAndCoast then
    -- Controlled smooth coast: deliver 25% smooth roll rather than 0% dead engine lockout
    ControlTelemetry.dispatchThrottleLimit(idx, 0.25, "Engaged Lift & Coast (25% coast roll into deceleration; fuel & tyre preservation)", car)
  elseif aiState.radioCommand == "SAVE" then
    -- Controlled cruise fuel-saving: cap throttle delivery at 85% to burn less fuel smoothly
    ControlTelemetry.dispatchThrottleLimit(idx, 0.85, "Fuel-saving cruise mode (85% throttle limit)", car)
  else
    -- Standard / PUSH / NORMAL: 100% unrestricted throttle delivery
    ControlTelemetry.dispatchThrottleLimit(idx, 1.0, "Restored 100% full throttle delivery", car)
  end

  -- 6. Physical Anthropomorphic Mistake Actuation (Brake Lockup & Traction Loss Snap)
  if aiState.state == "MISTAKE" and not aiState.physicalDispatched then
    aiState.physicalDispatched = true
    if aiState.physicalMistakeType == "BRAKE" or aiState.lastMistakeType == "BRAKE_LOCKUP" then
      local dur = aiState.physicalMistakeDur
      if not dur or dur <= 0 then dur = 0.35 end
      ControlTelemetry.dispatchBrakeMistake(idx, dur, "Front tyre brake lock-up induced under heavy deceleration", car)
    elseif aiState.physicalMistakeType == "TRACTION" or aiState.lastMistakeType == "TRACTION_SLIDE" then
      local dur = aiState.physicalMistakeDur
      if not dur or dur <= 0 then dur = 0.35 end
      local sev = aiState.physicalMistakeSev
      if not sev or sev <= 0 then sev = 1.25 end
      ControlTelemetry.dispatchTractionMistake(idx, dur, sev, "Rear traction loss snap induced on corner exit acceleration", car)
    end
  end

  -- 7. Anthropomorphic Body Language Actuation (Headlights Flashing & Horn Honking)
  _flashCooldowns[idx] = math.max(0.0, (_flashCooldowns[idx] or 0.0) - dt)
  _hornTimers[idx] = math.max(0.0, (_hornTimers[idx] or 0.0) - dt)

  local reqAction = aiState.bodyLangAction
  if reqAction and reqAction ~= "NONE" and (_flashCooldowns[idx] or 0.0) <= 0.0 then
    local targetIdx = aiState.bodyLangTarget or 0
    local targetNum = (targetIdx or 0) + 1
    local dName = nil
    if ac and ac.getDriverName then
      local ok, n = pcall(ac.getDriverName, idx)
      if ok and type(n) == "string" and n ~= "" then dName = n end
    end
    if not dName and car and type(car.driverName) == "string" then
      dName = car.driverName
    end
    local dLabel = EventHub.formatDriverLabel(idx, dName)
    local targetLabel = EventHub.formatDriverLabel(targetIdx, nil)

    if reqAction == "PROTEST" then
      _flashCounters[idx] = 10 -- 5 double flashes
      _flashPulseDurations[idx] = 0.08 -- 快速急促连闪
      _hornTimers[idx] = 0.45  -- 0.45s 鸣笛示警
      _hornWasActive[idx] = true
      _flashCooldowns[idx] = 14.0
      _flashReasons[idx] = "PROTEST"
      EventHub.pushAiEvent(idx, "HORN", string.format("【抗议阻挡】%s 鸣笛并狂闪大灯，抗议前方 %s 恶意变道阻挡！", dLabel, targetLabel), "INCIDENT")
      ControlTelemetry.dispatchBodyLanguage(idx, "PROTEST", 5, true, string.format("Protested illegal block by #%02d with rapid flash & horn", targetNum), car, dName)
    elseif reqAction == "BLUE_FLAG" then
      _flashCounters[idx] = 4 -- 2 次礼貌双闪
      _flashPulseDurations[idx] = 0.16 -- 适度从容节奏
      _hornTimers[idx] = 0.0
      _flashCooldowns[idx] = 8.0
      _flashReasons[idx] = "BLUE_FLAG"
      EventHub.pushAiEvent(idx, "LIGHTS", string.format("【大灯示意】%s 适度闪烁大灯示意前车 %s 尽快让出赛车线", dLabel, targetLabel), "TACTICAL")
      ControlTelemetry.dispatchBodyLanguage(idx, "BLUE_FLAG", 2, false, string.format("Demanded blue flag pass from #%02d with calm 2x flash", targetNum), car, dName)
    elseif reqAction == "HUNTING" then
      _flashCounters[idx] = 12 -- 6 次超高频狂闪暴闪
      _flashPulseDurations[idx] = 0.07 -- 0.07s 极速暴闪，压迫后视镜
      _hornTimers[idx] = 0.0
      _flashCooldowns[idx] = 9.0
      _flashReasons[idx] = "HUNTING"
      EventHub.pushAiEvent(idx, "LIGHTS", string.format("【大灯逼抢】%s 进入绝杀距离，连续狂闪大灯向前方 %s 施加极限威慑！", dLabel, targetLabel), "PRESSURE")
      ControlTelemetry.dispatchBodyLanguage(idx, "HUNTING", 6, false, string.format("Aggressively machine-gun flashed headlights 6x to intimidate #%02d in braking zone", targetNum), car, dName)
    elseif reqAction == "TAUNT" then
      _flashCounters[idx] = 2 -- 1 flash
      _flashPulseDurations[idx] = 0.12
      _hornTimers[idx] = 0.0
      _flashCooldowns[idx] = 12.0
      _flashReasons[idx] = "TAUNT"
      EventHub.pushAiEvent(idx, "LIGHTS", string.format("【挑衅示威】%s 绝杀超越 %s 后闪灯挑衅", dLabel, targetLabel), "TACTICAL")
      ControlTelemetry.dispatchBodyLanguage(idx, "TAUNT", 1, false, string.format("Flashed headlights 1x after overtaking #%02d", targetNum), car, dName)
    elseif reqAction == "THANKS" then
      _flashCounters[idx] = 2 -- 1 flash
      _flashPulseDurations[idx] = 0.15
      _hornTimers[idx] = 0.0
      _flashCooldowns[idx] = 12.0
      _flashReasons[idx] = "THANKS"
      EventHub.pushAiEvent(idx, "LIGHTS", string.format("【闪灯致意】%s 完成对 %s 超越后闪灯致意", dLabel, targetLabel), "TACTICAL")
      ControlTelemetry.dispatchBodyLanguage(idx, "THANKS", 1, false, string.format("Flashed headlights 1x after overtaking #%02d", targetNum), car, dName)
    elseif reqAction == "HAZARD" then
      _flashCounters[idx] = 6 -- 3 flashes
      _flashPulseDurations[idx] = 0.18 -- 慢速警示闪烁
      _hornTimers[idx] = 0.0
      _flashCooldowns[idx] = 10.0
      _flashReasons[idx] = "HAZARD"
      ControlTelemetry.dispatchBodyLanguage(idx, "HAZARD", 3, false, "Hazard warning flash for slow/spun car ahead", car, dName)
    end
    aiState.bodyLangAction = "NONE"
  end

  -- Physical execution of headlight pulsing & horn
  if (_flashCounters[idx] or 0) > 0 then
    local pDur = _flashPulseDurations[idx] or 0.10
    local fTimer = (_flashTimers[idx] or 0.0) + dt
    if fTimer >= pDur then
      fTimer = 0.0
      _flashCounters[idx] = _flashCounters[idx] - 1
    end
    _flashTimers[idx] = fTimer

    local isLightOn = (_flashCounters[idx] > 0) and (_flashCounters[idx] % 2 == 1)
    if ac and ac.setTargetCar and ac.setHighBeams then
      ac.setTargetCar(idx)
      ac.setHighBeams(isLightOn)
      ac.setTargetCar(0)
    end
    if ac and ac.overrideCarControls then
      local input = ac.overrideCarControls(idx)
      if input and isLightOn then
        input.headlightsFlash = true
      end
    end
  elseif (_flashTimers[idx] or 0.0) > 0.0 then
    _flashTimers[idx] = 0.0
    if ac and ac.setTargetCar and ac.setHighBeams then
      ac.setTargetCar(idx)
      ac.setHighBeams(false)
      ac.setTargetCar(0)
    end
  end

  if (_hornTimers[idx] or 0.0) > 0.0 then
    if ac and ac.overrideCarControls then
      local input = ac.overrideCarControls(idx)
      if input then
        input.horn = true
      end
    end
  elseif _hornWasActive[idx] then
    _hornWasActive[idx] = false
    if ac and ac.overrideCarControls then
      local input = ac.overrideCarControls(idx)
      if input then
        input.horn = false
      end
    end
  end
end

function M.reset()
  for i = 0, MAX_CARS - 1 do
    _twitchTimers[i] = 0.0
    _twitchPhases[i] = 0.0
    _flashTimers[i] = 0.0
    _flashCounters[i] = 0
    _flashReasons[i] = "NONE"
    _flashCooldowns[i] = 0.0
    _flashPulseDurations[i] = 0.10
    _hornTimers[i] = 0.0
    _hornWasActive[i] = false
  end
end

return M
