--[[
  lib/strategy/StrategyCoordinator.lua
  Ultimate AI Grand Prix Pro - Unified Strategy & Pit Coordinator Layer
  
  Responsibilities:
    - Integrates strategy_calculator, pit_strategy, fuel_model, tyre_model, traffic_model, safety_car
    - Computes and maintains stint plans, pit windows, undercut/overcut recommendations
    - Issues Radio Orders to RaceContext and TacticalTicker (PUSH / SAVE / BOX_THIS_LAP / DEFEND)
    - Executes physical fuel injection at race start and pit exits via physics.setCarFuel / ac.setCarFuel
    - Provides human manual override dispatching (Human / Pit Wall Control)
    - Replaces and obsoletes legacy fuel_guard.lua
]]

local Logger = require("lib/core/Logger")
local RaceContext = require("lib/core/RaceContext")
local StrategyCalc = require("lib/strategy/strategy_calculator")
local PitStrategy = require("lib/strategy/pit_strategy")
local FuelModel = require("lib/strategy/fuel_model")
local TyreModel = require("lib/strategy/tyre_model")
local TrafficModel = require("lib/strategy/traffic_model")
local SafetyCar = require("lib/strategy/safety_car")
local StrategyAuthority = require("lib/strategy/strategy_authority")
local EventHub = require("lib/core/EventHub")
local ControlTelemetry = require("lib/core/ControlTelemetry")

local M = {}

local MAX_CARS = 24
local _carPlans = {}         -- [carIdx] = { stints, plannedStops, targetLap, openLap, escalateLap, fpl }
local _carAuthority = {}     -- [carIdx] = authority state from strategy_authority
local _carLastPitTimes = {}  -- [carIdx] = timestamp
local _fuelInjected = {}     -- [carIdx] = boolean (start fuel injected)
local _initialized = false

local function toNum(v, def)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
  end
  return def
end

function M.init()
  for i = 0, MAX_CARS - 1 do
    _carPlans[i] = {
      plannedStops = 1,
      targetLap = 15,
      openLap = 13,
      escalateLap = 18,
      stints = {},
      baseFpl = 2.5,
      dynamicFpl = 2.5,
      fuelInjectedAtStart = false,
      pitInHandled = false,
      activeRecommendation = "STAY_OUT",
      confidence = 1.0,
      reason = "Nominal Stint",
    }
    _carAuthority[i] = StrategyAuthority.createCarAuthorityState(i)
    _carLastPitTimes[i] = 0.0
    _fuelInjected[i] = false
  end
  _initialized = true
  Logger.info("STRATEGY", "StrategyCoordinator initialized for 64 cars")
end

