--[[
  lib/ui/DashboardUI.lua
  Ultimate AI Grand Prix Pro - Unified ImGui Pit Wall & Live HUD
  
  Tabs:
    1. [LIVE HUD] AI Cars Psychological & Physical Grid Matrix (Stress, Flow/Tilt, Tactical State, LOD, Skills)
    2. [PIT WALL] Strategic Timeline, Pit Windows, Fuel Projections & Radio Orders (Push/Save/Box/Defend)
    3. [SETUP] Field Persona Override & Stint Parameter Controls
    4. [LOGS] Bounded Diagnostic Stream
]]

local RaceContext = require("lib/core/RaceContext")
local Logger = require("lib/core/Logger")
local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
local personaLoader = require("lib/driver/persona_loader")
local LODScheduler = require("lib/driver/LODScheduler")
local watchdog = require("lib/driver/watchdog")
local TelemetryBridge = require("lib/bridge/TelemetryBridge")

local M = {}

local function makeRgbm(r, g, b, a)
  if _G.rgbm then return _G.rgbm(r, g, b, a) end
  return { r = r, g = g, b = b, a = a }
end

local COLOR_TITLE  = makeRgbm(1.0, 0.35, 0.15, 1.0)
local COLOR_TEXT   = makeRgbm(0.92, 0.92, 0.92, 1.0)
local COLOR_MUTED  = makeRgbm(0.60, 0.65, 0.70, 1.0)
local COLOR_GREEN  = makeRgbm(0.20, 0.85, 0.35, 1.0)
local COLOR_WARN   = makeRgbm(1.00, 0.65, 0.10, 1.0)
local COLOR_DANGER = makeRgbm(1.00, 0.25, 0.25, 1.0)
local COLOR_INFO   = makeRgbm(0.25, 0.65, 1.00, 1.0)
local COLOR_PURPLE = makeRgbm(0.80, 0.45, 1.00, 1.0)

local _selectedTab = 1
local _selectedCarForRadio = 1
local _availablePersonas = { "aggressive_bull", "tactical_master", "ice_man", "gentleman_driver", "balanced" }

function M.renderMain(perfMs, activeAiCount)
  if not ui or not ui.text then return end

  -- Safe padding wrapper (does not throw if vec2 or WindowPadding is missing)
  local pushedStyle = false
  if ui.pushStyleVar and ui.StyleVar and ui.StyleVar.WindowPadding and _G.vec2 then
    pcall(function()
      ui.pushStyleVar(ui.StyleVar.WindowPadding, vec2(8, 8))
      pushedStyle = true
    end)
  end

  -- Header Banner
  ui.textColored(COLOR_TITLE, "ULTIMATE AI GRAND PRIX PRO")
  ui.sameLine()
  ui.textColored(COLOR_MUTED, string.format("| 10Hz/60Hz Core (%.2f ms)", perfMs or 0.0))

  -- Core Watchdog & Session Status
  local race = RaceContext.getRaceState()
  local isPhysOn = watchdog.isPhysicsAllowed()
  local physColor = isPhysOn and COLOR_GREEN or COLOR_WARN
  local physText = isPhysOn and "[PHYSICS: ACTIVE]" or "[MONITOR ONLY]"

  ui.textColored(physColor, physText)
  ui.sameLine()
  ui.textColored(COLOR_MUTED, "|")
  ui.sameLine()
  local flagColor = (race.flagState == "GREEN") and COLOR_GREEN or COLOR_WARN
  ui.text(string.format("Lap: %d/%d", race.currentLap or 1, race.totalLaps or 20))
  ui.sameLine()
  ui.textColored(flagColor, string.format("[%s]", race.flagState or "PRACTICE"))
  ui.sameLine()
  ui.textColored(COLOR_MUTED, "|")
  ui.sameLine()
  ui.text(string.format("Grid: %d (AI: %d)", race.carsCount or 0, activeAiCount or 0))

  ui.separator()

  -- Navigation Tabs
  if ui.button(_selectedTab == 1 and "[ 1. LIVE HUD ]" or " 1. LIVE HUD ") then _selectedTab = 1 end
  ui.sameLine()
  if ui.button(_selectedTab == 2 and "[ 2. PIT WALL ]" or " 2. PIT WALL ") then _selectedTab = 2 end
  ui.sameLine()
  if ui.button(_selectedTab == 3 and "[ 3. GRID SETUP ]" or " 3. GRID SETUP ") then _selectedTab = 3 end
  ui.sameLine()
  if ui.button(_selectedTab == 4 and "[ 4. LOGS ]" or " 4. LOGS ") then _selectedTab = 4 end

  ui.separator()

  if _selectedTab == 1 then
    M.renderLiveHudTab()
  elseif _selectedTab == 2 then
    M.renderPitWallTab()
  elseif _selectedTab == 3 then
    M.renderGridSetupTab()
  elseif _selectedTab == 4 then
    M.renderLogsTab()
  end

  if pushedStyle and ui.popStyleVar then
    pcall(ui.popStyleVar, 1)
  end
end

