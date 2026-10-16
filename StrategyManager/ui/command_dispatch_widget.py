"""
PySide6 Radio Command Dispatch & Target Strategy Workbench
==========================================================
Faithful reproduction of HUD Right Sidebar:
- Header: IN-RACE RADIO _ STRATEGY DISPATCH CONSOLE
- Target Car dropdown selector
- Next Compound dropdown with tire compound badge icon (e.g. HARD)
- Refuel (L) spin box (+ / - buttons)
- Vertical Stack of tactical buttons:
  - [BOX THIS LAP] (Deep red with pit entry icon)
  - [STAY OUT (CANCEL BOX)] (Grey neutral)
  - [PUSH NOW / QUALI PACE] (Vibrant green with lightning icon)
  - [SAVE FUEL / LIFT_COAST] (Cyan/blue with water droplet icon)
  - [MANAGE TYRES] (Dark with shield icon)
  - [DEFEND POSITION] (Dark with shield icon)
"""

from typing import Dict, Any, Optional
from PySide6.QtCore import Signal, Qt
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel,
    QComboBox, QSpinBox, QGridLayout
)
from PySide6.QtGui import QFont


class CommandDispatchWidget(QWidget):
    """Team Principal / FIA Admin Strategy Command Dispatcher matching UI mockup."""

    command_triggered = Signal(str, int, dict) # action, target_car_idx, params_dict

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(10)

        # 1. Header Title
        lbl_title = QLabel("IN-RACE RADIO _ STRATEGY DISPATCH CONSOLE")
        lbl_title.setStyleSheet("color: #E2E8F0; font-weight: 800; font-size: 11px; letter-spacing: 0.8px;")
        layout.addWidget(lbl_title)

        # 2. Controls Grid
        ctrl_layout = QGridLayout()
        ctrl_layout.setContentsMargins(0, 4, 0, 4)
        ctrl_layout.setVerticalSpacing(8)
        ctrl_layout.setHorizontalSpacing(8)

        # Row 0: Target Car
        lbl_target = QLabel("Target Car:")
        lbl_target.setStyleSheet("color: #A0AEC0; font-weight: 600;")
        ctrl_layout.addWidget(lbl_target, 0, 0)

        self.combo_cars = QComboBox()
        self.combo_cars.setMinimumHeight(28)
        ctrl_layout.addWidget(self.combo_cars, 0, 1)

        # Row 1: Next Compound
        lbl_comp = QLabel("Next Compound:")
        lbl_comp.setStyleSheet("color: #A0AEC0; font-weight: 600;")
        ctrl_layout.addWidget(lbl_comp, 1, 0)

        self.combo_compound = QComboBox()
        self.combo_compound.setMinimumHeight(28)
        self.combo_compound.addItems(["SOFT 🔴", "MEDIUM 🟡", "HARD ⚪", "INTER 🟢", "WET 🔵"])
        self.combo_compound.setCurrentIndex(2) # Default Hard
        ctrl_layout.addWidget(self.combo_compound, 1, 1)

        # Row 2: Refuel (L)
        lbl_refuel = QLabel("Refuel (L):")
        lbl_refuel.setStyleSheet("color: #A0AEC0; font-weight: 600;")
        ctrl_layout.addWidget(lbl_refuel, 2, 0)

        self.spin_refuel = QSpinBox()
        self.spin_refuel.setRange(0, 150)
        self.spin_refuel.setValue(0)
        self.spin_refuel.setMinimumHeight(28)
        self.spin_refuel.setAlignment(Qt.AlignCenter)
        ctrl_layout.addWidget(self.spin_refuel, 2, 1)

        layout.addLayout(ctrl_layout)

        layout.addSpacing(6)

        # 3. Stacked Tactical Action Buttons (One-Click)
        self.btn_box = QPushButton("BOX THIS LAP   ➔")
        self.btn_box.setObjectName("btn_box")
        self.btn_box.setMinimumHeight(38)
        self.btn_box.clicked.connect(self._on_box_clicked)
        layout.addWidget(self.btn_box)

        self.btn_cancel_box = QPushButton("STAY OUT (CANCEL BOX)   ✕")
        self.btn_cancel_box.setObjectName("btn_cancel_box")
        self.btn_cancel_box.setMinimumHeight(34)
        self.btn_cancel_box.clicked.connect(self._on_cancel_box_clicked)
        layout.addWidget(self.btn_cancel_box)

        self.btn_push = QPushButton("PUSH NOW / QUALI PACE   ⚡")
        self.btn_push.setObjectName("btn_push")
        self.btn_push.setMinimumHeight(36)
        self.btn_push.clicked.connect(lambda: self._dispatch_radio("PUSH"))
        layout.addWidget(self.btn_push)

        self.btn_save = QPushButton("SAVE FUEL / LIFT_COAST   💧")
        self.btn_save.setObjectName("btn_save")
        self.btn_save.setMinimumHeight(36)
        self.btn_save.clicked.connect(lambda: self._dispatch_radio("SAVE_FUEL"))
        layout.addWidget(self.btn_save)

        self.btn_manage = QPushButton("MANAGE TYRES   🛡")
        self.btn_manage.setObjectName("btn_tactical_neutral")
        self.btn_manage.setMinimumHeight(34)
        self.btn_manage.clicked.connect(lambda: self._dispatch_radio("MANAGE_TYRES"))
        layout.addWidget(self.btn_manage)

        self.btn_defend = QPushButton("DEFEND POSITION   🛡")
        self.btn_defend.setObjectName("btn_tactical_neutral")
        self.btn_defend.setMinimumHeight(34)
        self.btn_defend.clicked.connect(lambda: self._dispatch_radio("DEFEND"))
        layout.addWidget(self.btn_defend)

        layout.addStretch()

    def update_car_list(self, cars: list) -> None:
        current_data = self.combo_cars.currentData()
        self.combo_cars.blockSignals(True)
        self.combo_cars.clear()
        for c in cars:
            idx = c.get("i", c.get("car_index", 0))
            name = c.get("n", c.get("driver_name", f"Car #{idx}"))
            self.combo_cars.addItem(f"#{idx+1} - {name}", idx)

        if current_data is not None:
            idx_found = self.combo_cars.findData(current_data)
            if idx_found >= 0:
                self.combo_cars.setCurrentIndex(idx_found)
        self.combo_cars.blockSignals(False)

    def select_car(self, car_idx: int) -> None:
        idx_found = self.combo_cars.findData(car_idx)
        if idx_found >= 0:
            self.combo_cars.setCurrentIndex(idx_found)

    def get_selected_car_idx(self) -> int:
        return self.combo_cars.currentData() if self.combo_cars.count() > 0 else -1

    def _on_box_clicked(self) -> None:
        car_idx = self.get_selected_car_idx()
        if car_idx >= 0:
            comp_text = self.combo_compound.currentText().split()[0] # "HARD", "SOFT", etc.
            params = {
                "tc": comp_text,
                "fuel_add": self.spin_refuel.value()
            }
            self.command_triggered.emit("BOX", car_idx, params)

    def _on_cancel_box_clicked(self) -> None:
        car_idx = self.get_selected_car_idx()
        if car_idx >= 0:
            self.command_triggered.emit("CANCEL_BOX", car_idx, {})

    def _dispatch_radio(self, cmd_text: str) -> None:
        car_idx = self.get_selected_car_idx()
        if car_idx >= 0:
            self.command_triggered.emit("RADIO", car_idx, {"cmd": cmd_text})
