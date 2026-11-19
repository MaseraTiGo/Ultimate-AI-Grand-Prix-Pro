--[[
  lib/driver/SpatialRadar.lua
  Ultimate AI Grand Prix Pro - Omnidirectional Proximity & Spatial Awareness Radar Engine
  
  Derived & Elevated from CAS (Electronic Rearview & Proximity Radar SDK):
    1. Zero-Allocation Object Pool: recycled car tables, 0 GC pressure in 30Hz/60Hz loops.
    2. Squared-Distance Rejection: dx^2 + dy^2 + dz^2 <= R^2 skips sqrt for distant cars.
    3. Body-Relative Orthogonal Projection: localX (lateral) and localZ (longitudinal) via dot products.
    4. 360-Degree Clock Direction (1~12 o'clock) & 8-Sector Classification.
    5. Deterministic Overlap & Blindspot Logic (true wheel-to-wheel side-by-side detection).
    6. Multi-Car Grid Extension: full focal radar for focused/player car, plus ultra-fast O(N)
       tactical surrounding scans for all 24 AI cars (Three-Wide detection, flank clearances).
    7. Spotter State Machine: "Car Left", "Car Right", "Three Wide", "Clear" callout pipeline.
    8. Static String & Driver Metadata Caching: zero C++ API crossing overhead in hot loop.
]]

local M = {}

-- Local math caching for LuaJIT NYI-free performance
local sqrt = math.sqrt
local atan2 = math.atan2 or math.atan
local deg = math.deg
local floor = math.floor
local max = math.max
local min = math.min
local abs = math.abs

local MAX_CARS = 64

-- Configuration Defaults
local cfg = {
  maxDistance = 80.0,       -- Max spatial radius in meters
  nearThreshold = 7.0,      -- Distance considered dangerously close
  blindspotZRange = 5.0,    -- Longitudinal overlap range (-Z to +Z in meters)
  blindspotXMin = 1.6,      -- Minimum lateral offset for side overlap
  blindspotXMax = 5.0,      -- Maximum lateral offset for side overlap
  updateRate = 30,          -- 30Hz refresh throttle
  includePits = false       -- If false, ignores pitlane cars when on track
}

local maxDistanceSq = cfg.maxDistance * cfg.maxDistance

-- Sector Constants
local SECTOR_RIGHT = "RIGHT"
local SECTOR_LEFT = "LEFT"
local SECTOR_FRONT = "FRONT"
local SECTOR_RIGHT_FRONT = "RIGHT_FRONT"
local SECTOR_LEFT_FRONT = "LEFT_FRONT"
local SECTOR_REAR = "REAR"
local SECTOR_RIGHT_REAR = "RIGHT_REAR"
local SECTOR_LEFT_REAR = "LEFT_REAR"

M.SECTOR_RIGHT = SECTOR_RIGHT
M.SECTOR_LEFT = SECTOR_LEFT
M.SECTOR_FRONT = SECTOR_FRONT
M.SECTOR_RIGHT_FRONT = SECTOR_RIGHT_FRONT
M.SECTOR_LEFT_FRONT = SECTOR_LEFT_FRONT
M.SECTOR_REAR = SECTOR_REAR
M.SECTOR_RIGHT_REAR = SECTOR_RIGHT_REAR
M.SECTOR_LEFT_REAR = SECTOR_LEFT_REAR

-- Static metadata cache per car index to eliminate C++ API string queries in loop
local metaCache = {}

-- Preallocated Object Pool for focused car radar (Zero GC in loop)
local carPool = {}
for i = 1, MAX_CARS do
  carPool[i] = {
    index = -1,
    carId = "",
    carName = "",
    driverName = "",
    racePosition = 0,
    distance = 999.0,
    splineDistance = 999.0,
    speedKmh = 0.0,
    speedDiffKmh = 0.0,
    closingSpeedKmh = 0.0,
    sector = SECTOR_FRONT,
    clockDirection = 12,
    clockDegrees = 0.0,
    localX = 0.0,
    localZ = 0.0,
    isOverlapping = false,
    isNear = false,
    isInPitlane = false,
  }
end

local nearbyCars = {}
local timer = 0.0

local summary = {
  total = 0,
  frontCount = 0,
  rearCount = 0,
  leftCount = 0,
  rightCount = 0,
  nearCount = 0,
  hasDangerOverlap = false,
  isThreeWide = false,
  closest = nil,
  closestFront = nil,
  closestRear = nil,
  closestOverlap = nil,
  flankLeftCar = nil,
  flankRightCar = nil,
}

-- Spotter State Machine registers
local _spotter = {
  lastState = "NONE",       -- "NONE", "CAR_LEFT", "CAR_RIGHT", "THREE_WIDE"
  activeAlert = "NONE",
  alertTimer = 0.0,
  wasOverlapping = false,
  wasLeft = false,
  wasRight = false,
  clearCallPending = false,
  lastEventTime = 0.0,
}

-- Preallocated multi-car tactical scans (Zero runtime allocation for all 64 cars)
local _tacticalScans = {}
for i = 0, MAX_CARS - 1 do
  _tacticalScans[i] = {
    carIndex = i,
    hasOverlap = false,
    overlapRelX = 0.0,
    overlapCarIdx = -1,
    overlapDist = 999.0,
    isThreeWide = false,
    leftThreat = false,
    rightThreat = false,
    flankLeftIdx = -1,
    flankLeftDist = 999.0,
    flankRightIdx = -1,
    flankRightDist = 999.0,
    closestFrontIdx = -1,
    closestFrontDist = 999.0,
    closestFrontClosingSpeed = 0.0,
    closestBehindIdx = -1,
    closestBehindDist = 999.0,
    closestBehindClosingSpeed = 0.0,
    lastUpdateSessionTime = -1.0,
  }
end

--- Pure scalar sector classification
function M.calculateSector(localX, localZ)
  local absX = abs(localX)
  local absZ = abs(localZ)
  
  if absZ < 2.0 and absX >= 1.0 then
    return localX > 0 and SECTOR_RIGHT or SECTOR_LEFT
  end
  
  if localZ >= 0 then
    if absX < 1.8 then
      return SECTOR_FRONT
    elseif localX > 0 then
      return SECTOR_RIGHT_FRONT
    else
      return SECTOR_LEFT_FRONT
    end
  else
    if absX < 1.8 then
      return SECTOR_REAR
    elseif localX > 0 then
      return SECTOR_RIGHT_REAR
    else
      return SECTOR_LEFT_REAR
    end
  end
end

--- 360-degree clock direction & angle
function M.calculateClockDirection(localX, localZ)
  local angleRad = atan2(localX, localZ)
  local angleDeg = deg(angleRad)
  if angleDeg < 0 then
    angleDeg = angleDeg + 360.0
  end
  local hour = floor((angleDeg + 15.0) / 30.0) % 12
  if hour == 0 then
    hour = 12
  end
  return hour, angleDeg
end

--- Deterministic overlap & blindspot check
function M.calculateOverlap(localX, localZ, zRange, xMin, xMax)
  zRange = zRange or cfg.blindspotZRange
  xMin = xMin or cfg.blindspotXMin
  xMax = xMax or cfg.blindspotXMax
  local absX = abs(localX)
  local absZ = abs(localZ)
  return (absZ <= zRange) and (absX >= xMin and absX <= xMax)
end

--- Track-aligned spline distance with loop wrap-around
local function calculateSplineDistance(playerS, otherS, trackLengthM)
  local diff = otherS - playerS
  if diff > 0.5 then
    diff = diff - 1.0
  elseif diff < -0.5 then
    diff = diff + 1.0
  end
  return diff * trackLengthM
end

local function sortCarsByDistance(a, b)
  return a.distance < b.distance
end

--- Defensive wrapper to get car by index
local function safeGetCar(idx)
  if not idx or idx < 0 then return nil end
  if ac and ac.getCar then
    local ok, c = pcall(ac.getCar, idx)
    if ok and c then return c end
  end
  return nil
end

--- Get or cache immutable vehicle metadata (prevents expensive C++ interop calls)
local function getCarMetadata(cIndex)
  local meta = metaCache[cIndex]
  if not meta then
    local cId = ""
    local cName = ""
    local dName = ""
    if ac then
      if ac.getCarID then
        local ok, res = pcall(ac.getCarID, cIndex)
        if ok and type(res) == "string" then cId = res end
      end
      if ac.getCarName then
        local ok, res = pcall(ac.getCarName, cIndex)
        if ok and type(res) == "string" then cName = res end
      end
      if ac.getDriverName then
        local ok, res = pcall(ac.getDriverName, cIndex)
        if ok and type(res) == "string" then dName = res end
      end
    end
    meta = { carId = cId, carName = cName, driverName = dName }
    metaCache[cIndex] = meta
  end
  return meta
end

--- Initialize or update settings
function M.init(options)
  if type(options) == "table" then
    if type(options.maxDistance) == "number" then
      cfg.maxDistance = options.maxDistance
      maxDistanceSq = cfg.maxDistance * cfg.maxDistance
    end
    if type(options.nearThreshold) == "number" then cfg.nearThreshold = options.nearThreshold end
    if type(options.blindspotZRange) == "number" then cfg.blindspotZRange = options.blindspotZRange end
    if type(options.blindspotXMin) == "number" then cfg.blindspotXMin = options.blindspotXMin end
    if type(options.blindspotXMax) == "number" then cfg.blindspotXMax = options.blindspotXMax end
    if type(options.updateRate) == "number" and options.updateRate > 0 then cfg.updateRate = options.updateRate end
    if options.includePits ~= nil then cfg.includePits = options.includePits end
  end
  M.reset()
end

--- Reset all states and caches
function M.reset()
  timer = 0.0
  metaCache = {}
  summary.total = 0
  summary.frontCount = 0
  summary.rearCount = 0
  summary.leftCount = 0
  summary.rightCount = 0
  summary.nearCount = 0
  summary.hasDangerOverlap = false
  summary.isThreeWide = false
  summary.closest = nil
  summary.closestFront = nil
  summary.closestRear = nil
  summary.closestOverlap = nil
  summary.flankLeftCar = nil
  summary.flankRightCar = nil

  for i = 1, #nearbyCars do
    nearbyCars[i] = nil
  end

  _spotter.lastState = "NONE"
  _spotter.activeAlert = "NONE"
  _spotter.alertTimer = 0.0
  _spotter.wasOverlapping = false
  _spotter.wasLeft = false
  _spotter.wasRight = false
  _spotter.clearCallPending = false
  _spotter.lastEventTime = 0.0

  for i = 0, MAX_CARS - 1 do
    local s = _tacticalScans[i]
    s.hasOverlap = false
    s.overlapRelX = 0.0
    s.overlapCarIdx = -1
    s.overlapDist = 999.0
    s.isThreeWide = false
    s.leftThreat = false
    s.rightThreat = false
    s.flankLeftIdx = -1
    s.flankLeftDist = 999.0
    s.flankRightIdx = -1
    s.flankRightDist = 999.0
    s.closestFrontIdx = -1
    s.closestFrontDist = 999.0
    s.closestFrontClosingSpeed = 0.0
    s.closestBehindIdx = -1
    s.closestBehindDist = 999.0
    s.closestBehindClosingSpeed = 0.0
    s.lastUpdateSessionTime = -1.0
  end
end

--- Update Focal Spatial Radar (30Hz throttle)
---@param dt number
---@param focusCarIndex integer|nil (defaults to 0 / player car)
function M.update(dt, focusCarIndex)
  dt = dt or 0.033
  timer = timer + dt
  local interval = 1.0 / cfg.updateRate
  if timer < interval then
    return
  end
  timer = 0.0

  local targetIdx = focusCarIndex or 0
  local player = safeGetCar(targetIdx)
  if not player or not player.position then
    return
  end

  local sim = ac and ac.getSim and ac.getSim()
  local trackLen = (sim and sim.trackLengthM) or 5000.0
  local carsCount = (sim and sim.carsCount) or MAX_CARS
  if carsCount > MAX_CARS then carsCount = MAX_CARS end

  -- Precompute player car basis vectors and coordinates
  local pPos = player.position
  local pPosX, pPosY, pPosZ = pPos.x or 0.0, pPos.y or 0.0, pPos.z or 0.0

  local pSideX, pSideY, pSideZ = 1.0, 0.0, 0.0
  if player.side then
    pSideX = player.side.x or 1.0
    pSideY = player.side.y or 0.0
    pSideZ = player.side.z or 0.0
  end

  local pLookX, pLookY, pLookZ = 0.0, 0.0, 1.0
  if player.look then
    pLookX = player.look.x or 0.0
    pLookY = player.look.y or 0.0
    pLookZ = player.look.z or 1.0
  end

  local pSpeedKmh = player.speedKmh or 0.0
  local pInPit = player.isInPitlane or false
  local pSpline = player.splinePosition or 0.0

  local frontCount = 0
  local rearCount = 0
  local leftCount = 0
  local rightCount = 0
  local nearCount = 0
  local hasOverlap = false

  local closestDist = 999999.0
  local closestCar = nil
  local closestFrontDist = 999999.0
  local closestFrontCar = nil
  local closestRearDist = 999999.0
  local closestRearCar = nil
  local closestOverlapDist = 999999.0
  local closestOverlapCar = nil

  local flankLeftMin = 999999.0
  local flankLeftCar = nil
  local flankRightMin = 999999.0
  local flankRightCar = nil

  local currentActive = 0

  for otherIdx = 0, carsCount - 1 do
    if otherIdx ~= targetIdx then
      local other = safeGetCar(otherIdx)
      if other and other.isConnected ~= false and other.position then
        local skip = false
        if not cfg.includePits and other.isInPitlane ~= pInPit then
          skip = true
        end

        if not skip then
          local oPos = other.position
          local dx = (oPos.x or 0.0) - pPosX
          local dy = (oPos.y or 0.0) - pPosY
          local dz = (oPos.z or 0.0) - pPosZ

          -- Optimization 1: Squared distance check
          local distSq = dx * dx + dy * dy + dz * dz
          if distSq <= maxDistanceSq then
            local dist3D = sqrt(distSq)

            -- Vector dot products inlined
            local localX = dx * pSideX + dy * pSideY + dz * pSideZ
            local localZ = dx * pLookX + dy * pLookY + dz * pLookZ

            local sector = M.calculateSector(localX, localZ)
            local clockHour, clockDeg = M.calculateClockDirection(localX, localZ)

            -- Overlap & Blindspot check
            local isOverlap = (abs(localZ) <= cfg.blindspotZRange) and
                              (abs(localX) >= cfg.blindspotXMin and abs(localX) <= cfg.blindspotXMax)

            local isNear = (dist3D <= cfg.nearThreshold)
            if isNear then
              nearCount = nearCount + 1
            end

            if localZ >= 0 then
              frontCount = frontCount + 1
            else
              rearCount = rearCount + 1
            end

            if localX > 0.5 then
              rightCount = rightCount + 1
              if abs(localZ) <= 7.0 and dist3D < flankRightMin then
                flankRightMin = dist3D
              end
            elseif localX < -0.5 then
              leftCount = leftCount + 1
              if abs(localZ) <= 7.0 and dist3D < flankLeftMin then
                flankLeftMin = dist3D
              end
            end

            local oSpeedKmh = other.speedKmh or 0.0
            local speedDiff = oSpeedKmh - pSpeedKmh
            local closingSpeedKmh = 0.0
            if localZ >= 0 then
              closingSpeedKmh = max(0.0, -speedDiff)
            else
              closingSpeedKmh = max(0.0, speedDiff)
            end

            local splineDist = 0.0
            if trackLen > 0 and other.splinePosition then
              splineDist = calculateSplineDistance(pSpline, other.splinePosition, trackLen)
            end

            -- Optimization 2: Acquire table from Object Pool
            currentActive = currentActive + 1
            local target = carPool[currentActive]
            if not target then
              target = {}
              carPool[currentActive] = target
            end

            -- Optimization 3: Cached metadata
            local meta = getCarMetadata(otherIdx)

            target.index = otherIdx
            target.carId = meta.carId
            target.carName = meta.carName
            target.driverName = meta.driverName
            target.racePosition = other.racePosition or (otherIdx + 1)
            target.distance = dist3D
            target.splineDistance = splineDist
            target.speedKmh = oSpeedKmh
            target.speedDiffKmh = speedDiff
            target.closingSpeedKmh = closingSpeedKmh
            target.sector = sector
            target.clockDirection = clockHour
            target.clockDegrees = clockDeg
            target.localX = localX
            target.localZ = localZ
            target.isOverlapping = isOverlap
            target.isNear = isNear
            target.isInPitlane = other.isInPitlane or false

            nearbyCars[currentActive] = target

            if dist3D < closestDist then
              closestDist = dist3D
              closestCar = target
            end
            if localZ >= 0 and dist3D < closestFrontDist then
              closestFrontDist = dist3D
              closestFrontCar = target
            end
            if localZ < 0 and dist3D < closestRearDist then
              closestRearDist = dist3D
              closestRearCar = target
            end
            if isOverlap then
              hasOverlap = true
              if dist3D < closestOverlapDist then
                closestOverlapDist = dist3D
                closestOverlapCar = target
              end
            end
            if localX < -0.5 and dist3D == flankLeftMin then
              flankLeftCar = target
            end
            if localX > 0.5 and dist3D == flankRightMin then
              flankRightCar = target
            end
          end
        end
      end
    end
  end

  -- Trim active array to current count
  for i = currentActive + 1, #nearbyCars do
    nearbyCars[i] = nil
  end

  -- Sort active nearby cars by distance (insertion sort for zero-allocation)
  if currentActive > 1 then
    for i = 2, currentActive do
      local cur = nearbyCars[i]
      local j = i - 1
      while j >= 1 and nearbyCars[j].distance > cur.distance do
        nearbyCars[j + 1] = nearbyCars[j]
        j = j - 1
      end
      nearbyCars[j + 1] = cur
    end
  end

  local isThreeWide = (flankLeftCar ~= nil and flankRightCar ~= nil and flankLeftMin < 5.0 and flankRightMin < 5.0)

  -- Update summary structure
  summary.total = currentActive
  summary.frontCount = frontCount
  summary.rearCount = rearCount
  summary.leftCount = leftCount
  summary.rightCount = rightCount
  summary.nearCount = nearCount
  summary.hasDangerOverlap = hasOverlap
  summary.isThreeWide = isThreeWide
  summary.closest = closestCar
  summary.closestFront = closestFrontCar
  summary.closestRear = closestRearCar
  summary.closestOverlap = closestOverlapCar
  summary.flankLeftCar = flankLeftCar
  summary.flankRightCar = flankRightCar

  -- Update Spotter State Machine for the focus car
  M.updateSpotter(targetIdx, dt)
end

--- Update Spotter Alert State Machine
function M.updateSpotter(targetIdx, dt)
  dt = dt or 0.033
  _spotter.alertTimer = _spotter.alertTimer + dt

  local scan = (targetIdx and _tacticalScans[targetIdx]) or nil
  local hasOverlap = summary.hasDangerOverlap or (scan and scan.hasOverlap) or false
  local isThreeWide = summary.isThreeWide or (scan and scan.isThreeWide) or false

  local newAlert = "NONE"

  if isThreeWide then
    newAlert = "THREE_WIDE"
  elseif hasOverlap then
    local relX = (summary.closestOverlap and summary.closestOverlap.localX) or (scan and scan.overlapRelX) or 0.0
    if relX < 0 then
      newAlert = "CAR_LEFT"
    else
      newAlert = "CAR_RIGHT"
    end
  elseif _spotter.wasOverlapping and not hasOverlap then
    newAlert = "CLEAR"
  end

  -- Edge detection
  if newAlert ~= _spotter.activeAlert and newAlert ~= "NONE" then
    _spotter.activeAlert = newAlert
    _spotter.alertTimer = 0.0
    _spotter.lastState = newAlert

    -- Broadcast to EventHub and RadioVoiceEngine
    local EventHub = package.loaded["lib/core/EventHub"]
    if EventHub and EventHub.pushAiEvent then
      if newAlert == "CAR_LEFT" then
        EventHub.pushAiEvent(targetIdx, "SPOTTER", "【盲区警报】左侧有车！保持走线！(Car Left)", "TACTICAL")
      elseif newAlert == "CAR_RIGHT" then
        EventHub.pushAiEvent(targetIdx, "SPOTTER", "【盲区警报】右侧有车！保持走线！(Car Right)", "TACTICAL")
      elseif newAlert == "THREE_WIDE" then
        EventHub.pushAiEvent(targetIdx, "SPOTTER", "【极度危险】三车并排夹击！稳住车身！(Three Wide)", "INCIDENT")
      elseif newAlert == "CLEAR" then
        EventHub.pushAiEvent(targetIdx, "SPOTTER", "【警报解除】车身完全拉开，可以变道 (Clear)", "TACTICAL")
      end
    end
  elseif newAlert == "NONE" and _spotter.activeAlert == "CLEAR" and _spotter.alertTimer > 2.5 then
    _spotter.activeAlert = "NONE"
  end

  _spotter.wasOverlapping = hasOverlap
end

--- Get active spotter alert for UI / Voice
function M.getSpotterAlert()
  return _spotter.activeAlert, _spotter.alertTimer
end

--- Get preallocated tactical scan struct for car
---@param carIndex integer
---@return table _tacticalScans[carIndex]
function M.getTacticalScan(carIndex)
  if not carIndex or carIndex < 0 or carIndex >= MAX_CARS then
    return _tacticalScans[0]
  end
  return _tacticalScans[carIndex]
end

--- Pure scalar in-place tactical scan update from direct neighbor cars
--- Zero memory allocation, zero GC overhead in hot loops
---@param car table
---@param aheadCar table|nil
---@param behindCar table|nil
---@return table _tacticalScans[car.index]
function M.updateTacticalFromPair(car, aheadCar, behindCar)
  if not car or not car.position then
    return _tacticalScans[0]
  end
  local idx = car.index or 0
  if idx < 0 or idx >= MAX_CARS then idx = 0 end
  local scan = _tacticalScans[idx]

  scan.hasOverlap = false
  scan.overlapRelX = 0.0
  scan.overlapCarIdx = -1
  scan.overlapDist = 999.0
  scan.isThreeWide = false
  scan.leftThreat = false
  scan.rightThreat = false
  scan.flankLeftIdx = -1
  scan.flankLeftDist = 999.0
  scan.flankRightIdx = -1
  scan.flankRightDist = 999.0
  scan.closestFrontIdx = -1
  scan.closestFrontDist = 999.0
  scan.closestFrontClosingSpeed = 0.0
  scan.closestBehindIdx = -1
  scan.closestBehindDist = 999.0
  scan.closestBehindClosingSpeed = 0.0

  local px = car.position.x or 0.0
  local py = car.position.y or 0.0
  local pz = car.position.z or 0.0

  local sideX = 1.0
  local sideY = 0.0
  local sideZ = 0.0
  if car.side then
    sideX = car.side.x or 1.0
    sideY = car.side.y or 0.0
    sideZ = car.side.z or 0.0
  end

  local lookX = 0.0
  local lookY = 0.0
  local lookZ = 1.0
  if car.look then
    lookX = car.look.x or 0.0
    lookY = car.look.y or 0.0
    lookZ = car.look.z or 1.0
  end

  local mySpeed = car.speedKmh or 0.0

  -- 1. Ahead Car Scan
  if aheadCar and aheadCar.position then
    local ax = (aheadCar.position.x or 0.0) - px
    local ay = (aheadCar.position.y or 0.0) - py
    local az = (aheadCar.position.z or 0.0) - pz
    local aDistSq = ax * ax + ay * ay + az * az
    if aDistSq < 6400.0 then -- 80m limit
      local aDist = sqrt(aDistSq)
      local aLocalX = ax * sideX + ay * sideY + az * sideZ
      local aLocalZ = ax * lookX + ay * lookY + az * lookZ

      scan.closestFrontIdx = aheadCar.index or -1
      scan.closestFrontDist = aDist
      local aSpeed = aheadCar.speedKmh or 0.0
      scan.closestFrontClosingSpeed = max(0.0, mySpeed - aSpeed)

      local aOverlap = (abs(aLocalZ) <= cfg.blindspotZRange) and
                       (abs(aLocalX) >= cfg.blindspotXMin and abs(aLocalX) <= cfg.blindspotXMax)
      if aOverlap then
        scan.hasOverlap = true
        scan.overlapRelX = aLocalX
        scan.overlapCarIdx = aheadCar.index or -1
        scan.overlapDist = aDist
      end

      if abs(aLocalZ) <= 6.0 then
        if aLocalX < -0.8 then
          scan.flankLeftDist = aDist
          scan.flankLeftIdx = aheadCar.index or -1
          scan.leftThreat = (aDist < 4.5)
        elseif aLocalX > 0.8 then
          scan.flankRightDist = aDist
          scan.flankRightIdx = aheadCar.index or -1
          scan.rightThreat = (aDist < 4.5)
        end
      end
    end
  end

  -- 2. Behind Car Scan
  if behindCar and behindCar.position then
    local bx = (behindCar.position.x or 0.0) - px
    local by = (behindCar.position.y or 0.0) - py
    local bz = (behindCar.position.z or 0.0) - pz
    local bDistSq = bx * bx + by * by + bz * bz
    if bDistSq < 6400.0 then -- 80m limit
      local bDist = sqrt(bDistSq)
      local bLocalX = bx * sideX + by * sideY + bz * sideZ
      local bLocalZ = bx * lookX + by * lookY + bz * lookZ

      scan.closestBehindIdx = behindCar.index or -1
      scan.closestBehindDist = bDist
      local bSpeed = behindCar.speedKmh or 0.0
      scan.closestBehindClosingSpeed = max(0.0, bSpeed - mySpeed)

      local bOverlap = (abs(bLocalZ) <= cfg.blindspotZRange) and
                       (abs(bLocalX) >= cfg.blindspotXMin and abs(bLocalX) <= cfg.blindspotXMax)
      if bOverlap and bDist < scan.overlapDist then
        scan.hasOverlap = true
        scan.overlapRelX = bLocalX
        scan.overlapCarIdx = behindCar.index or -1
        scan.overlapDist = bDist
      end

      if abs(bLocalZ) <= 6.0 then
        if bLocalX < -0.8 and bDist < scan.flankLeftDist then
          scan.flankLeftDist = bDist
          scan.flankLeftIdx = behindCar.index or -1
          scan.leftThreat = (bDist < 4.5)
        elseif bLocalX > 0.8 and bDist < scan.flankRightDist then
          scan.flankRightDist = bDist
          scan.flankRightIdx = behindCar.index or -1
          scan.rightThreat = (bDist < 4.5)
        end
      end
    end
  end

  scan.isThreeWide = (scan.flankLeftIdx >= 0 and scan.flankRightIdx >= 0 and scan.flankLeftDist < 4.8 and scan.flankRightDist < 4.8)
  return scan
end

--- Ultra-fast O(N) tactical scan for ANY of the 24 cars on track
--- Preallocated zero-allocation return struct
---@param carIndex integer
---@param maxDist number|nil
---@return table _tacticalScans[carIndex]
function M.scanTacticalSurroundings(carIndex, maxDist)
  if carIndex < 0 or carIndex >= MAX_CARS then
    return _tacticalScans[0]
  end

  local scan = _tacticalScans[carIndex]
  local myCar = safeGetCar(carIndex)
  if not myCar or not myCar.position then
    scan.hasOverlap = false
    scan.isThreeWide = false
    scan.overlapCarIdx = -1
    scan.closestFrontIdx = -1
    scan.closestBehindIdx = -1
    return scan
  end

  local sim = ac and ac.getSim and ac.getSim()
  local carsCount = (sim and sim.carsCount) or MAX_CARS
  if carsCount > MAX_CARS then carsCount = MAX_CARS end

  local limitDist = maxDist or 45.0
  local limitDistSq = limitDist * limitDist

  local px, py, pz = myCar.position.x or 0.0, myCar.position.y or 0.0, myCar.position.z or 0.0

  local sideX, sideY, sideZ = 1.0, 0.0, 0.0
  if myCar.side then
    sideX = myCar.side.x or 1.0
    sideY = myCar.side.y or 0.0
    sideZ = myCar.side.z or 0.0
  end

  local lookX, lookY, lookZ = 0.0, 0.0, 1.0
  if myCar.look then
    lookX = myCar.look.x or 0.0
    lookY = myCar.look.y or 0.0
    lookZ = myCar.look.z or 1.0
  end

  local mySpeedKmh = myCar.speedKmh or 0.0
  local myInPit = myCar.isInPitlane or false

  local hasOverlap = false
  local overlapRelX = 0.0
  local overlapCarIdx = -1
  local minOverlapDist = 999.0

  local flankLeftIdx = -1
  local flankLeftDist = 999.0
  local flankRightIdx = -1
  local flankRightDist = 999.0

  local closestFrontIdx = -1
  local closestFrontDist = 999.0
  local closestFrontClosingSpeed = 0.0

  local closestBehindIdx = -1
  local closestBehindDist = 999.0
  local closestBehindClosingSpeed = 0.0

  for otherIdx = 0, carsCount - 1 do
    if otherIdx ~= carIndex then
      local other = safeGetCar(otherIdx)
      if other and other.isConnected ~= false and other.position and (other.isInPitlane or false) == myInPit then
        local ox, oy, oz = other.position.x or 0.0, other.position.y or 0.0, other.position.z or 0.0
        local dx = ox - px
        local dy = oy - py
        local dz = oz - pz

        local distSq = dx * dx + dy * dy + dz * dz
        if distSq <= limitDistSq then
          local dist3D = sqrt(distSq)
          local localX = dx * sideX + dy * sideY + dz * sideZ
          local localZ = dx * lookX + dy * lookY + dz * lookZ

          local otherSpeed = other.speedKmh or 0.0
          local speedDiff = otherSpeed - mySpeedKmh

          -- Overlap check
          local isOverlap = (abs(localZ) <= cfg.blindspotZRange) and
                            (abs(localX) >= cfg.blindspotXMin and abs(localX) <= cfg.blindspotXMax)

          if isOverlap and dist3D < minOverlapDist then
            hasOverlap = true
            minOverlapDist = dist3D
            overlapCarIdx = otherIdx
            overlapRelX = localX
          end

          -- Flank side tracking within 6m
          if abs(localZ) <= 6.0 then
            if localX < -0.8 and dist3D < flankLeftDist then
              flankLeftDist = dist3D
              flankLeftIdx = otherIdx
            elseif localX > 0.8 and dist3D < flankRightDist then
              flankRightDist = dist3D
              flankRightIdx = otherIdx
            end
          end

          -- Front / Behind closest
          if localZ >= 0 and dist3D < closestFrontDist then
            closestFrontDist = dist3D
            closestFrontIdx = otherIdx
            closestFrontClosingSpeed = max(0.0, -speedDiff)
          elseif localZ < 0 and dist3D < closestBehindDist then
            closestBehindDist = dist3D
            closestBehindIdx = otherIdx
            closestBehindClosingSpeed = max(0.0, speedDiff)
          end
        end
      end
    end
  end

  local isThreeWide = (flankLeftIdx >= 0 and flankRightIdx >= 0 and flankLeftDist < 4.8 and flankRightDist < 4.8)

  scan.hasOverlap = hasOverlap
  scan.overlapRelX = overlapRelX
  scan.overlapCarIdx = overlapCarIdx
  scan.overlapDist = minOverlapDist
  scan.isThreeWide = isThreeWide
  scan.leftThreat = (flankLeftIdx >= 0 and flankLeftDist < 4.5)
  scan.rightThreat = (flankRightIdx >= 0 and flankRightDist < 4.5)
  scan.flankLeftIdx = flankLeftIdx
  scan.flankLeftDist = flankLeftDist
  scan.flankRightIdx = flankRightIdx
  scan.flankRightDist = flankRightDist
  scan.closestFrontIdx = closestFrontIdx
  scan.closestFrontDist = closestFrontDist
  scan.closestFrontClosingSpeed = closestFrontClosingSpeed
  scan.closestBehindIdx = closestBehindIdx
  scan.closestBehindDist = closestBehindDist
  scan.closestBehindClosingSpeed = closestBehindClosingSpeed

  return scan
end

--- Get summary record of focal radar
function M.getSummary()
  return summary
end

--- Get active detected cars list
function M.getNearbyCars()
  return nearbyCars
end

--- Query threat flag
function M.hasThreat()
  return summary.hasDangerOverlap or (summary.nearCount > 0) or summary.isThreeWide
end

--- Filter vehicles by sector
function M.getCarsInSector(sectorName, outTable)
  local res = outTable or {}
  local n = 0
  for i = 1, summary.total do
    local c = nearbyCars[i]
    if c and c.sector == sectorName then
      n = n + 1
      res[n] = c
    end
  end
  for i = n + 1, #res do
    res[i] = nil
  end
  return res
end

return M
