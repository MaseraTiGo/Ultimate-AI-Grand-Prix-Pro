--[[
  lib/ui/DashboardUI.lua
  Ultimate AI Grand Prix Pro - Unified ImGui Pit Wall & Live HUD
  
  Tabs:
    1. [LIVE HUD] AI & Player Real-time Telemetry, Motion Matrix (Stress, Flow/Tilt, Tactical State, LOD, Skills)
    2. [PIT WALL] Strategic Timeline, Pit Windows, Fuel Projections & Radio Orders (Push/Save/Box/Defend)
    3. [SETUP] Strategy Workshop & Stint Planner (Stint Splits, Compound Selection, Fuel Delta)
    4. [GRID SETUP] Driver Persona 7D DNA & Field Manual Override Matrix
    5. [LOGS] Bounded Ring Buffer Event Diagnostics
    Bottom: Dual-Track Command Receipt & Tactical Race Event Feed
]]

local RaceContext = require("lib/core/RaceContext")
local Logger = require("lib/core/Logger")
local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
local personaLoader = require("lib/driver/persona_loader")
local LODScheduler = require("lib/driver/LODScheduler")
local watchdog = require("lib/driver/watchdog")
local TelemetryBridge = require("lib/bridge/TelemetryBridge")
local strategyCalc = require("lib/strategy/strategy_calculator")
local EventHub = require("lib/core/EventHub")
local ControlTelemetry = require("lib/core/ControlTelemetry")
local WeatherStrategyModel = require("lib/strategy/WeatherStrategyModel")
local TacticalTicker = require("lib/driver/TacticalTicker")
local TVDirectorEngine = require("lib/broadcast/TVDirectorEngine")

local M = {}

--------------------------------------------------------------------------------
-- 1. Color Palette & Zero-Leak Rendering Safe Guards
--------------------------------------------------------------------------------
-- Palette: Modern Motorsport Cockpit
-- Cyan: #00E5FF, Green: #00E676, Blue: #40C4FF, Gold: #FFB74D, Red: #FF5252, Muted: #90A4AE
local function makeColor(r, g, b, a)
  a = a or 1.0
  if _G.rgbm then
    return _G.rgbm(r, g, b, a)
  elseif _G.vec4 then
    return _G.vec4(r, g, b, a)
  end
  return { r = r, g = g, b = b, a = a }
end

local COLOR_CYAN  = makeColor(0.00, 0.90, 1.00, 1.0) -- #00E5FF
local COLOR_GREEN = makeColor(0.00, 0.90, 0.46, 1.0) -- #00E676
local COLOR_BLUE  = makeColor(0.25, 0.77, 1.00, 1.0) -- #40C4FF
local COLOR_GOLD  = makeColor(1.00, 0.72, 0.30, 1.0) -- #FFB74D
local COLOR_RED   = makeColor(1.00, 0.32, 0.32, 1.0) -- #FF5252
local COLOR_MUTED = makeColor(0.58, 0.64, 0.69, 1.0) -- #90A4AE
local COLOR_WHITE = makeColor(1.00, 1.00, 1.00, 1.0) -- #FFFFFF
local COLOR_PURPLE = makeColor(0.85, 0.20, 1.00, 1.0) -- #D500F9
local COLOR_WET_BLUE = makeColor(0.16, 0.47, 1.00, 1.0) -- #2979FF
local COLOR_BTN_OVERRIDE       = makeColor(0.00, 0.42, 0.65, 0.90)
local COLOR_BTN_OVERRIDE_HOVER = makeColor(0.00, 0.58, 0.88, 1.00)
local COLOR_BTN_NATIVE         = makeColor(0.00, 0.45, 0.28, 0.90)
local COLOR_BTN_NATIVE_HOVER   = makeColor(0.00, 0.60, 0.38, 1.00)

local function getCompoundVisual(compName, compIndex)
  local nameUpper = string.upper(tostring(compName or "")):gsub("^%s+", ""):gsub("%s+$", "")
  if (string.find(nameUpper, "SOFT") or nameUpper == "S") and not string.find(nameUpper, "SUPER") and not string.find(nameUpper, "ULTRA") then
    return COLOR_RED, "● [SOFT]"
  elseif string.find(nameUpper, "MED") or nameUpper == "M" then
    return COLOR_GOLD, "● [MED]"
  elseif string.find(nameUpper, "HARD") or nameUpper == "H" or nameUpper == "HR" then
    return COLOR_WHITE, "● [HARD]"
  elseif string.find(nameUpper, "SUPER") or string.find(nameUpper, "SS") then
    return COLOR_PURPLE, "● [SUPER-SOFT]"
  elseif string.find(nameUpper, "ULTRA") or string.find(nameUpper, "HYPER") or string.find(nameUpper, "US") then
    return COLOR_PURPLE, "● [ULTRA-SOFT]"
  elseif string.find(nameUpper, "INTER") or nameUpper == "I" then
    return COLOR_GREEN, "● [INTER]"
  elseif string.find(nameUpper, "WET") or string.find(nameUpper, "RAIN") or nameUpper == "W" then
    return COLOR_WET_BLUE, "● [WET]"
  elseif string.find(nameUpper, "SLICK") or string.find(nameUpper, "DRY") then
    return COLOR_GOLD, "● [SLICK]"
  end
  -- Fallback by index
  local idx = compIndex or 0
  if idx == 0 then return COLOR_RED, "● [SOFT]"
  elseif idx == 1 then return COLOR_GOLD, "● [MED]"
  elseif idx == 2 then return COLOR_WHITE, "● [HARD]"
  elseif idx == 3 then return COLOR_PURPLE, "● [SS]"
  elseif idx == 4 then return COLOR_PURPLE, "● [US]"
  elseif idx == 5 then return COLOR_GREEN, "● [INTER]"
  elseif idx == 6 then return COLOR_WET_BLUE, "● [WET]"
  end
  return COLOR_CYAN, "● [TYRE]"
end

local function getTextColorEnum()
  if ui and ui.StyleColor and ui.StyleColor.Text then
    return ui.StyleColor.Text
  end
  if ui and ui.Col and ui.Col.Text then
    return ui.Col.Text
  end
  return 0
end

local function drawTextColored(col, text)
  if not ui or not ui.text then return end
  if ui.pushStyleColor and ui.popStyleColor and col then
    ui.pushStyleColor(getTextColorEnum(), col)
    ui.text(text)
    ui.popStyleColor(1)
  else
    ui.text(text)
  end
end

local function drawInlineColored(col, text)
  if not ui or not ui.text then return end
  if ui.pushStyleColor and ui.popStyleColor and col then
    ui.pushStyleColor(getTextColorEnum(), col)
    ui.text(text)
    ui.popStyleColor(1)
  else
    ui.text(text)
  end
end

local function setTooltip(tipText)
  if ui and ui.isItemHovered and ui.isItemHovered() and ui.setTooltip then
    ui.setTooltip(tipText)
  end
end

local function drawPersonaOptionButton(label, key, carIndex, isCurrent, isOverride)
  local pushed = 0
  if isCurrent and ui and ui.pushStyleColor then
    local colBtn = isOverride and COLOR_BTN_OVERRIDE or COLOR_BTN_NATIVE
    local colHover = isOverride and COLOR_BTN_OVERRIDE_HOVER or COLOR_BTN_NATIVE_HOVER
    local colText = isOverride and COLOR_CYAN or COLOR_GREEN

    if ui.StyleColor and ui.StyleColor.Button then
      ui.pushStyleColor(ui.StyleColor.Button, colBtn)
      pushed = pushed + 1
      if ui.StyleColor.ButtonHovered then
        ui.pushStyleColor(ui.StyleColor.ButtonHovered, colHover)
        pushed = pushed + 1
      end
      if ui.StyleColor.Text then
        ui.pushStyleColor(ui.StyleColor.Text, colText)
        pushed = pushed + 1
      end
    elseif ui.Col and ui.Col.Button then
      ui.pushStyleColor(ui.Col.Button, colBtn)
      pushed = pushed + 1
    end
  end

  local btnTxt = string.format("%s%s##sel_p_%d_%s", isCurrent and "[● " or "  ", label, carIndex, key)
  if isCurrent then btnTxt = btnTxt .. " ]" else btnTxt = btnTxt .. "  " end

  local clicked = ui.button and ui.button(btnTxt)

  if pushed > 0 and ui and ui.popStyleColor then
    ui.popStyleColor(pushed)
  end

  return clicked
end

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

--------------------------------------------------------------------------------
-- 2. Driver Name Resolution & Formatting (Adaptive Ellipsis & Zero Wrap)
--------------------------------------------------------------------------------
local function getDriverNameDisplay(carIdx, maxLen)
  maxLen = maxLen or 10
  local rawName = ""
  local n = safeGetDriverName(carIdx)
  if n and n ~= "" then rawName = n end

  if rawName == "" then
    local c = RaceContext.getCarState(carIdx)
    if c and c.driverName and c.driverName ~= "" and not c.driverName:find("^AI #") and not c.driverName:find("^Car #") and not c.driverName:find("^AI车手") then
      rawName = c.driverName
    end
  end
  if rawName == "" then
    local car = safeGetCar(carIdx)
    if car then
      if type(car.driverName) == "string" and car.driverName ~= "" then
        rawName = car.driverName
      elseif type(car.driverName) == "function" then
        local ok, res = pcall(car.driverName, car)
        if ok and type(res) == "string" and res ~= "" then
          rawName = res
        end
      end
    end
  end
  if rawName == "" then
    rawName = (carIdx == 0) and "Player" or string.format("Driver #%02d", carIdx + 1)
  end

  local truncated = rawName
  if #rawName > maxLen then
    truncated = rawName:sub(1, maxLen - 2) .. ".."
  end
  return truncated, rawName
