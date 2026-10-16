"""
StrategyManager User TCP Client
===============================
Connects to Admin TCP Hub from User application (user_main.py).
Receives Fog-of-War filtered telemetry and dispatches authorized team commands.
"""

import socket
import threading
import json
import time
from typing import Dict, Any, Set, Optional, List
from PySide6.QtCore import QObject, Signal
from StrategyManager.core.protocol import ProtocolCodec, STATE_LOBBY_OPEN


class UserTCPClient(QObject):
    """
    Client connection object for Team Principal Pit Wall.
    Communicates exclusively with Admin TCP Hub.
    """
    connection_changed = Signal(bool, str)     # is_connected, status_message
    telemetry_received = Signal(dict)          # Fog-of-war filtered telemetry
    event_received = Signal(dict)              # Race discrete events
    ack_received = Signal(dict)                # Command acks
    roster_synced = Signal(dict)               # Full roster claim mapping
    lifecycle_synced = Signal(str)             # LOBBY_OPEN / ROSTER_FROZEN / RACE_ACTIVE
    claim_rejected = Signal(int, str)          # car_idx, reason
    log_message = Signal(str, str)             # level, text

    def __init__(self, host: str = "127.0.0.1", port: int = 30890, parent: Optional[QObject] = None):
        super().__init__(parent)
        self.host = host
        self.port = port

        self._running = False
        self._socket: Optional[socket.socket] = None
        self._rx_thread: Optional[threading.Thread] = None

        self.client_id: str = ""
        self.lifecycle_state: str = STATE_LOBBY_OPEN
        self.bound_cars: Set[int] = set()
        self.roster_map: Dict[int, str] = {}
        self._cmd_counter = 5000

    def connect_to_admin(self) -> bool:
        if self._running:
            return True
        try:
            self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._socket.connect((self.host, self.port))
            self._running = True

            self._rx_thread = threading.Thread(target=self._rx_worker, daemon=True, name="UserTCP_RX")
            self._rx_thread.start()

            self.connection_changed.emit(True, f"Connected to Admin Hub at {self.host}:{self.port}")
            self.log_message.emit("INFO", f"Connected to Admin Hub at {self.host}:{self.port}")
            return True
        except Exception as e:
            self.connection_changed.emit(False, f"Connection failed: {str(e)}")
            self.log_message.emit("ERROR", f"Connection error: {str(e)}")
            self.disconnect_from_admin()
            return False

    def disconnect_from_admin(self) -> None:
        self._running = False
        if self._socket:
            try:
                self._socket.close()
            except Exception:
                pass
            self._socket = None
        self.connection_changed.emit(False, "Disconnected")

    def claim_driver(self, car_idx: int) -> None:
        """Request to bind driver to my roster."""
        self._send_packet({
            "y": "CLAIM_DRIVER",
            "a": "BIND",
            "c": car_idx
        })

    def unclaim_driver(self, car_idx: int) -> None:
        """Request to release driver from my roster."""
        self._send_packet({
            "y": "CLAIM_DRIVER",
            "a": "UNBIND",
            "c": car_idx
        })

    def send_team_command(self, action: str, car_idx: int, params: Optional[Dict[str, Any]] = None) -> int:
        """Send strategy command for bound driver."""
        self._cmd_counter += 1
        cmd_id = self._cmd_counter
        self._send_packet({
            "y": "COMMAND",
            "id": cmd_id,
            "a": action,
            "c": car_idx,
            "p": params or {}
        })
        return cmd_id

    def _send_packet(self, data: Dict[str, Any]) -> None:
        if not self._running or not self._socket:
            return
        try:
            line = ProtocolCodec.encode(data) + b"\n"
            self._socket.sendall(line)
        except Exception as e:
            self.log_message.emit("ERROR", f"Failed sending packet: {str(e)}")

    def _rx_worker(self) -> None:
        buf = ""
        while self._running and self._socket:
            try:
                chunk = self._socket.recv(4096)
                if not chunk:
                    break
                buf += chunk.decode('utf-8', errors='ignore')
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    line = line.strip()
                    if line:
                        pkt = ProtocolCodec.decode(line.encode('utf-8'))
                        if pkt:
                            self._handle_incoming_packet(pkt)
            except Exception:
                break

        self.disconnect_from_admin()

    def _handle_incoming_packet(self, pkt: Dict[str, Any]) -> None:
        pkt_type = pkt.get("y")

        if pkt_type == "HANDSHAKE":
            self.client_id = pkt.get("client_id", "")
            self.lifecycle_state = pkt.get("lifecycle", STATE_LOBBY_OPEN)
            self.roster_map = {int(k): v for k, v in pkt.get("roster", {}).items()}
            self._update_bound_cars()
            self.lifecycle_synced.emit(self.lifecycle_state)
            self.roster_synced.emit(self.roster_map)
            self.log_message.emit("INFO", f"Handshake confirmed. ID: {self.client_id}, Lifecycle: {self.lifecycle_state}")

        elif pkt_type == "LIFECYCLE_SYNC":
            self.lifecycle_state = pkt.get("state", STATE_LOBBY_OPEN)
            self.lifecycle_synced.emit(self.lifecycle_state)
            self.log_message.emit("INFO", f"Lifecycle updated: {self.lifecycle_state}")

        elif pkt_type == "ROSTER_SYNC":
            self.roster_map = {int(k): v for k, v in pkt.get("roster", {}).items()}
            self._update_bound_cars()
            self.roster_synced.emit(self.roster_map)

        elif pkt_type == "CLAIM_REJECTED":
            car_idx = pkt.get("c", -1)
            reason = pkt.get("reason", "Rejected")
            self.claim_rejected.emit(car_idx, reason)
            self.log_message.emit("WARN", f"Claim rejected for Car #{car_idx}: {reason}")

        elif pkt_type == "T_USER":
            self.telemetry_received.emit(pkt)

        elif pkt_type == "E":
            self.event_received.emit(pkt)

        elif pkt_type == "A":
            self.ack_received.emit(pkt)

    def _update_bound_cars(self) -> None:
        self.bound_cars.clear()
        for c_idx, owner in self.roster_map.items():
            if owner == self.client_id:
                self.bound_cars.add(c_idx)
