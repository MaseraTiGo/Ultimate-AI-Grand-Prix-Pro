--[[
  TacticalTicker.lua
  PersonaAI v2.0.0-NextGen: High-Performance Tactical Ticker & Perception Pipeline
  
  Responsibilities:
    1. Human Perception Latency Buffer (Ring Buffer, 4 slots = ~200ms delay):
       - Eliminates instant non-human telepathic defense.
       - Attention Fixation in heavy braking zones reduces rear awareness.
    2. High-Order Racecraft:
       - Switchback / Undercut Counter: Late-apex cut when rival divebombs.
       - Gentle Squeeze: Gradual lateral slope pushing rival to dirty side.
       - Commitment Hold (0.7s) to prevent lateral weaving.
       - Eau Rouge / Maggotts Curvature Lookahead lockout.
    3. Integration with MistakeEngine & BehaviorActuator.
    4. Pure scalar math, zero dynamic memory allocation, NYI-free.
]]

local MistakeEngine = require("lib/driver/MistakeEngine")
local BehaviorActuator = require("lib/driver/BehaviorActuator")
local LODScheduler = require("lib/driver/LODScheduler")
local TelemetryBridge = require("lib/bridge/TelemetryBridge")
local watchdog = require("lib/driver/watchdog")
local SkillArbitrator = require("lib/skills/SkillArbitrator")

local M = {}

M.STATE_CRUISE = "CRUISE"
M.STATE_ATTACK = "ATTACK"
M.STATE_DEFEND = "DEFEND"
M.STATE_MISTAKE = "MISTAKE"
M.STATE_YIELD = "YIELD"
M.STATE_SWITCHBACK = "SWITCHBACK"
M.STATE_BOXING = "BOXING"

local MAX_CARS = 24
local RING_SIZE = 4 -- 4 slots @ 10Hz = 0.4s history buffer (covers 160-280ms human delay)

-- Preallocated Flat State Pool
local _aiStates = {}
local _trackHotspots = {}

for i = 0, MAX_CARS - 1 do
  _aiStates[i] = {
    index = i,
    state = M.STATE_CRUISE,
    activeSkill = "NONE",
    stress = 0.0,
    targetSplineOffset = 0.0,
    currentSplineOffset = 0.0,
    targetCaution = 1.0,
    currentCaution = 1.0,
    targetAggression = 0.7,
    currentAggression = 0.7,
    recoveryTimer = 0.0,
    defendMoveDone = false,
    decoyTimer = 0.0,
    decoyOffset = 0.0,
    lastMistakeType = "NONE",
    slipstreamActive = false,
    commitTimer = 0.0,
    committedState = nil,
    dirtyAirLoss = 0.0,
    mistakeGripPenalty = 0.0,
    switchbackTimer = 0.0,
    overlapRatio = 0.0,
    rivalRelX = 0.0,
    aheadDist = 999.0,
    behindDist = 999.0,
    persona = nil,

    -- Dynamic Feint / Dummy Move (Two-phase attack deception)
    feintTimer = 0.0,
    feintOffset = 0.0,
    isFeinting = false,

    -- Tire Cooking & Defense Heat Degradation
    defenseHeatTimer = 0.0,
    tireTempNorm = 1.0, -- 1.0 (nominal) up to 1.6 (cooked / overheated)
    outLapColdGrip = 1.0, -- 0.92 ~ 1.0 (cold tyre warmup ramp)

    -- v3.0.0 Momentum & Flow State (-1.0 Tilt to +1.0 Flow)
    momentum = 0.0,
    isInFlow = false,
    isTilting = false,

    -- v3.0.0 Breaking the Tow & Lift and Coast
    isBreakingTow = false,
    towBreakTimer = 0.0,
    towBreakOffset = 0.0,
    isLiftAndCoast = false,

    -- Perception Ring Buffer (flat array of 4 history snapshots)
    ringHead = 1,
    ringInitialized = false,
    ringDist = { 999.0, 999.0, 999.0, 999.0 },
    ringSpeedDelta = { 0.0, 0.0, 0.0, 0.0 },
    ringTTC = { 999.0, 999.0, 999.0, 999.0 },
  }
end

function M.getAiState(carIndex)
  return _aiStates[carIndex] or _aiStates[0]
end

