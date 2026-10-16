"""
PySide6 Pro Timing Tower & Live Telemetry Table
===============================================
Displays full field leaderboard with:
- Driver Name & Position
- Live Gap to Leader / Interval Ahead
- Best & Last Lap Times
- Compound Badge + Stint Age
- 4-Wheel Wear % (with Fog of War N/A masking for rival cars)
- Exact Fuel / Fuel Delta (with Fog of War N/A masking)
- Pit Stop Count & In-Pit Indicator
"""

from typing import Dict, Any, List, Optional
from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QTableWidget, QTableWidgetItem, QHeaderView
)
from PySide6.QtGui import QColor, QFont


class TimingTowerWidget(QWidget):
    """High-density live timing table with Fog of War handling."""

    car_selected = Signal(int) # Emits car_index when clicked

    COL_POS = 0
    COL_NAME = 1
    COL_GAP = 2
    COL_INT = 3
    COL_LAST_LAP = 4
    COL_BEST_LAP = 5
    COL_TYRE = 6
    COL_WEAR = 7
    COL_FUEL = 8
    COL_PITS = 9
    COL_STATUS = 10

    HEADERS = ["P", "DRIVER", "GAP", "INT", "LAST", "BEST", "TYRE", "WEAR (FL/FR/RL/RR)", "FUEL (L)", "PIT", "STATUS"]

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        self.table = QTableWidget()
        self.table.setColumnCount(len(self.HEADERS))
        self.table.setHorizontalHeaderLabels(self.HEADERS)
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(self.COL_NAME, QHeaderView.Stretch)
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.setSelectionMode(QTableWidget.SingleSelection)

        self.table.cellClicked.connect(self._on_row_clicked)
        layout.addWidget(self.table)

        self._row_to_car_idx: List[int] = []

    def update_grid(self, cars: List[Dict[str, Any]]) -> None:
        """Update leaderboard while sorting by position."""
        sorted_cars = sorted(cars, key=lambda c: c.get("p", c.get("position", 99)))
        self.table.setRowCount(len(sorted_cars))
        self._row_to_car_idx = []

        mono_font = QFont("Consolas", 9)

        for row, c in enumerate(sorted_cars):
            idx = c.get("i", c.get("car_index", 0))
            self._row_to_car_idx.append(idx)

            pos_str = str(c.get("p", c.get("position", row + 1)))
            name_str = c.get("n", c.get("driver_name", f"Driver #{idx}"))
            gap_sec = c.get("gl", c.get("gap_to_leader", 0.0))
            int_sec = c.get("ia", c.get("interval_ahead", 0.0))
            last_ms = c.get("ll", c.get("last_lap_ms", 0))
            best_ms = c.get("bl", c.get("best_lap_ms", 0))
            tc = c.get("tc", c.get("tyre_compound", "M"))
            ta = c.get("ta", c.get("tyre_age_laps", 0))
            wear_arr = c.get("w", c.get("tyre_wear"))
            fuel = c.get("fr", c.get("fuel_remaining"))
            pits = str(c.get("ps", c.get("pit_stops", 0)))

            # Status Flags
            flags = c.get("f", 0)
            in_pit = bool(flags & 1) or bool(flags & 2)
            retired = bool(flags & 64)
            status_str = "RETIRED" if retired else ("IN PIT" if in_pit else "TRACK")

            # Format timing
            gap_str = "LEADER" if row == 0 else f"+{gap_sec:.1f}s"
            int_str = "-" if row == 0 else f"+{int_sec:.1f}s"
            last_str = self._ms_to_laptime(last_ms)
            best_str = self._ms_to_laptime(best_ms)

            # Format Fog-of-War masked fields
            if wear_arr is None:
                wear_str = "--- / ---"
            else:
                wear_str = f"{int(wear_arr[0]*100)}% {int(wear_arr[1]*100)}% | {int(wear_arr[2]*100)}% {int(wear_arr[3]*100)}%"

            fuel_str = f"{fuel:.1f}L" if fuel is not None else "---"

            # Populate table items
            items = [
                (self.COL_POS, pos_str, Qt.AlignCenter),
                (self.COL_NAME, name_str, Qt.AlignLeft),
                (self.COL_GAP, gap_str, Qt.AlignRight),
                (self.COL_INT, int_str, Qt.AlignRight),
                (self.COL_LAST_LAP, last_str, Qt.AlignCenter),
                (self.COL_BEST_LAP, best_str, Qt.AlignCenter),
                (self.COL_TYRE, f"{tc} ({ta}L)", Qt.AlignCenter),
                (self.COL_WEAR, wear_str, Qt.AlignCenter),
                (self.COL_FUEL, fuel_str, Qt.AlignRight),
                (self.COL_PITS, pits, Qt.AlignCenter),
                (self.COL_STATUS, status_str, Qt.AlignCenter),
            ]

            for col, text, align in items:
                item = QTableWidgetItem(text)
                item.setFont(mono_font)
                item.setTextAlignment(align | Qt.AlignVCenter)

                # Color highlights
                if col == self.COL_STATUS:
                    if retired:
                        item.setForeground(QColor("#E53E3E"))
                    elif in_pit:
                        item.setForeground(QColor("#ED8936"))
                    else:
                        item.setForeground(QColor("#48BB78"))
                elif col == self.COL_TYRE:
                    if "SOFT" in tc or tc == "S":
                        item.setForeground(QColor("#E10600"))
                    elif "MED" in tc or tc == "M":
                        item.setForeground(QColor("#FFF200"))
                    elif "HARD" in tc or tc == "H":
                        item.setForeground(QColor("#E2E8F0"))

                self.table.setItem(row, col, item)

    def _ms_to_laptime(self, ms: int) -> str:
        if not ms or ms <= 0: return "-:--.---"
        mins = ms // 60000
        secs = (ms % 60000) / 1000.0
        return f"{mins}:{secs:06.3f}"

    def _on_row_clicked(self, row: int, col: int) -> None:
        if 0 <= row < len(self._row_to_car_idx):
            car_idx = self._row_to_car_idx[row]
            self.car_selected.emit(car_idx)
