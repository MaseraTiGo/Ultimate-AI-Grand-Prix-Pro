--[[
  LODScheduler.lua
  PersonaAI v2.0.0-NextGen: Spatial LOD Scheduler & Interleaved Time-Slicing
  
  Responsibilities:
    1. Spatial 3-Tier Dynamic LOD calculation relative to player (car 0):
       - Tier 1 (Focus Tier): Dist < 80m or within +-2 grid positions. Full 10Hz tick.
       - Tier 2 (Midfield Tier): 80m <= Dist < 250m. 3.33Hz (1 in 3 ticks), simplified racecraft.
       - Tier 3 (Ambient Tier): Dist >= 250m. 1Hz (1 in 10 ticks), highway cruise & basic safety.
    2. Interleaved Frame Distribution (Time-Slicing):
       - Prevents CPU spikes by interleaving Tier 2 and Tier 3 car ticks across successive frames.
    3. Flat preallocated scalar buffers, zero table allocation, zero pairs() iteration.
]]

local M = {}

M.TIER_FOCUS = 1
M.TIER_MIDFIELD = 2
M.TIER_AMBIENT = 3

local MAX_CARS = 24
local _carTiers = {}      -- [carIdx] = tier (1, 2, 3)
local _carDistSq = {}     -- [carIdx] = distance squared to player
local _tickCounter = 0

local _eventWakeCounter = {} -- [carIdx] = remaining wake ticks

for i = 0, MAX_CARS - 1 do
  _carTiers[i] = M.TIER_FOCUS
  _carDistSq[i] = 0.0
  _eventWakeCounter[i] = 0
end

--- Trigger Event-Driven Interrupt Wakeup (collision, yellow flag, or high-speed approach)
--- Wakes specific car from Deep Sleep for 30 ticks (3.0s)
---@param carIndex integer
function M.triggerWakeInterrupt(carIndex)
  if carIndex >= 0 and carIndex < MAX_CARS then
    _eventWakeCounter[carIndex] = 30
  end
end

--- Update LOD tiers for all cars based on Euclidean distance to player
--- Pure scalar calculation, NYI-free, zero table creation
---@param playerPos table? Player car position {x, y, z}
---@param carsCount integer Total number of cars in session
---@param getCarPos fun(i: integer): number, number, number Returns posX, posY, posZ
function M.updateTiers(playerPos, carsCount, getCarPos)
  _tickCounter = _tickCounter + 1
  if _tickCounter >= 30000 then _tickCounter = 0 end

  if not playerPos then
    for i = 0, carsCount - 1 do
      _carTiers[i] = M.TIER_FOCUS
    end
    return
  end

  local px = playerPos.x or 0.0
  local py = playerPos.y or 0.0
  local pz = playerPos.z or 0.0

  local count = carsCount
  if count > MAX_CARS then count = MAX_CARS end

  for i = 0, count - 1 do
    if i == 0 then
      _carTiers[0] = M.TIER_FOCUS
      _carDistSq[0] = 0.0
    else
      local cx, cy, cz = getCarPos(i)
      local dx = cx - px
      local dy = cy - py
      local dz = cz - pz
      local dSq = dx * dx + dy * dy + dz * dz
      _carDistSq[i] = dSq

      -- 80m threshold -> 6400 m^2
      -- 250m threshold -> 62500 m^2
      if dSq < 6400.0 then
        _carTiers[i] = M.TIER_FOCUS
      elseif dSq < 62500.0 then
        _carTiers[i] = M.TIER_MIDFIELD
      else
        _carTiers[i] = M.TIER_AMBIENT
      end
    end
  end
end

local _deepSleepEnabled = false
local _baselineHeartbeatInterval = 0 -- 0: pure deep sleep (0Hz); >0: ticks every N frames (~0.4Hz at 25 ticks)

function M.setDeepSleepEnabled(enabled)
  _deepSleepEnabled = (enabled ~= false)
end

--- Configure low-frequency baseline heartbeat interval (in ticks) for Tier 3 cars in Deep Sleep
--- E.g., interval = 25 (~0.4Hz at 10Hz base clock) ensures distant cars tick periodically for pit/tyre updates
---@param interval integer Number of ticks between heartbeats (0 disables heartbeat)
function M.setBaselineHeartbeat(interval)
  _baselineHeartbeatInterval = (interval and interval > 0) and math.floor(interval) or 0
end

--- Get configured baseline heartbeat interval
---@return integer interval
function M.getBaselineHeartbeat()
  return _baselineHeartbeatInterval
end

--- Check if specific car should execute tactical decision tick this frame
--- Event-Driven Deep Sleep:
---   Tier 1 (Focus): Runs every tick (10Hz)
---   Tier 2 (Midfield): Runs every 3rd tick (3.33Hz), staggered by (carIndex % 3)
---   Tier 3 (Ambient > 250m): DEEP SLEEP (0Hz) when enabled - skips routine ticks unless
---          awakened by event interrupt (collision/yellow flag/approach), then runs @ 1Hz.
---          If baseline heartbeat is configured (>0), ticks periodically at 0.4Hz.
---          If deep sleep is disabled, runs at normal 1Hz (1/10 ticks).
---@param carIndex integer
---@return boolean shouldTick, integer tier
function M.shouldTickCar(carIndex)
  local tier = _carTiers[carIndex] or M.TIER_FOCUS

  if tier == M.TIER_FOCUS then
    return true, M.TIER_FOCUS
  elseif tier == M.TIER_MIDFIELD then
    local phase = carIndex % 3
    if (_tickCounter % 3) == phase then
      return true, M.TIER_MIDFIELD
    end
    return false, M.TIER_MIDFIELD
  else
    -- Tier 3: Event-Driven Deep Sleep
    if _deepSleepEnabled then
      local wakeTicks = _eventWakeCounter[carIndex] or 0
      if wakeTicks > 0 then
        local phase = carIndex % 10
        if (_tickCounter % 10) == phase then
          _eventWakeCounter[carIndex] = wakeTicks - 1
          return true, M.TIER_AMBIENT
        end
      end
      -- Baseline heartbeat fallback for strategy & tyre progression (e.g. ~0.4Hz at 25 ticks)
      if _baselineHeartbeatInterval > 0 then
        local phase = carIndex % _baselineHeartbeatInterval
        if (_tickCounter % _baselineHeartbeatInterval) == phase then
          return true, M.TIER_AMBIENT
        end
      end
      -- Deep Sleep: 0Hz, zero cpu overhead
      return false, M.TIER_AMBIENT
    else
      -- Deep sleep disabled: periodic 1Hz (every 10 ticks)
      local phase = carIndex % 10
      if (_tickCounter % 10) == phase then
        return true, M.TIER_AMBIENT
      end
      return false, M.TIER_AMBIENT
    end
  end
end

--- Get assigned Tier for telemetry display
---@param carIndex integer
---@return integer tier
function M.getCarTier(carIndex)
  return _carTiers[carIndex] or M.TIER_FOCUS
end

--- Get squared distance to player
---@param carIndex integer
---@return number distSq
function M.getCarDistSq(carIndex)
  return _carDistSq[carIndex] or 0.0
end

--- For testing/debugging: manual set tier
function M.setCarTier(carIndex, tier)
  _carTiers[carIndex] = tier
end

--- Reset counter
function M.reset()
  _tickCounter = 0
  _baselineHeartbeatInterval = 0
  for i = 0, MAX_CARS - 1 do
    _carTiers[i] = M.TIER_FOCUS
    _carDistSq[i] = 0.0
    _eventWakeCounter[i] = 0
  end
end

return M
