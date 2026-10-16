"""
StrategyManager Rules Engine & Sandbox Override Manager
======================================================
Strict Two-Tier Configuration Hierarchy (Series -> Era/Year).
Enforces the philosophy: "100% Authentic by Default, Unlimited Sandbox Freedom by Override".
Immutability Guarantee: Modifying any rule NEVER overwrites files in presets/defaults/.
Any customization is saved as a new file in presets/user_custom/ (Copy-on-Write).
"""

import os
import json
import copy
from typing import Dict, Any, List, Optional
from PySide6.QtCore import QObject, Signal


class RulesEngine(QObject):
    """
    Central repository for racing regulations, active preset state, and sandbox overrides.
    """
    preset_loaded = Signal(str, dict)       # preset_id, full_config
    rule_overridden = Signal(str, object)   # key_path, new_value
    preset_saved = Signal(str, str)         # preset_id, filepath

    def __init__(self, defaults_dir: str, custom_dir: str, parent: Optional[QObject] = None):
        super().__init__(parent)
        self.defaults_dir = os.path.abspath(defaults_dir)
        self.custom_dir = os.path.abspath(custom_dir)

        os.makedirs(self.defaults_dir, exist_ok=True)
        os.makedirs(self.custom_dir, exist_ok=True)

        self.current_preset_id: str = ""
        self.is_custom: bool = False
        self.active_config: Dict[str, Any] = {}
        self.base_config: Dict[str, Any] = {}

    def list_available_presets(self) -> List[Dict[str, Any]]:
        """List all available presets (defaults + custom)."""
        presets = []

        # Read defaults
        if os.path.exists(self.defaults_dir):
            for fname in os.listdir(self.defaults_dir):
                if fname.endswith(".json"):
                    fpath = os.path.join(self.defaults_dir, fname)
                    cfg = self._read_json(fpath)
                    if cfg:
                        presets.append({
                            "id": cfg.get("preset_id", fname.replace(".json", "")),
                            "name": f"{cfg.get('series', 'Series')} - {cfg.get('era', 'Era')}",
                            "series": cfg.get("series", "Unknown"),
                            "era": cfg.get("era", "Unknown"),
                            "description": cfg.get("description", ""),
                            "is_custom": False,
                            "path": fpath
                        })

        # Read custom sandbox presets
        if os.path.exists(self.custom_dir):
            for fname in os.listdir(self.custom_dir):
                if fname.endswith(".json"):
                    fpath = os.path.join(self.custom_dir, fname)
                    cfg = self._read_json(fpath)
                    if cfg:
                        presets.append({
                            "id": cfg.get("preset_id", fname.replace(".json", "")),
                            "name": f"[CUSTOM] {cfg.get('series', 'Series')} - {cfg.get('era', 'Era')}",
                            "series": cfg.get("series", "Custom"),
                            "era": cfg.get("era", "Custom"),
                            "description": cfg.get("description", ""),
                            "is_custom": True,
                            "path": fpath
                        })

        return presets

    def load_preset(self, preset_id: str) -> bool:
        """Load a preset by ID, checking custom_dir first, then defaults_dir."""
        custom_path = os.path.join(self.custom_dir, f"{preset_id}.json")
        default_path = os.path.join(self.defaults_dir, f"{preset_id}.json")

        target_path = None
        is_custom = False

        if os.path.exists(custom_path):
            target_path = custom_path
            is_custom = True
        elif os.path.exists(default_path):
            target_path = default_path
            is_custom = False
        else:
            return False

        cfg = self._read_json(target_path)
        if not cfg:
            return False

        self.current_preset_id = preset_id
        self.is_custom = is_custom
        self.base_config = copy.deepcopy(cfg)
        self.active_config = copy.deepcopy(cfg)

        self.preset_loaded.emit(preset_id, self.active_config)
        return True

    def override_rule(self, section: str, key: str, value: Any) -> None:
        """
        Apply in-memory sandbox override.
        Marks configuration as customized.
        """
        if section not in self.active_config:
            self.active_config[section] = {}

        self.active_config[section][key] = value
        self.is_custom = True
        self.rule_overridden.emit(f"{section}.{key}", value)

    def save_as_custom_preset(self, new_preset_id: str, new_name: str = "", new_desc: str = "") -> str:
        """
        Copy-on-Write persistence.
        NEVER overwrites defaults_dir. Writes exclusively to custom_dir.
        """
        clean_id = "".join([c if c.isalnum() or c in "_-" else "_" for c in new_preset_id])
        save_path = os.path.join(self.custom_dir, f"{clean_id}.json")

        to_save = copy.deepcopy(self.active_config)
        to_save["preset_id"] = clean_id
        if new_name:
            to_save["era"] = new_name
        if new_desc:
            to_save["description"] = new_desc

        with open(save_path, "w", encoding="utf-8") as f:
            json.dump(to_save, f, indent=2, ensure_ascii=False)

        self.current_preset_id = clean_id
        self.is_custom = True
        self.preset_saved.emit(clean_id, save_path)
        return save_path

    # Accessors for Strategy AI
    def allow_refueling(self) -> bool:
        return bool(self.active_config.get("sporting_rules", {}).get("allow_refueling", False))

    def refueling_flow_rate(self) -> float:
        return float(self.active_config.get("sporting_rules", {}).get("refueling_flow_rate_kg_s", 10.0))

    def pit_mechanics(self) -> str:
        # "simultaneous" or "sequential"
        return str(self.active_config.get("sporting_rules", {}).get("pit_work_mechanics", "simultaneous"))

    def mandatory_compounds_count(self) -> int:
        return int(self.active_config.get("sporting_rules", {}).get("mandatory_dry_compounds", 2))

    def min_stationary_time(self) -> float:
        return float(self.active_config.get("sporting_rules", {}).get("min_pit_lane_stationary_time_sec", 0.0))

    def active_aero_enabled(self) -> bool:
        return bool(self.active_config.get("powertrain_and_aero", {}).get("active_aero_enabled", False))

    def get_compounds(self) -> List[Dict[str, Any]]:
        return self.active_config.get("tyres", {}).get("compounds", [])

    def _read_json(self, path: str) -> Optional[Dict[str, Any]]:
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return None
