"""
PySide6 Pre-Race Driver Binding / Draft Lobby Drawer
====================================================
Allows User to:
- View all drivers on the grid
- Claim / Bind drivers to form team roster
- Unbind drivers
- Respects Admin Roster Freeze / Parc Ferme lock
"""

from typing import Dict, Any, List, Set, Optional
from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QTableWidget, QTableWidgetItem,
    QPushButton, QLabel, QHeaderView, QGroupBox
)
from PySide6.QtGui import QFont, QColor
from StrategyManager.core.protocol import STATE_LOBBY_OPEN, STATE_ROSTER_FROZEN, STATE_RACE_ACTIVE


class DriverDraftLobbyDrawer(QGroupBox):
    """Driver Draft & Claiming Lobby."""

    claim_requested = Signal(int)   # car_idx
    unclaim_requested = Signal(int) # car_idx

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__("PRE-RACE DRIVER DRAFT & TEAM ROSTER BINDING", parent)
        layout = QVBoxLayout(self)

        self.lbl_status = QLabel("Lobby State: OPEN | Claim AI drivers to form your team roster.")
        self.lbl_status.setStyleSheet("color: #00E5FF; font-weight: bold;")
        layout.addWidget(self.lbl_status)

        self.table = QTableWidget()
        self.table.setColumnCount(5)
        self.table.setHorizontalHeaderLabels(["CAR #", "DRIVER NAME", "STATUS", "OWNED BY", "ACTION"])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.table.verticalHeader().setVisible(False)
        layout.addWidget(self.table)

        self.lifecycle_state = STATE_LOBBY_OPEN
        self.my_client_id = ""
        self.roster_map: Dict[int, str] = {}
        self.cars_list: List[Dict[str, Any]] = []

    def set_lifecycle_state(self, state: str) -> None:
        self.lifecycle_state = state
        if state == STATE_LOBBY_OPEN:
            self.lbl_status.setText("Lobby State: OPEN | Driver draft active.")
            self.lbl_status.setStyleSheet("color: #48BB78; font-weight: bold;")
        elif state == STATE_ROSTER_FROZEN:
            self.lbl_status.setText("Lobby State: ROSTER FROZEN (Parc Ferme) | Roster locked by FIA Admin.")
            self.lbl_status.setStyleSheet("color: #E53E3E; font-weight: bold;")
        elif state == STATE_RACE_ACTIVE:
            self.lbl_status.setText("Lobby State: RACE ACTIVE | In-race tactical mode.")
            self.lbl_status.setStyleSheet("color: #ED8936; font-weight: bold;")
        self.refresh_table()

    def update_roster(self, my_client_id: str, roster_map: Dict[int, str], cars: List[Dict[str, Any]]) -> None:
        self.my_client_id = my_client_id
        self.roster_map = roster_map
        self.cars_list = cars
        self.refresh_table()

    def refresh_table(self) -> None:
        if not self.cars_list:
            # Provide sample grid if cars not yet received
            cars = [{"i": i, "n": f"AI Driver #{i+1}"} for i in range(20)]
        else:
            cars = self.cars_list

        self.table.setRowCount(len(cars))
        mono_font = QFont("Consolas", 9)
        is_locked = (self.lifecycle_state != STATE_LOBBY_OPEN)

        for row, c in enumerate(cars):
            idx = c.get("i", c.get("car_index", row))
            name = c.get("n", c.get("driver_name", f"Driver #{idx}"))
            owner = self.roster_map.get(idx, "")

            is_mine = (owner == self.my_client_id and self.my_client_id != "")
            is_claimed = (owner != "")

            # Car #
            it_idx = QTableWidgetItem(f"#{idx}")
            it_idx.setFont(mono_font)
            it_idx.setTextAlignment(Qt.AlignCenter)
            self.table.setItem(row, 0, it_idx)

            # Name
            it_name = QTableWidgetItem(name)
            it_name.setFont(mono_font)
            self.table.setItem(row, 1, it_name)

            # Status
            status_text = "BOUND (YOU)" if is_mine else ("CLAIMED" if is_claimed else "AVAILABLE")
            it_status = QTableWidgetItem(status_text)
            it_status.setFont(mono_font)
            it_status.setTextAlignment(Qt.AlignCenter)
            if is_mine:
                it_status.setForeground(QColor("#00E5FF"))
            elif is_claimed:
                it_status.setForeground(QColor("#ED8936"))
            else:
                it_status.setForeground(QColor("#48BB78"))
            self.table.setItem(row, 2, it_status)

            # Owned By
            it_owner = QTableWidgetItem(owner if owner else "-")
            it_owner.setFont(mono_font)
            it_owner.setTextAlignment(Qt.AlignCenter)
            self.table.setItem(row, 3, it_owner)

            # Action Button
            btn = QPushButton()
            btn.setFont(QFont("Segoe UI", 8, QFont.Bold))
            if is_mine:
                btn.setText("UNBIND")
                btn.setStyleSheet("background-color: #742A2A; color: white;")
                btn.setEnabled(not is_locked)
                btn.clicked.connect(lambda _, cidx=idx: self.unclaim_requested.emit(cidx))
            elif is_claimed:
                btn.setText("TAKEN")
                btn.setEnabled(False)
            else:
                btn.setText("CLAIM / BIND")
                btn.setStyleSheet("background-color: #276749; color: white;")
                btn.setEnabled(not is_locked)
                btn.clicked.connect(lambda _, cidx=idx: self.claim_requested.emit(cidx))

            self.table.setCellWidget(row, 4, btn)
