--[[
  lib/core/ControlTelemetry.lua
  Ultimate AI Grand Prix Pro - AI Control Telemetry Stream & Diagnostics Hook

  Responsibilities:
    - High-performance, zero-overhead control telemetry stream for diagnostics
    - Intercept and translate low-level CSP AI physics and control directives into
      human-readable, operator-friendly semantic statements (who, what, target parameters)
    - Exception and precondition failure tracking with prominent error visibility
    - Zero-overhead bypassing when stream is disabled
    - Per-car rate limiting and debouncing (2–4 Hz diagnostic sampling cap)
    - Persistent toggle state across UI tabs and game sessions
]]

local M = {}

local MAX_ENTRIES = 120
local THROTTLE_INTERVAL_SEC = 0.35 -- ~2.85 Hz per vehicle per category

local _enabled = false
local _entries = {}
local _head = 1
local _count = 0
local _lastActionTimes = {}   -- [carIdx][category] = timestamp
local _lastThrottleStates = {} -- [carIdx] = 0.0 or 1.0

-- Official F1 driver car numbers mapping
local F1_DRIVER_NUMBERS = {
  ["verstappen"] = 1, ["max verstappen"] = 1,
  ["norris"] = 4, ["lando norris"] = 4,
  ["gasly"] = 10, ["pierre gasly"] = 10,
  ["perez"] = 11, ["sergio perez"] = 11,
  ["alonso"] = 14, ["fernando alonso"] = 14,
  ["leclerc"] = 16, ["charles leclerc"] = 16,
  ["stroll"] = 18, ["lance stroll"] = 18,
  ["tsunoda"] = 22, ["yuki tsunoda"] = 22,
  ["albon"] = 23, ["alexander albon"] = 23,
  ["hulkenberg"] = 27, ["nico hulkenberg"] = 27,
  ["ocon"] = 31, ["esteban ocon"] = 31,
  ["hamilton"] = 44, ["lewis hamilton"] = 44,
  ["sainz"] = 55, ["carlos sainz"] = 55,
  ["russell"] = 63, ["george russell"] = 63,
  ["bottas"] = 77, ["valtteri bottas"] = 77,
  ["piastri"] = 81, ["oscar piastri"] = 81,
  ["zhou"] = 24, ["guanyu zhou"] = 24,
  ["ricciardo"] = 3, ["daniel ricciardo"] = 3,
  ["magnussen"] = 20, ["kevin magnussen"] = 20,
  ["sargeant"] = 2, ["logan sargeant"] = 2,
  ["bearman"] = 38, ["oliver bearman"] = 38,
  ["colapinto"] = 43, ["franco colapinto"] = 43,
  ["antonelli"] = 12, ["kimi antonelli"] = 12,
  ["lawson"] = 30, ["liam lawson"] = 30,
  ["doohan"] = 7, ["jack doohan"] = 7,
  ["hadjar"] = 6, ["isack hadjar"] = 6,
  ["bortoleto"] = 5, ["gabriel bortoleto"] = 5,
}

--- Initialize or restore persisted toggle state
function M.init()
  local persisted = false
  if ac and ac.storage then
    local st = ac.storage{ liveAiControlStream = false }
    if st and st.liveAiControlStream ~= nil then
      persisted = st.liveAiControlStream
    end
  end
  _enabled = persisted or false
  M.clear()
end

--- Query whether control telemetry streaming is active (hot loop inlineable)
---@return boolean
function M.isEnabled()
  return _enabled
end

--- Update streaming state and persist
---@param val boolean
function M.setEnabled(val)
  _enabled = (val == true)
  if ac and ac.storage then
    local st = ac.storage{ liveAiControlStream = false }
    if st then st.liveAiControlStream = _enabled end
  end
end

--- Format standardized timestamp [HH:mm:ss.fff]
---@param sessionSec number|nil
---@return string
function M.formatTimestamp(sessionSec)
  local wall = os.date("%H:%M:%S")
  local clockVal = sessionSec or os.clock()
  local ms = math.floor((clockVal % 1.0) * 1000)
  if ms < 0 then ms = 0 end
  if ms > 999 then ms = 999 end
  return string.format("%s.%03d", wall, ms)
end

