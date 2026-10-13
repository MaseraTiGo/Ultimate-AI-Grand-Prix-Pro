--[[
  lib/core/EventHub.lua
  Ultimate AI Grand Prix Pro - Unified Dual-Track Zero-Alloc Event Hub
  
  Responsibilities:
    1. Preallocated dual ring buffer:
       - Track 1: Command & System Feedback (P0: Player actions, ACKs, failures)
       - Track 2: AI Tactics & World Broadcast (P1/P2/P3: Tactics, outcomes, SC/yellow, collisions)
    2. Zero runtime memory allocation in 60Hz/10Hz pathways
    3. Throttling and state edge-detection (prevents flood/flapping)
    4. Fast scalar query API for ImGui rendering
]]

local M = {}

local MAX_EVENTS_PER_TRACK = 64

-- Preallocated event pools
local _cmdTrack = {}
local _aiTrack = {}
local _cmdHead = 1
local _cmdCount = 0
local _aiHead = 1
local _aiCount = 0

-- Rate-limiting memory (carIndex -> lastEventTime)
local _lastTacticalEventTime = {}
local _lastTacticalState = {}
local _lastAttackEventTime = {}
local _lastTowWeaveEventTime = {}
local _lastDefendEventTime = {}

for i = 1, MAX_EVENTS_PER_TRACK do
  _cmdTrack[i] = {
    timeStr = "00:00:00",
    tag = "CMD",
    msg = "",
    status = "SUCCESS", -- "SUCCESS", "PENDING", "FAILED"
    priority = 0
  }
  _aiTrack[i] = {
    timeStr = "00:00:00",
    carIdx = -1,
    tag = "AI",
    msg = "",
    category = "TACTIC", -- "TACTIC", "OUTCOME", "STRATEGY", "WORLD"
    priority = 1
  }
end

local _pendingPitCommands = {}
for i = 0, 24 do
  _lastTacticalEventTime[i] = 0.0
  _lastTacticalState[i] = "CRUISE"
  _lastAttackEventTime[i] = 0.0
  _lastTowWeaveEventTime[i] = 0.0
  _lastDefendEventTime[i] = 0.0
  _pendingPitCommands[i] = 0
end

local function formatSimTime(sessionSec)
  if os and os.date then
    local ok, dStr = pcall(os.date, "%H:%M:%S")
    if ok and dStr then return dStr end
  end
  local total = math.max(0, math.floor(sessionSec or 0))
  local m = math.floor(total / 60)
  local s = total % 60
  return string.format("%02d:%02d", m, s)
end

function M.init()
  _cmdHead = 1
  _cmdCount = 0
  _aiHead = 1
  _aiCount = 0
  for i = 0, 24 do
    _lastTacticalEventTime[i] = 0.0
    _lastTacticalState[i] = "CRUISE"
    _lastAttackEventTime[i] = 0.0
    _lastTowWeaveEventTime[i] = 0.0
    _lastDefendEventTime[i] = 0.0
    _pendingPitCommands[i] = 0
  end
  _lastHeartbeatTime = 0.0
  M.pushAiEvent(0, "SYSTEM", "【系统就绪】Ultimate AI Grand Prix Pro 拟人化决策网络已就绪，正在监听全场遥测！", "WORLD", 0.0)
end

--- Check if car has an ongoing pending pit command
function M.isCarPitPending(carIdx)
  if not carIdx or carIdx < 0 or carIdx > 24 then return false end
  return (_pendingPitCommands[carIdx] or 0) > 0
end

--- Register new pit command for car
function M.registerPitCommand(carIdx)
  if carIdx and carIdx >= 0 and carIdx <= 24 then
    _pendingPitCommands[carIdx] = (_pendingPitCommands[carIdx] or 0) + 1
  end
end

--- Batch consume and settle all pending pit commands for a car
function M.settleCarPitCommands(carIdx, dLabel)
  if not carIdx or carIdx < 0 or carIdx > 24 then return end
  local pendingCount = _pendingPitCommands[carIdx] or 0
  _pendingPitCommands[carIdx] = 0
  local label = dLabel or ("Car #" .. (carIdx + 1))
  local msg = nil
  if pendingCount > 0 then
    msg = string.format("[CMD SETTLED] %s 待处理进站指令已全部批量结算出队 (共处理 %d 条指令)", label, pendingCount)
  else
    msg = string.format("[CMD SETTLED] %s 进站作业已接管确认 (状态已成功闭环)", label)
  end
  M.pushCommandEvent("SETTLE", msg, "SUCCESS")
end

--- Standardized lap string formatter: 第{currentLap}/{totalLaps}圈 (e.g. 第3/13圈)
function M.formatLapStr(curLap, totalLaps)
  local cLap = math.max(1, math.floor(curLap or 1))
  local tLaps = math.max(1, math.floor(totalLaps or 13))
  return string.format("第%d/%d圈", cLap, tLaps)
end

