--[[
  traffic_model.lua
  Track Position, Traffic Density, Gap Analysis and Clean Air Window modeling.
  Evaluates:
    - Distance/gap to car ahead and behind
    - Projected pit exit traffic window (rejoining in dirty air vs clean air)
    - Traffic penalty loss in seconds per lap
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

-- Typical pit lane loss time across road courses (seconds) if track-specific data is absent
M.DEFAULT_PIT_LANE_LOSS_SEC = 22.0

--[[
  analyzeCarSurroundings:
  Estimates track position and proximity to neighbors.
  @param myCarIndex: index of car
  @param carsList: table of { index, splinePosition (0..1), lapCount, speedKmh }
]]
function M.analyzeCarSurroundings(myCarIndex, carsList)
  if not carsList or #carsList == 0 then
    return {
      gapAheadSec = 999.0,
      gapBehindSec = 999.0,
      inDirtyAir = false,
      trafficDensity = 0.0,
      aheadCarIndex = nil,
      behindCarIndex = nil,
    }
  end

  local myCar = nil
  for _, c in ipairs(carsList) do
    if c.index == myCarIndex then
      myCar = c
      break
    end
  end

  if not myCar or not myCar.splinePosition then
    return {
      gapAheadSec = 999.0,
      gapBehindSec = 999.0,
      inDirtyAir = false,
      trafficDensity = 0.0,
    }
  end

  local myPos = myCar.splinePosition
  local minAheadDist = 1.0
  local minBehindDist = 1.0
  local aheadIdx = nil
  local behindIdx = nil
  local carsWithin100m = 0

  for _, c in ipairs(carsList) do
    if c.index ~= myCarIndex and c.splinePosition then
      -- Positive delta is ahead, negative is behind
      local delta = c.splinePosition - myPos
      if delta < -0.5 then delta = delta + 1.0 end
      if delta > 0.5 then delta = delta - 1.0 end

      if delta > 0 and delta < minAheadDist then
        minAheadDist = delta
        aheadIdx = c.index
      elseif delta < 0 and (-delta) < minBehindDist then
        minBehindDist = -delta
        behindIdx = c.index
      end

      -- If spline distance is under ~0.02 (approx 100m on a 5km track), count towards local density
      if math.abs(delta) < 0.025 then
        carsWithin100m = carsWithin100m + 1
      end
    end
  end

  -- Assume average lap time is ~90 seconds for spline-to-second conversion if lap time unavailable
  local approxLapSec = 90.0
  local gapAheadSec = math.floor(minAheadDist * approxLapSec * 10 + 0.5) / 10
  local gapBehindSec = math.floor(minBehindDist * approxLapSec * 10 + 0.5) / 10

  -- Following within 1.8s is considered dirty air
  local inDirtyAir = gapAheadSec < 1.8
  local trafficDensity = math.min(1.0, carsWithin100m / 3.0)

  return {
    gapAheadSec = gapAheadSec,
    gapBehindSec = gapBehindSec,
    inDirtyAir = inDirtyAir,
    trafficDensity = trafficDensity,
    aheadCarIndex = aheadIdx,
    behindCarIndex = behindIdx,
  }
end

--[[
  evaluatePitExitTrafficWindow:
  Simulates where a car will exit relative to the field after serving a pit stop.
  @param mySplinePos: current position on track (0..1)
  @param pitLossSeconds: total time lost in pit lane (stop + traverse, e.g. 24s)
  @param lapTimeSeconds: typical lap time (e.g. 90s)
  @param carsList: all other active cars with splinePosition
]]
function M.evaluatePitExitTrafficWindow(mySplinePos, pitLossSeconds, lapTimeSeconds, carsList)
  pitLossSeconds = toNum(pitLossSeconds, M.DEFAULT_PIT_LANE_LOSS_SEC)
  lapTimeSeconds = math.max(30.0, toNum(lapTimeSeconds, 90.0))
  mySplinePos = toNum(mySplinePos, 0.0)

  -- Fraction of a lap lost in pits
  local lapFractionLost = (pitLossSeconds / lapTimeSeconds)
  local exitSplinePos = (mySplinePos - lapFractionLost) % 1.0

  if not carsList or #carsList <= 1 then
    return {
      cleanExitWindow = true,
      exitTrafficPenaltySec = 0.0,
      nearbyCarsAtExit = 0,
      exitSplinePos = exitSplinePos,
    }
  end

  local nearbyCars = 0
  for _, c in ipairs(carsList) do
    if c.splinePosition then
      local delta = math.abs(c.splinePosition - exitSplinePos)
      if delta > 0.5 then delta = 1.0 - delta end
      -- Within 2 seconds of exit (~0.022 on a 90s lap)
      if delta < (2.0 / lapTimeSeconds) then
        nearbyCars = nearbyCars + 1
      end
    end
  end

  local cleanExit = (nearbyCars == 0)
  -- Each car blocking pit exit causes ~0.6s to 1.2s delay in the out-lap
  local exitPenalty = nearbyCars * 0.8

  return {
    cleanExitWindow = cleanExit,
    exitTrafficPenaltySec = exitPenalty,
    nearbyCarsAtExit = nearbyCars,
    exitSplinePos = exitSplinePos,
  }
end

return M
