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

--------------------------------------------------------------------------------
-- 2. Driver Name Resolution & Formatting (Adaptive Ellipsis & Zero Wrap)
--------------------------------------------------------------------------------
local function getDriverNameDisplay(carIdx, maxLen)
  maxLen = maxLen or 10
  local rawName = ""
  if ac and ac.getDriverName then
    local n = ac.getDriverName(carIdx)
    if n and n ~= "" then rawName = n end
  end
  if rawName == "" then
    local c = RaceContext.getCarState(carIdx)
    if c and c.driverName and c.driverName ~= "" and not c.driverName:find("^AI #") and not c.driverName:find("^Car #") and not c.driverName:find("^AI车手") then
      rawName = c.driverName
    end
  end
  if rawName == "" and ac and ac.getCar then
    local car = ac.getCar(carIdx)
    if car and car.driverName and car.driverName ~= "" then
      rawName = car.driverName
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
  local simCars = (ac and ac.getSim and ac.getSim().carsCount) or 0
  local totalCars = math.max(race.carsCount or 0, simCars)

  -- Determine maximum index to probe
  local maxProbe = math.min(23, math.max(totalCars - 1, 0))
  if ac and ac.getCar then
    for probeIdx = 1, 23 do
      if ac.getCar(probeIdx) then
        maxProbe = math.max(maxProbe, probeIdx)
      end
    end
  end

  for i = 1, maxProbe do
    local c = carStates[i]
    local acCar = ac and ac.getCar and ac.getCar(i)
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

local _availablePersonas = { "aggressive_bull", "tactical_master", "ice_man", "gentleman_driver", "balanced" }
local _personaNames = {
  ["aggressive_bull"] = "激进猛牛 (超进攻/高消耗)",
  ["tactical_master"] = "战术大师 (控场/精准卡位)",
  ["ice_man"] = "冰人 (极稳/极佳保胎)",
  ["gentleman_driver"] = "绅士车手 (留白/保守跟车)",
  ["balanced"] = "均衡车手 (标称配置)"
}