function M.recordTrackIncident(splinePos)
  if not splinePos then return end
  local bin = math.floor(splinePos * 20.0)
  _trackHotspots[bin] = (_trackHotspots[bin] or 0) + 1
end

function M.getHotspotDanger(splinePos)
  if not splinePos then return 0.0 end
  local bin = math.floor(splinePos * 20.0)
  local hits = _trackHotspots[bin] or 0
  local d = hits * 0.3
  if d > 1.0 then d = 1.0 end
  return d
end

--- Push instant observation into Ring Buffer and retrieve physiologically delayed view
---@param s table AI State struct
---@param dist number Instant distance
---@param speedDelta number Instant closing speed (m/s)
---@param ttc number Instant TTC
---@param delayFrames integer 1 to 3 frames delay
---@return number delayedDist, number delayedSpeedDelta, number delayedTTC
local function processPerceptionBuffer(s, dist, speedDelta, ttc, delayFrames)
  if not s.ringInitialized then
    s.ringInitialized = true
    for k = 1, RING_SIZE do
      s.ringDist[k] = dist
      s.ringSpeedDelta[k] = speedDelta
      s.ringTTC[k] = ttc
    end
    s.ringHead = 1
    return dist, speedDelta, ttc
  end

  -- Record observation into current head slot
  local writeIdx = s.ringHead
  s.ringDist[writeIdx] = dist
  s.ringSpeedDelta[writeIdx] = speedDelta
  s.ringTTC[writeIdx] = ttc

  -- Calculate read index: readIdx is writeIdx minus delayFrames
  local readIdx = writeIdx - delayFrames
  while readIdx < 1 do
    readIdx = readIdx + RING_SIZE
  end

  -- Advance head for next frame
  local nextHead = writeIdx + 1
  if nextHead > RING_SIZE then nextHead = 1 end
  s.ringHead = nextHead

  return s.ringDist[readIdx], s.ringSpeedDelta[readIdx], s.ringTTC[readIdx]
end

--- High-speed corner lookahead & heavy lateral G lockout
local function checkCurvatureSafe(car)
  if not car then return true end
  local spd = car.speedKmh or 0.0
  if spd > 160.0 and car.acceleration and car.acceleration.x then
    if math.abs(car.acceleration.x) > 5.88 then
      return false
    end
  end

  if car.look and car.velocity then
    local speed = car.velocity:length()
    if speed > 40.0 then
      local vNormX = car.velocity.x / speed
      local vNormY = car.velocity.y / speed
      local vNormZ = car.velocity.z / speed
      local dot = car.look.x * vNormX + car.look.y * vNormY + car.look.z * vNormZ
      if dot < 0.96 then
        return false
      end
    end
  end

  return true
end

--- Calculate continuous dynamic psychological stress
local function computeStress(s, dist, deltaV, persona, raceContext, dt)
  local w_dist = 1.2
  local w_speed = 0.8
  local resist = persona and persona.pressure_resist or 0.6
  local decayRate = 0.35 * resist

  local contextMod = 1.0
  if raceContext then
    if raceContext.isLastLap then contextMod = contextMod * 1.35 end
    if raceContext.tyreWear and raceContext.tyreWear > 0.6 then
      contextMod = contextMod * (1.0 + (raceContext.tyreWear - 0.6) * 0.8)
    end
  end

  local pressureInc = 0.0
  if dist > 0.1 and dist < 25.0 then
    local safeD = dist
    if safeD < 0.5 then safeD = 0.5 end
    local dv = deltaV
    if dv < 0.0 then dv = 0.0 end
    pressureInc = ((w_dist * (1.0 / safeD) + w_speed * dv) * contextMod) * dt
  end

  local newStress = s.stress + pressureInc - (decayRate * dt)
  if newStress < 0.0 then newStress = 0.0 end
  if newStress > 10.0 then newStress = 10.0 end
  return newStress
end

