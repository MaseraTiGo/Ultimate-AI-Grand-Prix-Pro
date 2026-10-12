--[[
  lib/ui/DashboardUI.lua
  Ultimate AI Grand Prix Pro - Unified ImGui Pit Wall & Live HUD
  
  Tabs:
    1. [LIVE HUD] AI & Player Real-time Telemetry, Motion Matrix (Stress, Flow/Tilt, Tactical State, LOD, Skills)
    2. [PIT WALL] Strategic Timeline, Pit Windows, Fuel Projections & Radio Orders (Push/Save/Box/Defend)
    3. [SETUP] Strategy Workshop & Stint Planner (Stint Splits, Compound Selection, Fuel Delta)
    4. [GRID SETUP] Driver Persona 7D DNA & Field Manual Override Matrix
    5. [LOGS] Bounded Ring Buffer Event Diagnostics
]]

local RaceContext = require("lib/core/RaceContext")
local Logger = require("lib/core/Logger")
local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
local personaLoader = require("lib/driver/persona_loader")
local LODScheduler = require("lib/driver/LODScheduler")
local watchdog = require("lib/driver/watchdog")
local TelemetryBridge = require("lib/bridge/TelemetryBridge")
local strategyCalc = require("lib/strategy/strategy_calculator")

local M = {}



local _selectedTab = 1
local _selectedCarForRadio = 1
local _availablePersonas = { "aggressive_bull", "tactical_master", "ice_man", "gentleman_driver", "balanced" }

-- Setup panel working state
local _setupTargetLaps = 20
local _setupStops = 1
local _setupBaseFpl = 2.5
local _setupCompound = "MEDIUM"

function M.renderMain(perfMs, activeAiCount)
  if not ui or not ui.text then return end

  -- Header Banner
  ui.text("ULTIMATE AI GRAND PRIX PRO")
  ui.sameLine()
  ui.text(string.format("| 10Hz/60Hz Core (%.2f ms)", perfMs or 0.0))

  -- Core Watchdog & Session Status
  local race = RaceContext.getRaceState()
  local isPhysOn = watchdog.isPhysicsAllowed()
  local physColor = isPhysOn and COLOR_GREEN or COLOR_WARN
  local physText = isPhysOn and "[PHYSICS: ACTIVE]" or "[MONITOR ONLY]"

  ui.text(physText)
  ui.sameLine()
  ui.text("|")
  ui.sameLine()
  local flagColor = (race.flagState == "GREEN") and COLOR_GREEN or COLOR_WARN
  ui.text(string.format("Lap: %d/%d", race.currentLap or 1, race.totalLaps or 20))
  ui.sameLine()
  ui.text(string.format("[%s]", race.flagState or "PRACTICE"))
  ui.sameLine()
  ui.text("|")
  ui.sameLine()
  ui.text(string.format("Grid: %d (AI: %d)", race.carsCount or 0, activeAiCount or 0))

  ui.separator()

  -- Navigation Tabs
  if ui.button(_selectedTab == 1 and "[ 1. LIVE HUD ]" or " 1. LIVE HUD ") then _selectedTab = 1 end
  ui.sameLine()
  if ui.button(_selectedTab == 2 and "[ 2. PIT WALL ]" or " 2. PIT WALL ") then _selectedTab = 2 end
  ui.sameLine()
  if ui.button(_selectedTab == 3 and "[ 3. STRATEGY ]" or " 3. STRATEGY ") then _selectedTab = 3 end
  ui.sameLine()
  if ui.button(_selectedTab == 4 and "[ 4. GRID SETUP ]" or " 4. GRID SETUP ") then _selectedTab = 4 end
  ui.sameLine()
  if ui.button(_selectedTab == 5 and "[ 5. LOGS ]" or " 5. LOGS ") then _selectedTab = 5 end

  ui.separator()

  if _selectedTab == 1 then
    M.renderLiveHudTab()
  elseif _selectedTab == 2 then
    M.renderPitWallTab()
  elseif _selectedTab == 3 then
    M.renderSetup()
  elseif _selectedTab == 4 then
    M.renderGridSetupTab()
  elseif _selectedTab == 5 then
    M.renderLogsTab()
  end
end

