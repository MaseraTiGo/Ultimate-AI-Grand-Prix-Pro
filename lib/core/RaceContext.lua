--[[
  lib/core/RaceContext.lua
  Ultimate AI Grand Prix Pro - Unified Single Source of Truth for Race State
  
  Responsibilities:
    - Centralize session time, laps, flags, Safety Car status, weather/track status
    - Preallocated per-car status cache (0 to 63)
    - Zero dynamic memory allocation in 10Hz/60Hz query paths
]]

local ControlTelemetry = require("lib/core/ControlTelemetry")

local M = {}

local MAX_CARS = 24

M.FLAG_GREEN  = "GREEN"
M.FLAG_YELLOW = "YELLOW"
M.FLAG_SC     = "SC"
M.FLAG_VSC    = "VSC"
M.FLAG_RED    = "RED"

-- Formal Pit State Machine Enums
M.PIT_STATE_NONE         = "NONE"
M.PIT_STATE_AUTO_PLANNED = "AUTO_PLANNED"
M.PIT_STATE_CONFIGURED   = "CONFIGURED"
M.PIT_STATE_CONFIRMED    = "CONFIRMED"
M.PIT_STATE_REQUESTED    = "REQUESTED"
M.PIT_STATE_APPROACHING  = "APPROACHING"
M.PIT_STATE_IN_PITLANE   = "IN_PITLANE"
M.PIT_STATE_IN_BAY       = "IN_BAY"
M.PIT_STATE_STATIONARY   = "STATIONARY"
M.PIT_STATE_SERVICING    = "SERVICING"
M.PIT_STATE_VERIFIED     = "VERIFIED"
M.PIT_STATE_RELEASED     = "RELEASED"
M.PIT_STATE_COMPLETED    = "COMPLETED"
M.PIT_STATE_FAILED       = "FAILED"
M.PIT_STATE_RETIRED      = "RETIRED"

-- Dual Experience Mode Enums
M.MODE_DRIVER    = "DRIVER"
M.MODE_SPECTATOR = "SPECTATOR"

local _raceState = {
  sessionType = "RACE",
  totalLaps = 13,
  currentLap = 1,
  sessionTime = 0.0,
  flagState = M.FLAG_GREEN,
  scActive = false,
  isReplay = false,
  carsCount = 0,
  playerIndex = 0,
  leaderIndex = 0,
  leaderSpeedKmh = 200.0,
  trackLengthM = 5000.0,
  experienceMode = M.MODE_DRIVER,
  manualModeOverride = nil,
}

local _compoundsCache = {}

local _carStates = {}
for i = 0, MAX_CARS - 1 do
  _carStates[i] = {
    index = i,
    driverName = "",
    carName = "",
    isAIControlled = true,
    isConnected = false,
    
    -- Spatial & Motion
    posX = 0.0, posY = 0.0, posZ = 0.0,
    speedKmh = 0.0,
    splinePos = 0.0,
    lapCount = 0,
    currentLap = 1,
    raceProgress = 0.0,
    gapAheadSec = 999.0,
    gapBehindSec = 999.0,
    positionInRace = i + 1,
    prevPositionInRace = i + 1,
    tyreCliffAlertSent = false,
    lastMechAlertTime = 0.0,
    isInPitlane = false,
    isInPit = false,
    isRetired = false,
    pitState = M.PIT_STATE_NONE,
    
    -- Telemetry Metadata & Confidence Tracking
    telemetryConfidence = {
      fuel = "DYNAMIC_ESTIMATE",
      tyre = "MODEL",
      lap = "EXACT",
      gap = "CALCULATED"
    },

    -- Fuel & Tyres
    fuelInTank = 30.0,
    maxFuelCapacity = 100.0,
    fuelPerLap = 2.5,
    tyreWear = 0.0,       -- 0.0 (new) ~ 1.0 (dead)
    tyreCompound = "MEDIUM",
    tyreLapsAge = 0,
    tyreWarmupProgress = 1.0, -- 0.0 (ice cold) ~ 1.0 (optimal)
    tyreTempNorm = 1.0,       -- 1.0 = nominal, >1.3 = cooked / overheated

    -- Mechanical Health & Damage (CSP StateCar)
    engineLifeLeft = 1000.0,
    waterTemp = 90.0,
    gearboxDamage = 0.0,
    bodyDamagePct = 0.0,
    suspensionDamagePct = 0.0,

    -- Per-wheel Telemetry: LF (1), RF (2), LR (3), RR (4)
    wheelWear = { 1.0, 1.0, 1.0, 1.0 },       -- 1.0 (new) to 0.0 (worn)
    wheelCoreTemp = { 90.0, 90.0, 90.0, 90.0 }, -- °C
    wheelBrakeTemp = { 250.0, 250.0, 250.0, 250.0 }, -- °C
    compoundIndex = 0,
    compoundName = "Default",

    -- Empirical Fuel Tracking (EMA)
    empiricalFpl = nil,
    fuelAtLapStart = nil,
    lastTrackedLap = 0,

    -- Dynamic Pit Stop Work Order
    pendingWorkOrder = {
      changeTyres = true,
      targetCompoundIndex = 0,
      targetCompoundName = "Default",
      refuelLiters = 0.0,
      isExplicit = false,
      source = "NONE",
      isConfirmed = false,
      serviced = false,
      status = "NONE",
      isExecuting = false,
    },

    -- Dynamic Racecraft & Strategy Integration
    tacticalState = "CRUISE",
    activeSkill = "NONE",
    stress = 0.0,
    momentum = 0.0,
    isInFlow = false,
    isTilting = false,
    isLiftAndCoast = false,
    isBreakingTow = false,
    
    -- Pit Strategy & Authority
    plannedStops = 0,
    currentStint = 1,
    targetPitLap = 999,
    openPitLap = 999,
    escalatePitLap = 999,
    actualStopsCount = 0,
    lastPitLap = -1,
    radioCommand = "NONE",     -- "NONE", "PUSH", "SAVE", "BOX_THIS_LAP", "DEFEND"
    radioOrderActive = false,
  }
end

function M.getRaceState()
  return _raceState
end

function M.setTotalLaps(laps)
  if laps and laps > 0 then
    _raceState.totalLaps = math.floor(laps)
  end
end

function M.getCarState(carIndex)
  return _carStates[carIndex] or _carStates[0]
end

function M.getAllCarStates()
  return _carStates
end

local function safeGetCar(idx)
  if not ac or not ac.getCar or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getCar, idx)
  if ok and res then return res end
  return nil
