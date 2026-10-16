"""
StrategyManager Strategy AI & Mathematical Physics Models
=========================================================
Implements:
1. Non-linear tyre degradation with thermal sensitivity & cliff threshold
2. Fuel burn mass-penalty lap-time delta (0.033s per kg in modern F1, 0.045s in V10)
3. Sequential vs. Parallel Pit Stop Time Loss Calculator
4. Ghost Pit-Out Traffic & Rejoin Position Predictor
5. Undercut / Overcut Threat & Opportunity Radar
"""

import math
from typing import Dict, Any, List, Optional, Tuple


class TyreDegradationModel:
    """Non-linear tyre degradation with thermal wear compounding."""

    @staticmethod
    def calculate_lap_time_loss(
        stint_lap: int,
        compound_deg_rate: float,
        thermal_sensitivity: float,
        core_temp_c: float,
        track_temp_c: float
    ) -> float:
        """
        Calculates lap time penalty (seconds) from tyre wear & thermal stress.
        Non-linear quadratic model: T_loss = base_deg * (laps)^1.15 + thermal_factor
        """
        # Optimal tyre temp is ~95C. Deviations cause accelerated wear / graining / overheating.
        temp_delta = max(0.0, core_temp_c - 105.0)
        thermal_penalty = (temp_delta * 0.025) * thermal_sensitivity

        # Non-linear wear curve (accelerates after lap 12-15 depending on compound)
        wear_curve = compound_deg_rate * math.pow(max(1, stint_lap), 1.15)

        # Cliff threshold: if stint exceeds typical lifespan, performance falls off a cliff
        cliff_penalty = 0.0
        cliff_lap = 1.0 / max(0.01, compound_deg_rate * 0.5)
        if stint_lap > cliff_lap:
            cliff_penalty = math.pow((stint_lap - cliff_lap), 1.6) * 0.15

        return round(wear_curve + thermal_penalty + cliff_penalty, 3)


class FuelPhysicsModel:
    """Calculates fuel burn and lap time weight penalty."""

    @staticmethod
    def calculate_weight_penalty(fuel_mass_kg: float, penalty_sec_per_kg: float = 0.033) -> float:
        """Heavier fuel increases braking distance and reduces acceleration."""
        return round(fuel_mass_kg * penalty_sec_per_kg, 3)

    @staticmethod
    def simulate_stint_fuel_burn(
        laps: int,
        burn_per_lap_kg: float,
        pace_mode: str = "NORMAL"
    ) -> Tuple[float, float]:
        """
        Returns (total_fuel_consumed_kg, avg_lap_time_offset_from_pace).
        Pace modes:
          - 'PUSH' / 'QUAL': +8% fuel burn, -0.4s lap time
          - 'NORMAL': baseline
          - 'SAVE' / 'LIFT_COAST': -12% fuel burn, +0.6s lap time
        """
        burn_mult = 1.0
        time_offset = 0.0
        if pace_mode in ("PUSH", "QUAL"):
            burn_mult = 1.08
            time_offset = -0.40
        elif pace_mode in ("SAVE", "LIFT_COAST"):
            burn_mult = 0.88
            time_offset = 0.60

        total_burn = laps * (burn_per_lap_kg * burn_mult)
        return round(total_burn, 2), time_offset


class PitStopLossCalculator:
    """Calculates total stationary pit stop duration and pit lane time loss."""

    @staticmethod
    def calculate_total_pit_loss(
        refuel_amount_kg: float,
        flow_rate_kg_s: float,
        pit_mechanics: str,
        tyre_change_time_sec: float = 2.4,
        pit_lane_delta_sec: float = 20.0,
        min_stationary_sec: float = 0.0
    ) -> Dict[str, float]:
        """
        pit_mechanics:
          - 'parallel' (F1 Refueling Era): Refueling and tyre change happen simultaneously.
          - 'sequential' (GT3 / WEC): Fuel hose must detach before wheel guns touch nuts.
        """
        refuel_time = 0.0
        if refuel_amount_kg > 0 and flow_rate_kg_s > 0:
            # 1.5s hose connect/disconnect overhead + actual flow time
            refuel_time = 1.5 + (refuel_amount_kg / flow_rate_kg_s)

        if pit_mechanics == "sequential":
            stationary_time = refuel_time + tyre_change_time_sec
        else:
            # parallel: stationary time is whichever takes longer
            stationary_time = max(refuel_time, tyre_change_time_sec)

        # Enforce minimum stationary rule (e.g. GT3 mandatory 45s)
        stationary_time = max(stationary_time, min_stationary_sec)
        total_time_lost = pit_lane_delta_sec + stationary_time

        return {
            "refuel_time_sec": round(refuel_time, 2),
            "tyre_change_time_sec": round(tyre_change_time_sec, 2),
            "stationary_time_sec": round(stationary_time, 2),
            "total_pit_loss_sec": round(total_time_lost, 2)
        }


