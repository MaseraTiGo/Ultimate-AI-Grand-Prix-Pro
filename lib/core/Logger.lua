--[[
  lib/core/Logger.lua
  Ultimate AI Grand Prix Pro - Unified Diagnostic & Bounded Logger
  
  Responsibilities:
    - Structured log output: module, level, timestamp, message
    - Bounded in-memory circular ring buffer for UI diagnosis (max 100 entries)
    - Throttling to prevent log flooding in hot loops
    - Safe integration with ac.log
]]

local M = {}

M.LEVEL_DEBUG = 1
M.LEVEL_INFO  = 2
M.LEVEL_WARN  = 3
M.LEVEL_ERROR = 4

local LEVEL_NAMES = {
  [1] = "DEBUG",
  [2] = "INFO",
  [3] = "WARN",
  [4] = "ERROR"
}

local MAX_LOG_HISTORY = 100
local _history = {}
local _historyHead = 1
local _historyCount = 0
local _currentLogLevel = M.LEVEL_INFO
local _lastThrottledMsgs = {} -- key -> timestamp

function M.setLevel(level)
  _currentLogLevel = level or M.LEVEL_INFO
end

function M.init()
  M.reset()
end

local function pushHistory(entry)
  _history[_historyHead] = entry
  _historyHead = (_historyHead % MAX_LOG_HISTORY) + 1
  if _historyCount < MAX_LOG_HISTORY then
    _historyCount = _historyCount + 1
  end
end

function M.log(level, tag, msg, throttleSec)
  if level < _currentLogLevel then return end

  local now = os.clock()
  if throttleSec and throttleSec > 0 then
    local key = (tag or "") .. ":" .. (msg or "")
    local lastTime = _lastThrottledMsgs[key] or 0
    if (now - lastTime) < throttleSec then
      return
    end
    _lastThrottledMsgs[key] = now
  end

  local lvlName = LEVEL_NAMES[level] or "INFO"
  local timeStr = string.format("%.2f", now)
  local fullMsg = string.format("[GP-PRO][%s][%s] %s", lvlName, tag or "CORE", tostring(msg))

  pushHistory({
    time = now,
    timeStr = timeStr,
    level = level,
    lvlName = lvlName,
    tag = tag or "CORE",
    message = tostring(msg)
  })

  if ac and ac.log then
    ac.log(fullMsg)
  end
end

function M.debug(tag, msg, throttleSec) M.log(M.LEVEL_DEBUG, tag, msg, throttleSec) end
function M.info(tag, msg, throttleSec)  M.log(M.LEVEL_INFO,  tag, msg, throttleSec) end
function M.warn(tag, msg, throttleSec)  M.log(M.LEVEL_WARN,  tag, msg, throttleSec) end
function M.error(tag, msg, throttleSec) M.log(M.LEVEL_ERROR, tag, msg, throttleSec) end

function M.getRecentLogs()
  local list = {}
  local idx = 1
  for i = 1, _historyCount do
    local readIndex = (_historyHead - 1 - _historyCount + i)
    while readIndex <= 0 do readIndex = readIndex + MAX_LOG_HISTORY end
    while readIndex > MAX_LOG_HISTORY do readIndex = readIndex - MAX_LOG_HISTORY end
    list[idx] = _history[readIndex]
    idx = idx + 1
  end
  return list
end

function M.reset()
  _history = {}
  _historyHead = 1
  _historyCount = 0
  _lastThrottledMsgs = {}
end

return M
