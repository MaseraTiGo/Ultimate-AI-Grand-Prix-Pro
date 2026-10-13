--[[
  lib/core/RaceContext.lua
  Ultimate AI Grand Prix Pro - Unified Single Source of Truth for Race State
  
  Responsibilities:
    - Centralize session time, laps, flags, Safety Car status, weather/track status
    - Preallocated per-car status cache (0 to 63)
    - Zero dynamic memory allocation in 10Hz/60Hz query paths
]]

local M = {}

local MAX_CARS = 24

M.FLAG_GREEN  = "GREEN"
M.FLAG_YELLOW = "YELLOW"
M.FLAG_SC     = "SC"
M.FLAG_VSC    = "VSC"
M.FLAG_RED    = "RED"

local _raceState = {
  sessionType = "RACE",
  totalLaps = 13,
  currentLap = 1,
  sessionTime = 0.0,
  flagState = M.FLAG_GREEN,
  scActive = false,
  isReplay = false,
  carsCount = 0,
  playerIndex = 0,
  leaderIndex = 0,
  leaderSpeedKmh = 200.0,
  trackLengthM = 5000.0,
}

local _carStates = {}
for i = 0, MAX_CARS - 1 do
  _carStates[i] = {
    index = i,
    driverName = "",
    carName = "",
    isAIControlled = true,
    isConnected = false,
    
    -- Spatial & Motion
    posX = 0.0, posY = 0.0, posZ = 0.0,
    speedKmh = 0.0,
    splinePos = 0.0,
    lapCount = 0,
    positionInRace = i + 1,
    isInPitlane = false,
    isInPit = false,
    
    -- Fuel & Tyres
    fuelInTank = 30.0,
    maxFuelCapacity = 100.0,
    fuelPerLap = 2.5,
    tyreWear = 0.0,       -- 0.0 (new) ~ 1.0 (dead)
    tyreCompound = "MEDIUM",
    tyreLapsAge = 0,
    tyreWarmupProgress = 1.0, -- 0.0 (ice cold) ~ 1.0 (optimal)
    tyreTempNorm = 1.0,       -- 1.0 = nominal, >1.3 = cooked / overheated

    -- Dynamic Racecraft & Strategy Integration
    tacticalState = "CRUISE",
    activeSkill = "NONE",
    stress = 0.0,
    momentum = 0.0,
    isInFlow = false,
    isTilting = false,
    isLiftAndCoast = false,
    isBreakingTow = false,
    
    -- Pit Strategy & Authority
    plannedStops = 1,
    currentStint = 1,
    targetPitLap = 15,
    openPitLap = 13,
    escalatePitLap = 18,
    actualStopsCount = 0,
    lastPitLap = -1,
    radioCommand = "NONE",     -- "NONE", "PUSH", "SAVE", "BOX_THIS_LAP", "DEFEND"
    radioOrderActive = false,
  }
end

function M.getRaceState()
  return _raceState
end

function M.setTotalLaps(laps)
  if laps and laps > 0 then
    _raceState.totalLaps = math.floor(laps)
  end
end

function M.getCarState(carIndex)
  return _carStates[carIndex] or _carStates[0]
end

function M.getAllCarStates()
  return _carStates
end

local function safeGetCar(idx)
  if not ac or not ac.getCar or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getCar, idx)
  if ok and res then return res end
  return nil
end

--- Safely query a field from a CSP C-struct or table without throwing FFI member errors
local function safeSimGet(sim, field)
  if not sim or not field then return nil end
  local ok, val = pcall(function() return sim[field] end)
  if ok then return val end
  return nil
end
M.safeSimGet = safeSimGet

--- Safely resolve current session time in seconds
local function getSimSessionTime(sim)
  if not sim then return 0.0 end
  -- 1. Try gameTime (in seconds from AC start, standard official CSP field)
  local gt = safeSimGet(sim, "gameTime")
  if gt and gt > 0 then return gt end
  -- 2. Try currentSessionTime (in ms -> sec, synced session time in online/offline)
  local cst = safeSimGet(sim, "currentSessionTime")
  if cst and cst > 0 then return cst / 1000.0 end
  -- 3. Try time (in ms -> sec)
  local t = safeSimGet(sim, "time")
  if t and t > 0 then return t / 1000.0 end
  -- 4. Try sessionTime (mock/fallback)
  local st = safeSimGet(sim, "sessionTime")
  if st and st > 0 then return st end
  return (os and os.clock and os.clock()) or 0.0
end
M.getSimSessionTime = getSimSessionTime

local function safeGetDriverName(idx)
  if not ac or not ac.getDriverName or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getDriverName, idx)
  if ok and res and res ~= "" then return res end
  return nil
end

