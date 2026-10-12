--[[
  Ultimate AI Grand Prix Pro.lua
  Main App Entry Point for Assetto Corsa Custom Shaders Patch
  
  Responsibilities:
    - Lifecycle Management (init, simUpdate, update, windowMain, windowSetup)
    - 60Hz Physics Watchdog execution (watchdog.stepPhysics)
    - 10Hz Driver Ticking & Spatial LOD pipeline (TacticalTicker, BehaviorActuator)
    - 1Hz / 0.5Hz Dynamic Strategy & Pit Wall pipeline (StrategyCoordinator)
    - Unified ImGui Pit Wall & Live HUD rendering (DashboardUI)
    - Telemetry stamping for zero-overhead ecosystem bridge
]]

local Logger = require("lib/core/Logger")
local Config = require("lib/core/Config")
local RaceContext = require("lib/core/RaceContext")
local personaLoader = require("lib/driver/persona_loader")
local TacticalTicker = require("lib/driver/TacticalTicker")
local BehaviorActuator = require("lib/driver/BehaviorActuator")
local MistakeEngine = require("lib/driver/MistakeEngine")
local LODScheduler = require("lib/driver/LODScheduler")
local rivalryMemory = require("lib/driver/rivalry_memory")
local watchdog = require("lib/driver/watchdog")
local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
local TelemetryBridge = require("lib/bridge/TelemetryBridge")
local DashboardUI = require("lib/ui/DashboardUI")

local _initialized = false
local _tacticalTimer = 0.0
local _strategyTimer = 0.0
local _flushTimer = 0.0
local _perfMs = 0.0
local _activeAiCount = 0

local function getCarDriverName(idx)
  if ac and ac.getDriverName then
    local n = ac.getDriverName(idx)
    if n and n ~= "" then return n end
  end
  local c = ac and ac.getCar and ac.getCar(idx)
  if c and c.driverName and c.driverName ~= "" then return c.driverName end
  return "AI #" .. (idx + 1)
end

local function getCarPositionScalar(i)
  local c = ac and ac.getCar and ac.getCar(i)
  if c and c.position then
    return c.position.x or 0.0, c.position.y or 0.0, c.position.z or 0.0
  end
  return 0.0, 0.0, 0.0
end

function script.init()
  Logger.init()
  Config.init("config/settings.json")
  watchdog.init()
  personaLoader.init("config/personas.json")
  rivalryMemory.init("rivalry_memory.jsonl")
  LODScheduler.reset()
  LODScheduler.setDeepSleepEnabled(true)
  MistakeEngine.reset()
  BehaviorActuator.reset()
  TacticalTicker.reset()
  StrategyCoordinator.init()
  TelemetryBridge.reset()

  local sim = ac and ac.getSim and ac.getSim()
  if sim then
    RaceContext.updateFromSim(sim)
    StrategyCoordinator.rebuildFieldStrategy(sim.raceLaps or 20, 1, 2.5)
  end

  _initialized = true
  Logger.info("LIFECYCLE", "[Ultimate AI Grand Prix Pro] Successfully initialized. Physics Allowed: " .. tostring(watchdog.isPhysicsAllowed()))
end

--- High-Frequency Physics Loop (simUpdate @ 60Hz)
--- STRICT PERFORMANCE BUDGET: < 0.1 ms per physics step.
function script.simUpdate(dt)
  if not _initialized then return end
  watchdog.stepPhysics(dt)
end

