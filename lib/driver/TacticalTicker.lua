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
local BattleTracker = require("lib/driver/BattleTracker")

local function safeExtractDriverName(car)
  if not car then return "" end
  local dn = car.driverName
  if type(dn) == "string" then
    return dn
  elseif type(dn) == "function" then
    local ok, res = pcall(dn, car)
    if ok and type(res) == "string" then return res end
  end
  local idx = car.index
  if idx and ac and ac.getDriverName then
    local ok, res = pcall(ac.getDriverName, idx)
    if ok and type(res) == "string" then return res end
  end
  return ""
end

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
    physicalMistakeType = nil,
    physicalMistakeDur = 0.0,
    physicalMistakeSev = 0.0,
    physicalDispatched = false,
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

    -- Anthropomorphic Body Language (Headlights & Horn Agitation)
    bodyLangAction = "NONE",
    bodyLangTarget = -1,
    bodyLangReason = "",
    bodyLangHorn = false,
    bodyLangFlashCount = 0,
    lastAheadIdx = -1,
    overtakeCooldown = 0.0,

    -- Perception Ring Buffer (flat array of 4 history snapshots)
    ringHead = 1,
    ringInitialized = false,
    ringDist = { 999.0, 999.0, 999.0, 999.0 },
    ringSpeedDelta = { 0.0, 0.0, 0.0, 0.0 },
    ringTTC = { 999.0, 999.0, 999.0, 999.0 },

    -- Direction A: Psychological Pressure, MTI & Hunter's Pounce
    mti = 0.0,
    breakdownRisk = 0.0,
    psychStatus = "CALM",
    pounceTimer = 0.0,
    pounceActive = false,
    pounceReported = false,

    -- COBAL Fuzzy Context & Commitment Engine (SCE / DCA / CCM / CPM)
    pursuitCommitment = 0.0,      -- 0.0 ~ 1.0 continuous attack commitment
    pressureCommitment = 0.0,     -- 0.0 ~ 1.0 continuous defensive commitment
    duelCommitment = 0.0,         -- 0.0 ~ 1.0 side-by-side intense battle commitment
    cohesionPacingBonus = 0.0,    -- -0.05 ~ +0.05 dynamic field cohesion pace modifier
    lineVariationOffset = 0.0,    -- subtle natural wandering in free air (-0.05 ~ +0.05)
    variationPhase = math.random() * 6.28,
    isCalmRecovery = false,

    -- Chatter Event Trigger State Trackers
    chatterTyreReported = false,
    chatterBlueReported = false,
    chatterVictoryReported = false,
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

--- High-speed straight verification: low lateral G, forward trajectory
local function checkIsStraight(car)
  if not car then return true end
  local spd = car.speedKmh or 0.0
  if spd < 100.0 then return false end
  if car.acceleration and car.acceleration.x then
    if math.abs(car.acceleration.x) > 2.0 then
      return false
    end
  end
  if car.look and car.velocity then
    local speed = car.velocity:length()
    if speed > 25.0 then
      local vNormX = car.velocity.x / speed
      local vNormY = car.velocity.y / speed
      local vNormZ = car.velocity.z / speed
      local dot = car.look.x * vNormX + car.look.y * vNormY + car.look.z * vNormZ
      if dot < 0.985 then
        return false
      end
    end
  end
  return true
end