--- Standardized driver identifier: [#02] Driver Name
function M.formatDriverLabel(carIdx, driverName)
  local carNum = (carIdx or 0) + 1
  local name = driverName
  if not name or name == "" or name:find("^AI #") or name:find("^Car #") or name:find("^AI车手") then
    name = (carIdx == 0) and "Player" or string.format("Driver #%02d", carNum)
  end
  return string.format("[#%02d] %s", carNum, name)
end

local _lastHeartbeatTime = 0.0

--- Heartbeat diagnostic feed: outputs status summary every 15s to keep broadcast alive
function M.tickHeartbeat(sessionSec, activeCars, curLap, totalLaps)
  local now = sessionSec or os.clock()
  if (now - _lastHeartbeatTime) >= 15.0 then
    _lastHeartbeatTime = now
    local lapStr = M.formatLapStr(curLap, totalLaps)
    local carsStr = string.format("%d 辆赛车", activeCars or 1)
    local msg = string.format("【赛事速递】%s 绿旗行车，全场 %s 状态平稳，AI 车手战术网络正常运转。", lapStr, carsStr)
    M.pushAiEvent(0, "HEARTBEAT", msg, "WORLD", now)
  end
end

--- Push player or system command execution event (Track 1)
function M.pushCommandEvent(tag, msg, status, sessionSec)
  local slot = _cmdTrack[_cmdHead]
  slot.timeStr = formatSimTime(sessionSec)
  slot.tag = tag or "CMD"
  slot.msg = msg or ""
  slot.status = status or "SUCCESS"
  slot.priority = 0

  if ac and ac.log then
    ac.log(string.format("[CMD-ECHO][%s][%s] %s", slot.timeStr, status or "OK", msg or ""))
  end

  _cmdHead = (_cmdHead % MAX_EVENTS_PER_TRACK) + 1
  if _cmdCount < MAX_EVENTS_PER_TRACK then
    _cmdCount = _cmdCount + 1
  end
end

--- Push AI tactical behavior, outcome or world event (Track 2)
function M.pushAiEvent(carIdx, tag, msg, category, sessionSec)
  local slot = _aiTrack[_aiHead]
  slot.timeStr = formatSimTime(sessionSec)
  slot.carIdx = carIdx or -1
  slot.tag = tag or "AI"
  slot.msg = msg or ""
  slot.category = category or "TACTIC"
  slot.priority = 1

  if ac and ac.log then
    ac.log(string.format("[AI-BROADCAST][%s] %s", slot.timeStr, msg or ""))
  end

  _aiHead = (_aiHead % MAX_EVENTS_PER_TRACK) + 1
  if _aiCount < MAX_EVENTS_PER_TRACK then
    _aiCount = _aiCount + 1
  end
end

--- Edge-detected tactical event emission with 2.5s deduplication per car
function M.emitTacticalStateChange(carIdx, driverName, newState, oldState, skillName, sessionSec)
  if not carIdx or carIdx < 0 or carIdx > 24 then return end
  local now = sessionSec or os.clock()
  -- Physical plausibility guard: Combat/overtake/defense skills cannot happen when stationary on grid
  if newState ~= "BOXING" and newState ~= "CRUISE" and ac and ac.getCar then
    local okCar, cObj = pcall(ac.getCar, carIdx)
    if okCar and cObj and (cObj.speedKmh or 0.0) < 45.0 then
      return
    end
  end

  -- BOXING and YIELD bypass throttling
  if newState ~= "BOXING" and newState ~= "YIELD" and (now - (_lastTacticalEventTime[carIdx] or 0)) < 3.5 then
    return
  end

  -- Specific high-frequency tactical event debouncing to prevent flood
  if newState == "ATTACK" or (skillName and skillName == "ATTACK") then
    if (now - (_lastAttackEventTime[carIdx] or 0)) < 15.0 then
      return
    end
    _lastAttackEventTime[carIdx] = now
  elseif newState == "TOW_WEAVE" or (skillName and skillName == "TOW_WEAVE") then
    if (now - (_lastTowWeaveEventTime[carIdx] or 0)) < 15.0 then
      return
    end
    _lastTowWeaveEventTime[carIdx] = now
  elseif newState == "DEFEND" then
    if (now - (_lastDefendEventTime[carIdx] or 0)) < 12.0 then
      return
    end
    _lastDefendEventTime[carIdx] = now
  end

  local dLabel = M.formatDriverLabel(carIdx, driverName)
  local msg = nil
  local category = "TACTIC"

  if newState == "LATE_BRAKE_DIVE" or (skillName and skillName == "LATE_BRAKE_DIVE") then
    msg = string.format("%s 尝试内线晚刹深潜超车！", dLabel)
  elseif newState == "FEINT_DUMMY" or (skillName and skillName == "FEINT_DUMMY") then
    msg = string.format("%s 发动声东击西佯攻，诱骗前车防线！", dLabel)
  elseif newState == "SWITCHBACK" or (skillName and skillName == "SWITCHBACK") then
    msg = string.format("%s 晚Apex下切交叉线，展开犀利反击！", dLabel)
  elseif newState == "TOW_WEAVE" or (skillName and skillName == "TOW_WEAVE") then
    msg = string.format("%s 大直道摇摆走线，阻断后车尾流吸入！", dLabel)
  elseif newState == "GENTLE_SQUEEZE" or (skillName and skillName == "GENTLE_SQUEEZE") then
    msg = string.format("%s 施展渐进侧向挤压，逼迫对手进入脏走线！", dLabel)
  elseif newState == "DEFEND" and oldState ~= "DEFEND" then
    msg = string.format("%s 察觉后车迫近威胁，全面卡死内线防守！", dLabel)
  elseif newState == "ATTACK" and oldState ~= "ATTACK" then
    msg = string.format("%s 进入攻击窗口，全力寻找超车空隙！", dLabel)
  elseif newState == "MISTAKE" then
    msg = string.format("%s 极限施压下出现微小失误！正在稳舵修正！", dLabel)
    category = "OUTCOME"
  elseif newState == "BOXING" then
    msg = string.format("%s 确认本圈进站指令，正贴靠外侧驶向维修通道！", dLabel)
    category = "STRATEGY"
  elseif newState == "YIELD" or (skillName and skillName == "YIELD") then
    if oldState ~= "YIELD" then
      msg = string.format("【蓝旗避让】%s 被出示蓝旗，主动让出内线避让快车！", dLabel)
      category = "TACTIC"
    end
  end

  if msg then
    _lastTacticalEventTime[carIdx] = now
    _lastTacticalState[carIdx] = newState
    M.pushAiEvent(carIdx, "TACTIC", msg, category, now)
  end
end

--- Emit overtake event when car gains position
function M.emitOvertake(overtakerIdx, driverName, newPos, sessionSec)
  local now = sessionSec or os.clock()
  local dLabel = M.formatDriverLabel(overtakerIdx, driverName)
  local msg = string.format("【超车完成】%s 干净利落完成超越，升至第 P%d 位！", dLabel, newPos or 1)
  M.pushAiEvent(overtakerIdx, "OVERTAKE", msg, "OUTCOME", now)
end

--- Emit tyre degradation cliff alert
function M.emitTyreCliffAlert(carIdx, driverName, wearPct, sessionSec)
  local now = sessionSec or os.clock()
  local dLabel = M.formatDriverLabel(carIdx, driverName)
  local msg = string.format("【轮胎警报】%s 轮胎损耗达 %.0f%%，抓地力跌入衰退悬崖！", dLabel, (wearPct or 0.65) * 100)
  M.pushAiEvent(carIdx, "TYRE", msg, "STRATEGY", now)
end

--- Emit mechanical health or thermal overheating alert
function M.emitMechanicalAlert(carIdx, driverName, alertType, detailVal, sessionSec)
  local now = sessionSec or os.clock()
  local dLabel = M.formatDriverLabel(carIdx, driverName)
  local msg = nil
  if alertType == "WATER_TEMP" then
    msg = string.format("【机械预警】%s 引擎水温异常偏高 (%.0f°C)，车队呼叫注意散热！", dLabel, detailVal or 105.0)
  elseif alertType == "GEARBOX" then
    msg = string.format("【机械预警】%s 变速箱磨损过大 (%.0f%%)，升降挡顿挫加剧！", dLabel, (detailVal or 0.3) * 100)
  else
    msg = string.format("【机械预警】%s 车身机械状态出现异常！", dLabel)
  end
  M.pushAiEvent(carIdx, "HEALTH", msg, "WORLD", now)
end

--- Emit fastest lap achievement
function M.emitFastestLap(carIdx, driverName, lapTime, sessionSec)
  local now = sessionSec or os.clock()
  local dLabel = M.formatDriverLabel(carIdx, driverName)
  local msg = string.format("【最快圈速】%s 做出全场最快圈速 (%.3f秒)！", dLabel, lapTime)
  M.pushAiEvent(carIdx, "FASTEST", msg, "OUTCOME", now)
end

--- Get latest command events (newest first)
function M.getRecentCommands(maxN)
  local list = {}
  local limit = math.min(maxN or 10, _cmdCount)
  for i = 0, limit - 1 do
    local idx = _cmdHead - 1 - i
    if idx <= 0 then idx = idx + MAX_EVENTS_PER_TRACK end
    table.insert(list, _cmdTrack[idx])
  end
  return list
end

--- Get latest AI events (newest first)
function M.getRecentAiEvents(maxN)
  local list = {}
  local limit = math.min(maxN or 10, _aiCount)
  for i = 0, limit - 1 do
    local idx = _aiHead - 1 - i
    if idx <= 0 then idx = idx + MAX_EVENTS_PER_TRACK end
    table.insert(list, _aiTrack[idx])
  end
  return list
end

function M.clearAll()
  _cmdHead = 1
  _cmdCount = 0
  _aiHead = 1
  _aiCount = 0
end

return M