end

--- Safely query a field from a CSP C-struct or table without throwing FFI member errors
local function safeSimGet(sim, field)
  if not sim or not field then return nil end
  local ok, val = pcall(function() return sim[field] end)
  if ok then return val end
  return nil
end
M.safeSimGet = safeSimGet

--- Safely query a field from an AC/CSP car C-struct (struct state_car) without throwing FFI member errors
local function safeCarGet(car, field)
  if not car or not field then return nil end
  local ok, val = pcall(function() return car[field] end)
  if ok then return val end
  return nil
end
M.safeCarGet = safeCarGet

--- Safely resolve current session time in seconds
local function getSimSessionTime(sim)
  if not sim then return 0.0 end
  -- 1. Try gameTime (in seconds from AC start, standard official CSP field)
  local gt = safeSimGet(sim, "gameTime")
  if gt and gt > 0 then return gt end
  -- 2. Try currentSessionTime (in ms -> sec, synced session time in online/offline)
  local cst = safeSimGet(sim, "currentSessionTime")
  if cst and cst > 0 then return cst / 1000.0 end
  -- 3. Try time (in ms -> sec)
  local t = safeSimGet(sim, "time")
  if t and t > 0 then return t / 1000.0 end
  -- 4. Try sessionTime (mock/fallback)
  local st = safeSimGet(sim, "sessionTime")
  if st and st > 0 then return st end
  return (os and os.clock and os.clock()) or 0.0
end
M.getSimSessionTime = getSimSessionTime

local function safeGetDriverName(idx)
  if not ac or not ac.getDriverName or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getDriverName, idx)
  if ok and res and res ~= "" then return res end
  return nil
end

--- Update global race state snapshot once per frame (10Hz / 1Hz)
function M.updateFromSim(sim)
  if not sim then return end
  _raceState.isReplay = (safeSimGet(sim, "isReplayActive") == true)
  _raceState.sessionTime = getSimSessionTime(sim)

  -- Count connected cars: safely from sim.carsCount and bounded probing
  local simCars = safeSimGet(sim, "carsCount") or 0
  if simCars == 0 and ac and ac.getSim then
    local okSim, s = pcall(ac.getSim)
    if okSim and s then
      simCars = safeSimGet(s, "carsCount") or 0
    end
  end

  local probedCount = 0
  local maxProbe = (simCars > 0) and math.min(simCars, MAX_CARS) or MAX_CARS
  for probeIdx = 0, maxProbe - 1 do
    local probeCar = safeGetCar(probeIdx)
    if probeCar then
      probedCount = probedCount + 1
    else
      if simCars == 0 then break end
    end
  end

  _raceState.carsCount = math.max(simCars, probedCount)
  if _raceState.carsCount > MAX_CARS then _raceState.carsCount = MAX_CARS end

  -- Dynamic Session Laps:
  -- 1. Try official CSP ac.getSession(sim.currentSessionIndex).laps
  local laps = nil
  if ac and ac.getSession then
    local sessIdx = safeSimGet(sim, "currentSessionIndex") or 0
    local ok, sess = pcall(ac.getSession, sessIdx)
    if ok and sess then
      local sLaps = safeSimGet(sess, "laps")
      if sLaps and sLaps > 0 then laps = sLaps end
    end
  end
  -- 2. Fallbacks: safe query of raceLaps, sessionLaps, totalLaps, laps
  if not laps or laps <= 0 then
    laps = safeSimGet(sim, "raceLaps")
      or safeSimGet(sim, "sessionLaps")
      or safeSimGet(sim, "totalLaps")
      or safeSimGet(sim, "laps")
  end

  if laps and laps > 0 then
    if _raceState.totalLaps ~= laps then
      _raceState.totalLaps = laps
      local StrategyCoordinator = package.loaded["lib/strategy/StrategyCoordinator"]
      if StrategyCoordinator and StrategyCoordinator.rebuildFieldStrategy then
        pcall(StrategyCoordinator.rebuildFieldStrategy, laps, nil, nil)
      end
    end
  end

  -- Current Lap:
  -- In CSP, leaderLapCount is completed laps by leader (0-indexed). So current lap = leaderLapCount + 1.
  local leaderCompleted = safeSimGet(sim, "leaderLapCount")
  local currentLap = nil
  if leaderCompleted and leaderCompleted >= 0 then
    currentLap = leaderCompleted + 1
  else
    local c0 = safeGetCar(0)
    if c0 and c0.lapCount and c0.lapCount >= 0 then
      currentLap = c0.lapCount + 1
    else
      currentLap = safeSimGet(sim, "currentLap") or _raceState.currentLap or 1
    end
  end

  -- Flags & Safety Car Edge Detection:
  -- CSP official: sim.raceFlagType (ac.FlagType.Caution = 2, ac.FlagType.FasterCar = 12, ac.FlagType.Finished = 13)
  local raceFlagType = safeSimGet(sim, "raceFlagType")
  local prevFlag = _raceState.flagState
  local isYellow = (raceFlagType == 2) or (safeSimGet(sim, "isYellowFlag") == true) or (safeSimGet(sim, "hasYellowFlag") == true)
  local isSC = (safeSimGet(sim, "safetyCarActive") == true) or (safeSimGet(sim, "isSafetyCar") == true)

  if isYellow then
    _raceState.flagState = M.FLAG_YELLOW
  elseif isSC then
    _raceState.flagState = M.FLAG_SC
    _raceState.scActive = true
  else
    _raceState.flagState = M.FLAG_GREEN
    _raceState.scActive = false
  end

  -- Blue flag tracking
  if raceFlagType == 12 then -- ac.FlagType.FasterCar
    _raceState.blueFlagCarIdx = safeSimGet(sim, "raceFlagCause") or -1
  else
    _raceState.blueFlagCarIdx = -1
  end

  local EventHub = package.loaded["lib/core/EventHub"]
  if EventHub and prevFlag ~= _raceState.flagState then
    if _raceState.flagState == M.FLAG_YELLOW then
      EventHub.pushAiEvent(0, "FLAG", "【全场黄旗】赛道出现危险状况，全场黄旗生效！禁止超车！", "WORLD", _raceState.sessionTime)
    elseif _raceState.flagState == M.FLAG_SC then
      EventHub.pushAiEvent(0, "FLAG", "【安全车出动】Safety Car 出动压车，各车队进入紧急进站窗口！", "WORLD", _raceState.sessionTime)
    elseif _raceState.flagState == M.FLAG_GREEN and prevFlag ~= M.FLAG_GREEN then
      EventHub.pushAiEvent(0, "FLAG", "【绿旗恢复】赛道险情解除，绿旗行车！比赛恢复全力推进！", "WORLD", _raceState.sessionTime)
    end
  end

  -- Lap progression edge detection
  local prevLap = _raceState.currentLap or 1
  if EventHub and currentLap > prevLap and prevLap > 0 then
    _raceState.currentLap = currentLap
    local lapStr = EventHub.formatLapStr and EventHub.formatLapStr(currentLap, _raceState.totalLaps) or string.format("第%d/%d圈", currentLap, _raceState.totalLaps or 13)
    EventHub.pushAiEvent(0, "RACE", string.format("【赛程更新】头车冲线，比赛正式进入%s！", lapStr), "WORLD", _raceState.sessionTime)
  else
    _raceState.currentLap = currentLap
  end

  -- Eager driver name sync from AC (strictly bound within known car count)
  local maxSync = math.min(_raceState.carsCount, MAX_CARS)
  for idx = 0, maxSync - 1 do
    local dName = safeGetDriverName(idx)
    if dName and dName ~= "" then
      _carStates[idx].driverName = dName
    end
  end

  -- Experience Mode Auto-Detection & Resolution:
  -- If manual override is explicitly set, honor it.
  -- Otherwise:
  -- 1. If in Replay (isReplayActive), or player car is retired, auto switch to SPECTATOR.
  -- 2. If human player car is connected and moving or sitting on track/grid, keep DRIVER mode.
  if _raceState.manualModeOverride then
    _raceState.experienceMode = _raceState.manualModeOverride
  else
    if _raceState.isReplay then
      _raceState.experienceMode = M.MODE_SPECTATOR
    else
      local pCar = _carStates[0]
      if pCar and pCar.isRetired then
        _raceState.experienceMode = M.MODE_SPECTATOR
      else
        _raceState.experienceMode = M.MODE_DRIVER
      end
    end
  end
