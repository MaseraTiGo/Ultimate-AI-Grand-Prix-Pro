"""
PySide6 Rule Override Drawer & Sandbox Panel
=============================================
Enforces Sandbox Rule-Breaker philosophy:
- Players can break authentic rules (fuel flow rate, refueling toggle, compound mandates)
- Modifications are saved Copy-on-Write to presets/user_custom/
- Immutable defaults are protected
"""

from typing import Dict, Any, Optional
from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QCheckBox,
    QDoubleSpinBox, QSpinBox, QComboBox, QPushButton, QGroupBox, QLineEdit, QMessageBox
)
from StrategyManager.rules_engine.rules_engine import RulesEngine


class RuleOverrideDrawer(QGroupBox):
    """Interactive sandbox rule-breaker panel."""

    rules_updated = Signal()

    def __init__(self, rules_engine: RulesEngine, parent: Optional[QWidget] = None):
        super().__init__("SANDBOX RULE-BREAKER & REGULATION MANAGER", parent)
        self.rules_engine = rules_engine
        layout = QVBoxLayout(self)

        # Preset Selector Row
        preset_row = QHBoxLayout()
        preset_row.addWidget(QLabel("Active Preset:"))
        self.combo_presets = QComboBox()
        self.combo_presets.currentIndexChanged.connect(self._on_preset_selected)
        preset_row.addWidget(self.combo_presets, 1)

        self.btn_refresh = QPushButton("Reload")
        self.btn_refresh.clicked.connect(self.populate_presets)
        preset_row.addWidget(self.btn_refresh)
        layout.addLayout(preset_row)

        # Rule Controls
        grid_box = QGroupBox("Sporting & Mechanics Overrides")
        grid_layout = QVBoxLayout(grid_box)

        # 1. Refueling
        r1 = QHBoxLayout()
        self.chk_allow_refuel = QCheckBox("Allow Mid-Race Refueling")
        self.chk_allow_refuel.toggled.connect(lambda v: self.rules_engine.override_rule("sporting_rules", "allow_refueling", v))
        r1.addWidget(self.chk_allow_refuel)

        r1.addWidget(QLabel("Fuel Flow Rate (kg/s):"))
        self.spin_flow_rate = QDoubleSpinBox()
        self.spin_flow_rate.setRange(0.5, 30.0)
        self.spin_flow_rate.setSingleStep(0.5)
        self.spin_flow_rate.valueChanged.connect(lambda v: self.rules_engine.override_rule("sporting_rules", "refueling_flow_rate_kg_s", v))
        r1.addWidget(self.spin_flow_rate)
        grid_layout.addLayout(r1)

        # 2. Pit Work Mechanics (Sequential vs Parallel)
        r2 = QHBoxLayout()
        r2.addWidget(QLabel("Pit Work Order Mechanics:"))
        self.combo_mechanics = QComboBox()
        self.combo_mechanics.addItems(["simultaneous", "sequential"])
        self.combo_mechanics.currentTextChanged.connect(lambda v: self.rules_engine.override_rule("sporting_rules", "pit_work_mechanics", v))
        r2.addWidget(self.combo_mechanics)

        r2.addWidget(QLabel("Min Stationary Time (s):"))
        self.spin_min_stationary = QDoubleSpinBox()
        self.spin_min_stationary.setRange(0.0, 120.0)
        self.spin_min_stationary.valueChanged.connect(lambda v: self.rules_engine.override_rule("sporting_rules", "min_pit_lane_stationary_time_sec", v))
        r2.addWidget(self.spin_min_stationary)
        grid_layout.addLayout(r2)

        # 3. Mandatory Dry Compounds
        r3 = QHBoxLayout()
        r3.addWidget(QLabel("Mandatory Dry Compounds:"))
        self.spin_compounds = QSpinBox()
        self.spin_compounds.setRange(1, 4)
        self.spin_compounds.valueChanged.connect(lambda v: self.rules_engine.override_rule("sporting_rules", "mandatory_dry_compounds", v))
        r3.addWidget(self.spin_compounds)

        self.chk_active_aero = QCheckBox("Enable 2026 Active Aero (Z/X-Mode)")
        self.chk_active_aero.toggled.connect(lambda v: self.rules_engine.override_rule("powertrain_and_aero", "active_aero_enabled", v))
        r3.addWidget(self.chk_active_aero)
        grid_layout.addLayout(r3)

        layout.addWidget(grid_box)

        # Copy-on-Write Save Bar
        save_box = QHBoxLayout()
        save_box.addWidget(QLabel("Save Custom Preset:"))
        self.txt_custom_name = QLineEdit()
        self.txt_custom_name.setPlaceholderText("e.g. f1_2026_refuel_sandbox")
        save_box.addWidget(self.txt_custom_name, 1)

        self.btn_save = QPushButton("Save (Copy-on-Write)")
        self.btn_save.clicked.connect(self._on_save_custom)
        save_box.addWidget(self.btn_save)
        layout.addLayout(save_box)

        self.populate_presets()

    def populate_presets(self) -> None:
        self.combo_presets.blockSignals(True)
        self.combo_presets.clear()
        presets = self.rules_engine.list_available_presets()
        for p in presets:
            self.combo_presets.addItem(p["name"], p["id"])
        self.combo_presets.blockSignals(False)

        if self.combo_presets.count() > 0:
            self._on_preset_selected(0)

    def _on_preset_selected(self, index: int) -> None:
        pid = self.combo_presets.currentData()
        if not pid: return
        self.rules_engine.load_preset(pid)

        # Sync widgets
        self.chk_allow_refuel.blockSignals(True)
        self.chk_allow_refuel.setChecked(self.rules_engine.allow_refueling())
        self.chk_allow_refuel.blockSignals(False)

        self.spin_flow_rate.blockSignals(True)
        self.spin_flow_rate.setValue(self.rules_engine.refueling_flow_rate())
        self.spin_flow_rate.blockSignals(False)

        self.combo_mechanics.blockSignals(True)
        self.combo_mechanics.setCurrentText(self.rules_engine.pit_mechanics())
        self.combo_mechanics.blockSignals(False)

        self.spin_min_stationary.blockSignals(True)
        self.spin_min_stationary.setValue(self.rules_engine.min_stationary_time())
        self.spin_min_stationary.blockSignals(False)

        self.spin_compounds.blockSignals(True)
        self.spin_compounds.setValue(self.rules_engine.mandatory_compounds_count())
        self.spin_compounds.blockSignals(False)

        self.chk_active_aero.blockSignals(True)
        self.chk_active_aero.setChecked(self.rules_engine.active_aero_enabled())
        self.chk_active_aero.blockSignals(False)

        self.rules_updated.emit()

    def _on_save_custom(self) -> None:
        name = self.txt_custom_name.text().strip()
        if not name:
            QMessageBox.warning(self, "Invalid Name", "Please enter a valid preset name.")
            return

        saved_path = self.rules_engine.save_as_custom_preset(name, f"Custom {name}", "User Sandbox Override")
        QMessageBox.information(self, "Saved", f"Custom preset saved cleanly to:\n{saved_path}")
        self.populate_presets()
