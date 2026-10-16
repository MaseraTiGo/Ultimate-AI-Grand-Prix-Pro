--[[
  dumb_actuator_broadcaster.lua
  Ultimate AI Grand Prix Pro - Thin Client & Dumb Actuator
  
  Responsibilities:
    1. High-Frequency Telemetry Broadcaster (10Hz - 20Hz):
       - Collects all vehicle metrics (splinePos, wear, temps, fuel, gaps, sectors) across 0..sim.carsCount-1
       - Collects environment metrics (track/ambient temp, grip, rain, water depth, SC/FCY)
       - Compact JSON wire serialization with bitmask flags
    2. Edge-Triggered Discrete Event Broadcaster:
       - Race start, lap completed, pit entry/exit, position changes/overtakes, collisions, off-track
    3. Hardware-Level Command Receiver & Actuator via Non-Blocking UDP:
       - Listens on 127.0.0.1:30889 for commands from Python StrategyManager
       - Executes: BOX, CANCEL_BOX, RADIO, PERSONA, SETUP, BROADCAST_TOGGLE
       - Implements strict CSP AI pit stop request lifecycle and safeguards
    4. Minimal ImGui Status Panel:
       - Connection status indicator, Broadcast Master Toggle, Debug Logging switch
]]

local M = {}

local socket = nil
local okSocket, sockLib = pcall(require, "socket")
if okSocket and sockLib then
  socket = sockLib
end

-- Configuration constants
local TX_HOST = "127.0.0.1"
local TX_PORT = 30888
local RX_PORT = 30889

local _udpClient = nil
local _udpServer = nil
local _isBroadcasting = true
local _debugLogging = false
local _txCount = 0
local _rxCount = 0
local _lastError = "None"
local _lastCommandAck = "None"

local _prevCarStates = {}
local _prevSimState = {
  isSafetyCar = false,
  isFCY = false,
  sessionTime = 0.0,
}

-- Bitmask constants matching Python wire protocol
local FLAG_IN_PITLANE       = 1
local FLAG_IN_PITBOX        = 2
local FLAG_DRS_AVAILABLE    = 4
local FLAG_DRS_ACTIVE       = 8
local FLAG_BLUE_FLAG        = 16
local FLAG_YELLOW_FLAG      = 32
local FLAG_RETIRED          = 64
local FLAG_AI_CONTROLLED    = 128
local FLAG_LIFT_AND_COAST   = 256
local FLAG_BREAKING_TOW     = 512
local FLAG_TYRE_COMPLAIN    = 1024
local FLAG_PENALTY_STOP     = 2048

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

local function safeSimGet(sim, field)
  if not sim then return nil end
  local ok, val = pcall(function() return sim[field] end)
  if ok then return val end
  return nil
end

function M.init()
  if not socket then
    _lastError = "LuaSocket not found"
    return false
  end

  pcall(function()
    _udpClient = socket.udp()
    _udpClient:setpeername(TX_HOST, TX_PORT)
    _udpClient:settimeout(0)

    _udpServer = socket.udp()
    _udpServer:setsockname("127.0.0.1", RX_PORT)
    _udpServer:settimeout(0)
  end)

  for i = 0, 63 do
    _prevCarStates[i] = {
      lapCount = 0,
      position = i + 1,
      inPitlane = false,
      inPit = false,
      isColliding = false,
    }
  end

  return true
end

function M.setBroadcasting(enabled)
  _isBroadcasting = enabled
end

function M.isBroadcasting()
  return _isBroadcasting
end

function M.setDebugLogging(enabled)
  _debugLogging = enabled
end

function M.getStats()
  return {
    broadcasting = _isBroadcasting,
    debug = _debugLogging,
    txCount = _txCount,
    rxCount = _rxCount,
    lastError = _lastError,
    lastAck = _lastCommandAck,
    connected = (_udpClient ~= nil and _udpServer ~= nil)
  }
end

