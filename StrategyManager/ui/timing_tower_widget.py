"""
PySide6 Pro Leaderboard & Timing Tower Widget
==============================================
Faithful reproduction of HUD image leaderboard:
- Columns: P (Pos), CAR/DRIVER with national flag or team icon, GAP, INT, LAST, BEST, TYRE, WEAR spark bar
- Color coding:
  - Green / Purple laptime highlights
  - Tire badges: Soft (Red), Med (Yellow), Hard (White)
  - Mini wear horizontal spark bars for 4 tyres
  - Fog of war handling: displays '---' for rival teams
"""

import math
from typing import Dict, Any, List, Optional
from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QTableWidget, QTableWidgetItem, QHeaderView, QLabel, QHBoxLayout, QStyledItemDelegate
)
from PySide6.QtGui import QColor, QFont, QPainter, QBrush, QPen, QLinearGradient


# Pre-defined country flags emoji or ISO codes for visual flair
NATIONAL_FLAGS = ["🇮🇹", "🇳🇱", "🇮🇹", "🇦🇺", "🇩🇰", "🇳🇱", "🇪🇸", "🇺🇸", "🇬🇧", "🇯🇵", "🇫🇮", "🇲🇽", "🇨🇦", "🇩🇪", "🇧🇷", "🇫🇷"]


class WearSparkBarDelegate(QStyledItemDelegate):
    """Custom painter delegate to render 4-segment tyre wear sparklines."""

    def paint(self, painter: QPainter, option, index):
        wear_data = index.data(Qt.UserRole)
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing)

        rect = option.rect
        # Background
        painter.fillRect(rect, QColor("#0B0E14"))

        if wear_data is None or not isinstance(wear_data, (list, tuple)) or len(wear_data) < 4:
            # Masked / Fog of war
            painter.setPen(QColor("#3A4454"))
            painter.setFont(QFont("Consolas", 9))
            painter.drawText(rect, Qt.AlignCenter, "--- / ---")
            painter.restore()
            return

        # Draw 4 mini vertical wear bars or 1 consolidated sparkline
        # Width per bar
        pad_x = 8
        bar_w = 7
        spacing = 4
        total_w = 4 * bar_w + 3 * spacing
        start_x = rect.x() + (rect.width() - total_w) // 2
        max_h = rect.height() - 10

        for i in range(4):
            wear_ratio = max(0.0, min(1.0, float(wear_data[i])))
            # Wear: 1.0 = brand new (green), <0.5 = yellow, <0.25 = red
            h = int(max_h * wear_ratio)
            bx = start_x + i * (bar_w + spacing)
            by = rect.y() + (rect.height() - h) // 2

            if wear_ratio > 0.65:
                bar_color = QColor("#00E5FF")
            elif wear_ratio > 0.35:
                bar_color = QColor("#ECC94B")
            else:
                bar_color = QColor("#E53E3E")

            painter.fillRect(bx, by, bar_w, h, bar_color)

        painter.restore()


