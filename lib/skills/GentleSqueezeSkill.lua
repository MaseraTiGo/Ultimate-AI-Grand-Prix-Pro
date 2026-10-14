--[[
  lib/skills/GentleSqueezeSkill.lua
  X-Skill: Gentle Squeeze & Dirty-Line Positioning
  
  Tactical Principle:
    When defending position against a tailing rival that starts to pull alongside,
    the defending car gently drifts toward the rival's line to squeeze their available width
    and force them onto the slippery marbles or undesirable entry angle.
]]

local M = {}

M.id = 3
M.name = "GENTLE_SQUEEZE"
M.category = "DEFENSE"

function M.checkPrerequisites(car, aheadCar, behindCar, geoState, memState)
  if not behindCar or not car then return false end
  local behindDist = geoState.behindDist or 999.0
  if behindDist > 25.0 or behindDist < 2.0 then return false end

  -- Speed gate: must be at racing speed, never on starting grid
  local mySpeed = car.speedKmh or 0.0
  if mySpeed < 70.0 then return false end

  -- Closing speed threat from behind (TTC < 2.0s)
  local ttcBehind = geoState.ttcBehind or 999.0
  if ttcBehind > 2.0 then return false end

  -- Curvature safety: cannot squeeze in heavy lateral G turns
  if not geoState.isCurvatureSafe then return false end

  return true
end

function M.evaluateUtility(car, aheadCar, behindCar, persona, geoState, memState)
  local block = persona and persona.block_tendency or 0.75
  local aggr = persona and persona.base_aggression or 0.70
  local iq = persona and persona.racecraft_iq or 0.75
  local grievance = memState and memState.grievance or 0.0

  -- Favored by stubborn defenders and seasoned masters (e.g. Alonso, Ocon, Perez, Verstappen)
  local utility = (block * 0.40) + (aggr * 0.25) + (iq * 0.25) + (grievance * 0.10)
  return math.max(0.0, math.min(1.0, utility))
end

function M.stepExecution(skillCtx, car, aheadCar, behindCar, dt)
  skillCtx.phaseTimer = skillCtx.phaseTimer + dt
  local behindRelX = 0.0
  if behindCar and behindCar.position and car.position then
    local bx = behindCar.position.x - car.position.x
    local bz = behindCar.position.z - car.position.z
    if car.side then
      behindRelX = bx * (car.side.x or 1.0) + bz * (car.side.z or 0.0)
    else
      behindRelX = bx
    end
  end

  -- Gentle Squeeze: push lateral offset toward rival with gentle rate
  local squeezeDir = (behindRelX > 0) and 1.0 or -1.0
  local blockWidth = 0.55 * squeezeDir

  skillCtx.targetOffset = blockWidth
  skillCtx.targetCaution = 0.35
  skillCtx.targetAggression = 0.90

  return skillCtx.targetOffset, skillCtx.targetCaution, skillCtx.targetAggression, 0.0
end

function M.checkAbort(car, aheadCar, behindCar, geoState)
  if not behindCar then return true end
  -- Overlap rule: if rival has established side-by-side overlap > 80%, cease aggressive squeeze to prevent pit maneuver
  if (geoState.overlapRatio or 0.0) > 0.80 then
    return true
  end
  return false
end

return M