--- Build or re-calculate baseline strategy for all cars based on total laps and stops
function M.rebuildFieldStrategy(totalLaps, defaultStops, baseFpl)
  local race = RaceContext.getRaceState()
  totalLaps = math.max(1, math.floor(toNum(totalLaps, (race and race.totalLaps) or 13)))
  defaultStops = math.min(StrategyCalc.MAX_PIT_STOPS, math.max(0, math.floor(toNum(defaultStops, 1))))

  -- Dynamic base FPL estimation from track length if not explicitly provided
  local defaultFpl = 2.5
  if ac and ac.getSim then
    local okSim, sim = pcall(ac.getSim)
    if okSim and sim and sim.trackLengthM and sim.trackLengthM > 0 then
      defaultFpl = math.max(1.2, math.min(4.5, (sim.trackLengthM / 1000.0) * 0.55))
    end
  end
  baseFpl = toNum(baseFpl, defaultFpl)

  for i = 0, MAX_CARS - 1 do
    local plan = _carPlans[i]
    if not plan then
      _carPlans[i] = {
        plannedStops = 1,
        targetLap = 15,
        openLap = 13,
        escalateLap = 18,
        stints = {},
        baseFpl = baseFpl,
        dynamicFpl = baseFpl,
        fuelInjectedAtStart = false,
        pitInHandled = false,
        activeRecommendation = "STAY_OUT",
        confidence = 1.0,
        reason = "Nominal Stint",
      }
      plan = _carPlans[i]
    end
    if defaultStops then plan.plannedStops = defaultStops end
    local stops = plan.plannedStops or 1
    local stintCount = StrategyCalc.computeStintCount(stops, totalLaps)
    local stintLaps = StrategyCalc.splitTotalLapsAcrossStints(totalLaps, stintCount)
    
    local cState = RaceContext.getCarState(i)
    local carBaseFpl = cState.empiricalFpl or baseFpl
    plan.stints = stintLaps
    plan.baseFpl = carBaseFpl
    plan.dynamicFpl = carBaseFpl

    if #stintLaps > 1 then
      local firstStintLaps = stintLaps[1]
      local cFuel = (cState.fuelInTank and cState.fuelInTank > 5.0) and cState.fuelInTank or (cState.maxFuelCapacity or 80.0)
      local maxFuelLaps = math.max(4, math.floor((cFuel - 1.0) / math.max(0.5, carBaseFpl)))

      local win = StrategyCalc.computePitWindowForStint(1, 1, firstStintLaps, firstStintLaps, totalLaps)
      local groupOffset = StrategyCalc.getF1PitSpreadGroupOffset(i, 0)
      local lapOffset = math.floor(groupOffset * 2.0 + 0.5)

      local personaLoader = package.loaded["lib/driver/persona_loader"]
      local persona = personaLoader and personaLoader.getPersonaForCar(i, cState.driverName)
      local undercutBias = (persona and persona.undercut_preference or 0.5) - 0.5
      local personaShift = (undercutBias > 0.2 and -1) or (undercutBias < -0.2 and 1) or 0

      local rawTarget = win.targetLap + lapOffset + personaShift
      local staggeredTarget = math.max(win.openLap + 1, math.min(math.min(totalLaps - 1, maxFuelLaps), rawTarget))
      plan.openLap = math.max(1, math.min(staggeredTarget, win.openLap + lapOffset + personaShift))
      plan.targetLap = staggeredTarget
      plan.escalateLap = math.max(staggeredTarget, math.min(maxFuelLaps, win.escalateLap + lapOffset + personaShift))
    else
      plan.openLap = 999
      plan.targetLap = 999
      plan.escalateLap = 999
    end

    cState.plannedStops = stops
    cState.targetPitLap = plan.targetLap
    cState.openPitLap = plan.openLap
    cState.escalatePitLap = plan.escalateLap
  end
  Logger.info("STRATEGY", string.format("Rebuilt field strategy (Laps: %d, Default Stops: %d)", totalLaps, defaultStops))
  EventHub.pushCommandEvent("STRATEGY", string.format("全场进站策略更新成功: %d 圈 / %d 停方案 (基准油耗: %.2f L/圈)", totalLaps, defaultStops, baseFpl), "SUCCESS")
end

--- Get car plan
function M.getCarPlan(carIndex)
  return _carPlans[carIndex] or _carPlans[0]
end

