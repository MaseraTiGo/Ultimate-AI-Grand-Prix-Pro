"""
StrategyManager Network Protocol Specifications
================================================
Defines:
1. Lua-to-Admin UDP Protocol (Compact JSON with bitmasks)
2. Admin-to-User TCP Hub Protocol:
   - Server-Side Fog of War filtering
   - Lobby State Machine (LOBBY_OPEN, ROSTER_FROZEN, RACE_ACTIVE)
   - User Roster Claiming & Server ACL Validation
"""

import json
from typing import Dict, Any, List, Optional, Set

PROTOCOL_VERSION = 100

# Bitmask Flags for Vehicle Boolean States (field 'f')
FLAG_IN_PITLANE       = 1 << 0   # 1
FLAG_IN_PITBOX        = 1 << 1   # 2
FLAG_DRS_AVAILABLE    = 1 << 2   # 4
FLAG_DRS_ACTIVE       = 1 << 3   # 8
FLAG_BLUE_FLAG        = 1 << 4   # 16
FLAG_YELLOW_FLAG      = 1 << 5   # 32
FLAG_RETIRED          = 1 << 6   # 64
FLAG_AI_CONTROLLED    = 1 << 7   # 128
FLAG_LIFT_AND_COAST   = 1 << 8   # 256
FLAG_BREAKING_TOW     = 1 << 9   # 512
FLAG_TYRE_COMPLAIN    = 1 << 10  # 1024
FLAG_PENALTY_STOP     = 1 << 11  # 2048

# Simulation Environment States
ENV_FLAG_REPLAY_ACTIVE   = 1 << 0
ENV_FLAG_SAFETY_CAR      = 1 << 1
ENV_FLAG_FCY             = 1 << 2
ENV_FLAG_FORMATION_LAP   = 1 << 3
ENV_FLAG_PIT_WINDOW_OPEN = 1 << 4

# Lobby Lifecycle State Machine
STATE_LOBBY_OPEN    = "LOBBY_OPEN"     # Pre-race: Users can freely bind/unbind drivers
STATE_ROSTER_FROZEN = "ROSTER_FROZEN"  # Parc Ferme: Rosters & setups locked by FIA Admin
STATE_RACE_ACTIVE   = "RACE_ACTIVE"    # In-race: Live strategy, commands strictly checked by ACL


class ProtocolCodec:
    """Wire encoding/decoding utilities."""

    @staticmethod
    def decode(raw_bytes: bytes) -> Optional[Dict[str, Any]]:
        try:
            return json.loads(raw_bytes.decode('utf-8'))
        except Exception:
            return None

    @staticmethod
    def encode(data: Dict[str, Any]) -> bytes:
        return json.dumps(data, separators=(',', ':')).encode('utf-8')

    @staticmethod
    def create_command(cmd_id: int, action: str, car_idx: int = -1, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Creates a standardized command packet dictionary for wire transmission.
        Matches the format expected by Lua dumb_actuator_broadcaster and TCP hubs:
        { 'id': cmd_id, 'a': action, 'c': car_idx, 'p': params }
        """
        pkt = {
            "id": int(cmd_id),
            "a": str(action),
            "c": int(car_idx)
        }
        if params is not None:
            pkt.update(params)
            pkt["p"] = params
        return pkt

    @staticmethod
    def parse_car_flags(flag_int: int) -> Dict[str, bool]:
        return {
            "in_pitlane": bool(flag_int & FLAG_IN_PITLANE),
            "in_pitbox": bool(flag_int & FLAG_IN_PITBOX),
            "drs_available": bool(flag_int & FLAG_DRS_AVAILABLE),
            "drs_active": bool(flag_int & FLAG_DRS_ACTIVE),
            "blue_flag": bool(flag_int & FLAG_BLUE_FLAG),
            "yellow_flag": bool(flag_int & FLAG_YELLOW_FLAG),
            "is_retired": bool(flag_int & FLAG_RETIRED),
            "is_ai": bool(flag_int & FLAG_AI_CONTROLLED),
            "lift_and_coast": bool(flag_int & FLAG_LIFT_AND_COAST),
            "breaking_tow": bool(flag_int & FLAG_BREAKING_TOW),
            "tyre_complain": bool(flag_int & FLAG_TYRE_COMPLAIN),
            "penalty_stop": bool(flag_int & FLAG_PENALTY_STOP),
        }

    @staticmethod
    def apply_fog_of_war(full_telemetry: Dict[str, Any], user_bound_cars: Set[int]) -> Dict[str, Any]:
        """
        Server-side Fog of War data masking.
        - Bound cars retain 100% deep telemetry (wear, temps, fuel, AI params).
        - Unbound rival cars have internal data stripped to None/NA, keeping ONLY public FIA timing info.
        """
        masked = {
            "y": "T_USER",
            "v": full_telemetry.get("v", PROTOCOL_VERSION),
            "e": full_telemetry.get("e", {}),
            "c": []
        }

        cars = full_telemetry.get("c", [])
        for car in cars:
            idx = car.get("i", 0)
            if idx in user_bound_cars:
                # 100% deep telemetry for own team
                masked["c"].append(dict(car))
            else:
                # Public FIA broadcast data only for rival cars
                rival_car = {
                    "i": idx,
                    "n": car.get("n", f"Driver #{idx}"),
                    "p": car.get("p", idx + 1),
                    "s": car.get("s", 0.0),
                    "v": car.get("v", 0.0),
                    "l": car.get("l", 0),
                    "ll": car.get("ll", 0),
                    "bl": car.get("bl", 0),
                    "s1": car.get("s1", 0),
                    "s2": car.get("s2", 0),
                    "s3": car.get("s3", 0),
                    "gl": car.get("gl", 0.0),
                    "ia": car.get("ia", 0.0),
                    "tc": car.get("tc", "M"),      # Visually public compound
                    "ta": car.get("ta", 0),        # Visually public stint age
                    "ps": car.get("ps", 0),        # Pit stops count
                    "f": car.get("f", 0),          # Public flags (pitlane, drs, retired)
                    # Fog of war masked fields:
                    "w": None,                     # Masked: 4-wheel wear
                    "tt": None,                    # Masked: tyre temperatures
                    "fr": None,                    # Masked: exact fuel remaining
                    "fl": None,                    # Masked: fuel burn per lap
                    "ec": None,                    # Masked: ERS charge
                    "rc": None,                    # Masked: radio tactical instructions
                    "sk": None,                    # Masked: active driving skill
                    "st": None,                    # Masked: psychological stress
                    "mo": None,                    # Masked: driver momentum
                }
                masked["c"].append(rival_car)

        return masked