--- Calculate Mirror Threat Index (MTI) from chaser dynamics, body language, reputation & stakes
---@param dist number
---@param behindCar table|nil
---@param behindState table|nil
---@param persona table|nil
---@param raceContext table|nil
---@return number mti (0.0 to 3.5)
function M.calculateMTI(dist, behindCar, behindState, persona, raceContext)
  if not dist or dist <= 0.1 or dist > 28.0 then
    return 0.0
  end

  -- Base distance threat: 1.0 at 0m, linearly decaying to 0.0 at 28m
  local baseThreat = 1.0 - (dist / 28.0)
  if baseThreat < 0.0 then baseThreat = 0.0 end

  local kFlash = 0.0
  local kWeave = 0.0
  local kRep = 0.0
  local kStakes = 0.0

  if behindState then
    -- Headlight strobe intimidation
    if behindState.bodyLangAction == "HUNTING" then
      kFlash = 0.45
    end
    -- Weaving / feinting lateral fake movements
    if behindState.isFeinting or behindState.activeSkill == "FEINT_DUMMY" or behindState.activeSkill == "TOW_WEAVE" or behindState.isBreakingTow then
      kWeave = 0.40
    end
  end

  -- Reputation intimidation
  if behindCar then
    local dName = safeExtractDriverName(behindCar)
    if dName ~= "" then
      local lower = string.lower(dName)
      if string.find(lower, "verstappen") or string.find(lower, "alonso") or string.find(lower, "hamilton") or string.find(lower, "leclerc") or string.find(lower, "norris") then
        kRep = 0.35
      end
    end
  end

  -- High-stakes race context
  if raceContext then
    local pos = raceContext.racePosition or (raceContext.leaderDistance and raceContext.leaderDistance < 20.0 and 1) or 99
    if pos <= 3 then
      kStakes = kStakes + 0.30
    end
    if raceContext.isLastLap or (raceContext.totalLaps and raceContext.currentLap and (raceContext.totalLaps - raceContext.currentLap <= 3)) then
      kStakes = kStakes + 0.35
    end
    if raceContext.tyreWear and raceContext.tyreWear > 0.65 then
      kStakes = kStakes + 0.25
    end
  end

  local mti = baseThreat * (1.0 + kFlash + kWeave + kRep + kStakes)
  if mti > 3.5 then mti = 3.5 end
  return mti
end

--- Calculate continuous dynamic psychological stress using MTI and persona resilience
local function computeStress(s, dist, deltaV, persona, raceContext, behindCar, behindState, dt)
  if type(behindCar) == "number" and dt == nil then
    dt = behindCar
    behindCar = nil
    behindState = nil
  end
  dt = dt or 0.1

  local mti = M.calculateMTI(dist, behindCar, behindState, persona, raceContext)
  s.mti = mti

  local pResist = (persona and (persona.mistake_resistance or persona.pressure_resist)) or 0.65
  if pResist > 0.96 then pResist = 0.96 end
  if pResist < 0.20 then pResist = 0.20 end

  local alpha = 1.85
  local beta = 0.45

  -- Flow state or Tilting modifier
  if s.isInFlow then
    alpha = alpha * 0.50 -- Flow halves stress accumulation
  elseif s.isTilting then
    alpha = alpha * 1.60 -- Tilting amplifies stress accumulation by 60%
  end

  -- DeltaV closing bonus: if chaser is rapidly closing (deltaV > 0.5 m/s) within threat range
  local dvBonus = 0.0
  if mti > 0.0 and deltaV and deltaV > 0.5 then
    dvBonus = math.min(1.5, deltaV * 0.35)
  end

  local pressureInc = alpha * (mti + dvBonus) * (1.0 - pResist) * dt
  local decayRate = beta * pResist * dt

  local newStress = s.stress + pressureInc - (decayRate * s.stress)
  if newStress < 0.0 then newStress = 0.0 end
  if newStress > 10.0 then newStress = 10.0 end

  -- Breakdown Risk percentage (0 ~ 100%)
  local risk = 0.0
  if newStress >= 6.0 then
    risk = (newStress - 6.0) / 4.0 * 100.0 -- 0% at 6.0, 100% at 10.0
    if risk > 99.0 then risk = 99.0 end
  end
  s.breakdownRisk = risk

  -- Psychological status classification
  if s.isInFlow then
    s.psychStatus = "FLOW"
  elseif newStress >= 9.0 then
    s.psychStatus = "CRACKING"
  elseif newStress >= 7.5 then
    s.psychStatus = "RATTLED"
  elseif newStress >= 5.0 then
    s.psychStatus = "UNDER_PRESSURE"
  else
    s.psychStatus = "CALM"
  end

  return newStress
end