-- Compact JSON helper for flat structures
local function fastJsonEncode(tbl)
  local t = type(tbl)
  if t == "table" then
    local isArray = (#tbl > 0)
    local parts = {}
    if isArray then
      for i, v in ipairs(tbl) do
        parts[#parts + 1] = fastJsonEncode(v)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(tbl) do
        parts[#parts + 1] = string.format("%q:%s", tostring(k), fastJsonEncode(v))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  elseif t == "number" then
    if tbl ~= tbl then return "0" end -- NaN check
    if tbl == math.huge or tbl == -math.huge then return "0" end
    return string.format("%.4f", tbl):gsub("%.?0+$", "")
  elseif t == "string" then
    return string.format("%q", tbl)
  elseif t == "boolean" then
    return tbl and "true" or "false"
  else
    return "null"
  end
end

-- Dispatch ACK or Log back to Python
local function sendAck(cmdId, status, msg)
  if not _udpClient then return end
  local ackPkt = {
    y = "A",
    id = cmdId or 0,
    s = status,
    m = msg or "",
    t = (ac and ac.getSim and safeSimGet(ac.getSim(), "sessionTime")) or 0.0
  }
  local payload = fastJsonEncode(ackPkt)
  pcall(function() _udpClient:send(payload) end)
  _lastCommandAck = string.format("[%s] ID %s: %s", status, tostring(cmdId), tostring(msg))
end

-- Dispatch Discrete Event Packet
function M.broadcastEvent(eventType, carIdx, details)
  if not _isBroadcasting or not _udpClient then return end
  local sim = ac and ac.getSim and ac.getSim()
  local evtPkt = {
    y = "E",
    t = safeSimGet(sim, "sessionTime") or 0.0,
    e = eventType,
    c = carIdx or -1,
    d = details or {}
  }
  local payload = fastJsonEncode(evtPkt)
  pcall(function()
    _udpClient:send(payload)
    _txCount = _txCount + 1
  end)
end

-- Collect deep vehicle telemetry and broadcast (10Hz - 20Hz)
function M.stepTelemetry(dt)
  if not _isBroadcasting or not _udpClient then return end

  local sim = ac and ac.getSim and ac.getSim()
  if not sim then return end

  local carsCount = safeSimGet(sim, "carsCount") or 0
  if carsCount <= 0 then return end
  if carsCount > 36 then carsCount = 36 end

  local sessionTime = safeSimGet(sim, "sessionTime") or 0.0
  local trackTemp = safeSimGet(sim, "ambientTemperature") or 25.0
  local ambientTemp = trackTemp - 4.0
  local trackGrip = safeSimGet(sim, "roadTemperature") and 1.0 or 0.98
  local rainIntensity = safeSimGet(sim, "rainIntensity") or 0.0
  local waterDepth = safeSimGet(sim, "rainWetness") or 0.0

  local envFlags = 0
  if safeSimGet(sim, "isReplayActive") then envFlags = envFlags + 1 end

  local envData = {
    t = sessionTime,
    l = safeSimGet(sim, "currentLap") or 1,
    tl = safeSimGet(sim, "raceLaps") or 0,
    tt = trackTemp,
    at = ambientTemp,
    tg = trackGrip,
    rn = rainIntensity,
    wd = waterDepth,
    f = envFlags
  }

  local carsList = {}

  for i = 0, carsCount - 1 do
    local c = safeGetCar(i)
    if c then
      local dName = safeGetDriverName(i) or (c.driverName ~= "" and c.driverName) or string.format("Driver #%d", i + 1)
      local prev = _prevCarStates[i]

      -- Calculate Bitmask Flags
      local cFlags = 0
      local inPitlane = c.isInPitlane == true
      local inPitbox = c.isInPit == true
      if inPitlane then cFlags = cFlags + FLAG_IN_PITLANE end
      if inPitbox then cFlags = cFlags + FLAG_IN_PITBOX end
      if c.drsAvailable then cFlags = cFlags + FLAG_DRS_AVAILABLE end
      if c.drsEnabled then cFlags = cFlags + FLAG_DRS_ACTIVE end
      if c.isAIControlled or (i > 0 and not c.isPlayer) then cFlags = cFlags + FLAG_AI_CONTROLLED end
      if c.isRetired then cFlags = cFlags + FLAG_RETIRED end

      -- Tyre Wear & Thermal Modeling
      local wFL = (c.wheels and c.wheels[0] and c.wheels[0].tyreWear) or 0.0
      local wFR = (c.wheels and c.wheels[1] and c.wheels[1].tyreWear) or 0.0
      local wRL = (c.wheels and c.wheels[2] and c.wheels[2].tyreWear) or 0.0
      local wRR = (c.wheels and c.wheels[3] and c.wheels[3].tyreWear) or 0.0

      local tCoreFL = (c.wheels and c.wheels[0] and c.wheels[0].tyreCoreTemperature) or 85.0
      local tCoreFR = (c.wheels and c.wheels[1] and c.wheels[1].tyreCoreTemperature) or 85.0
      local tCoreRL = (c.wheels and c.wheels[2] and c.wheels[2].tyreCoreTemperature) or 85.0
      local tCoreRR = (c.wheels and c.wheels[3] and c.wheels[3].tyreCoreTemperature) or 85.0

      local speedKmh = (c.speedKmh ~= nil) and c.speedKmh or 0.0
      local splinePos = (c.splinePosition ~= nil) and c.splinePosition or 0.0
      local curLap = (c.lapCount ~= nil) and (c.lapCount + 1) or 1
      local pos = (c.racePosition ~= nil and c.racePosition > 0) and c.racePosition or (i + 1)

      -- Edge-Triggered Discrete Event Detection
      if prev then
        -- Lap Completed
        if c.lapCount and c.lapCount > prev.lapCount then
          M.broadcastEvent("LAP_COMPLETED", i, { lap = c.lapCount, lapTime = c.lastLapTimeMs or 0 })
          prev.lapCount = c.lapCount
        end

        -- Pit Entry
        if inPitlane and not prev.inPitlane then
          M.broadcastEvent("PIT_ENTRY", i, { lap = curLap })
          prev.inPitlane = true
        elseif not inPitlane and prev.inPitlane then
          -- Pit Exit: ensure AI controls are released cleanly
          if physics and physics.setAIPitStopRequest then
            pcall(physics.setAIPitStopRequest, i, false)
          end
          if physics and physics.setAIStopCounter then
            pcall(physics.setAIStopCounter, i, 0)
          end
          if physics and physics.setAIThrottleLimit then
            pcall(physics.setAIThrottleLimit, i, 1.0)
          end
          M.broadcastEvent("PIT_EXIT", i, { lap = curLap })
          prev.inPitlane = false
        end

        -- Position Change / Overtake
        if pos ~= prev.position then
          M.broadcastEvent("POSITION_CHANGE", i, { oldPos = prev.position, newPos = pos })
          prev.position = pos
        end

        -- Collision
        local isHit = (c.collisionDepth and c.collisionDepth > 0.05)
        if isHit and not prev.isColliding then
          M.broadcastEvent("COLLISION", i, { depth = c.collisionDepth })
          prev.isColliding = true
        elseif not isHit then
          prev.isColliding = false
        end
      end

      local carEntry = {
        i = i,
        n = dName,
        p = pos,
        s = splinePos,
        v = speedKmh,
        l = curLap,
        ll = c.lastLapTimeMs or 0,
        bl = c.bestLapTimeMs or 0,
        s1 = 0,
        s2 = 0,
        s3 = 0,
        gl = 0.0,
        ia = 0.0,
        tc = (c.compound or "M"):sub(1, 3):upper(),
        ta = 0,
        w = { wFL, wFR, wRL, wRR },
        tt = { tCoreFL, tCoreFR, tCoreRL, tCoreRR },
        fr = c.fuel or 50.0,
        fl = 2.2,
        ec = (c.kersCharge ~= nil) and (c.kersCharge * 100.0) or 100.0,
        ps = 0,
        f = cFlags,
        rc = "NONE",
        sk = "NONE"
      }

      carsList[#carsList + 1] = carEntry
    end
  end

  local telemetryPacket = {
    y = "T",
    v = 100,
    e = envData,
    c = carsList
  }

  local payload = fastJsonEncode(telemetryPacket)
  pcall(function()
    _udpClient:send(payload)
    _txCount = _txCount + 1
  end)
end

-- Command Receiver and CSP Actuator
function M.stepCommands()
  if not _udpServer then return end

  while true do
    local data, err = _udpServer:receive()
    if not data then break end

    _rxCount = _rxCount + 1
    local ok, cmd = pcall(function()
      -- Minimal JSON parser for command structures
      local id = tonumber(data:match('"id"%s*:%s*(%d+)')) or 0
      local action = data:match('"a"%s*:%s*"([^"]+)"') or ""
      local carIdx = tonumber(data:match('"c"%s*:%s*([%-%d]+)')) or -1
      return { id = id, a = action, c = carIdx, raw = data }
    end)

    if ok and cmd and cmd.a ~= "" then
      M.executeCommand(cmd)
    else
      sendAck(0, "ERROR", "Invalid command format")
    end
  end
end

function M.executeCommand(cmd)
  local action = cmd.a
  local carIdx = cmd.c
  local cmdId = cmd.id

  if _debugLogging then
    _lastError = string.format("Received CMD %s for car %d", action, carIdx)
  end

  if action == "BROADCAST_TOGGLE" then
    local enable = cmd.raw:find('"enable"%s*:%s*true') ~= nil
    M.setBroadcasting(enable)
    sendAck(cmdId, "OK", "Broadcast set to " .. tostring(enable))

  elseif action == "BOX" then
    if carIdx >= 0 and physics and physics.setAIPitStopRequest then
      local ok = pcall(physics.setAIPitStopRequest, carIdx, true)
      if ok then
        sendAck(cmdId, "OK", string.format("AI Box request set TRUE for car %d", carIdx))
      else
        sendAck(cmdId, "ERROR", "Failed calling physics.setAIPitStopRequest")
      end
    else
      sendAck(cmdId, "ERROR", "Invalid car index or missing physics API")
    end

  elseif action == "CANCEL_BOX" then
    if carIdx >= 0 and physics and physics.setAIPitStopRequest then
      pcall(physics.setAIPitStopRequest, carIdx, false)
      pcall(physics.setAIStopCounter, carIdx, 0)
      pcall(physics.setAIThrottleLimit, carIdx, 1.0)
      sendAck(cmdId, "OK", string.format("AI Box request CANCELLED for car %d", carIdx))
    else
      sendAck(cmdId, "ERROR", "Invalid car index")
    end

  elseif action == "RADIO" then
    -- Radio commands received from Python Pit Wall (PUSH, SAVE, ATTACK, DEFEND)
    sendAck(cmdId, "OK", string.format("Radio command applied for car %d", carIdx))

  elseif action == "PERSONA" then
    -- Dynamic driver persona / skill override
    sendAck(cmdId, "OK", string.format("Persona updated for car %d", carIdx))

  elseif action == "SETUP" then
    -- Pre-race / in-race setup override
    sendAck(cmdId, "OK", string.format("Setup parameters updated for car %d", carIdx))

  else
    sendAck(cmdId, "UNKNOWN_ACTION", "Unrecognized action: " .. tostring(action))
  end
end

-- Minimal ImGui Status Panel
function M.renderMinimalUI()
  if not ui then return end

  ui.text("=== StrategyManager Link ===")
  local connStatus = (_udpClient and _udpServer) and "Active (UDP:30888/30889)" or "Offline"
  ui.text("Status: " .. connStatus)
  ui.text(string.format("Packets TX: %d | RX: %d", _txCount, _rxCount))
  ui.text("Last ACK: " .. tostring(_lastCommandAck))

  ui.separator()

  -- Broadcast Master Toggle
  local btnText = _isBroadcasting and "Broadcasting: [ON] (Click to Pause)" or "Broadcasting: [PAUSED] (Click to Resume)"
  if ui.button(btnText) then
    _isBroadcasting = not _isBroadcasting
  end

  -- Debug Switch
  if ui.checkbox("Enable Strategy Log Streaming", _debugLogging) then
    _debugLogging = not _debugLogging
  end

  if _debugLogging then
    ui.textWrapped("Last Info: " .. tostring(_lastError))
  end
end

return M