function M.renderLiveHudTab()
  ui.textColored(COLOR_INFO, "AI DRIVER REAL-TIME PSYCHOLOGY & MOTION MATRIX:")

  local carStates = RaceContext.getAllCarStates()
  local race = RaceContext.getRaceState()
  local carsCount = race.carsCount or 0

  -- Count actual active AI cars
  local aiCarsFound = 0
  for i = 1, math.min(23, carsCount > 0 and (carsCount - 1) or 0) do
    local c = carStates[i]
    if c and c.isConnected and c.isAIControlled then
      aiCarsFound = aiCarsFound + 1
    end
  end

  -- If in solo session or AI cars haven't connected yet, show informative diagnostic fallback card
  if aiCarsFound == 0 then
    ui.textColored(COLOR_WARN, "Waiting for AI grid / Solo Practice Session Active")
    ui.textColored(COLOR_MUTED, "No AI-controlled opponents detected on current track session.")
    ui.textColored(COLOR_TEXT, "- If in a Race/Track Day: AI telemetry will populate automatically once cars leave pit.")
    ui.textColored(COLOR_TEXT, "- 60Hz Physics Watchdog & 10Hz Decision Engine: RUNNING NORMALLY.")
    ui.separator()
    -- Render Player Car Telemetry
    local playerState = carStates[0]
    if playerState and playerState.isConnected then
      ui.textColored(COLOR_TITLE, "PLAYER CAR (CAR #00):")
      local speedKmh = 0.0
      if ac and ac.getCar then
        local pCar = ac.getCar(0)
        if pCar and pCar.speedKmh then speedKmh = pCar.speedKmh end
      end
      ui.text(string.format("Speed: %.1f km/h | Fuel: %.1f L | Tyre Wear: %.1f%%",
        speedKmh, playerState.fuelInTank or 0.0, (playerState.tyreWear or 1.0) * 100.0))
    end
    return
  end

  -- Render full AI grid matrix (up to 24 cars)
  for i = 1, math.min(23, carsCount - 1) do
    local c = carStates[i]
    if c and c.isConnected and c.isAIControlled then
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

      ui.text(string.format("#%02d %-10s [%s]", i + 1, dName, tierStr))
      ui.sameLine()
      ui.textColored(stColor, string.format("[%s]", c.tacticalState or "CRUISE"))
      ui.sameLine()
      ui.text(string.format("Str:%.1f | Mom:%+.2f", telem.stress or 0.0, telem.momentum or 0.0))

      if c.activeSkill and c.activeSkill ~= "NONE" then
        ui.sameLine()
        ui.textColored(COLOR_PURPLE, string.format("[%s]", c.activeSkill))
      end

      if telem.lift_and_coast == 1 then
        ui.sameLine()
        ui.textColored(COLOR_INFO, "[COAST]")
      end
      if telem.breaking_tow == 1 then
        ui.sameLine()
        ui.textColored(COLOR_WARN, "[WEAVE]")
      end
      if c.radioCommand and c.radioCommand ~= "NONE" then
        ui.sameLine()
        ui.textColored(COLOR_TITLE, string.format("CMD:%s", c.radioCommand))
      end
    end
  end
end

function M.renderPitWallTab()
  ui.textColored(COLOR_WARN, "PIT WALL STRATEGY & RADIO DISPATCH:")
  local carStates = RaceContext.getAllCarStates()
  local race = RaceContext.getRaceState()
  local carsCount = race.carsCount or 0
  local maxCar = math.max(1, carsCount > 1 and (carsCount - 1) or 1)

  -- Radio control buttons for selected car
  ui.text(string.format("Target: Car #%02d", _selectedCarForRadio + 1))
  ui.sameLine()
  if ui.button("Next Car##radio") then
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

      ui.text(string.format("#%02d %-10s | Fuel: %.1fL (~%dL) | Window: L%d-L%d",
        i + 1, dName, fuel, estLaps, plan.openLap or 0, plan.escalateLap or 0))
      ui.sameLine()
      if plan.activeRecommendation == "BOX_THIS_LAP" then
        ui.textColored(COLOR_DANGER, "[BOX IN]")
      else
        ui.textColored(COLOR_GREEN, "[STAY OUT]")
      end
    end
  end

  if aiCarsFound == 0 then
    ui.textColored(COLOR_MUTED, "No AI cars currently active on Pit Wall feed.")
  end
end

function M.renderGridSetupTab()
  ui.textColored(COLOR_TITLE, "GRID PERSONA & STINT CONFIGURATION:")
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
    ui.textColored(COLOR_MUTED, "No AI cars on grid to configure.")
  end
end

function M.renderLogsTab()
  ui.textColored(COLOR_INFO, "DIAGNOSTIC EVENT LOG STREAM:")
  local logs = Logger.getRecentLogs()
  if #logs == 0 then
    ui.textColored(COLOR_MUTED, "No logs recorded yet.")
    return
  end
  for i = #logs, math.max(1, #logs - 15), -1 do
    local l = logs[i]
    if l then
      local c = COLOR_TEXT
      if l.level == Logger.LEVEL_WARN then c = COLOR_WARN
      elseif l.level == Logger.LEVEL_ERROR then c = COLOR_DANGER end
      ui.textColored(c, string.format("[%s][%s] %s", l.timeStr, l.tag, l.message))
    end
  end
end

function M.renderSetup()
  ui.textColored(COLOR_TITLE, "Grand Prix Pro - Strategy Setup Panel")
  ui.separator()
  local race = RaceContext.getRaceState()
  ui.text(string.format("Current Race Laps: %d", race.totalLaps or 20))
  if ui.button("Plan 1-Stop Strategy") then
    StrategyCoordinator.rebuildFieldStrategy(race.totalLaps or 20, 1, 2.5)
  end
  ui.sameLine()
  if ui.button("Plan 2-Stop Strategy") then
    StrategyCoordinator.rebuildFieldStrategy(race.totalLaps or 20, 2, 2.5)
  end
end

return M