--- Main 10Hz Tactical Decision Tick for AI Car
--- Pure scalar mathematics, NYI-free
---@param car ac.StateCar
---@param aheadCar ac.StateCar?
---@param behindCar ac.StateCar?
---@param persona table
---@param rivalryScore number
---@param raceContext table?
---@param dt number
---@return table aiState
function M.stepCar(car, aheadCar, behindCar, persona, rivalryScore, raceContext, dt)
  if type(raceContext) == "number" and dt == nil then
    dt = raceContext
    raceContext = nil
  end
  dt = dt or 0.1
  local idx = car.index
  local s = _aiStates[idx] or _aiStates[0]
  s.persona = persona

  -- 0. Check Blue Flag yielding condition
  if raceContext and raceContext.isBlueFlagged and behindCar then
    s.state = M.STATE_YIELD
    s.activeSkill = "YIELD"
    s.targetSplineOffset = 0.75 -- Pull to outer safe line
    s.targetCaution = 1.8
    s.targetAggression = 0.3
    s.stress = s.stress - dt * 0.5
    if s.stress < 0.0 then s.stress = 0.0 end
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 1. Handle Active Recovery / Mistake / Switchback States
  if s.state == M.STATE_MISTAKE then
    s.activeSkill = "NONE"
    s.recoveryTimer = s.recoveryTimer - dt
    if s.recoveryTimer <= 0 then
      s.state = M.STATE_CRUISE
      s.stress = s.stress * 0.5
      s.targetSplineOffset = 0.0
      s.mistakeGripPenalty = 0.0
      s.targetCaution = persona and persona.base_caution or 1.0
    else
      -- Progressive recovery: caution smoothly relaxes as recovery timer expires
      local recovProgress = 1.0 - (s.recoveryTimer / 2.0)
      if recovProgress < 0.0 then recovProgress = 0.0 end
      if recovProgress > 1.0 then recovProgress = 1.0 end
      s.targetCaution = 2.0 - recovProgress * 0.8 -- drops from 2.0 to 1.2
      s.mistakeGripPenalty = (s.mistakeGripPenalty or 0.0) * (1.0 - recovProgress * 0.5)

      -- Recovery caution & grip adjustments are handled through s.targetCaution and s.mistakeGripPenalty
      -- Native AC AI pathfinding and physics solver handle steering and braking safely without control hijack

      -- If under sustained pressure while recovering, tyres cook
      if behindCar then
        s.defenseHeatTimer = (s.defenseHeatTimer or 0.0) + dt
        if s.defenseHeatTimer > 2.0 then
          s.tireTempNorm = math.min(1.50, (s.tireTempNorm or 1.0) + dt * 0.06)
          if raceContext then raceContext.tyreTempNorm = s.tireTempNorm end
        end
      end

      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    end
  end

  if s.state == M.STATE_SWITCHBACK then
    s.switchbackTimer = s.switchbackTimer - dt
    if s.switchbackTimer <= 0 then
      s.state = M.STATE_CRUISE
      s.targetSplineOffset = 0.0
    else
      -- Maintain late apex switchback counter-attack line
      s.targetAggression = 0.95
      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    end
  end

  -- 2. Sensory Acquisition with Perception Latency Buffer
  local instantDist = 999.0
  local instantDeltaV = 0.0
  local instantTTC = 999.0

  if behindCar and car.position and behindCar.position then
    local dx = car.position.x - behindCar.position.x
    local dy = car.position.y - behindCar.position.y
    local dz = car.position.z - behindCar.position.z
    instantDist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if instantDist < 0.1 then instantDist = 0.1 end

    local vBehind = behindCar.speedKmh or 0.0
    local vMe = car.speedKmh or 0.0
    instantDeltaV = (vBehind - vMe) / 3.6
    if instantDeltaV > 0.5 then
      instantTTC = instantDist / instantDeltaV
    end
  end

  -- Physiological Latency Buffer (2 frames ~ 200ms delay for average human, 1 frame for top stars)
  local latencyFrames = 2
  if persona and (persona.pressure_resist or 0.6) > 0.85 then
    latencyFrames = 1
  end

  -- Flow state bonus: shrink perception latency to 1 frame
  if s.isInFlow then
    latencyFrames = 1
  end

  -- Attention Fixation: in heavy braking zone (G > 1.2G), driver is fixated on apex -> latency degrades to 3 frames
  if car.acceleration and car.acceleration.z and car.acceleration.z < -11.76 then
    latencyFrames = 3
  end

  local behindDist, behindSpeedDelta, ttcBehind = processPerceptionBuffer(s, instantDist, instantDeltaV, instantTTC, latencyFrames)
  s.behindDist = behindDist

  -- 3. Calculate Dynamic Stress Level
  s.stress = computeStress(s, behindDist, behindSpeedDelta, persona, raceContext, dt)

  -- Update Dynamic Momentum & Flow State (-1.0 Tilt to +1.0 Flow)
  local momentumDelta = 0.0
  if raceContext and raceContext.tyreWear and raceContext.tyreWear > 0.65 then
    momentumDelta = momentumDelta - dt * 0.25
  end
  if raceContext and raceContext.isBlueFlagged then
    momentumDelta = momentumDelta - dt * 0.30
  end
  if s.stress > 4.0 then
    momentumDelta = momentumDelta - dt * 0.30
  else
    -- Clean running / low stress accumulates positive momentum
    momentumDelta = momentumDelta + dt * 0.15
  end

  s.momentum = s.momentum + momentumDelta
  if s.momentum > 1.0 then s.momentum = 1.0 end
  if s.momentum < -1.0 then s.momentum = -1.0 end

  s.isInFlow = (s.momentum >= 0.50)
  s.isTilting = (s.momentum <= -0.40)

  -- 4. Multi-axial Micro-Mistake Matrix Evaluation
  local hotspotDanger = M.getHotspotDanger(car.splinePosition)
  -- If in Flow, mistake chance halved. If Tilting, mistake chance doubled.
  local effectiveStress = s.stress
  if s.isInFlow then
    effectiveStress = effectiveStress * 0.5
  elseif s.isTilting then
    effectiveStress = math.min(10.0, effectiveStress * 1.5 + 1.0)
  end

  local mType, mDur, mOff, mCaut, mGrip = MistakeEngine.rollMistake(idx, effectiveStress, persona, rivalryScore, hotspotDanger, dt)
  if mType ~= MistakeEngine.TYPE_NONE then
    s.state = M.STATE_MISTAKE
    s.lastMistakeType = mType
    s.recoveryTimer = mDur
    s.targetSplineOffset = mOff
    s.targetCaution = mCaut
    s.mistakeGripPenalty = math.abs(mGrip)
    M.recordTrackIncident(car.splinePosition)
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 5. Radio Command Override (BOX_THIS_LAP priority for pit entry)
  local radioCmd = raceContext and raceContext.radioCommand or "NONE"
  if radioCmd == "BOX_THIS_LAP" then
    s.state = M.STATE_BOXING
    s.activeSkill = "NONE"
    s.targetCaution = 1.4
    s.targetSplineOffset = 0.65
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 6. X-Skill Arbitrator Execution & Evaluation
  local hasSkill, sOffset, sCaution, sAggression, extraGrip = SkillArbitrator.stepCarSkill(
    car, aheadCar, behindCar, persona, rivalryScore, raceContext, s, dt
  )

  if hasSkill then
    local skillCtx = SkillArbitrator.getContext(idx)
    s.activeSkill = skillCtx.activeSkillName or "SKILL"
    s.state = s.activeSkill
    s.targetSplineOffset = sOffset
    s.targetCaution = sCaution
    s.targetAggression = sAggression

    -- Track specialized flags for downstream systems / UI
    s.isBreakingTow = (s.activeSkill == "TOW_WEAVE")
    s.isFeinting = (s.activeSkill == "FEINT_DUMMY")

    -- Update tyre thermal effects if engaging in aggressive defense
    if s.activeSkill == "TOW_WEAVE" or s.activeSkill == "GENTLE_SQUEEZE" then
      s.defenseHeatTimer = (s.defenseHeatTimer or 0.0) + dt
      if s.defenseHeatTimer > 2.0 then
        s.tireTempNorm = math.min(1.50, (s.tireTempNorm or 1.0) + dt * 0.06)
        if raceContext then raceContext.tyreTempNorm = s.tireTempNorm end
      end
    else
      if s.tireTempNorm and s.tireTempNorm > 1.0 then
        s.tireTempNorm = math.max(1.0, s.tireTempNorm - dt * 0.03)
        if raceContext then raceContext.tyreTempNorm = s.tireTempNorm end
      end
      s.defenseHeatTimer = 0.0
    end

    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  else
    s.activeSkill = "NONE"
  end

  -- 7. Legacy Commitment Hold & Baseline Fallbacks
  if s.commitTimer > 0.0 then
    s.commitTimer = s.commitTimer - dt
    if s.committedState == M.STATE_DEFEND and behindCar and (behindDist < 35.0) then
      s.state = M.STATE_DEFEND
      -- Maintain tire cooking progression during committed defense
      s.defenseHeatTimer = (s.defenseHeatTimer or 0.0) + dt
      if s.defenseHeatTimer > 2.0 then
        s.tireTempNorm = math.min(1.50, (s.tireTempNorm or 1.0) + dt * 0.06)
        s.targetCaution = math.min(2.2, s.targetCaution + 0.15 * (s.tireTempNorm - 1.0))
        if raceContext then raceContext.tyreTempNorm = s.tireTempNorm end
      end
      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    elseif s.committedState == M.STATE_ATTACK and aheadCar and (s.aheadDist < 40.0) and not s.isFeinting then
      s.state = M.STATE_ATTACK
      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    else
      s.commitTimer = 0.0
      s.committedState = nil
    end
  end

  -- 6. Switchback / Undercut Detection (Rival Divebomb Counter)
  local isDivebombThreat = (instantDeltaV > 8.0 and instantTTC < 1.0 and instantDist < 18.0) or
                           (behindSpeedDelta > 8.0 and ttcBehind < 1.0 and behindDist < 18.0)
  if behindCar and isDivebombThreat then
    s.state = M.STATE_SWITCHBACK
    s.switchbackTimer = 1.8
    s.targetSplineOffset = 0.50
    s.targetCaution = 0.3
    s.targetAggression = 0.95
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 7. Threat Defense State (Delayed TTC < 1.5s & Dist < 25m)
  if ttcBehind < 1.5 and behindDist < 25.0 then
    local isSafeToDefend = checkCurvatureSafe(car)
    if isSafeToDefend then
      s.state = M.STATE_DEFEND
      s.committedState = M.STATE_DEFEND
      s.commitTimer = 0.7

      if not s.defendMoveDone then
        s.defendMoveDone = true
        local blockWidth = 0.55 * (persona.block_tendency or 0.7) + ((rivalryScore or 0) * 0.03)
        local behindRelX = 0.0
        if car.worldToLocal and behindCar and behindCar.position then
          local localBehind = car.worldToLocal:transformPoint(behindCar.position)
          behindRelX = localBehind.x
        end

        s.rivalRelX = behindRelX
        -- Side-by-side overlap ratio estimation
        local overlap = 0.0
        if behindDist < 6.0 then
          overlap = 1.0 - (behindDist / 6.0)
        end
        s.overlapRatio = overlap

        if behindRelX > 0.2 then
          s.targetSplineOffset = math.min(0.85, blockWidth)
        else
          s.targetSplineOffset = -math.min(0.85, blockWidth)
        end
      end

      local baseC = persona.base_caution or 1.0
      local tgtC = baseC * 0.4 - ((rivalryScore or 0) * 0.05)
      if s.isTilting then
        tgtC = tgtC * 0.7 -- Tilt causes late braking / overaggressive dive
      end
      if tgtC < 0.15 then tgtC = 0.15 end
      s.targetCaution = tgtC

      local baseA = persona.base_aggression or 0.75
      local tgtA = baseA * 1.2
      if tgtA > 0.98 then tgtA = 0.98 end
      s.targetAggression = tgtA

      -- Tire Cooking Mechanism: Prolonged intense defense (> 2.0s under pressure) overheats tyres
      s.defenseHeatTimer = (s.defenseHeatTimer or 0.0) + dt
      if s.defenseHeatTimer > 2.0 then
        s.tireTempNorm = math.min(1.50, (s.tireTempNorm or 1.0) + dt * 0.06)
        -- Overheated tyre penalty: degrades effective caution and introduces subtle micro-slip
        s.targetCaution = math.min(2.2, s.targetCaution + 0.15 * (s.tireTempNorm - 1.0))
        if raceContext then
          raceContext.tyreTempNorm = s.tireTempNorm
        end
      end

      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    end
  else
    s.defendMoveDone = false
    -- Gradually cool tyres when not defending hard
    if s.tireTempNorm and s.tireTempNorm > 1.0 then
      s.tireTempNorm = math.max(1.0, s.tireTempNorm - dt * 0.03)
      if raceContext then raceContext.tyreTempNorm = s.tireTempNorm end
    end
    s.defenseHeatTimer = 0.0
  end

  -- 7.5 Breaking the Tow & Weaving (Straight defense when tailgated < 30m)
  s.isBreakingTow = false
  local isStraight = checkCurvatureSafe(car)
  local mySpeed = car.speedKmh or 0.0
  if isStraight and mySpeed > 100.0 and behindCar and behindDist < 30.0 and behindDist > 6.0 and (not aheadCar or s.aheadDist > 40.0) then
    local aggr = persona and (persona.base_aggression or 0.7) or 0.7
    if aggr > 0.72 then
      s.isBreakingTow = true
      s.towBreakTimer = s.towBreakTimer + dt
      -- Oscillate weave: +/-0.35 spline units @ ~3.0 rad/s
      s.towBreakOffset = math.sin(s.towBreakTimer * 3.0) * 0.35
      s.targetSplineOffset = s.towBreakOffset
      s.targetCaution = 0.8
      s.targetAggression = aggr

      -- Intense weaving under tailgating also builds tire thermal load
      s.defenseHeatTimer = (s.defenseHeatTimer or 0.0) + dt
      if s.defenseHeatTimer > 2.0 then
        s.tireTempNorm = math.min(1.50, (s.tireTempNorm or 1.0) + dt * 0.06)
        if raceContext then raceContext.tyreTempNorm = s.tireTempNorm end
      end

      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    end
  else
    s.towBreakTimer = 0.0
    s.towBreakOffset = 0.0
  end

  -- 7.8 Radio Command & Strategy Orders / Lift and Coast
  s.isLiftAndCoast = false
  local tyreWear = (raceContext and raceContext.tyreWear) or 0.0
  local radioCmd = raceContext and raceContext.radioCommand or "NONE"

  if radioCmd == "BOX_THIS_LAP" then
    -- Pit In-Lap preparation: maintain conservative pace, prepare to tuck inside pit line
    s.targetCaution = 1.4
    s.targetSplineOffset = 0.65
  elseif radioCmd == "SAVE" or (tyreWear > 0.65 and isStraight and mySpeed > 120.0 and behindDist > 20.0) then
    -- Lift and Coast (Strategy saving mode or critical tyre wear)
    s.isLiftAndCoast = true
    s.targetCaution = 1.3
    s.targetSplineOffset = -0.15 -- Smooth line avoiding high kerbs
  elseif radioCmd == "PUSH" then
    -- Team Push Order: boost aggression, lower caution, trigger Flow momentum bonus
    s.targetCaution = math.max(0.15, (persona.base_caution or 0.7) * 0.4)
    s.targetAggression = math.min(0.98, (persona.base_aggression or 0.8) * 1.25)
    s.momentum = math.min(1.0, s.momentum + dt * 0.20)
    s.isInFlow = (s.momentum >= 0.50)
  elseif radioCmd == "DEFEND" then
    -- Tactical Hold Position Order
    s.targetCaution = 0.20
    s.targetAggression = 0.95
  end

  -- 8. Attack & Decoy Hunting Moves (Ahead Car)
  local aheadDist = 999.0
  if aheadCar and car.position and aheadCar.position then
    local dx = aheadCar.position.x - car.position.x
    local dy = aheadCar.position.y - car.position.y
    local dz = aheadCar.position.z - car.position.z
    aheadDist = math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  s.aheadDist = aheadDist

  -- Dirty Air Aero Wake understeer
  s.dirtyAirLoss = 0.0
  local mySpd = car.speedKmh or 0.0
  if aheadCar and mySpd > 90.0 and aheadDist < 16.0 then
    local aheadState = _aiStates[aheadCar.index]
    local aheadOff = aheadState and aheadState.currentSplineOffset or 0.0
    local dSpline = math.abs(s.currentSplineOffset - aheadOff)
    if dSpline < 0.40 then
      s.dirtyAirLoss = 0.06 * (1.0 - (aheadDist / 16.0))
    end
  end

  -- Slipstream Tow Seeking (25m ~ 60m)
  if aheadCar and aheadDist >= 25.0 and aheadDist <= 60.0 then
    s.state = M.STATE_ATTACK
    s.slipstreamActive = true
    local aheadState = _aiStates[aheadCar.index]
    s.targetSplineOffset = aheadState and aheadState.currentSplineOffset or 0.0
    s.targetAggression = math.min(0.95, (persona.base_aggression or 0.8) + 0.1)
    s.targetCaution = math.max(0.2, (persona.base_caution or 0.7) * 0.5)
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, tyreWear, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end
  s.slipstreamActive = false

  -- Close Quarters Hunting (< 20m) & Two-Phase Feint / Dummy Move
  if aheadDist < 20.0 and aheadCar then
    s.state = M.STATE_ATTACK
    s.committedState = M.STATE_ATTACK
    s.commitTimer = 0.7
    s.targetAggression = math.min(0.98, (persona.base_aggression or 0.8) + 0.15)
    s.targetCaution = math.max(0.1, (persona.base_caution or 0.5) * 0.3)

    local aggr = persona and persona.base_aggression or 0.75
    -- Two-Phase Feint / Dummy Move: High aggression drivers (> 0.80) feint outside then dive inside
    if aggr > 0.80 and aheadDist < 12.0 and isStraight then
      s.feintTimer = (s.feintTimer or 0.0) + dt
      if s.feintTimer < 0.40 then
        -- Phase 1 (0.0~0.4s): Feint outside (+0.45 offset) to lure defender
        s.targetSplineOffset = 0.45
        s.isFeinting = true
      elseif s.feintTimer < 1.10 then
        -- Phase 2 (0.4~1.1s): Rapid dive inside (-0.50 offset) for the overtake line
        s.targetSplineOffset = -0.50
        s.isFeinting = true
      else
        -- Cooldown
        s.isFeinting = false
        if s.feintTimer >= 3.5 then
          s.feintTimer = 0.0
        end
      end
    else
      s.isFeinting = false
      s.feintTimer = 0.0
      s.decoyTimer = s.decoyTimer - dt
      if s.decoyTimer <= 0.0 then
        if math.random() < (persona.decoy_tendency or 0.4) then
          s.decoyOffset = (math.random() > 0.5 and 0.45 or -0.45)
          s.decoyTimer = 2.0
        else
          s.decoyOffset = 0.0
          s.decoyTimer = 3.0
        end
      end
      s.targetSplineOffset = s.decoyOffset
    end
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, tyreWear, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 9. Default Cruise State
  s.state = M.STATE_CRUISE
  s.committedState = nil
  s.commitTimer = 0.0
  if not s.isLiftAndCoast and radioCmd == "NONE" then
    s.targetSplineOffset = 0.0
    s.targetCaution = persona.base_caution or 1.0
    s.targetAggression = persona.base_aggression or 0.75
  elseif radioCmd == "PUSH" then
    s.targetSplineOffset = 0.0
    -- targetCaution and targetAggression already set by PUSH above
  elseif radioCmd == "DEFEND" then
    -- targetCaution and targetAggression already set by DEFEND above
  end
  TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, tyreWear, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
  return s
