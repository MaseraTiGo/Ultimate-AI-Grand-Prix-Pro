--[[
  lib/skills/SwitchbackSkill.lua
  X-Skill: Late-Apex Switchback / Undercut Counter-Attack
  
  Tactical Principle:
    When a defending rival dives deep into the corner on the inside line,
    the attacker stays slightly wide on entry, squares off the corner at the apex,
    and applies power early to cut back underneath on the exit.
]]

local M = {}

M.id = 1
M.name = "SWITCHBACK"
M.category = "OFFENSE"

--- Check if physical & spatial conditions permit a Switchback attempt
function M.checkPrerequisites(car, aheadCar, behindCar, geoState, memState)
  if not aheadCar or not car then return false end
  local aheadDist = geoState.aheadDist or 999.0
  if aheadDist > 18.0 or aheadDist < 2.0 then return false end
  
  -- Speed gate: must be at racing speed, never on starting grid or slow crawl
  local mySpeed = car.speedKmh or 0.0
  if mySpeed < 70.0 then return false end

  -- Must be approaching or at a corner, not on high-speed flat-out straight
  if geoState.isCurvatureSafe and mySpeed > 220.0 then
    return false
  end

  -- Target ahead rival must be hugging or biased toward the inside line
  local aheadRelX = geoState.aheadRelX or 0.0
  if math.abs(aheadRelX) < 0.15 then
    -- Rival is in the dead center or outside, switchback less effective
    return false
  end

  return true
end

--- Calculate utility score [0.0 ~ 1.0] based on driver persona, tyre status, and opportunity
function M.evaluateUtility(car, aheadCar, behindCar, persona, geoState, memState)
  local aheadDist = geoState.aheadDist or 999.0
  local distFactor = 1.0 - (aheadDist / 18.0)
  if distFactor < 0.0 then distFactor = 0.0 end

  local iq = persona and persona.racecraft_iq or 0.70
  local patience = persona and persona.patience or 0.60
  local aggr = persona and persona.base_aggression or 0.75
  local tyreGrip = geoState.tyreGrip or 1.0

  -- Switchback is favored by high-IQ, patient, tactical drivers (e.g. Alonso, Hamilton, Sainz)
  local utility = (distFactor * 0.35) + (iq * 0.35) + (patience * 0.15) + (aggr * 0.15)
  utility = utility * tyreGrip

  return math.max(0.0, math.min(1.0, utility))
end

--- Step execution state machine for Switchback (Prep -> Apex Cut -> Exit Traction)
function M.stepExecution(skillCtx, car, aheadCar, behindCar, dt, geoState)
  skillCtx.phaseTimer = skillCtx.phaseTimer + dt

  -- Resolve ahead rival relative lateral position safely
  local aheadRelX = (geoState and geoState.aheadRelX) or 0.0
  if math.abs(aheadRelX) < 0.05 and aheadCar and aheadCar.position and car.position then
    local dx = aheadCar.position.x - car.position.x
    local dz = aheadCar.position.z - car.position.z
    if car.side then
      aheadRelX = dx * (car.side.x or 1.0) + dz * (car.side.z or 0.0)
    elseif car.look then
      aheadRelX = dx * (car.look.z or 1.0) - dz * (car.look.x or 0.0)
    end
  end

  -- Determine corner inside direction:
  -- If upcoming corner is right turn (angle > 0), inside line is + (right), outside prep is - (left).
  -- If upcoming corner is left turn (angle < 0), inside line is - (left), outside prep is + (right).
  local insideSign = 1.0
  if geoState and geoState.upcomingTurnAngle and math.abs(geoState.upcomingTurnAngle) > 0.04 then
    insideSign = (geoState.upcomingTurnAngle > 0) and 1.0 or -1.0
  else
    -- Fallback: if rival is on right (aheadRelX > 0), they are guarding inside right -> cutback inside is right (+1)
    insideSign = (aheadRelX >= 0) and 1.0 or -1.0
  end

  local cutMag = 0.45
  if geoState then
    local sideM = (insideSign > 0) and (geoState.trackRightM or 5.0) or (geoState.trackLeftM or 5.0)
    if sideM < 3.2 then
      cutMag = math.max(0.15, 0.45 * (sideM / 3.2))
    end
  end

  if skillCtx.currentPhase == 1 then
    -- Phase 1: Entry Prep (Stay wide opposite to inside apex)
    skillCtx.targetOffset = -insideSign * cutMag
    skillCtx.targetCaution = 1.10
    skillCtx.targetAggression = 0.75
    if skillCtx.phaseTimer >= 0.50 then
      skillCtx.currentPhase = 2
      skillCtx.phaseTimer = 0.0
    end
  elseif skillCtx.currentPhase == 2 then
    -- Phase 2: Square off apex & dive inside underneath
    skillCtx.targetOffset = insideSign * cutMag
    skillCtx.targetCaution = 0.25
    skillCtx.targetAggression = 0.95
    if skillCtx.phaseTimer >= 1.20 then
      skillCtx.currentPhase = 3
      skillCtx.phaseTimer = 0.0
    end
  else
    -- Phase 3: Straight exit acceleration
    skillCtx.targetOffset = 0.0
    skillCtx.targetCaution = 0.60
    skillCtx.targetAggression = 0.85
  end

  return skillCtx.targetOffset, skillCtx.targetCaution, skillCtx.targetAggression, 0.0
end

--- Abort condition: rival makes unexpected lateral snap or space vanishes (< 2m)
function M.checkAbort(car, aheadCar, behindCar, geoState)
  if not aheadCar then return true end
  if (geoState.aheadDist or 999.0) < 1.8 then
    return true -- avoid rear-end collision
  end
  return false
end

return M