-- Setup panel working state
local _setupTargetLaps = 13
local _setupStops = 1
local _setupBaseFpl = 2.5

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

      if c.tacticalState == "BOXING" or c.radioCommand == "BOX_THIS_LAP" or c.pit_requested then
        stText = "进站准备"
        stColor = COLOR_RED
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

      if c.activeSkill and c.activeSkill ~= "NONE" then
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

  local carStates = RaceContext.getAllCarStates()

  -- 1. Radio Command Console
  local _, fullTargetName = getDriverNameDisplay(_selectedCarForRadio, 16)
  local targetLabel = EventHub.formatDriverLabel(_selectedCarForRadio, fullTargetName)

  ui.text("当前指挥目标: ")
  ui.sameLine()
  drawInlineColored(COLOR_CYAN, targetLabel)
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
    end
  end
  setTooltip("切换至下一位活跃 AI 车手")

  ui.sameLine()
  if ui.button("全力冲刺 (PUSH)##cmd_push") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "PUSH")
  end
  setTooltip("指令赛车提升激进侵略度，全力向前推进")

  ui.sameLine()
  if ui.button("保胎节油 (SAVE)##cmd_save") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "SAVE")
  end
  setTooltip("指令赛车进入滑行断油模式 (Lift & Coast)，延长轮胎与燃油寿命")

  ui.sameLine()
  if ui.button("本圈进站 (BOX)##cmd_box") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "BOX_THIS_LAP")
  end
  setTooltip("强制要求赛车贴靠维修区入口并在本圈进站 (自动注入底层油量诱导激活原生进站)")

  ui.sameLine()
  if ui.button("解除指令 (CLEAR)##cmd_clear") then
    StrategyCoordinator.issueRadioOrder(_selectedCarForRadio, "NONE")
  end
  setTooltip("恢复该赛车的自主战术与标称策略节奏")

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

      if plan.activeRecommendation == "BOX_THIS_LAP" or c.radioCommand == "BOX_THIS_LAP" or c.tacticalState == "BOXING" or c.pit_requested then
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
  drawTextColored(COLOR_CYAN, "【进站策略工坊与参数设定】")
  ui.separator()

  local race = RaceContext.getRaceState()
  local totalLaps = race.totalLaps or _setupTargetLaps or 13

  ui.text("1. 比赛基础参数设定:")
  ui.text(string.format("  当前比赛总圈数: %d 圈  |  基准预估单圈油耗: %.2f L/圈", totalLaps, _setupBaseFpl))

  if ui.button("圈数 -1##setup_minus") then
    _setupTargetLaps = math.max(1, totalLaps - 1)
    RaceContext.setTotalLaps(_setupTargetLaps)
    StrategyCoordinator.rebuildFieldStrategy(_setupTargetLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("将整场比赛总圈数减少 1 圈并重新计算全场进站窗口")
  ui.sameLine()
  if ui.button("圈数 +1##setup_plus") then
    _setupTargetLaps = math.min(200, totalLaps + 1)
    RaceContext.setTotalLaps(_setupTargetLaps)
    StrategyCoordinator.rebuildFieldStrategy(_setupTargetLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("将整场比赛总圈数增加 1 圈并重新计算全场进站窗口")
  ui.sameLine()
  if ui.button("圈数 +5##setup_plus5") then
    _setupTargetLaps = math.min(200, totalLaps + 5)
    RaceContext.setTotalLaps(_setupTargetLaps)
    StrategyCoordinator.rebuildFieldStrategy(_setupTargetLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("将整场比赛总圈数增加 5 圈")
  ui.sameLine()
  if ui.button("低油耗 (2.2L)##setup_fpl_low") then
    _setupBaseFpl = 2.2
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("设定为省油车辆参数 (如 GT4 / 房车 / 高效调校)")
  ui.sameLine()
  if ui.button("高油耗 (2.8L)##setup_fpl_high") then
    _setupBaseFpl = 2.8
    StrategyCoordinator.rebuildFieldStrategy(totalLaps, _setupStops, _setupBaseFpl)
  end
  setTooltip("设定为大排量/推圈车辆参数 (如 F1 / GT3 / 冲刺调校)")

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
    Logger.info("SETUP", string.format("Applied field strategy: %d Laps, %d Stops, %.2f FPL", totalLaps, _setupStops, _setupBaseFpl))
  end
  setTooltip("将当前规划的停站圈数与进站窗口即时同步给所有 AI 车手的大脑")
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
    local pDisplay = _personaNames[curOverride] or (persona.name or "均衡配置")

    ui.text(string.format("  #%02d %-10s: ", i + 1, dName))
    setTooltip(string.format("车手: %s", fullDriverName))
    ui.sameLine()
    drawInlineColored(COLOR_BLUE, string.format("[ %s ]", pDisplay))
    ui.sameLine()

    if ui.button(string.format("切换性格模版##persona_%d", i)) then
      local nextIdx = 1
      for idx, key in ipairs(_availablePersonas) do
        if curOverride == key then
          nextIdx = (idx % #_availablePersonas) + 1
          break
        end
      end
      personaLoader.setManualOverride(i, _availablePersonas[nextIdx])
      EventHub.pushCommandEvent("GRID", string.format("已将 %s 性格覆写为: %s", dLabel, _personaNames[_availablePersonas[nextIdx]] or _availablePersonas[nextIdx]), "SUCCESS")
    end
    setTooltip(string.format("循环切换 %s 的驾驶性格模版", dLabel))
  end
end

--------------------------------------------------------------------------------
-- 9. Tab 5: Core System Diagnostic Logs
--------------------------------------------------------------------------------
function M.renderLogsTab()
  drawTextColored(COLOR_CYAN, "【核心运行诊断日志流】")
  local logs = Logger.getRecentLogs()
  if #logs == 0 then
    drawTextColored(COLOR_MUTED, "暂无已产生的日志记录。")
    return
  end
  for i = #logs, math.max(1, #logs - 15), -1 do
    local l = logs[i]
    if l then
      local tagCol = (l.tag == "RADIO") and COLOR_CYAN or ((l.tag == "STRATEGY") and COLOR_GREEN or COLOR_MUTED)
      ui.text(string.format("[%s] ", l.timeStr))
      ui.sameLine()
      drawInlineColored(tagCol, string.format("[%s]", l.tag))
      ui.sameLine()
      ui.text(l.message)
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
      local isAlert = ev.msg:find("失误") or ev.msg:find("黄旗") or ev.msg:find("进站") or ev.msg:find("撞击") or ev.msg:find("Safety") or ev.msg:find("安全车")
      local evCol = isAlert and COLOR_GOLD or COLOR_BLUE
      ui.text(string.format("  [%s] ", ev.timeStr))
      ui.sameLine()
      drawInlineColored(evCol, ev.msg)
    end
  end
end

return M