end

--- Update per-car state snapshot from AC car object (Pure scalar, zero-alloc)
function M.updateCarFromAc(carIndex, c)
  if not c or carIndex < 0 or carIndex >= MAX_CARS then return end
  local s = _carStates[carIndex]
  s.isConnected = safeCarGet(c, "isConnected") ~= false
  local isAI = safeCarGet(c, "isAIControlled")
  local isPlayer = safeCarGet(c, "isPlayer")
  s.isAIControlled = (isAI == true) or (carIndex > 0 and not isPlayer)
  s.speedKmh = safeCarGet(c, "speedKmh") or 0.0
  s.splinePos = safeCarGet(c, "splinePosition") or 0.0
  s.lapCount = safeCarGet(c, "lapCount") or 0
  s.currentLap = (s.lapCount or 0) + 1
  local totalLaps = _raceState.totalLaps or 13
  s.raceProgress = ((s.lapCount or 0) + (s.splinePos or 0.0)) / math.max(1, totalLaps)

  local prevPos = s.positionInRace
  local newPos = safeCarGet(c, "racePosition") or (carIndex + 1)
  s.positionInRace = newPos

  local fuelVal = safeCarGet(c, "fuel")
  if fuelVal and type(fuelVal) == "number" then
    s.fuelInTank = fuelVal
    if not s.fuelAtLapStart then
      s.fuelAtLapStart = fuelVal
    end
  end
  if (s.lapCount or 0) == 0 and s.fuelInTank then
    s.fuelAtLapStart = s.fuelInTank
    s.lastTrackedLap = 0
  end
  local maxFuel = safeCarGet(c, "maxFuel")
  if maxFuel and type(maxFuel) == "number" and maxFuel > 0 then
    s.maxFuelCapacity = maxFuel
  end

  if s.telemetryConfidence then
    s.telemetryConfidence.fuel = (s.empiricalFpl ~= nil) and "EMA_MEASURED" or "DYNAMIC_ESTIMATE"
    s.telemetryConfidence.tyre = (s.wheelWear and s.wheelWear[1] ~= nil) and "DIRECT_TELEMETRY" or "ESTIMATE"
    s.telemetryConfidence.lap = "EXACT"
  end

  local EventHub = package.loaded["lib/core/EventHub"]
  local StrategyCoordinator = package.loaded["lib/strategy/StrategyCoordinator"]

  if prevPos and prevPos > 0 and newPos < prevPos and s.speedKmh > 50.0 and (s.lapCount or 0) > 0 and (_raceState.sessionTime or 0) > 8.0 then
    if EventHub and EventHub.emitOvertake then
      EventHub.emitOvertake(carIndex, s.driverName, newPos, _raceState.sessionTime)
    end
  end

  local wasRetired = s.isRetired
  local isNowRetired = (safeCarGet(c, "isRetired") == true)
  s.isRetired = isNowRetired

  local curLap = _raceState.currentLap or 1
  local totalLaps = _raceState.totalLaps or 13
  local lapPrefix = (EventHub and EventHub.formatLapStr) and EventHub.formatLapStr(curLap, totalLaps) or string.format("第%d/%d圈", curLap, totalLaps)

  -- Terminal Retirement Gate:
  -- When an AI car retires (RET), AC engine immediately despawns it to its pit stall.
  -- Gating here prevents misclassifying retired cars as active pit stop servicings.
  if isNowRetired then
    s.tacticalState = "RETIRED"
    s.activeSkill = "RET"
    s.pitState = M.PIT_STATE_RETIRED
    s.pit_requested = false
    s.pit_stop_planned = false
    s.radioCommand = "NONE"
    s.radioOrderActive = false

    if not wasRetired then
      local dLabel = EventHub and EventHub.formatDriverLabel(carIndex, s.driverName) or string.format("Car #%02d", carIndex + 1)
      if EventHub then
        local retMsg = string.format("[%s] %s 赛车退赛 (RET)", lapPrefix, dLabel)
        EventHub.pushAiEvent(carIndex, "RETIRED", retMsg, "RACE", _raceState.sessionTime)
        EventHub.settleCarPitCommands(carIndex, dLabel)
      end
      if StrategyCoordinator and StrategyCoordinator.getCarPlan then
        local plan = StrategyCoordinator.getCarPlan(carIndex)
        if plan then
          plan.activeRecommendation = "NONE"
          plan.reason = "Driver Retired (RET)"
        end
      end
    end
    return
  end

  local wasInPitlane = s.isInPitlane
  local wasInPit = s.isInPit
  local rawInPitlane = safeCarGet(c, "isInPitlane") == true
  local rawInPit = safeCarGet(c, "isInPit") == true

  -- Anti-Trigger-Bleed & Starting Grid False Positive Filter:
  -- 1. High Speed Rejection: Pit limiter in AC is strictly 60-80 km/h. Any car traveling > 95.0 km/h
  --    is physically on the racing circuit passing by the pit wall, NOT in the pit lane.
  -- 2. Starting Grid Immunity: On lap 0 with session time < 25s, cars are sitting on the grid waiting for lights.
  local isHighSpeedOnTrack = (s.speedKmh and s.speedKmh > 95.0)
  local isGridFormation = ((s.lapCount or 0) == 0 and (_raceState.sessionTime or 0) < 25.0)

  if isHighSpeedOnTrack or isGridFormation then
    rawInPitlane = false
    rawInPit = false
  end

  s.isInPitlane = rawInPitlane
  s.isInPit = rawInPit
  local isNowInPit = s.isInPitlane or s.isInPit
  local wasInAnyPit = wasInPitlane or wasInPit

  -- Edge 1: Vehicle entering pitlane / pit bay
  if not wasInAnyPit and isNowInPit then
    local dLabel = EventHub and EventHub.formatDriverLabel(carIndex, s.driverName) or string.format("Car #%02d", carIndex + 1)
    s.pit_requested = false
    s.pit_stop_planned = false
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tacticalState = "PIT_BAY"
    s.pitState = s.isInPit and M.PIT_STATE_IN_BAY or M.PIT_STATE_IN_PITLANE

    -- In CSP/AC, setting physics.setAIPitStopRequest to false while entering pitlane cancels
    -- the pit stop intent and causes the AI to drive through without stopping at its pit box.
    -- The request must remain active until the car completes service and exits pitlane.
    if physics and physics.setAIThrottleLimit then
      physics.setAIThrottleLimit(carIndex, 1.0)
    end

    if StrategyCoordinator and StrategyCoordinator.getCarPlan then
      local plan = StrategyCoordinator.getCarPlan(carIndex)
      if plan then
        plan.activeRecommendation = "NONE"
        plan.pitInHandled = true
        local nextStintLaps = (plan.stints and plan.stints[2]) or 15
        plan.targetLap = curLap + nextStintLaps
        plan.openLap = math.max(curLap + 1, plan.targetLap - 2)
        plan.escalateLap = plan.targetLap + 2
      end
    end

    if EventHub then
      -- Format: [第3/13圈] [#02] 车手姓名 已进入维修区
      local pitInMsg = string.format("[%s] %s 已进入维修区", lapPrefix, dLabel)
      EventHub.pushAiEvent(carIndex, "PIT", pitInMsg, "STRATEGY", _raceState.sessionTime)
      EventHub.settleCarPitCommands(carIndex, dLabel)
    end
  end

  -- Continuous invariant: while inside pitlane / pit box
  if isNowInPit then
    s.pit_requested = false
    s.pit_stop_planned = false
    if s.radioCommand == "BOX_THIS_LAP" then
      s.radioCommand = "NONE"
      s.radioOrderActive = false
    end
    if s.tacticalState ~= "PIT_BAY" then
      s.tacticalState = "PIT_BAY"
    end
    if physics and physics.setAIThrottleLimit then
      physics.setAIThrottleLimit(carIndex, 1.0)
    end

    -- Sub-state machine for pit lane vs pit stall
    local isInBay = (s.isInPit == true or s.pitState == M.PIT_STATE_IN_BAY or s.pitState == M.PIT_STATE_SERVICING or s.pitState == M.PIT_STATE_STATIONARY or s.pitState == M.PIT_STATE_VERIFIED)
    local isStationaryInBay = isInBay and (s.speedKmh < 1.0)
    local isDrivingInPitLane = s.isInPitlane and not isInBay

    if isDrivingInPitLane then
      -- Cruising or queueing in pitlane: strictly do NOT trigger pit box servicing
      if s.pitState ~= M.PIT_STATE_RELEASED and s.pitState ~= M.PIT_STATE_VERIFIED then
        s.pitState = M.PIT_STATE_IN_PITLANE
      end
    elseif isStationaryInBay then
      local wo = s.pendingWorkOrder
      local hasPitIntent = s.pit_requested or s.pit_stop_planned or (s.pitState == M.PIT_STATE_IN_PITLANE) or
                           (s.pitState == M.PIT_STATE_IN_BAY) or (s.tacticalState == "BOXING") or
                           (s.radioCommand == "BOX_THIS_LAP") or ((s.fuelInTank or 50.0) < 3.0) or
                           ((s.tyreWear or 0.0) > 0.80)
      local shouldService = wo and not wo.serviced and (
        wo.isConfirmed or wo.status == "CONFIRMED" or wo.isExplicit or (s.isAIControlled and not s.radioOrderActive and hasPitIntent)
      )
      if shouldService then
        s.pitState = M.PIT_STATE_SERVICING
        wo.serviced = true
        wo.status = "VERIFIED"
        wo.isConfirmed = false
        wo.isExecuting = false
        if s.workOrder then s.workOrder.isConfirmed = false end

        -- 1. Fuel delivery: distinguish explicit work order vs autonomous AI strategy
        local currentFuel = s.fuelInTank or safeCarGet(c, "fuel") or 0.0
        local targetFuel = currentFuel
        local addedLiters = 0.0

        if wo.isExplicit or wo.isConfirmed then
          -- Explicit user or pit-wall order
          if wo.refuelLiters and wo.refuelLiters > 0 then
            addedLiters = wo.refuelLiters
            targetFuel = math.min(s.maxFuelCapacity, currentFuel + addedLiters)
          elseif wo.refuelLiters == 0.0 then
            -- Explicit 0L refuel (pure tyre change, modern F1 style)
            addedLiters = 0.0
            targetFuel = currentFuel
          end
        else
          -- Autonomous AI pit stop workflow
          local dynFpl = s.fuelPerLap or (s.empiricalFpl or 2.5)
          local remLaps = math.max(3, (_raceState.totalLaps or 13) - (s.currentLap or 1))
          local neededFuel = math.min(s.maxFuelCapacity, (remLaps * dynFpl) + 2.0)
          targetFuel = math.max(currentFuel, math.min(s.maxFuelCapacity, neededFuel))
          addedLiters = targetFuel - currentFuel
        end

        if targetFuel > currentFuel then
          ControlTelemetry.dispatchCarFuel(carIndex, targetFuel, c, s.driverName)
          s.fuelInTank = targetFuel
        end

        -- 2. One-shot tyre compound fitting
        if wo.changeTyres ~= false then
          local realIdx = wo.targetCompoundIndex or 0
          if ControlTelemetry and ControlTelemetry.resolveRealCompoundIndex then
            realIdx = ControlTelemetry.resolveRealCompoundIndex(carIndex, wo.targetCompoundIndex or 0, wo.targetCompoundName)
          end
          ControlTelemetry.dispatchAITyres(carIndex, realIdx, wo.targetCompoundName, c, s.driverName)
          s.compoundIndex = realIdx
          s.compoundName = wo.targetCompoundName or "Default"
          s.tyreWear = 0.0
          s.tyreWarmupProgress = 0.0
          s.tyreCliffAlertSent = false
          for wIdx = 1, 4 do s.wheelWear[wIdx] = 1.0 end
        end

        s.pitState = M.PIT_STATE_VERIFIED

        -- 3. Emit work order event
        if EventHub then
          local dLabel = EventHub.formatDriverLabel(carIndex, s.driverName)
          local msg = string.format("[%s] %s 进站工单执行完毕: 配方 %s, 补油 %.1fL",
            lapPrefix, dLabel, wo.targetCompoundName or "默认", addedLiters)
          EventHub.pushCommandEvent("PIT_WORK", msg, "SUCCESS")
        end
      else
        if s.pitState ~= M.PIT_STATE_SERVICING and s.pitState ~= M.PIT_STATE_VERIFIED then
          s.pitState = M.PIT_STATE_STATIONARY
        end
      end
    elseif isInBay and s.speedKmh >= 1.0 then
      -- Finished servicing and moving away from stall
      s.pitState = M.PIT_STATE_RELEASED
      if physics and physics.setAIStopCounter then
        physics.setAIStopCounter(carIndex, 0)
      end
      if physics and physics.setAIThrottleLimit then
        physics.setAIThrottleLimit(carIndex, 1.0)
      end
    else
      if s.pitState ~= M.PIT_STATE_RELEASED and s.pitState ~= M.PIT_STATE_VERIFIED then
        s.pitState = M.PIT_STATE_IN_PITLANE
      end
    end
  end

  -- Edge 2: Vehicle exiting pitlane back to track
  if wasInAnyPit and not isNowInPit then
    local dLabel = EventHub and EventHub.formatDriverLabel(carIndex, s.driverName) or string.format("Car #%02d", carIndex + 1)
    s.pit_requested = false
    s.pit_stop_planned = false
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tacticalState = "CRUISE"
    s.pitState = M.PIT_STATE_COMPLETED
    s.actualStopsCount = (s.actualStopsCount or 0) + 1
    s.lastPitLap = curLap
    if s.pendingWorkOrder then
      s.pendingWorkOrder.isExecuting = false
      s.pendingWorkOrder.serviced = false
      s.pendingWorkOrder.status = "NONE"
      s.pendingWorkOrder.isExplicit = false
    end

    -- Guarantee native AC AI is fully released to resume racing
    if physics and physics.setAIPitStopRequest then
      physics.setAIPitStopRequest(carIndex, false)
    end
    if physics and physics.setAIStopCounter then
      physics.setAIStopCounter(carIndex, 0)
    end
    if physics and physics.setAIThrottleLimit then
      physics.setAIThrottleLimit(carIndex, 1.0)
    end

    if StrategyCoordinator and StrategyCoordinator.getCarPlan then
      local plan = StrategyCoordinator.getCarPlan(carIndex)
      if plan then
        plan.activeRecommendation = "NONE"
        plan.pitInHandled = false
      end
    end

    if EventHub then
      -- Format: [第3/13圈] [#02] 车手姓名 进站作业完成
      local pitOutMsg = string.format("[%s] %s 进站作业完成", lapPrefix, dLabel)
      EventHub.pushAiEvent(carIndex, "PIT", pitOutMsg, "STRATEGY", _raceState.sessionTime)
    end
  end

  -- Empirical Fuel Tracking (EMA per completed lap)
  if wasInAnyPit or s.isInPitlane or s.isInPit then
    -- Pit in-lap, pit box service, or out-lap:
    -- Reset anchor to post-service tank level and advance tracked lap so pit deltas/refuels
    -- are completely isolated from clean flying-lap consumption tracking.
    s.fuelAtLapStart = s.fuelInTank
    s.lastTrackedLap = s.lapCount
  elseif s.lapCount > (s.lastTrackedLap or 0) then
    if s.fuelAtLapStart and s.fuelInTank then
      local deltaF = s.fuelAtLapStart - s.fuelInTank
      local sim = ac and ac.getSim and ac.getSim()
      local trackKm = 4.0
      if sim and sim.trackLengthM and sim.trackLengthM > 0 then
        trackKm = sim.trackLengthM / 1000.0
      end
      local minPlausibleFpl = math.max(0.35, trackKm * 0.20)
      local maxPlausibleFpl = math.max(2.2, trackKm * 1.30)

      if deltaF >= minPlausibleFpl and deltaF <= maxPlausibleFpl then
        if s.empiricalFpl == nil then
          s.empiricalFpl = deltaF
        else
          s.empiricalFpl = 0.70 * s.empiricalFpl + 0.30 * deltaF
        end
        s.fuelPerLap = s.empiricalFpl
      end
    end
    s.fuelAtLapStart = s.fuelInTank
    s.lastTrackedLap = s.lapCount
  end

  -- Mechanical Health & Damage Telemetry
  local engLife = safeCarGet(c, "engineLifeLeft")
  if engLife and type(engLife) == "number" then
    s.engineLifeLeft = engLife
  end
  local wTemp = safeCarGet(c, "waterTemperature")
  if wTemp and type(wTemp) == "number" then
    s.waterTemp = wTemp
  end
  local gbDmg = safeCarGet(c, "gearboxDamage")
  if gbDmg and type(gbDmg) == "number" then
    s.gearboxDamage = gbDmg
  end
  local dmg = safeCarGet(c, "damage")
  if dmg and type(dmg) == "table" then
    local maxD = 0.0
    for dIdx = 0, 3 do
      local val = dmg[dIdx]
      if type(val) == "number" and val > maxD then maxD = val end
    end
    s.bodyDamagePct = math.min(100.0, maxD)
  end
  local susp = safeCarGet(c, "suspensionDamage")
  if susp and type(susp) == "table" then
    local maxS = 0.0
    for sIdx = 0, 3 do
      local sVal = susp[sIdx]
      if type(sVal) == "number" and sVal > maxS then maxS = sVal end
    end
    s.suspensionDamagePct = math.min(100.0, maxS * 100.0)
  end

  local dName = safeGetDriverName(carIndex)
  if dName and dName ~= "" then
    s.driverName = dName
  end
  if (not s.driverName or s.driverName == "") and c then
    local cn = safeCarGet(c, "driverName")
    if type(cn) == "function" then
      local okCall, resCall = pcall(cn, c)
      if okCall and resCall and type(resCall) == "string" and resCall ~= "" then
        s.driverName = resCall
      end
    elseif type(cn) == "string" and cn ~= "" then
      s.driverName = cn
    end
  end

  local pos = safeCarGet(c, "position")
  if pos then
    s.posX = pos.x or 0.0
    s.posY = pos.y or 0.0
    s.posZ = pos.z or 0.0
  end

  -- Safe tyre wear retrieval:
  -- AC/CSP official: car.wheels[0].tyreWear (ac.StateWheel.tyreWear number 0~1)
  -- Mock/fallback: car.tyres[0].wear
  local wearVal = nil
  local wheels = safeCarGet(c, "wheels")
  if wheels and wheels[0] then
    local okW, w = pcall(function() return wheels[0].tyreWear end)
    if okW and type(w) == "number" then
      wearVal = w
    end
  end
  if not wearVal then
    local tyres = safeCarGet(c, "tyres")
    if tyres and tyres[0] then
      local okT, tw = pcall(function() return tyres[0].wear end)
      if okT and type(tw) == "number" then
        wearVal = tw
      end
    end
  end
  if wearVal then
    s.tyreWear = wearVal
    if s.tyreWear >= 0.65 and not s.tyreCliffAlertSent and not isNowInPit and (_raceState.sessionTime or 0) > 10.0 then
      s.tyreCliffAlertSent = true
      if EventHub and EventHub.emitTyreCliffAlert then
        EventHub.emitTyreCliffAlert(carIndex, s.driverName, s.tyreWear, _raceState.sessionTime)
      end
    end
  end

  -- Thermal health monitoring
  if s.waterTemp and s.waterTemp > 105.0 and ((_raceState.sessionTime or 0) - (s.lastMechAlertTime or 0)) > 35.0 and (_raceState.sessionTime or 0) > 10.0 then
    s.lastMechAlertTime = _raceState.sessionTime or 0
    if EventHub and EventHub.emitMechanicalAlert then
      EventHub.emitMechanicalAlert(carIndex, s.driverName, "WATER_TEMP", s.waterTemp, _raceState.sessionTime)
    end
  end

  -- Per-wheel telemetry & compound index
  local compIdx = safeCarGet(c, "compoundIndex")
  if compIdx and type(compIdx) == "number" then
    if s.compoundIndex ~= compIdx or not s.compoundName or s.compoundName == "Default" then
      s.compoundIndex = compIdx
      -- Query true compound name from CSP API
      local resolvedName = nil
      if ac and ac.getTyresLongName then
        local okL, lName = pcall(ac.getTyresLongName, carIndex, compIdx, false)
        if okL and lName and type(lName) == "string" and lName ~= "" then
          resolvedName = lName
        end
      end
      if not resolvedName and ac and ac.getTyresName then
        local okS, sName = pcall(ac.getTyresName, carIndex, compIdx)
        if okS and sName and type(sName) == "string" and sName ~= "" then
          resolvedName = sName
        end
      end
      if not resolvedName and c and type(c.tyresLongName) == "function" then
        local okMeth, mName = pcall(c.tyresLongName, c)
        if okMeth and mName and type(mName) == "string" and mName ~= "" then
          resolvedName = mName
        end
      end
      if resolvedName then
        s.compoundName = resolvedName
      end
    end
  end
  if wheels then
    for wIdx = 0, 3 do
      local w = wheels[wIdx]
      if w then
        local wWear = safeCarGet(w, "tyreWear")
        if type(wWear) == "number" then s.wheelWear[wIdx + 1] = wWear end
        local wCore = safeCarGet(w, "tyreCoreTemperature")
        if type(wCore) == "number" then s.wheelCoreTemp[wIdx + 1] = wCore end
        local wBrake = safeCarGet(w, "brakeTemperature")
        if type(wBrake) == "number" then s.wheelBrakeTemp[wIdx + 1] = wBrake end
      end
    end
  end
end

function M.reset()
  _raceState.currentLap = 1
  _raceState.flagState = M.FLAG_GREEN
  _raceState.scActive = false
  _raceState.experienceMode = M.MODE_DRIVER
  _raceState.manualModeOverride = nil
  for i = 0, MAX_CARS - 1 do
    local s = _carStates[i]
    s.lapCount = 0
    s.actualStopsCount = 0
    s.lastPitLap = -1
    s.isRetired = false
    s.pitState = M.PIT_STATE_NONE
    s.stress = 0.0
    s.momentum = 0.0
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tyreWarmupProgress = 1.0
    s.tyreTempNorm = 1.0
    if s.pendingWorkOrder then
      s.pendingWorkOrder.isConfirmed = false
      s.pendingWorkOrder.serviced = false
      s.pendingWorkOrder.status = "NONE"
      s.pendingWorkOrder.isExecuting = false
    end
    s.plannedStops = 0
    s.targetPitLap = 999
    s.openPitLap = 999
    s.escalatePitLap = 999
    s.fuelAtLapStart = nil
    s.empiricalFpl = nil
    s.lastTrackedLap = 0
    s.tyreCliffAlertSent = false
    s.lastMechAlertTime = 0.0
  end
  for k in pairs(_compoundsCache) do
    _compoundsCache[k] = nil
  end
end

M.MAX_CARS = MAX_CARS

-- Spatial Topology Neighbor Ring (Pure scalar, 24 cars)
-- preallocated flat lookup arrays
local _topoAheadIndex = {}
local _topoBehindIndex = {}
local _topoDistAhead = {}
local _topoDistBehind = {}

for i = 0, MAX_CARS - 1 do
  _topoAheadIndex[i] = -1
  _topoBehindIndex[i] = -1
  _topoDistAhead[i] = 999.0
  _topoDistBehind[i] = 999.0
end

--- Update 24-car pairwise topology using track spline position
--- Runs in 10Hz tactical loop before vehicle steps (O(N) scalar distance checks, ~0.01ms)
function M.updateTopology(carsCount, acGetCar)
  local count = math.min(MAX_CARS, carsCount or 0)
  for i = 0, count - 1 do
    _topoAheadIndex[i] = -1
    _topoBehindIndex[i] = -1
    _topoDistAhead[i] = 999.0
    _topoDistBehind[i] = 999.0
  end

  if count < 2 then return end

  for i = 0, count - 1 do
    local okI, carI = pcall(acGetCar, i)
    if okI and carI and carI.isConnected ~= false and carI.position then
      local sI = carI.splinePosition or 0.0
      local pxI = carI.position.x or 0.0
      local pyI = carI.position.y or 0.0
      local pzI = carI.position.z or 0.0

      local bestAheadIdx = -1
      local minAheadDist = 999.0
      local bestBehindIdx = -1
      local minBehindDist = 999.0

      for j = 0, count - 1 do
        if i ~= j then
          local okJ, carJ = pcall(acGetCar, j)
          if okJ and carJ and carJ.isConnected ~= false and carJ.position then
            local dx = carJ.position.x - pxI
            local dy = carJ.position.y - pyI
            local dz = carJ.position.z - pzI
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            
            if dist < 65.0 then -- Focus bubble (65m proximity)
              local sJ = carJ.splinePosition or 0.0
              -- Spline forward distance with wrap-around [0, 1]
              local sDiff = sJ - sI
              if sDiff < -0.5 then sDiff = sDiff + 1.0
              elseif sDiff > 0.5 then sDiff = sDiff - 1.0 end

              local trackLen = _raceState.trackLengthM or 4000.0
              local splineDistM = math.abs(sDiff) * trackLen

              -- Hairpin and adjacent track section filtering:
              -- 1. If cars are separated by > 10% of track or > 400m along the track spline,
              --    they are physically on distant track sections (e.g. parallel straights or multi-loop layouts).
              -- 2. If cars are close in 3D Euclidean space (< 50m) but traveling in opposing directions (heading dot < -0.2),
              --    they are navigating opposite sides of a hairpin, NOT in tactical convoy.
              local isHairpinGhost = false
              if math.abs(sDiff) > 0.10 or splineDistM > 400.0 then
                isHairpinGhost = true
              elseif dist < 50.0 and carI.look and carJ.look then
                local dotHeading = (carI.look.x or 0.0) * (carJ.look.x or 0.0) + (carI.look.z or 0.0) * (carJ.look.z or 0.0)
                if dotHeading < -0.2 then
                  isHairpinGhost = true
                end
              end

              if not isHairpinGhost then
                if sDiff > 0.0 then
                  -- carJ is ahead of carI
                  if dist < minAheadDist then
                    minAheadDist = dist
                    bestAheadIdx = j
                  end
                elseif sDiff < 0.0 then
                  -- carJ is behind carI
                  if dist < minBehindDist then
                    minBehindDist = dist
                    bestBehindIdx = j
                  end
                end
              end
            end
          end
        end
      end

      _topoAheadIndex[i] = bestAheadIdx
      _topoDistAhead[i] = minAheadDist
      _topoBehindIndex[i] = bestBehindIdx
      _topoDistBehind[i] = minBehindDist

      local sState = _carStates[i]
      if sState then
        local spdMs = math.max(10.0, (sState.speedKmh or 120.0) / 3.6)
        sState.gapAheadSec = (bestAheadIdx >= 0 and minAheadDist < 500.0) and (minAheadDist / spdMs) or 999.0
        sState.gapBehindSec = (bestBehindIdx >= 0 and minBehindDist < 500.0) and (minBehindDist / spdMs) or 999.0
      end
    end
  end
end

--- Query topological neighbors for carIndex
---@param carIndex integer
---@return integer aheadIdx, number aheadDist, integer behindIdx, number behindDist
function M.getNeighbors(carIndex)
  if carIndex < 0 or carIndex >= MAX_CARS then
    return -1, 999.0, -1, 999.0
  end
  return _topoAheadIndex[carIndex] or -1,
         _topoDistAhead[carIndex] or 999.0,
         _topoBehindIndex[carIndex] or -1,
         _topoDistBehind[carIndex] or 999.0
end

--- Dynamically query actual tire compound options for the vehicle
function M.getCarCompounds(carIndex)
  if carIndex and _compoundsCache[carIndex] and #_compoundsCache[carIndex] > 0 then
    return _compoundsCache[carIndex]
  end

  local list = {}
  local seenNames = {}

  local function addCompound(idx, sName, lName)
    sName = tostring(sName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    lName = tostring(lName or sName):gsub("^%s+", ""):gsub("%s+$", "")
    if sName == "" and lName == "" then return end
    if sName == "" then sName = lName end
    if lName == "" then lName = sName end
    local dedupeKey = string.upper(lName)
    if seenNames[dedupeKey] then return end
    seenNames[dedupeKey] = true

    list[#list + 1] = {
      index = idx,
      shortName = sName,
      longName = lName,
    }
  end

  -- Tier 1: CSP ac.INIConfig.carData(carIndex, 'tyres.ini')
  if ac and ac.INIConfig and ac.INIConfig.carData and carIndex then
    local okIni, ini = pcall(ac.INIConfig.carData, carIndex, 'tyres.ini')
    if okIni and ini then
      for idx = 0, 15 do
        local secFront = idx == 0 and "FRONT" or ("FRONT_" .. idx)
        local secThermal = idx == 0 and "THERMAL_FRONT" or ("THERMAL_FRONT_" .. idx)
        local secComp = "COMPOUND_" .. idx

        local name = ini:get(secFront, "NAME", "")
        if name == "" then name = ini:get(secThermal, "NAME", "") end
        if name == "" then name = ini:get(secComp, "NAME", "") end

        local shortName = ini:get(secFront, "SHORT_NAME", "")
        if shortName == "" then shortName = ini:get(secThermal, "SHORT_NAME", "") end
        if shortName == "" then shortName = ini:get(secComp, "SHORT_NAME", "") end

        if name ~= "" or shortName ~= "" then
          addCompound(idx, shortName ~= "" and shortName or name, name ~= "" and name or shortName)
        end
      end
    end
  end

  -- Tier 2: CSP setup spinners
  if #list == 0 and ac and ac.getSetupSpinners then
    local okS, spinners = pcall(ac.getSetupSpinners)
    if okS and spinners and type(spinners) == "table" then
      for _, sp in ipairs(spinners) do
        local spName = string.upper(tostring(sp.name or sp.label or ""))
        if spName:find("TYRE") or spName:find("COMPOUND") then
          if sp.items and type(sp.items) == "table" and #sp.items > 0 then
            for sIdx, itemText in ipairs(sp.items) do
              addCompound(sIdx - 1, itemText, itemText)
            end
            break
          end
        end
      end
    end
  end

  -- Tier 3: ac.getTyresName and ac.getTyresLongName
  if #list == 0 and ac and ac.getTyresName and carIndex then
    local emptyStreak = 0
    for idx = 0, 15 do
      local okN, sName = pcall(ac.getTyresName, carIndex, idx)
      if okN and sName and type(sName) == "string" and sName ~= "" then
        emptyStreak = 0
        local lName = sName
        if ac.getTyresLongName then
          local okL, resL = pcall(ac.getTyresLongName, carIndex, idx, false)
          if okL and resL and type(resL) == "string" and resL ~= "" then
            lName = resL
          end
        end
        addCompound(idx, sName, lName)
      else
        emptyStreak = emptyStreak + 1
        if emptyStreak >= 2 and idx >= 4 then
          break
        end
      end
    end
  end

  -- Check if discovered list only collapsed to generic DRY/WET without specific slicks
  local onlyGenericSlicks = false
  if #list > 0 and #list <= 2 then
    local allGeneric = true
    for _, item in ipairs(list) do
      local u = string.upper(item.shortName or item.longName)
      if u ~= "DRY" and u ~= "WET" and u ~= "RAIN" and u ~= "SLICK" then
        allGeneric = false
        break
      end
    end
    onlyGenericSlicks = allGeneric
  end

  -- Tier 4: Cross-car discovery in session (if selected car only found generic DRY/WET)
  if (onlyGenericSlicks or #list == 0) and ac and _raceState.carsCount and _raceState.carsCount > 1 then
    for otherIdx = 0, math.min(_raceState.carsCount, MAX_CARS) - 1 do
      if otherIdx ~= carIndex then
        local otherList = nil
        if ac.INIConfig and ac.INIConfig.carData then
          local okOther, otherIni = pcall(ac.INIConfig.carData, otherIdx, 'tyres.ini')
          if okOther and otherIni then
            local candList = {}
            for idx = 0, 15 do
              local sec = idx == 0 and "FRONT" or ("FRONT_" .. idx)
              local n = otherIni:get(sec, "NAME", "")
              local sn = otherIni:get(sec, "SHORT_NAME", "")
              if n ~= "" or sn ~= "" then
                candList[#candList + 1] = { index = idx, shortName = sn ~= "" and sn or n, longName = n ~= "" and n or sn }
              end
            end
            if #candList >= 3 then
              otherList = candList
            end
          end
        end
        if otherList and #otherList >= 3 then
          list = otherList
          onlyGenericSlicks = false
          break
        end
      end
    end
  end

  -- Tier 5: Rich fallback motorsport compound catalog (F1 & GT3/WEC)
  if #list == 0 or onlyGenericSlicks then
    local fallbackList = {
      { index = 0, shortName = "SOFT",  longName = "Soft Slick (红胎 软胎)" },
      { index = 1, shortName = "MED",   longName = "Medium Slick (黄胎 中性胎)" },
      { index = 2, shortName = "HARD",  longName = "Hard Slick (白胎 硬胎)" },
      { index = 3, shortName = "SS",    longName = "Super Soft (紫胎 超软胎)" },
      { index = 4, shortName = "US",    longName = "Ultra Soft (粉胎 极软胎)" },
      { index = 5, shortName = "INTER", longName = "Intermediate (绿胎 半雨胎)" },
      { index = 6, shortName = "WET",   longName = "Full Wet (蓝胎 全雨胎)" },
    }
    if carIndex then _compoundsCache[carIndex] = fallbackList end
    return fallbackList
  end

  if carIndex then _compoundsCache[carIndex] = list end
  return list
end

--- Configure pit stop work order for a specific car
function M.setCarWorkOrder(carIndex, workOrder)
  if not carIndex or carIndex < 0 or carIndex >= MAX_CARS then return end
  local s = _carStates[carIndex]
  if not s or not workOrder then return end
  s.pendingWorkOrder = s.pendingWorkOrder or {}
  s.workOrder = s.workOrder or {}

  local wo = s.pendingWorkOrder
  wo.baseFuel = s.fuelInTank or 30.0
  if workOrder.changeTyres ~= nil then
    wo.changeTyres = workOrder.changeTyres
    s.workOrder.changeTyres = workOrder.changeTyres
  end
  if workOrder.targetCompoundIndex ~= nil then
    wo.targetCompoundIndex = workOrder.targetCompoundIndex
    s.workOrder.targetCompoundIndex = workOrder.targetCompoundIndex
  end
  if workOrder.targetCompoundName ~= nil then
    wo.targetCompoundName = workOrder.targetCompoundName
    s.workOrder.targetCompoundName = workOrder.targetCompoundName
  end
  if workOrder.refuelLiters ~= nil then
    wo.refuelLiters = math.max(0.0, workOrder.refuelLiters)
    s.workOrder.refuelLiters = math.max(0.0, workOrder.refuelLiters)
    s.workOrder.addFuelLiters = math.max(0.0, workOrder.refuelLiters)
    wo.isExplicit = true
    s.workOrder.isExplicit = true
  end
  if workOrder.isExplicit ~= nil then
    wo.isExplicit = workOrder.isExplicit
    s.workOrder.isExplicit = workOrder.isExplicit
  end
  if workOrder.source ~= nil then
    wo.source = workOrder.source
    s.workOrder.source = workOrder.source
  else
    wo.source = "PLAYER"
    s.workOrder.source = "PLAYER"
  end
  if workOrder.isConfirmed ~= nil then
    wo.isConfirmed = workOrder.isConfirmed
    s.workOrder.isConfirmed = workOrder.isConfirmed
  end
  wo.serviced = false
  wo.status = (workOrder.isConfirmed and "CONFIRMED") or (wo.isExplicit and "CONFIGURED") or "PENDING"
  wo.isExecuting = false
end

--- Get current active experience mode (DRIVER or SPECTATOR)
---@return string
function M.getExperienceMode()
  return _raceState.experienceMode or M.MODE_DRIVER
end

--- Set or override experience mode
---@param mode string? "DRIVER" or "SPECTATOR", nil to revert to auto
function M.setExperienceMode(mode)
  if mode == M.MODE_DRIVER or mode == M.MODE_SPECTATOR then
    _raceState.manualModeOverride = mode
    _raceState.experienceMode = mode
  else
    _raceState.manualModeOverride = nil
  end
end

return M