end

--------------------------------------------------------------------------------
-- 3. State Management & Dynamic AI Car Discovery (Zero Allocation)
--------------------------------------------------------------------------------
local _selectedTab = 1
local _selectedCarForRadio = 1
local _feedPaused = false

-- Static preallocated buffer for dynamic active AI discovery
local _activeAiIndices = {}
local _activeAiCount = 0

local function refreshActiveAiCars()
  _activeAiCount = 0
  local carStates = RaceContext.getAllCarStates()
  local race = RaceContext.getRaceState()
  local simCars = 0
  if ac and ac.getSim then
    local okSim, s = pcall(ac.getSim)
    if okSim and s and s.carsCount then simCars = s.carsCount end
  end
  local totalCars = math.max(race.carsCount or 0, simCars)

  -- Determine maximum index to probe (never probe blindly with unprotected ac.getCar)
  local maxProbe = math.min(23, math.max(totalCars - 1, 0))
  if maxProbe < 1 then
    for probeIdx = 1, 23 do
      local pCar = safeGetCar(probeIdx)
      if pCar then
        maxProbe = probeIdx
      else
        break
      end
    end
  end

  for i = 1, maxProbe do
    local c = carStates[i]
    local acCar = safeGetCar(i)
    local isAI = false

    if acCar then
      isAI = (acCar.isAIControlled == true) or (i > 0 and not acCar.isPlayer)
    elseif c then
      isAI = (c.isAIControlled == true) and (c.isConnected ~= false)
    end

    if isAI then
      _activeAiCount = _activeAiCount + 1
      _activeAiIndices[_activeAiCount] = i
    end
  end

  -- Guarantee race.carsCount reflects reality (minimum active AI + player)
  local actualTotalCars = math.max(totalCars, _activeAiCount + 1)
  if (not race.carsCount) or race.carsCount < actualTotalCars then
    race.carsCount = actualTotalCars
  end

  -- Validate _selectedCarForRadio
  if _activeAiCount > 0 then
    local found = false
    for slot = 1, _activeAiCount do
      if _activeAiIndices[slot] == _selectedCarForRadio then
        found = true
        break
      end
    end
    if not found then
      _selectedCarForRadio = _activeAiIndices[1]
    end
  end

  return _activeAiCount
end

local _availablePersonas = { "aggressive_bull", "tactical_master", "ice_man", "gentleman_driver", "balanced", "f1_verstappen", "f1_hamilton", "f1_leclerc", "f1_alonso", "f1_norris" }
local _personaNames = {
  ["aggressive_bull"] = "激进猛牛 (超进攻/高消耗)",
  ["tactical_master"] = "战术大师 (控场/精准卡位)",
  ["ice_man"] = "冰人 (极稳/极佳保胎)",
  ["gentleman_driver"] = "绅士车手 (留白/保守跟车)",
  ["balanced"] = "均衡车手 (标称配置)",
  ["f1_verstappen"] = "Max Verstappen (红牛/极度侵略)",
  ["f1_hamilton"] = "Lewis Hamilton (法拉利/极致保胎)",
  ["f1_leclerc"] = "Charles Leclerc (法拉利/排位速度)",
  ["f1_alonso"] = "Fernando Alonso (阿斯顿马丁/战术大师)",
  ["f1_norris"] = "Lando Norris (迈凯伦/精准稳定)"
}

local _personaButtons = {
  { key = "aggressive_bull", label = "激进猛牛" },
  { key = "tactical_master", label = "战术大师" },
  { key = "ice_man", label = "冰人保胎" },
  { key = "gentleman_driver", label = "绅士防守" },
  { key = "balanced", label = "标称均衡" },
  { key = "f1_verstappen", label = "Verstappen" },
  { key = "f1_hamilton", label = "Hamilton" },
  { key = "f1_leclerc", label = "Leclerc" },
  { key = "f1_alonso", label = "Alonso" },
  { key = "f1_norris", label = "Norris" },
}

-- Setup panel working state (Total laps is locked by FIA / session rules)
local _setupStops = 0
local _setupBaseFpl = nil
local _setupAppliedTimestamp = 0.0
local _setupAppliedFeedback = nil

-- Pit Wall Work Order Modal state
local _showWorkOrderModal = false
local _workOrderCarIndex = 1
local _woChangeTyres = true
local _woCompoundIndex = 0
local _woCompoundName = "Default"
local _woRefuelLiters = 0.0

-- Persona grid selection state
local _selectedCarForPersona = nil

--------------------------------------------------------------------------------
-- 4. Main Header & Entry Point
--------------------------------------------------------------------------------
function M.renderMain(perfMs, activeAiCount)
  if not ui or not ui.text then return end

  refreshActiveAiCars()

  -- Top Brand Header
  drawInlineColored(COLOR_CYAN, "ULTIMATE AI GRAND PRIX PRO")
  ui.sameLine()
  ui.text(string.format("| 核心调度延迟: %.2f ms", perfMs or 0.0))

  -- Core Watchdog & Session Status
  local race = RaceContext.getRaceState()
  local isPhysOn = watchdog.isPhysicsAllowed()

  if isPhysOn then
    drawInlineColored(COLOR_GREEN, "[物理看门狗: 已接管]")
  else
    drawInlineColored(COLOR_MUTED, "[物理看门狗: 仅监听]")
  end
  ui.sameLine()
  ui.text("|")
  ui.sameLine()

  local totalLaps = race.totalLaps or 13
  local curLap = race.currentLap or 1
  local lapStr = (totalLaps > 0) and string.format("圈数: %d/%d", curLap, totalLaps) or string.format("当前圈: 第 %d 圈 (计时赛)", curLap)
  drawInlineColored(COLOR_CYAN, lapStr)
  ui.sameLine()
  ui.text("|")
  ui.sameLine()

  if race.flagState == "GREEN" then
    drawInlineColored(COLOR_GREEN, "[绿旗行车]")
  elseif race.flagState == "YELLOW" then
    drawInlineColored(COLOR_GOLD, "[全场黄旗]")
  elseif race.flagState == "SC" or race.flagState == "VSC" then
    drawInlineColored(COLOR_GOLD, "[安全车(SC)]")
  elseif race.flagState == "RED" then
    drawInlineColored(COLOR_RED, "[红旗中止]")
  else
    ui.text(string.format("[%s]", race.flagState or "NORMAL"))
  end

  ui.sameLine()
  ui.text("|")
  ui.sameLine()

  local displayTotalCars = (race.carsCount and race.carsCount > 0) and race.carsCount or math.max(1, _activeAiCount + 1)
  ui.text(string.format("总车辆: %d 辆 (AI 车手: %d 位)", displayTotalCars, _activeAiCount))
  ui.sameLine()
  ui.text("|")
  ui.sameLine()

  local wWetness = WeatherStrategyModel.getTrackWetness()
  local wRain = WeatherStrategyModel.getRainIntensity()
  local wBand = WeatherStrategyModel.getActiveBandName()
  local wOpt = WeatherStrategyModel.getOptimalTyreCompound()
  local wCol = COLOR_GREEN
  local wText = "[天气: 干燥]"
  if wBand == "WET" then
    wCol = COLOR_WET_BLUE
    wText = string.format("[天气: 大雨积水 %.0f%% | %s]", wWetness * 100, wOpt)
  elseif wBand == "INTERMEDIATE" then
    wCol = COLOR_CYAN
    wText = string.format("[天气: 湿地雨势 %.0f%% | %s]", wWetness * 100, wOpt)
  else
    if wRain > 0.05 then
      wCol = COLOR_GOLD
      wText = string.format("[天气: 降水开始 %.0f%% | %s]", wWetness * 100, wOpt)
    else
      wCol = COLOR_GREEN
      wText = "[天气: 干燥路面 (干胎)]"
    end
  end
  drawInlineColored(wCol, wText)

  ui.separator()

  -- Navigation Tabs
  if ui.button(_selectedTab == 1 and "[ 1. 实时HUD ]" or "  1. 实时HUD  ") then _selectedTab = 1 end
  setTooltip("全场活跃 AI 赛车与玩家第一人称微观遥测矩阵")
  ui.sameLine()
  if ui.button(_selectedTab == 2 and "[ 2. 车队指挥 ]" or "  2. 车队指挥  ") then _selectedTab = 2 end
  setTooltip("进站窗口监控、动态油耗与车队无线电指令下达")
  ui.sameLine()
  if ui.button(_selectedTab == 3 and "[ 3. 策略工坊 ]" or "  3. 策略工坊  ") then _selectedTab = 3 end
  setTooltip("全场停站圈数拆解、进站窗口计算与全局策略应用")
  ui.sameLine()
  if ui.button(_selectedTab == 4 and "[ 4. 车手配置 ]" or "  4. 车手配置  ") then _selectedTab = 4 end
  setTooltip("7D 连续 DNA 个性基因覆写与车手风格矩阵")
  ui.sameLine()
  if ui.button(_selectedTab == 5 and "[ 5. 诊断日志 ]" or "  5. 诊断日志  ") then _selectedTab = 5 end
  setTooltip("系统底层有界环形诊断事件流")
  ui.sameLine()
  if ui.button(_selectedTab == 6 and "[ 6. 智能导播 ]" or "  6. 智能导播  ") then _selectedTab = 6 end
  setTooltip("智能实时导播系统控制台：镜头节奏配置、转播风格切换、实时热点雷达与手动直切")

  -- Single Master Toggle Button (Requirement: Single button toggles ON/OFF, defaults to OFF)
  if ui and ui.sameLine then ui.sameLine() end
  local isDirectorOn = TVDirectorEngine.isEnabled()
  local toggleBtnText = isDirectorOn and "[ 🎥 导播: 运行中 ]##top_tv_dir_btn" or "[ 🎥 导播: 已关闭 ]##top_tv_dir_btn"
  if ui and ui.button and ui.button(toggleBtnText) then
    TVDirectorEngine.toggleEnabled()
  end
  setTooltip("一键开启或关闭智能实时导播（默认关闭）。开启后系统根据全场攻防热度与突发失误自主运镜。")

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
  elseif _selectedTab == 6 then
    M.renderDirectorTab()
  end

  -- Pinned Live Event Feed at the Bottom
  M.renderEventFeed()
