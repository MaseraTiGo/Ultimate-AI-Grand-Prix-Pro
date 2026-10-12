--[[
  pit_strategy.lua
  Dynamic Undercut / Overcut comparison and pit timing selector.
  Instead of sticking strictly to pre-calculated targetLap, dynamically evaluates:
    Option 1: PIT NOW (Lap N) - Undercut candidate
    Option 2: PIT NEXT LAP (Lap N+1)
    Option 3: PIT +2 LAPS (Lap N+2) - Overcut candidate
  Considers:
    - Net tyre pace advantage (fresh tyre delta vs current tyre deg)
    - Traffic penalty at pit exit
    - Fuel remaining in tank (must have enough fuel to reach pit lap!)
    - Gap to car ahead / behind
    - Driver persona (undercut_preference vs overcut_preference)
]]

local M = {}

local function toNum(v, def)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
  end
  return def
end

--[[
  evaluatePitTimingOptions:
  Scores Pit Now vs Pit +1 vs Pit +2.
  @param input:
    - currentLap: integer
    - plannedPitLap: integer
    - fuelLapsRemaining: number
    - currentTyrePaceLoss: number (seconds/lap)
    - freshTyreAdvantage: number (seconds/lap)
    - gapAheadSec: number
    - gapBehindSec: number
    - exitTrafficPenaltyNow: number (seconds)
    - exitTrafficPenaltyLater: number (seconds)
    - persona: table of driver traits
    - scActive: boolean
]]
function M.evaluatePitTimingOptions(input)
  local currentLap   = toNum(input.currentLap, 1)
  local plannedLap   = toNum(input.plannedPitLap, 20)
  local fuelLaps     = toNum(input.fuelLapsRemaining, 10.0)
  local tyreLoss     = toNum(input.currentTyrePaceLoss, 0.5)
  local freshAdv     = toNum(input.freshTyreAdvantage, 1.0)
  local gapAhead     = toNum(input.gapAheadSec, 999.0)
  local gapBehind    = toNum(input.gapBehindSec, 999.0)
  local exitPenNow   = toNum(input.exitTrafficPenaltyNow, 0.0)
  local exitPenLater = toNum(input.exitTrafficPenaltyLater, 0.0)
  local persona      = input.persona or {}
  local scActive     = input.scActive or false

  local undercutPref = toNum(persona.undercut_preference, 0.5)
  local overcutPref  = toNum(persona.overcut_preference, 0.5)
  local riskTol      = toNum(persona.risk_tolerance, 0.5)

  local results = {}

  -- Condition A: Can we afford to Pit Now?
  -- (Always true if we have at least 0.1 laps of fuel, we are on in-lap)
  local canPitNow = true

  -- Condition B: Can we afford to extend +1 lap?
  local canPitPlus1 = fuelLaps >= 1.2

  -- Condition C: Can we afford to extend +2 laps?
  local canPitPlus2 = fuelLaps >= 2.2

  -- --- 1. Score PIT NOW (Undercut attempt) ---
  -- Undercut is powerful when:
  --   a) Stuck behind a car ahead within 1.5s (gapAhead < 1.5)
  --   b) Fresh tyres offer significant speed advantage (freshAdv > 0.8)
  --   c) Pit exit window is clean (exitPenNow is low)
  local scoreNow = 0.0

  if gapAhead < 1.8 and gapAhead > 0.1 then
    -- High undercut potential! Fresh tyre out-lap can leapfrog the car ahead
    scoreNow = scoreNow + 4.5 * (1.8 - gapAhead)
  end
  -- Fresh tyre gain
  scoreNow = scoreNow + (freshAdv * 1.5)
  -- Subtract dirty exit traffic
  scoreNow = scoreNow - (exitPenNow * 1.2)
  -- Persona weight
  scoreNow = scoreNow + ((undercutPref - 0.5) * 3.0)
  -- Proximity to planned target lap
  local lapDiff = plannedLap - currentLap
  if lapDiff <= 1 and lapDiff >= -1 then
    scoreNow = scoreNow + 3.0
  elseif lapDiff > 4 then
    scoreNow = scoreNow - 4.0 -- too early to box
  end

  if scActive then
    scoreNow = scoreNow + 6.0
  end

  results.pit_now = {
    valid = canPitNow,
    score = math.floor(scoreNow * 10 + 0.5) / 10,
    lap = currentLap,
    action = "PIT_NOW",
    tactic = (gapAhead < 1.8) and "UNDERCUT" or "NORMAL_BOX",
  }

  -- --- 2. Score PIT +1 LAP ---
  local scorePlus1 = 0.0
  if canPitPlus1 then
    -- Staying out 1 lap: suffers 1 lap of tyre degradation
    scorePlus1 = scorePlus1 - (tyreLoss * 1.0)
    -- If gap behind is small, pitting now might put us right behind traffic, staying out gives clean air
    if exitPenNow > 1.0 and exitPenLater < 0.5 then
      scorePlus1 = scorePlus1 + 3.0 -- wait for traffic window to clear
    end
    -- Proximity to planned lap
    if (plannedLap - (currentLap + 1)) == 0 then
      scorePlus1 = scorePlus1 + 3.5
    end
  else
    scorePlus1 = -999.0
  end

  results.pit_plus1 = {
    valid = canPitPlus1,
    score = math.floor(scorePlus1 * 10 + 0.5) / 10,
    lap = currentLap + 1,
    action = "PIT_PLUS_1",
    tactic = "EXTEND_ONE_LAP",
  }

  -- --- 3. Score PIT +2 LAPS (Overcut candidate) ---
  -- Overcut is powerful when:
  --   a) Car ahead pits first, giving us clean air
  --   b) Current tyres are not falling off a cliff
  --   c) Overcut preference is high
  local scorePlus2 = 0.0
  if canPitPlus2 then
    scorePlus2 = scorePlus2 - (tyreLoss * 2.2)
    scorePlus2 = scorePlus2 + ((overcutPref - 0.5) * 3.5)
    -- If in completely clean air (gapAhead > 4.0s), overcut can be effective
    if gapAhead > 4.0 then
      scorePlus2 = scorePlus2 + 2.5
    end
    if (plannedLap - (currentLap + 2)) == 0 then
      scorePlus2 = scorePlus2 + 3.0
    end
  else
    scorePlus2 = -999.0
  end

  results.pit_plus2 = {
    valid = canPitPlus2,
    score = math.floor(scorePlus2 * 10 + 0.5) / 10,
    lap = currentLap + 2,
    action = "PIT_PLUS_2",
    tactic = "OVERCUT",
  }

  -- Determine best choice
  local bestAction = "PIT_NOW"
  local bestScore = results.pit_now.score

  if results.pit_plus1.valid and results.pit_plus1.score > bestScore then
    bestAction = "PIT_PLUS_1"
    bestScore = results.pit_plus1.score
  end
  if results.pit_plus2.valid and results.pit_plus2.score > bestScore then
    bestAction = "PIT_PLUS_2"
    bestScore = results.pit_plus2.score
  end

  local bestOpt = results[bestAction == "PIT_NOW" and "pit_now" or (bestAction == "PIT_PLUS_1" and "pit_plus1" or "pit_plus2")]

  return {
    bestAction = bestAction,
    bestTactic = bestOpt.tactic,
    bestOption = bestOpt,
    options = results,
  }
end

return M
