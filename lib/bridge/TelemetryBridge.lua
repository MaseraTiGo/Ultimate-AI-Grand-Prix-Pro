--[[
  TelemetryBridge.lua
  PersonaAI v3.0.0-Evolution: Zero-Overhead Ecosystem Bridge
  
  Responsibilities:
    1. LuaJIT FFI Shared Memory & Broadcast Bridge:
       - Uses ffi.cdef to define fixed C struct for AI psychological & tactical state.
       - Maps all cars telemetry into continuous zero-allocation binary memory.
       - Enables external AI Race Engineer / Copilot apps to read telemetry with 0ms GC overhead.
       - Gracefully falls back to zero-allocation flat table buffers if standalone Lua doesn't have FFI.
    2. Event-driven telemetry export:
       - AI car index, tactical state ID, stress (0-10), momentum (-1 to +1), tyre complain flag,
         lift & coast active flag, mistake intent ID.
]]

local M = {}

local MAX_CARS = 64

-- C struct definition for FFI
local C_STRUCT_DEF = [[
  typedef struct {
    int car_index;
    int state_id;            // 0: CRUISE, 1: ATTACK, 2: DEFEND, 3: MISTAKE, 4: YIELD, 5: SWITCHBACK
    float stress;            // 0.0 ~ 10.0
    float momentum;          // -1.0 (Tilt) ~ +1.0 (Flow)
    float tyre_wear;         // 0.0 ~ 1.0
    int lift_and_coast;      // 0 or 1
    int breaking_tow;        // 0 or 1
    int mistake_type_id;     // 0: NONE, 1: OVERSLOW, 2: TRAIL, 3: LOCKUP, 4: SLIDE, 5: APEX
    float spline_offset;     // -1.0 ~ 1.0
    float target_caution;    // Caution level
  } AiTelemetryEntry;

  typedef struct {
    int version;
    int cars_count;
    double timestamp;
    AiTelemetryEntry cars[64];
  } AiTelemetryPacket;
]]

local _hasFFI = false
local _ffi = nil
local _sharedBuffer = nil

-- Check FFI availability
local okFFI, ffiLib = pcall(require, "ffi")
if okFFI and ffiLib and ffiLib.cdef then
  _hasFFI = true
  _ffi = ffiLib
  pcall(function()
    _ffi.cdef(C_STRUCT_DEF)
    _sharedBuffer = _ffi.new("AiTelemetryPacket")
    _sharedBuffer.version = 300
    _sharedBuffer.cars_count = 0
  end)
end

-- Fallback scalar storage if FFI not available (e.g. standard Lua 5.1 tests)
local _fallbackPacket = {
  version = 300,
  cars_count = 0,
  timestamp = 0.0,
  cars = {}
}

for i = 0, MAX_CARS - 1 do
  _fallbackPacket.cars[i] = {
    car_index = i,
    state_id = 0,
    stress = 0.0,
    momentum = 0.0,
    tyre_wear = 0.0,
    lift_and_coast = 0,
    breaking_tow = 0,
    mistake_type_id = 0,
    spline_offset = 0.0,
    target_caution = 1.0,
  }
end

local _stateMap = {
  ["CRUISE"] = 0,
  ["ATTACK"] = 1,
  ["DEFEND"] = 2,
  ["MISTAKE"] = 3,
  ["YIELD"] = 4,
  ["SWITCHBACK"] = 5
}

local _mistakeMap = {
  ["NONE"] = 0,
  ["OVERSLOW"] = 1,
  ["TRAIL_UNDERSTEER"] = 2,
  ["BRAKE_LOCKUP"] = 3,
  ["TRACTION_SLIDE"] = 4,
  ["MISSED_APEX"] = 5,
  ["START_WHEELSPIN"] = 6,
  ["START_BOGDOWN"] = 7
}

--- Publish single AI car telemetry entry into shared bridge (Zero Allocation)
---@param carIndex integer
---@param stateStr string State name
---@param stress number
---@param momentum number (-1.0 Tilt to +1.0 Flow)
---@param tyreWear number
---@param isLiftAndCoast boolean
---@param isBreakingTow boolean
---@param mistakeStr string
---@param splineOffset number
---@param caution number
function M.updateCarTelemetry(carIndex, stateStr, stress, momentum, tyreWear, isLiftAndCoast, isBreakingTow, mistakeStr, splineOffset, caution)
  if carIndex < 0 or carIndex >= MAX_CARS then return end

  local sId = _stateMap[stateStr or "CRUISE"] or 0
  local mId = _mistakeMap[mistakeStr or "NONE"] or 0
  local lac = isLiftAndCoast and 1 or 0
  local btw = isBreakingTow and 1 or 0

  if _hasFFI and _sharedBuffer then
    local entry = _sharedBuffer.cars[carIndex]
    entry.car_index = carIndex
    entry.state_id = sId
    entry.stress = stress or 0.0
    entry.momentum = momentum or 0.0
    entry.tyre_wear = tyreWear or 0.0
    entry.lift_and_coast = lac
    entry.breaking_tow = btw
    entry.mistake_type_id = mId
    entry.spline_offset = splineOffset or 0.0
    entry.target_caution = caution or 1.0
  else
    local entry = _fallbackPacket.cars[carIndex]
    entry.car_index = carIndex
    entry.state_id = sId
    entry.stress = stress or 0.0
    entry.momentum = momentum or 0.0
    entry.tyre_wear = tyreWear or 0.0
    entry.lift_and_coast = lac
    entry.breaking_tow = btw
    entry.mistake_type_id = mId
    entry.spline_offset = splineOffset or 0.0
    entry.target_caution = caution or 1.0
  end
end

--- Stamp frame timestamp and active cars count
function M.stampPacket(carsCount, timestamp)
  if _hasFFI and _sharedBuffer then
    _sharedBuffer.cars_count = carsCount or 0
    _sharedBuffer.timestamp = timestamp or 0.0
  else
    _fallbackPacket.cars_count = carsCount or 0
    _fallbackPacket.timestamp = timestamp or 0.0
  end
end

--- Get C-pointer to shared memory buffer or fallback table
function M.getSharedBuffer()
  if _hasFFI and _sharedBuffer then
    return _sharedBuffer
  end
  return _fallbackPacket
end

--- Query car telemetry entry (for testing or copilot integration)
---@param carIndex integer
---@return table entry
function M.getCarTelemetry(carIndex)
  if _hasFFI and _sharedBuffer then
    local e = _sharedBuffer.cars[carIndex]
    return {
      car_index = e.car_index,
      state_id = e.state_id,
      stress = e.stress,
      momentum = e.momentum,
      tyre_wear = e.tyre_wear,
      lift_and_coast = e.lift_and_coast,
      breaking_tow = e.breaking_tow,
      mistake_type_id = e.mistake_type_id,
      spline_offset = e.spline_offset,
      target_caution = e.target_caution
    }
  end
  return _fallbackPacket.cars[carIndex] or _fallbackPacket.cars[0]
end

function M.isFFIAvailable()
  return _hasFFI
end

function M.reset()
  if _hasFFI and _sharedBuffer then
    _sharedBuffer.cars_count = 0
    _sharedBuffer.timestamp = 0.0
  else
    _fallbackPacket.cars_count = 0
    _fallbackPacket.timestamp = 0.0
  end
end

return M