class TimingTowerWidget(QWidget):
    """Cyberpunk Pro Leaderboard with corner brackets and header metadata."""

    car_selected = Signal(int) # Emits car_index

    COL_POS = 0
    COL_NUM = 1
    COL_DRIVER = 2
    COL_GAP = 3
    COL_INT = 4
    COL_LAST = 5
    COL_BEST = 6
    COL_TYRE = 7
    COL_WEAR = 8

    HEADERS = [
        "P", "CAR", "车手 / DRIVER", "GAP (间距)", "INT (前车)", "LAST (上一圈)", "BEST (最快)", "TYRE", "WEAR (磨损)"
    ]

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(6)

        # Header Title Bar
        header_row = QHBoxLayout()
        header_row.setContentsMargins(4, 2, 4, 2)

        self.lbl_title = QLabel("LEADERBOARD")
        self.lbl_title.setStyleSheet("color: #00E5FF; font-weight: 900; font-size: 13px; letter-spacing: 1px;")
        header_row.addWidget(self.lbl_title)

        header_row.addStretch()

        self.lbl_corner = QLabel("≡ LIVE TELEMETRY")
        self.lbl_corner.setStyleSheet("color: #4A5568; font-size: 9px; font-weight: bold; font-family: 'Consolas';")
        header_row.addWidget(self.lbl_corner)

        layout.addLayout(header_row)

        # Table
        self.table = QTableWidget()
        self.table.setColumnCount(len(self.HEADERS))
        self.table.setHorizontalHeaderLabels(self.HEADERS)
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.setSelectionMode(QTableWidget.SingleSelection)
        self.table.setShowGrid(False)

        # Column widths
        h_header = self.table.horizontalHeader()
        h_header.setSectionResizeMode(self.COL_POS, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_NUM, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_DRIVER, QHeaderView.Stretch)
        h_header.setSectionResizeMode(self.COL_GAP, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_INT, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_LAST, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_BEST, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_TYRE, QHeaderView.ResizeToContents)
        h_header.setSectionResizeMode(self.COL_WEAR, QHeaderView.ResizeToContents)

        # Custom delegate for Wear bar
        self.wear_delegate = WearSparkBarDelegate(self.table)
        self.table.setItemDelegateForColumn(self.COL_WEAR, self.wear_delegate)

        self.table.cellClicked.connect(self._on_row_clicked)
        layout.addWidget(self.table)

        self._row_to_car_idx: List[int] = []

    def update_grid(self, cars: List[Dict[str, Any]]) -> None:
        sorted_cars = sorted(cars, key=lambda c: c.get("p", c.get("position", 99)))
        self.table.setRowCount(len(sorted_cars))
        self._row_to_car_idx = []

        mono_font = QFont("Consolas", 10, QFont.Bold)

        for row, c in enumerate(sorted_cars):
            idx = c.get("i", c.get("car_index", row))
            self._row_to_car_idx.append(idx)

            pos = c.get("p", c.get("position", row + 1))
            name = c.get("n", c.get("driver_name", f"RIVI"))
            gap_sec = c.get("gl", c.get("gap_to_leader", 0.0))
            int_sec = c.get("ia", c.get("interval_ahead", 0.0))
            last_ms = c.get("ll", c.get("last_lap_ms", 0))
            best_ms = c.get("bl", c.get("best_lap_ms", 0))
            tc = c.get("tc", c.get("tyre_compound", "M"))
            wear_arr = c.get("w", c.get("tyre_wear"))

            # Visual national flag flair
            flag_emoji = NATIONAL_FLAGS[idx % len(NATIONAL_FLAGS)]

            # Formats
            gap_str = "-" if row == 0 else f"+{gap_sec:.3f}"
            int_str = "-" if row == 0 else f"+{int_sec:.3f}"
            last_str = self._format_laptime(last_ms)
            best_str = self._format_laptime(best_ms)

            # Col 0: Pos
            it_pos = QTableWidgetItem(str(pos))
            it_pos.setTextAlignment(Qt.AlignCenter)
            it_pos.setFont(mono_font)
            if row == 0:
                it_pos.setForeground(QColor("#00F59B"))
            else:
                it_pos.setForeground(QColor("#E2E8F0"))
            self.table.setItem(row, self.COL_POS, it_pos)

            # Col 1: Car #
            it_num = QTableWidgetItem(str(idx + 1))
            it_num.setTextAlignment(Qt.AlignCenter)
            it_num.setFont(mono_font)
            it_num.setForeground(QColor("#00E5FF"))
            self.table.setItem(row, self.COL_NUM, it_num)

            # Col 2: Driver with flag
            it_driver = QTableWidgetItem(f"{flag_emoji}  {name}")
            it_driver.setTextAlignment(Qt.AlignLeft | Qt.AlignVCenter)
            it_driver.setFont(QFont("Segoe UI", 9, QFont.Bold))
            it_driver.setForeground(QColor("#FFFFFF"))
            self.table.setItem(row, self.COL_DRIVER, it_driver)

            # Col 3: GAP
            it_gap = QTableWidgetItem(gap_str)
            it_gap.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
            it_gap.setFont(mono_font)
            it_gap.setForeground(QColor("#A0AEC0"))
            self.table.setItem(row, self.COL_GAP, it_gap)

            # Col 4: INT
            it_int = QTableWidgetItem(int_str)
            it_int.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
            it_int.setFont(mono_font)
            it_int.setForeground(QColor("#A0AEC0"))
            self.table.setItem(row, self.COL_INT, it_int)

            # Col 5: LAST
            it_last = QTableWidgetItem(last_str)
            it_last.setTextAlignment(Qt.AlignCenter)
            it_last.setFont(mono_font)
            it_last.setForeground(QColor("#EDF2F7"))
            self.table.setItem(row, self.COL_LAST, it_last)

            # Col 6: BEST (Purple for fastest, green for personal best)
            it_best = QTableWidgetItem(best_str)
            it_best.setTextAlignment(Qt.AlignCenter)
            it_best.setFont(mono_font)
            if row == 0:
                it_best.setForeground(QColor("#00E5FF")) # Fastest cyan/purple
            else:
                it_best.setForeground(QColor("#48BB78"))
            self.table.setItem(row, self.COL_BEST, it_best)

            # Col 7: TYRE badge
            tyre_label = "🔴 S" if ("S" in tc or "SOFT" in tc) else ("🟡 M" if ("M" in tc or "MED" in tc) else "⚪ H")
            it_tyre = QTableWidgetItem(tyre_label)
            it_tyre.setTextAlignment(Qt.AlignCenter)
            it_tyre.setFont(QFont("Segoe UI", 9, QFont.Bold))
            if "S" in tc or "SOFT" in tc:
                it_tyre.setForeground(QColor("#FF4D4D"))
            elif "M" in tc or "MED" in tc:
                it_tyre.setForeground(QColor("#FFD700"))
            else:
                it_tyre.setForeground(QColor("#E2E8F0"))
            self.table.setItem(row, self.COL_TYRE, it_tyre)

            # Col 8: WEAR (stored in UserRole for delegate)
            it_wear = QTableWidgetItem()
            it_wear.setData(Qt.UserRole, wear_arr)
            self.table.setItem(row, self.COL_WEAR, it_wear)

            self.table.setRowHeight(row, 26)

    def _format_laptime(self, ms: int) -> str:
        if ms <= 0:
            return "---.---"
        total_sec = ms / 1000.0
        if total_sec < 60.0:
            return f"{total_sec:.3f}"
        m = int(total_sec // 60)
        s = total_sec % 60
        return f"{m}:{s:06.3f}"

    def _on_row_clicked(self, row: int, col: int) -> None:
        if 0 <= row < len(self._row_to_car_idx):
            self.car_selected.emit(self._row_to_car_idx[row])