end

--------------------------------------------------------------------------------
-- 5. Tab 1: Live HUD (Player & Dynamic AI Telemetry Matrix)
--------------------------------------------------------------------------------
function M.renderLiveHudTab()
  drawTextColored(COLOR_CYAN, "【赛道实时动态与玩家车辆遥测】")

  local carStates = RaceContext.getAllCarStates()

  -- 1. Player Telemetry Section (Car #0)
  local playerState = carStates[0]
  local pSpeed = 0.0
  local pGear = 0
  local pRpm = 0
  local pCar = safeGetCar(0)
  if pCar then
    pSpeed = pCar.speedKmh or 0.0
    pGear = pCar.gear or 0
    pRpm = pCar.rpm or 0
  end

  local pFuel = (playerState and playerState.fuelInTank) or 0.0
  local pWear = (playerState and playerState.tyreWear) or 0.0
  local pGearStr = (pGear == 0) and "空档(N)" or ((pGear < 0) and "倒档(R)" or string.format("%d档", pGear))
  local _, pFullName = getDriverNameDisplay(0, 16)

  ui.text(string.format("玩家 [#01] %s: 车速: %.1f km/h | 档位: %s | 转速: %d RPM", pFullName, pSpeed, pGearStr, math.floor(pRpm)))
  ui.text(string.format("  燃油余量: %.1f L | 轮胎磨损: %.1f%% | 看门狗接管: %s",
    pFuel, pWear * 100.0, watchdog.isPhysicsAllowed() and "正常激活" or "仅监听"))

  ui.separator()

  -- 2. Dynamic AI Driver Telemetry Matrix
  drawTextColored(COLOR_CYAN, "【AI 车手动态遥测与攻防博弈矩阵】(点击车手行可直接选中车队指挥目标)")
  
  if _activeAiCount == 0 then
    drawTextColored(COLOR_MUTED, "  [待命状态] 当前赛道暂未检测到其他 AI 车手。")
    drawTextColored(COLOR_MUTED, "  全套拟人化决策网络与 60Hz 物理看门狗已全部就绪。")
    drawTextColored(COLOR_GOLD, "  提示: 加入包含 AI 赛车的快速比赛或周末大奖赛，即可在此查看实时博弈矩阵。")
    return
  end

  -- Table Header (Strict fixed-width alignment)
  ui.text("  车号   车手姓名     LOD等级   攻防战术姿态     压力值   士气/心流    当前特技/指令")

  for slot = 1, _activeAiCount do
    local i = _activeAiIndices[slot]
    local c = carStates[i]
    if c then
      local tier = LODScheduler.getCarTier(i)
      local tierStr = (tier == 1) and "高精T1" or ((tier == 2) and "中距T2" or "低频T3")
      local telem = TelemetryBridge.getCarTelemetry(i)

      local dName, fullDriverName = getDriverNameDisplay(i, 10)
      local dLabel = EventHub.formatDriverLabel(i, fullDriverName)

      local isSelected = (_selectedCarForRadio == i)
      local selPrefix = isSelected and "> " or "  "
      local rowLabel = string.format("%s#%02d %-10s##ai_row_%d", selPrefix, i + 1, dName, i)

      local rowClicked = false
      if ui.selectable then
        rowClicked = ui.selectable(rowLabel, isSelected)
      else
        ui.text(rowLabel)
      end

      if rowClicked then
        _selectedCarForRadio = i
        EventHub.pushCommandEvent("UI", string.format("已切换指挥目标至: %s", dLabel), "SUCCESS")
      end
      setTooltip(string.format("车手: %s (点击选中为车队无线电指挥目标)", fullDriverName))

      ui.sameLine()
      ui.text(string.format("[%s]", tierStr))
      ui.sameLine()

      -- State badge with dedicated color
      local stText = "标准巡航"
      local stColor = COLOR_GREEN

      if c.isRetired or c.pitState == "RETIRED" or c.tacticalState == "RETIRED" then
        stText = "赛车退赛"
        stColor = COLOR_MUTED
      elseif c.pitState == "IN_BAY" or c.pitState == "IN_PITLANE" or c.tacticalState == "PIT_BAY" or c.isInPitlane or c.isInPit then
        stText = "停站作业"
        stColor = COLOR_CYAN
      elseif c.pitState == "REQUESTED" or c.tacticalState == "BOXING" or c.radioCommand == "BOX_THIS_LAP" or c.pit_requested then
        stText = "进站准备"
        stColor = COLOR_RED
      elseif c.tacticalState == "POUNCE_PASS" or c.activeSkill == "POUNCE_PASS" then
        stText = "捕食绝杀"
        stColor = COLOR_GOLD
      elseif c.tacticalState == "ATTACK" or c.tacticalState == "LATE_BRAKE_DIVE" or c.tacticalState == "FEINT_DUMMY" or c.tacticalState == "SWITCHBACK" then
        stText = "进攻推进"
        stColor = COLOR_GOLD
      elseif c.tacticalState == "DEFEND" or c.tacticalState == "GENTLE_SQUEEZE" or c.tacticalState == "TOW_WEAVE" then
        stText = "卡位防守"
        stColor = COLOR_BLUE
      elseif c.tacticalState == "MISTAKE" then
        stText = "失误修正"
        stColor = COLOR_RED
      elseif c.tacticalState == "YIELD" then
        stText = "让行避让"
        stColor = COLOR_MUTED
      end

      drawInlineColored(stColor, string.format("[%-4s]", stText))
      ui.sameLine()
      ui.text(string.format("   %4.2f     %+5.2f     ", telem.stress or 0.0, telem.momentum or 0.0))
      ui.sameLine()

      if c.isRetired or c.pitState == "RETIRED" or c.tacticalState == "RETIRED" or c.activeSkill == "RET" then
        drawInlineColored(COLOR_RED, "[RET]")
      elseif c.activeSkill == "POUNCE_PASS" or c.tacticalState == "POUNCE_PASS" then
        drawInlineColored(COLOR_GOLD, "[捕食绝杀]")
      elseif c.activeSkill and c.activeSkill ~= "NONE" then
        drawInlineColored(COLOR_CYAN, string.format("[%s]", c.activeSkill))
      elseif c.radioCommand and c.radioCommand ~= "NONE" then
        local rCmdCol = (c.radioCommand == "BOX_THIS_LAP") and COLOR_RED or ((c.radioCommand == "PUSH") and COLOR_GOLD or COLOR_GREEN)
        drawInlineColored(rCmdCol, string.format("[%s]", c.radioCommand))
      elseif telem.lift_and_coast == 1 then
        drawInlineColored(COLOR_GREEN, "[滑行节油]")
      elseif telem.breaking_tow == 1 then
        drawInlineColored(COLOR_GOLD, "[破尾流防守]")
      else
        drawInlineColored(COLOR_MUTED, "稳定跟车")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 6. Tab 2: Pit Wall & Driver Radio Command Console
--------------------------------------------------------------------------------
function M.renderPitWallTab()
  drawTextColored(COLOR_CYAN, "【车队无线电指挥台与进站调度】")

  local wWetness = WeatherStrategyModel.getTrackWetness()
  local wRain = WeatherStrategyModel.getRainIntensity()
  local wBand = WeatherStrategyModel.getActiveBandName()
  local wOpt = WeatherStrategyModel.getOptimalTyreCompound()
  local radarCol = (wBand == "WET") and COLOR_WET_BLUE or ((wBand == "INTERMEDIATE") and COLOR_CYAN or COLOR_GREEN)
  drawInlineColored(radarCol, string.format("[天气雷达] 赛道湿地率: %.1f%% | 降水强度: %.2f | 路面分区: %s | 策略推荐配方: %s",
    wWetness * 100.0, wRain, wBand, wOpt))

  local carStates = RaceContext.getAllCarStates()

  -- 1. Radio Command Console
  local _, fullTargetName = getDriverNameDisplay(_selectedCarForRadio, 16)
  local targetLabel = EventHub.formatDriverLabel(_selectedCarForRadio, fullTargetName)

  ui.text("当前指挥目标: ")
  ui.sameLine()
  drawInlineColored(COLOR_CYAN, targetLabel)
  ui.sameLine()

  local selAi = TacticalTicker.getAiState(_selectedCarForRadio)
  local mtiVal = (selAi and selAi.mti) or 0.0
  local riskVal = (selAi and selAi.breakdownRisk) or 0.0
  local psychSt = (selAi and selAi.psychStatus) or "CALM"
  local psychCol = (psychSt == "FLOW") and COLOR_CYAN or ((psychSt == "CRACKING") and COLOR_RED or ((psychSt == "RATTLED") and COLOR_GOLD or ((psychSt == "UNDER_PRESSURE") and COLOR_GOLD or COLOR_GREEN)))
  ui.text("| 心态:")
  ui.sameLine()
  drawInlineColored(psychCol, string.format("[%s]", psychSt))
  ui.sameLine()
  ui.text(string.format("| 威胁(MTI): %.2f | 崩盘风险: %.0f%%", mtiVal, riskVal))
  ui.sameLine()

  if ui.button(" < 上一车手##radio_prev ") then
    if _activeAiCount > 0 then
      local currentSlot = 1
      for slot = 1, _activeAiCount do
        if _activeAiIndices[slot] == _selectedCarForRadio then
          currentSlot = slot
          break
        end
      end
      local prevSlot = ((currentSlot - 2 + _activeAiCount) % _activeAiCount) + 1
      _selectedCarForRadio = _activeAiIndices[prevSlot]
      local _, prevFullName = getDriverNameDisplay(_selectedCarForRadio, 16)
      local prevLabel = EventHub.formatDriverLabel(_selectedCarForRadio, prevFullName)
      EventHub.pushCommandEvent("UI", string.format("已切换指挥目标至: %s", prevLabel), "SUCCESS")
    else
      local cur = _selectedCarForRadio or 1
      _selectedCarForRadio = (cur > 1) and (cur - 1) or 1
      local _, prevFullName = getDriverNameDisplay(_selectedCarForRadio, 16)
      local prevLabel = EventHub.formatDriverLabel(_selectedCarForRadio, prevFullName)
      EventHub.pushCommandEvent("UI", string.format("已切换指挥目标至: %s", prevLabel), "SUCCESS")
    end
  end
  setTooltip("切换至上一位活跃 AI 车手")

  ui.sameLine()
  if ui.button(" 下一车手 >##radio_next ") then
    if _activeAiCount > 0 then
      local currentSlot = 1
      for slot = 1, _activeAiCount do
        if _activeAiIndices[slot] == _selectedCarForRadio then
          currentSlot = slot
          break
        end
      end
      local nextSlot = (currentSlot % _activeAiCount) + 1
      _selectedCarForRadio = _activeAiIndices[nextSlot]
      local _, nextFullName = getDriverNameDisplay(_selectedCarForRadio, 16)
      local nextLabel = EventHub.formatDriverLabel(_selectedCarForRadio, nextFullName)
      EventHub.pushCommandEvent("UI", string.format("已切换指挥目标至: %s", nextLabel), "SUCCESS")
    else
      local cur = _selectedCarForRadio or 1
      local totalC = (RaceContext.getRaceState().carsCount or 2)
      local maxC = math.max(1, totalC - 1)
      _selectedCarForRadio = (cur % maxC) + 1
      local _, nextFullName = getDriverNameDisplay(_selectedCarForRadio, 16)
      local nextLabel = EventHub.formatDriverLabel(_selectedCarForRadio, nextFullName)
      EventHub.pushCommandEvent("UI", string.format("已切换指挥目标至: %s", nextLabel), "SUCCESS")
    end
  end
  setTooltip("切换至下一位活跃 AI 车手")

  ui.sameLine()
  if ui.button("全力冲刺 (PUSH)##cmd_push") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "PUSH")
  end
  setTooltip("指令赛车提升激进侵略度，全力向前推进")

  ui.sameLine()
  if ui.button("激进超车 (ATTACK)##cmd_attack") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "ATTACK")
  end
  setTooltip("指令赛车开启超车通道，缩短跟车留白，执行晚刹车极限超越")

  ui.sameLine()
  if ui.button("极限防守 (DEFEND)##cmd_defend") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "DEFEND")
  end
  setTooltip("指令赛车死守内线防守走线，大直道破坏后车尾流")

  ui.sameLine()
  if ui.button("保胎节油 (SAVE)##cmd_save") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "SAVE")
  end
  setTooltip("指令赛车进入滑行断油模式 (Lift & Coast)，延长轮胎与燃油寿命")

  local selCar = RaceContext.getCarState(_selectedCarForRadio)
  local selPlan = StrategyCoordinator.getCarPlan(_selectedCarForRadio)
  local selFuel = selCar and selCar.fuelInTank or 30.0
  local selMaxFuel = selCar and selCar.maxFuelCapacity or 100.0
  local selFpl = (selCar and selCar.empiricalFpl) or (selPlan and selPlan.dynamicFpl) or 2.5
  local selEstLaps = (selFpl > 0) and math.floor(selFuel / selFpl) or 0

  ui.sameLine()
  if ui.button("本圈进站 (BOX)##cmd_box") then
    _workOrderCarIndex = _selectedCarForRadio
    _showWorkOrderModal = true
    _woChangeTyres = true
    _woCompoundIndex = selCar.compoundIndex or 0
    local compounds = RaceContext.getCarCompounds(_selectedCarForRadio)
    _woCompoundName = (compounds[1] and (compounds[1].longName or compounds[1].shortName)) or "默认配方"
    for _, comp in ipairs(compounds) do
      if comp.index == _woCompoundIndex then
        _woCompoundName = comp.longName or comp.shortName
        break
      end
    end
    local room = math.max(0.0, selMaxFuel - selFuel)
    local race = RaceContext.getRaceState()
    local curLap = race.currentLap or 1
    local totalLaps = race.totalLaps or 13
    local remainLaps = math.max(0, totalLaps - curLap)
    local fuelToFinish = math.max(0.0, (remainLaps * selFpl + 2.0) - selFuel)
    _woRefuelLiters = math.min(room, math.floor(fuelToFinish * 10 + 0.5) / 10)
  end
  setTooltip("配置进站工单（选择轮胎配方、加油量）并向车手下达进站指令")

  ui.sameLine()
  if ui.button("极速进站 (FAST)##cmd_fastbox") then
    RaceContext.setCarWorkOrder(_selectedCarForRadio, {
      changeTyres = true,
      targetCompoundIndex = selCar.compoundIndex or 0,
      targetCompoundName = selCar.compoundName or "Default",
      refuelLiters = 0.0,
      isConfirmed = true,
    })
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "BOX_THIS_LAP")
  end
  setTooltip("一键极速进站 (采用智能默认配置换胎不补油，无需手动配置工单)")

  ui.sameLine()
  if ui.button("解除指令 (CLEAR)##cmd_clear") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "NONE")
  end
  setTooltip("恢复该赛车的自主战术与标称策略节奏")

  -- Command History & Echo preview for quick feedback right on the Pit Wall
  local recentCmds = EventHub.getRecentCommands(3)
  if #recentCmds > 0 then
    local latestCmd = recentCmds[#recentCmds]
    local isOk = (latestCmd.status == "SUCCESS")
    local statusTag = isOk and "[已确认]" or ((latestCmd.status == "PENDING") and "[处理中/合流]" or "[未执行]")
    local statusCol = isOk and COLOR_GREEN or ((latestCmd.status == "PENDING") and COLOR_GOLD or COLOR_RED)
    ui.text("最近无线电回显: ")
    ui.sameLine()
    drawInlineColored(statusCol, statusTag)
    ui.sameLine()
    ui.text(string.format("[%s] %s", latestCmd.timeStr, latestCmd.msg))
  end

  ui.separator()

  -- 2. Synchronized Driver Telemetry & Vehicle Health Panel
  drawTextColored(COLOR_CYAN, string.format("【#%02d %s 实时机械工况与车况遥测】", _selectedCarForRadio + 1, fullTargetName))
  local engHealth = math.max(0.0, math.min(100.0, (selCar.engineLifeLeft or 1000.0) / 10.0))
  local waterT = selCar.waterTemp or 90.0
  local gbHealth = math.max(0.0, math.min(100.0, (1.0 - (selCar.gearboxDamage or 0.0)) * 100.0))
  local bodyDmg = selCar.bodyDamagePct or 0.0
  ui.text(string.format("  引擎寿命: %5.1f%% | 水温: %4.1f°C | 变速箱健康: %5.1f%% | 车身损伤: %4.1f%%",
    engHealth, waterT, gbHealth, bodyDmg))

  local fplTag = selCar.empiricalFpl and "[EMA实测]" or "[动态预估]"
  ui.text(string.format("  燃油状态: %4.1f L / %4.1f L | 单圈能耗: %.2f L/圈 %s | 预计续航: ~%d 圈",
    selFuel, selMaxFuel, selFpl, fplTag, selEstLaps))

  local wWear = selCar.wheelWear or { 1.0, 1.0, 1.0, 1.0 }
  local wCore = selCar.wheelCoreTemp or { 90.0, 90.0, 90.0, 90.0 }
  local wBrake = selCar.wheelBrakeTemp or { 250.0, 250.0, 250.0, 250.0 }
  local compName = selCar.compoundName or "Default"
  ui.text(string.format("  四轮磨损与胎温 (左前/右前/左后/右后) [配方: %s]:", compName))
  ui.text(string.format("    左前: %3d%% (%3d°C / 刹%3d°C)  |  右前: %3d%% (%3d°C / 刹%3d°C)",
    math.floor(wWear[1] * 100 + 0.5), math.floor(wCore[1] + 0.5), math.floor(wBrake[1] + 0.5),
    math.floor(wWear[2] * 100 + 0.5), math.floor(wCore[2] + 0.5), math.floor(wBrake[2] + 0.5)))
  ui.text(string.format("    左后: %3d%% (%3d°C / 刹%3d°C)  |  右后: %3d%% (%3d°C / 刹%3d°C)",
    math.floor(wWear[3] * 100 + 0.5), math.floor(wCore[3] + 0.5), math.floor(wBrake[3] + 0.5),
    math.floor(wWear[4] * 100 + 0.5), math.floor(wCore[4] + 0.5), math.floor(wBrake[4] + 0.5)))

  -- 3. Pre-Dispatch Pit Stop Work Order Modal
  if _showWorkOrderModal and _workOrderCarIndex == _selectedCarForRadio then
    ui.separator()
    drawTextColored(COLOR_GOLD, string.format("【进站作业工单配置 (PIT WORK ORDER) - %s】", targetLabel))

    -- Tire Change
    ui.text("  1. 轮胎作业:")
    if ui.button(_woChangeTyres and "[ 换新轮胎: 是 ]##wo_tyres_yes" or "  换新轮胎: 是  ##wo_tyres_yes") then
      _woChangeTyres = true
    end
    ui.sameLine()
    if ui.button(not _woChangeTyres and "[ 保持原胎: 否 ]##wo_tyres_no" or "  保持原胎: 否  ##wo_tyres_no") then
      _woChangeTyres = false
    end
    setTooltip("选择本次进站是否更换一套全新轮胎")

    if _woChangeTyres then
      local compounds = RaceContext.getCarCompounds(_selectedCarForRadio)
      local selCol, selBadge = getCompoundVisual(_woCompoundName, _woCompoundIndex)
      ui.text("     选定配方:")
      ui.sameLine()
      drawInlineColored(selCol, string.format("【%s】", _woCompoundName or "默认配方"))

      -- Horizontal compact badge selector bar with high-contrast indicator
      for cIdx, comp in ipairs(compounds) do
        if cIdx > 1 and (cIdx - 1) % 4 ~= 0 then
          ui.sameLine()
        end
        local isSel = (_woCompoundIndex == comp.index)
        local cCol, cBadge = getCompoundVisual(comp.longName or comp.shortName, comp.index)
        local shortCode = comp.shortName or ("C" .. comp.index)
        local btnLabel = string.format("%s %s##wo_comp_%d", isSel and "[✔]" or "[ ]", shortCode, comp.index)

        local pushedCol = false
        if isSel and ui.pushStyleColor and ui.popStyleColor and ui.StyleColor and ui.StyleColor.Button then
          ui.pushStyleColor(ui.StyleColor.Button, cCol)
          pushedCol = true
        end

        local clicked = ui.button(btnLabel)
        if pushedCol then
          ui.popStyleColor(1)
        end

        if clicked then
          _woCompoundIndex = comp.index
          _woCompoundName = comp.longName or comp.shortName
        end
        setTooltip(string.format("点击选用: %s (%s)", comp.longName or "", shortCode))
      end
    end

    -- Refueling
    local room = math.max(0.0, selMaxFuel - selFuel)
    local race = RaceContext.getRaceState()
    local curLap = race.currentLap or 1
    local totalLaps = race.totalLaps or 13
    local remainLaps = math.max(0, totalLaps - curLap)
    local fuelToFinish = math.max(0.0, (remainLaps * selFpl + 2.0) - selFuel)
    local safeRecRefuel = math.min(room, math.floor(fuelToFinish * 10 + 0.5) / 10)

    ui.text(string.format("  2. 燃油加注 (剩余容积: %.1f L | 跑完余赛建议: +%.1f L):", room, safeRecRefuel))
    if ui.button(_woRefuelLiters == 0 and "[ 不加油 (0L) ]##wo_rf_0" or "  不加油 (0L)  ##wo_rf_0") then
      _woRefuelLiters = 0.0
    end
    setTooltip("纯换胎不补油 (现代F1赛事规则 / 短停站)")
    ui.sameLine()
    if ui.button(string.format(" 安全跑完 (+%.1fL)##wo_rf_safe", safeRecRefuel)) then
      _woRefuelLiters = safeRecRefuel
    end
    setTooltip("补加足够跑完剩余比赛加 2.0L 保底的安全燃油")
    ui.sameLine()
    if ui.button(" +10L##wo_rf_10 ") then
      _woRefuelLiters = math.min(room, _woRefuelLiters + 10.0)
    end
    ui.sameLine()
    if ui.button(" +25L##wo_rf_25 ") then
      _woRefuelLiters = math.min(room, _woRefuelLiters + 25.0)
    end
    ui.sameLine()
    if ui.button(" 加满油箱 (MAX)##wo_rf_max ") then
      _woRefuelLiters = room
    end

    ui.text(string.format("    -> 计划加注油量: %.1f L (加注后预计油量: %.1f L)",
      _woRefuelLiters, math.min(selMaxFuel, selFuel + _woRefuelLiters)))

    -- Confirmation
    if ui.button("【确认工单并下达进站 (CONFIRM & ISSUE BOX)】##wo_confirm") then
      RaceContext.setCarWorkOrder(_selectedCarForRadio, {
        changeTyres = _woChangeTyres,
        targetCompoundIndex = _woCompoundIndex,
        targetCompoundName = _woCompoundName,
        refuelLiters = _woRefuelLiters,
        isConfirmed = true,
      })
      StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "BOX_THIS_LAP")
      _showWorkOrderModal = false
      EventHub.pushCommandEvent("WORK_ORDER", string.format("已签发 %s 进站工单: 换胎=%s(%s), 补油=%.1fL",
        targetLabel, _woChangeTyres and "是" or "否", _woCompoundName, _woRefuelLiters), "SUCCESS")
    end
    setTooltip("向机组签发该工单并立即通知车手本圈进站")

    ui.sameLine()
    if ui.button(" 取消 (CANCEL)##wo_cancel ") then
      _showWorkOrderModal = false
    end
    setTooltip("取消工单配置，不发送进站指令")
  end

  ui.separator()

  -- 2. Dynamic Pit Strategy Table
  drawTextColored(COLOR_CYAN, "【全场进站策略窗口与动态续航概览】(点击车手行可直接选中指挥目标)")

  if _activeAiCount == 0 then
    -- Show Player Standby Plan
    local playerPlan = StrategyCoordinator.getCarPlan(0)
    local pState = carStates[0]
    local pFuel = pState and pState.fuelInTank or 30.0
    local pFpl = playerPlan.dynamicFpl or 2.5
    local pEstLaps = (pFpl > 0) and math.floor(pFuel / pFpl) or 0
    local _, pFullName = getDriverNameDisplay(0, 16)
    ui.text("  车号   车手姓名     燃油/单圈     预计续航   进站建议窗口    策略决策")
    ui.text(string.format("  #01   %-10s   %4.1fL(%.2f)   ~%2d 圈    第%02d-%02d圈     ",
      pFullName:sub(1, 10), pFuel, pFpl, pEstLaps, playerPlan.openLap or 0, playerPlan.escalateLap or 0))
    ui.sameLine()
    drawInlineColored(COLOR_GREEN, "[继续留场]")
    drawTextColored(COLOR_MUTED, "  [待命] 当前未检测到其他 AI 赛车。多车比赛时将在此动态列出全场战术规划。")
    return
  end

  ui.text("  车号   车手姓名     燃油/单圈     预计续航   进站建议窗口    策略决策")

  for slot = 1, _activeAiCount do
    local i = _activeAiIndices[slot]
    local c = carStates[i]
    if c then
      local plan = StrategyCoordinator.getCarPlan(i)
      local fuel = c.fuelInTank or 0.0
      local fpl = plan.dynamicFpl or 2.5
      local estLaps = (fpl > 0) and math.floor(fuel / fpl) or 0
      local dName, fullDriverName = getDriverNameDisplay(i, 10)
      local dLabel = EventHub.formatDriverLabel(i, fullDriverName)

      local isSelected = (_selectedCarForRadio == i)
      local selPrefix = isSelected and "> " or "  "
      local rowLabel = string.format("%s#%02d %-10s##pit_row_%d", selPrefix, i + 1, dName, i)

      local rowClicked = false
      if ui.selectable then
        rowClicked = ui.selectable(rowLabel, isSelected)
      else
        ui.text(rowLabel)
      end

      if rowClicked then
        _selectedCarForRadio = i
        EventHub.pushCommandEvent("UI", string.format("已切换指挥目标至: %s", dLabel), "SUCCESS")
      end
      setTooltip(string.format("车手: %s (点击选中为指挥目标)", fullDriverName))

      ui.sameLine()
      ui.text(string.format(" %4.1fL(%.2f)   ~%2d 圈    第%02d-%02d圈     ",
        fuel, fpl, estLaps, plan.openLap or 0, plan.escalateLap or 0))
      ui.sameLine()

      if c.isRetired or c.pitState == "RETIRED" or c.tacticalState == "RETIRED" then
        drawInlineColored(COLOR_MUTED, "[已退赛 (RET)]")
      elseif c.pitState == "IN_BAY" or c.pitState == "IN_PITLANE" or c.tacticalState == "PIT_BAY" or c.isInPitlane or c.isInPit then
        drawInlineColored(COLOR_CYAN, "[停站作业中 (BAY)]")
      elseif c.pitState == "REQUESTED" or c.radioCommand == "BOX_THIS_LAP" or c.tacticalState == "BOXING" or c.pit_requested then
        drawInlineColored(COLOR_RED, "[立即进站 (BOX)]")
      else
        drawInlineColored(COLOR_GREEN, "[继续留场 (STAY)]")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 7. Tab 3: Strategy Workshop & Stint Planner