function M.renderLiveHudTab()
  ui.text("=== LIVE TELEMETRY & TACTICAL MOTION MATRIX ===")

  local carStates = RaceContext.getAllCarStates()
  local race = RaceContext.getRaceState()
  local carsCount = race.carsCount or 0

  -- 1. Player Telemetry Section (Car #0)
  local playerState = carStates[0]
  local pSpeed = 0.0
  local pGear = 0
  local pRpm = 0
  if ac and ac.getCar then
    local pCar = ac.getCar(0)
    if pCar then
      pSpeed = pCar.speedKmh or 0.0
      pGear = pCar.gear or 0
      pRpm = pCar.rpm or 0
    end
  end

  local pFuel = (playerState and playerState.fuelInTank) or 0.0
  local pWear = (playerState and playerState.tyreWear) or 0.0
  local pGearStr = (pGear == 0) and "N" or ((pGear < 0) and "R" or tostring(pGear))

  ui.text(string.format("PLAYER [CAR #00]:  Speed: %.1f km/h | Gear: %s | RPM: %d", pSpeed, pGearStr, math.floor(pRpm)))
  ui.text(string.format("  Fuel: %.1f L | Tyre Wear: %.1f%% | Watchdog: %s",
    pFuel, pWear * 100.0, watchdog.isPhysicsAllowed() and "ONLINE" or "PASSIVE"))
  
  ui.separator()

  -- 2. AI Grid Telemetry Matrix
  ui.text("CAR #   DRIVER       TIER   STATE         STRESS   MOMENTUM   SKILL / RADIO")

  local aiCarsFound = 0
  for i = 1, math.min(23, carsCount > 0 and (carsCount - 1) or 0) do
    local c = carStates[i]
    if c and c.isConnected and c.isAIControlled then
      aiCarsFound = aiCarsFound + 1
      local tier = LODScheduler.getCarTier(i)
      local tierStr = (tier == 1) and "T1" or ((tier == 2) and "T2" or "T3")
      local telem = TelemetryBridge.getCarTelemetry(i)

      local stColor = COLOR_GREEN
      if c.tacticalState == "ATTACK" or c.tacticalState == "LATE_BRAKE_DIVE" or c.tacticalState == "FEINT_DUMMY" or c.tacticalState == "SWITCHBACK" then
        stColor = COLOR_WARN
      elseif c.tacticalState == "DEFEND" or c.tacticalState == "GENTLE_SQUEEZE" or c.tacticalState == "TOW_WEAVE" then
        stColor = COLOR_INFO
      elseif c.tacticalState == "MISTAKE" then
        stColor = COLOR_DANGER
      elseif c.tacticalState == "YIELD" then
        stColor = COLOR_MUTED
      end

      local rawName = (c.driverName and c.driverName ~= "") and c.driverName or ("AI #" .. (i + 1))
      local dName = rawName:sub(1, 10)

      ui.text(string.format("#%02d    %-10s   [%s]  ", i + 1, dName, tierStr))
      ui.sameLine()
      ui.text(string.format("%-12s", "[" .. (c.tacticalState or "CRUISE") .. "]"))
      ui.sameLine()
      ui.text(string.format("%.2f    %+0.2f     ", telem.stress or 0.0, telem.momentum or 0.0))

      if c.activeSkill and c.activeSkill ~= "NONE" then
        ui.sameLine()
        ui.text(string.format("[%s]", c.activeSkill))
      elseif c.radioCommand and c.radioCommand ~= "NONE" then
        ui.sameLine()
        ui.text(string.format("RAD:%s", c.radioCommand))
      elseif telem.lift_and_coast == 1 then
        ui.sameLine()
        ui.text("[COAST]")
      elseif telem.breaking_tow == 1 then
        ui.sameLine()
        ui.text("[WEAVE]")
      else
        ui.sameLine()
        ui.text("NOMINAL")
      end
    end
  end

  if aiCarsFound == 0 then
    ui.text("[SOLO / PRACTICE MODE] No AI opponents actively spawned on track.")
    ui.text("All 24 AI brain workers & 60Hz physics watchdog are primed in standby.")
    ui.text("Start a Quick Race or Weekend session with AI to engage full real-time combat.")
  end
end

function M.renderPitWallTab()
  ui.text("=== PIT WALL STRATEGY & RADIO DISPATCH ===")
  local carStates = RaceContext.getAllCarStates()
  local race = RaceContext.getRaceState()
  local carsCount = race.carsCount or 0
  local maxCar = math.max(1, carsCount > 1 and (carsCount - 1) or 1)

  -- Radio Control Console
  ui.text(string.format("Radio Target: Car #%02d", _selectedCarForRadio + 1))
  ui.sameLine()
  if ui.button("Cycle Car##radio") then
    _selectedCarForRadio = (_selectedCarForRadio % maxCar) + 1
  end

  ui.sameLine()
  if ui.button("PUSH##radio") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "PUSH")
  end
  ui.sameLine()
  if ui.button("SAVE##radio") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "SAVE")
  end
  ui.sameLine()
  if ui.button("BOX##radio") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "BOX_THIS_LAP")
  end
  ui.sameLine()
  if ui.button("CLEAR##radio") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "NONE")
  end

  ui.separator()

  -- Pit Strategy Live Roster Table
  ui.text("CAR #   DRIVER       FUEL/FPL     EST.LAPS   PIT WINDOW   RECOMMENDATION")

  local aiCarsFound = 0
  for i = 1, math.min(23, carsCount > 0 and (carsCount - 1) or 0) do
    local c = carStates[i]
    if c and c.isConnected and c.isAIControlled then
      aiCarsFound = aiCarsFound + 1
      local plan = StrategyCoordinator.getCarPlan(i)
      local fuel = c.fuelInTank or 0.0
      local fpl = plan.dynamicFpl or 2.5
      local estLaps = (fpl > 0) and math.floor(fuel / fpl) or 0
      local rawName = (c.driverName and c.driverName ~= "") and c.driverName or ("AI #" .. (i + 1))
      local dName = rawName:sub(1, 10)

      ui.text(string.format("#%02d    %-10s   %4.1fL(%.2f)   ~%2dL laps   L%02d-L%02d     ",
        i + 1, dName, fuel, fpl, estLaps, plan.openLap or 0, plan.escalateLap or 0))
      ui.sameLine()
      if plan.activeRecommendation == "BOX_THIS_LAP" or c.radioCommand == "BOX_THIS_LAP" then
        ui.text("[BOX THIS LAP]")
      else
        ui.text("[STAY OUT]")
      end
    end
  end

  if aiCarsFound == 0 then
    -- Show sample plan for Player car / Standby preview
    local playerPlan = StrategyCoordinator.getCarPlan(0)
    local pState = carStates[0]
    local pFuel = pState and pState.fuelInTank or 30.0
    local pFpl = playerPlan.dynamicFpl or 2.5
    local pEstLaps = (pFpl > 0) and math.floor(pFuel / pFpl) or 0
    ui.text(string.format("#00    PLAYER       %4.1fL(%.2f)   ~%2dL laps   L%02d-L%02d     ",
      pFuel, pFpl, pEstLaps, playerPlan.openLap or 0, playerPlan.escalateLap or 0))
    ui.sameLine()
    ui.text("[STAY OUT]")
    ui.text("Pit Wall is monitoring session parameters. AI grid plans will appear in multi-car races.")
  end