--- Format driver tag: [#CarNum DriverName] (e.g. [#16 Leclerc], [#55 Sainz], [#1 Verstappen])
---@param carIdx number
---@param car table|nil
---@param driverName string|nil
---@return string
function M.formatDriverTag(carIdx, car, driverName)
  local cIdx = carIdx or 0
  local dName = driverName
  if (not dName or dName == "") and car and car.driverName then
    dName = car.driverName
  end
  if not dName or dName == "" then
    dName = (cIdx == 0) and "Player" or string.format("Driver #%02d", cIdx + 1)
  end

  local carNum = nil
  if car and car.carNumber and type(car.carNumber) == "number" and car.carNumber > 0 then
    carNum = car.carNumber
  elseif car and car.number and type(car.number) == "number" and car.number > 0 then
    carNum = car.number
  end

  if not carNum and dName then
    local lower = dName:lower()
    carNum = F1_DRIVER_NUMBERS[lower]
    if not carNum then
      local surname = lower:match("(%S+)$")
      if surname then
        carNum = F1_DRIVER_NUMBERS[surname]
      end
    end
  end

  if not carNum then
    carNum = cIdx + 1
  end

  local shortName = dName
  local lastWord = dName:match("%s+(%S+)$")
  if lastWord and not dName:find("^Driver #") and not dName:find("^Car #") and not dName:find("^AI") then
    shortName = lastWord
  end

  return string.format("[#%d %s]", carNum, shortName)
end

local function pushEntry(entry)
  _entries[_head] = entry
  _head = (_head % MAX_ENTRIES) + 1
  if _count < MAX_ENTRIES then
    _count = _count + 1
  end
end

--- Log a successful semantic control intervention
---@param carIdx number
---@param category string
---@param desc string
---@param car table|nil
---@param driverName string|nil
---@param force boolean|nil
function M.logAction(carIdx, category, desc, car, driverName, force)
  if not _enabled then return end

  local now = os.clock()
  local cIdx = carIdx or 0
  if not force then
    local carTimes = _lastActionTimes[cIdx]
    if not carTimes then
      carTimes = {}
      _lastActionTimes[cIdx] = carTimes
    end
    local lastT = carTimes[category]
    if lastT and (now - lastT) < THROTTLE_INTERVAL_SEC then
      return
    end
    carTimes[category] = now
  end

  local timeStr = M.formatTimestamp(now)
  local dTag = M.formatDriverTag(cIdx, car, driverName)
  local line = string.format("[%s] %s %s -> %s", timeStr, dTag, category, desc)

  pushEntry({
    time = now,
    timeStr = timeStr,
    isError = false,
    carIndex = cIdx,
    driverLabel = dTag,
    category = category,
    description = desc,
    formattedLine = line
  })
end

--- Log a failed control action or precondition rejection
---@param carIdx number
---@param actionDesc string
---@param reason string
---@param car table|nil
---@param driverName string|nil
function M.logError(carIdx, actionDesc, reason, car, driverName)
  if not _enabled then return end

  local now = os.clock()
  local cIdx = carIdx or 0
  local timeStr = M.formatTimestamp(now)
  local dTag = M.formatDriverTag(cIdx, car, driverName)
  local reasonStr = tostring(reason or "Unknown precondition error")
  local line = string.format("[%s] [ERROR] %s Action Failed: %s | Reason: %s", timeStr, dTag, actionDesc, reasonStr)

  pushEntry({
    time = now,
    timeStr = timeStr,
    isError = true,
    carIndex = cIdx,
    driverLabel = dTag,
    category = actionDesc,
    actionDesc = actionDesc,
    reason = reasonStr,
    description = string.format("Action Failed: %s | Reason: %s", actionDesc, reasonStr),
    formattedLine = line
  })
end

--------------------------------------------------------------------------------
-- Control Pipeline Wrappers & Interceptors (Zero-overhead when disabled)
--------------------------------------------------------------------------------

--- Intercept Lateral Spline Offset Intervention
function M.dispatchSplineOffset(carIdx, offset, isOverride, lateralDesc, car, driverName)
  local cIdx = carIdx or 0
  if not physics or not physics.setAISplineOffset then
    if _enabled then
      M.logError(cIdx, "Lateral Line Override", "CSP physics.setAISplineOffset API unavailable", car, driverName)
    end
    return false
  end

  if not _enabled then
    physics.setAISplineOffset(cIdx, offset, isOverride or false)
    return true
  end

  local ok, err = pcall(physics.setAISplineOffset, cIdx, offset, isOverride or false)
  if not ok then
    M.logError(cIdx, "Lateral Line Override", tostring(err), car, driverName)
    return false
  end

  local category = "Defensive Bias"
  local desc = lateralDesc
  if not desc then
    if offset < -0.05 then
      desc = "Set defensive lateral offset (Holding inside line)"
    elseif offset > 0.05 then
      desc = "Set defensive lateral offset (Guarding outer lane)"
    else
      desc = "Centered on primary racing line"
    end
  end
  if desc:find("Attack") or desc:find("Pass") or desc:find("Dive") or desc:find("feint") or desc:find("Feint") then
    category = "Attack Trajectory"
  end

  M.logAction(cIdx, category, desc, car, driverName)
  return true
end

--- Intercept Pace & Aggression Overrides
function M.dispatchPace(carIdx, aggression, caution, paceTargetPct, paceDesc, car, driverName)
  local cIdx = carIdx or 0
  local hasAgg = physics and physics.setAIAggression
  local hasCaut = physics and physics.setAICaution

  if not hasAgg and not hasCaut then
    if _enabled then
      M.logError(cIdx, "Pace Override", "CSP physics.setAIAggression/setAICaution unavailable", car, driverName)
    end
    return false
  end

  if not _enabled then
    if hasAgg and aggression then physics.setAIAggression(cIdx, aggression) end
    if hasCaut and caution then physics.setAICaution(cIdx, caution) end
    return true
  end

  local okAgg, errAgg = true, nil
  if hasAgg and aggression then
    okAgg, errAgg = pcall(physics.setAIAggression, cIdx, aggression)
  end

  local okCaut, errCaut = true, nil
  if hasCaut and caution then
    okCaut, errCaut = pcall(physics.setAICaution, cIdx, caution)
  end

  if not okAgg or not okCaut then
    M.logError(cIdx, "Pace Override", tostring(errAgg or errCaut), car, driverName)
    return false
  end

  local pct = paceTargetPct or math.floor((aggression or 0.75) * 100)
  local descText = paceDesc
  if not descText then
    if pct >= 95 then
      descText = "(Pushing lap)"
    elseif pct <= 75 then
      descText = "(Fuel saving cruise)"
    else
      descText = "(Standard race pace)"
    end
  end

  M.logAction(cIdx, "Pace Override", string.format("Set race pace target to %d%% %s", pct, descText), car, driverName)
  return true
end

--- Intercept Pit Directives (BOX instruction & lifecycle)
function M.dispatchPitStopRequest(carIdx, request, compoundName, fuelLiters, car, driverName)
  local cIdx = carIdx or 0
  if not physics or not physics.setAIPitStopRequest then
    if _enabled then
      M.logError(cIdx, "Pit Stop Directive", "CSP physics.setAIPitStopRequest API is unavailable", car, driverName)
    end
    return false
  end

  if request and car and (car.isInPitlane or car.isInPit) then
    if _enabled then
      M.logError(cIdx, "Pit Stop Directive", "Vehicle already committed in pit lane", car, driverName)
    end
    -- Still proceed with call for robustness
  end

  if not _enabled then
    physics.setAIPitStopRequest(cIdx, request)
    return true
  end

  local ok, err = pcall(physics.setAIPitStopRequest, cIdx, request)
  if not ok then
    M.logError(cIdx, "Pit Stop Directive", tostring(err), car, driverName)
    return false
  end

  if request then
    local compStr = compoundName or "Hard"
    local fuelStr = (fuelLiters and fuelLiters > 0) and string.format("%dL", math.floor(fuelLiters)) or "42L"
    M.logAction(cIdx, "Pit Control", string.format("Instructed to box this lap (Compound: %s, Fuel: %s)", compStr, fuelStr), car, driverName, true)
  else
    M.logAction(cIdx, "Pit Control", "Cleared pit stop request flag (Pit lane exit complete)", car, driverName, true)
  end
  return true
end

--- Intercept Throttle Limit & Lift-and-Coast Modulation
function M.dispatchThrottleLimit(carIdx, throttleLimit, throttleDesc, car, driverName)
  local cIdx = carIdx or 0
  if not physics or not physics.setAIThrottleLimit then
    if _enabled then
      M.logError(cIdx, "Throttle Modulation", "CSP physics.setAIThrottleLimit API unavailable", car, driverName)
    end
    return false
  end

  if not _enabled then
    physics.setAIThrottleLimit(cIdx, throttleLimit)
    return true
  end

  local lastVal = _lastThrottleStates[cIdx]
  -- Only log discrete transitions for throttle limit
  local isTransition = (lastVal == nil) or (math.abs(lastVal - throttleLimit) > 0.5)
  _lastThrottleStates[cIdx] = throttleLimit

  local ok, err = pcall(physics.setAIThrottleLimit, cIdx, throttleLimit)
  if not ok then
    M.logError(cIdx, "Throttle Modulation", tostring(err), car, driverName)
    return false
  end

  if isTransition then
    if throttleLimit <= 0.05 then
      M.logAction(cIdx, "Throttle Management", throttleDesc or "Engaged Lift and Coast into braking zone (Saving fuel & tyres)", car, driverName, true)
    elseif throttleLimit >= 0.95 then
      M.logAction(cIdx, "Throttle Management", throttleDesc or "Restored 100% full throttle delivery", car, driverName, true)
    end
  end
  return true
end

--- Log Energy Deployment (DRS / ERS Overtake Boost)
function M.logEnergyDeployment(carIdx, modeDesc, car, driverName)
  if not _enabled then return end
  local cIdx = carIdx or 0
  local desc = modeDesc or "Deployed overtake boost mode"
  M.logAction(cIdx, "Energy Deployment", desc, car, driverName, true)
end

--- Log Fuel Delivery
function M.dispatchCarFuel(carIdx, fuelLiters, car, driverName)
  local cIdx = carIdx or 0
  if not physics or not physics.setCarFuel then
    if _enabled then
      M.logError(cIdx, "Fuel Delivery", "CSP physics.setCarFuel API unavailable", car, driverName)
    end
    return false
  end

  if not _enabled then
    physics.setCarFuel(cIdx, fuelLiters)
    return true
  end

  local ok, err = pcall(physics.setCarFuel, cIdx, fuelLiters)
  if not ok then
    M.logError(cIdx, "Fuel Delivery", tostring(err), car, driverName)
    return false
  end

  M.logAction(cIdx, "Fuel Delivery", string.format("Refueled %dL into fuel cell", math.floor(fuelLiters)), car, driverName, true)
  return true
end

--- Log Tyre Compound Fitting
function M.dispatchAITyres(carIdx, compoundIdx, compoundName, car, driverName)
  local cIdx = carIdx or 0
  if not physics or not physics.setAITyres then
    if _enabled then
      M.logError(cIdx, "Tyre Fitting", "CSP physics.setAITyres API unavailable", car, driverName)
    end
    return false
  end

  if not _enabled then
    physics.setAITyres(cIdx, compoundIdx)
    return true
  end

  local ok, err = pcall(physics.setAITyres, cIdx, compoundIdx)
  if not ok then
    M.logError(cIdx, "Tyre Fitting", tostring(err), car, driverName)
    return false
  end

  local cName = compoundName or string.format("Compound #%d", compoundIdx)
  M.logAction(cIdx, "Tyre Fitting", string.format("Fitted fresh set of %s tyres", cName), car, driverName, true)
  return true
end

--- Retrieve recent entries from circular buffer (ordered oldest to newest)
---@param maxCount number|nil
---@return table
function M.getRecentEntries(maxCount)
  local countToFetch = math.min(_count, maxCount or MAX_ENTRIES)
  local list = {}
  local outIdx = 1
  for i = 1, countToFetch do
    local offset = _count - countToFetch + i
    local readIndex = (_head - 1 - _count + offset)
    while readIndex <= 0 do readIndex = readIndex + MAX_ENTRIES end
    while readIndex > MAX_ENTRIES do readIndex = readIndex - MAX_ENTRIES end
    list[outIdx] = _entries[readIndex]
    outIdx = outIdx + 1
  end
  return list
end

--- Clear buffer entries
function M.clear()
  _entries = {}
  _head = 1
  _count = 0
  _lastActionTimes = {}
  _lastThrottleStates = {}
end

--- Complete reset
function M.reset()
  M.clear()
  _enabled = false
end

return M
