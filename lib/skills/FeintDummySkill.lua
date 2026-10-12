--[[
  lib/skills/FeintDummySkill.lua
  X-Skill: Two-Phase Feint / Dummy Move
  
  Tactical Principle:
    On approach to a braking zone on a straight, the attacker feints to the outside line
    to bait the defender into covering that side, then rapidly cuts inside for the pass.
]]

local M = {}

M.id = 2
M.name = "FEINT_DUMMY"
M.category = "OFFENSE"

function M.checkPrerequisites(car, aheadCar, behindCar, geoState, memState)
  if not aheadCar or not car then return false end
  local aheadDist = geoState.aheadDist or 999.0
  if aheadDist > 14.0 or aheadDist < 4.0 then return false end

  -- Must be on a straight with decent closing speed
  if not geoState.isStraight or (car.speedKmh or 0.0) < 130.0 then
    return false
  end

  local deltaV = (aheadCar.speedKmh or 0.0) - (car.speedKmh or 0.0)
  -- closing in on ahead car (deltaV negative means we are faster)
  if deltaV > -2.0 then
    return false
  end

  return true
end

function M.evaluateUtility(car, aheadCar, behindCar, persona, geoState, memState)
  local aggr = persona and persona.base_aggression or 0.75
  local iq = persona and persona.racecraft_iq or 0.70
  local caution = persona and persona.base_caution or 1.0

  -- Favored by bold, aggressive drivers with high craft (e.g. Verstappen, Leclerc, Norris)
  local utility = (aggr * 0.45) + (iq * 0.35) + ((1.0 - math.min(1.0, caution)) * 0.20)
  return math.max(0.0, math.min(1.0, utility))
end

function M.stepExecution(skillCtx, car, aheadCar, behindCar, dt)
  skillCtx.phaseTimer = skillCtx.phaseTimer + dt

  if skillCtx.currentPhase == 1 then
    if skillCtx.phaseTimer >= 0.40 then
      skillCtx.currentPhase = 2
      skillCtx.phaseTimer = 0.0
      skillCtx.targetOffset = -0.50
      skillCtx.targetCaution = 0.20
      skillCtx.targetAggression = 0.98
    else
      -- Phase 1 (0.0 ~ 0.4s): Feint outside (+0.45 offset)
      skillCtx.targetOffset = 0.45
      skillCtx.targetCaution = 0.50
      skillCtx.targetAggression = 0.90
    end
  elseif skillCtx.currentPhase == 2 then
    -- Phase 2 (0.4 ~ 1.1s): Rapid dive inside (-0.50 offset)
    skillCtx.targetOffset = -0.50
    skillCtx.targetCaution = 0.20
    skillCtx.targetAggression = 0.98
    if skillCtx.phaseTimer >= 0.70 then
      skillCtx.currentPhase = 3
      skillCtx.phaseTimer = 0.0
    end
  else
    -- Phase 3: Hold inside overtake corridor
    skillCtx.targetOffset = -0.40
    skillCtx.targetCaution = 0.40
    skillCtx.targetAggression = 0.92
  end

  return skillCtx.targetOffset, skillCtx.targetCaution, skillCtx.targetAggression, 0.0
end

function M.checkAbort(car, aheadCar, behindCar, geoState)
  if not aheadCar then return true end
  if (geoState.aheadDist or 999.0) < 1.5 then
    return true
  end
  return false
end

return M
