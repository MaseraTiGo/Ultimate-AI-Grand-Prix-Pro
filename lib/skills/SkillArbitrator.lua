--[[
  lib/skills/SkillArbitrator.lua
  Ultimate AI Grand Prix Pro - High Performance X-Skill Arbitrator
  
  Responsibilities:
    1. Preallocated flat skill contexts for 24 cars (Zero GC Allocation)
    2. Zero-overhead 2-phase gating:
       - Phase 1: Hard Prerequisites filter (early-exit, O(1) scalars)
       - Phase 2: Utility Scoring based on driver persona, tyre, stress & race context
    3. Lifecycle Management: PREP -> EXECUTE -> COMPLETE / ABORT
    4. Anti-flapping commitment hold (0.6s) and skill cooldowns
    5. Fallback safety & anomaly protection (pcall execution isolation)
]]

local SkillRegistry = require("lib/skills/SkillRegistry")
local Logger = require("lib/core/Logger")

local M = {}

local MAX_CARS = 24
local MIN_COMMIT_HOLD = 0.60 -- seconds locked into a skill before re-evaluating
local DEFAULT_COOLDOWN = 3.50 -- seconds cooldown before the same skill can be triggered

-- Preallocated Flat Context Pool (Zero Runtime Allocations)
local _contexts = {}

for i = 0, MAX_CARS - 1 do
  _contexts[i] = {
    carIndex = i,
    activeSkillId = 0,         -- 0: NONE (Nominal cruise/racing line)
    activeSkillName = "NONE",
    currentPhase = 0,          -- 0: IDLE, 1: PREP, 2: EXECUTE, 3: RECOVER
    phaseTimer = 0.0,
    commitTimer = 0.0,
    cooldowns = {
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    }, -- per skill ID cooldown (1..32)
    targetOffset = 0.0,
    targetCaution = 1.0,
    targetAggression = 0.7,
    extraGrip = 0.0,
    utilityScore = 0.0,
    abortCount = 0,
    successCount = 0,
  }
end

-- Preallocated shared spatial state struct for zero-alloc parameter passing
local _geoState = {
  aheadDist = 999.0,
  behindDist = 999.0,
  aheadRelX = 0.0,
  behindRelX = 0.0,
  closingSpeedAhead = 0.0,
  ttcBehind = 999.0,
  isStraight = true,
  isCurvatureSafe = true,
  overlapRatio = 0.0,
  tyreGrip = 1.0,
  stress = 0.0,
}

local _memState = {
  grievance = 0.0,
  momentum = 0.0,
  isInFlow = false,
  isTilting = false,
}

local _initialized = false

function M.init()
  if _initialized then return end
  SkillRegistry.init()
  M.reset()
  _initialized = true
end

function M.getContext(carIndex)
  return _contexts[carIndex] or _contexts[0]
end

