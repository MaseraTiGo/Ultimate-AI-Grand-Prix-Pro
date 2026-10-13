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
  baseFpl = toNum(baseFpl, 2.5)

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
    
    plan.stints = stintLaps
    plan.baseFpl = baseFpl
    plan.dynamicFpl = baseFpl

    if #stintLaps > 1 then
      local firstStintLaps = stintLaps[1]
      local win = StrategyCalc.computePitWindowForStint(1, 1, firstStintLaps, firstStintLaps, totalLaps)
      plan.openLap = win.openLap
      plan.targetLap = win.targetLap
      plan.escalateLap = win.escalateLap
    else
      plan.openLap = 999
      plan.targetLap = 999
      plan.escalateLap = 999
    end

    local cState = RaceContext.getCarState(i)
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

    cState.tacticalState = "BOXING"
    cState.pit_requested = true
    cState.pit_stop_planned = true
    EventHub.registerPitCommand(carIndex)

    local plan = _carPlans[carIndex]
    if plan then
      plan.activeRecommendation = "BOX_THIS_LAP"
    end
    -- Forced Physical Pit Entry Induction:
    -- In Assetto Corsa native AI, cars ONLY branch into pitlane when fuel drops below critical reserve (~2L).
    -- Setting fuel to 1.8L forces AC native AI navigation to branch into pitlane immediately on this lap!
    if physics and physics.setCarFuel then
      physics.setCarFuel(carIndex, 1.8)
    end
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [BOX_THIS_LAP] (物理诱导激活)", dLabel), "SUCCESS")
    EventHub.pushAiEvent(carIndex, "RADIO", string.format("【进站指令】%s 车队无线电下达: 本圈立即进站换胎！赛车已进入进站准备姿态！", dLabel), "STRATEGY")
  elseif cmd == "PUSH" then
    cState.radioCommand = "PUSH"
    cState.radioOrderActive = true
    cState.tacticalState = "ATTACK"
    cState.pit_requested = false
    cState.pit_stop_planned = false
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [PUSH 全力推进]", dLabel), "SUCCESS")
  elseif cmd == "SAVE" then
    cState.radioCommand = "SAVE"
    cState.radioOrderActive = true
    cState.tacticalState = "CRUISE"
    cState.isLiftAndCoast = true
    cState.pit_requested = false
    cState.pit_stop_planned = false
    EventHub.pushCommandEvent("RADIO", string.format("[CMD ACCEPTED] %s 确认指令 -> 执行 [SAVE 保胎节油]", dLabel), "SUCCESS")
  elseif cmd == "NONE" then
    cState.radioCommand = "NONE"
    cState.radioOrderActive = false
    cState.tacticalState = "CRUISE"
    cState.isLiftAndCoast = false
    cState.pit_requested = false
    cState.pit_stop_planned = false
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

      -- 1. Compute dynamic fuel consumption
      local trafficFactor = cState.isInDirtyAir and 0.8 or 0.0
      local paceDelta = 0.0
      if cState.radioCommand == "PUSH" then paceDelta = -0.04
      elseif cState.radioCommand == "SAVE" then paceDelta = 0.05 end

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
      if curLap >= plan.openLap and curLap <= plan.escalateLap then
        local fuelLaps = FuelModel.estimateLapsRemaining(cState.fuelInTank, dynFpl, 0.5)
        local evalInput = {
          currentLap = curLap,
          plannedPitLap = plan.targetLap,
          fuelLapsRemaining = fuelLaps,
          currentTyrePaceLoss = cState.tyreWear * 2.0,
          freshTyreAdvantage = 1.0,
          gapAheadSec = 2.0,
          gapBehindSec = 3.0,
          exitTrafficPenaltyNow = 0.0,
          exitTrafficPenaltyLater = 0.5,
          persona = {},
          scActive = race.scActive
        }

        local decision = PitStrategy.evaluatePitTimingOptions(evalInput)
        if decision and decision.bestOption then
          if decision.bestOption.action == "PIT_NOW" or curLap >= plan.targetLap or fuelLaps <= 1.2 then
            plan.activeRecommendation = "BOX_THIS_LAP"
            -- If in autonomous AI mode or order confirmed, set radio order
            if not cState.radioOrderActive or cState.radioCommand == "BOX_THIS_LAP" then
              cState.radioCommand = "BOX_THIS_LAP"
            end
          else
            plan.activeRecommendation = "STAY_OUT"
          end
          plan.confidence = decision.bestOption.score or 1.0
          plan.reason = decision.bestOption.reason or "Stint window"
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
        if not plan.pitInHandled then
          plan.pitInHandled = true
          plan.activeRecommendation = "NONE"
          cState.actualStopsCount = cState.actualStopsCount + 1
          cState.lastPitLap = curLap
          cState.radioCommand = "NONE"
          cState.radioOrderActive = false
          cState.tacticalState = "CRUISE"
          cState.pit_requested = false
          cState.pit_stop_planned = false

          local dLabel = EventHub.formatDriverLabel(i, cState.driverName)
          EventHub.pushAiEvent(i, "PIT", string.format("【进站作业】%s 已平稳驶入维修区，车组人员开始换胎与补油！", dLabel), "STRATEGY", race.sessionTime)

          -- Trigger realistic pit dwell pause if available (3.0 seconds service dwell)
          if physics and physics.setAIStopCounter then
            physics.setAIStopCounter(i, 3)
          end

          -- Trigger fresh tyre out-lap warmup state (cold tyre warmup begins from 0.0)
          cState.tyreWarmupProgress = 0.0
          cState.tyreWear = 0.0 -- fresh tyres fitted
          cState.tyreLapsAge = 0

          -- Refill fuel for next stint
          local refillLiters = math.min(cState.maxFuelCapacity, dynFpl * 15.0)
          if physics and physics.setCarFuel then
            physics.setCarFuel(i, refillLiters)
            Logger.info("PIT", string.format("%s completed pit stop (Refilled: %.1fL, Next Stint Ready, Cold Out-Lap Active)", dLabel, refillLiters))
          end
          EventHub.pushAiEvent(i, "PIT", string.format("【完成出站】%s 进站作业完成（加注 %.1fL 燃油，换装全新轮胎），安全出站重返赛道！", dLabel, refillLiters), "STRATEGY", race.sessionTime)
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