--- Update global race state snapshot once per frame (10Hz / 1Hz)
function M.updateFromSim(sim)
  if not sim then return end
  _raceState.isReplay = (safeSimGet(sim, "isReplayActive") == true)
  _raceState.sessionTime = getSimSessionTime(sim)

  -- Count connected cars: safely from sim.carsCount and bounded probing
  local simCars = safeSimGet(sim, "carsCount") or 0
  if simCars == 0 and ac and ac.getSim then
    local okSim, s = pcall(ac.getSim)
    if okSim and s then
      simCars = safeSimGet(s, "carsCount") or 0
    end
  end

  local probedCount = 0
  local maxProbe = (simCars > 0) and math.min(simCars, MAX_CARS) or MAX_CARS
  for probeIdx = 0, maxProbe - 1 do
    local probeCar = safeGetCar(probeIdx)
    if probeCar then
      probedCount = probedCount + 1
    else
      if simCars == 0 then break end
    end
  end

  _raceState.carsCount = math.max(simCars, probedCount)
  if _raceState.carsCount > MAX_CARS then _raceState.carsCount = MAX_CARS end

  -- Dynamic Session Laps:
  -- 1. Try official CSP ac.getSession(sim.currentSessionIndex).laps
  local laps = nil
  if ac and ac.getSession then
    local sessIdx = safeSimGet(sim, "currentSessionIndex") or 0
    local ok, sess = pcall(ac.getSession, sessIdx)
    if ok and sess then
      local sLaps = safeSimGet(sess, "laps")
      if sLaps and sLaps > 0 then laps = sLaps end
    end
  end
  -- 2. Fallbacks: safe query of raceLaps, sessionLaps, totalLaps, laps
  if not laps or laps <= 0 then
    laps = safeSimGet(sim, "raceLaps")
      or safeSimGet(sim, "sessionLaps")
      or safeSimGet(sim, "totalLaps")
      or safeSimGet(sim, "laps")
  end

  if laps and laps > 0 then
    if _raceState.totalLaps ~= laps then
      _raceState.totalLaps = laps
      local StrategyCoordinator = package.loaded["lib/strategy/StrategyCoordinator"]
      if StrategyCoordinator and StrategyCoordinator.rebuildFieldStrategy then
        pcall(StrategyCoordinator.rebuildFieldStrategy, laps, nil, nil)
      end
    end
  end

  -- Current Lap:
  -- In CSP, leaderLapCount is completed laps by leader (0-indexed). So current lap = leaderLapCount + 1.
  local leaderCompleted = safeSimGet(sim, "leaderLapCount")
  local currentLap = nil
  if leaderCompleted and leaderCompleted >= 0 then
    currentLap = leaderCompleted + 1
  else
    local c0 = safeGetCar(0)
    if c0 and c0.lapCount and c0.lapCount >= 0 then
      currentLap = c0.lapCount + 1
    else
      currentLap = safeSimGet(sim, "currentLap") or _raceState.currentLap or 1
    end
  end

  -- Flags & Safety Car Edge Detection:
  -- CSP official: sim.raceFlagType (ac.FlagType.Caution = 2, ac.FlagType.FasterCar = 12, ac.FlagType.Finished = 13)
  local raceFlagType = safeSimGet(sim, "raceFlagType")
  local prevFlag = _raceState.flagState
  local isYellow = (raceFlagType == 2) or (safeSimGet(sim, "isYellowFlag") == true) or (safeSimGet(sim, "hasYellowFlag") == true)
  local isSC = (safeSimGet(sim, "safetyCarActive") == true) or (safeSimGet(sim, "isSafetyCar") == true)

  if isYellow then
    _raceState.flagState = M.FLAG_YELLOW
  elseif isSC then
    _raceState.flagState = M.FLAG_SC
    _raceState.scActive = true
  else
    _raceState.flagState = M.FLAG_GREEN
    _raceState.scActive = false
  end

  -- Blue flag tracking
  if raceFlagType == 12 then -- ac.FlagType.FasterCar
    _raceState.blueFlagCarIdx = safeSimGet(sim, "raceFlagCause") or -1
  else
    _raceState.blueFlagCarIdx = -1
  end

  local EventHub = package.loaded["lib/core/EventHub"]
  if EventHub and prevFlag ~= _raceState.flagState then
    if _raceState.flagState == M.FLAG_YELLOW then
      EventHub.pushAiEvent(0, "FLAG", "【全场黄旗】赛道出现危险状况，全场黄旗生效！禁止超车！", "WORLD", _raceState.sessionTime)
    elseif _raceState.flagState == M.FLAG_SC then
      EventHub.pushAiEvent(0, "FLAG", "【安全车出动】Safety Car 出动压车，各车队进入紧急进站窗口！", "WORLD", _raceState.sessionTime)
    elseif _raceState.flagState == M.FLAG_GREEN and prevFlag ~= M.FLAG_GREEN then
      EventHub.pushAiEvent(0, "FLAG", "【绿旗恢复】赛道险情解除，绿旗行车！比赛恢复全力推进！", "WORLD", _raceState.sessionTime)
    end
  end

  -- Lap progression edge detection
  local prevLap = _raceState.currentLap or 1
  if EventHub and currentLap > prevLap and prevLap > 0 then
    _raceState.currentLap = currentLap
    local totalStr = (_raceState.totalLaps and _raceState.totalLaps > 0) and string.format("/%d 圈", _raceState.totalLaps) or ""
    EventHub.pushAiEvent(0, "RACE", string.format("【赛程更新】头车冲线，比赛正式进入第 %d 圈%s！", currentLap, totalStr), "WORLD", _raceState.sessionTime)
  else
    _raceState.currentLap = currentLap
  end

  -- Eager driver name sync from AC (strictly bound within known car count)
  local maxSync = math.min(_raceState.carsCount, MAX_CARS)
  for idx = 0, maxSync - 1 do
    local dName = safeGetDriverName(idx)
    if dName and dName ~= "" then
      _carStates[idx].driverName = dName
    end
  end
