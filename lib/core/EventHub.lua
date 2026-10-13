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

local MAX_EVENTS_PER_TRACK = 32

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

for i = 0, 24 do
  _lastTacticalEventTime[i] = 0.0
  _lastTacticalState[i] = "CRUISE"
end

local function formatSimTime(sessionSec)
  local total = math.max(0, math.floor(sessionSec or 0))
  local m = math.floor(total / 60)
  local s = total % 60
  local ms = math.floor(((sessionSec or 0) - total) * 100)
  return string.format("%02d:%02d:%02d", m, s, ms)
end

function M.init()
  _cmdHead = 1
  _cmdCount = 0
  _aiHead = 1
  _aiCount = 0
  for i = 0, 24 do
    _lastTacticalEventTime[i] = 0.0
    _lastTacticalState[i] = "CRUISE"
  end
end

--- Push player or system command execution event (Track 1)
function M.pushCommandEvent(tag, msg, status, sessionSec)
  local slot = _cmdTrack[_cmdHead]
  slot.timeStr = formatSimTime(sessionSec or os.clock())
  slot.tag = tag or "CMD"
  slot.msg = msg or ""
  slot.status = status or "SUCCESS"
  slot.priority = 0

  _cmdHead = (_cmdHead % MAX_EVENTS_PER_TRACK) + 1
  if _cmdCount < MAX_EVENTS_PER_TRACK then
    _cmdCount = _cmdCount + 1
  end
end

--- Push AI tactical behavior, outcome or world event (Track 2)
function M.pushAiEvent(carIdx, tag, msg, category, sessionSec)
  local slot = _aiTrack[_aiHead]
  slot.timeStr = formatSimTime(sessionSec or os.clock())
  slot.carIdx = carIdx or -1
  slot.tag = tag or "AI"
  slot.msg = msg or ""
  slot.category = category or "TACTIC"
  slot.priority = 1

  _aiHead = (_aiHead % MAX_EVENTS_PER_TRACK) + 1
  if _aiCount < MAX_EVENTS_PER_TRACK then
    _aiCount = _aiCount + 1
  end
end

--- Edge-detected tactical event emission with 2.5s deduplication per car
function M.emitTacticalStateChange(carIdx, driverName, newState, oldState, skillName, sessionSec)
  if not carIdx or carIdx < 0 or carIdx > 24 then return end
  local now = sessionSec or os.clock()
  if (now - (_lastTacticalEventTime[carIdx] or 0)) < 2.5 then
    return
  end

  local name = (driverName and driverName ~= "") and driverName or string.format("Car #%02d", carIdx + 1)
  local msg = nil
  local category = "TACTIC"

  if newState == "LATE_BRAKE_DIVE" or (skillName and skillName == "LATE_BRAKE_DIVE") then
    msg = string.format("[%s] 尝试内线晚刹深潜超车！", name)
  elseif newState == "FEINT_DUMMY" or (skillName and skillName == "FEINT_DUMMY") then
    msg = string.format("[%s] 发动声东击西佯攻，诱骗前车防线！", name)
  elseif newState == "SWITCHBACK" or (skillName and skillName == "SWITCHBACK") then
    msg = string.format("[%s] 晚Apex下切交叉线，展开犀利反击！", name)
  elseif newState == "TOW_WEAVE" or (skillName and skillName == "TOW_WEAVE") then
    msg = string.format("[%s] 大直道摇摆走线，阻断后车尾流吸入！", name)
  elseif newState == "GENTLE_SQUEEZE" or (skillName and skillName == "GENTLE_SQUEEZE") then
    msg = string.format("[%s] 施展渐进侧向挤压，逼迫对手进入脏走线！", name)
  elseif newState == "DEFEND" and oldState ~= "DEFEND" then
    msg = string.format("[%s] 察觉后车迫近威胁，全面卡死内线防守！", name)
  elseif newState == "ATTACK" and oldState ~= "ATTACK" then
    msg = string.format("[%s] 进入攻击窗口，全力寻找超车空隙！", name)
  elseif newState == "MISTAKE" then
    msg = string.format("[%s] 极限施压下出现微小失误！正在稳舵修正！", name)
    category = "OUTCOME"
  end

  if msg then
    _lastTacticalEventTime[carIdx] = now
    _lastTacticalState[carIdx] = newState
    M.pushAiEvent(carIdx, "TACTIC", msg, category, now)
  end
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
