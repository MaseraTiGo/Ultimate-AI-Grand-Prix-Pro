local dumbActuator = require("dumb_actuator_broadcaster")

print("[Test 46] Testing Dumb Actuator & Telemetry Broadcaster IPC Lifecycle...")
assert(dumbActuator.init() == true, "dumbActuator.init failed")
assert(dumbActuator.isBroadcasting() == true, "default broadcast should be true")

-- Test Toggle
dumbActuator.setBroadcasting(false)
assert(dumbActuator.isBroadcasting() == false, "broadcasting should be false after toggle")
dumbActuator.setBroadcasting(true)
assert(dumbActuator.isBroadcasting() == true, "broadcasting should be restored")

-- Test Command Execution
local dummyCmd = { id = 999, a = "BROADCAST_TOGGLE", c = -1, raw = '{"id":999,"a":"BROADCAST_TOGGLE","c":-1,"p":{"enable":false}}' }
dumbActuator.executeCommand(dummyCmd)
assert(dumbActuator.isBroadcasting() == false, "Command execution failed to toggle broadcast")

local stats = dumbActuator.getStats()
assert(stats ~= nil, "stats should not be nil")
print("  -> Passed: Dumb Actuator & Telemetry Broadcaster IPC Lifecycle verified.")