end

--- Update per-car state snapshot from AC car object (Pure scalar, zero-alloc)
function M.updateCarFromAc(carIndex, c)
  if not c or carIndex < 0 or carIndex >= MAX_CARS then return end
  local s = _carStates[carIndex]
  s.isConnected = c.isConnected ~= false
  s.isAIControlled = (c.isAIControlled == true) or (carIndex > 0 and not c.isPlayer)
  s.speedKmh = c.speedKmh or 0.0
  s.splinePos = c.splinePosition or 0.0
  s.lapCount = c.lapCount or 0
  s.positionInRace = c.racePosition or (carIndex + 1)

  local wasInPitlane = s.isInPitlane
  local wasInPit = s.isInPit
  s.isInPitlane = c.isInPitlane == true
  s.isInPit = c.isInPit == true
  local isNowInPit = s.isInPitlane or s.isInPit
  local wasInAnyPit = wasInPitlane or wasInPit

  local EventHub = package.loaded["lib/core/EventHub"]
  local StrategyCoordinator = package.loaded["lib/strategy/StrategyCoordinator"]

  -- Edge 1: Vehicle entering pitlane / pit bay
  if not wasInAnyPit and isNowInPit then
    local dLabel = EventHub and EventHub.formatDriverLabel(carIndex, s.driverName) or string.format("Car #%02d", carIndex + 1)
    s.pit_requested = false
    s.pit_stop_planned = false
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tacticalState = "PIT_BAY"

    if StrategyCoordinator and StrategyCoordinator.getCarPlan then
      local plan = StrategyCoordinator.getCarPlan(carIndex)
      if plan then
        plan.activeRecommendation = "NONE"
        plan.pitInHandled = true
        local curLap = _raceState.currentLap or 1
        local nextStintLaps = (plan.stints and plan.stints[2]) or 15
        plan.targetLap = curLap + nextStintLaps
        plan.openLap = math.max(curLap + 1, plan.targetLap - 2)
        plan.escalateLap = plan.targetLap + 2
      end
    end

    if EventHub then
      EventHub.pushAiEvent(carIndex, "PIT", string.format("【进站作业】%s 已平稳驶入维修区，车组人员开始换胎与补油！", dLabel), "STRATEGY", _raceState.sessionTime)
      EventHub.settleCarPitCommands(carIndex, dLabel)
    end
  end

  -- Continuous invariant: while inside pitlane / pit box, stay cleared
  if isNowInPit then
    s.pit_requested = false
    s.pit_stop_planned = false
    if s.radioCommand == "BOX_THIS_LAP" then
      s.radioCommand = "NONE"
      s.radioOrderActive = false
    end
    if s.tacticalState ~= "PIT_BAY" then
      s.tacticalState = "PIT_BAY"
    end
  end

  -- Edge 2: Vehicle exiting pitlane back to track
  if wasInAnyPit and not isNowInPit then
    local dLabel = EventHub and EventHub.formatDriverLabel(carIndex, s.driverName) or string.format("Car #%02d", carIndex + 1)
    s.pit_requested = false
    s.pit_stop_planned = false
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tacticalState = "CRUISE"

    if StrategyCoordinator and StrategyCoordinator.getCarPlan then
      local plan = StrategyCoordinator.getCarPlan(carIndex)
      if plan then
        plan.activeRecommendation = "NONE"
        plan.pitInHandled = false
      end
    end

    if EventHub then
      EventHub.pushAiEvent(carIndex, "PIT", string.format("【出站重返】%s 进站作业完成，重返赛道全力推进！", dLabel), "STRATEGY", _raceState.sessionTime)
    end
  end

  s.fuelInTank = c.fuel or s.fuelInTank

  local dName = safeGetDriverName(carIndex)
  if dName and dName ~= "" then
    s.driverName = dName
  end
  if (not s.driverName or s.driverName == "") and c then
    local okName, cn = pcall(function()
      if type(c.driverName) == "function" then return c:driverName() end
      if type(c.driverName) == "string" then return c.driverName end
      return nil
    end)
    if okName and cn and type(cn) == "string" and cn ~= "" then
      s.driverName = cn
    end
  end

  if c.position then
    s.posX = c.position.x or 0.0
    s.posY = c.position.y or 0.0
    s.posZ = c.position.z or 0.0
  end

  if c.tyres and c.tyres[0] and c.tyres[0].wear then
    s.tyreWear = c.tyres[0].wear
  end
