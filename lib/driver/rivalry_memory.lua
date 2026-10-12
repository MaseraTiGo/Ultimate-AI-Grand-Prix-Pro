--[[
  rivalry_memory.lua
  Persistent Cross-Session Rivalry & Incident Memory System
  Uses lightweight JSON Lines storage to log contact & grievance events asynchronously.
]]

local M = {}

local _rivalryDB = {} -- driverKey -> { grievanceLevel, contactCount, lastIncidentLap }
local _storageFile = "rivalry_memory.jsonl"
local _pendingEvents = {}
local _adapter = nil

-- Adapter interface:
-- adapter.init(config)
-- adapter.recordEvent(event)
-- adapter.loadEvents() -> list
-- adapter.flush(events)

local LocalFileAdapter = {}
function LocalFileAdapter.loadEvents(filename)
  local list = {}
  local content = nil
  if io and io.load then
    content = io.load(filename)
  else
    local f = io.open(filename, "r")
    if f then content = f:read("*a"); f:close() end
  end
  if content then
    for line in content:gmatch("[^\r\n]+") do
      local ok, ev = pcall(function()
        if JSON and JSON.parse then return JSON.parse(line) end
        if json and json.decode then return json.decode(line) end
        local okJ, libJ = pcall(require, "lib/driver/json")
        if okJ and libJ and libJ.parse then return libJ.parse(line) end
        if okJ and libJ and libJ.decode then return libJ.decode(line) end
        return nil
      end)
      if ok and ev then table.insert(list, ev) end
    end
  end
  return list
end

function LocalFileAdapter.flush(filename, events)
  if not events or #events == 0 then return end
  local buffer = ""
  for _, ev in ipairs(events) do
    local jsonStr = nil
    if JSON and JSON.stringify then jsonStr = JSON.stringify(ev)
    elseif json and json.encode then jsonStr = json.encode(ev)
    else
      local okJ, libJ = pcall(require, "lib/driver/json")
      if okJ and libJ and libJ.stringify then jsonStr = libJ.stringify(ev)
      elseif okJ and libJ and libJ.encode then jsonStr = libJ.encode(ev)
      else
        jsonStr = string.format('{"tick":%d,"driverKey":"%s","player":"%s","severity":%.2f,"lap":%d}',
          ev.tick or 0, ev.driverKey or "", ev.player or "", ev.severity or 1.0, ev.lap or 0)
      end
    end
    if jsonStr then buffer = buffer .. jsonStr .. "\n" end
  end
  if buffer ~= "" then
    local f = io.open(filename, "a")
    if f then f:write(buffer); f:close() end
  end
end

-- Future Online Adapter skeleton
local WebSocketRivalryAdapter = {}
function WebSocketRivalryAdapter.loadEvents(url) return {} end
function WebSocketRivalryAdapter.flush(url, events)
  -- Stubs websocket dispatch to AssettoServer
end

function M.setAdapter(customAdapter)
  _adapter = customAdapter
end

local function getDriverKey(driverName)
  if not driverName or driverName == "" then return "UnknownDriver" end
  return driverName:gsub("[%s%p]", "_"):lower()
end

function M.init(filepath, customAdapter)
  _storageFile = filepath or "rivalry_memory.jsonl"
  _adapter = customAdapter or LocalFileAdapter
  
  -- Load historical events via active Adapter
  local loaded = _adapter.loadEvents(_storageFile)
  for _, ev in ipairs(loaded) do
    if ev and ev.driverKey then
      local r = _rivalryDB[ev.driverKey] or { grievanceLevel = 0, contactCount = 0 }
      r.contactCount = r.contactCount + 1
      r.grievanceLevel = math.min(10.0, r.grievanceLevel + (ev.severity or 1.0))
      _rivalryDB[ev.driverKey] = r
    end
  end
end

--- Record a physical incident/collision between player and AI
---@param aiDriverName string
---@param playerDriverName string
---@param severity number (1.0 = rub, 3.0 = hard hit)
---@param lap integer
function M.recordContact(aiDriverName, playerDriverName, severity, lap)
  local key = getDriverKey(aiDriverName)
  local r = _rivalryDB[key] or { grievanceLevel = 0, contactCount = 0, lastIncidentLap = 0 }
  
  r.contactCount = r.contactCount + 1
  r.grievanceLevel = math.min(10.0, r.grievanceLevel + (severity or 1.5))
  r.lastIncidentLap = lap or 0
  _rivalryDB[key] = r

  -- Append to pending events for asynchronous disk write
  local record = {
    tick = os.time(),
    driverKey = key,
    player = playerDriverName or "Player",
    severity = severity or 1.0,
    lap = lap or 0
  }
  table.insert(_pendingEvents, record)
end

--- Get grievance level for an AI driver against player [0.0 ~ 10.0]
function M.getGrievance(aiDriverName)
  local key = getDriverKey(aiDriverName)
  local r = _rivalryDB[key]
  if r then return r.grievanceLevel or 0.0 end
  return 0.0
end

--- Flush pending events asynchronously to storage via adapter
function M.flush()
  if #_pendingEvents == 0 then return end
  if _adapter and _adapter.flush then
    _adapter.flush(_storageFile, _pendingEvents)
  end
  _pendingEvents = {}
end

return M
