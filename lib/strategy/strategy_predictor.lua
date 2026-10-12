--[[
  strategy_predictor.lua
  Competitor Strategy Inference & Pit Window Prediction Model.
  Based strictly on observable data (laps completed, observed fuel burn rate, lap times, pit stops made).
  Does NOT cheat or access unobservable private variables.
  Outputs predictions like:
    "AI #12 (VER) -> likely pit L17 +/- 1 (Medium to Hard, 1-Stop)"
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

--[[
  predictCompetitorStrategy:
  @param competitorData:
    - carIndex: integer
    - driverName: string
    - observedLaps: integer
    - observedStopsCount: integer
    - totalRaceLaps: integer
    - observedFuelPerLap: number (from practice or tracker observation)
    - estimatedTankCapacity: number (e.g. 100L or from car.ini)
    - currentTyreCompound: string (if observable, else "MEDIUM")
    - lastPitLap: integer or nil
]]
function M.predictCompetitorStrategy(competitorData)
  local carIdx    = toNum(competitorData.carIndex, 0)
  local name      = competitorData.driverName or string.format("AI #%d", carIdx)
  local curLap    = toNum(competitorData.observedLaps, 1)
  local stopsDone = toNum(competitorData.observedStopsCount, 0)
  local totalLaps = toNum(competitorData.totalRaceLaps, 50)
  local fpl       = toNum(competitorData.observedFuelPerLap, 2.2)
  local tank      = toNum(competitorData.estimatedTankCapacity, 100.0)
  local lastLap   = toNum(competitorData.lastPitLap, 0)

  if fpl <= 0 then fpl = 2.2 end
  if totalLaps <= 0 then totalLaps = 50 end

  -- Fuel-limited max stint length
  local maxLapsFuel = math.max(1, math.floor((tank * 0.90) / fpl))

  -- Estimate optimal stops count for this car
  local neededStints = math.ceil(totalLaps / maxLapsFuel)
  local predictedStops = math.max(1, neededStints - 1)

  -- Calculate expected next stint length
  local remainingLaps = totalLaps - curLap
  local remainingStops = math.max(0, predictedStops - stopsDone)

  local expectedStintLaps = math.floor(totalLaps / (predictedStops + 1))
  local nextPitLap = (lastLap > 0) and (lastLap + expectedStintLaps) or expectedStintLaps

  -- Window is +/- 1 lap
  local windowOpen = math.max(curLap + 1, nextPitLap - 1)
  local windowClose = nextPitLap + 1

  local confidence = "HIGH"
  if competitorData.observedFuelPerLap == nil then
    confidence = "MEDIUM"
  end

  local summary = string.format("%s: likely pit L%d [L%d-L%d] (%d-stop plan, %s conf)",
    name, nextPitLap, windowOpen, windowClose, predictedStops, confidence)

  return {
    carIndex = carIdx,
    driverName = name,
    predictedNextPitLap = nextPitLap,
    windowOpenLap = windowOpen,
    windowCloseLap = windowClose,
    predictedTotalStops = predictedStops,
    confidence = confidence,
    summary = summary,
  }
end

return M