end

function M.reset()
  _raceState.currentLap = 1
  _raceState.flagState = M.FLAG_GREEN
  _raceState.scActive = false
  for i = 0, MAX_CARS - 1 do
    local s = _carStates[i]
    s.lapCount = 0
    s.actualStopsCount = 0
    s.lastPitLap = -1
    s.stress = 0.0
    s.momentum = 0.0
    s.radioCommand = "NONE"
    s.radioOrderActive = false
    s.tyreWarmupProgress = 1.0
    s.tyreTempNorm = 1.0
  end
end

M.MAX_CARS = MAX_CARS

-- Spatial Topology Neighbor Ring (Pure scalar, 24 cars)
-- preallocated flat lookup arrays
local _topoAheadIndex = {}
local _topoBehindIndex = {}
local _topoDistAhead = {}
local _topoDistBehind = {}

for i = 0, MAX_CARS - 1 do
  _topoAheadIndex[i] = -1
  _topoBehindIndex[i] = -1
  _topoDistAhead[i] = 999.0
  _topoDistBehind[i] = 999.0
end

--- Update 24-car pairwise topology using track spline position
--- Runs in 10Hz tactical loop before vehicle steps (O(N) scalar distance checks, ~0.01ms)
function M.updateTopology(carsCount, acGetCar)
  local count = math.min(MAX_CARS, carsCount or 0)
  for i = 0, count - 1 do
    _topoAheadIndex[i] = -1
    _topoBehindIndex[i] = -1
    _topoDistAhead[i] = 999.0
    _topoDistBehind[i] = 999.0
  end

  if count < 2 then return end

  for i = 0, count - 1 do
    local okI, carI = pcall(acGetCar, i)
    if okI and carI and carI.isConnected ~= false and carI.position then
      local sI = carI.splinePosition or 0.0
      local pxI = carI.position.x or 0.0
      local pyI = carI.position.y or 0.0
      local pzI = carI.position.z or 0.0

      local bestAheadIdx = -1
      local minAheadDist = 999.0
      local bestBehindIdx = -1
      local minBehindDist = 999.0

      for j = 0, count - 1 do
        if i ~= j then
          local okJ, carJ = pcall(acGetCar, j)
          if okJ and carJ and carJ.isConnected ~= false and carJ.position then
            local dx = carJ.position.x - pxI
            local dy = carJ.position.y - pyI
            local dz = carJ.position.z - pzI
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            
            if dist < 65.0 then -- Focus bubble (65m proximity)
              local sJ = carJ.splinePosition or 0.0
              -- Spline forward distance with wrap-around [0, 1]
              local sDiff = sJ - sI
              if sDiff < -0.5 then sDiff = sDiff + 1.0
              elseif sDiff > 0.5 then sDiff = sDiff - 1.0 end

              if sDiff > 0.0 then
                -- carJ is ahead of carI
                if dist < minAheadDist then
                  minAheadDist = dist
                  bestAheadIdx = j
                end
              elseif sDiff < 0.0 then
                -- carJ is behind carI
                if dist < minBehindDist then
                  minBehindDist = dist
                  bestBehindIdx = j
                end
              end
            end
          end
        end
      end

      _topoAheadIndex[i] = bestAheadIdx
      _topoDistAhead[i] = minAheadDist
      _topoBehindIndex[i] = bestBehindIdx
      _topoDistBehind[i] = minBehindDist
    end
  end
end

--- Query topological neighbors for carIndex
---@param carIndex integer
---@return integer aheadIdx, number aheadDist, integer behindIdx, number behindDist
function M.getNeighbors(carIndex)
  if carIndex < 0 or carIndex >= MAX_CARS then
    return -1, 999.0, -1, 999.0
  end
  return _topoAheadIndex[carIndex] or -1,
         _topoDistAhead[carIndex] or 999.0,
         _topoBehindIndex[carIndex] or -1,
         _topoDistBehind[carIndex] or 999.0
end

return M
