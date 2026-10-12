--[[
  watchdog.lua
  PersonaAI Physics & Control Watchdog
  Responsibility:
    1. Safety sandbox for ac.overrideCarControls to guarantee single-frame auto-release.
    2. Zero allocation during 60Hz physics steps.
    3. Slip angle / spinout safety monitoring to prevent car flying/glitches.
    4. Anti-stuck unfreezing watchdog (AI speed < 2 km/h for 5s).
]]

local M = {}

local _activeOverrides = {}  -- carIndex -> { duration, elapsed, onComplete }
local _stuckWatch = {}       -- carIndex -> { timer, lastPos }
local _rejoinRamp = {}        -- carIndex -> { remainingTimer, totalTimer, initialCap }
local _dropHistory = { drops = 0, success = 0 } -- Self-judging reposition tracker
local _isPhysicsAllowed = false

function M.init()
  if physics and physics.allowed then
    _isPhysicsAllowed = physics.allowed()
  else
    _isPhysicsAllowed = false
  end
end

function M.isPhysicsAllowed()
  return _isPhysicsAllowed
end

--- Request transient micro-control takeover for specific carIndex (< 0.5s)
---@param carIndex integer
---@param durationSec number
---@param onControlStep fun(ctrl: ac.CarControlsInput, car: ac.StateCar, dt: number)
function M.requestTakeover(carIndex, durationSec, onControlStep)
  if not _isPhysicsAllowed or not ac or not ac.overrideCarControls then return false end
  
  _activeOverrides[carIndex] = {
    duration = math.min(durationSec or 0.3, 0.5), -- hard cap 0.5s as per design
    elapsed = 0,
    callback = onControlStep
  }
  return true
end

--- Force release any active micro-control takeover immediately
function M.releaseTakeover(carIndex)
  _activeOverrides[carIndex] = nil
end

--- High frequency physics watchdog step (Run in simUpdate @ 60Hz)
--- STRICT BUDGET: < 0.1ms per physics step. ZERO table creation / ZERO string ops.
function M.stepPhysics(dt)
  if not _isPhysicsAllowed then return end

  -- 1. Process active micro-takeovers
  for carIdx, item in pairs(_activeOverrides) do
    item.elapsed = item.elapsed + dt
    if item.elapsed >= item.duration then
      -- Auto release in single frame back to AC native AI
      _activeOverrides[carIdx] = nil
    else
      local car = ac.getCar(carIdx)
      if car and car.isAIControlled then
        -- 1. Check slip angle / spin safety & inverted car
        -- 2. Lateral G shock cutoff: if lateral acceleration > 3.0G (~29.4 m/s²), abort immediately to prevent physics explosion
        local latGExceeded = false
        if car.acceleration and math.abs(car.acceleration.x or 0) > 29.4 then
          latGExceeded = true
        end

        if car.speedKmh < 0.5 or (car.up and car.up.y < 0.2) or latGExceeded then
          _activeOverrides[carIdx] = nil
        else
          local ctrl = ac.overrideCarControls(carIdx)
          if ctrl then
            ctrl.combineAxis = false
            item.callback(ctrl, car, dt)
          else
            _activeOverrides[carIdx] = nil
          end
        end
      else
        _activeOverrides[carIdx] = nil
      end
    end
  end

  -- 2. Process post-reposition rejoin throttle ramp (prevents cold-tyre snap spin)
  for carIdx, ramp in pairs(_rejoinRamp) do
    ramp.remainingTimer = ramp.remainingTimer - dt
    if ramp.remainingTimer <= 0 then
      _rejoinRamp[carIdx] = nil
    else
      local car = ac.getCar(carIdx)
      if car and car.isAIControlled then
        local progress = 1.0 - (ramp.remainingTimer / ramp.totalTimer)
        -- Ramp throttle from 60% up to 100%
        local throttleCap = ramp.initialCap + (1.0 - ramp.initialCap) * progress
        local ctrl = ac.overrideCarControls(carIdx)
        if ctrl then
          ctrl.combineAxis = false
          if ctrl.gas and ctrl.gas > throttleCap then
            ctrl.gas = throttleCap
          end
        end
      else
        _rejoinRamp[carIdx] = nil
      end
    end
  end
end

