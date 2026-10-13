--[[
  strategy_authority.lua
  Strategy Authority & Command Arbitration Layer for VF1 / AI Pit Control.

  Arbitrates strategy decisions among:
    1. EMERGENCY (Safety / Punctures / Out of Fuel) -> Priority 100
    2. SAFETY_CAR / SYSTEM (Cheap pit under SC, race regulations) -> Priority 80
    3. VALID HUMAN COMMAND (Human strategist override via Remote Server) -> Priority 60
    4. AI STRATEGY (Nominal dynamic race strategy engine) -> Priority 40
    5. DEFAULT FALLBACK -> Priority 10

  Manages three operational modes:
    - AI_CONTROL: 100% autonomous AI strategy
    - HUMAN_CONTROL: Human strategist holds execution authority (subject to validation)
    - HYBRID_CONTROL: AI generates recommendations; human accepts/modifies/rejects
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

-- Supported strategy commands from Human / Server
M.COMMANDS = {
  PIT_NOW           = "PIT_NOW",
  PIT_NEXT_LAP      = "PIT_NEXT_LAP",
  EXTEND_STINT      = "EXTEND_STINT",
  SHORTEN_STINT     = "SHORTEN_STINT",
  SET_TYRE          = "SET_TYRE",
  SET_FUEL_TARGET   = "SET_FUEL_TARGET",
  ACCEPT_AI_STRATEGY= "ACCEPT_AI_STRATEGY",
  OVERRIDE_STRATEGY = "OVERRIDE_STRATEGY",
}

M.MODES = {
  AI_CONTROL     = "AI_CONTROL",
  HUMAN_CONTROL  = "HUMAN_CONTROL",
  HYBRID_CONTROL = "HYBRID_CONTROL",
}

--[[
  createCarAuthorityState:
  Initializes per-car strategy authority state container.
]]
function M.createCarAuthorityState(carIndex)
  return {
    carIndex             = carIndex,
    mode                 = M.MODES.AI_CONTROL, -- Default to AI_CONTROL (safe fallback)
    assignedHumanId      = nil,
    assignedTeamName     = "AI Racing Team",
    humanControlActive   = false,
    lastHeartbeatTime    = 0,
    heartbeatTimeoutSec  = 5.0,  -- If client silent for > 5s, auto-fallback to AI

    -- Pending human strategy override
    pendingHumanCommand  = nil,
    activeOverride       = nil,  -- { action, tyre, fuelLiters, targetLap, source, deadlineLap, status }

    -- Strategy lock & decision deadline
    strategyWindowOpen   = true,
    decisionDeadlineLap  = nil,  -- e.g. Lap 17.5 (pit entry line)
    isDecisionLocked     = false,

    -- AI Recommendation for Hybrid mode
    aiRecommendation     = nil,  -- { pitLap, tyre, fuelDelta, confidence, reason }

    -- Timeline tracking
    strategyTimeline     = {},
  }
end

--[[
  validateHumanCommand:
  Verifies that a human strategist's command is legal, executable, and safe.
  @param authState: car authority state
  @param cmd: { command, carIndex, tyre, fuelLiters, targetLap, timestamp }
  @param raceContext: { currentLap, splinePos, isInPitlane, fuelInTank, fpl, scActive }
  @return ok: boolean, reason: string
]]
function M.validateHumanCommand(authState, cmd, raceContext)
  if not cmd or not cmd.command then
    return false, "Invalid or empty command"
  end

  local curLap = toNum(raceContext.currentLap, 1)
  local inPit  = raceContext.isInPitlane or false
  local spline = toNum(raceContext.splinePos, 0.0)
  local fuel   = toNum(raceContext.fuelInTank, 20.0)
  local fpl    = toNum(raceContext.fpl, 2.2)

  -- 1. Check Decision Deadline & Pit Entry Line Lock
  -- If car is already inside pit lane, cannot change pit intent for current in-lap
  if inPit then
    if cmd.command == M.COMMANDS.PIT_NOW or cmd.command == M.COMMANDS.EXTEND_STINT then
      return false, "REJECTED: Car is already committed inside pit lane"
    end
  end

  -- If commanding PIT_NOW when car has already passed the pit entry commit point (e.g. spline > 0.92 on final sector)
  if cmd.command == M.COMMANDS.PIT_NOW then
    if spline > 0.94 then
      return false, "REJECTED: Passed pit entry commit line for current lap (L" .. string.format("%.2f", curLap + spline) .. ")"
    end
  end

  -- 2. Fuel validation: If extending stint, check if fuel allows reaching that lap
  if cmd.command == M.COMMANDS.EXTEND_STINT or cmd.command == M.COMMANDS.PIT_NEXT_LAP then
    local lapsRemaining = (fpl > 0) and (fuel / fpl) or 10.0
    local lapsNeeded = (cmd.command == M.COMMANDS.PIT_NEXT_LAP) and 1.1 or 2.1
    if lapsRemaining < lapsNeeded then
      return false, string.format("REJECTED: Insufficient fuel to extend (have %.1f laps, need %.1f)", lapsRemaining, lapsNeeded)
    end
  end

  -- 3. Tyre selection validation
  if cmd.tyre then
    local tUpper = tostring(cmd.tyre):upper():gsub("^%s+", ""):gsub("%s+$", "")
    local validTyres = {
      SOFT = true, MEDIUM = true, HARD = true, INTERMEDIATE = true, WET = true,
      S = true, M = true, H = true, I = true, W = true, HR = true,
      SS = true, US = true, SUPERSOFT = true, ULTRASOFT = true,
      DRY = true, SLICK = true, C1 = true, C2 = true, C3 = true, C4 = true, C5 = true
    }
    local isValid = validTyres[tUpper] ~= nil
    if not isValid then
      if tUpper:find("SOFT") or tUpper:find("MED") or tUpper:find("HARD") or tUpper:find("WET") or tUpper:find("INTER") or tUpper:find("SLICK") or tUpper:find("DRY") then
        isValid = true
      end
    end
    if not isValid then
      return false, "REJECTED: Unknown tyre compound " .. tostring(cmd.tyre)
    end
  end

  -- 4. Fuel target validation (cannot exceed 150L or be negative)
  if cmd.fuelLiters ~= nil then
    local liters = toNum(cmd.fuelLiters, -1)
    if liters < 0 or liters > 150 then
      return false, "REJECTED: Target fuel out of physical bounds (0 - 150L)"
    end
  end

  return true, "VALID"
end

--[[
  arbitrateStrategy:
  Evaluates strategy priority and selects active execution directive.
  @param authState: car authority state
  @param aiPlan: nominal/dynamic AI plan from Strategy Engine
  @param raceContext: real-time car and race parameters
]]
function M.arbitrateStrategy(authState, aiPlan, raceContext)
  local nowTime = os.time()
  local curLap = toNum(raceContext.currentLap, 1)

  -- Check heartbeat for Human fail-safe:
  if authState.humanControlActive then
    if (nowTime - (authState.lastHeartbeatTime or 0)) > authState.heartbeatTimeoutSec then
      -- Human client timed out or disconnected!
      authState.humanControlActive = false
      authState.mode = M.MODES.AI_CONTROL
      table.insert(authState.strategyTimeline, {
        lap = curLap,
        time = nowTime,
        event = "FAILSAFE_TRIGGERED",
        detail = "Human strategist offline, AI Strategy took over immediately",
      })
    end
  end

  -- 1. Check for Pending Human Command
  local activeDirective = nil

  if authState.humanControlActive and authState.pendingHumanCommand then
    local cmd = authState.pendingHumanCommand
    local valid, reason = M.validateHumanCommand(authState, cmd, raceContext)

    if valid then
      activeDirective = {
        source        = "HUMAN",
        priority      = 60,
        command       = cmd.command,
        targetLap     = (cmd.command == M.COMMANDS.PIT_NOW) and curLap or ((cmd.command == M.COMMANDS.PIT_NEXT_LAP) and (curLap + 1) or cmd.targetLap),
        tyre          = cmd.tyre or "MEDIUM",
        fuelLiters    = cmd.fuelLiters,
        status        = "ACCEPTED",
        reason        = "Executed by Human Strategist",
      }
      authState.activeOverride = activeDirective
      table.insert(authState.strategyTimeline, {
        lap = curLap,
        time = nowTime,
        event = "HUMAN_COMMAND_ACCEPTED",
        command = cmd.command,
        detail = activeDirective,
      })
    else
      -- Command Rejected
      table.insert(authState.strategyTimeline, {
        lap = curLap,
        time = nowTime,
        event = "HUMAN_COMMAND_REJECTED",
        command = cmd.command,
        reason = reason,
      })
    end
    -- Clear pending once processed
    authState.pendingHumanCommand = nil
  end

  -- 2. Fallback to active override if still valid
  if not activeDirective and authState.activeOverride then
    if authState.activeOverride.targetLap and authState.activeOverride.targetLap >= curLap then
      activeDirective = authState.activeOverride
    else
      -- Override expired naturally
      authState.activeOverride = nil
    end
  end

  -- 3. Default to AI STRATEGY
  if not activeDirective then
    activeDirective = {
      source     = "AI",
      priority   = 40,
      command    = "NOMINAL_AI_PLAN",
      targetLap  = aiPlan and aiPlan.targetLap or (curLap + 5),
      openLap    = aiPlan and aiPlan.openLap or (curLap + 4),
      escalateLap= aiPlan and aiPlan.escalateLap or (curLap + 6),
      tactic     = aiPlan and aiPlan.tactic or "NORMAL",
      reason     = aiPlan and aiPlan.reason or "Running autonomous AI strategy",
    }
  end

  return activeDirective
end

--[[
  generateAiRecommendation:
  Produces recommendation card for Hybrid / Human consultation.
]]
function M.generateAiRecommendation(aiPlan, raceContext)
  if not aiPlan then return nil end
  return {
    recommendedAction = (aiPlan.targetLap == raceContext.currentLap) and "PIT_NOW" or "BOX_LAP_" .. tostring(aiPlan.targetLap),
    targetLap = aiPlan.targetLap,
    recommendedTyre = "MEDIUM",
    fuelDeltaLiters = aiPlan.fuelTargetLiters or 32.0,
    confidencePct = 85,
    expectedGainSec = 1.6,
    reason = aiPlan.reason or "Optimal tyre deg cross-over window",
  }
end

return M
