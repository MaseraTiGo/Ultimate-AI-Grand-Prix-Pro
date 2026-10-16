"""
PySide6 Radio Command Dispatch & Target Strategy Workbench
==========================================================
Provides one-click race engineer command buttons:
- Box This Lap
- Cancel Box / Stay Out
- Push Now / Quali Pace
- Save Fuel / Lift & Coast
- Manage Tyres
- Next Pit Compound selector & Fuel Refill Target (L)
"""

from typing import Dict, Any, Optional
from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel,
    QComboBox, QSpinBox, QGroupBox, QGridLayout
)


class CommandDispatchWidget(QGroupBox):
    """Team Principal / FIA Admin Strategy Command Dispatcher."""

    command_triggered = Signal(str, int, dict) # action, target_car_idx, params_dict

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__("IN-RACE RADIO & STRATEGY DISPATCH CONSOLE", parent)
        layout = QVBoxLayout(self)

        # Target Selector
        top_row = QHBoxLayout()
        top_row.addWidget(QLabel("Target Car:"))
        self.combo_cars = QComboBox()
        top_row.addWidget(self.combo_cars, 1)

        top_row.addWidget(QLabel("Next Compound:"))
        self.combo_compound = QComboBox()
        self.combo_compound.addItems(["SOFT", "MED", "HARD", "INTER", "WET"])
        self.combo_compound.setCurrentText("HARD")
        top_row.addWidget(self.combo_compound)

        top_row.addWidget(QLabel("Refuel (L):"))
        self.spin_refuel = QSpinBox()
        self.spin_refuel.setRange(0, 150)
        self.spin_refuel.setValue(0)
        top_row.addWidget(self.spin_refuel)

        layout.addLayout(top_row)

        # Tactical Action Buttons Grid
        btn_grid = QGridLayout()

        self.btn_box = QPushButton("BOX THIS LAP")
        self.btn_box.setObjectName("btn_box")
        self.btn_box.clicked.connect(self._on_box_clicked)
        btn_grid.addWidget(self.btn_box, 0, 0)

        self.btn_cancel_box = QPushButton("STAY OUT (CANCEL BOX)")
        self.btn_cancel_box.clicked.connect(self._on_cancel_box_clicked)
        btn_grid.addWidget(self.btn_cancel_box, 0, 1)

        self.btn_push = QPushButton("PUSH NOW / QUALI PACE")
        self.btn_push.setObjectName("btn_push")
        self.btn_push.clicked.connect(lambda: self._dispatch_radio("PUSH"))
        btn_grid.addWidget(self.btn_push, 1, 0)

        self.btn_save = QPushButton("SAVE FUEL / LIFT & COAST")
        self.btn_save.setObjectName("btn_save")
        self.btn_save.clicked.connect(lambda: self._dispatch_radio("SAVE_FUEL"))
        btn_grid.addWidget(self.btn_save, 1, 1)

        self.btn_manage = QPushButton("MANAGE TYRES")
        self.btn_manage.clicked.connect(lambda: self._dispatch_radio("MANAGE_TYRES"))
        btn_grid.addWidget(self.btn_manage, 2, 0)

        self.btn_defend = QPushButton("DEFEND POSITION")
        self.btn_defend.clicked.connect(lambda: self._dispatch_radio("DEFEND"))
        btn_grid.addWidget(self.btn_defend, 2, 1)

        layout.addLayout(btn_grid)

    def update_car_list(self, cars: list) -> None:
        current_data = self.combo_cars.currentData()
        self.combo_cars.blockSignals(True)
        self.combo_cars.clear()
        for c in cars:
            idx = c.get("i", c.get("car_index", 0))
            name = c.get("n", c.get("driver_name", f"Car #{idx}"))
            self.combo_cars.addItem(f"#{idx} - {name}", idx)

        # Restore selection
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
            params = {
                "tc": self.combo_compound.currentText(),
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
