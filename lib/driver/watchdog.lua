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

local MAX_CARS = 24

local function safeGetCar(idx)
  if not ac or not ac.getCar or not idx or idx < 0 then return nil end
  local ok, res = pcall(ac.getCar, idx)
  if ok and res then return res end
  return nil
end

local _activeOverrides = {}  -- carIndex -> { active, duration, elapsed, callback }
local _stuckWatch = {}       -- carIndex -> { timer, lastPos }
local _rejoinRamp = {}        -- carIndex -> { remainingTimer, totalTimer, initialCap }
local _dropHistory = { drops = 0, success = 0 } -- Self-judging reposition tracker
local _isPhysicsAllowed = false

for i = 0, MAX_CARS - 1 do
  _activeOverrides[i] = {
    active = false,
    duration = 0.3,
    elapsed = 0.0,
    callback = nil
  }
  _stuckWatch[i] = { timer = 0, judgeTimer = 0, dropPending = false, attemptedJTurn = false }
  _rejoinRamp[i] = { active = false, remainingTimer = 0.0, totalTimer = 0.0, initialCap = 0.60 }
end

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
  if carIndex < 0 or carIndex >= MAX_CARS then return false end
  
  local item = _activeOverrides[carIndex]
  if not item then return false end
  item.active = true
  item.duration = math.min(durationSec or 0.3, 0.5) -- hard cap 0.5s as per design
  item.elapsed = 0.0
  item.callback = onControlStep
  return true
end

--- Force release any active micro-control takeover immediately
function M.releaseTakeover(carIndex)
  if carIndex >= 0 and carIndex < MAX_CARS then
    _activeOverrides[carIndex].active = false
    _activeOverrides[carIndex].callback = nil
  end
end

--- High frequency physics watchdog step (Run in simUpdate @ 60Hz)
--- STRICT BUDGET: < 0.1ms per physics step. ZERO table creation / ZERO string ops.
function M.stepPhysics(dt)
  if not _isPhysicsAllowed then return end

  -- 1. Process active micro-takeovers
  for carIdx = 0, MAX_CARS - 1 do
    local item = _activeOverrides[carIdx]
    if item and item.active then
      item.elapsed = item.elapsed + dt
      if item.elapsed >= item.duration then
        -- Auto release in single frame back to AC native AI
        item.active = false
        item.callback = nil
      else
        local car = safeGetCar(carIdx)
        if car and car.isAIControlled then
          local latGExceeded = false
          if car.acceleration and math.abs(car.acceleration.x or 0) > 29.4 then
            latGExceeded = true
          end

          if (car.speedKmh or 0) < 0.5 or (car.up and car.up.y < 0.2) or latGExceeded then
            item.active = false
            item.callback = nil
          else
            local ctrl = ac.overrideCarControls(carIdx)
            if ctrl and item.callback then
              ctrl.combineAxis = false
              item.callback(ctrl, car, dt)
            else
              item.active = false
              item.callback = nil
            end
          end
        else
          item.active = false
          item.callback = nil
        end
      end
    end
  end

  -- 2. Process post-reposition rejoin throttle ramp (prevents cold-tyre snap spin)
  for carIdx = 0, MAX_CARS - 1 do
    local ramp = _rejoinRamp[carIdx]
    if ramp and ramp.active then
      ramp.remainingTimer = ramp.remainingTimer - dt
      if ramp.remainingTimer <= 0 then
        ramp.active = false
        if physics and physics.setAIThrottleLimit then
          physics.setAIThrottleLimit(carIdx, 1.0)
        end
      else
        local car = safeGetCar(carIdx)
        if car and car.isAIControlled then
          local progress = 1.0 - (ramp.remainingTimer / ramp.totalTimer)
          -- Ramp throttle from 60% up to 100%
          local throttleCap = ramp.initialCap + (1.0 - ramp.initialCap) * progress
          if physics and physics.setAIThrottleLimit then
            physics.setAIThrottleLimit(carIdx, throttleCap)
          end
        else
          ramp.active = false
        end
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
      local other = safeGetCar(i)
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
--- Strict Start Protection: Never trigger during race start / grid formation
function M.checkStuckCars(car, dt, sessionTime)
   if not _isPhysicsAllowed or not car or not car.isAIControlled or car.isRetired then return end
   local idx = car.index
   
   if not _stuckWatch[idx] then
     _stuckWatch[idx] = { timer = 0, judgeTimer = 0, dropPending = false, attemptedJTurn = false }
   end
   
   local w = _stuckWatch[idx]

  -- 1. START GUARD: Strictly ignore cars on starting grid or during race launch phase.
  -- While car is on Lap 0, NEVER trigger stuck unfreeze or tamper with car.
  -- Cars sitting on the starting grid waiting for lights or accelerating down the front straight must not be flagged as stuck!
  if (car.lapCount or 0) == 0 or (sessionTime and sessionTime < 25.0) then
    w.timer = 0
    w.attemptedJTurn = false
    return
  end

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

   -- 2. Anti-Retirement Shield:
   -- When an AI car is slowed down outside pits (due to traffic, incident, or spin recovery),
   -- invoke CSP physics.preventAIFromRetiring so AC engine does not prematurely retire and teleport it!
   if (car.speedKmh or 0) < 25.0 and not car.isInPitlane and not car.isInPit then
     if physics and physics.preventAIFromRetiring then
       pcall(physics.preventAIFromRetiring, idx)
     end
   end

   if (car.speedKmh or 0) < 2.0 and not car.isInPitlane and not car.isInPit then
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

       -- If car is stopped or facing backwards, clear stop counter to prompt native AC AI restart
       if physics.setAIStopCounter then
         physics.setAIStopCounter(idx, 0)
       end

       local okEv, EventHub = pcall(require, "lib/core/EventHub")
       if okEv and EventHub then
         EventHub.pushAiEvent(idx, "WATCHDOG", string.format("赛车 #%02d 遭遇停滞，看门狗已清空停止计时重置原生AI寻路。", idx + 1), "WORLD")
       end
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

function M.reset()
  for i = 0, MAX_CARS - 1 do
    local item = _activeOverrides[i]
    if item then
      item.active = false
      item.callback = nil
    end
    local w = _stuckWatch[i]
    if w then
      w.timer = 0
      w.judgeTimer = 0
      w.dropPending = false
      w.attemptedJTurn = false
    end
    local r = _rejoinRamp[i]
    if r then
      r.active = false
      r.remainingTimer = 0.0
    end
  end
  _dropHistory.drops = 0
  _dropHistory.success = 0
end

return M