class StrategySimulator:
    """
    Undercut/Overcut Radar and Ghost Pit-Out Traffic Finder.
    """

    @staticmethod
    def predict_pit_out_rejoin(
        target_car: Dict[str, Any],
        all_cars: List[Dict[str, Any]],
        total_pit_loss_sec: float,
        track_lap_time_sec: float
    ) -> Dict[str, Any]:
        """
        Projects where target_car will rejoin after pitting.
        Identifies traffic, slow cars ahead, or clean air.
        """
        target_s = target_car.get("spline_position", 0.0)
        # Fraction of a lap lost in pit lane
        lap_fraction_lost = (total_pit_loss_sec / max(30.0, track_lap_time_sec))
        rejoin_s = (target_s - lap_fraction_lost) % 1.0

        # Scan for traffic within +/- 0.05 spline around rejoin position
        traffic_ahead = []
        traffic_behind = []

        for c in all_cars:
            if c.get("car_index") == target_car.get("car_index"):
                continue
            c_s = c.get("spline_position", 0.0)
            delta_s = (c_s - rejoin_s)
            # Normalize to -0.5 .. +0.5
            if delta_s > 0.5: delta_s -= 1.0
            if delta_s < -0.5: delta_s += 1.0

            # delta_s > 0 means car is immediately ahead of rejoin point
            if 0.0 < delta_s < 0.06:
                traffic_ahead.append({
                    "car_index": c.get("car_index"),
                    "driver_name": c.get("driver_name"),
                    "delta_sec": round(delta_s * track_lap_time_sec, 1)
                })
            elif -0.06 < delta_s < 0.0:
                traffic_behind.append({
                    "car_index": c.get("car_index"),
                    "driver_name": c.get("driver_name"),
                    "delta_sec": round(abs(delta_s) * track_lap_time_sec, 1)
                })

        clean_air = (len(traffic_ahead) == 0)

        return {
            "rejoin_spline": round(rejoin_s, 4),
            "clean_air": clean_air,
            "traffic_ahead": traffic_ahead,
            "traffic_behind": traffic_behind,
            "gap_to_traffic_ahead_sec": traffic_ahead[0]["delta_sec"] if traffic_ahead else 99.0
        }

    @staticmethod
    def evaluate_undercut_threat(
        leader_car: Dict[str, Any],
        chaser_car: Dict[str, Any],
        pit_loss_sec: float,
        fresh_tyre_delta_sec: float = 1.8
    ) -> Dict[str, Any]:
        """
        Calculates if chaser can undercut the car ahead.
        Condition: Gap < Fresh tyre pace advantage on out-lap - In-lap delta.
        """
        gap_sec = chaser_car.get("interval_ahead", 1.5)
        if gap_sec <= 0:
            gap_sec = abs(leader_car.get("spline_position", 0.0) - chaser_car.get("spline_position", 0.0)) * 80.0

        # Undercut window is critical when gap < 2.5 seconds
        threat_score = max(0.0, min(10.0, (2.5 - gap_sec) * 4.0))
        is_threat = gap_sec <= fresh_tyre_delta_sec + 0.3

        return {
            "gap_sec": round(gap_sec, 2),
            "threat_score": round(threat_score, 1),
            "is_undercut_threat": is_threat,
            "recommended_action": "COVER_PIT_NOW" if is_threat else "MAINTAIN_PACE"
        }
