--[[
  lib/skills/TowWeaveSkill.lua
  X-Skill: Breaking the Tow / Straight Weaving Defense
  
  Tactical Principle:
    On high-speed straights when closely followed by a slipstreaming car,
    oscillate across the track to break the slipstream tow without making illegal blocking moves.
]]

local M = {}

M.id = 4
M.name = "TOW_WEAVE"
M.category = "DEFENSE"

function M.checkPrerequisites(car, aheadCar, behindCar, geoState, memState)
  if not behindCar or not car then return false end
  local behindDist = geoState.behindDist or 999.0
  -- Strict proximity window on high-speed straights: 4.5m to 22.0m
  if behindDist > 22.0 or behindDist < 4.5 then return false end

  -- Must be on an active high-speed straight
  if not geoState.isStraight or (car.speedKmh or 0.0) < 115.0 then
    return false
  end

  -- Trailing car must be aligned in the slipstream corridor (< 1.2m lateral offset)
  local relX = math.abs(geoState.behindRelX or 0.0)
  if relX > 1.2 then
    return false
  end

  -- Trailing car must be a real threat (closing in or low TTC)
  local ttc = geoState.ttcBehind or 999.0
  local vBehind = behindCar.speedKmh or 0.0
  local vMe = car.speedKmh or 0.0
  if ttc > 2.8 and vBehind < vMe - 0.5 then
    return false
  end

  -- Ahead must be clear
  if (geoState.aheadDist or 999.0) < 30.0 then
    return false
  end

  return true
end

function M.evaluateUtility(car, aheadCar, behindCar, persona, geoState, memState)
  local aggr = persona and persona.base_aggression or 0.70
  local block = persona and persona.block_tendency or 0.70

  -- Favored by aggressive defenders when hunted in DRS / tow
  local utility = (aggr * 0.60) + (block * 0.40)
  return math.max(0.0, math.min(1.0, utility))
end

function M.stepExecution(skillCtx, car, aheadCar, behindCar, dt)
  skillCtx.phaseTimer = skillCtx.phaseTimer + dt

  -- Oscillate weave: +/-0.35 spline units @ ~3.0 rad/s
  local offset = math.sin(skillCtx.phaseTimer * 3.0) * 0.35
  skillCtx.targetOffset = offset
  skillCtx.targetCaution = 0.80
  skillCtx.targetAggression = 0.85

  return skillCtx.targetOffset, skillCtx.targetCaution, skillCtx.targetAggression, 0.0
end

function M.checkAbort(car, aheadCar, behindCar, geoState)
  if not behindCar then return true end
  -- End of straight or rival dangerously close
  if not geoState.isStraight or (geoState.behindDist or 999.0) < 4.0 then
    return true
  end
  return false
end

return M
