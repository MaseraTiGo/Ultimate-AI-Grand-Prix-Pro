"""
StrategyManager Team Principal Pit Wall Client (user_main.py)
============================================================
Team Principal Desktop Application matching target HUD:
- Top bar with TEAM PRINCIPAL PIT WALL badge, LED connection status dot, Bound Cars indicator, Fog of War badge
- Top Tabs: TEAM PIT WALL | DRIVER DRAFT ROSTER | TEAM RADIO LOGS
- Inside Tab 1 (Team Pit Wall):
  - Left: Pro Leaderboard (with Fog of War masking for rival cars)
  - Center: Circuit Radar visualizer + Stint Planner Gantt chart
  - Right: Bound team tactical radio dispatch console
- Inside Tab 2: Pre-race driver draft claiming lobby
- Inside Tab 3: Team radio logs console
- Bottom cyber telemetry bar (LOAD MGG, Connection status)
"""

import sys
import os
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QTabWidget, QTextEdit, QSplitter, QStatusBar, QMessageBox, QProgressBar
)
from StrategyManager.core import (
    UserTCPClient, STATE_LOBBY_OPEN, STATE_ROSTER_FROZEN, STATE_RACE_ACTIVE
)
from StrategyManager.ui import (
    PITWALL_STYLE, TrackMapWidget, TimingTowerWidget, StintPlannerPanel,
    CommandDispatchWidget, DriverDraftLobbyDrawer
)


