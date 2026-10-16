"""
StrategyManager IPC Gateway
===========================
High-performance asynchronous UDP server/client and command dispatcher.
Communicates bi-directionally with Assetto Corsa CSP Lua script.
"""

from typing import Optional, Dict, Any
import socket
import threading
import time
from PySide6.QtCore import QObject, Signal
from StrategyManager.core.protocol import ProtocolCodec, PROTOCOL_VERSION
from StrategyManager.core.state_store import StateStore


class IPCGateway(QObject):
    """
    Bi-directional UDP IPC Gateway.
    - Listens on `rx_port` (default: 30888) for Lua telemetry & events.
    - Sends to `tx_host:tx_port` (default: 127.0.0.1:30889) for Lua command execution.
    """
    log_message = Signal(str, str) # level, message

    def __init__(self, state_store: StateStore, rx_port: int = 30888, tx_host: str = "127.0.0.1", tx_port: int = 30889, parent: Optional[QObject] = None):
        super().__init__(parent)
        self.state_store = state_store
        self.rx_port = rx_port
        self.tx_host = tx_host
        self.tx_port = tx_port

        self._running = False
        self._rx_socket: Optional[socket.socket] = None
        self._tx_socket: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._cmd_counter = 1000

    def start(self) -> bool:
        if self._running:
            return True

        try:
            self._rx_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._rx_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._rx_socket.bind(("0.0.0.0", self.rx_port))
            self._rx_socket.settimeout(0.5)

            self._tx_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

            self._running = True
            self._thread = threading.Thread(target=self._rx_worker, daemon=True, name="IPC_UDP_Worker")
            self._thread.start()

            self.log_message.emit("INFO", f"IPC Gateway listening on UDP 0.0.0.0:{self.rx_port}, target {self.tx_host}:{self.tx_port}")
            return True
        except Exception as e:
            self.log_message.emit("ERROR", f"Failed to start IPC Gateway: {str(e)}")
            self.stop()
            return False

    def stop(self) -> None:
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
            self._thread = None

        if self._rx_socket:
            try:
                self._rx_socket.close()
            except Exception:
                pass
            self._rx_socket = None

        if self._tx_socket:
            try:
                self._tx_socket.close()
            except Exception:
                pass
            self._tx_socket = None

        self.state_store.set_connected(False, "Stopped")
        self.log_message.emit("INFO", "IPC Gateway stopped.")

    def _rx_worker(self) -> None:
        while self._running and self._rx_socket:
            try:
                data, addr = self._rx_socket.recvfrom(65535)
                if not data:
                    continue

                packet = ProtocolCodec.decode(data)
                if packet:
                    self.state_store.process_incoming_packet(packet)
            except socket.timeout:
                self.state_store.is_connected() # triggers timeout check
                continue
            except Exception as e:
                if self._running:
                    self.log_message.emit("WARN", f"UDP RX error: {str(e)}")
                time.sleep(0.01)

    def send_command(self, action: str, car_idx: int = -1, params: Optional[Dict[str, Any]] = None) -> int:
        """
        Send command to Lua script.
        Returns command_id for ACK tracking.
        """
        self._cmd_counter += 1
        cmd_id = self._cmd_counter
        cmd_pkt = ProtocolCodec.create_command(cmd_id, action, car_idx, params)

        self.state_store.pending_commands[cmd_id] = {
            "timestamp": time.time(),
            "packet": cmd_pkt
        }

        try:
            raw = ProtocolCodec.encode(cmd_pkt)
            if self._tx_socket:
                self._tx_socket.sendto(raw, (self.tx_host, self.tx_port))
                self.log_message.emit("DEBUG", f"Sent CMD [{cmd_id}] {action} -> Car {car_idx}")
        except Exception as e:
            self.log_message.emit("ERROR", f"Failed to send command [{cmd_id}]: {str(e)}")

        return cmd_id

    # Shortcut Helpers
    def dispatch_box_this_lap(self, car_idx: int, compound: str = "", tyre_pressures: Optional[list] = None) -> int:
        return self.send_command("BOX", car_idx, {"tc": compound, "tp": tyre_pressures or []})

    def dispatch_cancel_box(self, car_idx: int) -> int:
        return self.send_command("CANCEL_BOX", car_idx)

    def dispatch_radio(self, car_idx: int, command: str) -> int:
        return self.send_command("RADIO", car_idx, {"cmd": command})

    def dispatch_broadcast_toggle(self, enabled: bool) -> int:
        return self.send_command("BROADCAST_TOGGLE", -1, {"enable": enabled})

    def dispatch_persona_override(self, car_idx: int, persona_data: Dict[str, Any]) -> int:
        return self.send_command("PERSONA", car_idx, persona_data)

    def dispatch_setup_override(self, car_idx: int, setup_data: Dict[str, Any]) -> int:
        return self.send_command("SETUP", car_idx, setup_data)