--- Check if any other car is dangerously close (< 5m) to avoid pileup explosion upon teleport
local function isCrowdedNearby(car)
  if not ac or not ac.getSim then return false end
  local sim = ac.getSim()
  local count = sim and sim.carsCount or 0
  for i = 0, count - 1 do
    if i ~= car.index then
      local other = ac.getCar(i)
      if other and other.position and car.position then
        local dx = other.position.x - car.position.x
        local dy = other.position.y - car.position.y
        local dz = other.position.z - car.position.z
        local distSq = dx * dx + dy * dy + dz * dz
        if distSq < 25.0 then -- < 5m
          return true
        end
      end
    end
  end
  return false
end

--- Unstuck monitor (Low frequency 10Hz/1Hz) with self-judging reposition and throttle ramp
function M.checkStuckCars(car, dt)
  if not _isPhysicsAllowed or not car or not car.isAIControlled then return end
  local idx = car.index
  
  if not _stuckWatch[idx] then
    _stuckWatch[idx] = { timer = 0, judgeTimer = 0, dropPending = false }
  end
  
  local w = _stuckWatch[idx]

  -- Track self-judging drop outcome: did the car reach 50 km/h within 15 seconds?
  if w.dropPending then
    w.judgeTimer = w.judgeTimer + dt
    if (car.speedKmh or 0) >= 50.0 then
      _dropHistory.success = _dropHistory.success + 1
      w.dropPending = false
    elseif w.judgeTimer >= 15.0 then
      -- Failed drop (e.g. stranded or hit again)
      w.dropPending = false
    end
  end

  if (car.speedKmh or 0) < 2.0 and not car.isInPitlane then
    w.timer = w.timer + dt
    if w.timer >= 5.0 then
      -- Self-judging guard: if at least 4 drops occurred and success rate is < 25%, abort teleport
      -- to let AC retire the car naturally instead of creating a permanent chicane of wrecks
      if _dropHistory.drops >= 4 and (_dropHistory.success / _dropHistory.drops) < 0.25 then
        return
      end

      -- Verify crowd safety before unfreeze/teleport to avoid multi-car explosion
      if isCrowdedNearby(car) then
        -- Postpone teleport by 1 second until gap clears or stagger resolution
        w.timer = 4.0
        return
      end

      -- AI stuck for > 5s outside pits: Trigger unfreeze
      w.timer = 0
      _activeOverrides[idx] = nil -- Release overrides

      -- Physics-Based Recovery: If car is facing backwards (look dot splineDir < -0.3),
      -- attempt a physical J-Turn (steer full lock + reverse throttle pulse) before hard teleport
      local isFacingBackwards = false
      if car.look and car.splinePosition and ac and ac.getTrackSplineDirection then
        local okSpline, splineDir = pcall(ac.getTrackSplineDirection, car.splinePosition)
        if okSpline and splineDir and car.look.dot then
          if car.look:dot(splineDir) < -0.3 then
            isFacingBackwards = true
          end
        end
      end

      if isFacingBackwards and not w.attemptedJTurn then
        -- Execute 0.45s physical reverse J-turn flick
        w.attemptedJTurn = true
        M.requestTakeover(idx, 0.45, function(ctrl, cCar, dt)
          ctrl.gas = 0.0
          ctrl.brake = 0.0
          ctrl.steer = -1.0 -- full lock reverse flick
          ctrl.gear = -1   -- reverse gear
          ctrl.handbrake = 0.0
        end)
        w.timer = 3.5 -- give 1.5s for physics momentum to turn car around before re-checking
        return
      end

      w.attemptedJTurn = false
      
      -- If physical recovery fails or car is not spun backwards, use safe realignment
      if physics.setAICarPosition then
        -- passing nil for dir aligns along spline
        physics.setAICarPosition(idx, car.position, nil)
      end
      if physics.setAIStopCounter then
        physics.setAIStopCounter(idx, 0) -- Clear stop counter
      end

      -- Record reposition drop for self-judging assessment
      _dropHistory.drops = _dropHistory.drops + 1
      w.dropPending = true
      w.judgeTimer = 0.0

      -- Activate Rejoin Throttle Ramp for 3.0s (ramp up from 0.60 to 1.0)
      _rejoinRamp[idx] = {
        remainingTimer = 3.0,
        totalTimer = 3.0,
        initialCap = 0.60,
      }
    end
  else
    w.timer = 0
    w.attemptedJTurn = false
  end
end

function M.getRejoinRamp(carIndex)
  return _rejoinRamp[carIndex]
end

function M.getDropStats()
  return _dropHistory
end

return M
