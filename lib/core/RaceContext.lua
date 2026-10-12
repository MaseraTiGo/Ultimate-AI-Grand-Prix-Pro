--[[
  lib/core/RaceContext.lua
  Ultimate AI Grand Prix Pro - Unified Single Source of Truth for Race State
  
  Responsibilities:
    - Centralize session time, laps, flags, Safety Car status, weather/track status
    - Preallocated per-car status cache (0 to 63)
    - Zero dynamic memory allocation in 10Hz/60Hz query paths
]]

local M = {}

local MAX_CARS = 64

M.FLAG_GREEN  = "GREEN"
M.FLAG_YELLOW = "YELLOW"
M.FLAG_SC     = "SC"
M.FLAG_VSC    = "VSC"
M.FLAG_RED    = "RED"

local _raceState = {
  sessionType = "RACE",
  totalLaps = 20,
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

    -- Dynamic Racecraft & Strategy Integration
    tacticalState = "CRUISE",
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

function M.getCarState(carIndex)
  return _carStates[carIndex] or _carStates[0]
end

function M.getAllCarStates()
  return _carStates
end

--- Update global race state snapshot once per frame (10Hz / 1Hz)
function M.updateFromSim(sim)
  if not sim then return end
  _raceState.isReplay = sim.isReplayActive or false
  _raceState.sessionTime = sim.sessionTime or 0.0
  _raceState.carsCount = math.min(MAX_CARS, sim.carsCount or 0)
  _raceState.totalLaps = sim.raceLaps or _raceState.totalLaps
  _raceState.currentLap = sim.currentLap or 1

  -- Flags & Safety Car
  if sim.isYellowFlag or sim.hasYellowFlag then
    _raceState.flagState = M.FLAG_YELLOW
  elseif sim.safetyCarActive or sim.isSafetyCar then
    _raceState.flagState = M.FLAG_SC
    _raceState.scActive = true
  else
    _raceState.flagState = M.FLAG_GREEN
    _raceState.scActive = false
  end
end

--- Update per-car state snapshot from AC car object (Pure scalar, zero-alloc)
function M.updateCarFromAc(carIndex, c)
  if not c or carIndex < 0 or carIndex >= MAX_CARS then return end
  local s = _carStates[carIndex]
  s.isConnected = c.isConnected ~= false
  s.isAIControlled = c.isAIControlled == true
  s.speedKmh = c.speedKmh or 0.0
  s.splinePos = c.splinePosition or 0.0
  s.lapCount = c.lapCount or 0
  s.positionInRace = c.racePosition or (carIndex + 1)
  s.isInPitlane = c.isInPitlane == true
  s.isInPit = c.isInPit == true
  s.fuelInTank = c.fuel or s.fuelInTank

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
  end
end

return M
