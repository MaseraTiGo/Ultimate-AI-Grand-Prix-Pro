"""
StrategyManager AI Persona & Setup Manager
==========================================
Manages:
1. Anthropomorphic AI Driver Personas (Aggression, Defense, Mistake Proneness, Tyre Saving, Wet Skill)
2. Pre-race baseline setup profiles and live in-race bias overrides
"""

from typing import Dict, Any, Optional, List
import copy


class PersonaSetupManager:
    """Manages AI Driver Personalities and Vehicle Setup Biases."""

    # Baseline Default Persona Template
    DEFAULT_PERSONA = {
        "aggression": 0.70,             # 0.0 ~ 1.0 (Overtake opportunism)
        "defense_hardness": 0.75,       # 0.0 ~ 1.0 (Weaving / Tow breaking tenacity)
        "mistake_proneness": 0.15,      # 0.0 ~ 1.0 (Likelihood of lockup/slide under pressure)
        "tyre_preservation": 0.80,      # 0.0 ~ 1.0 (Smoothness on throttle/steering)
        "wet_weather_skill": 0.85,      # 0.0 ~ 1.0 (Grip threshold perception in rain)
        "fuel_saving_willingness": 0.65 # 0.0 ~ 1.0 (Compliance with lift & coast radio calls)
    }

    # Baseline Setup Profile
    DEFAULT_SETUP = {
        "front_wing_angle": 28.0,       # Degrees
        "rear_wing_angle": 34.0,        # Degrees
        "brake_bias_f": 56.5,           # % Front
        "tyre_pressures_psi": [22.5, 22.5, 20.0, 20.0],
        "initial_fuel_kg": 55.0,
        "starting_compound": "MED",
        "gear_ratio_bias": "MEDIUM"     # SHORT, MEDIUM, TALL
    }

    def __init__(self):
        self.car_personas: Dict[int, Dict[str, Any]] = {}
        self.car_setups: Dict[int, Dict[str, Any]] = {}

    def get_persona(self, car_idx: int) -> Dict[str, Any]:
        if car_idx not in self.car_personas:
            self.car_personas[car_idx] = copy.deepcopy(self.DEFAULT_PERSONA)
        return self.car_personas[car_idx]

    def set_persona(self, car_idx: int, persona_data: Dict[str, Any]) -> Dict[str, Any]:
        p = self.get_persona(car_idx)
        for k, v in persona_data.items():
            if k in p:
                p[k] = max(0.0, min(1.0, float(v)))
        return p

    def get_setup(self, car_idx: int) -> Dict[str, Any]:
        if car_idx not in self.car_setups:
            self.car_setups[car_idx] = copy.deepcopy(self.DEFAULT_SETUP)
        return self.car_setups[car_idx]

    def set_setup(self, car_idx: int, setup_data: Dict[str, Any]) -> Dict[str, Any]:
        s = self.get_setup(car_idx)
        for k, v in setup_data.items():
            if k in s:
                s[k] = v
        return s

    def generate_preset_persona(self, driver_archetype: str) -> Dict[str, float]:
        """Pre-defined driver archetype personalities."""
        archetypes = {
            "AGGRESSIVE_CHAMPION": {
                "aggression": 0.95, "defense_hardness": 0.92, "mistake_proneness": 0.04,
                "tyre_preservation": 0.88, "wet_weather_skill": 0.98, "fuel_saving_willingness": 0.60
            },
            "TYRE_WHISPERER": {
                "aggression": 0.68, "defense_hardness": 0.78, "mistake_proneness": 0.06,
                "tyre_preservation": 0.98, "wet_weather_skill": 0.85, "fuel_saving_willingness": 0.90
            },
            "ROOKIE_CHARGER": {
                "aggression": 0.85, "defense_hardness": 0.70, "mistake_proneness": 0.35,
                "tyre_preservation": 0.60, "wet_weather_skill": 0.65, "fuel_saving_willingness": 0.45
            },
            "CALCULATED_VETERAN": {
                "aggression": 0.72, "defense_hardness": 0.85, "mistake_proneness": 0.05,
                "tyre_preservation": 0.92, "wet_weather_skill": 0.92, "fuel_saving_willingness": 0.88
            }
        }
        return archetypes.get(driver_archetype, self.DEFAULT_PERSONA)