end

function M.renderSetup()
  ui.text("=== GRAND PRIX PRO - STRATEGY SETUP WORKSHOP ===")
  ui.separator()

  local race = RaceContext.getRaceState()
  local totalLaps = race.totalLaps or _setupTargetLaps or 20

  ui.text("1. SESSION PARAMETERS:")
  ui.text(string.format("  Total Race Laps: %d  |  Estimated FPL: %.2f L/lap", totalLaps, _setupBaseFpl))
  
  if ui.button("Laps -5##setup") then
    _setupTargetLaps = math.max(5, totalLaps - 5)
    StrategyCoordinator.rebuildFieldStrategy(_setupTargetLaps, _setupStops, _setupBaseFpl)
  end
  ui.sameLine()
  if ui.button("Laps +5##setup") then
    _setupTargetLaps = math.min(100, totalLaps + 5)
    StrategyCoordinator.rebuildFieldStrategy(_setupTargetLaps, _setupStops, _setupBaseFpl)
  end
  ui.sameLine()
  if ui.button("FPL: 2.2L##setup") then
    _setupBaseFpl = 2.2
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end
  ui.sameLine()
  if ui.button("FPL: 2.8L##setup") then
    _setupBaseFpl = 2.8
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end

  ui.separator()

  ui.text("2. TARGET PIT STOP STRATEGY:")
  if ui.button(_setupStops == 0 and "[ 0-STOP (Sprint) ]" or "  0-STOP (Sprint)  ") then
    _setupStops = 0
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, 0, _setupBaseFpl)
  end
  ui.sameLine()
  if ui.button(_setupStops == 1 and "[ 1-STOP (Optimal) ]" or "  1-STOP (Optimal)  ") then
    _setupStops = 1
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, 1, _setupBaseFpl)
  end
  ui.sameLine()
  if ui.button(_setupStops == 2 and "[ 2-STOP (Attack) ]" or "  2-STOP (Attack)  ") then
    _setupStops = 2
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, 2, _setupBaseFpl)
  end

  ui.separator()

  ui.text("3. STINT BREAKDOWN & TYRE WINDOWS:")
  local stintCount = strategyCalc.computeStintCount(_setupStops, totalLaps)
  local splits = strategyCalc.splitTotalLapsAcrossStints(totalLaps, stintCount)
  local startFuel = totalLaps * _setupBaseFpl
  local safeFuel = startFuel + (_setupBaseFpl * 0.8) + 1.0

  local curLapAcc = 0
  for s = 1, #splits do
    local laps = splits[s]
    local startL = curLapAcc + 1
    local endL = curLapAcc + laps
    curLapAcc = endL
    local stintFuel = laps * _setupBaseFpl
    local isFinal = (s == #splits)
    local win = strategyCalc.computePitWindowForStint(s, startL, endL, laps, totalLaps)
    
    ui.text(string.format("  Stint %d: Laps %d -> %d (%d Laps) | Fuel: ~%.1f L", s, startL, endL, laps, stintFuel))
    if not isFinal then
      ui.text(string.format("    -> Pit Window: Open L%d | Target L%d | Escalate L%d", win.openLap, win.targetLap, win.escalateLap))
    else
      ui.text("    -> Final Stint to Chequered Flag")
    end
  end

  ui.separator()

  ui.text("4. FUEL CALCULATION CARD:")
  ui.text(string.format("  Total Race Fuel Needed: %.1f L (Safe with Reserve: %.1f L)", startFuel, safeFuel))
  ui.text(string.format("  Fuel Save Target: %.2f L/lap  |  Push Target: %.2f L/lap", _setupBaseFpl * 0.94, _setupBaseFpl * 1.05))

  ui.separator()

  if ui.button("APPLY STRATEGY TO ENTIRE FIELD") then
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
    Logger.info("SETUP", string.format("Applied field strategy: %d Laps, %d Stops, %.2f FPL", totalLaps, _setupStops, _setupBaseFpl))
  end
end

function M.renderGridSetupTab()
  ui.text("=== GRID PERSONA & 7D DNA CONFIGURATION ===")
  local race = RaceContext.getRaceState()
  local carsCount = race.carsCount or 0

  local aiCarsFound = 0
  for i = 1, math.min(23, carsCount > 0 and (carsCount - 1) or 0) do
    local c = RaceContext.getCarState(i)
    if c and c.isConnected and c.isAIControlled then
      aiCarsFound = aiCarsFound + 1
      local rawName = (c.driverName and c.driverName ~= "") and c.driverName or ("AI #" .. (i + 1))
      local dName = rawName:sub(1, 10)
      local curOverride = personaLoader.getManualOverride(i)
      local persona = personaLoader.getPersonaForCar(i, rawName)

      ui.text(string.format("#%02d %-10s: [%s]", i + 1, dName, persona.name or "Default"))
      ui.sameLine()
      if ui.button(string.format("Cycle##persona_%d", i)) then
        local nextIdx = 1
        for idx, key in ipairs(_availablePersonas) do
          if curOverride == key then
            nextIdx = (idx % #_availablePersonas) + 1
            break
          end
        end
        personaLoader.setManualOverride(i, _availablePersonas[nextIdx])
      end
    end
  end

  if aiCarsFound == 0 then
    ui.text("No AI cars detected on grid to override.")
    ui.text("Available Presets: aggressive_bull, tactical_master, ice_man, gentleman_driver, balanced")
  end
end

function M.renderLogsTab()
  ui.text("=== SYSTEM DIAGNOSTIC EVENT LOG STREAM ===")
  local logs = Logger.getRecentLogs()
  if #logs == 0 then
    ui.text("No logs recorded yet.")
    return
  end
  for i = #logs, math.max(1, #logs - 15), -1 do
    local l = logs[i]
    if l then
      local c = COLOR_TEXT
      if l.level == Logger.LEVEL_WARN then c = COLOR_WARN
      elseif l.level == Logger.LEVEL_ERROR then c = COLOR_DANGER end
      ui.text(string.format("[%s][%s] %s", l.timeStr, l.tag, l.message))
    end
  end
end

return M
