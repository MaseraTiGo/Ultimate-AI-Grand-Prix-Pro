--[[
  strategy_evaluator.lua
  Post-race or in-race Strategy Quality & Opportunity Loss Evaluator.
  Analyzes:
    - Actual pit stop lap vs theoretical optimal lap
    - Strategy time delta / opportunity cost (seconds)
    - Safety Car decision benefit (seconds gained or missed)
    - Traffic delays experienced post-stop
    - Summarizes strategy execution efficiency (0 - 100%)
]]

local M = {}

local function toNum(v, def)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
  end
  return def
end

function M.createRaceStrategyLog(carIndex)
  return {
    carIndex = carIndex,
    plannedStops = 0,
    actualStops = 0,
    stopsHistory = {}, -- { stopNum, pitLap, plannedLap, tyreSet, fuelAdded, trafficPenalty, timeLostVsOptimal }
    safetyCarBoxes = 0,
    missedScOpportunities = 0,
    totalStrategyDeltaSec = 0.0,
  }
end

--[[
  recordStopExecution:
  Records a completed pit stop and calculates delta to optimal plan.
]]
function M.recordStopExecution(log, stopNum, actualLap, plannedLap, trafficPenaltySec, scPitted)
  if not log then return end
  actualLap = toNum(actualLap, 1)
  plannedLap = toNum(plannedLap, actualLap)
  trafficPenaltySec = toNum(trafficPenaltySec, 0.0)

  local lapDelta = math.abs(actualLap - plannedLap)
  -- Each lap away from optimal tyre/fuel window costs ~0.3s to 0.7s in stint pace
  local paceCost = lapDelta * 0.4
  local totalLoss = paceCost + trafficPenaltySec

  if scPitted then
    -- Pitting under SC saved approx 10.5 seconds vs green stop!
    totalLoss = totalLoss - 10.5
  end

  local entry = {
    stopNum = stopNum,
    actualLap = actualLap,
    plannedLap = plannedLap,
    lapDelta = lapDelta,
    trafficPenaltySec = trafficPenaltySec,
    timeLostVsOptimal = totalLoss,
    scPitted = scPitted,
  }

  table.insert(log.stopsHistory, entry)
  log.actualStops = log.actualStops + 1
  log.totalStrategyDeltaSec = log.totalStrategyDeltaSec + totalLoss
end

--[[
  generateStrategyReport:
  Generates readable summary of how well the race strategy performed.
]]
function M.generateStrategyReport(log)
  if not log or #log.stopsHistory == 0 then
    return {
      grade = "N/A",
      scorePct = 100,
      summary = "No pit stops executed yet",
    }
  end

  local netDelta = log.totalStrategyDeltaSec
  local scorePct = 100 - math.max(0, math.min(50, netDelta * 2.0))
  if netDelta < 0 then
    -- Strategy gained net time (e.g. brilliant SC timing or undercut!)
    scorePct = math.min(100, 100 + math.abs(netDelta) * 1.5)
  end

  local grade = "A"
  if scorePct < 70 then grade = "C"
  elseif scorePct < 85 then grade = "B"
  end

  local summary = string.format("Completed %d stop(s). Net strategy delta: %+.1fs (%s, %.0f%%)",
    log.actualStops, netDelta, grade, scorePct)

  return {
    grade = grade,
    scorePct = math.floor(scorePct + 0.5),
    netDeltaSeconds = math.floor(netDelta * 10 + 0.5) / 10,
    summary = summary,
  }
end

return M