--- Evaluate Anthropomorphic Body Language (Headlights Flashing & Horn Honking Intent)
--- Scenarios:
---   1. PROTEST: Anger at ahead car's illegal blocking / weave-to-break-tow (Flash 4x + Horn 0.4s)
---   2. BLUE_FLAG: Demanding slower / lapped car to yield racing line (Flash 2x)
---   3. HUNTING: Intimidation & psychological warfare in braking zone (Flash 2x)
---   4. TAUNT / THANKS: Flash 1x upon completing critical overtake
---   5. HAZARD: Warning flash for slow / spun car ahead
local function evaluateBodyLanguage(s, car, aheadCar, behindCar, aheadDist, behindDist, persona, rivalryScore, raceContext, dt)
  s.bodyLangAction = "NONE"
  s.overtakeCooldown = math.max(0.0, (s.overtakeCooldown or 0.0) - dt)

  -- 1. Overtake Taunt or Courtesy Thanks
  if behindCar and s.lastAheadIdx == behindCar.index and behindDist < 12.0 and s.overtakeCooldown <= 0.0 then
    s.overtakeCooldown = 12.0
    if (rivalryScore or 0) > 0.40 and (persona and persona.base_aggression or 0.7) > 0.80 then
      s.bodyLangAction = "TAUNT"
      s.bodyLangTarget = behindCar.index
      s.bodyLangFlashCount = 1
      s.bodyLangHorn = false
      s.bodyLangReason = "绝杀超越后闪灯示威"
    else
      s.bodyLangAction = "THANKS"
      s.bodyLangTarget = behindCar.index
      s.bodyLangFlashCount = 1
      s.bodyLangHorn = false
      s.bodyLangReason = "超越后闪灯致意"
    end
  end

  if aheadCar then
    s.lastAheadIdx = aheadCar.index
    local mySpeed = (car and car.speedKmh) or 0.0
    local aheadSpeed = (aheadCar and aheadCar.speedKmh) or 0.0
    local aheadState = _aiStates[aheadCar.index]

    -- Priority 1: PROTEST (Dirty blocking / weaving / dangerous defense)
    local aheadWeaving = aheadState and (aheadState.isBreakingTow or aheadState.activeSkill == "TOW_WEAVE" or aheadState.activeSkill == "GENTLE_SQUEEZE")
    local highRivalry = ((rivalryScore or 0) > 0.45) or s.isTilting
    if aheadDist < 15.0 and (aheadWeaving or (highRivalry and (s.state == M.STATE_ATTACK or s.activeSkill == "LATE_BRAKE_DIVE"))) then
      s.bodyLangAction = "PROTEST"
      s.bodyLangTarget = aheadCar.index
      s.bodyLangFlashCount = 4
      s.bodyLangHorn = true
      s.bodyLangReason = "抗议恶意变道阻挡"

    -- Priority 2: BLUE_FLAG (Lapping slower / blue-flagged car ahead - 适当节奏礼貌提示让路)
    elseif aheadDist >= 7.0 and aheadDist <= 35.0 and (((car and car.lapCount or 0) > (aheadCar.lapCount or 0)) or (raceContext and raceContext.isLappingAhead)) then
      s.bodyLangAction = "BLUE_FLAG"
      s.bodyLangTarget = aheadCar.index
      s.bodyLangFlashCount = 2
      s.bodyLangHorn = false
      s.bodyLangReason = "示意前车让出赛车线"

    -- Priority 3: HUNTING (Close-quarters attack intimidation - 贴身逼抢/超车连续狂闪后视镜施压)
    elseif (s.state == M.STATE_ATTACK or s.activeSkill == "LATE_BRAKE_DIVE" or s.activeSkill == "SWITCHBACK" or s.activeSkill == "FEINT_DUMMY") and aheadDist < 18.0 and aheadDist > 2.5 and mySpeed > 85.0 then
      local aggr = persona and persona.base_aggression or 0.75
      if aggr >= 0.70 then
        s.bodyLangAction = "HUNTING"
        s.bodyLangTarget = aheadCar.index
        s.bodyLangFlashCount = 6
        s.bodyLangHorn = false
        s.bodyLangReason = "超车进攻狂闪大灯极限施压"
      end

    -- Priority 4: HAZARD (Spun/crawling car ahead)
    elseif aheadDist < 50.0 and aheadDist > 15.0 and aheadSpeed < 35.0 and mySpeed > 80.0 then
      s.bodyLangAction = "HAZARD"
      s.bodyLangTarget = aheadCar.index
      s.bodyLangFlashCount = 2
      s.bodyLangHorn = false
      s.bodyLangReason = "前方慢车避险慢闪警示"
    end
  end
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
  local idx = (car and car.index) or (raceContext and raceContext.carIndex) or 0
  local s = _aiStates[idx] or _aiStates[0]
  s.persona = persona
  MistakeEngine.stepCooldown(idx, dt)

  -- -2. Terminal Retirement Gate:
  -- Retired AI cars (RET) are parked in pit stalls by AC engine; do NOT misclassify as active PIT_SERVICE!
  local isRetired = (car and car.isRetired) or (raceContext and raceContext.isRetired)
  if isRetired then
    s.state = "RETIRED"
    s.activeSkill = "RET"
    s.targetSplineOffset = 0.0
    s.currentSplineOffset = 0.0
    s.targetCaution = 1.0
    s.targetAggression = 0.0
    s.stress = 0.0
    s.momentum = 0.0
    s.commitTimer = 0.0
    s.committedState = nil
    s.isBreakingTow = false
    s.isLiftAndCoast = false
    s.isFeinting = false
    TelemetryBridge.updateCarTelemetry(idx, s.state, 0.0, 0.0, (raceContext and raceContext.tyreWear) or 0.0, false, false, "NONE", 0.0, 1.0)
    return s
  end

  -- -1. Pit Lane & Pit Bay Authority Gate:
  -- While car is entering, dwelling, or exiting pits, lock into PIT_BAY cruise
  local inPit = car.isInPitlane or car.isInPit or (raceContext and (raceContext.isInPitlane or raceContext.isInPit))
  if inPit then
    s.state = "PIT_BAY"
    s.activeSkill = "PIT_SERVICE"
    s.targetSplineOffset = 0.0
    s.currentSplineOffset = 0.0
    s.targetCaution = 1.0
    s.targetAggression = 0.5
    s.stress = 0.0
    s.commitTimer = 0.0
    s.committedState = nil
    s.isBreakingTow = false
    s.isLiftAndCoast = false
    s.isFeinting = false
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, false, false, s.lastMistakeType, 0.0, 1.0)
    return s
  end

  -- 0. Launch & Low-Speed Safety Gate:
  -- During race start, grid waiting, or slow crawl (< 45 km/h), maintain pure stable CRUISE
  -- Never calculate aggressive combat offsets, tow weaving, or divebombs that spin cars on the grid
  local currentSpeedKmh = car.speedKmh or 0.0
  if currentSpeedKmh < 45.0 then
    s.state = M.STATE_CRUISE
    s.activeSkill = "NONE"
    s.targetSplineOffset = 0.0
    s.targetCaution = persona and persona.base_caution or 1.0
    s.targetAggression = persona and persona.base_aggression or 0.7
    s.stress = 0.0
    s.commitTimer = 0.0
    s.committedState = nil
    s.switchbackTimer = 0.0
    s.recoveryTimer = 0.0
    s.defenseHeatTimer = 0.0
    s.isBreakingTow = false
    s.isFeinting = false
    s.isLiftAndCoast = false
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 0.1 Check Blue Flag yielding condition
  if raceContext and raceContext.isBlueFlagged and behindCar then
    s.state = M.STATE_YIELD
    s.activeSkill = "YIELD"
    s.targetSplineOffset = 0.75 -- Pull to outer safe line
    s.targetCaution = 1.8
    s.targetAggression = 0.3
    s.stress = s.stress - dt * 0.5
    if s.stress < 0.0 then s.stress = 0.0 end

    if not s.chatterBlueReported then
      s.chatterBlueReported = true
      local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
      DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_BLUE_FLAG, persona, safeExtractDriverName(car))
    end

    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  else
    s.chatterBlueReported = false
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
      s.physicalMistakeType = nil
      s.physicalDispatched = false
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

  local aheadDist = 999.0
  if aheadCar and car.position and aheadCar.position then
    local ax = aheadCar.position.x - car.position.x
    local ay = aheadCar.position.y - car.position.y
    local az = aheadCar.position.z - car.position.z
    aheadDist = math.sqrt(ax * ax + ay * ay + az * az)
  end
  s.aheadDist = aheadDist

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
  s.isLaunchDelayed = MistakeEngine.isLaunchDelayed(idx)

  -- COBAL Fuzzy Scenario Context (SCE) & Commitment Evaluation (DCA)
  -- 1. Pursuit Commitment (0.0 to 1.0 smooth ramp as closing within 25m)
  local pursuitMu = 0.0
  if aheadCar and s.aheadDist < 30.0 and s.aheadDist > 0.5 then
    pursuitMu = 1.0 - (s.aheadDist / 30.0)
    if pursuitMu < 0.0 then pursuitMu = 0.0 end
    if pursuitMu > 1.0 then pursuitMu = 1.0 end
  end
  s.pursuitCommitment = pursuitMu

  -- 2. Defensive Pressure Commitment (0.0 to 1.0 as rival approaches within 25m / TTC < 2.5s)
  local pressureMu = 0.0
  if behindCar and behindDist < 25.0 and behindDist > 0.5 then
    pressureMu = 1.0 - (behindDist / 25.0)
    if ttcBehind < 2.0 then
      pressureMu = math.min(1.0, pressureMu + (2.0 - ttcBehind) * 0.25)
    end
    if pressureMu < 0.0 then pressureMu = 0.0 end
    if pressureMu > 1.0 then pressureMu = 1.0 end
  end
  s.pressureCommitment = pressureMu

  -- 3. Side-by-Side Duel Commitment (0.0 to 1.0 when lateral overlap is detected)
  local duelMu = 0.0
  if (behindCar and behindDist < 8.0) or (aheadCar and s.aheadDist < 8.0) then
    local gap = (behindCar and behindDist < 8.0) and behindDist or s.aheadDist
    duelMu = 1.0 - (gap / 8.0)
    if duelMu < 0.0 then duelMu = 0.0 end
    if duelMu > 1.0 then duelMu = 1.0 end
  end
  s.duelCommitment = duelMu

  -- 3. Calculate Dynamic Stress Level
  local behindState = behindCar and _aiStates[behindCar.index]
  s.stress = computeStress(s, behindDist, behindSpeedDelta, persona, raceContext, behindCar, behindState, dt)

  -- Update Dynamic Momentum & Flow State (-1.0 Tilt to +1.0 Flow)
  local momentumDelta = 0.0
  if raceContext and raceContext.tyreWear and raceContext.tyreWear > 0.60 then
    momentumDelta = momentumDelta - dt * 0.25
    if not s.chatterTyreReported and raceContext.tyreWear >= 0.65 then
      s.chatterTyreReported = true
      local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
      DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_TYRE_CLIFF, persona, safeExtractDriverName(car))
    end
  elseif raceContext and raceContext.tyreWear and raceContext.tyreWear < 0.20 then
    s.chatterTyreReported = false
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

  local mType, mDur, mOff, mCaut, mGrip, pType, pDur, pSev, mTier = MistakeEngine.rollMistake(
    idx, effectiveStress, persona, rivalryScore, hotspotDanger, dt, car, raceContext
  )
  if mType ~= MistakeEngine.TYPE_NONE then
    s.state = M.STATE_MISTAKE
    s.lastMistakeType = mType
    s.recoveryTimer = mDur
    s.targetSplineOffset = mOff
    s.targetCaution = mCaut
    s.mistakeGripPenalty = math.abs(mGrip)
    s.physicalMistakeType = pType
    s.physicalMistakeDur = pDur
    s.physicalMistakeSev = pSev
    s.physicalDispatched = false
    s.tierMistake = mTier or 1
    if mTier == MistakeEngine.TIER_2_TECHNICAL then
      local EventHub = require("lib/core/EventHub")
      local dLabel = EventHub.formatDriverLabel(idx, safeExtractDriverName(car))
      EventHub.pushAiEvent(idx, "MISTAKE", string.format("【重压失误】%s 在后车压迫下入弯前轮抱死走大，内线门户大开！", dLabel), "TACTICAL")
      -- Proactive Team Radio: Alert human player (car 0) if car ahead made an error
      if behindCar and behindCar.index == 0 then
        local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
        RadioVoiceEngine.playRadio("cmd_attack", RadioVoiceEngine.PRIORITY_COMMAND)
      end
      local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
      DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_MISTAKE, persona, safeExtractDriverName(car))
    elseif mTier == MistakeEngine.TIER_3_SEVERE then
      local EventHub = require("lib/core/EventHub")
      local dLabel = EventHub.formatDriverLabel(idx, safeExtractDriverName(car))
      EventHub.pushAiEvent(idx, "SPIN", string.format("【心理崩盘】%s 极度慌乱急躁出弯尾部剧烈甩尾，险些掉头失控！", dLabel), "INCIDENT")
      if behindCar and behindCar.index == 0 then
        local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
        RadioVoiceEngine.playRadio("info_yellow_flag", RadioVoiceEngine.PRIORITY_EMERGENCY)
      end
      local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
      DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_CRASH, persona, safeExtractDriverName(car))
    end
    if s.stress > 2.5 or s.pressureCommitment > 0.5 then
      BattleTracker.recordPressureMistake(idx, mType)
    end
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

  -- 5.1 Hunter's Pounce (POUNCE_PASS): opportunistically pounce when ahead car makes an error / washes wide
  if s.pounceTimer > 0.0 then
    s.pounceTimer = s.pounceTimer - dt
    if s.pounceTimer <= 0.0 then
      s.pounceActive = false
      s.pounceReported = false
    else
      s.state = "POUNCE_PASS"
      s.activeSkill = "POUNCE_PASS"
      s.targetCaution = 0.25
      s.targetAggression = 0.98
      evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    end
  elseif aheadCar and s.aheadDist >= 1.5 and s.aheadDist <= 25.0 and not inPit then
    local aheadState = _aiStates[aheadCar.index]
    local aheadInMistake = aheadState and (aheadState.state == M.STATE_MISTAKE or aheadState.lastMistakeType == "MISSED_APEX" or aheadState.lastMistakeType == "BRAKE_LOCKUP" or aheadState.lastMistakeType == "TRAIL_UNDERSTEER")
    local aheadWashedWide = aheadState and (math.abs(aheadState.targetSplineOffset or 0) >= 0.35 or math.abs(aheadState.currentSplineOffset or 0) >= 0.35)
    if aheadInMistake or aheadWashedWide then
      local aheadOff = (aheadState and (aheadState.currentSplineOffset or aheadState.targetSplineOffset)) or 0.0
      local pounceLine = (aheadOff > 0) and -0.40 or 0.40
      s.state = "POUNCE_PASS"
      s.activeSkill = "POUNCE_PASS"
      s.targetSplineOffset = pounceLine
      s.targetCaution = 0.25 -- bold opportunistic attack
      s.targetAggression = 0.98
      s.pounceTimer = 2.0
      s.pounceActive = true
      BattleTracker.recordSkillExecuted("POUNCE_PASS", idx)
      if not s.pounceReported then
        s.pounceReported = true
        local EventHub = require("lib/core/EventHub")
        local myLabel = EventHub.formatDriverLabel(idx, safeExtractDriverName(car))
        local targetLabel = EventHub.formatDriverLabel(aheadCar.index, safeExtractDriverName(aheadCar))
        EventHub.pushAiEvent(idx, "OVERTAKE", string.format("【绝杀突袭】%s 敏锐捕捉到前车 %s 失误走大，强行插入内线切弯反超！", myLabel, targetLabel), "COMBAT")
        local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
        RadioVoiceEngine.playRadio("info_overtake", RadioVoiceEngine.PRIORITY_COMMAND)
        local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
        DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_OVERTAKE, persona, safeExtractDriverName(car))
      end
      evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
      TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
      return s
    end
  end

  -- 6. X-Skill Arbitrator Execution & Evaluation
  local hasSkill, sOffset, sCaution, sAggression, extraGrip = SkillArbitrator.stepCarSkill(
    car, aheadCar, behindCar, persona, rivalryScore, raceContext, s, dt
  )

  if hasSkill then
    local skillCtx = SkillArbitrator.getContext(idx)
    s.activeSkill = skillCtx.activeSkillName or "SKILL"
    BattleTracker.recordSkillExecuted(s.activeSkill, idx)
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

    evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
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
    BattleTracker.recordSkillExecuted("SWITCHBACK", idx)
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
        if behindCar and behindCar.position and car.position then
          local bx = behindCar.position.x - car.position.x
          local bz = behindCar.position.z - car.position.z
          if car.side then
            behindRelX = bx * (car.side.x or 1.0) + bz * (car.side.z or 0.0)
          elseif car.worldToLocal and car.worldToLocal.transformPoint then
            local localBehind = car.worldToLocal:transformPoint(behindCar.position)
            behindRelX = localBehind and localBehind.x or 0.0
          else
            behindRelX = bx
          end
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

        local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
        if overlap > 0.45 or (behindDist < 3.8 and math.abs(behindRelX) < 1.8) then
          DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_SQUEEZED, persona, safeExtractDriverName(car))
        else
          DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_DOGFIGHT, persona, safeExtractDriverName(car))
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

      evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
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

  -- 7.5 Breaking the Tow & Weaving (Straight defense when tailgated in direct slipstream < 22m)
  s.isBreakingTow = false
  local isStraight = checkIsStraight(car)
  local mySpeed = car.speedKmh or 0.0
  local isTailgated = isStraight and mySpeed > 115.0 and behindCar and behindDist <= 22.0 and behindDist > 4.5
  if isTailgated and (not aheadCar or s.aheadDist > 30.0) then
    local relX = math.abs(s.rivalRelX or 0.0)
    local isClosingIn = (behindSpeedDelta > -0.2) or (ttcBehind < 2.5)
    if relX < 1.2 and isClosingIn then
      local aggr = persona and (persona.base_aggression or 0.7) or 0.7
      if aggr > 0.72 then
        s.isBreakingTow = true
        s.state = "TOW_WEAVE"
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

        evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
        TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, (raceContext and raceContext.tyreWear) or 0.0, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
        return s
      end
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
  elseif radioCmd == "ATTACK" then
    -- Team Attack Order: maximum aggression, late braking and hunt ahead car
    s.targetCaution = math.max(0.12, (persona.base_caution or 0.7) * 0.3)
    s.targetAggression = math.max(0.96, math.min(0.99, (persona.base_aggression or 0.8) * 1.35))
    s.momentum = math.min(1.0, s.momentum + dt * 0.30)
    s.isInFlow = (s.momentum >= 0.40)
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

  -- Slipstream Tow Seeking (18m ~ 60m) - Pure drafting cruise, NOT attack window
  if aheadCar and aheadDist >= 18.0 and aheadDist <= 60.0 then
    s.state = M.STATE_CRUISE
    s.slipstreamActive = true
    local aheadState = _aiStates[aheadCar.index]
    s.targetSplineOffset = aheadState and aheadState.currentSplineOffset or 0.0
    s.targetAggression = math.min(0.95, (persona.base_aggression or 0.8) + 0.05)
    s.targetCaution = math.max(0.4, (persona.base_caution or 0.7) * 0.8)
    evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, tyreWear, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end
  s.slipstreamActive = false

  -- Close Quarters Hunting (< 18m) & Two-Phase Feint / Dummy Move
  if aheadDist < 18.0 and aheadCar then
    s.state = M.STATE_ATTACK
    s.committedState = M.STATE_ATTACK
    s.commitTimer = 0.7
    s.targetAggression = math.min(0.98, (persona.base_aggression or 0.8) + 0.15)
    s.targetCaution = math.max(0.35, (persona.base_caution or 0.8) * 0.55)

    -- Proactive Team Radio: Warn player car (0) when a chasing AI launches an attack
    if aheadCar.index == 0 and aheadDist < 14.0 then
      local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
      RadioVoiceEngine.playRadio("cmd_defend", RadioVoiceEngine.PRIORITY_COMMAND)
    end

    local aggr = persona and persona.base_aggression or 0.75
    -- Two-Phase Feint / Dummy Move: High aggression drivers (> 0.80) feint outside then dive inside
    if aggr > 0.80 and aheadDist < 12.0 and isStraight then
      s.feintTimer = (s.feintTimer or 0.0) + dt

      -- Determine inside apex direction for corner approach
      local insideSign = -1.0
      if ac and ac.getTrackUpcomingTurn and car.splinePosition then
        local okT, d, a = pcall(ac.getTrackUpcomingTurn, car.splinePosition)
        if okT and type(a) == "number" and math.abs(a) > 0.04 then
          insideSign = (a > 0) and 1.0 or -1.0
        end
      end

      if s.feintTimer < 0.40 then
        -- Phase 1 (0.0~0.4s): Feint outside opposite to inside apex
        s.targetSplineOffset = -insideSign * 0.45
        s.isFeinting = true
      elseif s.feintTimer < 1.10 then
        -- Phase 2 (0.4~1.1s): Rapid dive inside for the overtake line
        s.targetSplineOffset = insideSign * 0.50
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
        -- Geometry and rival-relative positioning (no coin-flip randomization)
        local peekSide = -1.0
        if ac and ac.getTrackUpcomingTurn and car.splinePosition then
          local okT, d, a = pcall(ac.getTrackUpcomingTurn, car.splinePosition)
          if okT and type(a) == "number" and math.abs(a) > 0.04 then
            peekSide = (a > 0) and 1.0 or -1.0
          end
        end
        if aheadCar and aheadCar.position and car.position and car.side then
          local bx = aheadCar.position.x - car.position.x
          local bz = aheadCar.position.z - car.position.z
          local aheadRelX = bx * (car.side.x or 1.0) + bz * (car.side.z or 0.0)
          if aheadRelX > 0.15 then
            peekSide = -1.0 -- Rival is to our right, peek left
          elseif aheadRelX < -0.15 then
            peekSide = 1.0 -- Rival is to our left, peek right
          end
        end

        if math.random() < (persona.decoy_tendency or 0.4) then
          s.decoyOffset = peekSide * 0.45
          s.decoyTimer = 2.0
        else
          s.decoyOffset = 0.0
          s.decoyTimer = 3.0
        end
      end
      s.targetSplineOffset = s.decoyOffset
    end
    evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
    TelemetryBridge.updateCarTelemetry(idx, s.state, s.stress, s.momentum, tyreWear, s.isLiftAndCoast, s.isBreakingTow, s.lastMistakeType, s.currentSplineOffset, s.targetCaution)
    return s
  end

  -- 9. Default Cruise State
  s.state = M.STATE_CRUISE
  s.committedState = nil
  s.commitTimer = 0.0
  if not s.isLiftAndCoast and radioCmd == "NONE" then
    -- COBAL CPM (Cooperative Positioning Module): Subtle line variation in free air
    -- Prevents rigid "slot car" mechanical feeling when racing without immediate threats
    local isFreeAir = (s.aheadDist > 25.0) and (s.behindDist > 20.0)
    local curSpd = car.speedKmh or 0.0
    if isFreeAir and curSpd > 80.0 and (car.lapCount or 0) > 0 then
      s.variationPhase = (s.variationPhase or 0.0) + dt * 0.8
      if s.variationPhase > 62.8 then s.variationPhase = s.variationPhase - 62.8 end
      -- Subtle wandering within +/- 0.04 spline offset
      s.lineVariationOffset = math.sin(s.variationPhase) * 0.035
      s.targetSplineOffset = s.lineVariationOffset
    else
      s.lineVariationOffset = 0.0
      s.targetSplineOffset = 0.0
    end
    s.targetCaution = persona.base_caution or 1.0
    s.targetAggression = persona.base_aggression or 0.75
  elseif radioCmd == "PUSH" then
    s.targetSplineOffset = 0.0
    -- targetCaution and targetAggression already set by PUSH above
  elseif radioCmd == "ATTACK" then
    s.state = M.STATE_ATTACK
    s.targetSplineOffset = 0.0
    -- targetCaution and targetAggression already set by ATTACK above
  elseif radioCmd == "DEFEND" then
    s.state = M.STATE_DEFEND
    -- targetCaution and targetAggression already set by DEFEND above
  end

  -- Victory check (Checker flag / Last Lap finish line crossed)
  if raceContext and raceContext.isLastLap and not s.chatterVictoryReported and (car.splinePosition or 0) > 0.95 then
    s.chatterVictoryReported = true
    local DriverChatterEngine = require("lib/audio/DriverChatterEngine")
    DriverChatterEngine.triggerChatter(idx, DriverChatterEngine.SIT_VICTORY, persona, safeExtractDriverName(car), true)
  end

  evaluateBodyLanguage(s, car, aheadCar, behindCar, s.aheadDist or 999.0, s.behindDist or 999.0, persona, rivalryScore, raceContext, dt)
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
  BehaviorActuator.reset()
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
    s.bodyLangAction = "NONE"
    s.bodyLangTarget = -1
    s.bodyLangReason = ""
    s.bodyLangHorn = false
    s.bodyLangFlashCount = 0
    s.lastAheadIdx = -1
    s.overtakeCooldown = 0.0
    s.mti = 0.0
    s.breakdownRisk = 0.0
    s.psychStatus = "CALM"
    s.pounceTimer = 0.0
    s.pounceActive = false
    s.pounceReported = false
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
