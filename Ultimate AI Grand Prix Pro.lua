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
local EventHub = require("lib/core/EventHub")
local DashboardUI = require("lib/ui/DashboardUI")

local _initialized = false
local _initAttempted = false
local _tacticalTimer = 0.0
local _strategyTimer = 0.0
local _flushTimer = 0.0
local _perfMs = 0.0
local _activeAiCount = 0

local function safeGetCar(idx)
  if not ac or not ac.getCar or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getCar, idx)
  if ok and res then return res end
  return nil
end

local function safeGetDriverName(idx)
  if not ac or not ac.getDriverName or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getDriverName, idx)
  if ok and res and res ~= "" then return res end
  return nil
end

local function getCarDriverName(idx)
  local n = safeGetDriverName(idx)
  if n and n ~= "" then return n end
  local c = safeGetCar(idx)
  if c and c.driverName and c.driverName ~= "" then return c.driverName end
  return (idx == 0) and "Player" or string.format("Driver #%02d", idx + 1)
end

local function getCarPositionScalar(i)
  local c = safeGetCar(i)
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
  EventHub.init()

  local sim = nil
  if ac and ac.getSim then
    local okSim, res = pcall(ac.getSim)
    if okSim and res then sim = res end
  end

  if sim then
    pcall(RaceContext.updateFromSim, sim)
    local rState = RaceContext.getRaceState()
    local laps = (rState and rState.totalLaps and rState.totalLaps > 0) and rState.totalLaps or 13
    pcall(StrategyCoordinator.rebuildFieldStrategy, laps, 1, 2.5)
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
  if not sim or RaceContext.safeSimGet(sim, "isReplayActive") then return end

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
    local rState = RaceContext.getRaceState()
    EventHub.tickHeartbeat(rState.sessionTime or 0.0, _activeAiCount + 1, rState.currentLap or 1, rState.totalLaps or 13)
  end

  -- 3. Tactical Driver Decision Tick @ 10Hz (0.1s interval)
  if _tacticalTimer >= 0.1 then
    local t0 = os.clock()
    local tacticalDt = _tacticalTimer
    _tacticalTimer = 0.0

    RaceContext.updateFromSim(sim)
    local raceState = RaceContext.getRaceState()
    local carCount = raceState.carsCount or 0
    if carCount > 24 then carCount = 24 end
    if carCount < 1 then carCount = 1 end
    _activeAiCount = 0

    local playerCar = safeGetCar(0)
    local playerDriverName = getCarDriverName(0)

    -- Update Spatial 3-Tier Dynamic LOD based on player position
    local playerPos = playerCar and playerCar.position or nil
    LODScheduler.updateTiers(playerPos, carCount, getCarPositionScalar)

    -- Update Global 24-Car Topological Neighbor Ring (AI-to-AI Inter-Vehicle Awareness)
    RaceContext.updateTopology(carCount, safeGetCar)

    for i = 0, carCount - 1 do
      local c = safeGetCar(i)
      if c then
        RaceContext.updateCarFromAc(i, c)
        local cState = RaceContext.getCarState(i)
        cState.driverName = getCarDriverName(i)
      end
      local isCarAI = (c ~= nil) and ((c.isAIControlled == true) or (i > 0 and not c.isPlayer))
      if isCarAI then
        _activeAiCount = _activeAiCount + 1
        local cState = RaceContext.getCarState(i)
        cState.isAIControlled = true


        -- Cold tyre warmup progression on out-lap
        if cState.tyreWarmupProgress and cState.tyreWarmupProgress < 1.0 then
          cState.tyreWarmupProgress = math.min(1.0, cState.tyreWarmupProgress + tacticalDt * 0.05) -- takes ~20s to warm up
        end

        -- Anti-stuck watchdog (gated during race start / grid formation)
        watchdog.checkStuckCars(c, tacticalDt, raceState.sessionTime)

        -- Spatial LOD scheduling check
        local shouldTick, tier = LODScheduler.shouldTickCar(i)
        local persona = personaLoader.getPersonaForCar(i, cState.driverName)

        -- Standing start launch simulation (reaction delays and start blunder states recorded without locking physical throttle)
        if raceState.sessionTime and raceState.sessionTime < 10.0 then
          MistakeEngine.evaluateStandingStart(i, persona, raceState.sessionTime)
          MistakeEngine.stepStandingStart(i, tacticalDt)
        end

        if shouldTick then
          -- Collision detection & event wakeup trigger
          if playerCar and c.collisionDepth and c.collisionDepth > 0.02 and playerCar.position and c.position then
            local dx = c.position.x - playerCar.position.x
            local dy = c.position.y - playerCar.position.y
            local dz = c.position.z - playerCar.position.z
            local dPlayerSq = dx * dx + dy * dy + dz * dz
            if dPlayerSq < 16.0 then
              rivalryMemory.recordContact(cState.driverName, playerDriverName, 1.5, raceState.currentLap or 1)
              LODScheduler.triggerWakeInterrupt(i)
            end
          end

          local rivalryGrievance = rivalryMemory.getGrievance(cState.driverName)

          -- Topological proximity tracking across all 24 cars (AI-to-AI and AI-to-Player)
          local aheadCar = nil
          local behindCar = nil
          local aheadIdx, aheadDist, behindIdx, behindDist = RaceContext.getNeighbors(i)

          if aheadIdx >= 0 and aheadDist < 35.0 then
            aheadCar = safeGetCar(aheadIdx)
          end
          if behindIdx >= 0 and behindDist < 35.0 then
            behindCar = safeGetCar(behindIdx)
          end

          -- Build Race Context
          local raceCtx = {
            isLastLap = (raceState.totalLaps and raceState.totalLaps > 0 and (raceState.currentLap or 0) >= raceState.totalLaps),
            tyreWear = cState.tyreWear,
            isBlueFlagged = false,
            radioCommand = cState.radioCommand,
            tyreWarmupProgress = cState.tyreWarmupProgress or 1.0,
            tyreTempNorm = cState.tyreTempNorm or 1.0,
          }
          if playerCar and c.lapCount then
            local pLap = playerCar.lapCount or 0
            local cLap = c.lapCount or 0
            if pLap > cLap and behindCar == playerCar and behindDist < 25.0 then
              raceCtx.isBlueFlagged = true
            end
          end
          if raceState.blueFlagCarIdx and raceState.blueFlagCarIdx == i then
            raceCtx.isBlueFlagged = true
          end

          -- Execute 10Hz Tactical Tick
          local aiState = TacticalTicker.stepCar(c, aheadCar, behindCar, persona, rivalryGrievance, raceCtx, tacticalDt)

          -- Pass cold tyre warmup factor to aiState for actuator grip adjustment
          if cState.tyreWarmupProgress and cState.tyreWarmupProgress < 1.0 then
            -- Cold tyres start at 0.92 grip and ramp to 1.0
            aiState.outLapColdGrip = 0.92 + (0.08 * cState.tyreWarmupProgress)
          else
            aiState.outLapColdGrip = 1.0
          end

          -- Sync back to unified RaceContext
          local prevState = cState.tacticalState
          cState.tacticalState = aiState.state
          cState.activeSkill = aiState.activeSkill or "NONE"
          cState.stress = aiState.stress
          cState.momentum = aiState.momentum
          cState.isLiftAndCoast = aiState.isLiftAndCoast
          cState.isBreakingTow = aiState.isBreakingTow

          -- Emit tactical behavior events if state transitioned or skill activated
          if cState.tacticalState ~= prevState or (cState.activeSkill ~= "NONE" and cState.activeSkill ~= prevState) then
            EventHub.emitTacticalStateChange(i, cState.driverName, cState.tacticalState, prevState, cState.activeSkill, raceState.sessionTime or 0.0)
          end

          -- Apply Behavior Actuators
          BehaviorActuator.applyActuator(c, aiState, tacticalDt)
        end
      end
    end

    -- Stamp telemetry packet for external ecosystem consumers
    TelemetryBridge.stampPacket(_activeAiCount, raceState.sessionTime or 0.0)

    _perfMs = (os.clock() - t0) * 1000.0
  end