--------------------------------------------------------------------------------
function M.renderSetup()
  if not ui or not ui.text then return end
  drawTextColored(COLOR_CYAN, "【进站策略工坊与参数设定】")
  ui.separator()

  local race = RaceContext.getRaceState()
  local totalLaps = race.totalLaps or 13

  if not _setupBaseFpl then
    local sim = ac and ac.getSim and ac.getSim()
    if sim and sim.trackLengthM and sim.trackLengthM > 0 then
      _setupBaseFpl = math.max(0.8, math.min(4.5, (sim.trackLengthM / 1000.0) * 0.65))
    else
      _setupBaseFpl = 2.0
    end
  end

  ui.text("1. 比赛基础参数设定 (FIA 官方正赛规程锁定):")
  ui.text(string.format("  官方总圈数: %d 圈 (赛程已锁定)  |  基准预估单圈油耗: %.2f L/圈", totalLaps, _setupBaseFpl))

  if ui.button("省油特性 (2.0L)##setup_fpl_low") then
    _setupBaseFpl = 2.0
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("设定为省油车辆参数 (如 GT4 / 房车 / 高效调校)")
  ui.sameLine()
  if ui.button("标准特性 (2.5L)##setup_fpl_med") then
    _setupBaseFpl = 2.5
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("设定为标准 GT3 / 单座方程式标称能耗")
  ui.sameLine()
  if ui.button("高耗特性 (3.2L)##setup_fpl_high") then
    _setupBaseFpl = 3.2
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("设定为大排量/推圈车辆参数 (如 F1 / GT3 / 斯帕长赛道调校)")

  ui.separator()

  ui.text("2. 目标进站停站轮次:")
  if ui.button(_setupStops == 0 and "[ 0停冲刺 (不进站) ]" or "  0停冲刺 (不进站)  ") then
    _setupStops = 0
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, 0, _setupBaseFpl)
  end
  setTooltip("规划为一胎到底、中途不停站策略")
  ui.sameLine()
  if ui.button(_setupStops == 1 and "[ 1停均衡 (常规最优) ]" or "  1停均衡 (常规最优)  ") then
    _setupStops = 1
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, 1, _setupBaseFpl)
  end
  setTooltip("规划为中程单次进站策略，平衡抓地力与停站耗时")
  ui.sameLine()
  if ui.button(_setupStops == 2 and "[ 2停攻击 (全力超车) ]" or "  2停攻击 (全力超车)  ") then
    _setupStops = 2
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, 2, _setupBaseFpl)
  end
  setTooltip("规划为两次进站策略，全程使用高抓地力软胎全力推圈")

  ui.separator()

  ui.text("3. 各赛段 (Stint) 详细拆解与进站开窗:")
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

    ui.text(string.format("  赛段 %d: 第 %d 圈 -> 第 %d 圈 (共 %d 圈) | 所需燃油: ~%.1f L", s, startL, endL, laps, stintFuel))
    if not isFinal then
      drawInlineColored(COLOR_GOLD, string.format("    -> 进站窗口: 最早第 %d 圈 | 目标第 %d 圈 | 最晚第 %d 圈", win.openLap, win.targetLap, win.escalateLap))
    else
      drawInlineColored(COLOR_GREEN, "    -> 最终赛段: 直奔终点方格旗")
    end
  end

  ui.separator()

  ui.text("4. 燃油需求核算卡片:")
  ui.text(string.format("  全场理论耗油: %.1f L (安全储备含保底: %.1f L)", startFuel, safeFuel))
  ui.text(string.format("  节油巡航目标: %.2f L/圈  |  进攻推圈限额: %.2f L/圈", _setupBaseFpl * 0.94, _setupBaseFpl * 1.05))

  ui.separator()

  if ui.button("应用策略至全场发车格 (APPLY STRATEGY)##setup_apply") then
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
    _setupAppliedTimestamp = (os and os.clock and os.clock()) or 0.0
    _setupAppliedFeedback = string.format("策略修改成功！已下发全场: %d圈 / %d停 / %.2f L/圈", totalLaps, _setupStops, _setupBaseFpl)
    Logger.info("SETUP", string.format("Applied field strategy: %d Laps, %d Stops, %.2f FPL", totalLaps, _setupStops, _setupBaseFpl))
  end
  setTooltip("将当前规划的停站圈数与进站窗口即时同步给所有 AI 车手的大脑")

  local nowClock = (os and os.clock and os.clock()) or 0.0
  if _setupAppliedFeedback and (nowClock - _setupAppliedTimestamp) < 4.0 then
    ui.sameLine()
    drawInlineColored(COLOR_GREEN, " [OK] " .. _setupAppliedFeedback)
  end
