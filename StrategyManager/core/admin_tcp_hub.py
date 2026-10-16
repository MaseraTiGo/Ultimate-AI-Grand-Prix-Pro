"""
StrategyManager Admin-to-User TCP Hub & ACL Validator
=====================================================
Hosts the central state server for PySide6 User clients:
- Manages User client connections and authentications
- Manages Driver draft / Claiming roster
- Enforces Roster Freeze / Parc Ferme lifecycle
- Applies Server-Side Fog of War filtering per connected user
- Validates strategy commands with Server-Side ACL
- Forwards validated commands to Lua UDP
"""

import socket
import threading
import json
import time
from typing import Dict, Any, Set, Optional, List
from PySide6.QtCore import QObject, Signal
from StrategyManager.core.protocol import (
    ProtocolCodec,
    STATE_LOBBY_OPEN,
    STATE_ROSTER_FROZEN,
    STATE_RACE_ACTIVE
)
from StrategyManager.core.state_store import StateStore
from StrategyManager.core.ipc_gateway import IPCGateway


class AdminTCPHub(QObject):
    """
    Central TCP Hub hosted by FIA Admin (admin_main.py).
    Serves connected User clients (user_main.py).
    """
    client_connected = Signal(str, str)     # client_id, address
    client_disconnected = Signal(str)       # client_id
    roster_changed = Signal(dict)            # current roster claim mapping
    lifecycle_state_changed = Signal(str)    # new lifecycle state
    log_message = Signal(str, str)          # level, text

    def __init__(self, state_store: StateStore, ipc_gateway: IPCGateway, host: str = "0.0.0.0", port: int = 30890, parent: Optional[QObject] = None):
        super().__init__(parent)
        self.state_store = state_store
        self.ipc_gateway = ipc_gateway
        self.host = host
        self.port = port

        self._running = False
        self._server_socket: Optional[socket.socket] = None
        self._listen_thread: Optional[threading.Thread] = None

        # Lifecycle State: LOBBY_OPEN -> ROSTER_FROZEN -> RACE_ACTIVE
        self.lifecycle_state = STATE_LOBBY_OPEN

        # Client registry: client_id -> {"socket": socket, "addr": addr, "bound_cars": set()}
        self._clients: Dict[str, Dict[str, Any]] = {}
        self._lock = threading.RLock()

        # Connect state store signals to push updates to User clients
        self.state_store.telemetry_updated.connect(self._on_telemetry_updated)
        self.state_store.event_received.connect(self._on_event_received)
        self.state_store.ack_received.connect(self._on_ack_received)

    def start(self) -> bool:
        if self._running:
            return True
        try:
            self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._server_socket.bind((self.host, self.port))
            self._server_socket.listen(10)
            self._server_socket.settimeout(0.5)

            self._running = True
            self._listen_thread = threading.Thread(target=self._accept_loop, daemon=True, name="AdminTCP_Accept")
            self._listen_thread.start()

            self.log_message.emit("INFO", f"Admin TCP Hub listening on {self.host}:{self.port}")
            return True
        except Exception as e:
            self.log_message.emit("ERROR", f"Failed starting Admin TCP Hub: {str(e)}")
            return False

    def stop(self) -> None:
        self._running = False
        if self._server_socket:
            try:
                self._server_socket.close()
            except Exception:
                pass
            self._server_socket = None

        with self._lock:
            for cid, cinfo in list(self._clients.items()):
                try:
                    cinfo["socket"].close()
                except Exception:
                    pass
            self._clients.clear()

        self.log_message.emit("INFO", "Admin TCP Hub stopped.")

    def set_lifecycle_state(self, new_state: str) -> None:
        """Transitions Parc Ferme state and broadcasts to all connected Users."""
        self.lifecycle_state = new_state
        self.lifecycle_state_changed.emit(new_state)
        self._broadcast_all({
            "y": "LIFECYCLE_SYNC",
            "state": new_state,
            "timestamp": time.time()
        })
        self.log_message.emit("INFO", f"Race Lifecycle State changed to: {new_state}")

    def freeze_roster(self) -> None:
        self.set_lifecycle_state(STATE_ROSTER_FROZEN)

    def open_lobby(self) -> None:
        self.set_lifecycle_state(STATE_LOBBY_OPEN)

    def start_race(self) -> None:
        self.set_lifecycle_state(STATE_RACE_ACTIVE)

    def get_claimed_cars_map(self) -> Dict[int, str]:
        """Returns map of car_idx -> client_id."""
        with self._lock:
            claimed = {}
            for cid, cinfo in self._clients.items():
                for car_idx in cinfo["bound_cars"]:
                    claimed[car_idx] = cid
            return claimed

    def _accept_loop(self) -> None:
        while self._running and self._server_socket:
            try:
                client_sock, addr = self._server_socket.accept()
                client_sock.settimeout(None)
                cid = f"User_{addr[0]}:{addr[1]}"
                with self._lock:
                    self._clients[cid] = {
                        "socket": client_sock,
                        "addr": addr,
                        "bound_cars": set(),
                        "rx_buf": ""
                    }
                self.client_connected.emit(cid, f"{addr[0]}:{addr[1]}")
                self.log_message.emit("INFO", f"Client connected: {cid}")

                # Send initial handshake with current lifecycle state and roster
                handshake = {
                    "y": "HANDSHAKE",
                    "client_id": cid,
                    "lifecycle": self.lifecycle_state,
                    "roster": self.get_claimed_cars_map()
                }
                self._send_to_client(client_sock, handshake)

                # Spawn worker thread for client
                cthread = threading.Thread(target=self._client_worker, args=(cid, client_sock), daemon=True)
                cthread.start()
            except socket.timeout:
                continue
            except Exception as e:
                if self._running:
                    self.log_message.emit("WARN", f"TCP accept error: {str(e)}")
                time.sleep(0.05)

    def _client_worker(self, cid: str, sock: socket.socket) -> None:
        buf = ""
        while self._running:
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk.decode('utf-8', errors='ignore')
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    line = line.strip()
                    if line:
                        pkt = ProtocolCodec.decode(line.encode('utf-8'))
                        if pkt:
                            self._handle_client_packet(cid, pkt)
            except Exception:
                break

        # Cleanup disconnected client
        with self._lock:
            if cid in self._clients:
                del self._clients[cid]
        self.client_disconnected.emit(cid)
        self.roster_changed.emit(self.get_claimed_cars_map())
        self.log_message.emit("INFO", f"Client disconnected: {cid}")

    def _handle_client_packet(self, cid: str, pkt: Dict[str, Any]) -> None:
        pkt_type = pkt.get("y")

        # 1. Driver Claim / Bind Request
        if pkt_type == "CLAIM_DRIVER":
            car_idx = pkt.get("c", -1)
            action = pkt.get("a", "BIND")  # "BIND" or "UNBIND"

            if self.lifecycle_state != STATE_LOBBY_OPEN:
                self._send_to_client_id(cid, {
                    "y": "CLAIM_REJECTED",
                    "c": car_idx,
                    "reason": f"Roster is locked ({self.lifecycle_state}). Parc Ferme active."
                })
                return

            with self._lock:
                cinfo = self._clients.get(cid)
                if not cinfo:
                    return

                claimed_map = self.get_claimed_cars_map()
                if action == "BIND":
                    # Check if already claimed by someone else
                    existing_owner = claimed_map.get(car_idx)
                    if existing_owner and existing_owner != cid:
                        self._send_to_client_id(cid, {
                            "y": "CLAIM_REJECTED",
                            "c": car_idx,
                            "reason": f"Driver #{car_idx} is already claimed by {existing_owner}"
                        })
                        return
                    cinfo["bound_cars"].add(car_idx)
                    self.log_message.emit("INFO", f"Client {cid} bound Car #{car_idx}")
                elif action == "UNBIND":
                    cinfo["bound_cars"].discard(car_idx)
                    self.log_message.emit("INFO", f"Client {cid} unbound Car #{car_idx}")

            # Broadcast updated roster to all Users
            roster_sync = {
                "y": "ROSTER_SYNC",
                "roster": self.get_claimed_cars_map()
            }
            self._broadcast_all(roster_sync)
            self.roster_changed.emit(self.get_claimed_cars_map())

        # 2. Strategy Command Dispatch (ACL Gated)
        elif pkt_type == "COMMAND":
            car_idx = pkt.get("c", -1)
            cmd_action = pkt.get("a", "")
            cmd_id = pkt.get("id", 0)
            params = pkt.get("p", {})

            # Server-Side ACL Check
            with self._lock:
                cinfo = self._clients.get(cid)
                is_authorized = cinfo and (car_idx in cinfo["bound_cars"])

            if not is_authorized:
                self._send_to_client_id(cid, {
                    "y": "A",
                    "id": cmd_id,
                    "s": "ACL_DENIED",
                    "m": f"Unauthorized: Car #{car_idx} is not in your bound roster."
                })
                self.log_message.emit("WARN", f"ACL DENIED for {cid}: attempted command {cmd_action} on Car #{car_idx}")
                return

            # Authorized! Forward command to Lua via IPCGateway
            forward_id = self.ipc_gateway.send_command(cmd_action, car_idx, params)
            self.log_message.emit("INFO", f"ACL PASSED: {cid} -> Forwarded CMD [{forward_id}] {cmd_action} on Car #{car_idx}")

    def _on_telemetry_updated(self, raw_telemetry: Dict[str, Any]) -> None:
        """Pushes Fog-of-War masked telemetry to each client according to bound cars."""
        with self._lock:
            for cid, cinfo in list(self._clients.items()):
                bound_set = cinfo["bound_cars"]
                masked_packet = ProtocolCodec.apply_fog_of_war(raw_telemetry, bound_set)
                self._send_to_client(cinfo["socket"], masked_packet)

    def _on_event_received(self, evt: Dict[str, Any]) -> None:
        """Broadcasts discrete events to all clients."""
        self._broadcast_all(evt)

    def _on_ack_received(self, ack: Dict[str, Any]) -> None:
        """Broadcasts execution acks to all clients."""
        self._broadcast_all(ack)

    def _send_to_client(self, sock: socket.socket, data: Dict[str, Any]) -> None:
        try:
            line = ProtocolCodec.encode(data) + b"\n"
            sock.sendall(line)
        except Exception:
            pass

    def _send_to_client_id(self, cid: str, data: Dict[str, Any]) -> None:
        with self._lock:
            cinfo = self._clients.get(cid)
            if cinfo:
                self._send_to_client(cinfo["socket"], data)

    def _broadcast_all(self, data: Dict[str, Any]) -> None:
        with self._lock:
            for cid, cinfo in list(self._clients.items()):
                self._send_to_client(cinfo["socket"], data)
