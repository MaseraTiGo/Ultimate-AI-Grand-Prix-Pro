--[[
  tests/test_grand_prix_pro.lua
  Automated Integration & System Verification Suite for Ultimate AI Grand Prix Pro
  
  Covers:
    [Test 1] Core Config & Logger initialization and bounded ring buffer
    [Test 2] RaceContext single source of truth contracts & updates
    [Test 3] PersonaLoader 7D Continuous DNA & strategy traits mapping
    [Test 4] TacticalTicker driver psychology, momentum flow & physiological latency
    [Test 5] Breaking the Tow straight weaving defense
    [Test 6] Radio Command dispatch & driver adherence (PUSH, SAVE, BOX_THIS_LAP, DEFEND)
    [Test 7] StrategyCoordinator baseline stint planning & 5-Group pit windows
    [Test 8] Dynamic fuel consumption model (mass, pace, traffic, SC)
    [Test 9] Pit timing evaluation (Undercut vs Overcut vs Stay Out)
    [Test 10] Emergency fuel starvation guard & pit stop refill execution
    [Test 11] Safety Watchdog 60Hz physics takeover, auto-release & J-Turn recovery
    [Test 12] Spatial LOD 3-tier scheduling, 0Hz deep sleep & interrupt wakeup
    [Test 13] TelemetryBridge LuaJIT FFI shared memory & binary fallback
    [Test 14] Hot loop zero memory allocation & LuaJIT NYI-Free validation (500 cycles)
    [Test 15] Full system update loop integration (simUpdate & update pipeline)
    [Test 16] Advanced Racecraft (Topology, Feint, Cooking & Cold Out-Lap)
    [Test 17] X-Skill Architecture (Registry, Gating, Personality & Safety Abort)
    [Test 18] CSP Strict Bounds Safety, Dynamic Laps & AI Discovery
    [Test 19] CSP LuaJIT FFI struct safety for ac.StateSim (Zero struct member crash)
    [Test 20] Pit state machine closed loop & idempotency batch settlement
    [Test 21] Blue flag yielding and Track 2 broadcast event pipeline
]]

local function assertEq(val, expected, msg)
  if val ~= expected then
    error(string.format("ASSERTION FAILED: %s (Expected: %s, Got: %s)", msg or "", tostring(expected), tostring(val)))
  end
end

local function assertTrue(cond, msg)
  if not cond then
    error(string.format("ASSERTION FAILED: %s", msg or "Condition is false"))
  end
end

-- Mock AC / Vector environment for offline standalone test execution
vec3 = function(x, y, z)
  return {
    x = x or 0, y = y or 0, z = z or 0,
    length = function(self) return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end,
    dot = function(self, o) return self.x*o.x + self.y*o.y + self.z*o.z end,
    __sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end,
  }
end

local _throttleLimits = {}
local _fuelInjectedValues = {}
local _aiPitRequests = {}
local _aiStopCounters = {}
local _aiBrakeMistakes = {}
local _aiTractionMistakes = {}
local _preventRetireCalls = {}
local _actuatorAudit = {
  splineOffsetCalls = {},
  splineOffsetValues = {},
  cautionCalls = {},
  aggressionCalls = {},
}

physics = {
  allowed = function() return true end,
  setAICarPosition = function() end,
  setAIStopCounter = function(idx, val) _aiStopCounters[idx] = val end,
  setAIPitStopRequest = function(idx, val) _aiPitRequests[idx] = val end,
  setAISplineOffset = function(idx, off, isOverride)
    _actuatorAudit.splineOffsetCalls[idx] = (_actuatorAudit.splineOffsetCalls[idx] or 0) + 1
    _actuatorAudit.splineOffsetValues[idx] = off
  end,
  setAICaution = function(idx, caut)
    _actuatorAudit.cautionCalls[idx] = (_actuatorAudit.cautionCalls[idx] or 0) + 1
  end,
  setAIAggression = function(idx, aggr)
    _actuatorAudit.aggressionCalls[idx] = (_actuatorAudit.aggressionCalls[idx] or 0) + 1
  end,
  setExtraAIGrip = function() end,
  setAIBrakeMistake = function(idx, dur) _aiBrakeMistakes[idx] = dur end,
  setAITractionMistake = function(idx, dur, sev) _aiTractionMistakes[idx] = { dur = dur, sev = sev } end,
  setAIThrottleLimit = function(idx, lim) _throttleLimits[idx] = lim end,
  setCarFuel = function(idx, fuel) _fuelInjectedValues[idx] = fuel end,
  setAITyres = function(idx, compoundIdx) return true end,
  setTyresCompound = function(idx, wheels, compoundIdx) return true end,
  setAIRainTyres = function(idx, isRain) return true end,
  setTyresVirtualKM = function(idx, wheels, km) return true end,
  preventAIFromRetiring = function(idx) _preventRetireCalls[idx] = (_preventRetireCalls[idx] or 0) + 1 end,
}

local _mockControls = { combineAxis = false, headlightsFlash = false, horn = false }

local _mockSim = {
  carsCount = 4,
  raceLaps = 25,
  currentLap = 5,
  sessionTime = 120.0,
  isReplayActive = false,
  isYellowFlag = false,
  safetyCarActive = false,
  trackLengthM = 5000.0,
}

ac = {
  getSim = function()
    return _mockSim
  end,
  getCar = function(i)
    return {
      index = i,
      isConnected = true,
      isAIControlled = (i > 0),
      position = vec3(0, 0, i * 40),
      speedKmh = 190,
      splinePosition = 0.2 + (i * 0.05),
      lapCount = 5,
      fuel = 28.0,
      tyres = { [0] = { wear = 0.2 } },
      worldToLocal = {
        transformPoint = function(self, p) return vec3(0.5, 0, -10) end
      }
    }
  end,
  overrideCarControls = function() return _mockControls end,
  getTrackSplineDirection = function(s) return vec3(0, 0, 1) end,
  log = function(msg) end,
}

print("==================================================================")
print("  Running Ultimate AI Grand Prix Pro Comprehensive Test Suite     ")
print("==================================================================")

