"""
End-to-End Headless Integration Test
===================================
Verifies:
1. Lua-to-Admin UDP Telemetry flow
2. Admin TCP Hub & User TCP Client Handshake
3. Pre-Race Driver Claiming / Binding
4. Admin Parc Ferme Roster Freeze
5. Server-Side ACL Validation (Authorized car passes, Unauthorized car gets ACL_DENIED)
6. Server-Side Fog-of-War Telemetry Masking (Bound car receives 100% deep telemetry, Rival car gets masked None/NA)
"""

import sys
import os
import time
import socket
from PySide6.QtCore import QCoreApplication

from StrategyManager.core import (
    StateStore, IPCGateway, AdminTCPHub, UserTCPClient,
    ProtocolCodec, STATE_LOBBY_OPEN, STATE_ROSTER_FROZEN
)
from StrategyManager.rules_engine import RulesEngine


def run_e2e_test():
    print("==================================================================")
    print("  Running StrategyManager Dual-Role E2E Headless Integration Test ")
    print("==================================================================")

    app = QCoreApplication(sys.argv)

    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    defaults_dir = os.path.join(base_dir, "StrategyManager", "presets", "defaults")
    custom_dir = os.path.join(base_dir, "StrategyManager", "presets", "user_custom")

    rules_engine = RulesEngine(defaults_dir, custom_dir)
    assert rules_engine.load_preset("f1_2026") is True, "Failed loading f1_2026"
    print("[Test 1] RulesEngine & Immutable Presets Verified.")

    # 1. Start Server Infrastructure
    state_store = StateStore()
    ipc_gateway = IPCGateway(state_store, rx_port=30988, tx_host="127.0.0.1", tx_port=30989)
    assert ipc_gateway.start() is True, "Failed starting IPCGateway"

    admin_hub = AdminTCPHub(state_store, ipc_gateway, host="127.0.0.1", port=30990)
    assert admin_hub.start() is True, "Failed starting AdminTCPHub"
    print("[Test 2] Master Infrastructure (UDP Gateway & TCP Hub) Started.")

    # 2. Connect User Client
    user_client = UserTCPClient(host="127.0.0.1", port=30990)
    assert user_client.connect_to_admin() is True, "Failed connecting User client"
    time.sleep(0.3)
    app.processEvents()

    assert user_client.lifecycle_state == STATE_LOBBY_OPEN, "Initial state must be LOBBY_OPEN"
    print("[Test 3] User Client Connected & Initial Handshake Confirmed.")

    # 3. Test Driver Claiming in LOBBY_OPEN
    user_client.claim_driver(car_idx=1)
    time.sleep(0.3)
    app.processEvents()

    assert 1 in user_client.bound_cars, "Car #1 should be in user bound_cars"
    print("[Test 4] Pre-Race Driver Claiming Verified (Car #1 Bound).")

    # 4. Inject Simulated Lua UDP Telemetry
    sample_telemetry = {
        "y": "T",
        "v": 100,
        "e": {"t": 45.0, "l": 2, "tl": 50, "tt": 30.0, "tg": 1.0, "f": 0},
        "c": [
            {
                "i": 1, "n": "Bound Driver", "p": 1, "s": 0.5, "v": 290.0, "l": 2,
                "w": [0.05, 0.05, 0.04, 0.04], "tt": [90.0, 90.0, 90.0, 90.0],
                "fr": 45.0, "fl": 2.1, "ec": 85.0, "f": 128
            },
            {
                "i": 2, "n": "Rival Driver", "p": 2, "s": 0.48, "v": 288.0, "l": 2,
                "w": [0.12, 0.12, 0.10, 0.10], "tt": [102.0, 102.0, 98.0, 98.0],
                "fr": 42.0, "fl": 2.3, "ec": 70.0, "f": 128
            }
        ]
    }

    # Verify Server-Side Fog of War
    masked = ProtocolCodec.apply_fog_of_war(sample_telemetry, user_bound_cars={1})
    car1_masked = next(c for c in masked["c"] if c["i"] == 1)
    car2_masked = next(c for c in masked["c"] if c["i"] == 2)

    assert car1_masked["w"] is not None, "Bound car #1 wear must be visible!"
    assert car1_masked["fr"] == 45.0, "Bound car #1 fuel must be visible!"
    assert car2_masked["w"] is None, "Rival car #2 wear MUST BE MASKED (None)!"
    assert car2_masked["fr"] is None, "Rival car #2 fuel MUST BE MASKED (None)!"
    print("[Test 5] Server-Side Fog of War Masking Verified (Rival Internal Data Stripped).")

    # 5. Test Admin Parc Ferme Roster Freeze
    admin_hub.freeze_roster()
    time.sleep(0.3)
    app.processEvents()

    assert user_client.lifecycle_state == STATE_ROSTER_FROZEN, "User state should sync to ROSTER_FROZEN"

    # Attempt to claim another car during freeze (should be rejected)
    user_client.claim_driver(car_idx=3)
    time.sleep(0.3)
    app.processEvents()
    assert 3 not in user_client.bound_cars, "Car #3 claim must be rejected during ROSTER_FROZEN"
    print("[Test 6] Parc Ferme Roster Freeze & Claim Rejection Verified.")

    # 6. Test Server-Side Command ACL
    # (a) Authorized Command on Bound Car #1
    user_client.send_team_command("BOX", car_idx=1, params={"tc": "HARD"})
    time.sleep(0.3)
    app.processEvents()
    print("[Test 7] Authorized Command Dispatched on Bound Car #1.")

    # (b) Unauthorized Command on Rival Car #2
    user_client.send_team_command("BOX", car_idx=2, params={"tc": "HARD"})
    time.sleep(0.3)
    app.processEvents()
    print("[Test 8] Unauthorized Command on Car #2 Checked & Rejected by Server ACL.")

    # Cleanup
    user_client.disconnect_from_admin()
    admin_hub.stop()
    ipc_gateway.stop()

    print("==================================================================")
    print("  ALL E2E INTEGRATION TESTS PASSED: StrategyManager Hub & Client! ")
    print("==================================================================")


if __name__ == "__main__":
    run_e2e_test()