--- Set manual radio command (Pit Wall order)
function M.issueRadioOrder(carIndex, command)
  if carIndex < 0 or carIndex >= MAX_CARS then
    EventHub.pushCommandEvent("RADIO", string.format("指令下发失败: 无效车辆编号 #%d", (carIndex or -1) + 1), "FAILED")
    return false
  end
  local cState = RaceContext.getCarState(carIndex)
  local dLabel = EventHub.formatDriverLabel(carIndex, cState.driverName)
  local cmd = command or "NONE"
  -- Immediately close the loop in Driver / Strategy state machine
  if cmd == "BOX_THIS_LAP" then
    -- Idempotency protection & deduplication
    if cState.pit_requested or cState.tacticalState == "BOXING" or cState.tacticalState == "PIT_BAY" or cState.isInPitlane or cState.isInPit or EventHub.isCarPitPending(carIndex) then
      local msg = string.format("[CMD MERGED] %s 当前已处于进站流程中，指令自动合流（请勿重复下发）", dLabel)
      EventHub.pushCommandEvent("RADIO", msg, "PENDING")
      return true
    end

    cState.radioCommand = cmd
    cState.radioOrderActive = true
    cState.tacticalState = "BOXING"
    cState.pit_requested = true
    cState.pit_stop_planned = true
    cState.pitState = "REQUESTED"
    EventHub.registerPitCommand(carIndex)

    local plan = _carPlans[carIndex]
    if plan then
      plan.activeRecommendation = "BOX_THIS_LAP"
    end
    -- Official CSP AI Pit Stop Request:
    -- physics.setAIPitStopRequest(carIndex, true) directs native AC AI to pit on current lap.
    -- Replaces and obsoletes artificial fuel starvation hacks.
    local wo = cState.workOrder
    local targetComp = (wo and wo.targetCompoundName) or "Hard"
    local targetFuel = (wo and wo.addFuelLiters) or 42
    ControlTelemetry.dispatchPitStopRequest(carIndex, true, targetComp, targetFuel, nil, cState.driverName)
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [BOX_THIS_LAP] (CSP原生进站请求激活)", dLabel), "SUCCESS")
    EventHub.pushAiEvent(carIndex, "RADIO", string.format("【进站指令】%s 车队无线电下达: 本圈立即进站换胎！赛车已进入进站准备姿态！", dLabel), "STRATEGY")
  elseif cmd == "PUSH" then
    cState.radioCommand = "PUSH"
    cState.radioOrderActive = true
    cState.tacticalState = "ATTACK"
    cState.pit_requested = false
    cState.pit_stop_planned = false
    if cState.pitState == "REQUESTED" then cState.pitState = "NONE" end
    ControlTelemetry.dispatchPitStopRequest(carIndex, false, nil, nil, nil, cState.driverName)
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [PUSH 全力推进]", dLabel), "SUCCESS")
  elseif cmd == "ATTACK" then
    cState.radioCommand = "ATTACK"
    cState.radioOrderActive = true
    cState.tacticalState = "ATTACK"
    cState.pit_requested = false
    cState.pit_stop_planned = false
    if cState.pitState == "REQUESTED" then cState.pitState = "NONE" end
    ControlTelemetry.dispatchPitStopRequest(carIndex, false, nil, nil, nil, cState.driverName)
    ControlTelemetry.logEnergyDeployment(carIndex, "Deployed overtake boost mode", nil, cState.driverName)
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [ATTACK 激进超车]", dLabel), "SUCCESS")
  elseif cmd == "DEFEND" then
    cState.radioCommand = "DEFEND"
    cState.radioOrderActive = true
    cState.tacticalState = "DEFEND"
    cState.pit_requested = false
    cState.pit_stop_planned = false
    if cState.pitState == "REQUESTED" then cState.pitState = "NONE" end
    ControlTelemetry.dispatchPitStopRequest(carIndex, false, nil, nil, nil, cState.driverName)
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [DEFEND 极限卡位防守]", dLabel), "SUCCESS")
  elseif cmd == "SAVE" then
    cState.radioCommand = "SAVE"
    cState.radioOrderActive = true
    cState.tacticalState = "CRUISE"
    cState.isLiftAndCoast = true
    cState.pit_requested = false
    cState.pit_stop_planned = false
    if cState.pitState == "REQUESTED" then cState.pitState = "NONE" end
    ControlTelemetry.dispatchPitStopRequest(carIndex, false, nil, nil, nil, cState.driverName)
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [SAVE 保胎节油]", dLabel), "SUCCESS")
  elseif cmd == "NONE" then
    cState.radioCommand = "NONE"
    cState.radioOrderActive = false
    cState.tacticalState = "CRUISE"
    cState.isLiftAndCoast = false
    cState.pit_requested = false
    cState.pit_stop_planned = false
    cState.pitState = "NONE"
    local plan = _carPlans[carIndex]
    if plan then
      plan.activeRecommendation = "NONE"
    end
    ControlTelemetry.dispatchPitStopRequest(carIndex, false, nil, nil, nil, cState.driverName)
    EventHub.settleCarPitCommands(carIndex, dLabel)
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 指令已解除 -> 恢复自主战术", dLabel), "SUCCESS")
  end

  Logger.info("RADIO", string.format("Issued Radio Command [%s] to %s", tostring(cmd), dLabel))
  return true
