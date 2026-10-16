"""
StrategyManager FIA Race Control & Master Hub (admin_main.py)
============================================================
Omniscient Authority Desktop Application:
- Connects directly to AC CSP Lua via UDP (IPCGateway: 30888/30889)
- Hosts Admin TCP Hub (30890) for Team Pit Wall User clients
- Enforces Roster Freeze / Parc Ferme lifecycle toggle
- Controls Lua Telemetry Broadcast Master Toggle
- Manages Regulation Presets & Sandbox Rule-Breaker overrides
- Omniscient Monitoring & God Mode Tactical Commands across 100% of the grid
"""

import sys
import os
from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QTabWidget, QTextEdit, QSplitter, QStatusBar
)
from StrategyManager.core import StateStore, IPCGateway, AdminTCPHub, STATE_LOBBY_OPEN, STATE_ROSTER_FROZEN, STATE_RACE_ACTIVE
from StrategyManager.rules_engine import RulesEngine
from StrategyManager.strategy_ai import StrategySimulator, PitStopLossCalculator
from StrategyManager.ui import (
    PITWALL_STYLE, TrackMapWidget, TimingTowerWidget, StintPlannerPanel,
    RuleOverrideDrawer, CommandDispatchWidget
)


class AdminMainWindow(QMainWindow):
    """FIA Race Control Master Application Window."""

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Ultimate AI Grand Prix Pro — FIA Race Control & Central Authority (Admin)")
        self.resize(1440, 920)
        self.setStyleSheet(PITWALL_STYLE)

        # 1. Core Services Setup
        base_dir = os.path.dirname(os.path.abspath(__file__))
        defaults_dir = os.path.join(base_dir, "presets", "defaults")
        custom_dir = os.path.join(base_dir, "presets", "user_custom")

        self.rules_engine = RulesEngine(defaults_dir, custom_dir, self)
        self.state_store = StateStore(self)
        self.ipc_gateway = IPCGateway(self.state_store, rx_port=30888, tx_host="127.0.0.1", tx_port=30889, parent=self)
        self.admin_hub = AdminTCPHub(self.state_store, self.ipc_gateway, host="0.0.0.0", port=30890, parent=self)

        # 2. Setup Central Layout
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(10, 10, 10, 10)

        # Top Control Bar (FIA Master Switches)
        main_layout.addLayout(self._create_top_bar())

        # Main Workspace Splitter
        workspace_splitter = QSplitter(Qt.Horizontal)

        # Left Column: Pro Timing Tower
        self.timing_tower = TimingTowerWidget()
        self.timing_tower.car_selected.connect(self._on_car_selected)
        workspace_splitter.addWidget(self.timing_tower)

        # Center Column: Track Map + Tactical Stint Planner
        center_widget = QWidget()
        center_layout = QVBoxLayout(center_widget)
        center_layout.setContentsMargins(0, 0, 0, 0)

        self.track_map = TrackMapWidget()
        center_layout.addWidget(self.track_map, 2)

        self.stint_planner = StintPlannerPanel()
        center_layout.addWidget(self.stint_planner, 1)

        workspace_splitter.addWidget(center_widget)

        # Right Column: Strategy Dispatch + Sandbox Rules Drawer + Event Log
        right_tabs = QTabWidget()

        # Tab 1: Dispatch
        self.cmd_dispatch = CommandDispatchWidget()
        self.cmd_dispatch.command_triggered.connect(self._on_admin_command)
        right_tabs.addTab(self.cmd_dispatch, "TACTICAL DISPATCH")

        # Tab 2: Sandbox Rules
        self.rule_drawer = RuleOverrideDrawer(self.rules_engine)
        right_tabs.addTab(self.rule_drawer, "REGULATIONS & SANDBOX")

        # Tab 3: Console Logs
        self.log_console = QTextEdit()
        self.log_console.setReadOnly(True)
        right_tabs.addTab(self.log_console, "SYSTEM CONSOLE")

        workspace_splitter.addWidget(right_tabs)
        workspace_splitter.setStretchFactor(0, 4)
        workspace_splitter.setStretchFactor(1, 4)
        workspace_splitter.setStretchFactor(2, 3)

        main_layout.addWidget(workspace_splitter)

        # Status Bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("FIA Admin Core Online. Listening on UDP:30888/30889, TCP:30890")

        # 3. Connect Signals
        self.state_store.telemetry_updated.connect(self._on_telemetry_updated)
        self.state_store.event_received.connect(self._on_event_received)
        self.state_store.ack_received.connect(self._on_ack_received)
        self.ipc_gateway.log_message.connect(self._log)
        self.admin_hub.log_message.connect(self._log)

        # 4. Start Gateways
        self.ipc_gateway.start()
        self.admin_hub.start()

    def _create_top_bar(self) -> QHBoxLayout:
        bar = QHBoxLayout()

        self.lbl_role = QLabel("FIA RACE CONTROL (GOD MODE)")
        self.lbl_role.setStyleSheet("color: #00E5FF; font-weight: bold; font-size: 14px;")
        bar.addWidget(self.lbl_role)

        bar.addSpacing(20)

        # Lua Telemetry Master Toggle
        self.btn_lua_toggle = QPushButton("LUA BROADCAST: [ON]")
        self.btn_lua_toggle.setCheckable(True)
        self.btn_lua_toggle.setChecked(True)
        self.btn_lua_toggle.clicked.connect(self._toggle_lua_broadcast)
        bar.addWidget(self.btn_lua_toggle)

        # Parc Ferme / Roster Freeze Master Toggle
        self.btn_freeze_roster = QPushButton("PARC FERME: [OPEN]")
        self.btn_freeze_roster.setStyleSheet("background-color: #276749; color: white;")
        self.btn_freeze_roster.clicked.connect(self._toggle_roster_freeze)
        bar.addWidget(self.btn_freeze_roster)

        # Synthetic Safety Car Trigger
        self.btn_sc_toggle = QPushButton("SAFETY CAR: [DEPLOY]")
        self.btn_sc_toggle.clicked.connect(self._trigger_synthetic_sc)
        bar.addWidget(self.btn_sc_toggle)

        bar.addStretch()

        self.lbl_session = QLabel("SESSION: RACE | LAP: 0/0 | TRACK: 25.0°C | GRIP: 100%")
        self.lbl_session.setStyleSheet("color: #A0AEC0; font-family: 'Consolas';")
        bar.addWidget(self.lbl_session)

        return bar

    def _toggle_lua_broadcast(self) -> None:
        is_on = self.btn_lua_toggle.isChecked()
        self.btn_lua_toggle.setText("LUA BROADCAST: [ON]" if is_on else "LUA BROADCAST: [PAUSED]")
        self.ipc_gateway.dispatch_broadcast_toggle(is_on)
        self._log("INFO", f"Dispatched Lua Broadcast Toggle -> {is_on}")

    def _toggle_roster_freeze(self) -> None:
        if self.admin_hub.lifecycle_state == STATE_LOBBY_OPEN:
            self.admin_hub.freeze_roster()
            self.btn_freeze_roster.setText("PARC FERME: [FROZEN]")
            self.btn_freeze_roster.setStyleSheet("background-color: #742A2A; color: white;")
        else:
            self.admin_hub.open_lobby()
            self.btn_freeze_roster.setText("PARC FERME: [OPEN]")
            self.btn_freeze_roster.setStyleSheet("background-color: #276749; color: white;")

    def _trigger_synthetic_sc(self) -> None:
        self.state_store.is_safety_car = not self.state_store.is_safety_car
        self.btn_sc_toggle.setText("SAFETY CAR: [RECALL]" if self.state_store.is_safety_car else "SAFETY CAR: [DEPLOY]")
        self.track_map.set_yellow_flags(self.state_store.is_safety_car)
        self._log("WARN", f"Synthetic Safety Car toggled -> {self.state_store.is_safety_car}")

    def _on_telemetry_updated(self, pkt: dict) -> None:
        cars = pkt.get("c", [])
        env = pkt.get("e", {})

        # Update Top Bar
        cur_lap = env.get("l", 0)
        tot_laps = env.get("tl", 0)
        tt = env.get("tt", 25.0)
        tg = env.get("tg", 1.0) * 100.0
        self.lbl_session.setText(f"SESSION: RACE | LAP: {cur_lap}/{tot_laps} | TRACK: {tt:.1f}°C | GRIP: {tg:.1f}%")

        # Update Leaderboard & Dispatcher
        self.timing_tower.update_grid(cars)
        self.cmd_dispatch.update_car_list(cars)

        # Update Stint Gantt
        self.stint_planner.gantt.set_plan(self.stint_planner.gantt.active_plan, tot_laps, cur_lap)

        # Update Track Map & Ghost Rejoin
        sel_idx = self.cmd_dispatch.get_selected_car_idx()
        target_car = self.state_store.cars.get(sel_idx)

        ghost_spline = None
        if target_car:
            loss = PitStopLossCalculator.calculate_total_pit_loss(
                refuel_amount_kg=0.0,
                flow_rate_kg_s=10.0,
                pit_mechanics=self.rules_engine.pit_mechanics(),
                pit_lane_delta_sec=21.0
            )
            rejoin_data = StrategySimulator.predict_pit_out_rejoin(target_car, list(self.state_store.cars.values()), loss["total_pit_loss_sec"], 85.0)
            ghost_spline = rejoin_data["rejoin_spline"]

        self.track_map.update_telemetry(cars, sel_idx, ghost_spline)

    def _on_car_selected(self, car_idx: int) -> None:
        self.cmd_dispatch.select_car(car_idx)

    def _on_admin_command(self, action: str, car_idx: int, params: dict) -> None:
        cmd_id = self.ipc_gateway.send_command(action, car_idx, params)
        self._log("INFO", f"Admin Command Dispatched: [{cmd_id}] {action} on Car #{car_idx}")

    def _on_event_received(self, evt: dict) -> None:
        e_type = evt.get("e", "EVENT")
        c_idx = evt.get("c", -1)
        self._log("EVENT", f"[{e_type}] Car #{c_idx} | {evt.get('d', {})}")

    def _on_ack_received(self, ack: dict) -> None:
        self._log("ACK", f"Cmd #{ack.get('id')} -> {ack.get('s')}: {ack.get('m')}")

    def _log(self, level: str, text: str) -> None:
        self.log_console.append(f"[{level}] {text}")

    def closeEvent(self, event) -> None:
        self.ipc_gateway.stop()
        self.admin_hub.stop()
        event.accept()


def main():
    app = QApplication(sys.argv)
    window = AdminMainWindow()
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
