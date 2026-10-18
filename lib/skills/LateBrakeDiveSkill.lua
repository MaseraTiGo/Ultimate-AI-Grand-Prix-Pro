--[[
  lib/skills/LateBrakeDiveSkill.lua
  X-Skill: Late-Braking Divebomb / Inside Line Overtake
  
  Tactical Principle:
    Into a heavy braking zone, the attacking driver brakes deeper than conventional,
    squeezes to the inside apex line, and claims corner rights before the defender turns in.
]]

local M = {}

M.id = 5
M.name = "LATE_BRAKE_DIVE"
M.category = "OFFENSE"

function M.checkPrerequisites(car, aheadCar, behindCar, geoState, memState)
  if not aheadCar or not car then return false end
  local aheadDist = geoState.aheadDist or 999.0
  if aheadDist > 16.0 or aheadDist < 2.5 then return false end

  -- Approaching braking zone
  local spd = car.speedKmh or 0.0
  if spd < 100.0 then return false end

  -- Sufficient tyre grip
  if (geoState.tyreGrip or 1.0) < 0.65 then
    return false -- Avoid lockup/skate on dying tyres
  end

  return true
end

function M.evaluateUtility(car, aheadCar, behindCar, persona, geoState, memState)
  local aggr = persona and persona.base_aggression or 0.75
  local caution = persona and persona.base_caution or 1.0
  local resist = persona and persona.pressure_resist or 0.70
  local aheadDist = geoState.aheadDist or 999.0

  local proxFactor = 1.0 - (aheadDist / 16.0)
  if proxFactor < 0.0 then proxFactor = 0.0 end

  -- Late brake dive is favored by hyper-aggressive late brakers (e.g. Verstappen, Tsunoda, Leclerc)
  local utility = (aggr * 0.45) + (proxFactor * 0.30) + (resist * 0.15) - (math.min(1.0, caution) * 0.15)
  return math.max(0.0, math.min(1.0, utility))
end

function M.stepExecution(skillCtx, car, aheadCar, behindCar, dt, geoState)
  skillCtx.phaseTimer = skillCtx.phaseTimer + dt

  -- Dynamic turn direction and track width safety envelope:
  local insideSign = -1.0
  local diveMag = 0.50

  if geoState and geoState.upcomingTurnAngle and math.abs(geoState.upcomingTurnAngle) > 0.04 then
    if geoState.upcomingTurnAngle > 0 then
      -- Right-hand corner: inside line is on the right (+)
      insideSign = 1.0
    else
      -- Left-hand corner: inside line is on the left (-)
      insideSign = -1.0
    end
  else
    -- Fallback when corner direction is unavailable: bias opposite to rival or toward wider track side
    local aheadRelX = (geoState and geoState.aheadRelX) or 0.0
    if aheadRelX > 0.15 then
      insideSign = -1.0
    elseif aheadRelX < -0.15 then
      insideSign = 1.0
    else
      local leftM = (geoState and geoState.trackLeftM) or 5.0
      local rightM = (geoState and geoState.trackRightM) or 5.0
      insideSign = (rightM >= leftM) and 1.0 or -1.0
    end
  end

  -- Scale dive magnitude to respect track boundary envelope (avoid clipping walls on narrow tracks)
  if geoState then
    local sideM = (insideSign > 0) and (geoState.trackRightM or 5.0) or (geoState.trackLeftM or 5.0)
    if sideM < 3.5 then
      local scale = math.max(0.15, (sideM - 1.5) / 2.0)
      diveMag = math.min(diveMag, 0.50 * scale)
    end
  end

  -- Squeeze inside line and drop caution to delay brake application
  skillCtx.targetOffset = insideSign * diveMag
  skillCtx.targetCaution = 0.20
  skillCtx.targetAggression = 0.98

  return skillCtx.targetOffset, skillCtx.targetCaution, skillCtx.targetAggression, 0.0
end

function M.checkAbort(car, aheadCar, behindCar, geoState)
  if not aheadCar then return true end
  if (geoState.aheadDist or 999.0) < 1.6 then
    return true -- prevent slamming into ahead car
  end
  return false
end

return M