class UserMainWindow(QMainWindow):
    """Team Principal Pit Wall Application Window."""

    def __init__(self, admin_host: str = "127.0.0.1", admin_port: int = 30890):
        super().__init__()
        self.setWindowTitle("Ultimate AI Grand Prix Pro — Team Principal Pit Wall (User)")
        self.resize(1366, 768)
        self.setMinimumSize(1180, 680)
        self.setStyleSheet(PITWALL_STYLE)

        # 1. Setup TCP Client
        self.tcp_client = UserTCPClient(admin_host, admin_port, parent=self)

        # 2. Setup Central Layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(10, 8, 10, 8)
        main_layout.setSpacing(8)

        # Top Bar
        main_layout.addLayout(self._create_top_bar())

        # Main Tabs: 1. TEAM PIT WALL, 2. DRIVER DRAFT ROSTER, 3. TEAM RADIO LOGS
        self.main_tabs = QTabWidget()

        # Tab 1: Pit Wall Workbench
        pitwall_widget = QWidget()
        pw_layout = QHBoxLayout(pitwall_widget)
        pw_layout.setContentsMargins(4, 4, 4, 4)

        splitter = QSplitter(Qt.Horizontal)
        splitter.setHandleWidth(4)

        # Left Column: Leaderboard
        self.timing_tower = TimingTowerWidget()
        self.timing_tower.car_selected.connect(self._on_car_selected)
        splitter.addWidget(self.timing_tower)

        # Center: Track Map + Stint Planner
        center_box = QWidget()
        center_layout = QVBoxLayout(center_box)
        center_layout.setContentsMargins(0, 0, 0, 0)
        center_layout.setSpacing(8)

        self.track_map = TrackMapWidget()
        center_layout.addWidget(self.track_map, 3)

        self.stint_planner = StintPlannerPanel()
        center_layout.addWidget(self.stint_planner, 2)
        splitter.addWidget(center_box)

        # Right: Bound Team Strategy Dispatch Console
        self.cmd_dispatch = CommandDispatchWidget()
        self.cmd_dispatch.command_triggered.connect(self._on_user_command)
        splitter.addWidget(self.cmd_dispatch)

        splitter.setStretchFactor(0, 5)
        splitter.setStretchFactor(1, 5)
        splitter.setStretchFactor(2, 4)

        pw_layout.addWidget(splitter)
        self.main_tabs.addTab(pitwall_widget, "TEAM PIT WALL")

        # Tab 2: Pre-Race Driver Draft Lobby
        self.draft_lobby = DriverDraftLobbyDrawer()
        self.draft_lobby.claim_requested.connect(self.tcp_client.claim_driver)
        self.draft_lobby.unclaim_requested.connect(self.tcp_client.unclaim_driver)
        self.main_tabs.addTab(self.draft_lobby, "DRIVER DRAFT ROSTER")

        # Tab 3: Radio Log Console
        self.log_console = QTextEdit()
        self.log_console.setReadOnly(True)
        self.main_tabs.addTab(self.log_console, "TEAM RADIO LOGS")

        main_layout.addWidget(self.main_tabs, 1)

        # Bottom Cyber Telemetry Strip
        main_layout.addLayout(self._create_bottom_strip())

        # Status Bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Connecting to FIA Admin Hub...")

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
        bar.setContentsMargins(4, 4, 4, 4)
        bar.setSpacing(12)

        # Team Principal Badge Box
        brand_box = QWidget()
        brand_layout = QHBoxLayout(brand_box)
        brand_layout.setContentsMargins(8, 4, 12, 4)
        brand_layout.setSpacing(8)
        brand_box.setStyleSheet("""
            background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #0F2338, stop:1 #0A131F);
            border: 1px solid #00E5FF;
            border-radius: 6px;
        """)

        lbl_logo = QLabel("🏎")
        lbl_logo.setStyleSheet("color: #00E5FF; font-size: 14px;")
        brand_layout.addWidget(lbl_logo)

        brand_text_box = QVBoxLayout()
        brand_text_box.setSpacing(0)
        lbl_brand = QLabel("TEAM PRINCIPAL")
        lbl_brand.setStyleSheet("color: #00E5FF; font-weight: 900; font-size: 11px; letter-spacing: 1px;")
        lbl_sub = QLabel("PIT WALL")
        lbl_sub.setStyleSheet("color: #FFFFFF; font-weight: 900; font-size: 13px; letter-spacing: 1px;")
        brand_text_box.addWidget(lbl_brand)
        brand_text_box.addWidget(lbl_sub)
        brand_layout.addLayout(brand_text_box)

        bar.addWidget(brand_box)

        # LED Connection Status Indicator
        self.lbl_led = QLabel("●")
        self.lbl_led.setStyleSheet("color: #E53E3E; font-size: 16px;")
        bar.addWidget(self.lbl_led)

        self.lbl_conn = QLabel("STATUS: Disconnected")
        self.lbl_conn.setStyleSheet("color: #ED8936; font-weight: bold; font-family: 'Consolas';")
        bar.addWidget(self.lbl_conn)

        bar.addSpacing(16)

        # Bound Cars Indicator
        self.lbl_roster = QLabel("BOUND CARS: NONE (Open Draft Lobby to Bind)")
        self.lbl_roster.setStyleSheet("color: #ECC94B; font-weight: bold; font-family: 'Consolas';")
        bar.addWidget(self.lbl_roster)

        bar.addStretch()

        # Session & Fog of War
        self.lbl_session = QLabel("SESSION: RACE | FOG OF WAR: ACTIVE ☁")
        self.lbl_session.setStyleSheet("color: #A0AEC0; font-family: 'Consolas'; font-size: 11px; font-weight: 700;")
        bar.addWidget(self.lbl_session)

        return bar

    def _create_bottom_strip(self) -> QHBoxLayout:
        bar = QHBoxLayout()
        bar.setContentsMargins(4, 2, 4, 2)
        bar.setSpacing(10)

        lbl_load = QLabel("LOAD MGG:")
        lbl_load.setStyleSheet("color: #718096; font-size: 9px; font-family: 'Consolas'; font-weight: bold;")
        bar.addWidget(lbl_load)

        self.bar_load = QProgressBar()
        self.bar_load.setFixedHeight(6)
        self.bar_load.setMaximumWidth(140)
        self.bar_load.setValue(35)
        self.bar_load.setTextVisible(False)
        self.bar_load.setStyleSheet("""
            QProgressBar {
                background-color: #0E131C;
                border: 1px solid #1C2636;
                border-radius: 3px;
            }
            QProgressBar::chunk {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #0088AA, stop:1 #00E5FF);
                border-radius: 2px;
            }
        """)
        bar.addWidget(self.bar_load)

        bar.addSpacing(20)

        self.lbl_bottom_status = QLabel("Disconnected")
        self.lbl_bottom_status.setStyleSheet("color: #718096; font-size: 10px; font-family: 'Consolas';")
        bar.addWidget(self.lbl_bottom_status)

        bar.addStretch()
        return bar

    def _on_connection_changed(self, is_connected: bool, msg: str) -> None:
        if is_connected:
            self.lbl_led.setStyleSheet("color: #00F59B; font-size: 16px;")
            self.lbl_conn.setText("STATUS: Connected")
            self.lbl_conn.setStyleSheet("color: #00F59B; font-weight: bold; font-family: 'Consolas';")
            self.lbl_bottom_status.setText("Connected to FIA Admin")
        else:
            self.lbl_led.setStyleSheet("color: #E53E3E; font-size: 16px;")
            self.lbl_conn.setText(f"STATUS: {msg}")
            self.lbl_conn.setStyleSheet("color: #E53E3E; font-weight: bold; font-family: 'Consolas';")
            self.lbl_bottom_status.setText(msg)
        self.status_bar.showMessage(msg)

    def _on_lifecycle_synced(self, state: str) -> None:
        self.draft_lobby.set_lifecycle_state(state)
        if state == STATE_ROSTER_FROZEN:
            self.main_tabs.setCurrentIndex(0)
            self.status_bar.showMessage("PARC FERME ACTIVE: Rosters locked by FIA Admin. Race strategy engaged.")

    def _on_roster_synced(self, roster_map: dict) -> None:
        self.draft_lobby.update_roster(self.tcp_client.client_id, roster_map, self.timing_tower.table.property("raw_cars") or [])
        bound = list(self.tcp_client.bound_cars)
        if bound:
            car_display = [f"#{c+1}" for c in bound]
            self.lbl_roster.setText(f"BOUND CARS: {', '.join(car_display)}")
            self.lbl_roster.setStyleSheet("color: #00E5FF; font-weight: bold; font-family: 'Consolas';")
        else:
            self.lbl_roster.setText("BOUND CARS: NONE (Open Draft Lobby to Bind)")
            self.lbl_roster.setStyleSheet("color: #ECC94B; font-weight: bold; font-family: 'Consolas';")

    def _on_claim_rejected(self, car_idx: int, reason: str) -> None:
        QMessageBox.warning(self, "Claim Rejected", f"Could not bind Car #{car_idx+1}:\n{reason}")

    def _on_telemetry_received(self, pkt: dict) -> None:
        cars = pkt.get("c", [])
        env = pkt.get("e", {})

        self.timing_tower.table.setProperty("raw_cars", cars)
        self.timing_tower.update_grid(cars)
        self.draft_lobby.refresh_table()

        bound_set = self.tcp_client.bound_cars
        target_cars = [c for c in cars if (c.get("i", 0) in bound_set)] if bound_set else cars
        self.cmd_dispatch.update_car_list(target_cars)

        cur_lap = env.get("l", 0)
        tot_laps = env.get("tl", 0)
        self.stint_planner.gantt.set_plan(self.stint_planner.gantt.active_plan, tot_laps, cur_lap)

        sel_idx = self.cmd_dispatch.get_selected_car_idx()
        self.track_map.update_telemetry(cars, sel_idx)

    def _on_car_selected(self, car_idx: int) -> None:
        self.cmd_dispatch.select_car(car_idx)

    def _on_user_command(self, action: str, car_idx: int, params: dict) -> None:
        if self.tcp_client.bound_cars and (car_idx not in self.tcp_client.bound_cars):
            QMessageBox.warning(self, "Unauthorized", f"Car #{car_idx+1} is not in your bound team roster!")
            return
        cmd_id = self.tcp_client.send_team_command(action, car_idx, params)
        self._log("CMD", f"Dispatched Team Command [{cmd_id}] {action} on Car #{car_idx+1}")

    def _on_event_received(self, evt: dict) -> None:
        self._log("EVENT", f"[{evt.get('e')}] Car #{evt.get('c')+1} | {evt.get('d')}")

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
