"""
StrategyManager Team Principal Pit Wall Client (user_main.py)
============================================================
Team Principal Desktop Application:
- Connects exclusively to Admin TCP Hub (30890)
- Interactive Pre-Race Driver Draft / Claiming Lobby (LOBBY_OPEN)
- Automatic transition and UI lock upon Admin Parc Ferme freeze (ROSTER_FROZEN)
- Enforces Fog of War on rival cars (wear, temps, exact fuel hidden)
- Full deep strategy workbench, Undercut Radar, and Radio Command Dispatch for bound cars ONLY
"""

import sys
import os
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QTabWidget, QTextEdit, QSplitter, QStatusBar, QMessageBox
)
from StrategyManager.core import UserTCPClient, STATE_LOBBY_OPEN, STATE_ROSTER_FROZEN, STATE_RACE_ACTIVE
from StrategyManager.strategy_ai import StrategySimulator, PitStopLossCalculator
from StrategyManager.ui import (
    PITWALL_STYLE, TrackMapWidget, TimingTowerWidget, StintPlannerPanel,
    CommandDispatchWidget, DriverDraftLobbyDrawer
)


class UserMainWindow(QMainWindow):
    """Team Principal Pit Wall Application Window."""

    def __init__(self, admin_host: str = "127.0.0.1", admin_port: int = 30890):
        super().__init__()
        self.setWindowTitle("Ultimate AI Grand Prix Pro — Team Principal Pit Wall (User)")
        self.resize(1380, 880)
        self.setStyleSheet(PITWALL_STYLE)

        # 1. Setup TCP Client
        self.tcp_client = UserTCPClient(admin_host, admin_port, parent=self)

        # 2. Setup Central Layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(10, 10, 10, 10)

        # Top Bar
        main_layout.addLayout(self._create_top_bar())

        # Main Tabs: 1. Team Pit Wall, 2. Pre-Race Driver Draft Lobby, 3. Radio Logs
        self.main_tabs = QTabWidget()

        # Tab 1: Pit Wall Workbench
        pitwall_widget = QWidget()
        pw_layout = QHBoxLayout(pitwall_widget)
        pw_layout.setContentsMargins(0, 0, 0, 0)

        splitter = QSplitter(Qt.Horizontal)

        # Timing Tower (Fog-of-War filtered)
        self.timing_tower = TimingTowerWidget()
        self.timing_tower.car_selected.connect(self._on_car_selected)
        splitter.addWidget(self.timing_tower)

        # Center: Track Map + Stint Planner
        center_box = QWidget()
        center_layout = QVBoxLayout(center_box)
        center_layout.setContentsMargins(0, 0, 0, 0)

        self.track_map = TrackMapWidget()
        center_layout.addWidget(self.track_map, 2)

        self.stint_planner = StintPlannerPanel()
        center_layout.addWidget(self.stint_planner, 1)
        splitter.addWidget(center_box)

        # Right: Bound Team Strategy Dispatch Console
        self.cmd_dispatch = CommandDispatchWidget()
        self.cmd_dispatch.command_triggered.connect(self._on_user_command)
        splitter.addWidget(self.cmd_dispatch)

        splitter.setStretchFactor(0, 4)
        splitter.setStretchFactor(1, 4)
        splitter.setStretchFactor(2, 3)

        pw_layout.addWidget(splitter)
        self.main_tabs.addTab(pitwall_widget, "TEAM PIT WALL")

        # Tab 2: Pre-Race Driver Draft Lobby
        self.draft_lobby = DriverDraftLobbyDrawer()
        self.draft_lobby.claim_requested.connect(self.tcp_client.claim_driver)
        self.draft_lobby.unclaim_requested.connect(self.tcp_client.unclaim_driver)
        self.main_tabs.addTab(self.draft_lobby, "DRIVER DRAFT & ROSTER")

        # Tab 3: Radio Log Console
        self.log_console = QTextEdit()
        self.log_console.setReadOnly(True)
        self.main_tabs.addTab(self.log_console, "TEAM RADIO LOGS")

        main_layout.addWidget(self.main_tabs)

        # Status Bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Connecting to Admin Hub...")

        # 3. Connect Client Signals
        self.tcp_client.connection_changed.connect(self._on_connection_changed)
        self.tcp_client.lifecycle_synced.connect(self._on_lifecycle_synced)
        self.tcp_client.roster_synced.connect(self._on_roster_synced)
        self.tcp_client.telemetry_received.connect(self._on_telemetry_received)
        self.tcp_client.event_received.connect(self._on_event_received)
        self.tcp_client.ack_received.connect(self._on_ack_received)
        self.tcp_client.claim_rejected.connect(self._on_claim_rejected)
        self.tcp_client.log_message.connect(self._log)

        # Auto-connect
        self.tcp_client.connect_to_admin()

    def _create_top_bar(self) -> QHBoxLayout:
        bar = QHBoxLayout()

        self.lbl_team = QLabel("TEAM PRINCIPAL PIT WALL")
        self.lbl_team.setStyleSheet("color: #00E5FF; font-weight: bold; font-size: 14px;")
        bar.addWidget(self.lbl_team)

        bar.addSpacing(20)

        self.lbl_conn = QLabel("STATUS: CONNECTING...")
        self.lbl_conn.setStyleSheet("color: #ED8936; font-weight: bold;")
        bar.addWidget(self.lbl_conn)

        bar.addSpacing(20)

        self.lbl_roster = QLabel("BOUND CARS: NONE (Open Draft Lobby to Bind)")
        self.lbl_roster.setStyleSheet("color: #ECC94B; font-weight: bold;")
        bar.addWidget(self.lbl_roster)

        bar.addStretch()

        self.lbl_session = QLabel("SESSION: RACE | FOG OF WAR: ACTIVE")
        self.lbl_session.setStyleSheet("color: #A0AEC0; font-family: 'Consolas';")
        bar.addWidget(self.lbl_session)

        return bar

    def _on_connection_changed(self, is_connected: bool, msg: str) -> None:
        if is_connected:
            self.lbl_conn.setText("STATUS: CONNECTED TO FIA ADMIN")
            self.lbl_conn.setStyleSheet("color: #48BB78; font-weight: bold;")
        else:
            self.lbl_conn.setText(f"STATUS: {msg}")
            self.lbl_conn.setStyleSheet("color: #E53E3E; font-weight: bold;")
        self.status_bar.showMessage(msg)

    def _on_lifecycle_synced(self, state: str) -> None:
        self.draft_lobby.set_lifecycle_state(state)
        if state == STATE_ROSTER_FROZEN:
            self.main_tabs.setCurrentIndex(0) # Automatically switch to Pit Wall view
            self.status_bar.showMessage("PARC FERME ACTIVE: Rosters locked by FIA Admin. Race strategy engaged.")

    def _on_roster_synced(self, roster_map: dict) -> None:
        self.draft_lobby.update_roster(self.tcp_client.client_id, roster_map, self.timing_tower.table.property("raw_cars") or [])
        bound = list(self.tcp_client.bound_cars)
        if bound:
            self.lbl_roster.setText(f"BOUND CARS: {bound}")
            self.lbl_roster.setStyleSheet("color: #00E5FF; font-weight: bold;")
        else:
            self.lbl_roster.setText("BOUND CARS: NONE (Open Draft Lobby to Bind)")
            self.lbl_roster.setStyleSheet("color: #ECC94B; font-weight: bold;")

    def _on_claim_rejected(self, car_idx: int, reason: str) -> None:
        QMessageBox.warning(self, "Claim Rejected", f"Could not bind Car #{car_idx}:\n{reason}")

    def _on_telemetry_received(self, pkt: dict) -> None:
        cars = pkt.get("c", [])
        env = pkt.get("e", {})

        self.timing_tower.table.setProperty("raw_cars", cars)
        self.timing_tower.update_grid(cars)
        self.draft_lobby.refresh_table()

        # Update Dispatcher filter (only show bound cars if claimed, or all if in open lobby)
        bound_set = self.tcp_client.bound_cars
        target_cars = [c for c in cars if (c.get("i", 0) in bound_set)] if bound_set else cars
        self.cmd_dispatch.update_car_list(target_cars)

        # Update Gantt & Track Map
        cur_lap = env.get("l", 0)
        tot_laps = env.get("tl", 0)
        self.stint_planner.gantt.set_plan(self.stint_planner.gantt.active_plan, tot_laps, cur_lap)

        sel_idx = self.cmd_dispatch.get_selected_car_idx()
        self.track_map.update_telemetry(cars, sel_idx)

    def _on_car_selected(self, car_idx: int) -> None:
        self.cmd_dispatch.select_car(car_idx)

    def _on_user_command(self, action: str, car_idx: int, params: dict) -> None:
        if self.tcp_client.bound_cars and (car_idx not in self.tcp_client.bound_cars):
            QMessageBox.warning(self, "Unauthorized", f"Car #{car_idx} is not in your bound team roster!")
            return
        cmd_id = self.tcp_client.send_team_command(action, car_idx, params)
        self._log("CMD", f"Dispatched Team Command [{cmd_id}] {action} on Car #{car_idx}")

    def _on_event_received(self, evt: dict) -> None:
        self._log("EVENT", f"[{evt.get('e')}] Car #{evt.get('c')} | {evt.get('d')}")

    def _on_ack_received(self, ack: dict) -> None:
        status = ack.get("s")
        msg = ack.get("m")
        if status == "ACL_DENIED":
            self._log("DENIED", f"FIA Server ACL Rejected: {msg}")
            QMessageBox.critical(self, "FIA Server ACL Denied", msg)
        else:
            self._log("ACK", f"Cmd #{ack.get('id')} -> {status}: {msg}")

    def _log(self, level: str, text: str) -> None:
        self.log_console.append(f"[{level}] {text}")

    def closeEvent(self, event) -> None:
        self.tcp_client.disconnect_from_admin()
        event.accept()


def main():
    app = QApplication(sys.argv)
    window = UserMainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
