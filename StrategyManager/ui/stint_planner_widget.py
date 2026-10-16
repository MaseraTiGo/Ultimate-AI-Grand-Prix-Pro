"""
PySide6 Stint Planner & Pit Window Gantt Chart
==============================================
Renders horizontal lap-by-lap stint visualization with:
- Target car pit window projection
- Interactive Plan A / Plan B / Plan C switching
- Dynamic Undercut / Overcut threat indicator
"""

from typing import Dict, Any, List, Optional
from PySide6.QtCore import Qt, QRectF
from PySide6.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel, QGroupBox
from PySide6.QtGui import QPainter, QColor, QFont, QPen, QBrush


class StintGanttWidget(QWidget):
    """Custom QPainter canvas rendering race lap horizontal Gantt bars."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setMinimumHeight(110)
        self.total_laps = 50
        self.current_lap = 12
        self.active_plan = "PLAN_A"

        # Stint configurations for active car: [(start_lap, end_lap, compound_code, color)]
        self.stints: List[tuple] = [
            (1, 18, "SOFT", QColor("#E10600")),
            (19, 36, "MED", QColor("#FFF200")),
            (37, 50, "HARD", QColor("#E2E8F0")),
        ]
        self.undercut_alert = False

    def set_plan(self, plan_name: str, total_laps: int, current_lap: int) -> None:
        self.active_plan = plan_name
        self.total_laps = max(10, total_laps)
        self.current_lap = min(self.total_laps, max(1, current_lap))

        if plan_name == "PLAN_A":
            # 2-Stop Soft -> Med -> Hard
            p1 = int(self.total_laps * 0.35)
            p2 = int(self.total_laps * 0.70)
            self.stints = [
                (1, p1, "SOFT", QColor("#E10600")),
                (p1 + 1, p2, "MED", QColor("#FFF200")),
                (p2 + 1, self.total_laps, "HARD", QColor("#E2E8F0")),
            ]
        elif plan_name == "PLAN_B":
            # 1-Stop Medium -> Hard
            p1 = int(self.total_laps * 0.48)
            self.stints = [
                (1, p1, "MED", QColor("#FFF200")),
                (p1 + 1, self.total_laps, "HARD", QColor("#E2E8F0")),
            ]
        elif plan_name == "PLAN_C":
            # Aggressive 3-Stop Sprint
            p1 = int(self.total_laps * 0.25)
            p2 = int(self.total_laps * 0.50)
            p3 = int(self.total_laps * 0.75)
            self.stints = [
                (1, p1, "SOFT", QColor("#E10600")),
                (p1 + 1, p2, "SOFT", QColor("#E10600")),
                (p2 + 1, p3, "MED", QColor("#FFF200")),
                (p3 + 1, self.total_laps, "SOFT", QColor("#E10600")),
            ]
        self.update()

    def set_undercut_alert(self, active: bool) -> None:
        self.undercut_alert = active
        self.update()

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        painter.fillRect(self.rect(), QColor("#12151B"))

        w = self.width() - 40
        h = self.height()
        ox = 20
        oy = 25
        bar_h = 32

        if self.total_laps <= 0 or w <= 50:
            return

        lap_width = w / float(self.total_laps)

        # Draw Stint Rectangles
        font = QFont("Consolas", 8, QFont.Bold)
        painter.setFont(font)

        for (start, end, comp, color) in self.stints:
            sx = ox + (start - 1) * lap_width
            sw = max(4.0, (end - start + 1) * lap_width)
            rect = QRectF(sx, oy, sw, bar_h)

            painter.setBrush(QBrush(color.darker(150)))
            painter.setPen(QPen(color, 2))
            painter.drawRoundedRect(rect, 4, 4)

            # Text Label
            painter.setPen(QColor("#FFFFFF"))
            label = f"{comp} (L{start}-{end})"
            painter.drawText(rect, Qt.AlignCenter, label)

        # Current Lap Cursor
        cur_x = ox + (self.current_lap - 1) * lap_width
        cursor_pen = QPen(QColor("#00E5FF"), 3)
        painter.setPen(cursor_pen)
        painter.drawLine(int(cur_x), int(oy - 8), int(cur_x), int(oy + bar_h + 8))

        # Current Lap Label
        painter.setPen(QColor("#00E5FF"))
        painter.drawText(int(cur_x - 15), int(oy - 12), f"L{self.current_lap}")

        # Undercut Alert Banner
        if self.undercut_alert:
            painter.setPen(QColor("#E53E3E"))
            painter.setFont(QFont("Consolas", 9, QFont.Bold))
            painter.drawText(int(ox), int(oy + bar_h + 24), "THREAT: CHASER ENTERED UNDERCUT WINDOW! COVER PIT STOP RECOMMENDED")


class StintPlannerPanel(QGroupBox):
    """Panel wrapper with Plan A/B/C selector buttons."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__("STINT PLANNER & PIT WINDOW GANTT", parent)
        layout = QVBoxLayout(self)

        top_bar = QHBoxLayout()
        self.btn_plan_a = QPushButton("PLAN A (2-Stop)")
        self.btn_plan_b = QPushButton("PLAN B (1-Stop)")
        self.btn_plan_c = QPushButton("PLAN C (Sprint)")

        self.btn_plan_a.clicked.connect(lambda: self.gantt.set_plan("PLAN_A", self.gantt.total_laps, self.gantt.current_lap))
        self.btn_plan_b.clicked.connect(lambda: self.gantt.set_plan("PLAN_B", self.gantt.total_laps, self.gantt.current_lap))
        self.btn_plan_c.clicked.connect(lambda: self.gantt.set_plan("PLAN_C", self.gantt.total_laps, self.gantt.current_lap))

        top_bar.addWidget(self.btn_plan_a)
        top_bar.addWidget(self.btn_plan_b)
        top_bar.addWidget(self.btn_plan_c)
        top_bar.addStretch()

        layout.addLayout(top_bar)

        self.gantt = StintGanttWidget()
        layout.addWidget(self.gantt)
