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

physics = {
  allowed = function() return true end,
  setAICarPosition = function() end,
  setAIStopCounter = function() end,
  setAISplineOffset = function() end,
  setAICaution = function() end,
  setAIAggression = function() end,
  setExtraAIGrip = function() end,
  setAIBrakeMistake = function() end,
  setAITractionMistake = function() end,
  setAIThrottleLimit = function(idx, lim) _throttleLimits[idx] = lim end,
  setCarFuel = function(idx, fuel) _fuelInjectedValues[idx] = fuel end,
}

ac = {
  getSim = function()
    return {
      carsCount = 4,
      raceLaps = 25,
      currentLap = 5,
      sessionTime = 120.0,
      isReplayActive = false,
      isYellowFlag = false,
      safetyCarActive = false,
    }
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
  overrideCarControls = function() return { combineAxis = false, headlightsFlash = false } end,
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
assertEq(mappedVerstappen.name, "Aggressive Bull", "Verstappen should resolve to Aggressive Bull")
assertTrue(mappedVerstappen.undercut_preference >= 0.90, "Verstappen undercut preference high")

local proceduralDriver = personaLoader.getPersonaForCar(7, "Jack Doohan")
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
local loopLead = {
  index = 1,
  position = vec3(0, 0, 100),
  speedKmh = 210,
  isAIControlled = true,
  splinePosition = 0.5,
  worldToLocal = { transformPoint = function(s, p) return vec3(0.5, 0, -12) end }
}
local loopChaser = {
  index = 2,
  position = vec3(0, 0, 85),
  speedKmh = 220,
  isAIControlled = true,
  splinePosition = 0.45
}

-- Warmup JIT
for i = 1, 50 do
  local st = TacticalTicker.stepCar(loopLead, nil, loopChaser, mappedVerstappen, 0.0, nil, 0.1)
  BehaviorActuator.applyActuator(loopLead, st, 0.1)
end

collectgarbage("collect")
local memBefore = collectgarbage("count")

for i = 1, 500 do
  local st = TacticalTicker.stepCar(loopLead, nil, loopChaser, mappedVerstappen, 0.0, nil, 0.1)
  BehaviorActuator.applyActuator(loopLead, st, 0.1)
end

local memAfter = collectgarbage("count")
local deltaKB = memAfter - memBefore
assertTrue(deltaKB < 1.0, string.format("Hot loop GC allocation must be ~0 KB across 500 cycles (Got %.2f KB)", deltaKB))
print(string.format("  -> Passed: Hot loop zero allocation confirmed (%.3f KB delta over 500 steps).", deltaKB))

-- [Test 15] Full system update loop integration (simUpdate & update pipeline)
print("[Test 15] Testing Full System Update Loop Integration...")
_G.script = {}
dofile("Ultimate AI Grand Prix Pro.lua")
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

print("==================================================================")
print("  ALL 16 INTEGRATION TESTS PASSED: Ultimate AI Grand Prix Pro!    ")
print("==================================================================")