end

--------------------------------------------------------------------------------
-- 8. Tab 4: Driver Grid Persona Configuration
--------------------------------------------------------------------------------
function M.renderGridSetupTab()
  drawTextColored(COLOR_CYAN, "【车手性格与 7D 基因图谱覆写】")

  if _activeAiCount == 0 then
    drawTextColored(COLOR_MUTED, "当前未检测到活跃 AI 车手。")
    return
  end

  for slot = 1, _activeAiCount do
    local i = _activeAiIndices[slot]
    local c = RaceContext.getCarState(i)
    local dName, fullDriverName = getDriverNameDisplay(i, 10)
    local dLabel = EventHub.formatDriverLabel(i, fullDriverName)
    local curOverride = personaLoader.getManualOverride(i)
    local persona = personaLoader.getPersonaForCar(i, fullDriverName)
    local activeKey = (personaLoader.getActivePersonaKey and personaLoader.getActivePersonaKey(i, fullDriverName)) or curOverride
    local pDisplay = _personaNames[curOverride] or (activeKey and _personaNames[activeKey]) or (persona.name or "均衡配置")

    ui.text(string.format("  #%02d %-10s: ", i + 1, dName))
    setTooltip(string.format("车手: %s", fullDriverName))
    ui.sameLine()
    drawInlineColored(COLOR_BLUE, string.format("[ %s ]", pDisplay))
    ui.sameLine()

    local isEditing = (_selectedCarForPersona == i)
    if ui.button(string.format("%s##btn_persona_%d", isEditing and "收起模版" or "自选模版", i)) then
      if isEditing then
        _selectedCarForPersona = nil
      else
        _selectedCarForPersona = i
      end
    end
    setTooltip(string.format("展开/收起 %s 的性格模版选择面板", dLabel))

    ui.sameLine()
    if ui.button(string.format("恢复默认##reset_persona_%d", i)) then
      personaLoader.setManualOverride(i, nil)
      EventHub.pushCommandEvent("GRID", string.format("已将 %s 恢复为出厂原生性格", dLabel), "SUCCESS")
    end
    setTooltip("清除当前手动覆写，恢复该车手原厂名字对应的基因")

    if isEditing then
      local isManual = (curOverride ~= nil)
      local activeDesc = (curOverride and _personaNames[curOverride])
        or (activeKey and _personaNames[activeKey])
        or (persona.name and (persona.name .. (persona.is_procedural and " (7D连续基因)" or "")))
        or "均衡配置"

      ui.text("    当前生效性格:")
      ui.sameLine()
      drawInlineColored(isManual and COLOR_CYAN or COLOR_GREEN, string.format("[● %s]", activeDesc))
      ui.sameLine()
      drawInlineColored(COLOR_MUTED, isManual and "(玩家手动覆写)" or "(原生AI匹配)")

      ui.text("    [性格流派]:")
      for idx = 1, 5 do
        local pBtn = _personaButtons[idx]
        ui.sameLine()
        local isCurrent = (activeKey == pBtn.key)
        local isOverride = (curOverride == pBtn.key)
        if drawPersonaOptionButton(pBtn.label, pBtn.key, i, isCurrent, isOverride) then
          personaLoader.setManualOverride(i, pBtn.key)
          EventHub.pushCommandEvent("GRID", string.format("已将 %s 性格覆写为: %s", dLabel, _personaNames[pBtn.key] or pBtn.key), "SUCCESS")
        end
        setTooltip(string.format("套用原型模版: %s%s", _personaNames[pBtn.key] or pBtn.key, isCurrent and " (当前生效中)" or ""))
      end

      ui.text("    [F1 传奇]:")
      for idx = 6, 10 do
        local pBtn = _personaButtons[idx]
        ui.sameLine()
        local isCurrent = (activeKey == pBtn.key)
        local isOverride = (curOverride == pBtn.key)
        if drawPersonaOptionButton(pBtn.label, pBtn.key, i, isCurrent, isOverride) then
          personaLoader.setManualOverride(i, pBtn.key)
          EventHub.pushCommandEvent("GRID", string.format("已将 %s 性格覆写为: %s", dLabel, _personaNames[pBtn.key] or pBtn.key), "SUCCESS")
        end
        setTooltip(string.format("套用 F1 传奇基因: %s%s", _personaNames[pBtn.key] or pBtn.key, isCurrent and " (当前生效中)" or ""))
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 9. Tab 5: Core System Diagnostic Logs
--------------------------------------------------------------------------------
function M.renderLogsTab()
  drawTextColored(COLOR_CYAN, "【核心运行诊断与 AI 控制日志】")

  -- 1. Toolbar & Controls
  local isStreamActive = ControlTelemetry.isEnabled()
  if ui and ui.checkbox then
    if ui.checkbox("实时 AI 直接控制日志 (Live AI Control Stream)##ctrl_telemetry_toggle", isStreamActive) then
      ControlTelemetry.setEnabled(not isStreamActive)
    end
  elseif ui and ui.button then
    local toggleBtnText = isStreamActive and "[✔ 开启] 实时 AI 控制遥测流##ctrl_toggle" or "[  关闭] 实时 AI 控制遥测流##ctrl_toggle"
    if ui.button(toggleBtnText) then
      ControlTelemetry.setEnabled(not isStreamActive)
    end
  end
  setTooltip("开启或关闭下发至 CSP 原生 AI 车手的动作遥测流。开启后实时解析配速、进站、防守及异常，关闭时零性能损耗。")

  if ui and ui.sameLine then ui.sameLine() end
  local badgeText = isStreamActive and "[✔ 2-4Hz 动态抽样监听中]" or "[已停用 - 零开销模式]"
  local badgeCol = isStreamActive and COLOR_GREEN or COLOR_MUTED
  drawInlineColored(badgeCol, badgeText)
  setTooltip("当前状态: " .. (isStreamActive and "正在捕获 AI 控制动作 (2-4Hz 采样)" or "控制遥测流已旁路关闭 (零性能开销)"))

  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button("清空控制流##clear_ctrl_stream") then
    ControlTelemetry.clear()
  end
  setTooltip("清空已捕获的 AI 控制动作与异常条目")

  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button("清空系统日志##clear_sys_logs") then
    Logger.reset()
  end
  setTooltip("清空常规诊断与策略服务日志")

  if ui and ui.separator then ui.separator() end

  -- Team Radio Voice Settings Toolbar
  local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
  local isRadioActive = RadioVoiceEngine.isEnabled()
  if ui and ui.checkbox then
    if ui.checkbox("车队无线电语音 (Team Radio Voice)##radio_voice_toggle", isRadioActive) then
      RadioVoiceEngine.setEnabled(not isRadioActive)
    end
  end
  setTooltip("开启或关闭车队无线电真实 F1 语音播报（进站、推圈、省油、超车模式、安全车）")

  if isRadioActive then
    if ui and ui.sameLine then ui.sameLine() end
    local curLang = RadioVoiceEngine.getLanguage()
    local langBtnText = (curLang == "zh") and "[语音: 中文 ZH (点击切英文)]##radio_lang_btn" or "[语音: 英文 EN (点击切中文)]##radio_lang_btn"
    if ui and ui.button and ui.button(langBtnText) then
      RadioVoiceEngine.setLanguage(curLang == "zh" and "en" or "zh")
    end
    setTooltip("双语实时切换：英文围场原声 (EN) / 中文专业指令 (ZH)")

    if ui and ui.sameLine then ui.sameLine() end
    if ui and ui.button and ui.button("试听电台##radio_test_play") then
      RadioVoiceEngine.preview("cmd_push")
    end
    setTooltip("播放测试指令语音，验证开闭蜂鸣与电台播报")
  end

  if ui and ui.separator then ui.separator() end

  -- 2. Live AI Control Stream Section (Streamed when enabled)
  if isStreamActive then
    drawTextColored(COLOR_CYAN, "=== 实时 AI 原生控制遥测流 (Live AI Control Telemetry Stream) ===")
    local ctrlEntries = ControlTelemetry.getRecentEntries(30)
    if #ctrlEntries == 0 then
      drawTextColored(COLOR_MUTED, "  [监听中] 暂无控制动作下发。当战术策略系统下发油门、变道、配速或进站指令时将在此实时显示。")
    else
      for i = #ctrlEntries, 1, -1 do
        local e = ctrlEntries[i]
        if e then
          if e.isError then
            -- Error format: distinct warning/error style (amber/red)
            drawInlineColored(COLOR_RED, string.format("[%s] [ERROR] ", e.timeStr))
            if ui and ui.sameLine then ui.sameLine() end
            drawInlineColored(COLOR_GOLD, e.driverLabel .. " ")
            if ui and ui.sameLine then ui.sameLine() end
            drawInlineColored(COLOR_RED, string.format("Action Failed: %s | Reason: %s", e.category or "Control Action", e.reason or "Precondition failure"))
          else
            if ui and ui.text then
              ui.text(string.format("[%s] ", e.timeStr))
            end
            if ui and ui.sameLine then ui.sameLine() end
            drawInlineColored(COLOR_CYAN, e.driverLabel .. " ")
            if ui and ui.sameLine then ui.sameLine() end
            local catCol = COLOR_WHITE
            if e.category:find("Pit") or e.category:find("Fuel") or e.category:find("Tyre") then
              catCol = COLOR_GREEN
            elseif e.category:find("Defensive") or e.category:find("Attack") then
              catCol = COLOR_GOLD
            elseif e.category:find("Pace") or e.category:find("Energy") then
              catCol = COLOR_BLUE
            elseif e.category:find("Body Language") then
              catCol = COLOR_GOLD
            elseif e.category:find("Throttle") then
              catCol = COLOR_CYAN
            elseif e.category:find("Rescue") then
              catCol = COLOR_RED
            end
            drawInlineColored(catCol, e.category .. " -> ")
            if ui and ui.sameLine then ui.sameLine() end
            if ui and ui.text then
              ui.text(e.description)
            end
          end
        end
      end
    end
    if ui and ui.separator then ui.separator() end
  end

  -- 3. Standard Core System Diagnostic Logs
  drawTextColored(COLOR_CYAN, "=== 系统诊断与服务日志 (System Service Logs) ===")
  local logs = Logger.getRecentLogs()
  if #logs == 0 then
    drawTextColored(COLOR_MUTED, "暂无已产生的日志记录。")
    return
  end
  for i = #logs, math.max(1, #logs - 15), -1 do
    local l = logs[i]
    if l then
      local tagCol = (l.tag == "RADIO") and COLOR_CYAN or ((l.tag == "STRATEGY") and COLOR_GREEN or COLOR_MUTED)
      if ui and ui.text then
        ui.text(string.format("[%s] ", l.timeStr))
      end
      if ui and ui.sameLine then ui.sameLine() end
      drawInlineColored(tagCol, string.format("[%s]", l.tag))
      if ui and ui.sameLine then ui.sameLine() end
      if ui and ui.text then
        ui.text(l.message)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 9b. Tab 6: Intelligent Real-time TV Director Hub