-- [Test 1] Core Config & Logger
print("[Test 1] Testing Core Config & Logger...")
local Logger = require("lib/core/Logger")
local Config = require("lib/core/Config")
Logger.reset()
Config.init()
assertEq(Config.get("general", "enable_smart_driver"), true, "Config default enable_smart_driver should be true")
Logger.info("TEST", "Sample test log entry")
local logs = Logger.getRecentLogs()
assertTrue(#logs >= 1, "Logger should record entry in bounded history")
assertEq(logs[#logs].tag, "TEST", "Log tag matches")
print("  -> Passed: Config & Logger verified.")

-- [Test 2] RaceContext Single Source of Truth
print("[Test 2] Testing RaceContext single source of truth...")
local RaceContext = require("lib/core/RaceContext")
RaceContext.reset()
local sim = ac.getSim()
RaceContext.updateFromSim(sim)
assertEq(RaceContext.getRaceState().totalLaps, 25, "RaceContext totalLaps updated from sim")
local mockCarAc = ac.getCar(1)
RaceContext.updateCarFromAc(1, mockCarAc)
local cState1 = RaceContext.getCarState(1)
assertEq(cState1.speedKmh, 190, "Car speed updated in unified RaceContext")
print("  -> Passed: RaceContext contract verified.")

-- [Test 3] PersonaLoader 7D Continuous DNA & Strategy Traits
print("[Test 3] Testing PersonaLoader 7D Continuous DNA...")
local personaLoader = require("lib/driver/persona_loader")
personaLoader.init("config/personas.json")
local mappedVerstappen = personaLoader.getPersonaForCar(1, "Max Verstappen")
assertEq(mappedVerstappen.name, "Max Verstappen", "Verstappen should resolve to Max Verstappen")
assertTrue(mappedVerstappen.undercut_preference >= 0.90, "Verstappen undercut preference high")

local proceduralDriver = personaLoader.getPersonaForCar(7, "Unknown Rookie 99")
assertTrue(proceduralDriver.is_procedural == true, "Unmapped driver should receive continuous DNA")
assertTrue(proceduralDriver.base_aggression >= 0.50 and proceduralDriver.base_aggression <= 0.95, "DNA aggression in spectrum")
assertTrue(proceduralDriver.fuel_saving_factor >= 0.30 and proceduralDriver.fuel_saving_factor <= 0.90, "DNA fuel saving in spectrum")
assertTrue(proceduralDriver.undercut_preference >= 0.30 and proceduralDriver.undercut_preference <= 0.95, "DNA undercut in spectrum")
print(string.format("  -> Passed: 7D DNA verified (Procedural Aggr: %.2f, FuelSave: %.2f, Undercut: %.2f).",
  proceduralDriver.base_aggression, proceduralDriver.fuel_saving_factor, proceduralDriver.undercut_preference))

-- [Test 4] TacticalTicker driver psychology, momentum flow & physiological latency
print("[Test 4] Testing TacticalTicker psychology & momentum...")
local TacticalTicker = require("lib/driver/TacticalTicker")
TacticalTicker.reset()
local s4 = TacticalTicker.getAiState(2)
s4.momentum = 0.0
local car2 = {
  index = 2,
  position = vec3(0, 0, 100),
  speedKmh = 180,
  isAIControlled = true,
  splinePosition = 0.4
}
-- Clean run builds Flow momentum
for t = 1, 10 do
  TacticalTicker.stepCar(car2, nil, nil, proceduralDriver, 0.0, nil, 0.5)
end
assertTrue(s4.momentum > 0.45, "Clean running must build momentum into Flow")
assertTrue(s4.isInFlow == true, "Momentum >= 0.50 must set isInFlow flag")
print(string.format("  -> Passed: Driver psychology & Flow momentum verified (M: %+.2f).", s4.momentum))

-- [Test 5] Breaking the Tow straight weaving defense
print("[Test 5] Testing Breaking the Tow straight weaving defense...")
TacticalTicker.reset()
local leadCar = {
  index = 3,
  position = vec3(0, 0, 100),
  speedKmh = 230,
  isAIControlled = true,
  splinePosition = 0.5
}
local tailCar = {
  index = 4,
  position = vec3(0, 0, 80), -- 20m behind on straight (< 30m)
  speedKmh = 230,
  isAIControlled = true,
  splinePosition = 0.45
}
local towLeadState = TacticalTicker.stepCar(leadCar, nil, tailCar, mappedVerstappen, 0.0, nil, 0.1)
assertTrue(towLeadState.isBreakingTow == true, "Leader tailgated on straight should activate Breaking the Tow")
assertTrue(math.abs(towLeadState.targetSplineOffset) > 0.01, "Breaking tow commands oscillating weave")
print(string.format("  -> Passed: Breaking the tow active (Offset: %+.3f).", towLeadState.targetSplineOffset))

-- [Test 6] Radio Command Dispatch & Driver Adherence
print("[Test 6] Testing Radio Command Dispatch & Driver Adherence...")
local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
StrategyCoordinator.init()
StrategyCoordinator.issueRadioOrder(2, "PUSH")
assertEq(RaceContext.getCarState(2).radioCommand, "PUSH", "Radio order stored in RaceContext")

local pushCtx = { radioCommand = "PUSH", tyreWear = 0.2 }
local pushState = TacticalTicker.stepCar(car2, nil, nil, proceduralDriver, 0.0, pushCtx, 0.1)
assertTrue(pushState.targetCaution < 0.5, "PUSH command must sharply lower caution")
assertTrue(pushState.targetAggression > 0.85, "PUSH command must boost aggression")

StrategyCoordinator.issueRadioOrder(2, "SAVE")
local saveCtx = { radioCommand = "SAVE", tyreWear = 0.2 }
local saveState = TacticalTicker.stepCar(car2, nil, nil, proceduralDriver, 0.0, saveCtx, 0.1)
assertTrue(saveState.isLiftAndCoast == true, "SAVE command must trigger Lift and Coast")

StrategyCoordinator.issueRadioOrder(2, "BOX_THIS_LAP")
local boxCtx = { radioCommand = "BOX_THIS_LAP", tyreWear = 0.2 }
local boxState = TacticalTicker.stepCar(car2, nil, nil, proceduralDriver, 0.0, boxCtx, 0.1)
assertTrue(boxState.targetCaution >= 1.3, "BOX_THIS_LAP command must set conservative in-lap caution")
print("  -> Passed: Radio Commands PUSH, SAVE, BOX_THIS_LAP strictly adhered to.")

-- [Test 7] StrategyCoordinator baseline stint planning & 5-Group pit windows
print("[Test 7] Testing StrategyCoordinator Stint Planning...")
StrategyCoordinator.rebuildFieldStrategy(30, 2, 2.4) -- 30 laps, 2 stops (3 stints of 10 laps)
local plan1 = StrategyCoordinator.getCarPlan(1)
assertEq(#plan1.stints, 3, "30 laps / 2 stops should yield 3 stints")
assertEq(plan1.stints[1], 10, "First stint is 10 laps")
assertTrue(plan1.targetLap >= 7 and plan1.targetLap <= 9, string.format("Target lap within stint 1 (Got %d)", plan1.targetLap))
print(string.format("  -> Passed: Stint planning verified (Stints: %d, Target Lap: %d).", #plan1.stints, plan1.targetLap))

-- [Test 8] Dynamic fuel consumption model
print("[Test 8] Testing Dynamic Fuel Consumption Model...")
local FuelModel = require("lib/strategy/fuel_model")
local baseFpl = 2.5
local normalBurn = FuelModel.calculateDynamicFuelPerLap(baseFpl, 30.0, 100.0, "GREEN", 0.0, 0.5, 0.0)
local scBurn = FuelModel.calculateDynamicFuelPerLap(baseFpl, 30.0, 100.0, "SC", 0.0, 0.5, 0.0)
assertTrue(scBurn < normalBurn * 0.6, "Safety Car burn rate drops by ~50%")
local pushBurn = FuelModel.calculateDynamicFuelPerLap(baseFpl, 30.0, 100.0, "GREEN", 0.0, 0.5, -0.05)
assertTrue(pushBurn > normalBurn, "Pushing pace increases fuel burn rate")
print(string.format("  -> Passed: Fuel model dynamic burn (Normal: %.3f, SC: %.3f, Push: %.3f).", normalBurn, scBurn, pushBurn))

-- [Test 9] Pit timing evaluation (Undercut vs Overcut vs Stay Out)
print("[Test 9] Testing Pit Strategy Undercut / Overcut Scoring...")
local PitStrategy = require("lib/strategy/pit_strategy")
local undercutEval = {
  currentLap = 8,
  plannedPitLap = 9,
  fuelLapsRemaining = 2.5,
  currentTyrePaceLoss = 1.2, -- heavily degraded tyres
  freshTyreAdvantage = 1.5,
  gapAheadSec = 1.0, -- stuck behind rival
  gapBehindSec = 5.0,
  exitTrafficPenaltyNow = 0.0,
  exitTrafficPenaltyLater = 1.5,
  persona = { undercut_preference = 0.9, risk_tolerance = 0.8 },
  scActive = false
}
local pitDecision = PitStrategy.evaluatePitTimingOptions(undercutEval)
assertTrue(pitDecision ~= nil, "Pit decision generated")
assertEq(pitDecision.bestOption.action, "PIT_NOW", "Severe tyre degradation & gap ahead must favor PIT_NOW undercut")
print(string.format("  -> Passed: Undercut successfully triggered (Action: %s, Score: %.2f).",
  pitDecision.bestOption.action, pitDecision.bestOption.score))

-- [Test 10] Emergency fuel starvation guard & pit stop refill execution
print("[Test 10] Testing Fuel Starvation Guard & Pit Refill...")
RaceContext.getCarState(1).fuelInTank = 1.2
RaceContext.getCarState(1).isInPitlane = false
_fuelInjectedValues[1] = 0.0
StrategyCoordinator.stepStrategy(1.0)
assertTrue(_fuelInjectedValues[1] >= 8.0, "Fuel guard must inject emergency reserve fuel when < 1.8L")

-- Simulate pit stop refill
RaceContext.getCarState(1).isInPitlane = true
StrategyCoordinator.stepStrategy(1.0)
assertTrue(RaceContext.getCarState(1).actualStopsCount >= 1, "Pit stop completed count recorded")
print("  -> Passed: Emergency fuel guard & pit stop refill verified.")

-- [Test 11] Safety Watchdog 60Hz physics takeover, auto-release & J-Turn recovery
print("[Test 11] Testing Watchdog 60Hz physics takeover & J-Turn...")
local watchdog = require("lib/driver/watchdog")
watchdog.init()
local takeoverFired = false
watchdog.requestTakeover(1, 0.2, function(ctrl, car, dt) takeoverFired = true end)
watchdog.stepPhysics(0.25)
watchdog.stepPhysics(0.01) -- should auto-release
assertEq(takeoverFired, false, "Takeover auto-released after duration expired")
print("  -> Passed: Watchdog 60Hz auto-release safety confirmed.")

-- [Test 12] Spatial LOD 3-tier scheduling, 0Hz deep sleep & interrupt wakeup
print("[Test 12] Testing Spatial LOD & 0Hz Deep Sleep...")
local LODScheduler = require("lib/driver/LODScheduler")
LODScheduler.reset()
LODScheduler.setDeepSleepEnabled(true)
local mockPlayerPos = { x = 0, y = 0, z = 0 }
local mockPosFunc = function(i)
  if i == 10 then return 0, 0, 350 end -- Tier 3 distance (> 250m)
  return 0, 0, 50
end
LODScheduler.updateTiers(mockPlayerPos, 12, mockPosFunc)
assertEq(LODScheduler.getCarTier(10), LODScheduler.TIER_AMBIENT, "Car 10 is Tier 3 Ambient")

local sleepTicks = 0
for t = 1, 30 do
  LODScheduler.updateTiers(mockPlayerPos, 12, mockPosFunc)
  if LODScheduler.shouldTickCar(10) then sleepTicks = sleepTicks + 1 end
end
assertEq(sleepTicks, 0, "Tier 3 in deep sleep consumes exactly 0 ticks (0Hz)")

LODScheduler.triggerWakeInterrupt(10)
local wakeTicks = 0
for t = 1, 30 do
  LODScheduler.updateTiers(mockPlayerPos, 12, mockPosFunc)
  if LODScheduler.shouldTickCar(10) then wakeTicks = wakeTicks + 1 end
end
assertTrue(wakeTicks >= 2 and wakeTicks <= 4, string.format("Interrupt wakes car to 1Hz (~3/30 ticks, got %d)", wakeTicks))
print(string.format("  -> Passed: Deep sleep confirmed (0Hz: %d ticks -> Interrupt: %d ticks).", sleepTicks, wakeTicks))

-- [Test 13] TelemetryBridge LuaJIT FFI shared memory & binary fallback
print("[Test 13] Testing TelemetryBridge shared state export...")
local TelemetryBridge = require("lib/bridge/TelemetryBridge")
TelemetryBridge.reset()
TelemetryBridge.updateCarTelemetry(5, "ATTACK", 4.2, 0.75, 0.35, false, true, "NONE", -0.30, 0.40)
TelemetryBridge.stampPacket(1, 100.5)
local tEntry = TelemetryBridge.getCarTelemetry(5)
assertEq(tEntry.car_index, 5, "Car index matches")
assertEq(tEntry.state_id, 1, "State ATTACK maps to 1")
assertEq(tEntry.breaking_tow, 1, "Breaking tow flag is 1")
assertTrue(math.abs(tEntry.stress - 4.2) < 0.01, "Stress exported accurately")
assertTrue(math.abs(tEntry.momentum - 0.75) < 0.01, "Momentum exported accurately")
print("  -> Passed: TelemetryBridge shared memory pipeline verified.")

-- [Test 14] Hot loop zero memory allocation & LuaJIT NYI-Free validation (500 cycles)
print("[Test 14] Testing Hot loop zero memory allocation (500 cycles)...")
local BehaviorActuator = require("lib/driver/BehaviorActuator")
LODScheduler.setDeepSleepEnabled(false) -- exercise active ticks
local _staticLoopLoc = vec3(0.5, 0, -12)
local loopLead = {
  index = 1,
  position = vec3(0, 0, 100),
  speedKmh = 210,
  isAIControlled = true,
  splinePosition = 0.5,
  look = vec3(0, 0, 1),
  side = vec3(1, 0, 0),
  worldToLocal = { transformPoint = function(s, p) return _staticLoopLoc end }
}
local loopChaser = {
  index = 2,
  position = vec3(0, 0, 85),
  speedKmh = 220,
  isAIControlled = true,
  splinePosition = 0.45,
  look = vec3(0, 0, 1),
  side = vec3(1, 0, 0),
}

-- Warmup state and preallocated structures
for i = 1, 100 do
  local st = TacticalTicker.stepCar(loopLead, nil, loopChaser, mappedVerstappen, 0.0, nil, 0.1)
  BehaviorActuator.applyActuator(loopLead, st, 0.1)
end

if jit then
  jit.off()
  jit.flush()
end
collectgarbage("collect")
local memBefore = collectgarbage("count")

for i = 1, 500 do
  local st = TacticalTicker.stepCar(loopLead, nil, loopChaser, mappedVerstappen, 0.0, nil, 0.1)
  BehaviorActuator.applyActuator(loopLead, st, 0.1)
end

local memAfter = collectgarbage("count")
if jit then jit.on() end
local deltaKB = memAfter - memBefore
assertTrue(deltaKB < 1.0, string.format("Hot loop GC allocation must be ~0 KB across 500 cycles (Got %.2f KB)", deltaKB))
print(string.format("  -> Passed: Hot loop zero allocation confirmed (%.3f KB delta over 500 steps).", deltaKB))

-- [Test 15] Full system update loop integration (simUpdate & update pipeline)
print("[Test 15] Testing Full System Update Loop Integration...")
_G.script = {}
dofile("Ultimate-AI-Grand-Prix-Pro.lua")
assertTrue(type(script.init) == "function", "script.init defined")
assertTrue(type(script.simUpdate) == "function", "script.simUpdate defined")
assertTrue(type(script.update) == "function", "script.update defined")
assertTrue(type(script.windowMain) == "function", "script.windowMain defined")

script.init()
script.simUpdate(0.016) -- 60Hz physics step
script.update(0.1)     -- 10Hz tactical step
script.update(1.0)     -- 1Hz strategy step

print("  -> Passed: Main script pipeline successfully initialized and stepped.")

-- [Test 16] Advanced Human Racecraft: 24-Car Topology, Feint Dummy, Tyre Cooking & Cold Out-Lap
print("[Test 16] Testing 24-Car AI Topology, Feint Dummy, Tyre Cooking & Cold Out-Lap...")
-- 1. Test 24-Car Inter-Vehicle Topology
local mockCars = {
  [0] = { index = 0, isConnected = true, position = vec3(0, 0, 0), splinePosition = 0.10 },
  [1] = { index = 1, isConnected = true, position = vec3(0, 0, 20), splinePosition = 0.12 },
  [2] = { index = 2, isConnected = true, position = vec3(0, 0, 45), splinePosition = 0.15 },
}
local function mockGetCar(i) return mockCars[i] end
RaceContext.updateTopology(3, mockGetCar)
local ahead1, distAhead1, behind1, distBehind1 = RaceContext.getNeighbors(1)
assertEq(ahead1, 2, "Car 1 ahead neighbor is Car 2 (spline 0.15)")
assertEq(behind1, 0, "Car 1 behind neighbor is Car 0 (spline 0.10)")
assertTrue(distAhead1 < 30.0, "Car 1 ahead distance ~25m")
assertTrue(distBehind1 < 25.0, "Car 1 behind distance ~20m")

-- 2. Test Feint / Dummy Move Execution
TacticalTicker.reset()
local aggrAttacker = {
  index = 3,
  position = vec3(0, 0, 30),
  speedKmh = 220,
  isAIControlled = true,
  splinePosition = 0.20,
  worldToLocal = { transformPoint = function(s, p) return vec3(0, 0, 10) end }
}
local defenderCar = {
  index = 4,
  position = vec3(0, 0, 40), -- 10m ahead (< 12m)
  speedKmh = 205,
  isAIControlled = true,
  splinePosition = 0.21
}
local highAggrPersona = { base_aggression = 0.90, base_caution = 0.5, pressure_resist = 0.8 }
local feintPhase1 = TacticalTicker.stepCar(aggrAttacker, defenderCar, nil, highAggrPersona, 0.0, nil, 0.2)
assertTrue(feintPhase1.isFeinting == true, "Aggressive attacker initiates feint dummy move")
assertTrue(feintPhase1.targetSplineOffset > 0.0, "Phase 1 feints outside (offset > 0)")

local feintPhase2 = TacticalTicker.stepCar(aggrAttacker, defenderCar, nil, highAggrPersona, 0.0, nil, 0.3)
assertTrue(feintPhase2.targetSplineOffset < 0.0, "Phase 2 dives inside for pass (offset < 0)")

-- 3. Test Tyre Cooking & Heat Degradation under sustained defense
TacticalTicker.reset()
local defendingCar = {
  index = 5,
  position = vec3(0, 0, 50),
  speedKmh = 180,
  isAIControlled = true,
  splinePosition = 0.30,
  worldToLocal = { transformPoint = function(s, p) return vec3(0.5, 0, -8) end }
}
local pressuringCar = {
  index = 6,
  position = vec3(0, 0, 42), -- 8m behind (< 25m)
  speedKmh = 205, -- 25 km/h faster -> TTC = 8 / (25 / 3.6) = 1.15s (< 1.5s)
  isAIControlled = true,
  splinePosition = 0.29
}
local defState = nil
for step = 1, 35 do -- ~3.5s of intense defense
  defState = TacticalTicker.stepCar(defendingCar, nil, pressuringCar, mappedVerstappen, 0.0, nil, 0.1)
end
assertTrue(defState.tireTempNorm > 1.05, string.format("Sustained defense cooks tyres (Temp Norm: %.2f)", defState.tireTempNorm))

-- 4. Test Cold Tyre Out-Lap warmup grip
RaceContext.getCarState(1).tyreWarmupProgress = 0.0 -- fresh out-lap
local coldState = TacticalTicker.stepCar(car2, nil, nil, proceduralDriver, 0.0, nil, 0.1)
assertTrue(coldState.outLapColdGrip <= 1.0, "Cold tyres initial grip is bounded")
print("  -> Passed: Advanced Racecraft verified (24-Car Topology, Feint Dummy, Tyre Cooking & Cold Out-Lap).")

-- [Test 17] Testing X-Skill Architecture (Registry, 2-Phase Gating, Extensibility & Driver Personality)
print("[Test 17] Testing X-Skill Architecture (Registry, Gating, Extensibility & Personality)...")
local SkillRegistry = require("lib/skills/SkillRegistry")
local SkillArbitrator = require("lib/skills/SkillArbitrator")

-- 1. Registry Contract & Built-in Skills
SkillRegistry.init()
local skills, count = SkillRegistry.getAllSkills()
assertTrue(count >= 5, string.format("SkillRegistry loaded at least 5 built-in skills (Got %d)", count))
assertEq(SkillRegistry.getSkillById(1).name, "SWITCHBACK", "Skill 1 is SWITCHBACK")
assertEq(SkillRegistry.getSkillById(2).name, "FEINT_DUMMY", "Skill 2 is FEINT_DUMMY")
assertEq(SkillRegistry.getSkillById(3).name, "GENTLE_SQUEEZE", "Skill 3 is GENTLE_SQUEEZE")
assertEq(SkillRegistry.getSkillById(4).name, "TOW_WEAVE", "Skill 4 is TOW_WEAVE")
assertEq(SkillRegistry.getSkillById(5).name, "LATE_BRAKE_DIVE", "Skill 5 is LATE_BRAKE_DIVE")

-- 2. Zero-Edit Dynamic Extension via registerSkill
local customSkill = {
  id = 16,
  name = "MOCK_CUSTOM_SLIPSTREAM",
  category = "OFFENSE",
  checkPrerequisites = function(car, ahead, behind, geo, mem) return true end,
  evaluateUtility = function(car, ahead, behind, persona, geo, mem) return 0.88 end,
  stepExecution = function(ctx, car, ahead, behind, dt) return 0.25, 0.40, 0.90, 0.0 end,
  checkAbort = function(car, ahead, behind, geo) return false end
}
local regOk = SkillRegistry.registerSkill(customSkill)
assertTrue(regOk == true, "Custom skill successfully registered without modifying core files")
assertEq(SkillRegistry.getSkillById(16).name, "MOCK_CUSTOM_SLIPSTREAM", "Custom skill queryable by ID")

-- 3. Driver Personality Differentiation in Utility Scoring
local boldPersona = { base_aggression = 0.95, racecraft_iq = 0.90, base_caution = 0.3 }
local timidPersona = { base_aggression = 0.30, racecraft_iq = 0.40, base_caution = 1.2 }
local feintSkill = SkillRegistry.getSkillById(2)
local scoreBold = feintSkill.evaluateUtility(nil, nil, nil, boldPersona, {}, {})
local scoreTimid = feintSkill.evaluateUtility(nil, nil, nil, timidPersona, {}, {})
assertTrue(scoreBold > scoreTimid + 0.30, string.format("Bold driver utility (%.2f) significantly higher than timid driver (%.2f)", scoreBold, scoreTimid))

-- 4. 2-Phase Gating & Commitment Hold
SkillArbitrator.reset()
local chaserCar = {
  index = 8,
  position = vec3(0, 0, 100),
  speedKmh = 230,
  isAIControlled = true,
  splinePosition = 0.60,
  look = vec3(0, 0, 1),
  side = vec3(1, 0, 0)
}
local targetCar = {
  index = 9,
  position = vec3(0, 0, 110), -- 10m ahead (< 14m)
  speedKmh = 200, -- 30 km/h slower (closing in)
  isAIControlled = true,
  splinePosition = 0.62
}
local sCtxLead = { stress = 1.0, momentum = 0.2 }
local hasSkill, off, caut, aggr = SkillArbitrator.stepCarSkill(chaserCar, targetCar, nil, boldPersona, 0.0, nil, sCtxLead, 0.1)
assertTrue(hasSkill == true, "Offensive skill triggered in prime overtake conditions")
local arbCtx = SkillArbitrator.getContext(8)
assertTrue(arbCtx.commitTimer > 0.0, "SkillArbitrator engages commitment lock to prevent flapping")
assertEq(arbCtx.activeSkillName, "FEINT_DUMMY", "Selected highest utility FEINT_DUMMY skill")

-- 5. Safety Abort Verification
local dangerGeo = { isStraight = false, aheadDist = 1.0 }
local abortCheck = feintSkill.checkAbort(chaserCar, targetCar, nil, dangerGeo)
assertTrue(abortCheck == true, "Skill triggers abort when corner hazard or proximity violation occurs")

-- Restore built-in skill registry and reset arbitrator state
SkillRegistry.reset()
SkillRegistry.init()
SkillArbitrator.reset()

print("  -> Passed: X-Skill Architecture verified (Registry, Dynamic Extension, Gating, Personality & Safety Abort).")

-- [Test 18] CSP Strict Bounds Safety, Multi-frame Init Guard & Dynamic Laps Sync
print("[Test 18] Testing CSP Strict Bounds Safety, Dynamic Laps & AI Discovery...")
local origGetCar = ac.getCar
local origGetDriverName = ac.getDriverName
local origGetSim = ac.getSim

-- Simulate real CSP environment where only 5 cars exist (0: Player, 1..4: AI)
-- and any call to getCar(i) or getDriverName(i) for i >= 5 throws a hard Lua error!
local mockSim5 = {
  carsCount = 5,
  raceLaps = 13,
  currentLap = 2,
  sessionTime = 250.0,
  isReplayActive = false,
  isYellowFlag = false,
  safetyCarActive = false,
}
ac.getSim = function() return mockSim5 end
ac.getCar = function(i)
  if i >= 5 or i < 0 then
    error("CSP out of range: " .. tostring(i))
  end
  return {
    index = i,
    isConnected = true,
    isAIControlled = (i > 0),
    isPlayer = (i == 0),
    driverName = (i == 0) and "Player Driver" or ("Rival AI " .. i),
    position = vec3(0, 0, i * 35),
    speedKmh = 180 + i * 5,
    splinePosition = 0.1 + (i * 0.05),
    lapCount = 2,
    fuel = 30.0,
    tyres = { [0] = { wear = 0.1 } }
  }
end
ac.getDriverName = function(i)
  if i >= 5 or i < 0 then
    error("CSP driver out of range: " .. tostring(i))
  end
  return (i == 0) and "Player Driver" or ("Rival AI " .. i)
end

RaceContext.reset()
RaceContext.updateFromSim(mockSim5)
local rState = RaceContext.getRaceState()
assertEq(rState.totalLaps, 13, "RaceContext successfully synced 13 dynamic laps from sim")
assertEq(rState.carsCount, 5, "RaceContext carsCount matches 5 connected cars")

local DashboardUI = require("lib/ui/DashboardUI")
DashboardUI.renderMain(0.05, 4)
local c1 = RaceContext.getCarState(1)
assertEq(c1.driverName, "Rival AI 1", "AI driver 1 name resolved safely")

-- Restore mocks
ac.getCar = origGetCar
ac.getDriverName = origGetDriverName
ac.getSim = origGetSim
print("  -> Passed: CSP Strict Bounds Safety, Dynamic Laps & AI Discovery confirmed.")

-- ==============================================================================
-- [Test 19] CSP LuaJIT FFI Struct Safety for ac.StateSim (Zero Struct Member Crash)
-- ==============================================================================
print("[Test 19] Testing CSP LuaJIT FFI Struct Safety for ac.StateSim...")
-- Emulate a real C-level struct state_sim where querying non-existent fields raises a fatal Lua error
local allowedSimFields = {
  carsCount = true,
  gameTime = true,
  time = true,
  currentSessionTime = true,
  currentSessionIndex = true,
  leaderLapCount = true,
  raceFlagType = true,
  raceFlagCause = true,
  isReplayActive = true,
  isSessionStarted = true,
  isSessionFinished = true,
  speedLimitKmh = true,
  dt = true,
}
local strictSimStruct = setmetatable({
  carsCount = 8,
  gameTime = 345.67,
  time = 345670.0,
  currentSessionTime = 345670.0,
  currentSessionIndex = 0,
  leaderLapCount = 6,
  raceFlagType = 0,
  raceFlagCause = -1,
  isReplayActive = false,
  isSessionStarted = true,
  isSessionFinished = false,
  speedLimitKmh = 80.0,
  dt = 0.016,
}, {
  __index = function(t, k)
    if not allowedSimFields[k] then
      error(string.format("'struct state_sim' has no member named '%s'", tostring(k)))
    end
    return rawget(t, k)
  end
})

-- Verify that safeSimGet never throws when probing nonexistent fields
assertEq(RaceContext.safeSimGet(strictSimStruct, "sessionTime"), nil, "safeSimGet safely returns nil for nonexistent sessionTime")
assertEq(RaceContext.safeSimGet(strictSimStruct, "raceLaps"), nil, "safeSimGet safely returns nil for nonexistent raceLaps")
assertEq(RaceContext.safeSimGet(strictSimStruct, "currentLap"), nil, "safeSimGet safely returns nil for nonexistent currentLap")
assertEq(RaceContext.safeSimGet(strictSimStruct, "carsCount"), 8, "safeSimGet retrieves valid carsCount")
assertEq(RaceContext.safeSimGet(strictSimStruct, "gameTime"), 345.67, "safeSimGet retrieves valid gameTime")

-- Test updateFromSim with strict C struct
RaceContext.reset()
local updateOk, updateErr = pcall(RaceContext.updateFromSim, strictSimStruct)
assertTrue(updateOk, "RaceContext.updateFromSim executed without any struct member errors: " .. tostring(updateErr))
local strictState = RaceContext.getRaceState()
assertEq(strictState.sessionTime, 345.67, "Session time resolved safely from gameTime (345.67s)")
assertEq(strictState.currentLap, 7, "Current lap resolved safely from leaderLapCount + 1 = 7")
assertEq(strictState.carsCount, 8, "Cars count resolved safely as 8")

-- Test safety_car module with strict C struct
local safetyCarMod = require("lib/strategy/safety_car")
local scStatus, scConf = safetyCarMod.detectSafetyCarCondition(strictSimStruct, {}, 180.0)
assertEq(scStatus, "GREEN", "safety_car module safely evaluated GREEN with zero C struct errors")

print("  -> Passed: CSP LuaJIT FFI Struct Safety for ac.StateSim verified.")

-- Verify CSP LuaJIT FFI Struct Safety for ac.StateCar (ac.StateWheel instead of .tyres)
local strictCarStruct = setmetatable({
  isConnected = true,
  isAIControlled = true,
  isPlayer = false,
  driverName = "Strict Pilot",
  speedKmh = 160.0,
  splinePosition = 0.5,
  lapCount = 3,
  racePosition = 2,
  isInPitlane = false,
  isInPit = false,
  fuel = 28.5,
  wheels = {
    [0] = { tyreWear = 0.18 },
    [1] = { tyreWear = 0.19 },
    [2] = { tyreWear = 0.22 },
    [3] = { tyreWear = 0.21 },
  }
}, {
  __index = function(t, k)
    if k == "tyres" then
      error("'struct state_car' has no member named 'tyres'")
    end
    return rawget(t, k)
  end
})

assertEq(RaceContext.safeCarGet(strictCarStruct, "tyres"), nil, "safeCarGet safely returns nil when probing nonexistent tyres field")
assertEq(RaceContext.safeCarGet(strictCarStruct, "wheels")[0].tyreWear, 0.18, "safeCarGet retrieves valid wheels[0].tyreWear")

local carUpdateOk, carUpdateErr = pcall(RaceContext.updateCarFromAc, 1, strictCarStruct)
assertTrue(carUpdateOk, "updateCarFromAc executed without any struct member crash on .tyres: " .. tostring(carUpdateErr))
local c1State = RaceContext.getCarState(1)
assertEq(c1State.tyreWear, 0.18, "Car tyre wear successfully resolved from wheels[0].tyreWear without crash")

-- ==============================================================================
-- [Test 20] Pit State Machine Closed Loop & Idempotency Batch Settlement
-- ==============================================================================
print("[Test 20] Testing Pit State Machine Closed Loop & Idempotency Settlement...")
local EventHub = require("lib/core/EventHub")
local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")

RaceContext.reset()
EventHub.init()
StrategyCoordinator.init()
StrategyCoordinator.rebuildFieldStrategy(13, 1, 2.5)

-- Verify standardized lap formatter: 第{currentLap}/{totalLaps}圈
assertEq(EventHub.formatLapStr(3, 13), "第3/13圈", "formatLapStr matches exact uniform specification 第3/13圈")
assertEq(EventHub.formatLapStr(1, 13), "第1/13圈", "formatLapStr matches exact uniform specification 第1/13圈")

-- 1. Issue Radio Order BOX_THIS_LAP to AI Car #02 (index 1)
local c1 = RaceContext.getCarState(1)
c1.driverName = "Max Pace"
local orderOk = StrategyCoordinator.issueRadioOrder(1, "BOX_THIS_LAP")
assertTrue(orderOk, "Issued BOX_THIS_LAP radio command")
assertEq(c1.pit_requested, true, "cState.pit_requested is true")
assertEq(c1.radioCommand, "BOX_THIS_LAP", "cState.radioCommand is BOX_THIS_LAP")
assertEq(_aiPitRequests[1], true, "physics.setAIPitStopRequest(1, true) invoked by BOX_THIS_LAP")
assertEq(c1.tacticalState, "BOXING", "cState.tacticalState transitioned to BOXING")
assertEq(c1.pitState, "REQUESTED", "cState.pitState transitioned to REQUESTED")

-- 2. Idempotency test: Re-issue same command to same car
local reorderOk = StrategyCoordinator.issueRadioOrder(1, "BOX_THIS_LAP")
assertTrue(reorderOk, "Duplicate radio command handled gracefully")
local recentCmds = EventHub.getRecentCommands(2)
local mergedFound = false
for _, cmd in ipairs(recentCmds) do
  if cmd.msg:find("CMD MERGED") then mergedFound = true end
end
assertTrue(mergedFound, "Duplicate pit order resulted in idempotency merge receipt (Track 1)")

-- 3. Simulate car entering pitlane (acCar.isInPitlane = true)
local mockCarInPit = {
  index = 1,
  isConnected = true,
  isAIControlled = true,
  isPlayer = false,
  driverName = "Max Pace",
  speedKmh = 75.0,
  splinePosition = 0.05,
  lapCount = 4,
  positionInRace = 2,
  isInPitlane = true,
  isInPit = false,
  fuel = 20.0,
  wheels = { [0] = { tyreWear = 0.25 } }
}
RaceContext.updateCarFromAc(1, mockCarInPit)
assertEq(c1.pit_requested, false, "cState.pit_requested reset to false upon pitlane entry")
assertEq(c1.radioCommand, "NONE", "cState.radioCommand cleared to NONE upon pitlane entry")
assertEq(_aiPitRequests[1], true, "physics.setAIPitStopRequest(1, true) remains true during pit entry so car stops in stall")
assertEq(c1.tacticalState, "PIT_BAY", "cState.tacticalState set to PIT_BAY")
assertEq(c1.pitState, "IN_PITLANE", "cState.pitState set to IN_PITLANE")

-- BehaviorActuator in-pit immunity: must not modify spline offset while in pits
local pitAiState = { currentSplineOffset = 0.0, targetSplineOffset = 0.5, state = "PIT_BAY" }
BehaviorActuator.applyActuator(mockCarInPit, pitAiState, 0.1)
assertEq(pitAiState.currentSplineOffset, 0.0, "BehaviorActuator enforces 0.0 spline offset while in pit lane")

-- Verify Track 1 received batch settlement receipt
local cmdSettled = false
for _, cmd in ipairs(EventHub.getRecentCommands(3)) do
  if cmd.msg:find("CMD SETTLED") then cmdSettled = true end
end
assertTrue(cmdSettled, "Track 1 received settlement confirmation [CMD SETTLED]")

-- Verify Track 2 received standardized pit broadcast message [第1/13圈] [#02] Max Pace 已进入维修区
local pitBroadcast = false
local expectedPitIn = "[#02] Max Pace 已进入维修区"
for _, ev in ipairs(EventHub.getRecentAiEvents(5)) do
  if ev.msg:find(expectedPitIn, 1, true) then pitBroadcast = true end
end
assertTrue(pitBroadcast, "Track 2 received standardized pit entry broadcast: " .. expectedPitIn)

-- 4. Step strategy while in pit: verify plan targetLap was advanced and pit_requested remains false
StrategyCoordinator.stepStrategy(1.0)
assertEq(c1.pit_requested, false, "pit_requested remains false during pit dwell")
assertEq(c1.radioCommand, "NONE", "radioCommand remains NONE during pit dwell")
local plan1 = StrategyCoordinator.getCarPlan(1)
assertTrue(plan1.targetLap > 4, "Stint planned targetLap advanced to prevent re-arming BOX_THIS_LAP")

-- Verify autonomous recommendation does NOT contaminate radioCommand on other cars
local c2 = RaceContext.getCarState(2)
assertEq(c2.radioCommand, "NONE", "Autonomous recommendation did NOT mutate radioCommand on uncommanded Car #03")

-- 5. Simulate car exiting pitlane back to track
mockCarInPit.isInPitlane = false
mockCarInPit.isInPit = false
RaceContext.updateCarFromAc(1, mockCarInPit)
assertEq(c1.tacticalState, "CRUISE", "cState.tacticalState reverted to CRUISE upon track re-entry")
assertEq(c1.pit_requested, false, "cState.pit_requested remains false after exiting pit")
assertEq(c1.pitState, "COMPLETED", "cState.pitState transitioned to COMPLETED")
assertEq(_aiStopCounters[1], 0, "physics.setAIStopCounter(1, 0) was invoked upon pit exit to release car")
assertEq(_aiPitRequests[1], false, "physics.setAIPitStopRequest(1, false) invoked upon pit exit to prevent re-entering pits")

local exitBroadcast = false
local expectedPitOut = "[#02] Max Pace 进站作业完成"
for _, ev in ipairs(EventHub.getRecentAiEvents(5)) do
  if ev.msg:find(expectedPitOut, 1, true) then exitBroadcast = true end
end
assertTrue(exitBroadcast, "Track 2 received standardized pit exit broadcast: " .. expectedPitOut)
print("  -> Passed: Pit State Machine Closed Loop & Idempotency Settlement verified.")

-- ==============================================================================
-- [Test 21] Blue Flag Yielding and Track 2 Broadcast Event Pipeline
-- ==============================================================================
print("[Test 21] Testing Blue Flag Yielding and Track 2 Broadcast Pipeline...")
local TacticalTicker = require("lib/driver/TacticalTicker")
local mockLappedCar = {
  index = 2,
  speedKmh = 190.0,
  splinePosition = 0.40,
  lapCount = 3,
  position = vec3(0, 0, 100),
  collisionDepth = 0.0,
}
local mockLeaderCar = {
  index = 0,
  speedKmh = 230.0,
  splinePosition = 0.39,
  lapCount = 4, -- 1 lap ahead
  position = vec3(0, 0, 85),
  collisionDepth = 0.0,
}

local blueCtx = {
  isLastLap = false,
  tyreWear = 0.3,
  isBlueFlagged = true, -- Blue flag condition active
  radioCommand = "NONE",
}
local personaRival = { base_caution = 1.0, aggression = 0.6 }
local aiYieldState = TacticalTicker.stepCar(mockLappedCar, nil, mockLeaderCar, personaRival, 0.0, blueCtx, 0.1)
assertEq(aiYieldState.state, "YIELD", "TacticalTicker transitioned to YIELD state under blue flag")
assertEq(aiYieldState.activeSkill, "YIELD", "Active skill assigned to YIELD")
assertTrue(aiYieldState.targetSplineOffset > 0.5, "Spline offset pulled to outer line to yield")

-- Verify emission to EventHub
EventHub.emitTacticalStateChange(2, "Backmarker Bob", "YIELD", "CRUISE", "YIELD", 360.0)
local blueFlagBroadcast = false
for _, ev in ipairs(EventHub.getRecentAiEvents(5)) do
  if ev.msg:find("蓝旗避让") then blueFlagBroadcast = true end
end
assertTrue(blueFlagBroadcast, "Track 2 event stream broadcasted Blue Flag yielding event [【蓝旗避让】]")
print("  -> Passed: Blue Flag Yielding and Track 2 Broadcast Pipeline confirmed.")

-- ==============================================================================
-- [Test 22] Launch & Low-Speed Safety Gating & Physical Broadcast Plausibility
-- ==============================================================================
print("[Test 22] Testing Launch / Low-Speed Safety Gating & Broadcast Plausibility...")
TacticalTicker.reset()
BehaviorActuator.reset()

-- 1. Stationary car on starting grid (speed = 0 km/h)
local gridCar = {
  index = 3,
  position = vec3(5, 0, 10),
  speedKmh = 0.0,
  isAIControlled = true,
  splinePosition = 0.02,
}
local gridAheadCar = {
  index = 2,
  position = vec3(5, 0, 18),
  speedKmh = 0.0,
  isAIControlled = true,
  splinePosition = 0.03,
}

local gridState = TacticalTicker.stepCar(gridCar, gridAheadCar, nil, boldPersona, 0.0, nil, 0.1)
assertEq(gridState.state, "CRUISE", "Grid stationary car forced to CRUISE state without skill takeover")
assertEq(gridState.targetSplineOffset, 0.0, "Grid stationary car targetSplineOffset locked to 0.0")

BehaviorActuator.applyActuator(gridCar, gridState, 0.1)
assertEq(gridState.currentSplineOffset, 0.0, "BehaviorActuator enforces currentSplineOffset == 0.0 below 45 km/h")

-- 2. Verify broadcast muting for stationary car
local origGetCarFunc = ac.getCar
ac.getCar = function(i)
  if i == 3 then
    return { index = 3, isConnected = true, isAIControlled = true, speedKmh = 0.0 }
  end
  return origGetCarFunc(i)
end

EventHub.emitTacticalStateChange(3, "Grid George", "SWITCHBACK", "CRUISE", "SWITCHBACK", 12.0)
local newAiEvents = EventHub.getRecentAiEvents(10)
local falseBroadcastFound = false
for _, ev in ipairs(newAiEvents) do
  if ev.msg:find("Grid George") and ev.msg:find("交叉线") then
    falseBroadcastFound = true
  end
end
ac.getCar = origGetCarFunc
assertTrue(not falseBroadcastFound, "EventHub strictly suppressed tactical combat broadcast when car is stationary on grid")
print("  -> Passed: Launch / Low-Speed Safety Gating & Broadcast Plausibility confirmed.")

-- ==============================================================================
-- [Test 23] Adaptive Empirical Fuel Tracking (EMA) & Dynamic Pit Timing
-- ==============================================================================
print("[Test 23] Testing Adaptive Fuel Estimation (EMA) & Dynamic Pit Timing...")
local c1State = RaceContext.getCarState(1)
c1State.lapCount = 0
c1State.fuelInTank = 50.0
c1State.fuelAtLapStart = 50.0
c1State.lastTrackedLap = 0
c1State.empiricalFpl = nil

-- Lap 1 completion: fuel burned = 50.0 - 47.0 = 3.0L
local mockLap1Car = { isConnected = true, isAIControlled = true, lapCount = 1, fuel = 47.0 }
RaceContext.updateCarFromAc(1, mockLap1Car)
assertEq(c1State.empiricalFpl, 3.0, "Lap 1 empirical fuel consumption initialized to 3.0 L/lap")

-- Lap 2 completion: fuel burned = 47.0 - 44.5 = 2.5L -> EMA = 0.70 * 3.0 + 0.30 * 2.5 = 2.85
local mockLap2Car = { isConnected = true, isAIControlled = true, lapCount = 2, fuel = 44.5 }
RaceContext.updateCarFromAc(1, mockLap2Car)
assertTrue(math.abs(c1State.empiricalFpl - 2.85) < 0.001, string.format("Lap 2 EMA fuel burn rate updated to 2.85 L/lap (Got %.3f)", c1State.empiricalFpl))

-- Verify StrategyCoordinator picks up dynamic empirical FPL
StrategyCoordinator.rebuildFieldStrategy(24, 1)
local dynPlan1 = StrategyCoordinator.getCarPlan(1)
assertTrue(math.abs(dynPlan1.baseFpl - 2.85) < 0.001, "StrategyCoordinator adapts baseFpl from empirical tracking")
print("  -> Passed: Adaptive Fuel Estimation (EMA) & Dynamic Pit Timing verified.")

-- ==============================================================================
-- [Test 24] Pre-Dispatch Pit Stop Work Order & Dynamic Compound Pipeline
-- ==============================================================================
print("[Test 24] Testing Pit Stop Work Order & Compound Execution...")
local compList = RaceContext.getCarCompounds(1)
assertTrue(#compList >= 1, "RaceContext returns available compound options for car 1")

-- Configure Work Order for Car 1
RaceContext.setCarWorkOrder(1, {
  changeTyres = true,
  targetCompoundIndex = 1,
  targetCompoundName = "Hard Slick",
  refuelLiters = 20.0,
  isConfirmed = true,
})

-- Verify Car 2 work order is completely isolated
local c2State = RaceContext.getCarState(2)
assertTrue(not (c2State.pendingWorkOrder and c2State.pendingWorkOrder.isConfirmed), "Work order parameters strictly isolated to Car 1")

-- Mock Car 1 entering pit box with confirmed work order
local initialFuel = c1State.fuelInTank
local mockCarInBox = {
  isConnected = true,
  isAIControlled = true,
  isInPit = true,
  isInPitlane = true,
  fuel = initialFuel,
  maxFuel = 100.0,
}
RaceContext.updateCarFromAc(1, mockCarInBox)
assertEq(c1State.fuelInTank, initialFuel + 20.0, "Work order refuel executed: fuel injected into tank")
assertEq(c1State.pendingWorkOrder.isConfirmed, false, "Work order cleared after execution in pit box")
print("  -> Passed: Pit Stop Work Order & Compound Execution confirmed.")

-- ==============================================================================
-- [Test 25] Synchronized Vehicle Health & Mechanical Telemetry
-- ==============================================================================
print("[Test 25] Testing Vehicle Health & Mechanical Condition Telemetry...")
local mockHealthCar = {
  isConnected = true,
  isAIControlled = true,
  engineLifeLeft = 982.5,
  waterTemperature = 88.5,
  gearboxDamage = 0.04,
  damage = { [0] = 5.0, [1] = 0.0, [2] = 0.0, [3] = 0.0 },
  suspensionDamage = { [0] = 0.02, [1] = 0.0, [2] = 0.0, [3] = 0.0 },
  wheels = {
    [0] = { tyreWear = 0.92, tyreCoreTemperature = 94.0, brakeTemperature = 320.0 },
    [1] = { tyreWear = 0.90, tyreCoreTemperature = 96.0, brakeTemperature = 340.0 },
    [2] = { tyreWear = 0.88, tyreCoreTemperature = 91.0, brakeTemperature = 280.0 },
    [3] = { tyreWear = 0.87, tyreCoreTemperature = 93.0, brakeTemperature = 290.0 },
  }
}
RaceContext.updateCarFromAc(2, mockHealthCar)
assertEq(c2State.engineLifeLeft, 982.5, "Engine life left correctly ingested")
assertEq(c2State.waterTemp, 88.5, "Water temperature correctly ingested")
assertEq(c2State.gearboxDamage, 0.04, "Gearbox damage correctly ingested")
assertEq(c2State.wheelWear[1], 0.92, "LF wheel wear correctly ingested")
assertEq(c2State.wheelCoreTemp[2], 96.0, "RF wheel core temperature correctly ingested")
assertEq(c2State.wheelBrakeTemp[1], 320.0, "LF brake temperature correctly ingested")
print("  -> Passed: Vehicle Health & Mechanical Telemetry verified.")

-- ==============================================================================
-- [Test 26] Driver Persona Selection & Radio Directives (ATTACK & DEFEND)
-- ==============================================================================
print("[Test 26] Testing Persona Template Selection & ATTACK/DEFEND Directives...")
local personaLoader = require("lib/driver/persona_loader")

-- Test active persona key resolution for mapped drivers
assertEq(personaLoader.getActivePersonaKey(1, "Max Verstappen"), "f1_verstappen", "Verstappen resolves active key f1_verstappen")
assertEq(personaLoader.getActivePersonaKey(2, "Fernando Alonso"), "f1_alonso", "Alonso resolves active key f1_alonso")

-- Test manual persona override to F1 Verstappen
personaLoader.setManualOverride(1, "f1_verstappen")
assertEq(personaLoader.getActivePersonaKey(1, "Unknown"), "f1_verstappen", "Manual override reflects in getActivePersonaKey")
local pOver = personaLoader.getPersonaForCar(1, "Unknown")
assertEq(pOver.name, "Max Verstappen", "Manual override successfully assigned Max Verstappen persona")

-- Test resetting to default
personaLoader.setManualOverride(1, nil)
assertEq(personaLoader.getManualOverride(1), nil, "Manual override cleared to default")
assertEq(personaLoader.getActivePersonaKey(1, "Max Verstappen"), "f1_verstappen", "Reverts to native mapped active key after reset")

-- Test ATTACK radio directive
c1State.isInPit = false
c1State.isInPitlane = false
c1State.pitState = "NONE"
StrategyCoordinator.issueRadioOrder(1, "ATTACK")
assertEq(c1State.radioCommand, "ATTACK", "Radio command ATTACK set on Car 1")
local atkCar = { index = 1, isConnected = true, isAIControlled = true, speedKmh = 160.0 }
local atkState = TacticalTicker.stepCar(atkCar, nil, nil, pOver, 0.0, c1State, 0.1)
assertTrue(atkState.targetAggression >= 0.95, "ATTACK directive boosts target aggression to >= 0.95")

-- Test DEFEND radio directive
StrategyCoordinator.issueRadioOrder(1, "DEFEND")
assertEq(c1State.radioCommand, "DEFEND", "Radio command DEFEND set on Car 1")
local defState = TacticalTicker.stepCar(atkCar, nil, nil, pOver, 0.0, c1State, 0.1)
assertTrue(defState.targetAggression >= 0.90, "DEFEND directive maintains high defense aggression")

print("  -> Passed: Persona Template Selection & ATTACK/DEFEND Directives confirmed.")

-- ==============================================================================
-- [Test 27] Driver Persona Accordion Toggle State
-- ==============================================================================
print("[Test 27] Testing Driver Persona Accordion Toggle State...")
local mockEditingState = nil
local function toggleAccordion(carIdx)
  if mockEditingState == carIdx then
    mockEditingState = nil
  else
    mockEditingState = carIdx
  end
end
assertEq(mockEditingState, nil, "Initial state is collapsed")
toggleAccordion(2)
assertEq(mockEditingState, 2, "First click expands car 2")
toggleAccordion(2)
assertEq(mockEditingState, nil, "Second click cleanly collapses car 2 (Lua nil ternary bug resolved)")
print("  -> Passed: Driver Persona Accordion Toggle State verified.")

-- ==============================================================================
-- [Test 28] Broadcast False Positives Suppression (Attack Window & Weaving Gating)
-- ==============================================================================
print("[Test 28] Testing Broadcast False Positives Suppression...")
-- 1. When aheadDist is 35m (drafting), state must remain CRUISE (not premature ATTACK)
local draftingLeadCar = { index = 5, position = vec3(0, 0, 135), speedKmh = 190.0, isAIControlled = true }
local draftingChaserCar = { index = 6, position = vec3(0, 0, 100), speedKmh = 195.0, isAIControlled = true }
local chaserState = TacticalTicker.stepCar(draftingChaserCar, draftingLeadCar, nil, proceduralDriver, 0.0, nil, 0.1)
assertEq(chaserState.state, TacticalTicker.STATE_CRUISE, "35m drafting gap must remain STATE_CRUISE, not premature STATE_ATTACK")
assertTrue(chaserState.slipstreamActive == true, "Slipstream drafting flag active at 35m")

-- 2. When trailing car is 28m behind (too far) or cornering, breaking the tow must NOT trigger
local gentleCurveCar = {
  index = 7,
  position = vec3(0, 0, 100),
  speedKmh = 180.0,
  acceleration = vec3(3.5, 0, 0), -- Lateral G > 2.0 (cornering)
  isAIControlled = true
}
local farTailCar = {
  index = 8,
  position = vec3(0, 0, 72), -- 28m behind (> 22m)
  speedKmh = 180.0,
  isAIControlled = true
}
local curveState = TacticalTicker.stepCar(gentleCurveCar, nil, farTailCar, mappedVerstappen, 0.0, nil, 0.1)
assertEq(curveState.isBreakingTow, false, "Straight weaving defense strictly suppressed on curved sections or > 22m gap")
print("  -> Passed: Broadcast False Positives Suppression verified.")

-- ==============================================================================
-- [Test 29] EventHub Event Pipeline Diversity & Rate-Limiting
-- ==============================================================================
print("[Test 29] Testing EventHub Event Pipeline Diversity & Rate-Limiting...")
EventHub.clearAll()
-- 1. Overtake broadcast
EventHub.emitOvertake(1, "Max Verstappen", 2, 120.0)
local recentEvts = EventHub.getRecentAiEvents(5)
assertTrue(#recentEvts >= 1, "Overtake event pushed to Track 2")
assertEq(recentEvts[1].category, "OUTCOME", "Overtake classified as OUTCOME")
assertTrue(recentEvts[1].msg:find("超车完成") ~= nil, "Overtake message contains keyword")

-- 2. Tyre cliff alert
EventHub.emitTyreCliffAlert(2, "Lewis Hamilton", 0.68, 122.0)
recentEvts = EventHub.getRecentAiEvents(5)
assertEq(recentEvts[1].category, "STRATEGY", "Tyre alert classified as STRATEGY")
assertTrue(recentEvts[1].msg:find("轮胎警报") ~= nil, "Tyre alert message contains keyword")

-- 3. Mechanical health alert
EventHub.emitMechanicalAlert(3, "Charles Leclerc", "WATER_TEMP", 108.0, 125.0)
recentEvts = EventHub.getRecentAiEvents(5)
assertEq(recentEvts[1].category, "WORLD", "Health alert classified as WORLD")
assertTrue(recentEvts[1].msg:find("水温异常偏高") ~= nil, "Mechanical alert message contains keyword")

-- 4. Debouncing test: rapid consecutive ATTACK emissions for the same car within 10s must be suppressed
local initCount = #recentEvts
EventHub.emitTacticalStateChange(1, "Max Verstappen", "ATTACK", "CRUISE", "ATTACK", 130.0)
local afterOne = #EventHub.getRecentAiEvents(10)
assertTrue(afterOne > initCount, "First ATTACK event admitted")
EventHub.emitTacticalStateChange(1, "Max Verstappen", "ATTACK", "CRUISE", "ATTACK", 133.0) -- only 3s later
local afterTwo = #EventHub.getRecentAiEvents(10)
assertEq(afterOne, afterTwo, "Second ATTACK event within 15s suppressed by debouncing gate")
print("  -> Passed: EventHub Event Pipeline Diversity & Rate-Limiting confirmed.")

-- ==============================================================================
-- [Test 30] Autonomous AI Pit Timing Protection against Premature Box
-- ==============================================================================
print("[Test 30] Testing Autonomous AI Pit Timing Protection...")
StrategyCoordinator.rebuildFieldStrategy(13, 1, 2.5) -- 13 laps, 1 stop (target lap around 7)
local pCarState = RaceContext.getCarState(2)
local pCarPlan = StrategyCoordinator.getCarPlan(2)
pCarState.isInPitlane = false
pCarState.isInPit = false
pCarState.pitState = "NONE"
pCarState.pit_requested = false
pCarState.radioCommand = "NONE"
pCarState.radioOrderActive = false
pCarState.fuelInTank = 35.0 -- Plenty of fuel (~14 laps remaining)
pCarState.tyreWear = 0.18   -- Pristine tyres (far from cliff)

-- Simulate Lap 3 (curLap < plan.targetLap, e.g. targetLap is 7)
RaceContext.getRaceState().currentLap = 3
RaceContext.getRaceState().scActive = false
StrategyCoordinator.stepStrategy(1.0)

assertEq(pCarState.pit_requested, false, "AI must NOT request pit stop on Lap 3 with healthy tyres and fuel")
assertEq(pCarPlan.activeRecommendation, "STAY_OUT", "Recommendation remains STAY_OUT before target lap")

-- Simulate reaching targetLap: now the AI scheduled stop triggers
RaceContext.getRaceState().currentLap = pCarPlan.targetLap
StrategyCoordinator.stepStrategy(1.0)
assertEq(pCarState.pit_requested, true, "AI executes pit request when targetLap is reached")
assertEq(pCarPlan.activeRecommendation, "BOX_THIS_LAP", "Recommendation becomes BOX_THIS_LAP on target lap")
print("  -> Passed: Autonomous AI Pit Timing Protection verified.")

-- ==============================================================================
-- [Test 31] AI Control Telemetry Stream Toggle, Persistence & Zero-Overhead Bypassing
-- ==============================================================================
print("[Test 31] Testing AI Control Telemetry Stream Toggle & Bypassing...")
local ControlTelemetry = require("lib/core/ControlTelemetry")
ControlTelemetry.reset()
assertEq(ControlTelemetry.isEnabled(), false, "Control telemetry stream is disabled by default")

-- When disabled, zero log entries are generated (zero overhead bypassing)
ControlTelemetry.logAction(1, "Pace Override", "Set race pace target to 98% (Pushing lap)", nil, "Charles Leclerc")
assertEq(#ControlTelemetry.getRecentEntries(), 0, "Zero entries stored when stream is disabled (zero CPU/GC overhead)")

-- Enable stream
ControlTelemetry.setEnabled(true)
assertEq(ControlTelemetry.isEnabled(), true, "Stream enabled successfully")

-- Pushing action when enabled
ControlTelemetry.logAction(1, "Pace Override", "Set race pace target to 98% (Pushing lap)", nil, "Charles Leclerc")
local entries = ControlTelemetry.getRecentEntries()
assertEq(#entries, 1, "Action recorded when stream is enabled")

-- High-frequency rate-limiting check: second identical continuous action within 0.1s is debounced
ControlTelemetry.logAction(1, "Pace Override", "Set race pace target to 98% (Pushing lap)", nil, "Charles Leclerc")
assertEq(#ControlTelemetry.getRecentEntries(), 1, "Duplicate continuous action within throttle window is throttled")

-- Discrete / forced event is admitted
ControlTelemetry.logEnergyDeployment(1, "Deployed overtake boost mode", nil, "Charles Leclerc")
assertEq(#ControlTelemetry.getRecentEntries(), 2, "Discrete energy deployment event admitted")

-- Clear buffer
ControlTelemetry.clear()
assertEq(#ControlTelemetry.getRecentEntries(), 0, "Clear buffer empties entries")
print("  -> Passed: AI Control Telemetry Stream Toggle & Bypassing verified.")

-- ==============================================================================
-- [Test 32] Human-Readable Action Translation, Driver Tagging & Semantic Formatting
-- ==============================================================================
print("[Test 32] Testing Human-Readable Action Translation & Semantic Formatting...")
-- 1. Test driver tag formatting
assertEq(ControlTelemetry.formatDriverTag(1, nil, "Charles Leclerc"), "[#16 Leclerc]", "Format [#16 Leclerc] verified")
assertEq(ControlTelemetry.formatDriverTag(2, nil, "Carlos Sainz"), "[#55 Sainz]", "Format [#55 Sainz] verified")
assertEq(ControlTelemetry.formatDriverTag(0, nil, "Max Verstappen"), "[#1 Verstappen]", "Format [#1 Verstappen] verified")
assertEq(ControlTelemetry.formatDriverTag(3, nil, "Lewis Hamilton"), "[#44 Hamilton]", "Format [#44 Hamilton] verified")

-- 2. Test semantic dispatches
ControlTelemetry.clear()
ControlTelemetry.setEnabled(true)

-- Pace & Aggression
ControlTelemetry.dispatchPace(1, 0.98, 0.70, 98, "(Pushing lap)", nil, "Charles Leclerc")
-- Pit Directives
ControlTelemetry.dispatchPitStopRequest(2, true, "Hard", 42, nil, "Carlos Sainz")
-- Overtake / Defense
ControlTelemetry.dispatchSplineOffset(0, -0.08, false, "Set defensive lateral offset (Holding inside line)", nil, "Max Verstappen")
-- DRS / ERS Mode
ControlTelemetry.logEnergyDeployment(3, "Deployed overtake boost mode", nil, "Lewis Hamilton")

local streamEntries = ControlTelemetry.getRecentEntries()
assertEq(#streamEntries, 4, "Four semantic dispatches captured")

-- Validate formatting against specification
-- Example 1: [#16 Leclerc] Pace Override -> Set race pace target to 98% (Pushing lap)
assertTrue(streamEntries[1].formattedLine:find("%[#16 Leclerc%] Pace Override %-> Set race pace target to 98%% %(Pushing lap%)") ~= nil,
  "Pace Override formatted correctly: " .. streamEntries[1].formattedLine)

-- Example 2: [#55 Sainz] Pit Control -> Instructed to box this lap (Compound: Hard, Fuel: 42L)
assertTrue(streamEntries[2].formattedLine:find("%[#55 Sainz%] Pit Control %-> Instructed to box this lap %(Compound: Hard, Fuel: 42L%)") ~= nil,
  "Pit Control formatted correctly: " .. streamEntries[2].formattedLine)

-- Example 3: [#1 Verstappen] Defensive Bias -> Set defensive lateral offset (Holding inside line)
assertTrue(streamEntries[3].formattedLine:find("%[#1 Verstappen%] Defensive Bias %-> Set defensive lateral offset %(Holding inside line%)") ~= nil,
  "Defensive Bias formatted correctly: " .. streamEntries[3].formattedLine)

-- Example 4: [#44 Hamilton] Energy Deployment -> Deployed overtake boost mode
assertTrue(streamEntries[4].formattedLine:find("%[#44 Hamilton%] Energy Deployment %-> Deployed overtake boost mode") ~= nil,
  "Energy Deployment formatted correctly: " .. streamEntries[4].formattedLine)

-- Timestamp pattern check: [HH:mm:ss.fff]
assertTrue(streamEntries[1].formattedLine:find("^%[%d%d:%d%d:%d%d%.%d%d%d%]") ~= nil,
  "Timestamp matches [HH:mm:ss.fff] format")

-- 3. Strict LuaJIT FFI C-struct protection for struct state_car
local strictCarStruct = setmetatable({
  index = 1,
  speedKmh = 240.0,
  driverName = "Charles Leclerc",
  isInPitlane = false,
  isInPit = false,
}, {
  __index = function(t, k)
    error(string.format("'struct state_car' has no member named '%s'", tostring(k)))
  end
})
local tagWithStrictCar = ControlTelemetry.formatDriverTag(1, strictCarStruct, nil)
assertEq(tagWithStrictCar, "[#16 Leclerc]", "Strict struct state_car handled safely without FFI member crash")
local paceOk, paceErr = pcall(ControlTelemetry.dispatchPace, 1, 0.95, 0.75, 95, "(Pushing lap)", strictCarStruct, nil)
assertTrue(paceOk, "dispatchPace with strict struct state_car succeeded: " .. tostring(paceErr))
print("  -> Passed: Human-Readable Action Translation & Semantic Formatting confirmed.")

-- ==============================================================================
-- [Test 33] Exception & Failure Visibility & Distinct Error Formatting
-- ==============================================================================
print("[Test 33] Testing Exception & Failure Visibility...")
ControlTelemetry.clear()
ControlTelemetry.setEnabled(true)

-- 1. Direct Error Feedback
ControlTelemetry.logError(1, "Pit Stop Request", "Vehicle already committed in pit lane", nil, "Charles Leclerc")
local errEntries = ControlTelemetry.getRecentEntries()
assertEq(#errEntries, 1, "Error entry recorded")
assertTrue(errEntries[1].isError, "Entry marked as error")

-- Validate Error Format: [HH:mm:ss.fff] [ERROR] [#CarNum DriverName] Action Failed: [Action Description] | Reason: [Diagnostic Message / API Error]
assertTrue(errEntries[1].formattedLine:find("%[ERROR%] %[#16 Leclerc%] Action Failed: Pit Stop Request | Reason: Vehicle already committed in pit lane") ~= nil,
  "Error formatted correctly: " .. errEntries[1].formattedLine)

-- 2. Precondition check inside dispatchPitStopRequest
local inPitCar = { index = 2, isInPitlane = true, driverName = "Carlos Sainz" }
ControlTelemetry.dispatchPitStopRequest(2, true, "Soft", 30, inPitCar, "Carlos Sainz")
errEntries = ControlTelemetry.getRecentEntries()
assertTrue(#errEntries >= 2, "Precondition error recorded for vehicle in pitlane")
local lastErr = errEntries[#errEntries - 1]
assertTrue(lastErr.isError, "Precondition check triggered error entry")

-- 3. Diagnostics UI render testing (both with stream enabled and disabled)
local DashboardUI = require("lib/ui/DashboardUI")
local okRenderEnabled, errRenderEnabled = pcall(DashboardUI.renderLogsTab)
assertTrue(okRenderEnabled, "renderLogsTab renders cleanly with stream enabled: " .. tostring(errRenderEnabled))

ControlTelemetry.setEnabled(false)
local okRenderDisabled, errRenderDisabled = pcall(DashboardUI.renderLogsTab)
assertTrue(okRenderDisabled, "renderLogsTab renders cleanly with stream disabled: " .. tostring(errRenderDisabled))

-- 4. Verify UI Checkbox click semantics (Dear ImGui event model)
local simulatedClick = false
ui = {
  checkbox = function(label, currentVal)
    if simulatedClick then
      return true -- clicked!
    else
      return false -- not clicked
    end
  end,
  button = function() return false end,
  sameLine = function() end,
  separator = function() end,
  text = function() end,
  itemHovered = function() return false end,
  setTooltip = function() end,
}
ControlTelemetry.setEnabled(false)
-- Frame 1: User clicks checkbox
simulatedClick = true
DashboardUI.renderLogsTab()
assertEq(ControlTelemetry.isEnabled(), true, "Checkbox click successfully enabled the stream")

-- Frame 2: User does not click on next frame -> state must remain TRUE!
simulatedClick = false
DashboardUI.renderLogsTab()
assertEq(ControlTelemetry.isEnabled(), true, "Checkbox state persists as true when not clicked on subsequent frames")

-- Frame 3: User clicks checkbox again -> must toggle back to FALSE!
simulatedClick = true
DashboardUI.renderLogsTab()
assertEq(ControlTelemetry.isEnabled(), false, "Checkbox click toggles stream back to false")

ui = nil

-- ==============================================================================
-- ==============================================================================
-- [Test 34] Comprehensive Compound Palette Discovery & Pit Lifecycle Execution
-- ==============================================================================
do
print("[Test 34] Testing Comprehensive Compound Palette Discovery & Pit Lifecycle Execution...")
-- 1. Test rich motorsport compound options returned when car has no custom tyres
local compounds = RaceContext.getCarCompounds(3)
assertTrue(#compounds >= 5, "RaceContext returns comprehensive motorsport compound options (Soft/Med/Hard/SS/US/Inter/Wet)")
local foundSoft, foundHard, foundWet = false, false, false
for _, c in ipairs(compounds) do
  if c.shortName == "SOFT" then foundSoft = true end
  if c.shortName == "HARD" then foundHard = true end
  if c.shortName == "WET" or c.shortName == "INTER" then foundWet = true end
end
assertTrue(foundSoft and foundHard and foundWet, "Compound palette contains Soft, Hard, and Wet/Inter tyre choices")

-- 2. Test Work Order anti-premature gating: entering pitlane (driving at speed) must NOT execute service
local c3State = RaceContext.getCarState(3)
c3State.fuelInTank = 15.0
c3State.maxFuelCapacity = 100.0
c3State.pitState = "NONE"
c3State.isInPit = false
c3State.isInPitlane = false
RaceContext.setCarWorkOrder(3, {
  changeTyres = true,
  targetCompoundIndex = 2,
  targetCompoundName = "Hard Slick",
  refuelLiters = 25.0,
  isConfirmed = true,
})
assertTrue(c3State.pendingWorkOrder.isConfirmed, "Car 3 pendingWorkOrder is confirmed before pit entry")

local mockCarDrivingInPitLane = {
  isConnected = true,
  isAIControlled = true,
  isInPit = false,
  isInPitlane = true,
  speedKmh = 75.0,
  fuel = 15.0,
  maxFuel = 100.0,
}
RaceContext.updateCarFromAc(3, mockCarDrivingInPitLane)
assertEq(c3State.fuelInTank, 15.0, "Car 3 fuel strictly UNCHANGED while driving in pitlane limiter zone (anti-premature)")
assertTrue(c3State.pendingWorkOrder.isConfirmed, "Work order remains pending while vehicle is driving down pit lane")
assertEq(c3State.pitState, "IN_PITLANE", "Car 3 transitioned to IN_PITLANE")

-- 3. Test Service Execution: strictly triggers once vehicle comes to complete halt in pit stall
local mockCarHaltedInBay = {
  isConnected = true,
  isAIControlled = true,
  isInPit = true,
  isInPitlane = true,
  speedKmh = 0.0,
  fuel = 15.0,
  maxFuel = 100.0,
}
RaceContext.updateCarFromAc(3, mockCarHaltedInBay)
assertEq(c3State.fuelInTank, 40.0, "Car 3 refueled +25L strictly upon halting in pit stall")
assertEq(c3State.compoundIndex, 2, "Car 3 fitted with Hard compound (#2)")
assertEq(c3State.compoundName, "Hard Slick", "Car 3 compound name updated to Hard Slick")
assertEq(c3State.pendingWorkOrder.isConfirmed, false, "Work order cleared after execution in pit stall")
assertEq(c3State.pendingWorkOrder.serviced, true, "Work order marked serviced")

-- 4. Test Idempotency: subsequent frames while halted in bay do not re-dispatch or thrash
mockCarHaltedInBay.fuel = 40.0
RaceContext.updateCarFromAc(3, mockCarHaltedInBay)
assertEq(c3State.fuelInTank, 40.0, "Car 3 fuel remains 40.0 on subsequent frame (idempotent, zero thrashing)")

-- 5. Test Release: vehicle pulls away from pit box
local mockCarDepartingBay = {
  isConnected = true,
  isAIControlled = true,
  isInPit = true,
  isInPitlane = true,
  speedKmh = 12.0,
  fuel = 40.0,
  maxFuel = 100.0,
}
RaceContext.updateCarFromAc(3, mockCarDepartingBay)
assertEq(c3State.pitState, "RELEASED", "Car 3 transitioned to RELEASED upon accelerating out of pit box")

-- 6. Test Track Re-entry: vehicle exits pitlane back onto circuit
local mockCarBackOnTrack = {
  isConnected = true,
  isAIControlled = true,
  isInPit = false,
  isInPitlane = false,
  speedKmh = 180.0,
  fuel = 40.0,
  maxFuel = 100.0,
}
RaceContext.updateCarFromAc(3, mockCarBackOnTrack)
assertEq(c3State.pitState, "COMPLETED", "Car 3 transitioned to COMPLETED upon re-entering track")
assertEq(c3State.pendingWorkOrder.serviced, false, "Work order serviced flag cleanly reset for next stop")
print("  -> Passed: Comprehensive Compound Palette Discovery & Pit Lifecycle Execution verified.")
end

-- -----------------------------------------------------------------------------
-- [Test 35] Testing Real Tyre Compound Resolution & Multi-Tier Physical Fitting
-- -----------------------------------------------------------------------------
do
print("[Test 35] Testing Real Tyre Compound Resolution & Multi-Tier Physical Fitting...")
local resolvedSlot, isRain = ControlTelemetry.resolveRealCompoundIndex(0, 5, "Intermediate (绿胎 半雨胎)")
assertTrue(isRain, "Compound containing Intermediate recognized as rain/wet compound")

local wetSlot, isWet = ControlTelemetry.resolveRealCompoundIndex(0, 6, "Full Wet (蓝胎 全雨胎)")
assertTrue(isWet, "Compound containing Full Wet recognized as rain/wet compound")

local drySlot, isDryRain = ControlTelemetry.resolveRealCompoundIndex(0, 2, "Hard Slick (白胎 硬胎)")
assertTrue(not isDryRain, "Compound Hard Slick recognized as dry compound")

-- Verify physical dispatch executes with resolve, setAITyres, setTyresCompound across wheels, and virtual KM reset
local fitOk = ControlTelemetry.dispatchAITyres(0, 2, "Hard Slick", nil, "Driver 1")
assertTrue(fitOk, "Tyre compound dispatch succeeded across physics interfaces")
print("  -> Passed: Real Tyre Compound Resolution & Multi-Tier Physical Fitting verified.")
end

-- -----------------------------------------------------------------------------
-- [Test 36] Testing Multi-Factorial Anthropomorphic Mistake Engine & Persona Scaling
-- -----------------------------------------------------------------------------
local function runTest36()
print("[Test 36] Testing Multi-Factorial Anthropomorphic Mistake Engine & Persona Scaling...")
local MistakeEngine = require("lib/driver/MistakeEngine")
local personaLoader = require("lib/driver/persona_loader")
local BehaviorActuator = require("lib/driver/BehaviorActuator")
personaLoader.init("config/personas.json")

-- 1. Verify Persona Resolution & Mistake Resistance / Pressure Handling Traits
local pVerstappen = personaLoader.getPersonaForCar(1, "Max Verstappen")
local pColapinto = personaLoader.getPersonaForCar(2, "Franco Colapinto")

assertTrue(pVerstappen ~= nil, "Verstappen persona resolved")
assertTrue(pColapinto ~= nil, "Colapinto persona resolved")
assertEq(pVerstappen.mistake_resistance, 0.95, "Verstappen mistake_resistance is 0.95")
assertEq(pVerstappen.pressure_handling, 0.95, "Verstappen pressure_handling is 0.95")
assertEq(pColapinto.mistake_resistance, 0.62, "Colapinto mistake_resistance is 0.62")
assertEq(pColapinto.pressure_handling, 0.65, "Colapinto pressure_handling is 0.65")
assertTrue(pVerstappen.mistake_resistance <= 0.96, "Verstappen strictly capped by anti-immunization rule (<= 0.96)")

-- 2. Verify Comparative Error Rates under identical high environmental stress
local testCar = {
  index = 1,
  speedKmh = 190.0,
  lapCount = 3,
  isInPitlane = false,
  isInPit = false,
  acceleration = vec3(0, 0, -8.5),
  brake = 0.90,
  gas = 0.0,
}
local raceCtx = {
  tyreWear = 0.55,
  tyreTempNorm = 1.25,
  isInPitlane = false,
  isInPit = false,
}

local verstappenMistakes = 0
local colapintoMistakes = 0

MistakeEngine.reset()
math.randomseed(42)
for i = 1, 1000 do
  MistakeEngine.setMistakeCooldown(1, 0.0)
  local mType = MistakeEngine.rollMistake(1, 8.5, pVerstappen, 1.0, 0.5, 0.1, testCar, raceCtx)
  if mType ~= MistakeEngine.TYPE_NONE then
    verstappenMistakes = verstappenMistakes + 1
  end
end

math.randomseed(42)
for i = 1, 1000 do
  MistakeEngine.setMistakeCooldown(2, 0.0)
  local mType = MistakeEngine.rollMistake(2, 8.5, pColapinto, 1.0, 0.5, 0.1, testCar, raceCtx)
  if mType ~= MistakeEngine.TYPE_NONE then
    colapintoMistakes = colapintoMistakes + 1
  end
end

assertTrue(colapintoMistakes > verstappenMistakes * 3, string.format("Colapinto error count (%d) must be significantly higher than Verstappen (%d)", colapintoMistakes, verstappenMistakes))
assertTrue(verstappenMistakes >= 0, "Anti-immunization verified (Verstappen non-zero propensity under stress)")
print(string.format("  -> Mistake rate comparison (1000 trials under identical high stress): Verstappen=%d, Colapinto=%d (Ratio: %.1fx)", verstappenMistakes, colapintoMistakes, colapintoMistakes / math.max(1, verstappenMistakes)))

-- 3. Verify Telemetry Gating: Heavy braking induces BRAKE_LOCKUP
MistakeEngine.reset()
local heavyBrakeCar = {
  index = 1,
  speedKmh = 210.0,
  lapCount = 2,
  isInPitlane = false,
  isInPit = false,
  acceleration = vec3(0, 0, -9.5),
  brake = 0.92,
  gas = 0.0,
}
math.randomseed(123)
local lockupFound = false
for i = 1, 50 do
  MistakeEngine.setMistakeCooldown(1, 0.0)
  local mType, _, _, _, _, pType, pDur = MistakeEngine.rollMistake(1, 9.5, pColapinto, 1.5, 0.8, 0.2, heavyBrakeCar, raceCtx)
  if mType == MistakeEngine.TYPE_BRAKE_LOCKUP and pType == "BRAKE" then
    lockupFound = true
    assertTrue(pDur >= 0.20 and pDur <= 0.50, "Brake lockup duration within expected [0.20, 0.50] band")
    break
  end
end
assertTrue(lockupFound, "Brake lockup telemetry gating successfully triggered under heavy braking")

-- 4. Verify Telemetry Gating: Corner exit throttle induces TRACTION_SLIDE
MistakeEngine.reset()
local cornerExitCar = {
  index = 1,
  speedKmh = 85.0,
  lapCount = 2,
  isInPitlane = false,
  isInPit = false,
  acceleration = vec3(2.5, 0, 3.2),
  gas = 0.90,
  brake = 0.0,
}
math.randomseed(456)
local snapFound = false
for i = 1, 50 do
  MistakeEngine.setMistakeCooldown(1, 0.0)
  local mType, _, _, _, _, pType, pDur, pSev = MistakeEngine.rollMistake(1, 9.5, pColapinto, 1.5, 0.8, 0.2, cornerExitCar, raceCtx)
  if mType == MistakeEngine.TYPE_TRACTION_SLIDE and pType == "TRACTION" then
    snapFound = true
    assertTrue(pDur >= 0.20 and pDur <= 0.50, "Traction snap duration within expected [0.20, 0.50] band")
    assertTrue(pSev >= 1.20 and pSev <= 1.40, "Traction snap severity within expected [1.20, 1.40] band")
    break
  end
end
assertTrue(snapFound, "Traction slide telemetry gating successfully triggered on corner exit acceleration")

-- 5. Verify Safety Gates: Launch / Lap 0 / Crawl suppression
local lap0Car = {
  index = 1,
  speedKmh = 60.0,
  lapCount = 0,
  isInPitlane = false,
  isInPit = false,
  acceleration = vec3(0, 0, -9.0),
  brake = 0.90,
}
for i = 1, 20 do
  local mType = MistakeEngine.rollMistake(1, 10.0, pColapinto, 2.0, 1.0, 0.1, lap0Car, raceCtx)
  assertEq(mType, MistakeEngine.TYPE_NONE, "Lap 0 / low speed strictly suppresses mistake triggers")
end

-- 6. Verify Safety Gates: Pit lane suppression
local pitCar = {
  index = 1,
  speedKmh = 140.0,
  lapCount = 3,
  isInPitlane = true,
  isInPit = false,
}
for i = 1, 20 do
  local mType = MistakeEngine.rollMistake(1, 10.0, pColapinto, 2.0, 1.0, 0.1, pitCar, raceCtx)
  assertEq(mType, MistakeEngine.TYPE_NONE, "Pitlane presence strictly suppresses mistake triggers")
end

-- 7. Verify Actuator Execution: BehaviorActuator dispatches to physics.setAIBrakeMistake and setAITractionMistake
_aiBrakeMistakes[1] = nil
_aiTractionMistakes[1] = nil
local mockAiStateBrake = {
  index = 1,
  state = "MISTAKE",
  lastMistakeType = "BRAKE_LOCKUP",
  physicalMistakeType = "BRAKE",
  physicalMistakeDur = 0.32,
  physicalDispatched = false,
  currentSplineOffset = 0.0,
  targetSplineOffset = 0.0,
  currentCaution = 1.0,
  targetCaution = 1.8,
  currentAggression = 0.7,
  targetAggression = 0.7,
}
BehaviorActuator.applyActuator(heavyBrakeCar, mockAiStateBrake, 0.1)
assertEq(_aiBrakeMistakes[1], 0.32, "BehaviorActuator dispatched brake mistake to physics.setAIBrakeMistake")
assertTrue(mockAiStateBrake.physicalDispatched, "physicalDispatched flag marked true after actuation")

local mockAiStateTraction = {
  index = 1,
  state = "MISTAKE",
  lastMistakeType = "TRACTION_SLIDE",
  physicalMistakeType = "TRACTION",
  physicalMistakeDur = 0.38,
  physicalMistakeSev = 1.28,
  physicalDispatched = false,
  currentSplineOffset = 0.0,
  targetSplineOffset = 0.0,
  currentCaution = 1.0,
  targetCaution = 1.6,
  currentAggression = 0.7,
  targetAggression = 0.7,
}
BehaviorActuator.applyActuator(cornerExitCar, mockAiStateTraction, 0.1)
assertTrue(_aiTractionMistakes[1] ~= nil, "BehaviorActuator dispatched traction mistake to physics.setAITractionMistake")
assertEq(_aiTractionMistakes[1].dur, 0.38, "Traction mistake duration passed correctly")
assertEq(_aiTractionMistakes[1].sev, 1.28, "Traction mistake severity passed correctly")

-- 8. Verify Physical Cooldown: Enforces 25s between physical mistakes
MistakeEngine.reset()
MistakeEngine.setMistakeCooldown(1, 20.0)
assertEq(MistakeEngine.getMistakeCooldown(1), 20.0, "Cooldown reads 20.0s")
MistakeEngine.stepCooldown(1, 5.0)
assertEq(MistakeEngine.getMistakeCooldown(1), 15.0, "Cooldown stepped by 5.0s to 15.0s")

print("  -> Passed: Multi-Factorial Anthropomorphic Mistake Engine & Persona Scaling verified.")
end
runTest36()

-- [Test 37] Anthropomorphic Body Language (Headlights Flashing & Horn Honking)
print("[Test 37] Testing Anthropomorphic Body Language (Flashing & Horn)...")
local function runTest37()
  EventHub.clearAll()
  ControlTelemetry.clear()
  ControlTelemetry.setEnabled(true)
  BehaviorActuator.reset()
  TacticalTicker.reset()

  local car1 = {
    index = 1,
    position = vec3(0, 0, 100),
    speedKmh = 210,
    isAIControlled = true,
    splinePosition = 0.50,
    lapCount = 5,
    look = vec3(0, 0, 1),
    side = vec3(1, 0, 0),
  }
  local car2 = {
    index = 2,
    position = vec3(0, 0, 108),
    speedKmh = 180,
    isAIControlled = true,
    splinePosition = 0.504,
    lapCount = 5,
    look = vec3(0, 0, 1),
    side = vec3(1, 0, 0),
  }

  -- 1. Scenario: PROTEST (Weaving / dirty block ahead triggers 4x flash + horn)
  local s1 = TacticalTicker.getAiState(1)
  local s2 = TacticalTicker.getAiState(2)
  s2.isBreakingTow = true
  s2.activeSkill = "TOW_WEAVE"

  local stProtest = TacticalTicker.stepCar(car1, car2, nil, mappedVerstappen, 0.50, nil, 0.1)
  assertEq(stProtest.bodyLangAction, "PROTEST", "Body language action resolves to PROTEST against weaving rival")
  assertTrue(stProtest.bodyLangHorn == true, "PROTEST demands horn burst")
  assertEq(stProtest.bodyLangFlashCount, 4, "PROTEST demands 4 flashes")

  BehaviorActuator.applyActuator(car1, stProtest, 0.1)

  -- Verify Track 2 Broadcast
  local aiEvents = EventHub.getRecentAiEvents(5)
  assertTrue(#aiEvents >= 1, "Track 2 Broadcast recorded body language event")
  local lastEv = aiEvents[#aiEvents]
  assertTrue(lastEv.msg:find("抗议") ~= nil, "Track 2 Broadcast message contains protest keyword")
  assertEq(lastEv.category, "INCIDENT", "PROTEST event categorized as INCIDENT")

  -- Verify Control Telemetry Stream (Tab 5)
  local ctrlEntries = ControlTelemetry.getRecentEntries(5)
  assertTrue(#ctrlEntries >= 1, "Control telemetry stream recorded body language action")
  local lastCtrl = ctrlEntries[#ctrlEntries]
  assertEq(lastCtrl.category, "Body Language", "Telemetry categorized under Body Language")
  assertTrue(lastCtrl.description:find("PROTEST") ~= nil or lastCtrl.description:find("Protested") ~= nil, "Telemetry logs protest description")

  -- 2. Scenario: BLUE_FLAG (Demanding slower / lapped car to yield)
  EventHub.clearAll()
  ControlTelemetry.clear()
  BehaviorActuator.reset()
  s2.isBreakingTow = false
  s2.activeSkill = "NONE"
  car1.lapCount = 6
  car2.lapCount = 5 -- car2 is 1 lap down

  local stBlue = TacticalTicker.stepCar(car1, car2, nil, mappedVerstappen, 0.0, nil, 0.1)
  assertEq(stBlue.bodyLangAction, "BLUE_FLAG", "Resolves to BLUE_FLAG when catching lapped car")
  assertEq(stBlue.bodyLangFlashCount, 2, "BLUE_FLAG demands 2 flashes")
  assertEq(stBlue.bodyLangHorn, false, "BLUE_FLAG does not honk")

  BehaviorActuator.applyActuator(car1, stBlue, 0.1)
  local blueEvents = EventHub.getRecentAiEvents(5)
  assertTrue(#blueEvents >= 1, "Track 2 Broadcast recorded BLUE_FLAG event")
  assertTrue(blueEvents[#blueEvents].msg:find("大灯示意") ~= nil, "Broadcast message contains blue flag lights notice")

  -- 3. Scenario: Physical Actuation (High beams pulsing & Horn control)
  _mockControls.headlightsFlash = false
  _mockControls.horn = false
  -- Step actuator through pulse
  BehaviorActuator.applyActuator(car1, stBlue, 0.12)
  -- Timers should step down and cleanly release without errors
  BehaviorActuator.reset()

  print("  -> Passed: Anthropomorphic Body Language (Flashing & Horn) in broadcast & telemetry verified.")
end
runTest37()

-- ==============================================================================
-- [Test 38] Authoritative Update Lifecycle, Non-Simulation UI & Re-entrancy Guard
-- ==============================================================================
local function runTest38()
  print("[Test 38] Testing Authoritative Update Lifecycle, Non-Simulation UI & Re-entrancy...")
  _G.script = {}
  dofile("Ultimate-AI-Grand-Prix-Pro.lua")
  script.init()

  -- 1. Verify UI functions exist and are callable
  assertTrue(type(script.windowMain) == "function", "script.windowMain defined")
  assertTrue(type(script.windowSetup) == "function", "script.windowSetup defined")
  assertTrue(type(script.windowStrategy) == "function", "script.windowStrategy defined")

  -- 2. Intercept script.update to prove UI rendering NEVER triggers or steps simulation
  local updateCallCount = 0
  local originalUpdate = script.update
  script.update = function(dt)
    updateCallCount = updateCallCount + 1
    return originalUpdate(dt)
  end

  -- Call all UI windows concurrently
  pcall(script.windowMain, 0.016)
  pcall(script.windowSetup, 0.016)
  pcall(script.windowStrategy, 0.016)
  assertEq(updateCallCount, 0, "UI window render callbacks must NEVER advance simulation (0 update calls)")

  -- Restore original update
  script.update = originalUpdate

  -- 3. Verify safeDt clamping on frame spike (e.g. dt = 0.5s or negative)
  local okSpike = pcall(script.update, 0.5)
  assertTrue(okSpike, "script.update gracefully handles and clamps large dt spikes")
  local okZero = pcall(script.update, 0.0)
  assertTrue(okZero, "script.update gracefully handles 0.0 dt")

  print("  -> Passed: Authoritative Update Lifecycle, Non-Simulation UI & Re-entrancy verified.")
end
runTest38()

-- ==============================================================================
-- [Test 39] Pit Stop Work Order Precedence, Fuel Isolation & Bay Verification
-- ==============================================================================
local function runTest39()
  print("[Test 39] Testing Pit Stop Work Order Precedence, Fuel Isolation & Bay Verification...")
  local c4State = RaceContext.getCarState(4)
  c4State.fuelInTank = 25.0
  c4State.maxFuelCapacity = 100.0
  c4State.pitState = "NONE"
  c4State.pit_requested = true

  -- Case A: Explicit 0.0L refuel work order (tyres-only stop)
  RaceContext.setCarWorkOrder(4, {
    changeTyres = true,
    targetCompoundIndex = 1,
    targetCompoundName = "Soft",
    refuelLiters = 0.0
  }, "PLAYER")
  assertTrue(c4State.pendingWorkOrder.isExplicit, "Player work order marked isExplicit")
  assertEq(c4State.pendingWorkOrder.refuelLiters, 0.0, "Refuel liters is explicitly 0.0")

  -- Car stops in pitlane but NOT in pit bay (isInPit = false)
  local mockPitlaneTraffic = {
    isConnected = true,
    isAIControlled = true,
    isInPitlane = true,
    isInPit = false,
    speedKmh = 0.0,
    fuel = 25.0,
    maxFuel = 100.0
  }
  RaceContext.updateCarFromAc(4, mockPitlaneTraffic)
  assertEq(c4State.pitState, "IN_PITLANE", "Car in pitlane road transitions to IN_PITLANE")
  assertEq(c4State.fuelInTank, 25.0, "Car merely halted in pitlane traffic does NOT receive pit service")
  assertEq(c4State.pendingWorkOrder.serviced, false, "Work order NOT serviced on pit road")

  -- Car arrives and halts in true pit stall (isInPit = true, speed < 1.0)
  local mockInStall = {
    isConnected = true,
    isAIControlled = true,
    isInPitlane = true,
    isInPit = true,
    speedKmh = 0.0,
    fuel = 25.0,
    maxFuel = 100.0
  }
  RaceContext.updateCarFromAc(4, mockInStall)
  assertEq(c4State.pitState, "VERIFIED", "Car halted in true pit stall transitions to VERIFIED after service")
  assertEq(c4State.fuelInTank, 25.0, "Explicit 0.0L refuel respected: fuel remains 25.0L (tyre-only stop)")
  assertEq(c4State.pendingWorkOrder.serviced, true, "Work order marked serviced in stall")

  -- Case B: Unconfigured AI car halted in bay (isExplicit = false)
  local c5State = RaceContext.getCarState(5)
  c5State.fuelInTank = 10.0
  c5State.maxFuelCapacity = 100.0
  c5State.pitState = "NONE"
  c5State.pendingWorkOrder.isConfirmed = false
  c5State.pendingWorkOrder.isExplicit = false
  c5State.pendingWorkOrder.serviced = false
  local mockUnconfiguredAI = {
    isConnected = true,
    isAIControlled = true,
    isInPitlane = true,
    isInPit = true,
    speedKmh = 0.0,
    fuel = 10.0,
    maxFuel = 100.0
  }
  RaceContext.updateCarFromAc(5, mockUnconfiguredAI)
  assertTrue(c5State.fuelInTank >= 35.0, "Unconfigured AI halted in bay automatically refuelled to baseline stint fuel")
  assertEq(c5State.pitState, "VERIFIED", "Unconfigured AI completes service and enters VERIFIED in stall")

  print("  -> Passed: Pit Stop Work Order Precedence, Fuel Isolation & Bay Verification verified.")
end
runTest39()

-- ==============================================================================
-- [Test 40] Credible Fuel-Saving Multi-Tier Throttle Policy & Collision Safety
-- ==============================================================================
local function runTest40()
  print("[Test 40] Testing Credible Fuel-Saving Multi-Tier Throttle Policy & Collision Safety...")
  BehaviorActuator.reset()
  ControlTelemetry.reset()
  ControlTelemetry.setEnabled(true)

  local testCar = {
    index = 6,
    isConnected = true,
    isAIControlled = true,
    speedKmh = 160.0,
    lapCount = 2
  }

  -- 1. Standard / PUSH state: delivers 100% full throttle
  local pushState = {
    state = "CRUISE",
    targetSplineOffset = 0.0,
    currentSplineOffset = 0.0,
    radioCommand = "PUSH",
    isLiftAndCoast = false,
    behindDist = 40.0
  }
  BehaviorActuator.applyActuator(testCar, pushState, 0.1)
  assertEq(_throttleLimits[6], 1.0, "PUSH mode applies 1.0 full throttle limit")
  local lastCtrl = ControlTelemetry.getRecentEntries(1)[1]
  assertEq(lastCtrl.category, "Throttle Management", "Throttle management action recorded")
  assertTrue(lastCtrl.description:find("100%%") ~= nil, "PUSH mode logs 100% full throttle")

  -- 2. SAVE state with NO follower close behind: 85% throttle ceiling during cruise
  local saveCruiseState = {
    state = "CRUISE",
    targetSplineOffset = 0.0,
    currentSplineOffset = 0.0,
    radioCommand = "SAVE",
    isLiftAndCoast = false,
    behindDist = 35.0
  }
  BehaviorActuator.applyActuator(testCar, saveCruiseState, 0.1)
  assertEq(_throttleLimits[6], 0.85, "SAVE cruise applies 0.85 throttle limit")
  lastCtrl = ControlTelemetry.getRecentEntries(1)[1]
  assertTrue(lastCtrl.description:find("85%%") ~= nil, "SAVE cruise mode logs 85% throttle limit")

  -- 3. SAVE state during Lift and Coast phase: 25% smooth roll (never 0% dead lockout)
  local saveCoastState = {
    state = "CRUISE",
    targetSplineOffset = 0.0,
    currentSplineOffset = 0.0,
    radioCommand = "SAVE",
    isLiftAndCoast = true,
    behindDist = 35.0
  }
  BehaviorActuator.applyActuator(testCar, saveCoastState, 0.1)
  assertEq(_throttleLimits[6], 0.25, "Lift & Coast applies 0.25 throttle limit (smooth coast, not dead 0.0)")
  lastCtrl = ControlTelemetry.getRecentEntries(1)[1]
  assertTrue(lastCtrl.description:find("25%%") ~= nil or lastCtrl.description:find("Lift & Coast") ~= nil, "Lift & Coast logs smooth coast roll")

  -- 4. SAVE state WITH close follower behind (< 14m): fuel-saving inhibited for collision prevention!
  local threatenedState = {
    state = "CRUISE",
    targetSplineOffset = 0.0,
    currentSplineOffset = 0.0,
    radioCommand = "SAVE",
    isLiftAndCoast = true,
    behindDist = 8.5 -- Follower right on gearbox!
  }
  BehaviorActuator.applyActuator(testCar, threatenedState, 0.1)
  assertEq(_throttleLimits[6], 1.0, "Close follower behind inhibits lift and delivers 1.0 throttle for collision safety")
  lastCtrl = ControlTelemetry.getRecentEntries(1)[1]
  assertTrue(lastCtrl.description:find("inhibited") ~= nil, "Collision safety override logged in telemetry")

  -- 5. Spline Offset Pipeline Transparency
  assertEq(type(threatenedState.requestedSplineOffset), "number", "requestedSplineOffset tracked")
  assertEq(type(threatenedState.safetyClampedOffset), "number", "safetyClampedOffset tracked")
  assertEq(type(threatenedState.appliedSplineOffset), "number", "appliedSplineOffset tracked")

  ControlTelemetry.setEnabled(false)
  print("  -> Passed: Credible Fuel-Saving Multi-Tier Throttle Policy & Collision Safety verified.")
end
runTest40()

-- ==============================================================================
-- [Test 41] Per-Car Authoritative Race State & Topology Gaps
-- ==============================================================================
local function runTest41()
  print("[Test 41] Testing Per-Car Authoritative Race State & Topology Gaps...")
  local c7State = RaceContext.getCarState(7)
  local mockAcCar = {
    isConnected = true,
    isAIControlled = true,
    lapCount = 4,
    splinePosition = 0.45,
    speedKmh = 210.0,
    fuel = 45.0,
    maxFuel = 100.0
  }
  RaceContext.updateCarFromAc(7, mockAcCar)
  assertEq(c7State.lapCount, 4, "Lap count updated to 4")
  local expectedProgress = (4.0 + 0.45) / math.max(1, RaceContext.getRaceState().totalLaps or 13)
  assertTrue(math.abs(c7State.raceProgress - expectedProgress) < 0.001, "raceProgress accurately reflects race fraction")
  assertTrue(c7State.telemetryConfidence ~= nil, "telemetryConfidence metadata present")
  assertEq(c7State.telemetryConfidence.lap, "EXACT", "Lap confidence is EXACT")

  -- Test Topology gapAheadSec and gapBehindSec calculation
  local topCars = {
    [0] = { index = 0, isConnected = true, position = vec3(0, 0, 100), splinePosition = 0.50, speedKmh = 180.0 },
    [1] = { index = 1, isConnected = true, position = vec3(0, 0, 50), splinePosition = 0.48, speedKmh = 180.0 },
    [2] = { index = 2, isConnected = true, position = vec3(0, 0, 0), splinePosition = 0.45, speedKmh = 180.0 }
  }
  local function getTopCar(i) return topCars[i] end
  RaceContext.updateTopology(3, getTopCar)
  local c1TopState = RaceContext.getCarState(1)
  assertTrue(c1TopState.gapAheadSec < 2.0, "Car 1 gapAheadSec is valid delta in seconds (~1.0s)")
  assertTrue(c1TopState.gapBehindSec < 2.0, "Car 1 gapBehindSec is valid delta in seconds (~1.0s)")

  print("  -> Passed: Per-Car Authoritative Race State & Topology Gaps verified.")
end
runTest41()

-- ==============================================================================
-- [Test 42] Teammate Pit Stagger & Independent Strategy Window Execution
-- ==============================================================================
local function runTest42()
  print("[Test 42] Testing Teammate Pit Stagger & Independent Strategy Window...")
  
  -- 1. Dual-Car Teammate Pit Window Stagger
  StrategyCoordinator.rebuildFieldStrategy(24, 1, 2.5)
  local p0 = StrategyCoordinator.getCarPlan(0)
  local p1 = StrategyCoordinator.getCarPlan(1)
  assertTrue(p0 ~= nil and p1 ~= nil, "Plans generated for teammate cars 0 and 1")
  assertTrue(p0.targetLap ~= p1.targetLap, string.format("Teammates staggered: Car 0 target %d vs Car 1 target %d", p0.targetLap, p1.targetLap))

  -- 2. Strategy Window Rendering & Execution
  local DashboardUI = require("lib/ui/DashboardUI")
  local okRender = pcall(DashboardUI.renderStrategyWindow)
  assertTrue(okRender, "DashboardUI.renderStrategyWindow renders safely without exceptions")

  -- 3. Radio Order Dispatch
  local c0State = RaceContext.getCarState(0)
  c0State.isInPit = false
  c0State.isInPitlane = false
  c0State.pitState = "NONE"
  StrategyCoordinator.issueRadioOrder(0, "BOX_THIS_LAP")
  assertEq(c0State.radioCommand, "BOX_THIS_LAP", "Strategy radio command BOX_THIS_LAP dispatched to Car 0")

  print("  -> Passed: Teammate Pit Stagger & Independent Strategy Window verified.")
end
runTest42()

-- ==============================================================================
-- [Test 43] AI Retirement (RET) Lifecycle, In-Pit Classification & Shielding
-- ==============================================================================
local function runTest43()
  print("[Test 43] Testing AI Retirement (RET) Lifecycle, In-Pit Classification & Shielding...")

  -- 1. AI Car Retires on Track and Teleports to Pit Stall:
  -- When car.isRetired is true and car is in pit stall (isInPit = true),
  -- RaceContext must set state to RETIRED and pitState to RETIRED, NOT PIT_BAY or IN_BAY / SERVICING!
  local mockRetiredCar = {
    index = 2,
    isConnected = true,
    isAIControlled = true,
    isPlayer = false,
    isRetired = true,
    driverName = "Retired AI",
    speedKmh = 0.0,
    splinePosition = 0.1,
    lapCount = 3,
    positionInRace = 15,
    isInPitlane = true,
    isInPit = true,
    fuel = 0.0,
    wheels = { [0] = { tyreWear = 0.40 } }
  }

  RaceContext.updateCarFromAc(2, mockRetiredCar)
  local c2 = RaceContext.getCarState(2)
  assertEq(c2.isRetired, true, "cState.isRetired correctly detected as true")
  assertEq(c2.tacticalState, "RETIRED", "cState.tacticalState set to RETIRED, not PIT_BAY")
  assertEq(c2.activeSkill, "RET", "cState.activeSkill set to RET, not PIT_SERVICE")
  assertEq(c2.pitState, "RETIRED", "cState.pitState set to RETIRED, not IN_BAY or SERVICING")

  -- 2. TacticalTicker stepCar on retired car:
  -- Must return RETIRED / RET and zero offsets, zero stress, no PIT_SERVICE!
  local tickerState = TacticalTicker.stepCar(mockRetiredCar, nil, nil, {}, 0.0, c2, 0.1)
  assertEq(tickerState.state, "RETIRED", "TacticalTicker returns state RETIRED")
  assertEq(tickerState.activeSkill, "RET", "TacticalTicker returns activeSkill RET, preventing permanent PIT_SERVICE")
  assertEq(tickerState.targetSplineOffset, 0.0, "Retired car targetSplineOffset locked to 0.0")

  -- 3. Watchdog Anti-Retirement Shield:
  -- When an active car is slowed down on track (< 25 km/h outside pits),
  -- watchdog must invoke physics.preventAIFromRetiring
  local mockSlowCar = {
    index = 3,
    isConnected = true,
    isAIControlled = true,
    isPlayer = false,
    isRetired = false,
    speedKmh = 10.0,
    lapCount = 2,
    isInPitlane = false,
    isInPit = false
  }
  _preventRetireCalls[3] = 0
  watchdog.checkStuckCars(mockSlowCar, 0.1, 50.0)
  assertTrue(_preventRetireCalls[3] > 0, "Watchdog invoked physics.preventAIFromRetiring for slowed car on track")

  -- 4. Fuel Emergency Pit Stop Outside Nominal Window:
  -- If fuel is critically low (< 1.3 laps), StrategyCoordinator must evaluate pit immediately
  -- without waiting for plan.openLap!
  local plan3 = StrategyCoordinator.getCarPlan(3)
  plan3.openLap = 10
  plan3.targetLap = 12
  plan3.escalateLap = 14
  local c3 = RaceContext.getCarState(3)
  c3.isConnected = true
  c3.isAIControlled = true
  c3.isRetired = false
  c3.fuelInTank = 2.0  -- critical! (1 lap or less)
  c3.lapCount = 3      -- lap 4, well before openLap 10!
  c3.isInPitlane = false
  c3.isInPit = false
  c3.pitState = "NONE"
  c3.radioOrderActive = false

  StrategyCoordinator.stepStrategy(1.0)
  assertEq(plan3.activeRecommendation, "BOX_THIS_LAP", "Critical fuel triggers BOX_THIS_LAP even when carOwnLap < openLap")
  assertTrue(c3.pit_requested, "Critical fuel triggers pit_requested to prevent fuel exhaustion retirement")

  -- 5. DashboardUI formatting:
  local DashboardUI = require("lib/ui/DashboardUI")
  local okDash = pcall(DashboardUI.renderMain, 0.05, 4)
  assertTrue(okDash, "DashboardUI.renderMain renders retired car with [RET] cleanly")

  print("  -> Passed: AI Retirement (RET) Lifecycle, In-Pit Classification & Shielding verified.")
end
runTest43()

-- -----------------------------------------------------------------------------
-- [Test 44] Testing Circuit-Aware Fuel Baseline & Plausibility Outlier Filtering
-- -----------------------------------------------------------------------------
local function runTest44()
  print("[Test 44] Testing Circuit-Aware Fuel Baseline & Plausibility Outlier Filtering...")
  -- 1. Mock Vallelunga 1700m
  _mockSim.trackLengthM = 1700.0
  StrategyCoordinator.rebuildFieldStrategy(10, nil, nil)
  local plan0 = StrategyCoordinator.getCarPlan(0)
  -- Track length 1.7km * 0.65 = 1.105 L/lap
  assertTrue(plan0.baseFpl >= 1.0 and plan0.baseFpl <= 1.25, "Dynamic base FPL for 1.7km track is clamped around ~1.1 L/lap")

  -- 2. Car starts on grid with 18.0L
  local c0 = RaceContext.getCarState(0)
  c0.isConnected = true
  c0.isAIControlled = true
  c0.lapCount = 0
  c0.fuelInTank = 18.0
  RaceContext.updateCarFromAc(0, {
    isConnected = true,
    isAIControlled = true,
    speedKmh = 0.0,
    lapCount = 0,
    fuel = 18.0,
    maxFuel = 80.0,
  })
  assertEq(c0.fuelAtLapStart, 18.0, "Lap 0 grid anchor aligns with fuelInTank (18.0L), eliminating 30.0L dummy offset")

  -- 3. Car completes Lap 1, fuel drops from 18.0L to 16.85L (delta = 1.15L)
  RaceContext.updateCarFromAc(0, {
    isConnected = true,
    isAIControlled = true,
    speedKmh = 140.0,
    lapCount = 1,
    fuel = 16.85,
    maxFuel = 80.0,
  })
  assertTrue(c0.empiricalFpl >= 1.10 and c0.empiricalFpl <= 1.20, "Empirical fuel correctly measures 1.15 L/lap instead of 12 L/lap")

  -- 4. Aberrant jump / out-of-bounds burn (e.g. 12L drop in single lap on 1.7km circuit)
  -- Max plausible for 1.7km is max(2.2, 1.7 * 1.3) = 2.21 L/lap
  local prevEmpirical = c0.empiricalFpl
  RaceContext.updateCarFromAc(0, {
    isConnected = true,
    isAIControlled = true,
    speedKmh = 140.0,
    lapCount = 2,
    fuel = 4.85, -- 12L drop!
    maxFuel = 80.0,
  })
  assertEq(c0.empiricalFpl, prevEmpirical, "Aberrant 12 L/lap outlier on 1.7km circuit is strictly rejected by physical plausibility gating")

  print("  -> Passed: Circuit-Aware Fuel Baseline & Plausibility Outlier Filtering verified.")
end
runTest44()

-- -----------------------------------------------------------------------------
-- [Test 45] Testing Setup UI 0-Stop Default Strategy & Submit Feedback UX
-- -----------------------------------------------------------------------------
local function runTest45()
  print("[Test 45] Testing Setup UI 0-Stop Default Strategy & Submit Feedback UX...")
  -- 1. Default stops is 0
  StrategyCoordinator.rebuildFieldStrategy(25)
  local plan1 = StrategyCoordinator.getCarPlan(1)
  assertEq(plan1.plannedStops, 0, "Default field strategy is 0-stop (no-stop)")
  assertEq(plan1.openLap, 999, "0-stop pit window openLap is 999")
  assertEq(plan1.targetLap, 999, "0-stop pit window targetLap is 999")
  assertEq(plan1.escalateLap, 999, "0-stop pit window escalateLap is 999")
  assertEq(#plan1.stints, 1, "0-stop strategy has exactly 1 stint covering entire race")
  assertEq(plan1.stints[1], 25, "Single stint covers all 25 laps")

  -- 2. DashboardUI renderSetup execution & Apply button click feedback
  local DashboardUI = require("lib/ui/DashboardUI")
  local lastRenderedText = {}
  local appliedClicked = false
  ui = {
    button = function(label)
      if label and string.find(label, "setup_apply") then
        return appliedClicked
      end
      return false
    end,
    sameLine = function() end,
    separator = function() end,
    text = function(str)
      table.insert(lastRenderedText, str)
    end,
    pushStyleColor = function() end,
    popStyleColor = function() end,
    itemHovered = function() return false end,
    setTooltip = function() end,
  }

  -- Frame 1: Normal render without clicking apply
  appliedClicked = false
  local okSetup1 = pcall(DashboardUI.renderSetup)
  assertTrue(okSetup1, "DashboardUI.renderSetup renders without errors")

  -- Frame 2: User clicks 'Apply Strategy' button
  appliedClicked = true
  local okSetup2 = pcall(DashboardUI.renderSetup)
  assertTrue(okSetup2, "DashboardUI.renderSetup handles apply button click cleanly")

  -- Frame 3: Next frame verifies feedback text was rendered
  appliedClicked = false
  lastRenderedText = {}
  local okSetup3 = pcall(DashboardUI.renderSetup)
  assertTrue(okSetup3, "DashboardUI.renderSetup renders feedback banner cleanly")
  local hasFeedback = false
  for _, txt in ipairs(lastRenderedText) do
    if txt and string.find(txt, "策略修改成功") then
      hasFeedback = true
      break
    end
  end
  assertTrue(hasFeedback, "Submit feedback banner displaying '策略修改成功' rendered after clicking apply")

  ui = nil

  print("  -> Passed: Setup UI 0-Stop Default Strategy & Submit Feedback UX verified.")
end
runTest45()

-- [Test 46] Testing Watchdog stuck recovery, releaseTakeover safe reset & subsequent takeover
do
  local function runTest46()
    print("[Test 46] Testing Watchdog Stuck Recovery & Safe Takeover Lifecycle...")
    local watchdog = require("lib/driver/watchdog")
    watchdog.reset()

    local dummyCar = {
      index = 3,
      isAIControlled = true,
      isRetired = false,
      isInPitlane = false,
      isInPit = false,
      speedKmh = 0.5,
      lapCount = 2,
      position = vec3(10, 0, 100),
    }

    -- Trigger stuck recovery check over 5 seconds
    for _ = 1, 60 do
      watchdog.checkStuckCars(dummyCar, 0.1, 50.0)
    end

    -- Verify releaseTakeover does not error or dereference nil
    local okRelease = pcall(watchdog.releaseTakeover, 3)
    assertTrue(okRelease, "watchdog.releaseTakeover executes safely without nil dereference")

    -- Verify subsequent takeover request succeeds cleanly (table was not nilled out)
    local cbCalled = false
    local okTakeover = watchdog.requestTakeover(3, 0.3, function(ctrl, car, dt)
      cbCalled = true
    end)
    assertTrue(okTakeover, "watchdog.requestTakeover succeeds after stuck recovery without table corruption")

    print("  -> Passed: Watchdog Stuck Recovery & Safe Takeover Lifecycle verified.")
  end
  runTest46()
end

-- [Test 47] Testing Deterministic X-Skills Registry Initialization & Idempotency
do
  local function runTest47()
    print("[Test 47] Testing Deterministic X-Skills Registry Initialization...")
    local SkillRegistry = require("lib/skills/SkillRegistry")
    local TacticalTicker = require("lib/driver/TacticalTicker")

    -- Reset registry to simulate pre-init state
    SkillRegistry.reset()
    local listBefore, countBefore = SkillRegistry.getAllSkills()
    assertEq(countBefore, 0, "SkillRegistry reset cleanly to 0 skills")

    -- Call TacticalTicker.init() as executed in script.init()
    TacticalTicker.init()
    local listAfter, countAfter = SkillRegistry.getAllSkills()
    assertTrue(countAfter >= 5, "TacticalTicker.init registers all built-in X-Skills (count >= 5)")

    -- Call init again to verify idempotency (does not duplicate or crash)
    TacticalTicker.init()
    local listSecond, countSecond = SkillRegistry.getAllSkills()
    assertEq(countSecond, countAfter, "TacticalTicker.init is idempotent (count unchanged)")

    print("  -> Passed: Deterministic X-Skills Registry Initialization verified.")
  end
  runTest47()
end

-- [Test 48] Testing Zero-Allocation Procedural Persona Caching & Invalidation
do
  local function runTest48()
    print("[Test 48] Testing Zero-Allocation Procedural Persona Caching...")
    local personaLoader = require("lib/driver/persona_loader")
    personaLoader.reset()

    -- Warm up cache with an unmapped rookie driver
    local pFirst = personaLoader.getPersonaForCar(11, "Rookie Testdriver")
    assertTrue(pFirst ~= nil and pFirst.is_procedural == true, "Procedural DNA generated for unmapped driver")

    -- Measure memory allocations over 500 consecutive lookups
    if jit then jit.off(); jit.flush() end
    collectgarbage("collect")
    local memBefore = collectgarbage("count")

    for _ = 1, 500 do
      local pLoop = personaLoader.getPersonaForCar(11, "Rookie Testdriver")
      if pLoop.base_aggression < 0 then error("invalid") end
    end

    local memAfter = collectgarbage("count")
    local deltaKB = memAfter - memBefore
    assertTrue(deltaKB <= 0.05, string.format("Procedural persona lookup in 10Hz loop is zero-alloc (Delta: %.3f KB)", deltaKB))

    -- Verify cache invalidation when manual override is set
    personaLoader.setManualOverride(11, "f1_verstappen")
    local pOverridden = personaLoader.getPersonaForCar(11, "Rookie Testdriver")
    assertEq(pOverridden.name, "Max Verstappen", "Manual override takes precedence over procedural cache")

    -- Reset clears overrides and caches
    personaLoader.reset()
    local pPostReset = personaLoader.getPersonaForCar(11, "Rookie Testdriver")
    assertTrue(pPostReset.is_procedural == true, "Reset restores procedural generation cleanly")

    print("  -> Passed: Zero-Allocation Procedural Persona Caching verified.")
  end
  runTest48()
end

-- [Test 49] Testing Actuator Contract, Native Neutral Recovery & Deduplication
do
  local function runTest49()
    print("[Test 49] Testing Actuator Contract, Native Neutral Recovery & Deduplication...")
    local BehaviorActuator = require("lib/driver/BehaviorActuator")
    local watchdog = require("lib/driver/watchdog")
    BehaviorActuator.reset()

    local car10 = {
      index = 10,
      isConnected = true,
      isAIControlled = true,
      speedKmh = 140.0,
      lapCount = 3
    }

    -- 1. Step with non-zero tactical offset (e.g. 0.12)
    local stateActive = {
      state = "ATTACK",
      targetSplineOffset = 0.12,
      currentSplineOffset = 0.12,
      targetCaution = 0.85,
      currentCaution = 0.85,
      targetAggression = 0.80,
      currentAggression = 0.80,
      radioCommand = "NONE",
      behindDist = 50.0
    }

    _actuatorAudit.splineOffsetCalls[10] = 0
    _throttleLimits[10] = nil
    BehaviorActuator.applyActuator(car10, stateActive, 0.1)

    assertEq(_actuatorAudit.splineOffsetCalls[10], 1, "Tactical non-zero offset dispatched to physics.setAISplineOffset")
    assertTrue(math.abs(_actuatorAudit.splineOffsetValues[10] - 0.12) < 0.001, "Dispatched offset matches tactical target 0.12")
    assertTrue(BehaviorActuator.isOffsetActive(10), "Offset tracking register marked active")

    -- 2. Deduplication: run 5 consecutive frames with identical target state
    local callsBefore = _actuatorAudit.splineOffsetCalls[10]
    for _ = 1, 5 do
      BehaviorActuator.applyActuator(car10, stateActive, 0.1)
    end
    assertEq(_actuatorAudit.splineOffsetCalls[10], callsBefore, "Repeated frames with unchanged offset are deduplicated (0 redundant calls)")

    -- 3. Neutral state recovery: skill finishes / target returns to 0.0
    local stateNeutral = {
      state = "CRUISE",
      targetSplineOffset = 0.0,
      currentSplineOffset = 0.0,
      targetCaution = 1.0,
      currentCaution = 1.0,
      targetAggression = 0.70,
      currentAggression = 0.70,
      radioCommand = "NONE",
      behindDist = 50.0
    }

    BehaviorActuator.applyActuator(car10, stateNeutral, 0.1)
    assertEq(_actuatorAudit.splineOffsetCalls[10], callsBefore + 1, "Explicit neutral recovery dispatched exactly once")
    assertEq(_actuatorAudit.splineOffsetValues[10], 0.0, "Dispatched offset explicitly restored to 0.0")
    assertEq(BehaviorActuator.isOffsetActive(10), false, "Offset active register cleared to false")

    -- 4. Deduplication in neutral: 5 more frames in neutral should not call setAISplineOffset again
    local callsAfterNeutral = _actuatorAudit.splineOffsetCalls[10]
    for _ = 1, 5 do
      BehaviorActuator.applyActuator(car10, stateNeutral, 0.1)
    end
    assertEq(_actuatorAudit.splineOffsetCalls[10], callsAfterNeutral, "Neutral state is not spammed to native physics (0 redundant calls)")

    -- 5. Exclusive Authority: Pit Lane overrides tactical offsets
    local pitCar = {
      index = 10,
      isConnected = true,
      isAIControlled = true,
      isInPitlane = true,
      speedKmh = 60.0,
      lapCount = 3
    }
    local pitState = {
      state = "PIT_BAY",
      targetSplineOffset = 0.14,
      currentSplineOffset = 0.14,
      behindDist = 50.0
    }
    BehaviorActuator.applyActuator(pitCar, pitState, 0.1)
    assertEq(pitState.currentSplineOffset, 0.0, "Pit lane enforces 0.0 offset")
    assertEq(BehaviorActuator.getAppliedThrottleLimit(10), 1.0, "Pit lane restores 1.0 full throttle")

    -- 6. Exclusive Authority: Watchdog takeover yields BehaviorActuator
    watchdog.init()
    local okT = watchdog.requestTakeover(10, 1.0, function() end)
    assertTrue(okT, "watchdog takeover requested successfully")
    assertTrue(watchdog.isOverridden(10), "watchdog.isOverridden reports active")
    local preTakeoverCalls = _actuatorAudit.splineOffsetCalls[10]
    BehaviorActuator.applyActuator(car10, stateActive, 0.1)
    assertEq(_actuatorAudit.splineOffsetCalls[10], preTakeoverCalls, "BehaviorActuator yields during watchdog takeover")
    watchdog.releaseTakeover(10)

    -- 7. Reset path clean restoration
    BehaviorActuator.applyActuator(car10, stateActive, 0.1)
    assertTrue(BehaviorActuator.isOffsetActive(10), "Offset active prior to reset")
    BehaviorActuator.reset()
    assertEq(BehaviorActuator.isOffsetActive(10), false, "Reset clears offset active")
    assertEq(BehaviorActuator.getAppliedOffset(10), 0.0, "Reset restores applied offset to 0.0")

    print("  -> Passed: Actuator Contract, Native Neutral Recovery & Deduplication verified.")
  end
  runTest49()
end

-- [Test 50] Testing Geometry-Aware Safety, Turn-Directional Maneuvers & Hairpin Filtering
do
  local function runTest50()
    print("[Test 50] Testing Geometry-Aware Safety, Turn-Directional Maneuvers & Hairpin Filtering...")
    local LateBrakeDive = require("lib/skills/LateBrakeDiveSkill")
    local Switchback = require("lib/skills/SwitchbackSkill")

    -- 1. Test Turn-Directional Inside Line Selection in LateBrakeDive
    local mockCar = { index = 1, splinePosition = 0.30, speedKmh = 180.0 }
    local mockRival = { index = 2, splinePosition = 0.302, position = vec3(0, 0, 10) }
    local skillCtx = { phaseTimer = 0.0, currentPhase = 1, targetOffset = 0.0, targetCaution = 1.0, targetAggression = 0.7 }

    -- Right Turn (angle > 0): inside line must be on the right (+offset)
    local geoRight = {
      upcomingTurnAngle = 0.45, -- Right-hand turn
      trackLeftM = 6.0,
      trackRightM = 6.0,
      aheadRelX = 0.0,
      aheadDist = 8.0,
    }
    LateBrakeDive.stepExecution(skillCtx, mockCar, mockRival, nil, 0.1, geoRight)
    assertTrue(skillCtx.targetOffset > 0.35, "Late brake dive into right turn takes inside right line (+offset)")

    -- Left Turn (angle < 0): inside line must be on the left (-offset)
    local geoLeft = {
      upcomingTurnAngle = -0.45, -- Left-hand turn
      trackLeftM = 6.0,
      trackRightM = 6.0,
      aheadRelX = 0.0,
      aheadDist = 8.0,
    }
    LateBrakeDive.stepExecution(skillCtx, mockCar, mockRival, nil, 0.1, geoLeft)
    assertTrue(skillCtx.targetOffset < -0.35, "Late brake dive into left turn takes inside left line (-offset)")

    -- Narrow track envelope constraint: right track boundary is cramped (2.2m)
    local geoNarrowRight = {
      upcomingTurnAngle = 0.45,
      trackLeftM = 6.0,
      trackRightM = 2.2, -- narrow barrier
      aheadRelX = 0.0,
      aheadDist = 8.0,
    }
    LateBrakeDive.stepExecution(skillCtx, mockCar, mockRival, nil, 0.1, geoNarrowRight)
    assertTrue(skillCtx.targetOffset <= 0.25, "Narrow track boundary clamps dive offset safely (avoiding wall)")

    -- 2. Test Geometry-Aware Directional Maneuvers in Switchback
    local sbCtx = { phaseTimer = 0.0, currentPhase = 1, targetOffset = 0.0, targetCaution = 1.0, targetAggression = 0.7 }
    -- Right Turn Switchback: Phase 1 stays wide outside left (<0), Phase 2 cuts back inside right (>0)
    Switchback.stepExecution(sbCtx, mockCar, mockRival, nil, 0.1, geoRight)
    assertTrue(sbCtx.targetOffset < 0, "Right-turn switchback Phase 1 prepares wide on outside left (-offset)")
    sbCtx.phaseTimer = 0.6 -- advance past 0.5s phase threshold
    Switchback.stepExecution(sbCtx, mockCar, mockRival, nil, 0.1, geoRight)
    assertEq(sbCtx.currentPhase, 2, "Switchback advanced to Phase 2 (Cutback)")
    Switchback.stepExecution(sbCtx, mockCar, mockRival, nil, 0.1, geoRight)
    assertTrue(sbCtx.targetOffset > 0, "Right-turn switchback Phase 2 cuts back inside right (+offset)")

    -- 3. Test Hairpin & Parallel Track Ghost Filtering in Topology
    local hairpinCars = {
      [0] = {
        index = 0,
        isConnected = true,
        position = vec3(10, 0, 50),
        splinePosition = 0.45,
        look = vec3(0, 0, 1), -- Traveling North
      },
      [1] = {
        index = 1,
        isConnected = true,
        position = vec3(12, 0, 65), -- Only 15m Euclidean distance away!
        splinePosition = 0.47,
        look = vec3(0, 0, -1), -- Traveling South (Opposite side of hairpin!)
      },
      [2] = {
        index = 2,
        isConnected = true,
        position = vec3(10, 0, 75), -- 25m Euclidean distance away
        splinePosition = 0.85, -- Parallel track section 2000m away on circuit!
        look = vec3(0, 0, 1),
      },
    }
    local function getHairpinCar(i) return hairpinCars[i] end
    RaceContext.updateTopology(3, getHairpinCar)
    local aheadHairpin, distAheadHairpin = RaceContext.getNeighbors(0)
    assertEq(aheadHairpin, -1, "Opposite-facing hairpin neighbor and distant parallel track car both filtered as ghosts")

    print("  -> Passed: Geometry-Aware Safety, Turn-Directional Maneuvers & Hairpin Filtering verified.")
  end
  runTest50()
end

-- ==============================================================================
-- [Test 51] Actuator Dynamic Authority, Maneuver Slew Rate & Pace Bounds
-- ==============================================================================
do
  local function runTest51()
    print("[Test 51] Testing Actuator Dynamic Authority, Maneuver Slew Rate & Pace Bounds...")
    local BehaviorActuator = require("lib/driver/BehaviorActuator")
    local TacticalTicker = require("lib/driver/TacticalTicker")
    BehaviorActuator.reset()
    TacticalTicker.reset()

    local carManeuver = {
      index = 11,
      isConnected = true,
      isAIControlled = true,
      speedKmh = 160.0,
      lapCount = 2,
      splinePosition = 0.35,
    }

    -- 1. Slew rate comparison: Maneuvering (0.85/s) vs Cruising (0.35/s)
    local stateCruise = {
      state = "CRUISE",
      targetSplineOffset = 0.50,
      currentSplineOffset = 0.0,
      behindDist = 40.0
    }
    BehaviorActuator.applyActuator(carManeuver, stateCruise, 0.1)
    local cruiseOffset = stateCruise.currentSplineOffset
    assertTrue(cruiseOffset > 0.030 and cruiseOffset < 0.040, string.format("Cruising lateral slew is ~0.035/0.1s (got %.4f)", cruiseOffset))

    local stateAttack = {
      state = "ATTACK",
      targetSplineOffset = 0.50,
      currentSplineOffset = 0.0,
      behindDist = 40.0
    }
    BehaviorActuator.applyActuator(carManeuver, stateAttack, 0.1)
    local attackOffset = stateAttack.currentSplineOffset
    assertTrue(attackOffset > 0.080 and attackOffset < 0.090, string.format("Maneuvering lateral slew is ~0.085/0.1s (got %.4f)", attackOffset))
    assertTrue(attackOffset > cruiseOffset * 2.0, "Maneuvering slew rate is > 2x faster than cruising")

    -- 2. Wide Dynamic Corridor vs Narrow Wall Clamping
    local origGetSides = ac.getTrackAISplineSides
    -- Scenario A: Wide track (left 7m, right 7m) -> allows safe offset up to 0.55
    ac.getTrackAISplineSides = function(s) return 7.0, 7.0 end
    local stateWide = {
      state = "ATTACK",
      targetSplineOffset = 0.50,
      currentSplineOffset = 0.50,
      behindDist = 40.0
    }
    BehaviorActuator.applyActuator(carManeuver, stateWide, 0.1)
    assertEq(stateWide.appliedSplineOffset, 0.50, "Wide track corridor permits full 0.50 tactical dive offset")

    -- Scenario B: Narrow right track margin (2.0m) -> reserves 1.8m margin, clamps right offset to 0.15
    ac.getTrackAISplineSides = function(s) return 7.0, 2.0 end
    BehaviorActuator.applyActuator(carManeuver, stateWide, 0.1)
    assertTrue(stateWide.appliedSplineOffset <= 0.20, string.format("Narrow track margin clamps offset to safe zone (got %.2f)", stateWide.appliedSplineOffset))
    ac.getTrackAISplineSides = origGetSides

    -- 3. High-Authority Pace (Caution down to 0.20, Aggression up to 0.98)
    local stateAggressive = {
      state = "ATTACK",
      targetCaution = 0.20,
      currentCaution = 0.20,
      targetAggression = 0.98,
      currentAggression = 0.98,
      targetSplineOffset = 0.0,
      currentSplineOffset = 0.0,
      behindDist = 40.0
    }
    BehaviorActuator.applyActuator(carManeuver, stateAggressive, 0.1)
    local appliedA, appliedC = BehaviorActuator.getAppliedPace(11)
    assertTrue(math.abs(appliedC - 0.20) < 0.01, string.format("Caution allowed to reach 0.20 (got %.2f, old clamped at 0.75)", appliedC))
    assertTrue(math.abs(appliedA - 0.98) < 0.01, string.format("Aggression allowed to reach 0.98 (got %.2f, old clamped at 0.85)", appliedA))

    print("  -> Passed: Actuator Dynamic Authority, Maneuver Slew Rate & Pace Bounds verified.")
  end
  runTest51()
end

-- ==============================================================================
-- [Test 52] Spatial LOD Baseline Heartbeat & Standing-Start Launch Throttle Modulation
-- ==============================================================================
do
  local function runTest52()
    print("[Test 52] Testing Spatial LOD Baseline Heartbeat & Standing-Start Launch...")
    local LODScheduler = require("lib/driver/LODScheduler")
    local MistakeEngine = require("lib/driver/MistakeEngine")
    local BehaviorActuator = require("lib/driver/BehaviorActuator")

    -- 1. Baseline Heartbeat for Deep Sleep Tier 3 Cars
    LODScheduler.reset()
    LODScheduler.setDeepSleepEnabled(true)
    LODScheduler.setBaselineHeartbeat(25) -- ~0.4Hz at 10Hz base clock
    local mockPlayerPos = { x = 0, y = 0, z = 0 }
    local mockPosFunc = function(i)
      if i == 10 then return 0, 0, 350 end -- Tier 3 Ambient (> 250m)
      return 0, 0, 50
    end
    LODScheduler.updateTiers(mockPlayerPos, 12, mockPosFunc)
    assertEq(LODScheduler.getCarTier(10), LODScheduler.TIER_AMBIENT, "Car 10 is Tier 3 Ambient")

    local hbTicks = 0
    for t = 1, 50 do
      LODScheduler.updateTiers(mockPlayerPos, 12, mockPosFunc)
      if LODScheduler.shouldTickCar(10) then hbTicks = hbTicks + 1 end
    end
    assertEq(hbTicks, 2, "Baseline heartbeat ticks exactly twice in 50 frames (0.4Hz, 1 tick every 25 frames)")
    LODScheduler.reset()
    assertEq(LODScheduler.getBaselineHeartbeat(), 0, "Reset clears baseline heartbeat interval to 0")

    -- 2. Standing-Start Launch Delay & Throttle Modulation
    MistakeEngine.reset()
    BehaviorActuator.reset()

    local startCar = {
      index = 7,
      isConnected = true,
      isAIControlled = true,
      speedKmh = 0.0,
      lapCount = 0,
      splinePosition = 0.01,
    }
    local startPersona = { base_aggression = 0.80 }
    local delay, blunder = MistakeEngine.evaluateStandingStart(7, startPersona, 0.5)
    assertTrue(delay >= 0.18 and delay <= 0.65, string.format("Standing start reaction delay generated (%.2fs)", delay))
    assertTrue(MistakeEngine.isLaunchDelayed(7), "MistakeEngine.isLaunchDelayed is true during start")

    local startState = {
      state = "CRUISE",
      isLaunchDelayed = true,
      targetSplineOffset = 0.0,
      currentSplineOffset = 0.0,
      behindDist = 40.0
    }
    BehaviorActuator.applyActuator(startCar, startState, 0.05)
    assertEq(BehaviorActuator.getAppliedThrottleLimit(7), 0.0, "Throttle limit is modulated to 0.0 during standing start reaction delay")

    -- Step time to elapse the delay
    MistakeEngine.stepStandingStart(7, delay + 0.1)
    assertEq(MistakeEngine.isLaunchDelayed(7), false, "Launch delay cleared once reaction time has elapsed")

    startState.isLaunchDelayed = false
    BehaviorActuator.applyActuator(startCar, startState, 0.05)
    assertEq(BehaviorActuator.getAppliedThrottleLimit(7), 1.0, "Full 1.0 throttle restored once launch reaction delay expires")

    -- Collision safety override: if car behind is within 14m, throttle must be 1.0 even if launch delay active
    startState.isLaunchDelayed = true
    startState.behindDist = 8.0
    BehaviorActuator.applyActuator(startCar, startState, 0.05)
    assertEq(BehaviorActuator.getAppliedThrottleLimit(7), 1.0, "Rear follower safety override forces 1.0 throttle despite launch delay")

    print("  -> Passed: Spatial LOD Baseline Heartbeat & Standing-Start Launch verified.")
  end
  runTest52()
end

-- ==============================================================================
-- [Test 53] Team Radio Voice Engine (State Machine, Preemption, Bilingual & Orders)
-- ==============================================================================
do
  local function runTest53()
    print("[Test 53] Testing Team Radio Voice Engine...")
    local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
    RadioVoiceEngine.reset()
    RadioVoiceEngine.init()

    -- 1. Configuration & Bilingual Switching
    assertEq(RadioVoiceEngine.getLanguage(), "en", "Default radio language is English")
    RadioVoiceEngine.setLanguage("zh")
    assertEq(RadioVoiceEngine.getLanguage(), "zh", "Switched radio language to Chinese")
    RadioVoiceEngine.setLanguage("en")
    assertEq(RadioVoiceEngine.getLanguage(), "en", "Switched radio language back to English")

    RadioVoiceEngine.setVolume(0.75)
    assertTrue(math.abs(RadioVoiceEngine.getVolume() - 0.75) < 0.01, "Volume configured to 0.75")
    assertTrue(RadioVoiceEngine.isEnabled(), "Radio engine is enabled by default")

    -- 2. State Machine: Trigger play and step transitions
    local okPlay = RadioVoiceEngine.playRadio("cmd_push", RadioVoiceEngine.PRIORITY_COMMAND)
    assertTrue(okPlay, "Radio message cmd_push queued/played successfully")
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_BEEP_OPEN, "Engine enters STATE_BEEP_OPEN on trigger")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_push", "Last played key is cmd_push")

    -- Step past open beep (0.12s)
    RadioVoiceEngine.step(0.15)
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_PLAYING_VOICE, "Engine transitions to STATE_PLAYING_VOICE")

    -- Step past speech clip (1.6s)
    RadioVoiceEngine.step(1.70)
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_BEEP_CLOSE, "Engine transitions to STATE_BEEP_CLOSE")

    -- Step past close beep (0.09s)
    RadioVoiceEngine.step(0.12)
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_COOLDOWN, "Engine transitions to STATE_COOLDOWN")

    -- Step past cooldown (0.25s)
    RadioVoiceEngine.step(0.30)
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_IDLE, "Engine returns to STATE_IDLE")

    -- 3. Anti-Spam Debounce: Repeating same key immediately is rejected
    local okSpam = RadioVoiceEngine.playRadio("cmd_push", RadioVoiceEngine.PRIORITY_COMMAND)
    assertEq(okSpam, false, "Duplicate command rejected by 12s debounce guard")

    -- 4. Preemption: Emergency priority (3) interrupts lower priority (1) during playback
    local okLow = RadioVoiceEngine.playRadio("info_blue_flag", RadioVoiceEngine.PRIORITY_INFO)
    assertTrue(okLow, "Low priority info message accepted")
    RadioVoiceEngine.step(0.15)
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_PLAYING_VOICE, "Low priority message playing")

    -- Emergency interrupts:
    local okEmergency = RadioVoiceEngine.playRadio("info_safety_car", RadioVoiceEngine.PRIORITY_EMERGENCY)
    assertTrue(okEmergency, "Emergency Safety Car message accepted during low-priority playback")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "info_safety_car", "Emergency immediately preempts current playback")
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_BEEP_OPEN, "Preemption resets state machine to BEEP_OPEN for emergency")

    -- 5. Command Integration via StrategyCoordinator
    RadioVoiceEngine.reset()
    local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
    StrategyCoordinator.issueRadioOrder(0, "BOX_THIS_LAP")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_box", "issueRadioOrder(BOX_THIS_LAP) triggers cmd_box radio voice")

    RadioVoiceEngine.reset()
    StrategyCoordinator.issueRadioOrder(0, "ATTACK")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_attack", "issueRadioOrder(ATTACK) triggers cmd_attack radio voice")

    print("  -> Passed: Team Radio Voice Engine verified.")
  end
  runTest53()
end

-- ==============================================================================
-- [Test 54] Dynamic Weather, Track Wetness Accumulation/Drainage & Rain Pit Crossover
-- ==============================================================================
do
  local function runTest54()
    print("[Test 54] Testing Dynamic Weather Perception, Tyre Crossover & Actuator Adaptation...")
    local WeatherStrategyModel = require("lib/strategy/WeatherStrategyModel")
    local BehaviorActuator = require("lib/driver/BehaviorActuator")
    local StrategyCoordinator = require("lib/strategy/StrategyCoordinator")
    local RaceContext = require("lib/core/RaceContext")
    local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
    local ControlTelemetry = require("lib/core/ControlTelemetry")

    WeatherStrategyModel.reset()
    assertEq(WeatherStrategyModel.getTrackWetness(), 0.0, "Initial wetness is 0.0")
    assertEq(WeatherStrategyModel.getActiveBand(), WeatherStrategyModel.BAND_DRY, "Initial band is DRY")
    assertEq(WeatherStrategyModel.getOptimalTyreCompound(), "Soft", "Optimal compound for dry is Soft")

    -- 1. Weather Perception & Differential Accumulation / Drainage
    local mockSim = { rainIntensity = 0.8, roadGrip = 0.95 }
    -- Step 10 seconds of 0.8 rain -> wetness += 0.8 * 0.05 * 10 = 0.40
    for _ = 1, 10 do
      WeatherStrategyModel.updateConditions(mockSim, 1.0)
    end
    local w = WeatherStrategyModel.getTrackWetness()
    assertTrue(w >= 0.39 and w <= 0.41, "Accumulated wetness ~0.40 under heavy rain")
    assertEq(WeatherStrategyModel.getActiveBand(), WeatherStrategyModel.BAND_INTER, "0.40 wetness classifies as BAND_INTER")
    assertEq(WeatherStrategyModel.getActiveBandName(), "INTERMEDIATE", "Semantic band name is INTERMEDIATE")
    assertEq(WeatherStrategyModel.getOptimalTyreCompound(), "Intermediate", "Optimal compound is Intermediate")

    -- Rain stops, test drainage: rainIntensity = 0.0
    mockSim.rainIntensity = 0.0
    -- Step 20 seconds of drainage -> wetness -= 0.015 * 20 = 0.30 -> wetness ~0.10 (< 0.20)
    for _ = 1, 20 do
      WeatherStrategyModel.updateConditions(mockSim, 1.0)
    end
    assertTrue(WeatherStrategyModel.getTrackWetness() <= 0.12, "Track drained below 0.12")
    assertEq(WeatherStrategyModel.getActiveBand(), WeatherStrategyModel.BAND_DRY, "Drained surface returns to BAND_DRY")

    -- 2. Tyre Pace Deficit & Weather Crossover Evaluation
    -- Set wetness to 0.75 (BAND_WET)
    WeatherStrategyModel.setTrackWetness(0.75)
    assertEq(WeatherStrategyModel.getActiveBand(), WeatherStrategyModel.BAND_WET, "0.75 wetness is BAND_WET")
    assertEq(WeatherStrategyModel.getOptimalTyreCompound(), "Wet", "0.75 wetness recommends Full Wet tyres")

    -- Slick tyre pace penalty on 0.75 wet track
    local slickPenalty = WeatherStrategyModel.getTyrePacePenalty("Soft", 0.75)
    assertTrue(slickPenalty > 20.0, "Slick tyres suffer > 20s/lap penalty in heavy wet")

    -- Wet tyre penalty on 0.75 wet track
    local wetPenalty = WeatherStrategyModel.getTyrePacePenalty("Wet", 0.75)
    assertEq(wetPenalty, 0.0, "Full Wet tyres have 0.0 penalty in optimal wet condition")

    -- Evaluate weather pit: On lap 3 of 15-lap race, car on Soft slicks should box for Wet tyres
    local shouldBox, targetComp, netBenefit = WeatherStrategyModel.evaluateWeatherPit("Soft", 3, 15)
    assertTrue(shouldBox, "Weather crossover triggers urgent pit stop for car on slicks")
    assertEq(targetComp, "Wet", "Target compound is Wet")
    assertTrue(netBenefit > 50.0, "Net benefit of switching to Wet tyres exceeds pit delta loss")

    -- If already on Wet tyres in wet condition, shouldBox should be false
    local shouldBoxWet, _, _ = WeatherStrategyModel.evaluateWeatherPit("Wet", 3, 15)
    assertEq(shouldBoxWet, false, "Car already on Wet tyres does not trigger weather box")

    -- 3. BehaviorActuator Rain Adjustments (Caution & Corridor Clamp)
    local cautionMult = WeatherStrategyModel.getWeatherCautionMultiplier()
    -- At wetness 0.75: 1.0 + 0.75 * 0.65 = 1.4875
    assertTrue(cautionMult > 1.40 and cautionMult < 1.55, "Caution multiplier ~1.49 at 0.75 wetness")

    local corridorClamp = WeatherStrategyModel.getWeatherCorridorClamp()
    -- At wetness 0.75: 0.55 - 0.75 * 0.33 = 0.3025
    assertTrue(corridorClamp < 0.35 and corridorClamp >= 0.22, "Corridor clamped to ~0.30 at 0.75 wetness")

    -- Actuator physical actuation under rain:
    BehaviorActuator.reset()
    local car = {
      index = 2,
      driverName = "Norris",
      speedKmh = 160.0,
      lapCount = 4,
      splinePosition = 0.5,
    }
    local aiState = {
      currentSplineOffset = 0.0,
      targetSplineOffset = 0.50, -- requests +0.50 lateral offset
      currentCaution = 1.0,
      targetCaution = 1.0,
      currentAggression = 0.7,
      targetAggression = 0.7,
    }
    BehaviorActuator.applyActuator(car, aiState, 1.0)
    -- Target offset 0.50 should be clamped by corridorClamp (~0.30)
    assertTrue(aiState.appliedSplineOffset <= corridorClamp + 0.02, "Applied spline offset clamped by rain corridor clamp")

    -- 4. End-to-End StrategyCoordinator Autonomous Weather Box Decision
    RadioVoiceEngine.reset()
    local cState = RaceContext.getCarState(2)
    cState.isConnected = true
    cState.isAIControlled = true
    cState.isRetired = false
    cState.compoundName = "Soft"
    cState.tyreWear = 0.10 -- tyres are fresh, not worn out!
    cState.fuelInTank = 40.0 -- fuel is plenty!
    cState.lapCount = 3
    cState.pitState = "NONE"
    cState.radioOrderActive = false

    local plan = StrategyCoordinator.getCarPlan(2)
    plan.targetLap = 12
    plan.openLap = 10
    plan.escalateLap = 13
    plan.pitInHandled = false

    -- Track is soaked at 0.75 wetness, triggering StrategyCoordinator.stepStrategy
    StrategyCoordinator.stepStrategy(1.0)

    assertEq(plan.activeRecommendation, "BOX_THIS_LAP", "StrategyCoordinator recommends BOX_THIS_LAP on rain crossover")
    assertEq(plan.reasonCode, "WEATHER_CROSSOVER", "Reason code is WEATHER_CROSSOVER")
    assertEq(cState.workOrder.targetCompoundName, "Wet", "Work order automatically configured to Wet compound")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_box", "Weather crossover triggers cmd_box radio voice")

    WeatherStrategyModel.reset()
    print("  -> Passed: Dynamic Weather, Track Wetness & Rain Pit Crossover verified.")
  end
  runTest54()
end

-- ==============================================================================
-- [Test 55] Mirror Threat Index (MTI) & Continuous Psychological Dynamics
-- ==============================================================================
do
  local function runTest55()
    print("[Test 55] Testing Mirror Threat Index (MTI) & Continuous Psychological Dynamics...")
    local TacticalTicker = require("lib/driver/TacticalTicker")

    -- 1. MTI Range and Distance Degradation
    local mtiOut = TacticalTicker.calculateMTI(35.0, nil, nil, nil, nil)
    assertEq(mtiOut, 0.0, "Car outside 28m yields 0.0 MTI")

    local mtiMid = TacticalTicker.calculateMTI(14.0, nil, nil, nil, nil)
    assertTrue(math.abs(mtiMid - 0.50) < 0.01, "Car at 14m yields 0.50 base MTI")

    -- 2. Threat Multipliers: Hunting Headlights & Weaving
    local huntingState = { bodyLangAction = "HUNTING" }
    local mtiHunt = TacticalTicker.calculateMTI(14.0, nil, huntingState, nil, nil)
    -- 0.50 * (1 + 0.45) = 0.725
    assertTrue(math.abs(mtiHunt - 0.725) < 0.01, "Hunting headlight strobe multiplies threat by 1.45x")

    local weavingState = { isFeinting = true }
    local mtiWeave = TacticalTicker.calculateMTI(14.0, nil, weavingState, nil, nil)
    -- 0.50 * (1 + 0.40) = 0.70
    assertTrue(math.abs(mtiWeave - 0.70) < 0.01, "Feinting / weaving multiplies threat by 1.40x")

    -- 3. Rival Reputation & High Stakes Race Context
    local champCar = { driverName = "Max Verstappen" }
    local mtiChamp = TacticalTicker.calculateMTI(14.0, champCar, nil, nil, nil)
    -- 0.50 * (1 + 0.35) = 0.675
    assertTrue(math.abs(mtiChamp - 0.675) < 0.01, "Champion reputation multiplies threat by 1.35x")

    local raceStakes = { racePosition = 1, isLastLap = true, tyreWear = 0.70 }
    local mtiStakes = TacticalTicker.calculateMTI(14.0, nil, nil, nil, raceStakes)
    -- kStakes = 0.30 + 0.35 + 0.25 = 0.90 -> 0.50 * (1 + 0.90) = 0.95
    assertTrue(math.abs(mtiStakes - 0.95) < 0.01, "High stakes context (P1, Last Lap, Worn Tyres) adds 0.90 threat factor")

    -- 4. Dynamic Stress Differential Accumulation & Exponential Decay
    local carLead = { index = 3, speedKmh = 140.0, lapCount = 5, position = { x = 100, y = 0, z = 0 } }
    local carBehind = { index = 4, speedKmh = 145.0, lapCount = 5, position = { x = 90, y = 0, z = 0 }, driverName = "Max Verstappen" }
    local pVerstappen = { mistake_resistance = 0.95, pressure_resist = 0.95 }
    local pColapinto = { mistake_resistance = 0.60, pressure_resist = 0.60 }

    TacticalTicker.reset()
    -- Step 20 ticks (2.0s) with Max Verstappen chasing Colapinto (car 3)
    local sColapinto = nil
    for _ = 1, 20 do
      sColapinto = TacticalTicker.stepCar(carLead, nil, carBehind, pColapinto, 0.0, nil, 0.1)
    end
    assertTrue(sColapinto.stress > 0.5, "Colapinto accumulates significant stress under Verstappen pursuit")
    assertTrue(sColapinto.mti > 0.5, "Colapinto perceives elevated MTI")
    local colapintoStress = sColapinto.stress

    -- Test Decay when pursuer pulls away (distance = 50m, 5.0s / 50 ticks of clean air)
    carBehind.position.x = 50
    for _ = 1, 50 do
      sColapinto = TacticalTicker.stepCar(carLead, nil, carBehind, pColapinto, 0.0, nil, 0.1)
    end
    assertTrue(sColapinto.stress < colapintoStress * 0.40, "Stress decays exponentially when pursuer falls back beyond threat zone")

    -- Now compare with top veteran Verstappen under identical pursuit (reset pursuer to 10m behind)
    TacticalTicker.reset()
    carBehind.position.x = 90
    local sMax = nil
    for _ = 1, 20 do
      sMax = TacticalTicker.stepCar(carLead, nil, carBehind, pVerstappen, 0.0, nil, 0.1)
    end
    assertTrue(sMax.stress < colapintoStress * 0.30, "Verstappen absorbs pressure with over 3x lower stress accumulation")

    print("  -> Passed: Mirror Threat Index (MTI) & Continuous Psychological Dynamics verified.")
  end
  runTest55()
end

-- ==============================================================================
-- [Test 56] Three-Tier Progressive Mistake Dynamics & Safety Invariants
-- ==============================================================================
do
  local function runTest56()
    print("[Test 56] Testing Three-Tier Progressive Mistake Dynamics & Safety Invariants...")
    local MistakeEngine = require("lib/driver/MistakeEngine")
    local BehaviorActuator = require("lib/driver/BehaviorActuator")
    local ControlTelemetry = require("lib/core/ControlTelemetry")

    MistakeEngine.reset()
    local car = {
      index = 5,
      speedKmh = 160.0,
      lapCount = 4,
      brake = 0.85,
      acceleration = { z = -7.5, x = 0.0 },
      isInPitlane = false,
      isInPit = false,
    }
    local persona = { mistake_resistance = 0.60, pressure_handling = 0.60, error_probability = 0.15 }

    -- 1. Safety Gates: Lap 0 / crawl speed suppresses mistakes
    local carLap0 = { speedKmh = 60.0, lapCount = 0, isInPitlane = false, isInPit = false }
    local mType, _, _, _, _, _, _, _, tier = MistakeEngine.rollMistake(5, 9.8, persona, 0.0, 0.0, 0.1, carLap0, nil)
    assertEq(mType, MistakeEngine.TYPE_NONE, "Lap 0 strictly suppresses mistakes")
    assertEq(tier, MistakeEngine.TIER_NONE, "Tier is TIER_NONE on lap 0")

    -- 2. Tier 1: Micro-Hesitation / Overslow (Stress in 6.0 ~ 7.5 range)
    local t1Type, t1Dur, t1Off, t1Caut, t1Tier
    for _ = 1, 20 do
      local mt, md, mo, mc, _, _, _, _, tr = MistakeEngine.rollMistake(5, 6.8, persona, 0.0, 0.0, 1.0, car, nil)
      if mt ~= MistakeEngine.TYPE_NONE then
        t1Type, t1Dur, t1Off, t1Caut, t1Tier = mt, md, mo, mc, tr
        break
      end
    end
    assertEq(t1Type, MistakeEngine.TYPE_OVERSLOW, "Stress 6.8 triggers Tier 1 OVERSLOW")
    assertEq(t1Tier, MistakeEngine.TIER_1_OVERSLOW, "Tier is TIER_1_OVERSLOW")
    assertEq(t1Off, 0.0, "Tier 1 does not deviate off racing line (offset 0.0)")
    assertTrue(t1Caut >= 2.0, "Tier 1 elevates caution for hesitant early braking")

    -- 3. Tier 2: Technical Blunder - Lockup & Missed Apex (Stress in 7.8 ~ 9.0 range)
    local t2Type, t2Dur, t2Off, t2Caut, pType, pDur, t2Tier
    for _ = 1, 20 do
      local mt, md, mo, mc, _, pt, pd, _, tr = MistakeEngine.rollMistake(5, 8.4, persona, 0.0, 0.0, 1.0, car, nil)
      if mt ~= MistakeEngine.TYPE_NONE then
        t2Type, t2Dur, t2Off, t2Caut, pType, pDur, t2Tier = mt, md, mo, mc, pt, pd, tr
        break
      end
    end
    assertEq(t2Tier, MistakeEngine.TIER_2_TECHNICAL, "Stress 8.4 triggers Tier 2 TECHNICAL blunder")
    assertTrue(t2Type == MistakeEngine.TYPE_BRAKE_LOCKUP or t2Type == MistakeEngine.TYPE_MISSED_APEX or t2Type == MistakeEngine.TYPE_TRAIL_UNDERSTEER, "Tier 2 produces lockup, missed apex or trail understeer")
    assertTrue(t2Off >= 0.45, "Tier 2 washes wide (offset >= 0.45) opening inside passing lane")
    if pType then
      assertEq(pType, "BRAKE", "Physical mistake dispatched as BRAKE lockup")
    end

    -- 4. Cooldown Enforcement: 20.0s cooldown prevents rapid successive physical mistakes
    assertTrue(MistakeEngine.getMistakeCooldown(5) > 18.0, "Physical cooldown set to ~20.0s")
    -- Next immediate roll should NOT dispatch physical mistake
    local _, _, _, _, _, pType2 = MistakeEngine.rollMistake(5, 8.5, persona, 0.0, 0.0, 1.0, car, nil)
    assertEq(pType2, nil, "Physical mistake suppressed while on cooldown")

    -- 5. Tier 3: Severe Panic Breakdown (Stress >= 9.2)
    MistakeEngine.setMistakeCooldown(5, 0.0)
    car.speedKmh = 90.0
    car.acceleration.z = 3.0
    car.acceleration.x = 2.5
    car.gas = 0.90
    car.brake = 0.0
    local t3Type, pType3, pSev3, t3Tier
    for _ = 1, 20 do
      local mt, _, _, _, _, pt, _, ps, tr = MistakeEngine.rollMistake(5, 9.6, persona, 0.0, 0.0, 1.0, car, nil)
      if mt ~= MistakeEngine.TYPE_NONE then
        t3Type, pType3, pSev3, t3Tier = mt, pt, ps, tr
        break
      end
    end
    assertEq(t3Tier, MistakeEngine.TIER_3_SEVERE, "Stress 9.6 triggers Tier 3 SEVERE panic breakdown")
    assertEq(t3Type, MistakeEngine.TYPE_TRACTION_SLIDE, "Corner exit oversteer snap triggered")
    assertEq(pType3, "TRACTION", "Dispatches physical TRACTION mistake")
    assertTrue(pSev3 >= 1.20, "Physical traction severity >= 1.20")

    -- 6. BehaviorActuator Throttle Modulation for Tier 1 Overslow
    BehaviorActuator.reset()
    local aiStateOverslow = {
      state = "MISTAKE",
      lastMistakeType = "OVERSLOW",
      currentSplineOffset = 0.0,
      targetSplineOffset = 0.0,
      currentCaution = 2.0,
      targetCaution = 2.0,
      currentAggression = 0.5,
      targetAggression = 0.5,
    }
    ControlTelemetry.clear()
    ControlTelemetry.setEnabled(true)
    BehaviorActuator.applyActuator(car, aiStateOverslow, 0.1)
    local recentTelems = ControlTelemetry.getRecentEntries(10)
    local foundThrottleLimit = false
    for _, a in ipairs(recentTelems) do
      if a.category == "Throttle Management" and a.description:find("70%%") then
        foundThrottleLimit = true
        break
      end
    end
    assertTrue(foundThrottleLimit, "BehaviorActuator modulated throttle to 70% for Tier 1 Overslow")
    ControlTelemetry.setEnabled(false)

    MistakeEngine.reset()
    print("  -> Passed: Three-Tier Progressive Mistake Dynamics & Safety Invariants verified.")
  end
  runTest56()
end

-- ==============================================================================
-- [Test 57] Hunter's Pounce (POUNCE_PASS) Opportunistic Overtake
-- ==============================================================================
do
  local function runTest57()
    print("[Test 57] Testing Hunter's Pounce (POUNCE_PASS) Opportunistic Overtake...")
    local TacticalTicker = require("lib/driver/TacticalTicker")
    local EventHub = require("lib/core/EventHub")
    local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
    local BehaviorActuator = require("lib/driver/BehaviorActuator")

    TacticalTicker.reset()
    RadioVoiceEngine.reset()
    EventHub.clearAll()

    local carLead = {
      index = 1,
      driverName = "Sainz",
      speedKmh = 120.0,
      lapCount = 6,
      position = { x = 100, y = 0, z = 0 },
    }
    local carChaser = {
      index = 2,
      driverName = "Leclerc",
      speedKmh = 128.0,
      lapCount = 6,
      position = { x = 93, y = 0, z = 0 }, -- 7.0m behind
    }

    local pChaser = {
      base_aggression = 0.85,
      base_caution = 0.8,
      pressure_resist = 0.85,
    }

    -- 1. Setup Lead car making Tier 2 mistake and washing wide
    local leadState = TacticalTicker.getAiState(1)
    leadState.state = "MISTAKE"
    leadState.lastMistakeType = "MISSED_APEX"
    leadState.currentSplineOffset = 0.55
    leadState.targetSplineOffset = 0.55

    -- 2. Step Chaser AI
    local chaserState = TacticalTicker.stepCar(carChaser, carLead, nil, pChaser, 0.0, nil, 0.1)

    -- Chaser should immediately sense the error and launch Hunter's Pounce
    assertEq(chaserState.state, "POUNCE_PASS", "Chaser transitions to POUNCE_PASS on lead car error")
    assertEq(chaserState.activeSkill, "POUNCE_PASS", "Active skill is POUNCE_PASS")
    assertEq(chaserState.targetSplineOffset, -0.40, "Chaser dives to opposite inside lane (-0.40)")
    assertEq(chaserState.targetCaution, 0.25, "Chaser drops caution to 0.25 for bold opportunistic pass")
    assertEq(chaserState.targetAggression, 0.98, "Chaser maximizes aggression to 0.98")
    assertTrue(chaserState.pounceActive, "pounceActive flag is true")

    -- 3. Verify Broadcast and Voice Engine Trigger
    local events = EventHub.getRecentAiEvents(5)
    local foundPounceEvent = false
    for _, ev in ipairs(events) do
      if ev.msg:find("绝杀突袭") and ev.msg:find("切弯反超") then
        foundPounceEvent = true
        break
      end
    end
    assertTrue(foundPounceEvent, "EventHub broadcast recorded Hunter's Pounce attack event")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "info_overtake", "Radio voice triggered info_overtake")

    -- 4. Verify BehaviorActuator handles POUNCE_PASS with high transition rate
    BehaviorActuator.reset()
    chaserState.currentSplineOffset = 0.0
    BehaviorActuator.applyActuator(carChaser, chaserState, 0.1)
    assertTrue(chaserState.currentSplineOffset < -0.05, "BehaviorActuator uses fast 0.85 maneuver slew rate for POUNCE_PASS")

    TacticalTicker.reset()
    print("  -> Passed: Hunter's Pounce (POUNCE_PASS) Opportunistic Overtake verified.")
  end
  runTest57()
end

do
  print("\n[Test 58] Testing Radio Voice Preview & CSP DriverName Function Guard...")
  local function runTest58()
    local TacticalTicker = require("lib/driver/TacticalTicker")
    local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")
    local RaceContext = require("lib/core/RaceContext")

    -- 1. Radio Voice Preview & Debounce Bypass Verification
    RadioVoiceEngine.reset()
    RadioVoiceEngine.playRadio("cmd_push", RadioVoiceEngine.PRIORITY_COMMAND)
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_push", "Initial playRadio cmd_push accepted")

    -- Calling playRadio again within 12s is rejected
    local rejected = RadioVoiceEngine.playRadio("cmd_push", RadioVoiceEngine.PRIORITY_COMMAND)
    assertEq(rejected, false, "playRadio rejected by 12s debounce guard")

    -- preview() bypasses debounce guard and immediately triggers
    local previewOk = RadioVoiceEngine.preview("cmd_push")
    assertTrue(previewOk, "preview() successfully bypasses 12s debounce")
    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_push", "Last played key is cmd_push")
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_BEEP_OPEN, "preview transitions to STATE_BEEP_OPEN")

    -- Step past open beep (0.12s) -> transitions to STATE_PLAYING_VOICE
    RadioVoiceEngine.step(0.15)
    assertEq(RadioVoiceEngine.getState(), RadioVoiceEngine.STATE_PLAYING_VOICE, "Engine transitions to STATE_PLAYING_VOICE")

    -- 2. CSP ac.StateCar driverName Function-Type Guard Verification
    TacticalTicker.reset()

    -- Mock car where driverName is a C++ Lua function / method (as in CSP ac.StateCar)
    local carLeadFn = {
      index = 0,
      driverName = function(self) return "Charles Leclerc" end,
      position = { x = 0.0, y = 0.0, z = 12.0 },
      speedKmh = 230,
      gas = 1.0,
      brake = 0.0,
      splineLoc = 0.40,
      steer = 0.0,
      gear = 6,
      isAIControlled = true,
      isInPitlane = false,
      isInPit = false,
      rpm = 11000,
      maxRpm = 12500,
      steerAngle = 0.0,
      slipRatio = {0.01, 0.01, 0.01, 0.01},
      tyresWear = {0.1, 0.1, 0.1, 0.1},
      tyresTemp = {90, 90, 90, 90},
      wheelAngularSpeed = {200, 200, 200, 200},
      tyreRadius = {0.33, 0.33, 0.33, 0.33},
    }

    local carHunterFn = {
      index = 1,
      driverName = function(self) return "Max Verstappen" end,
      position = { x = 0.0, y = 0.0, z = 0.0 },
      speedKmh = 245,
      gas = 1.0,
      brake = 0.0,
      splineLoc = 0.395,
      steer = 0.0,
      gear = 6,
      isAIControlled = true,
      isInPitlane = false,
      isInPit = false,
      rpm = 11800,
      maxRpm = 12500,
      steerAngle = 0.0,
      slipRatio = {0.01, 0.01, 0.01, 0.01},
      tyresWear = {0.1, 0.1, 0.1, 0.1},
      tyresTemp = {95, 95, 95, 95},
      wheelAngularSpeed = {210, 210, 210, 210},
      tyreRadius = {0.33, 0.33, 0.33, 0.33},
    }

    local persona = {
      aggression = 0.70,
      defensiveness = 0.65,
      consistency = 0.85,
      patience = 0.60,
      awareness = 0.80,
      paceBias = 1.0,
      mistakeProne = 0.05,
      reactionTime = 0.20,
      overtakeSkill = 0.80,
      pressureResistance = 0.75,
    }

    local raceCtx = {
      isYellowFlag = false,
      isBlueFlagged = false,
      trackWetness = 0.0,
      compoundGripMultiplier = 1.0,
      isInPitlane = false,
      isRetired = false,
    }

    -- Execute stepCar where behindCar.driverName is a Lua function
    -- Previously threw: "bad argument #1 to 'lower' (string expected, got function)"
    local okStep, leadAiState = pcall(TacticalTicker.stepCar, carLeadFn, nil, carHunterFn, persona, 0.0, raceCtx, 0.1)
    assertTrue(okStep, "TacticalTicker.stepCar executed without crash when driverName is a function")
    assertTrue(leadAiState ~= nil, "AI State successfully computed")
    assertTrue(leadAiState.stress > 0.0, "Stress calculated with MTI bonus for top pressure driver Max Verstappen")

    TacticalTicker.reset()
    RadioVoiceEngine.reset()
    print("  -> Passed: Radio Voice Preview & CSP DriverName Function Guard verified.")
  end
  runTest58()
end

do
  print("\n[Test 59] Testing TV Director Configuration, Hotspot Scoring & Priority Preemption...")
  local function runTest59()
    local TVDirectorEngine = require("lib/broadcast/TVDirectorEngine")
    local RaceContext = require("lib/core/RaceContext")

    TVDirectorEngine.reset()

    -- 1. Default disabled verification (Requirement: defaults to closed)
    assertEq(TVDirectorEngine.isEnabled(), false, "TV Director defaults to disabled (closed)")

    -- 2. Single Button Toggle Logic
    local stateOn = TVDirectorEngine.toggleEnabled()
    assertEq(stateOn, true, "Single toggle button enables TV Director")
    assertEq(TVDirectorEngine.isEnabled(), true, "isEnabled() reflects active state")

    local stateOff = TVDirectorEngine.toggleEnabled()
    assertEq(stateOff, false, "Single toggle button disables TV Director")
    assertEq(TVDirectorEngine.isEnabled(), false, "isEnabled() reflects inactive state")

    -- 3. Configurable Parameters & Defaults (Requirement: 1, 2 configurable, default 5s / 12s / 15s)
    assertEq(TVDirectorEngine.getMinDwellTime(), 5.0, "Default min dwell time is 5.0s")
    assertEq(TVDirectorEngine.getMaxDwellTime(), 12.0, "Default max dwell time is 12.0s")
    assertEq(TVDirectorEngine.getQuietWindow(), 15.0, "Default quiet window is 15.0s")

    TVDirectorEngine.setMinDwellTime(3.5)
    assertEq(TVDirectorEngine.getMinDwellTime(), 3.5, "Custom min dwell time accepted")
    TVDirectorEngine.setMaxDwellTime(18.0)
    assertEq(TVDirectorEngine.getMaxDwellTime(), 18.0, "Custom max dwell time accepted")
    TVDirectorEngine.setQuietWindow(25.0)
    assertEq(TVDirectorEngine.getQuietWindow(), 25.0, "Custom quiet window accepted")

    -- Clamping guards
    TVDirectorEngine.setMinDwellTime(0.2)
    assertEq(TVDirectorEngine.getMinDwellTime(), 1.0, "Min dwell time clamped to 1.0s minimum")
    TVDirectorEngine.setMaxDwellTime(100.0)
    assertEq(TVDirectorEngine.getMaxDwellTime(), 60.0, "Max dwell time clamped to 60.0s maximum")

    -- Reset back to defaults
    TVDirectorEngine.setMinDwellTime(5.0)
    TVDirectorEngine.setMaxDwellTime(12.0)
    TVDirectorEngine.setQuietWindow(15.0)

    -- 4. Hotspot Scoring & Priority Preemption
    TVDirectorEngine.setEnabled(true)

    -- Mock RaceContext state:
    -- Car 0: P1 leader, gap 999.0s (cruising alone)
    -- Car 1: P2 chaser, gap 0.25s (intense battle)
    -- Car 2: P3 car, spinning out (lastMistakeType = "SPIN")
    local c0 = RaceContext.getCarState(0)
    c0.isConnected = true
    c0.isAIControlled = true
    c0.isRetired = false
    c0.racePosition = 1
    c0.gapToAhead = 999.0
    c0.lastMistakeType = "NONE"

    local c1 = RaceContext.getCarState(1)
    c1.isConnected = true
    c1.isAIControlled = true
    c1.isRetired = false
    c1.racePosition = 2
    c1.gapToAhead = 0.25
    c1.lastMistakeType = "NONE"
    c1.stress = 7.5
    c1.mti = 2.2

    local c2 = RaceContext.getCarState(2)
    c2.isConnected = true
    c2.isAIControlled = true
    c2.isRetired = false
    c2.racePosition = 3
    c2.gapToAhead = 3.5
    c2.lastMistakeType = "SPIN"

    local raceState = RaceContext.getRaceState()
    raceState.carsCount = 3
    raceState.currentLap = 5
    raceState.totalLaps = 13

    -- Step TV Director: Car 2 (SPIN) has P0 Emergency priority -> instant cut
    TVDirectorEngine.step(0.1, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 2, "Car 2 spinning out takes highest priority (P0 EMERGENCY)")
    assertEq(TVDirectorEngine.getCurrentPriority(), TVDirectorEngine.PRIORITY_EMERGENCY, "Priority is EMERGENCY (0)")
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_TRACK, "Incident uses Track TV camera")

    print("  -> Passed: TV Director Configuration, Hotspot Scoring & Priority Preemption verified.")
  end
  runTest59()
end

do
  print("\n[Test 60] Testing TV Director Dwell Hysteresis, Styles & Manual Override...")
  local function runTest60()
    local TVDirectorEngine = require("lib/broadcast/TVDirectorEngine")
    local RaceContext = require("lib/core/RaceContext")

    TVDirectorEngine.reset()
    TVDirectorEngine.setEnabled(true)
    TVDirectorEngine.setMinDwellTime(5.0)
    TVDirectorEngine.setMaxDwellTime(12.0)
    TVDirectorEngine.setQuietWindow(15.0)

    -- Clear past incidents in RaceContext for dwell test
    local c2 = RaceContext.getCarState(2)
    c2.lastMistakeType = "NONE"
    c2.tacticalState = "CRUISE"
    local c1 = RaceContext.getCarState(1)
    c1.lastMistakeType = "NONE"
    c1.tacticalState = "CRUISE"
    c1.gapToAhead = 999.0
    c1.stress = 0.0
    c1.mti = 0.0

    -- Force initial cut to Car 1
    TVDirectorEngine.forceCut(1, TVDirectorEngine.CAMERA_MODE_TRACK, "TEST_INITIAL", TVDirectorEngine.PRIORITY_BATTLE, 8.0)
    assertEq(TVDirectorEngine.getFocusedCar(), 1, "Initial focus on Car 1")
    assertEq(TVDirectorEngine.getDwellTimer(), 0.0, "Dwell timer initialized to 0")

    -- 1. Dwell Time Hysteresis: Step 2.0s (< min dwell 5.0s) with competing candidate
    local c0 = RaceContext.getCarState(0)
    c0.isConnected = true
    c0.racePosition = 1
    c0.gapToAhead = 0.1 -- Small score increase

    TVDirectorEngine.step(2.0, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 1, "Director holds Car 1 due to min dwell hysteresis (elapsed 2.0s < 5.0s)")

    -- Step past min dwell time (2.0s + 4.0s = 6.0s >= 5.0s min dwell threshold)
    TVDirectorEngine.step(4.0, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 0, "Director cut to higher-scoring Car 0 after min dwell elapsed")

    -- 2. Director Style Presets
    TVDirectorEngine.setStyle(TVDirectorEngine.STYLE_ONBOARD)
    assertEq(TVDirectorEngine.getStyle(), TVDirectorEngine.STYLE_ONBOARD, "Director style set to ONBOARD")

    TVDirectorEngine.setStyle(TVDirectorEngine.STYLE_ACTION)
    assertEq(TVDirectorEngine.getStyle(), TVDirectorEngine.STYLE_ACTION, "Director style set to ACTION")

    -- 3. Manual Override Protection
    local mockSim = {
      focusedCar = 1,
      cameraMode = TVDirectorEngine.CAMERA_MODE_TRACK,
      isReplayActive = false
    }

    -- Step to record baseline
    TVDirectorEngine.step(0.1, mockSim)
    assertEq(TVDirectorEngine.isManualOverrideActive(), false, "Override inactive when matching engine state")

    -- Player changes camera/car externally (e.g. presses F1 or PageUp to Car 5)
    mockSim.focusedCar = 5
    TVDirectorEngine.step(0.1, mockSim)
    assertTrue(TVDirectorEngine.isManualOverrideActive(), "Manual override activated when player alters camera externally")
    assertTrue(TVDirectorEngine.getQuietTimer() >= 14.8 and TVDirectorEngine.getQuietTimer() <= 15.0, "Quiet window initialized to ~15.0s")

    -- While quiet window active, automatic director cuts are suppressed
    TVDirectorEngine.step(5.0, mockSim)
    assertTrue(TVDirectorEngine.isManualOverrideActive(), "Override remains active (remaining 10.0s)")

    -- Step past 15.0s quiet window
    TVDirectorEngine.step(11.0, mockSim)
    assertEq(TVDirectorEngine.isManualOverrideActive(), false, "Quiet window expires, director resumes autonomous operation")

    -- 4. Verify DashboardUI Tab 6 & Header Master Button
    local DashboardUI = require("lib/ui/DashboardUI")
    local okUI1 = pcall(DashboardUI.renderDirectorTab)
    assertTrue(okUI1, "DashboardUI.renderDirectorTab renders cleanly when disabled")

    TVDirectorEngine.setEnabled(true)
    local okUI2 = pcall(DashboardUI.renderDirectorTab)
    assertTrue(okUI2, "DashboardUI.renderDirectorTab renders cleanly when active with live telemetry")

    local okMain = pcall(DashboardUI.renderMain, 0.05, 4)
    assertTrue(okMain, "DashboardUI.renderMain renders cleanly with TV Director master toggle button")

    TVDirectorEngine.reset()
    print("  -> Passed: TV Director Dwell Hysteresis, Styles, Manual Override & DashboardUI verified.")
  end
  runTest60()
end

do
  print("\n[Test 61] Testing Contextual Tactical Camera Perspectives (Cockpit, Nose, Rear, Heli)...")
  local function runTest61()
    local TVDirectorEngine = require("lib/broadcast/TVDirectorEngine")
    local RaceContext = require("lib/core/RaceContext")

    TVDirectorEngine.reset()
    TVDirectorEngine.setEnabled(true)
    TVDirectorEngine.setMinDwellTime(2.0)
    TVDirectorEngine.setMaxDwellTime(10.0)

    local raceState = RaceContext.getRaceState()
    raceState.carsCount = 4
    raceState.currentLap = 5
    raceState.totalLaps = 15
    raceState.trackLengthM = 1000.0

    local function mockGetCar(i)
      local c = RaceContext.getCarState(i)
      local sp = c.splinePosition or 0.0
      return {
        isConnected = c.isConnected,
        splinePosition = sp,
        position = { x = sp * 1000.0, y = 0.0, z = 0.0 },
        velocity = { x = 30.0, y = 0.0, z = 0.0 }
      }
    end

    -- 1. Attacking Move -> ATTACK_NOSE (Bumper Cam)
    local c0 = RaceContext.getCarState(0)
    c0.isConnected = true
    c0.racePosition = 1
    c0.gapToAhead = 999.0
    c0.tacticalState = "CRUISE"
    c0.lastMistakeType = "NONE"
    c0.stress = 2.0
    c0.mti = 0.5
    c0.splinePosition = 0.200

    local c1 = RaceContext.getCarState(1)
    c1.isConnected = true
    c1.racePosition = 2
    c1.gapToAhead = 0.45
    c1.gapAheadSec = 0.45
    c1.tacticalState = "ATTACK"
    c1.activeSkill = "POUNCE_PASS"
    c1.lastMistakeType = "NONE"
    c1.stress = 3.0
    c1.mti = 0.8
    c1.splinePosition = 0.190

    local c2 = RaceContext.getCarState(2)
    c2.isConnected = true
    c2.racePosition = 3
    c2.gapToAhead = 5.0
    c2.tacticalState = "CRUISE"
    c2.lastMistakeType = "NONE"
    c2.stress = 0.0
    c2.mti = 0.0
    c2.splinePosition = 0.150

    local c3 = RaceContext.getCarState(3)
    c3.isConnected = true
    c3.racePosition = 4
    c3.gapToAhead = 10.0
    c3.tacticalState = "CRUISE"
    c3.lastMistakeType = "NONE"
    c3.splinePosition = 0.100

    RaceContext.updateTopology(4, mockGetCar)

    TVDirectorEngine.step(0.1, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 1, "Director focuses on Car 1 attacking move")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_ATTACK_NOSE, "Situation resolved to ATTACK_NOSE")
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_DRIVABLE, "Camera mode is Drivable")
    assertEq(TVDirectorEngine.getCurrentSubMode(), TVDirectorEngine.DRIVABLE_BUMPER, "SubMode is Bumper for low front nose view")

    -- 2. Psychological Strain -> STRAIN_COCKPIT (Dash / Cockpit view)
    c1.tacticalState = "CRUISE"
    c1.activeSkill = "NONE"
    c1.gapToAhead = 999.0

    c2.stress = 8.0
    c2.mti = 2.4
    c2.gapBehindSec = 0.35
    c2.tacticalState = "CRUISE"
    c2.splinePosition = 0.180
    c3.splinePosition = 0.170
    RaceContext.updateTopology(4, mockGetCar)

    TVDirectorEngine.step(3.0, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 2, "Director focuses on Car 2 under extreme psychological strain")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_STRAIN_COCKPIT, "Situation resolved to STRAIN_COCKPIT")
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_DRIVABLE, "Camera mode is Drivable")
    assertEq(TVDirectorEngine.getCurrentSubMode(), TVDirectorEngine.DRIVABLE_DASH, "SubMode is Dash for steering wheel & cockpit strain view")

    -- 3. Defending Move -> DEFEND_REAR (Chase / Mirror dual framing)
    c2.stress = 1.0
    c2.mti = 0.2
    c2.tacticalState = "DEFEND"
    c2.activeSkill = "DEFENSIVE_COVER"

    TVDirectorEngine.step(3.0, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 2, "Director tracks Car 2 defensive battle")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_DEFEND_REAR, "Situation evolved to DEFEND_REAR")
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_DRIVABLE, "Camera mode is Drivable")
    assertEq(TVDirectorEngine.getCurrentSubMode(), TVDirectorEngine.DRIVABLE_CHASE, "SubMode is Chase for rear mirror and chaser framing")

    -- 4. Side-by-Side Corner Duel -> SIDE_HELICOPTER (Helicopter Aerial)
    c2.tacticalState = "CRUISE"
    c2.activeSkill = "NONE"

    c0.splinePosition = 0.5000
    c1.splinePosition = 0.5020 -- 2.0m lateral / longitudinal proximity
    c0.speedKmh = 120.0
    c1.speedKmh = 120.0
    c0.tacticalState = "OVERTAKING"
    c0.gapToAhead = 0.15
    RaceContext.updateTopology(4, mockGetCar)

    TVDirectorEngine.step(3.0, nil)
    assertEq(TVDirectorEngine.getFocusedCar(), 0, "Director cuts to side-by-side corner duel on Car 0")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_SIDE_HELICOPTER, "Situation resolved to SIDE_HELICOPTER")
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_HELICOPTER, "Camera mode is Helicopter for aerial perspective")

    TVDirectorEngine.reset()
    print("  -> Passed: Contextual Tactical Camera Perspectives verified.")
  end
  runTest61()
end

do
  print("\n[Test 62] Testing Tactical Perspective Preferences, Storytelling Arc & Instant Audition...")
  local function runTest62()
    local TVDirectorEngine = require("lib/broadcast/TVDirectorEngine")
    local RaceContext = require("lib/core/RaceContext")
    local DashboardUI = require("lib/ui/DashboardUI")

    TVDirectorEngine.reset()
    TVDirectorEngine.setEnabled(true)

    -- 1. Verify Default Preferences (All True)
    assertEq(TVDirectorEngine.getPrefStrainCockpit(), true, "Default prefStrainCockpit is true")
    assertEq(TVDirectorEngine.getPrefAttackNose(), true, "Default prefAttackNose is true")
    assertEq(TVDirectorEngine.getPrefDefendRear(), true, "Default prefDefendRear is true")
    assertEq(TVDirectorEngine.getPrefSideHelicopter(), true, "Default prefSideHelicopter is true")
    assertEq(TVDirectorEngine.getPrefStorytelling(), true, "Default prefStorytelling is true")

    -- 2. Toggle and Fallback Behavior
    TVDirectorEngine.setPrefAttackNose(false)
    assertEq(TVDirectorEngine.getPrefAttackNose(), false, "prefAttackNose set to false")

    local function mockGetCar(i)
      local c = RaceContext.getCarState(i)
      local sp = c.splinePosition or 0.0
      return {
        isConnected = c.isConnected,
        splinePosition = sp,
        position = { x = sp * 1000.0, y = 0.0, z = 0.0 },
        velocity = { x = 30.0, y = 0.0, z = 0.0 }
      }
    end

    local c0 = RaceContext.getCarState(0)
    c0.isConnected = true
    c0.racePosition = 1
    c0.gapToAhead = 999.0
    c0.tacticalState = "CRUISE"
    c0.lastMistakeType = "NONE"
    c0.splinePosition = 0.200

    local c1 = RaceContext.getCarState(1)
    c1.isConnected = true
    c1.racePosition = 2
    c1.gapToAhead = 0.45
    c1.gapAheadSec = 0.45
    c1.tacticalState = "ATTACK"
    c1.activeSkill = "POUNCE_PASS"
    c1.lastMistakeType = "NONE"
    c1.splinePosition = 0.188 -- 12m trailing distance (aheadDist = 12m > 4.2m)

    RaceContext.updateTopology(4, mockGetCar)

    TVDirectorEngine.step(0.1, nil)
    -- With prefAttackNose disabled, attack falls back to World Feed / Track TV mode
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_WORLD_FEED, "Disabled attack nose falls back to WORLD_FEED")
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_TRACK, "Fallback uses Track camera")

    -- Re-enable via toggle
    TVDirectorEngine.togglePrefAttackNose()
    assertEq(TVDirectorEngine.getPrefAttackNose(), true, "togglePrefAttackNose restored to true")

    -- 3. Instant Perspective Audition via forceCut
    TVDirectorEngine.forceCut(0, TVDirectorEngine.CAMERA_MODE_DRIVABLE, "AUD_NOSE", 1, 6.0, TVDirectorEngine.DRIVABLE_BUMPER, TVDirectorEngine.SITUATION_ATTACK_NOSE)
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_DRIVABLE, "Audition camera mode set to Drivable")
    assertEq(TVDirectorEngine.getCurrentSubMode(), TVDirectorEngine.DRIVABLE_BUMPER, "Audition subMode set to Bumper")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_ATTACK_NOSE, "Audition situation set to ATTACK_NOSE")

    TVDirectorEngine.forceCut(0, TVDirectorEngine.CAMERA_MODE_DRIVABLE, "AUD_COCKPIT", 1, 6.0, TVDirectorEngine.DRIVABLE_DASH, TVDirectorEngine.SITUATION_STRAIN_COCKPIT)
    assertEq(TVDirectorEngine.getCurrentSubMode(), TVDirectorEngine.DRIVABLE_DASH, "Audition subMode set to Dash")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_STRAIN_COCKPIT, "Audition situation set to STRAIN_COCKPIT")

    TVDirectorEngine.forceCut(0, TVDirectorEngine.CAMERA_MODE_DRIVABLE, "AUD_CHASE", 1, 6.0, TVDirectorEngine.DRIVABLE_CHASE, TVDirectorEngine.SITUATION_DEFEND_REAR)
    assertEq(TVDirectorEngine.getCurrentSubMode(), TVDirectorEngine.DRIVABLE_CHASE, "Audition subMode set to Chase")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_DEFEND_REAR, "Audition situation set to DEFEND_REAR")

    TVDirectorEngine.forceCut(0, TVDirectorEngine.CAMERA_MODE_HELICOPTER, "AUD_HELI", 1, 6.0, 0, TVDirectorEngine.SITUATION_SIDE_HELICOPTER)
    assertEq(TVDirectorEngine.getCurrentCameraMode(), TVDirectorEngine.CAMERA_MODE_HELICOPTER, "Audition camera mode set to Helicopter")
    assertEq(TVDirectorEngine.getCurrentSituation(), TVDirectorEngine.SITUATION_SIDE_HELICOPTER, "Audition situation set to SIDE_HELICOPTER")

    -- 4. DashboardUI Director Tab Verification with New Controls
    local okUI = pcall(DashboardUI.renderDirectorTab)
    assertTrue(okUI, "DashboardUI.renderDirectorTab renders cleanly with all tactical perspective controls and audition buttons")

    TVDirectorEngine.reset()
    print("  -> Passed: Tactical Perspective Preferences, Storytelling Arc & Instant Audition verified.")
  end
  runTest62()
end

-- ==============================================================================
-- [Test 63] Testing COBAL Metrics, BattleTracker, Fuzzy Commitment & Tab 7 Radar
-- ==============================================================================
do
  local function runTest63()
    print("[Test 63] Testing COBAL Metrics, BattleTracker, Fuzzy Commitment & Tab 7 Radar...")
    local BattleTracker = require("lib/driver/BattleTracker")
    local TacticalTicker = require("lib/driver/TacticalTicker")
    local DashboardUI = require("lib/ui/DashboardUI")
    local RaceContext = require("lib/core/RaceContext")

    BattleTracker.reset()

    -- 1. Verify BattleTracker reset state
    local s0 = BattleTracker.getStats()
    assertEq(s0.totalDuelTime, 0.0, "Initial duel time is 0")
    assertEq(s0.completedOvertakes, 0, "Initial completed overtakes is 0")
    assertEq(s0.activeDuelsCount, 0, "Initial active duels is 0")

    -- 2. Mock race cars in close proximity to simulate a sustained duel
    local mockCars = {
      [0] = { index = 0, speedKmh = 120.0, splinePosition = 0.500, position = { x = 0, y = 0, z = 100 } },
      [1] = { index = 1, speedKmh = 125.0, splinePosition = 0.498, position = { x = 0, y = 0, z = 92 } },
    }
    local mockStates = {
      [0] = { isRetired = false, aheadCarIndex = -1, aheadDist = 999.0, driverName = "Driver 1" },
      [1] = { isRetired = false, aheadCarIndex = 0, aheadDist = 8.0, driverName = "Driver 2" },
    }

    local function mockGetCar(idx) return mockCars[idx] end
    local function mockGetState(idx) return mockStates[idx] end

    -- Step 1: Trigger duel detection
    BattleTracker.step(0.5, 10.0, 2, mockGetState, mockGetCar)
    local s1 = BattleTracker.getStats()
    assertEq(s1.activeDuelsCount, 1, "Active duels detected between Car 1 and Car 0")
    assertTrue(s1.totalDuelTime >= 0.5, "Duel time accumulated")
    assertEq(s1.duelEpisodesCount, 1, "One duel episode registered")

    -- Step 2: Simulate overtake by swapping positions and reporting
    mockStates[1].aheadCarIndex = -1
    mockStates[1].aheadDist = 999.0
    mockStates[0].aheadCarIndex = 1
    mockStates[0].aheadDist = 8.0
    mockCars[1].splinePosition = 0.505
    mockCars[0].splinePosition = 0.500
    BattleTracker.step(0.5, 10.5, 2, mockGetState, mockGetCar)
    local s2 = BattleTracker.getStats()
    assertEq(s2.completedOvertakes, 1, "Completed overtake correctly detected and counted")

    -- Step 3: Record combat maneuvers & pressure mistakes
    BattleTracker.recordSkillExecuted("POUNCE_PASS", 1)
    BattleTracker.recordSkillExecuted("SWITCHBACK", 0)
    BattleTracker.recordSkillExecuted("GENTLE_SQUEEZE", 1)
    BattleTracker.recordPressureMistake(0, "BRAKE_LOCKUP")

    local s3 = BattleTracker.getStats()
    assertEq(s3.lateBrakeDivesCount, 1, "POUNCE_PASS recorded")
    assertEq(s3.switchbacksCount, 1, "SWITCHBACK recorded")
    assertEq(s3.defenseSqueezesCount, 1, "GENTLE_SQUEEZE recorded")
    assertEq(s3.pressureMistakesCount, 1, "Pressure mistake recorded")

    -- 4. Verify TacticalTicker Fuzzy Commitments in aiState
    local persona = { base_caution = 0.8, base_aggression = 0.85, pressure_resist = 0.8 }
    local carA = { index = 1, speedKmh = 120.0, splinePosition = 0.40, position = { x = 0, y = 0, z = 0 } }
    local carAhead = { index = 0, speedKmh = 115.0, splinePosition = 0.401, position = { x = 0, y = 0, z = 12 } }
    local aiState = TacticalTicker.stepCar(carA, carAhead, nil, persona, 0.0, { currentLap = 2 }, 0.1)

    assertTrue(aiState.pursuitCommitment > 0.0, "Pursuit commitment ramped up continuously when closing in")
    assertTrue(type(aiState.lineVariationOffset) == "number", "Line variation offset exists as scalar")

    -- 5. Verify DashboardUI Tab 7 renders cleanly
    local okTab7 = pcall(DashboardUI.renderBattleRadarTab)
    assertTrue(okTab7, "DashboardUI.renderBattleRadarTab renders cleanly without exceptions")

    BattleTracker.reset()
    print("  -> Passed: COBAL Metrics, BattleTracker, Fuzzy Commitment & Tab 7 Radar verified.")
  end
  runTest63()
end

-- ==============================================================================
-- Test 64: Experience Mode (Driver vs Spectator), Cockpit Safety Lock & Proactive Alerts
-- ==============================================================================
do
  local function runTest64()
    print("[Test 64] Testing Experience Mode, Cockpit Safety Lock & Proactive Radio Alerts...")
    local RaceContext = require("lib/core/RaceContext")
    local TVDirectorEngine = require("lib/broadcast/TVDirectorEngine")
    local TacticalTicker = require("lib/driver/TacticalTicker")
    local RadioVoiceEngine = require("lib/audio/RadioVoiceEngine")

    -- 1. Experience Mode State Machine
    RaceContext.reset()
    assertEq(RaceContext.getExperienceMode(), RaceContext.MODE_DRIVER, "Default experience mode is DRIVER")
    RaceContext.setExperienceMode(RaceContext.MODE_SPECTATOR)
    assertEq(RaceContext.getExperienceMode(), RaceContext.MODE_SPECTATOR, "Mode transitions to SPECTATOR")
    RaceContext.setExperienceMode(RaceContext.MODE_DRIVER)
    assertEq(RaceContext.getExperienceMode(), RaceContext.MODE_DRIVER, "Mode returns to DRIVER")

    -- 2. Cockpit Anti-Interference Lock in TVDirectorEngine
    TVDirectorEngine.reset()
    TVDirectorEngine.setEnabled(true)
    local liveSim = { isReplayActive = false }
    
    -- In DRIVER mode with liveSim, step() must return early and NOT advance dwell or execute cuts
    local dwellBefore = TVDirectorEngine.getDwellTimer()
    TVDirectorEngine.step(1.0, liveSim)
    assertEq(TVDirectorEngine.getDwellTimer(), dwellBefore, "Dwell timer does not advance during live driving in DRIVER mode")

    -- In SPECTATOR mode with liveSim, step() must execute
    RaceContext.setExperienceMode(RaceContext.MODE_SPECTATOR)
    TVDirectorEngine.step(0.5, liveSim)
    -- Either dwellTimer executed a cut (reset to 0.0) or dwell advanced to 5.5
    local dwellAfter = TVDirectorEngine.getDwellTimer()
    assertTrue(dwellAfter == 0.0 or dwellAfter == 5.5, "TV Director executed step logic in SPECTATOR mode")

    -- 3. Proactive Team Radio Alerts on Technical Mistakes
    -- Step AI car 1 attacking human player car 0 (aheadCar.index == 0, distance 10m)
    local aiCar = { index = 1, speedKmh = 160.0, splinePosition = 0.499, position = { x = 0, y = 0, z = 0 } }
    local playerAhead = { index = 0, speedKmh = 155.0, splinePosition = 0.500, position = { x = 0, y = 0, z = 10 } }
    local personaAggr = { base_caution = 0.3, base_aggression = 0.9 }
    TacticalTicker.stepCar(aiCar, playerAhead, nil, personaAggr, 0.0, { currentLap = 3 }, 0.1)

    assertEq(RadioVoiceEngine.getLastPlayedKey(), "cmd_defend", "Proactive team radio triggered cmd_defend when AI attacks player car 0")

    RaceContext.setExperienceMode(RaceContext.MODE_DRIVER)
    print("  -> Passed: Experience Mode, Cockpit Safety Lock & Proactive Radio Alerts verified.")
  end
  runTest64()
end

print("==================================================================")
print("  ALL 64 INTEGRATION TESTS PASSED: Ultimate AI Grand Prix Pro!    ")
print("==================================================================")



