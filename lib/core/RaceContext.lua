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
M.PIT_STATE_NONE       = "NONE"
M.PIT_STATE_REQUESTED  = "REQUESTED"
M.PIT_STATE_IN_PITLANE = "IN_PITLANE"
M.PIT_STATE_IN_BAY     = "IN_BAY"
M.PIT_STATE_COMPLETED  = "COMPLETED"

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
}

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
    positionInRace = i + 1,
    prevPositionInRace = i + 1,
    tyreCliffAlertSent = false,
    lastMechAlertTime = 0.0,
    isInPitlane = false,
    isInPit = false,
    pitState = M.PIT_STATE_NONE,
    
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
    fuelAtLapStart = 30.0,
    lastTrackedLap = 0,

    -- Dynamic Pit Stop Work Order
    pendingWorkOrder = {
      changeTyres = true,
      targetCompoundIndex = 0,
      targetCompoundName = "Default",
      refuelLiters = 0.0,
      isConfirmed = false,
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
    plannedStops = 1,
    currentStint = 1,
    targetPitLap = 15,
    openPitLap = 13,
    escalatePitLap = 18,
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
  local prevPos = s.positionInRace
  local newPos = safeCarGet(c, "racePosition") or (carIndex + 1)
  s.positionInRace = newPos

  local EventHub = package.loaded["lib/core/EventHub"]
  local StrategyCoordinator = package.loaded["lib/strategy/StrategyCoordinator"]

  if prevPos and prevPos > 0 and newPos < prevPos and s.speedKmh > 50.0 and (s.lapCount or 0) > 0 and (_raceState.sessionTime or 0) > 8.0 then
    if EventHub and EventHub.emitOvertake then
      EventHub.emitOvertake(carIndex, s.driverName, newPos, _raceState.sessionTime)
    end
  end

  local wasInPitlane = s.isInPitlane
  local wasInPit = s.isInPit
  s.isInPitlane = safeCarGet(c, "isInPitlane") == true
  s.isInPit = safeCarGet(c, "isInPit") == true
  local isNowInPit = s.isInPitlane or s.isInPit
  local wasInAnyPit = wasInPitlane or wasInPit

  local curLap = _raceState.currentLap or 1
  local totalLaps = _raceState.totalLaps or 13
  local lapPrefix = (EventHub and EventHub.formatLapStr) and EventHub.formatLapStr(curLap, totalLaps) or string.format("第%d/%d圈", curLap, totalLaps)

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

  -- Continuous invariant: while inside pitlane / pit box, stay cleared
  if isNowInPit then
    s.pit_requested = false
    s.pit_stop_planned = false
    if s.radioCommand == "BOX_THIS_LAP" then
      s.radioCommand = "NONE"
      s.radioOrderActive = false
    end
    if s.isInPit then
      s.pitState = M.PIT_STATE_IN_BAY
    else
      s.pitState = M.PIT_STATE_IN_PITLANE
    end
    if s.tacticalState ~= "PIT_BAY" then
      s.tacticalState = "PIT_BAY"
    end
    if physics and physics.setAIThrottleLimit then
      physics.setAIThrottleLimit(carIndex, 1.0)
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

  local fuelVal = safeCarGet(c, "fuel")
  if fuelVal and type(fuelVal) == "number" then
    s.fuelInTank = fuelVal
  end
  local maxFuel = safeCarGet(c, "maxFuel")
  if maxFuel and type(maxFuel) == "number" and maxFuel > 0 then
    s.maxFuelCapacity = maxFuel
  end

  -- Empirical Fuel Tracking (EMA per completed lap)
  if s.lapCount > (s.lastTrackedLap or 0) then
    if s.fuelAtLapStart and s.fuelInTank then
      local deltaF = s.fuelAtLapStart - s.fuelInTank
      if deltaF > 0.1 and deltaF < 20.0 then
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
    s.compoundIndex = compIdx
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

  -- Execute pending work order if confirmed upon entering/dwelling in pit bay
  if s.isInPit and s.pendingWorkOrder and s.pendingWorkOrder.isConfirmed then
    local wo = s.pendingWorkOrder
    if wo.refuelLiters and wo.refuelLiters > 0 then
      local targetFuel = math.min(s.maxFuelCapacity, s.fuelInTank + wo.refuelLiters)
      if physics and physics.setCarFuel then
        ControlTelemetry.dispatchCarFuel(carIndex, targetFuel, c, s.driverName)
      end
      s.fuelInTank = targetFuel
    end
    if wo.changeTyres then
      if physics and physics.setAITyres then
        ControlTelemetry.dispatchAITyres(carIndex, wo.targetCompoundIndex or 0, wo.targetCompoundName, c, s.driverName)
      end
      s.tyreWear = 0.0
      s.tyreCliffAlertSent = false
      for wIdx = 1, 4 do s.wheelWear[wIdx] = 1.0 end
      s.compoundIndex = wo.targetCompoundIndex or 0
      s.compoundName = wo.targetCompoundName or "Default"
    end
    wo.isConfirmed = false
    if EventHub then
      local dLabel = EventHub.formatDriverLabel(carIndex, s.driverName)
      local msg = string.format("[%s] %s 进站工单执行完毕: 配方 %s, 补油 %.1fL",
        lapPrefix, dLabel, wo.targetCompoundName or "默认", wo.refuelLiters or 0.0)
      EventHub.pushCommandEvent("PIT_WORK", msg, "SUCCESS")
    end
  end
end

function M.reset()
  _raceState.currentLap = 1
  _raceState.flagState = M.FLAG_GREEN
  _raceState.scActive = false
  for i = 0, MAX_CARS - 1 do
    local s = _carStates[i]
    s.lapCount = 0
    s.actualStopsCount = 0
    s.lastPitLap = -1
    s.pitState = M.PIT_STATE_NONE
    s.stress = 0.0
    s.momentum = 0.0
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tyreWarmupProgress = 1.0
    s.tyreTempNorm = 1.0
    if s.pendingWorkOrder then s.pendingWorkOrder.isConfirmed = false end
    s.empiricalFpl = nil
    s.lastTrackedLap = 0
    s.tyreCliffAlertSent = false
    s.lastMechAlertTime = 0.0
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

      _topoAheadIndex[i] = bestAheadIdx
      _topoDistAhead[i] = minAheadDist
      _topoBehindIndex[i] = bestBehindIdx
      _topoDistBehind[i] = minBehindDist
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
local _compoundsCache = {}

function M.getCarCompounds(carIndex)
  if _compoundsCache[carIndex] then
    return _compoundsCache[carIndex]
  end

  local list = {}
  if ac and ac.getTyresName then
    for idx = 0, 10 do
      local okN, sName = pcall(ac.getTyresName, carIndex, idx)
      if okN and sName and type(sName) == "string" and sName ~= "" then
        local lName = sName
        if ac.getTyresLongName then
          local okL, resL = pcall(ac.getTyresLongName, carIndex, idx, false)
          if okL and resL and type(resL) == "string" and resL ~= "" then
            lName = resL
          end
        end
        list[#list + 1] = {
          index = idx,
          shortName = sName,
          longName = lName,
        }
      else
        break
      end
    end
  end

  if #list == 0 then
    list[1] = { index = 0, shortName = "SOFT", longName = "Soft Compound" }
    list[2] = { index = 1, shortName = "MED", longName = "Medium Compound" }
    list[3] = { index = 2, shortName = "HARD", longName = "Hard Compound" }
  end

  _compoundsCache[carIndex] = list
  return list
end

--- Configure pit stop work order for a specific car
function M.setCarWorkOrder(carIndex, workOrder)
  if not carIndex or carIndex < 0 or carIndex >= MAX_CARS then return end
  local s = _carStates[carIndex]
  if not s or not workOrder then return end
  s.pendingWorkOrder = s.pendingWorkOrder or {}
  if workOrder.changeTyres ~= nil then
    s.pendingWorkOrder.changeTyres = workOrder.changeTyres
  end
  if workOrder.targetCompoundIndex ~= nil then
    s.pendingWorkOrder.targetCompoundIndex = workOrder.targetCompoundIndex
  end
  if workOrder.targetCompoundName ~= nil then
    s.pendingWorkOrder.targetCompoundName = workOrder.targetCompoundName
  end
  if workOrder.refuelLiters ~= nil then
    s.pendingWorkOrder.refuelLiters = math.max(0.0, workOrder.refuelLiters)
  end
  if workOrder.isConfirmed ~= nil then
    s.pendingWorkOrder.isConfirmed = workOrder.isConfirmed
  end
end

return M