--------------------------------------------------------------------------------
function M.renderDirectorTab()
  if not ui or not ui.text then return end
  drawTextColored(COLOR_CYAN, "【智能实时导播系统 (AI TV Director & Cinematic Broadcast Engine)】")

  local isDirectorActive = TVDirectorEngine.isEnabled()

  -- 1. Master Toggle Button (Single Button Requirement: defaults to OFF)
  local toggleBtnText = isDirectorActive and "[ 🎥 智能导播: 运行中 (点击关闭) ]##tv_dir_main_toggle" or "[ 🎥 智能导播: 当前已关闭 (点击一键开启) ]##tv_dir_main_toggle"
  local toggleBtnCol = isDirectorActive and COLOR_GREEN or COLOR_MUTED
  if ui and ui.button and ui.button(toggleBtnText) then
    TVDirectorEngine.toggleEnabled()
  end
  setTooltip("一键开启或关闭智能实时导播。开启后系统根据全场攻防热度、心理高压、超车与失误事故自主电影级运镜；默认关闭。")

  if ui and ui.sameLine then ui.sameLine() end
  local statusBadge = isDirectorActive and "[✔ 自动化电视运镜调度中 (F1转播机位)]" or "[已停用 - 镜头由游戏原生控制]"
  drawInlineColored(toggleBtnCol, statusBadge)

  if ui and ui.separator then ui.separator() end

  -- 2. Live Telemetry Monitor (When Active)
  if isDirectorActive then
    drawTextColored(COLOR_CYAN, "=== 当前导播监视器 (Live Director Monitor) ===")
    local focusedCar = TVDirectorEngine.getFocusedCar()
    local _, fullTargetName = getDriverNameDisplay(focusedCar, 18)
    local targetLabel = EventHub.formatDriverLabel(focusedCar, fullTargetName)

    local curMode = TVDirectorEngine.getCurrentCameraMode()
    local modeName = (curMode == TVDirectorEngine.CAMERA_MODE_CAR) and "Car T-Cam (车载特写)" or ((curMode == TVDirectorEngine.CAMERA_MODE_HELICOPTER) and "Helicopter (直升机鸟瞰)" or "Track TV (赛道电视机位)")

    local reason = TVDirectorEngine.getCurrentReason()
    local prio = TVDirectorEngine.getCurrentPriority()
    local prioName = (prio == 0) and "P0_EMERGENCY" or ((prio == 1) and "P1_ACTION" or ((prio == 2) and "P2_TACTICS" or ((prio == 3) and "P3_BATTLE" or "P4_ATMOSPHERE")))
    local prioCol = (prio <= 1) and COLOR_RED or ((prio <= 2) and COLOR_GOLD or COLOR_GREEN)

    local dwellElapsed = TVDirectorEngine.getDwellTimer()
    local dwellTarget = TVDirectorEngine.getTargetDwellTime()
    local dwellRemain = TVDirectorEngine.getRemainingDwellTime()

    if ui and ui.text then ui.text(string.format("聚焦目标: %s | 机位: %s", targetLabel, modeName)) end
    if ui and ui.sameLine then ui.sameLine() end
    if ui and ui.text then ui.text("| 运镜理由:") end
    if ui and ui.sameLine then ui.sameLine() end
    drawInlineColored(prioCol, string.format("[%s : %s]", prioName, reason))

    if ui and ui.text then ui.text(string.format("镜头停留: %.1fs / %.1fs (剩余 %.1fs) | 导播风格: [%s]", dwellElapsed, dwellTarget, dwellRemain, TVDirectorEngine.getStyle())) end

    if TVDirectorEngine.isManualOverrideActive() then
      local quietRem = TVDirectorEngine.getQuietTimer()
      if ui and ui.sameLine then ui.sameLine() end
      drawInlineColored(COLOR_GOLD, string.format("[⚠️ 玩家接管中: 静默让渡剩余 %.1fs]", quietRem))
    end

    if ui and ui.separator then ui.separator() end
  end

  -- 3. Configurable Dwell Times & Quiet Window (Requirement 1 & 2)
  drawTextColored(COLOR_CYAN, "=== 镜头节奏与人工让渡时限配置 (Configurable Timing Parameters) ===")

  local minDwell = TVDirectorEngine.getMinDwellTime()
  local maxDwell = TVDirectorEngine.getMaxDwellTime()
  local quietWin = TVDirectorEngine.getQuietWindow()

  -- Min Dwell Control (default 5.0s)
  if ui and ui.text then ui.text(string.format("最小镜头驻留时限 (Min Dwell): %.1f 秒", minDwell)) end
  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" -1s##min_dwell_down ") then
    TVDirectorEngine.setMinDwellTime(minDwell - 1.0)
  end
  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" +1s##min_dwell_up ") then
    TVDirectorEngine.setMinDwellTime(minDwell + 1.0)
  end
  setTooltip("单个镜头的保底最短停留时长（默认 5.0s），防止由于微小热点浮动导致镜头抽搐眩晕。P0 紧急事故除外。")

  -- Max Dwell Control (default 12.0s)
  if ui and ui.text then ui.text(string.format("最大镜头驻留时限 (Max Dwell): %.1f 秒", maxDwell)) end
  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" -1s##max_dwell_down ") then
    TVDirectorEngine.setMaxDwellTime(maxDwell - 1.0)
  end
  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" +1s##max_dwell_up ") then
    TVDirectorEngine.setMaxDwellTime(maxDwell + 1.0)
  end
  setTooltip("单个镜头的最长停留时限（默认 12.0s），超时后强制轮换下一个焦点或切镜，防止镜头单调凝滞。")

  -- Quiet Window Control (default 15.0s)
  if ui and ui.text then ui.text(string.format("玩家手动切镜静默让渡 (Quiet Window): %.1f 秒", quietWin)) end
  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" -2s##quiet_win_down ") then
    TVDirectorEngine.setQuietWindow(quietWin - 2.0)
  end
  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" +2s##quiet_win_up ") then
    TVDirectorEngine.setQuietWindow(quietWin + 2.0)
  end
  setTooltip("检测到玩家手动按键切镜时，导播系统静默让渡的观察时长（默认 15.0s），期间绝不强行夺取镜头。")

  if ui and ui.sameLine then ui.sameLine() end
  if ui and ui.button and ui.button(" 恢复推荐默认值 (5s / 12s / 15s)##reset_director_defaults ") then
    TVDirectorEngine.setMinDwellTime(5.0)
    TVDirectorEngine.setMaxDwellTime(12.0)
    TVDirectorEngine.setQuietWindow(15.0)
  end
  setTooltip("将所有运镜时限一键恢复为官方推荐默认标准")

  if ui and ui.separator then ui.separator() end

  -- 4. Director Style Presets
  drawTextColored(COLOR_CYAN, "=== 转播风格预设 (Broadcast Flavor Presets) ===")
  local curStyle = TVDirectorEngine.getStyle()

  local style1Text = (curStyle == TVDirectorEngine.STYLE_WORLD_FEED) and "[✔ 官方转播风格 (World Feed)]##wf_btn" or "  官方转播风格 (World Feed)  ##wf_btn"
  if ui and ui.button and ui.button(style1Text) then
    TVDirectorEngine.setStyle(TVDirectorEngine.STYLE_WORLD_FEED)
  end
  setTooltip("均衡转播 F1 攻防焦点、头车争霸、关键停站与突发意外（默认推荐）")

  if ui and ui.sameLine then ui.sameLine() end
  local style2Text = (curStyle == TVDirectorEngine.STYLE_ACTION) and "[✔ 全场激战风格 (Action Focus)]##act_btn" or "  全场激战风格 (Action Focus)  ##act_btn"
  if ui and ui.button and ui.button(style2Text) then
    TVDirectorEngine.setStyle(TVDirectorEngine.STYLE_ACTION)
  end
  setTooltip("全程锁定全场间距小于 0.8s 的拼抢缠斗，无激战时才看前排")

  if ui and ui.sameLine then ui.sameLine() end
  local style3Text = (curStyle == TVDirectorEngine.STYLE_ONBOARD) and "[✔ 电影车载视角 (Onboard T-Cam)]##onb_btn" or "  电影车载视角 (Onboard T-Cam)  ##onb_btn"
  if ui and ui.button and ui.button(style3Text) then
    TVDirectorEngine.setStyle(TVDirectorEngine.STYLE_ONBOARD)
  end
  setTooltip("优先使用车载机位（T-Cam 与前鼻翼机位）感受第一人称极速搏杀")

  if ui and ui.separator then ui.separator() end

  -- 5. Combat Hotspot Radar Top 3
  drawTextColored(COLOR_CYAN, "=== 全场战斗精彩度雷达 (Top Combat Hotspots) ===")
  local topHotspots = TVDirectorEngine.getTopHotspots(3)
  for idx = 1, 3 do
    local h = topHotspots[idx]
    if h and h.carIndex >= 0 and h.score > 0 then
      local _, hName = getDriverNameDisplay(h.carIndex, 16)
      local hLabel = EventHub.formatDriverLabel(h.carIndex, hName)
      local hCol = (h.priority <= 1) and COLOR_RED or ((h.priority <= 2) and COLOR_GOLD or COLOR_GREEN)
      if ui and ui.text then ui.text(string.format("热点 #%d: %s | 精彩度: %.1f | ", idx, hLabel, h.score)) end
      if ui and ui.sameLine then ui.sameLine() end
      drawInlineColored(hCol, string.format("[%s]", h.reason))
      if ui and ui.sameLine then ui.sameLine() end
      if ui and ui.button and ui.button(string.format("直切镜头##force_cut_%d", idx)) then
        TVDirectorEngine.forceCut(h.carIndex, nil, "MANUAL_UI_CUT", 1, 8.0)
      end
      setTooltip("立即将 TV 转播镜头直接切换至此处战况焦点")
    end
  end