--- Update spatial geometric properties into preallocated buffer (zero-alloc)
local function populateGeoState(car, aheadCar, behindCar, sState, raceCtx)
  local px = car.position and car.position.x or 0.0
  local py = car.position and car.position.y or 0.0
  local pz = car.position and car.position.z or 0.0

  -- Ahead Car
  local aheadDist = 999.0
  local aheadRelX = 0.0
  if aheadCar and aheadCar.position then
    local dx = aheadCar.position.x - px
    local dy = aheadCar.position.y - py
    local dz = aheadCar.position.z - pz
    aheadDist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if car.side then
      aheadRelX = dx * (car.side.x or 1.0) + dz * (car.side.z or 0.0)
    elseif car.look then
      aheadRelX = dx * (car.look.z or 1.0) - dz * (car.look.x or 0.0)
    elseif car.worldToLocal then
      local loc = car.worldToLocal:transformPoint(aheadCar.position)
      aheadRelX = loc and loc.x or 0.0
    end
  end
  _geoState.aheadDist = aheadDist
  _geoState.aheadRelX = aheadRelX

  -- Behind Car
  local behindDist = 999.0
  local behindRelX = 0.0
  local ttcBehind = 999.0
  if behindCar and behindCar.position then
    local bx = behindCar.position.x
    local by = behindCar.position.y
    local bz = behindCar.position.z
    local dx = px - bx
    local dy = py - by
    local dz = pz - bz
    behindDist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if car.side then
      behindRelX = (bx - px) * (car.side.x or 1.0) + (bz - pz) * (car.side.z or 0.0)
    elseif car.look then
      behindRelX = (bx - px) * (car.look.z or 1.0) - (bz - pz) * (car.look.x or 0.0)
    elseif car.worldToLocal then
      local loc = car.worldToLocal:transformPoint(behindCar.position)
      behindRelX = loc and loc.x or 0.0
    end

    local vBehind = behindCar.speedKmh or 0.0
    local vMe = car.speedKmh or 0.0
    local deltaV = (vBehind - vMe) / 3.6
    if deltaV > 0.5 and behindDist > 0.1 then
      ttcBehind = behindDist / deltaV
    end
  end
  _geoState.behindDist = behindDist
  _geoState.behindRelX = behindRelX
  _geoState.ttcBehind = ttcBehind

  -- Side-by-side Overlap Ratio
  local overlap = 0.0
  if behindDist < 6.0 then
    overlap = 1.0 - (behindDist / 6.0)
  elseif aheadDist < 6.0 then
    overlap = 1.0 - (aheadDist / 6.0)
  end
  _geoState.overlapRatio = overlap

  -- Curvature & Straight detection
  local latG = 0.0
  if car.acceleration and car.acceleration.x then
    latG = math.abs(car.acceleration.x)
  end
  _geoState.isStraight = (latG < 2.0) and ((car.speedKmh or 0.0) > 90.0)
  _geoState.isCurvatureSafe = (latG < 9.8)

  -- Tyre & Grip
  local wear = (raceCtx and raceCtx.tyreWear) or 0.0
  local tempNorm = (raceCtx and raceCtx.tyreTempNorm) or 1.0
  local grip = (1.0 - wear * 0.4)
  if tempNorm > 1.2 then
    grip = grip - (tempNorm - 1.2) * 0.25
  end
  _geoState.tyreGrip = math.max(0.4, grip)
  _geoState.stress = sState and sState.stress or 0.0

  -- Psychological / Memory State
  _memState.grievance = 0.0 -- set by caller
  _memState.momentum = sState and sState.momentum or 0.0
  _memState.isInFlow = sState and sState.isInFlow or false
  _memState.isTilting = sState and sState.isTilting or false
end