end

--- Forward Actuator Application
function M.applyActuator(car, s, dt)
  BehaviorActuator.applyActuator(car, s, dt)
end

function M.init()
  SkillArbitrator.init()
  M.reset()
end

function M.reset()
  SkillArbitrator.reset()
  for i = 0, MAX_CARS - 1 do
    local s = _aiStates[i]
    s.state = M.STATE_CRUISE
    s.activeSkill = "NONE"
    s.stress = 0.0
    s.targetSplineOffset = 0.0
    s.currentSplineOffset = 0.0
    s.commitTimer = 0.0
    s.committedState = nil
    s.switchbackTimer = 0.0
    s.momentum = 0.0
    s.isInFlow = false
    s.isTilting = false
    s.isBreakingTow = false
    s.towBreakTimer = 0.0
    s.towBreakOffset = 0.0
    s.isLiftAndCoast = false
    s.feintTimer = 0.0
    s.feintOffset = 0.0
    s.isFeinting = false
    s.defenseHeatTimer = 0.0
    s.tireTempNorm = 1.0
    s.recoveryTimer = 0.0
    s.lastMistakeType = MistakeEngine.TYPE_NONE
    s.outLapColdGrip = 1.0
    s.ringHead = 1
    s.ringInitialized = false
    for k = 1, RING_SIZE do
      s.ringDist[k] = 999.0
      s.ringSpeedDelta[k] = 0.0
      s.ringTTC[k] = 999.0
    end
  end
end

return M
