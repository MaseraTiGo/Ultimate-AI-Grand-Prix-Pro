"""
StrategyManager State Store & Event Bus
=======================================
Thread-safe central state repository and Qt Signal / Pub-Sub dispatcher.
Receives wire data from IPC Gateway and updates normalized race state.
"""

from typing import Dict, Any, List, Optional
import time
from PySide6.QtCore import QObject, Signal
from StrategyManager.core.protocol import ProtocolCodec


class StateStore(QObject):
    """
    Authoritative local memory store reflecting real-time Assetto Corsa simulation.
    Emits granular Qt signals when race state, car telemetry, or race events change.
    """
    # Signals for UI and Strategy Engines
    telemetry_updated = Signal(dict)       # Raw / parsed telemetry packet
    car_updated = Signal(int, dict)        # (car_index, car_state_dict)
    event_received = Signal(dict)          # Discrete event packet
    ack_received = Signal(dict)            # Command ACK packet
    connection_changed = Signal(bool, str) # (is_connected, host_port_string)

    def __init__(self, parent: Optional[QObject] = None):
        super().__init__(parent)
        self._connected: bool = False
        self._last_rx_time: float = 0.0

        # Race Session State
        self.session_time: float = 0.0
        self.current_lap: int = 0
        self.total_laps: int = 0
        self.cars_count: int = 0
        self.is_safety_car: bool = False
        self.is_fcy: bool = False
        self.track_temp: float = 25.0
        self.ambient_temp: float = 20.0
        self.track_grip: float = 1.0
        self.rain_intensity: float = 0.0
        self.water_depth: float = 0.0

        # Cars State indexed by car_id (0 .. N-1)
        self.cars: Dict[int, Dict[str, Any]] = {}

        # Log of recent discrete events
        self.recent_events: List[Dict[str, Any]] = []

        # Command sequence tracking
        self.pending_commands: Dict[int, Dict[str, Any]] = {}

    def set_connected(self, connected: bool, endpoint_info: str = "") -> None:
        if self._connected != connected:
            self._connected = connected
            self.connection_changed.emit(connected, endpoint_info)

    def is_connected(self) -> bool:
        # Auto-timeout after 2.5 seconds of silence
        if self._connected and (time.time() - self._last_rx_time > 2.5):
            self._connected = False
            self.connection_changed.emit(False, "Connection Timed Out")
        return self._connected

    def process_incoming_packet(self, packet: Dict[str, Any]) -> None:
        """Entry point for incoming wire packet."""
        self._last_rx_time = time.time()
        self.set_connected(True, "UDP Active")

        pkt_type = packet.get("y")
        if pkt_type == "T":
            self._update_telemetry(packet)
        elif pkt_type == "E":
            self._update_event(packet)
        elif pkt_type == "A":
            self._update_ack(packet)

    def _update_telemetry(self, pkt: Dict[str, Any]) -> None:
        # Simulation environment block 'e'
        env = pkt.get("e", {})
        self.session_time = env.get("t", self.session_time)
        self.current_lap = env.get("l", self.current_lap)
        self.total_laps = env.get("tl", self.total_laps)
        self.track_temp = env.get("tt", self.track_temp)
        self.ambient_temp = env.get("at", self.ambient_temp)
        self.track_grip = env.get("tg", self.track_grip)
        self.rain_intensity = env.get("rn", self.rain_intensity)
        self.water_depth = env.get("wd", self.water_depth)

        env_flags = env.get("f", 0)
        self.is_safety_car = bool(env_flags & 2)
        self.is_fcy = bool(env_flags & 4)

        # Vehicle array 'c'
        cars_data = pkt.get("c", [])
        self.cars_count = len(cars_data)

        for c_raw in cars_data:
            idx = c_raw.get("i", 0)
            flags = ProtocolCodec.parse_car_flags(c_raw.get("f", 0))

            car_dict = {
                "car_index": idx,
                "driver_name": c_raw.get("n", f"Car #{idx}"),
                "position": c_raw.get("p", idx + 1),
                "spline_position": c_raw.get("s", 0.0),
                "speed_kmh": c_raw.get("v", 0.0),
                "current_lap": c_raw.get("l", 0),
                "last_lap_ms": c_raw.get("ll", 0),
                "best_lap_ms": c_raw.get("bl", 0),
                "sector1_ms": c_raw.get("s1", 0),
                "sector2_ms": c_raw.get("s2", 0),
                "sector3_ms": c_raw.get("s3", 0),
                "gap_to_leader": c_raw.get("gl", 0.0),
                "interval_ahead": c_raw.get("ia", 0.0),
                "tyre_compound": c_raw.get("tc", "M"),
                "tyre_age_laps": c_raw.get("ta", 0),
                "tyre_wear": c_raw.get("w", [0.0, 0.0, 0.0, 0.0]),
                "tyre_temps_core": c_raw.get("tt", [85.0, 85.0, 85.0, 85.0]),
                "tyre_temps_surface": c_raw.get("ts", [90.0, 90.0, 90.0, 90.0]),
                "fuel_remaining": c_raw.get("fr", 50.0),
                "fuel_per_lap": c_raw.get("fl", 2.2),
                "fuel_laps_left": c_raw.get("fl_left", 20.0),
                "ers_charge": c_raw.get("ec", 100.0),
                "ers_mode": c_raw.get("em", 0),
                "pit_stops": c_raw.get("ps", 0),
                "flags": flags,
                "in_pitlane": flags["in_pitlane"],
                "in_pitbox": flags["in_pitbox"],
                "is_ai": flags["is_ai"],
                "is_retired": flags["is_retired"],
                "radio_command": c_raw.get("rc", "NONE"),
                "active_skill": c_raw.get("sk", "NONE"),
                "stress": c_raw.get("st", 0.0),
                "momentum": c_raw.get("mo", 0.0),
            }

            self.cars[idx] = car_dict
            self.car_updated.emit(idx, car_dict)

        self.telemetry_updated.emit(pkt)

    def _update_event(self, pkt: Dict[str, Any]) -> None:
        self.recent_events.append(pkt)
        if len(self.recent_events) > 200:
            self.recent_events.pop(0)
        self.event_received.emit(pkt)

    def _update_ack(self, pkt: Dict[str, Any]) -> None:
        cmd_id = pkt.get("id")
        if cmd_id in self.pending_commands:
            del self.pending_commands[cmd_id]
        self.ack_received.emit(pkt)