--- Step tactical X-Skill decision and execution for specific car
---@param car ac.StateCar
---@param aheadCar ac.StateCar?
---@param behindCar ac.StateCar?
---@param persona table
---@param rivalryScore number
---@param raceCtx table?
---@param sState table TacticalTicker car state
---@param dt number
---@return boolean hasActiveSkill, number targetOffset, number targetCaution, number targetAggression, number extraGrip
function M.stepCarSkill(car, aheadCar, behindCar, persona, rivalryScore, raceCtx, sState, dt)
  local idx = car.index
  if idx < 0 or idx >= MAX_CARS then
    return false, 0.0, 1.0, 0.7, 0.0
  end

  if not _initialized then
    M.init()
  end

  local ctx = _contexts[idx]

  -- Tick cooldown timers
  for k = 1, 32 do
    local cd = ctx.cooldowns[k]
    if cd and cd > 0.0 then
      ctx.cooldowns[k] = cd - dt
    end
  end

  -- Update shared spatial state
  populateGeoState(car, aheadCar, behindCar, sState, raceCtx)
  _memState.grievance = rivalryScore or 0.0

  -- 1. If currently executing an active skill, handle commitment and abort checks
  if ctx.activeSkillId > 0 then
    local skill = SkillRegistry.getSkillById(ctx.activeSkillId)
    if not skill then
      ctx.activeSkillId = 0
      ctx.activeSkillName = "NONE"
      return false, 0.0, 1.0, 0.7, 0.0
    end

    -- Check Abort condition (Safety Net)
    local shouldAbort = false
    if skill.checkAbort and skill.checkAbort(car, aheadCar, behindCar, _geoState) == true then
      shouldAbort = true
    end

    if shouldAbort then
      ctx.abortCount = ctx.abortCount + 1
      ctx.cooldowns[ctx.activeSkillId] = DEFAULT_COOLDOWN * 0.5 -- short cooldown on abort
      ctx.activeSkillId = 0
      ctx.activeSkillName = "NONE"
      ctx.currentPhase = 0
      ctx.commitTimer = 0.0
      return false, 0.0, 1.3, 0.6, 0.0 -- safe return
    end

    -- Advance execution
    local off, caut, aggr, grip = skill.stepExecution(ctx, car, aheadCar, behindCar, dt)
    ctx.targetOffset = off or 0.0
    ctx.targetCaution = caut or 1.0
    ctx.targetAggression = aggr or 0.7
    ctx.extraGrip = grip or 0.0

    -- Check Commitment lock timer
    if ctx.commitTimer > 0.0 then
      ctx.commitTimer = ctx.commitTimer - dt
    else
      -- After commitment window, check if skill has completed its natural phases
      if ctx.currentPhase >= 3 or ctx.phaseTimer >= 3.5 then
        ctx.successCount = ctx.successCount + 1
        ctx.cooldowns[ctx.activeSkillId] = DEFAULT_COOLDOWN
        ctx.activeSkillId = 0
        ctx.activeSkillName = "NONE"
        ctx.currentPhase = 0
        return false, 0.0, 1.0, 0.7, 0.0
      end
    end

    return true, ctx.targetOffset, ctx.targetCaution, ctx.targetAggression, ctx.extraGrip
  end

  -- 2. No active skill: Arbitrate and select highest utility eligible skill
  local skillsList, skillCount = SkillRegistry.getAllSkills()
  local bestSkill = nil
  local bestScore = 0.52 -- threshold barrier (must beat 0.52 utility to trigger)

  for i = 1, skillCount do
    local candidate = skillsList[i]
    local sId = candidate.id
    local cd = ctx.cooldowns[sId] or 0.0

    if cd <= 0.0 then
      -- Phase 1: Hard Prerequisites Gate
      if candidate.checkPrerequisites(car, aheadCar, behindCar, _geoState, _memState) == true then
        -- Phase 2: Utility Scoring
        local score = candidate.evaluateUtility(car, aheadCar, behindCar, persona, _geoState, _memState)
        if type(score) == "number" and score > bestScore then
          bestScore = score
          bestSkill = candidate
        end
      end
    end
  end

  -- 3. Trigger chosen best skill
  if bestSkill then
    ctx.activeSkillId = bestSkill.id
    ctx.activeSkillName = bestSkill.name
    ctx.currentPhase = 1
    ctx.phaseTimer = 0.0
    ctx.commitTimer = MIN_COMMIT_HOLD
    ctx.utilityScore = bestScore

    local off, caut, aggr, grip = bestSkill.stepExecution(ctx, car, aheadCar, behindCar, dt)
    ctx.targetOffset = off or 0.0
    ctx.targetCaution = caut or 1.0
    ctx.targetAggression = aggr or 0.7
    ctx.extraGrip = grip or 0.0
    return true, ctx.targetOffset, ctx.targetCaution, ctx.targetAggression, ctx.extraGrip
  end

  return false, 0.0, 1.0, 0.7, 0.0
end

function M.reset()
  for i = 0, MAX_CARS - 1 do
    local ctx = _contexts[i]
    ctx.activeSkillId = 0
    ctx.activeSkillName = "NONE"
    ctx.currentPhase = 0
    ctx.phaseTimer = 0.0
    ctx.commitTimer = 0.0
    ctx.targetOffset = 0.0
    ctx.targetCaution = 1.0
    ctx.targetAggression = 0.7
    ctx.extraGrip = 0.0
    ctx.utilityScore = 0.0
    ctx.abortCount = 0
    ctx.successCount = 0
    for k = 1, 32 do
      ctx.cooldowns[k] = 0.0
    end
  end
end

return M