--- Frame Update & Decoupled Tactical / Strategy Pipeline
function script.update(dt)
  if not _initialized then return end
  local sim = ac and ac.getSim and ac.getSim()
  if not sim or sim.isReplayActive then return end

  _tacticalTimer = _tacticalTimer + dt
  _strategyTimer = _strategyTimer + dt
  _flushTimer = _flushTimer + dt

  -- 1. Periodic flush of rivalry incidents (every 5 seconds)
  if _flushTimer >= 5.0 then
    _flushTimer = 0.0
    rivalryMemory.flush()
  end

  -- 2. Strategy & Pit Wall Coordinator Tick (1Hz / 1.0s interval)
  if _strategyTimer >= 1.0 then
    local stratDt = _strategyTimer
    _strategyTimer = 0.0
    RaceContext.updateFromSim(sim)
    StrategyCoordinator.stepStrategy(stratDt)
  end

  -- 3. Tactical Driver Decision Tick @ 10Hz (0.1s interval)
  if _tacticalTimer >= 0.1 then
    local t0 = os.clock()
    local tacticalDt = _tacticalTimer
    _tacticalTimer = 0.0

    RaceContext.updateFromSim(sim)
    local carCount = math.min(64, sim.carsCount or 0)
    _activeAiCount = 0

    local playerCar = ac.getCar(0)
    local playerDriverName = getCarDriverName(0)

    -- Update Spatial 3-Tier Dynamic LOD based on player position
    local playerPos = playerCar and playerCar.position or nil
    LODScheduler.updateTiers(playerPos, carCount, getCarPositionScalar)

    for i = 0, carCount - 1 do
      local c = ac.getCar(i)
      if c and c.isAIControlled then
        _activeAiCount = _activeAiCount + 1
        RaceContext.updateCarFromAc(i, c)
        local cState = RaceContext.getCarState(i)
        cState.driverName = getCarDriverName(i)

        -- Anti-stuck watchdog
        watchdog.checkStuckCars(c, tacticalDt)

        -- Spatial LOD scheduling check
        local shouldTick, tier = LODScheduler.shouldTickCar(i)
        local persona = personaLoader.getPersonaForCar(i, cState.driverName)

        -- Standing start blunder & launch reaction handling on race green
        if sim.sessionTime and sim.sessionTime < 10.0 then
          local delay, blunder = MistakeEngine.evaluateStandingStart(i, persona, sim.sessionTime)
          if MistakeEngine.stepStandingStart(i, tacticalDt) then
            if physics.setAIThrottleLimit then
              physics.setAIThrottleLimit(i, 0.0)
            end
          end
        end

        if shouldTick then
          -- Collision detection & event wakeup trigger
          if playerCar and c.collisionDepth and c.collisionDepth > 0.02 and playerCar.position and c.position then
            local dx = c.position.x - playerCar.position.x
            local dy = c.position.y - playerCar.position.y
            local dz = c.position.z - playerCar.position.z
            local dPlayerSq = dx * dx + dy * dy + dz * dz
            if dPlayerSq < 16.0 then
              rivalryMemory.recordContact(cState.driverName, playerDriverName, 1.5, sim.currentLap or 1)
              LODScheduler.triggerWakeInterrupt(i)
            end
          end

          local rivalryGrievance = rivalryMemory.getGrievance(cState.driverName)

          -- Proximity tracking with playerCar
          local aheadCar = nil
          local behindCar = nil
          if playerCar and c.position and playerCar.position then
            local dx = c.position.x - playerCar.position.x
            local dy = c.position.y - playerCar.position.y
            local dz = c.position.z - playerCar.position.z
            local lenSq = dx * dx + dy * dy + dz * dz
            if lenSq < 1225.0 then -- < 35m
              local isBehind = false
              if c.look then
                local dot = dx * c.look.x + dy * c.look.y + dz * c.look.z
                isBehind = (dot < 0)
              else
                isBehind = (c.splinePosition > playerCar.splinePosition)
              end
              if isBehind then behindCar = playerCar
              else aheadCar = playerCar end
            end
          end

          -- Build Race Context
          local raceCtx = {
            isLastLap = (sim.raceLaps and sim.raceLaps > 0 and (sim.currentLap or 0) >= sim.raceLaps),
            tyreWear = cState.tyreWear,
            isBlueFlagged = false,
            radioCommand = cState.radioCommand,
          }
          if playerCar and sim.currentLap and c.lapCount then
            if (playerCar.lapCount or 0) > (c.lapCount or 0) and behindCar == playerCar then
              raceCtx.isBlueFlagged = true
            end
          end

          -- Execute 10Hz Tactical Tick
          local aiState = TacticalTicker.stepCar(c, aheadCar, behindCar, persona, rivalryGrievance, raceCtx, tacticalDt)

          -- Sync back to unified RaceContext
          cState.tacticalState = aiState.state
          cState.stress = aiState.stress
          cState.momentum = aiState.momentum
          cState.isLiftAndCoast = aiState.isLiftAndCoast
          cState.isBreakingTow = aiState.isBreakingTow

          -- Apply Behavior Actuators
          BehaviorActuator.applyActuator(c, aiState, tacticalDt)
        end
      end
    end

    -- Stamp telemetry packet for external ecosystem consumers
    TelemetryBridge.stampPacket(_activeAiCount, sim.sessionTime or 0.0)

    _perfMs = (os.clock() - t0) * 1000.0
  end
end

function script.windowMain(dt)
  if not _initialized then
    ui.text("Initializing Ultimate AI Grand Prix Pro...")
    return
  end
  DashboardUI.renderMain(_perfMs, _activeAiCount)
end

function script.windowSetup(dt)
  if not _initialized then return end
  DashboardUI.renderSetup()
end

function script.windowSettings(dt)
  if not _initialized then return end
  DashboardUI.renderGridSetupTab()
end