end

--------------------------------------------------------------------------------
-- 10. Dual-Track Live Command Receipt & Race Broadcast Feed (Pinned)
--------------------------------------------------------------------------------
function M.renderEventFeed()
  ui.separator()
  drawTextColored(COLOR_CYAN, "=== 实时指令响应与赛事广播流 ===")

  -- Controls bar
  if _feedPaused then
    drawInlineColored(COLOR_MUTED, "[已暂停广播]")
  else
    drawInlineColored(COLOR_GREEN, "[正在实时监听]")
  end
  ui.sameLine()
  if ui.button(_feedPaused and "恢复更新##feed_toggle" or "暂停更新##feed_toggle") then
    _feedPaused = not _feedPaused
  end
  setTooltip("暂停或恢复事件流的自动滚动刷新")
  ui.sameLine()
  if ui.button("清空面板##feed_clear") then
    EventHub.clearAll()
  end
  setTooltip("清除当前已记录的指令与事件列表")

  ui.separator()

  -- Track 1: Command & Execution Receipt
  drawTextColored(COLOR_CYAN, "【指令与系统回执 (Track 1)】")
  local cmdEvents = EventHub.getRecentCommands(5)
  if #cmdEvents == 0 then
    drawTextColored(COLOR_MUTED, "  [待命] 暂无已提交指令。在上方点击策略或无线电按钮即可产生即时回显。")
  else
    for _, ev in ipairs(cmdEvents) do
      local isOk = (ev.status == "SUCCESS")
      local markText = isOk and "执行成功" or "执行异常"
      local markCol = isOk and COLOR_GREEN or COLOR_RED
      ui.text(string.format("  [%s] ", ev.timeStr))
      ui.sameLine()
      drawInlineColored(markCol, string.format("[%s]", markText))
      ui.sameLine()
      ui.text(ev.msg)
    end
  end

  ui.separator()

  -- Track 2: AI Behavior & World Events
  drawTextColored(COLOR_CYAN, "【AI 拟人决策与赛事广播 (Track 2)】")
  local aiEvents = EventHub.getRecentAiEvents(7)
  if #aiEvents == 0 then
    drawTextColored(COLOR_MUTED, "  [监听中] 正在追踪全场 AI 攻防博弈、特技动作、失误修正与黄旗突发...")
  else
    for _, ev in ipairs(aiEvents) do
      local isHornAlert = ev.msg:find("抗议") or ev.msg:find("鸣笛")
      local isAlert = isHornAlert or ev.msg:find("大灯") or ev.msg:find("闪灯") or ev.msg:find("失误") or ev.msg:find("黄旗") or ev.msg:find("进站") or ev.msg:find("撞击") or ev.msg:find("Safety") or ev.msg:find("安全车") or ev.msg:find("蓝旗")
      local evCol = isHornAlert and COLOR_RED or (isAlert and COLOR_GOLD or COLOR_BLUE)
      ui.text(string.format("  [%s] ", ev.timeStr))
      ui.sameLine()
      drawInlineColored(evCol, ev.msg)
    end
  end
end

--------------------------------------------------------------------------------
-- 10. Independent Dedicated Strategy Window (On-demand, Zero simulation advance)
--------------------------------------------------------------------------------
function M.renderStrategyWindow()
  if not ui or not ui.text then return end
  refreshActiveAiCars()

  drawInlineColored(COLOR_CYAN, "ULTIMATE AI GRAND PRIX PRO — 独立车队策略指挥台 (PIT WALL & STRATEGY)")
  ui.sameLine()
  local race = RaceContext.getRaceState()
  local totalLaps = race.totalLaps or 13
  local curLap = race.currentLap or 1
  drawInlineColored(COLOR_GOLD, string.format("[赛程: %d/%d 圈]", curLap, totalLaps))
  ui.separator()

  -- Render authoritative pit wall console and command dispatch
  M.renderPitWallTab()

  ui.separator()
  M.renderEventFeed()
end

return M