end

local function ensureInitialized()
  if _initialized then return true end
  if _initAttempted then return false end
  _initAttempted = true

  if script.init then
    local ok, err = pcall(script.init)
    if not ok then
      _initialized = true -- Prevent recursive crash looping
      Logger.error("LIFECYCLE", "Initialization error: " .. tostring(err))
      return false
    end
  end
  return _initialized
end

local _lastWindowTick = 0.0

function windowMain(dt)
  ensureInitialized()
  local now = os.clock()
  local stepDt = (dt and dt > 0) and dt or ((_lastWindowTick > 0) and (now - _lastWindowTick) or 0.016)
  _lastWindowTick = now
  if stepDt > 0.1 then stepDt = 0.1 end

  -- Self-driving pump: guarantees update loops step even if CSP lazily throttles script.update
  if script.update then
    pcall(script.update, stepDt)
  end

  local ok, err = pcall(DashboardUI.renderMain, _perfMs, _activeAiCount)
  if not ok then
    if ui and ui.text then
      ui.text("Grand Prix Pro UI Render Error: " .. tostring(err))
    end
  end
end

function windowSetup(dt)
  ensureInitialized()
  local now = os.clock()
  local stepDt = (dt and dt > 0) and dt or ((_lastWindowTick > 0) and (now - _lastWindowTick) or 0.016)
  _lastWindowTick = now
  if stepDt > 0.1 then stepDt = 0.1 end

  if script.update then
    pcall(script.update, stepDt)
  end

  local ok, err = pcall(DashboardUI.renderSetup)
  if not ok and ui and ui.text then
    ui.text("Setup UI Error: " .. tostring(err))
  end
end

function windowSettings(dt)
  ensureInitialized()
  local ok, err = pcall(DashboardUI.renderGridSetupTab)
  if not ok and ui and ui.text then
    ui.text("Settings UI Error: " .. tostring(err))
  end
end

script.windowMain = windowMain
script.windowSetup = windowSetup
script.windowSettings = windowSettings