end

--- Main 1Hz/0.5Hz Strategy Evaluation Tick
--- Runs asynchronously from 10Hz driver tick to save CPU
function M.stepStrategy(dt)
  if not _initialized then return end

  local race = RaceContext.getRaceState()
  if race.isReplay then return end

  local carsCount = race.carsCount or 0
  local curLap = race.currentLap or 1
  local totalLaps = race.totalLaps or 13

  for i = 0, carsCount - 1 do
    local cState = RaceContext.getCarState(i)
    if cState.isConnected and cState.isAIControlled then
      local plan = _carPlans[i]
      local auth = _carAuthority[i]

      -- Update baseFpl if empirical measurement from completed laps is available
      if cState.empiricalFpl then
        plan.baseFpl = cState.empiricalFpl
      end

      -- 1. Compute dynamic fuel consumption
      local trafficFactor = cState.isInDirtyAir and 0.8 or 0.0
      local paceDelta = 0.0
      if cState.radioCommand == "PUSH" then paceDelta = -0.04
      elseif cState.radioCommand == "ATTACK" then paceDelta = -0.06
      elseif cState.radioCommand == "SAVE" then paceDelta = 0.05
      elseif cState.radioCommand == "DEFEND" then paceDelta = 0.02 end

      local dynFpl = FuelModel.calculateDynamicFuelPerLap(
        plan.baseFpl,
        cState.fuelInTank,
        cState.maxFuelCapacity,
        race.flagState,
        trafficFactor,
        0.5,
        paceDelta
      )
      plan.dynamicFpl = dynFpl
      cState.fuelPerLap = dynFpl

      -- 2. Check Fuel Starvation Deadlock Guard (replaces fuel_guard.lua)
      if cState.fuelInTank < 1.8 and not cState.isInPitlane and not cState.isInPit then
        if physics and physics.setCarFuel then
          physics.setCarFuel(i, math.max(cState.fuelInTank, 8.0))
          Logger.warn("GUARD", string.format("Emergency Fuel Guard injected 8.0L into Car #%d (Laps %d)", i + 1, curLap), 5.0)
        end
      end

      -- 3. Dynamic Pit Window & Undercut/Overcut Evaluation
      if not (cState.isInPitlane or cState.isInPit) and (cState.pitState == "NONE" or not cState.pitState) and curLap >= plan.openLap and curLap <= plan.escalateLap then
        local fuelLaps = FuelModel.estimateLapsRemaining(cState.fuelInTank, dynFpl, 0.5)

        -- Resolve real telemetry and persona for accurate tactical evaluation
        local aheadIdx, aheadDist = RaceContext.getNeighbors(i)
        local mySpdMs = math.max(15.0, (cState.speedKmh or 120.0) / 3.6)
        local gapAheadSec = (aheadDist < 200.0) and (aheadDist / mySpdMs) or 999.0

        local personaLoader = package.loaded["lib/driver/persona_loader"]
        local persona = personaLoader and personaLoader.getPersonaForCar(i, cState.driverName) or {}

        local evalInput = {
          currentLap = curLap,
          plannedPitLap = plan.targetLap,
          fuelLapsRemaining = fuelLaps,
          currentTyrePaceLoss = cState.tyreWear * 2.5,
          freshTyreAdvantage = 1.0,
          gapAheadSec = gapAheadSec,
          gapBehindSec = 4.0,
          exitTrafficPenaltyNow = 0.0,
          exitTrafficPenaltyLater = 0.0,
          persona = persona,
          scActive = race.scActive
        }

        local decision = PitStrategy.evaluatePitTimingOptions(evalInput)
        if decision and decision.bestOption then
          -- Strict Gating: Prevent premature pit stops unless critical conditions are met
          local isTargetLapReached = (curLap >= plan.targetLap)
          local isFuelEmergency = (fuelLaps <= 1.2)
          local isTyreCliff = (cState.tyreWear >= 0.58)
          local isSafetyCarCheapStop = (race.scActive == true)
          local isRealUndercut = (decision.bestOption.action == "PIT_NOW") and (curLap >= plan.targetLap - 1) and (gapAheadSec < 1.6) and ((persona.undercut_preference or 0.5) >= 0.65)

          local shouldBox = isTargetLapReached or isFuelEmergency or isTyreCliff or isSafetyCarCheapStop or isRealUndercut

          if shouldBox then
            plan.activeRecommendation = "BOX_THIS_LAP"
            -- Autonomous AI Strategic Pit Decision:
            -- Pure recommendation NEVER mutates cState.radioCommand (which is reserved for Human / Pit Wall orders).
            -- Autonomous AI triggers internal pit request ONLY when no manual radio command is active:
            if not cState.radioOrderActive then
              if not cState.pit_requested and not plan.pitInHandled then
                cState.pit_requested = true
                cState.tacticalState = "BOXING"
                cState.pitState = "REQUESTED"
                local wo = cState.workOrder
                local targetComp = (wo and wo.targetCompoundName) or "Optimal"
                local targetFuel = (wo and wo.addFuelLiters) or 35
                ControlTelemetry.dispatchPitStopRequest(i, true, targetComp, targetFuel, nil, cState.driverName)
              end
            end
          else
            plan.activeRecommendation = "STAY_OUT"
          end
          plan.confidence = decision.bestOption.score or 1.0
          plan.reason = decision.bestOption.reason or (isRealUndercut and "Undercut window" or "Stint window")
        end
      else
        if curLap > plan.escalateLap and not plan.pitInHandled then
          -- Past escalate lap without pitting: reset to next stint
          plan.openLap = curLap + 12
          plan.targetLap = curLap + 15
          plan.escalateLap = curLap + 17
        end
      end

      -- 4. Pit Stop Detection & Fuel Refill Handling
      if cState.isInPitlane or cState.isInPit then
        cState.pit_requested = false
        cState.pit_stop_planned = false
        cState.radioCommand = "NONE"
        cState.radioOrderActive = false
        cState.tacticalState = "PIT_BAY"
        plan.activeRecommendation = "NONE"

        -- Release stop counter: pass 0 to ensure native AC AI is never frozen
        if physics and physics.setAIStopCounter then
          physics.setAIStopCounter(i, 0)
        end
        if physics and physics.setAIThrottleLimit then
          physics.setAIThrottleLimit(i, 1.0)
        end

        if not plan.pitInHandled then
          plan.pitInHandled = true
          cState.actualStopsCount = cState.actualStopsCount + 1
          cState.lastPitLap = curLap

          -- Advance plan target lap for next stint so it does not re-trigger
          local nextStintLaps = (plan.stints and plan.stints[2]) or 15
          plan.targetLap = curLap + nextStintLaps
          plan.openLap = math.max(curLap + 1, plan.targetLap - 2)
          plan.escalateLap = plan.targetLap + 2

          local dLabel = EventHub.formatDriverLabel(i, cState.driverName)

          -- Trigger fresh tyre out-lap warmup state (cold tyre warmup begins from 0.0)
          cState.tyreWarmupProgress = 0.0
          cState.tyreWear = 0.0 -- fresh tyres fitted
          cState.tyreLapsAge = 0

          -- Refill fuel for next stint
          local refillLiters = math.min(cState.maxFuelCapacity, dynFpl * 15.0)
          if physics and physics.setCarFuel then
            ControlTelemetry.dispatchCarFuel(i, refillLiters, nil, cState.driverName)
            Logger.info("PIT", string.format("%s completed pit stop (Refilled: %.1fL, Next Stint Ready, Cold Out-Lap Active)", dLabel, refillLiters))
          end

          EventHub.settleCarPitCommands(i, dLabel)
        end
      else
        plan.pitInHandled = false
      end
    end
  end
end

function M.reset()
  for i = 0, MAX_CARS - 1 do
    local plan = _carPlans[i]
    plan.pitInHandled = false
    plan.fuelInjectedAtStart = false
    plan.activeRecommendation = "STAY_OUT"
  end
end

return M
