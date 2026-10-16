"""
PySide6 Stint Planner & Pit Window Gantt Chart
==============================================
Faithful reproduction of HUD Stint Gantt:
- Top selector buttons: PLAN A (2-Stop), PLAN B (1-Stop), PLAN C (Sprint)
- Chinese subheader: 轮胎寿命甘特图 (Tyre Life Gantt)
- Stint bars: SOFT (L1-18), MED (L19-36), HARD (L37-50)
- Neon blue vertical needle cursor showing current lap (e.g. L12) with laser light particles
- Horizontal lap scale markers (L10, 6, 12, 19, 36, 47, 50)
"""

from typing import Dict, Any, List, Optional
from PySide6.QtCore import Qt, QRectF, QPointF
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel, QGroupBox
)
from PySide6.QtGui import (
    QPainter, QColor, QFont, QPen, QBrush, QLinearGradient
)


class StintGanttWidget(QWidget):
    """Custom QPainter canvas reproducing HUD stint gantt timeline."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setMinimumHeight(130)
        self.total_laps = 50
        self.current_lap = 12
        self.active_plan = "PLAN_A"

        self.stints: List[tuple] = [
            (1, 18, "SOFT", QColor("#B82424")),
            (19, 36, "MED", QColor("#B8860B")),
            (37, 50, "HARD", QColor("#5A6A7E")),
        ]
        self.undercut_alert = False

    def set_plan(self, plan_name: str, total_laps: int, current_lap: int) -> None:
        self.active_plan = plan_name
        self.total_laps = max(10, total_laps)
        self.current_lap = min(self.total_laps, max(1, current_lap))

        if plan_name == "PLAN_A":
            p1 = int(self.total_laps * 0.36)
            p2 = int(self.total_laps * 0.72)
            self.stints = [
                (1, p1, "SOFT", QColor("#B82424")),
                (p1 + 1, p2, "MED", QColor("#B8860B")),
                (p2 + 1, self.total_laps, "HARD", QColor("#5A6A7E")),
            ]
        elif plan_name == "PLAN_B":
            p1 = int(self.total_laps * 0.48)
            self.stints = [
                (1, p1, "MED", QColor("#B8860B")),
                (p1 + 1, self.total_laps, "HARD", QColor("#5A6A7E")),
            ]
        elif plan_name == "PLAN_C":
            p1 = int(self.total_laps * 0.28)
            p2 = int(self.total_laps * 0.58)
            self.stints = [
                (1, p1, "SOFT", QColor("#B82424")),
                (p1 + 1, p2, "SOFT", QColor("#B82424")),
                (p2 + 1, self.total_laps, "MED", QColor("#B8860B")),
            ]
        self.update()

    def set_undercut_alert(self, active: bool) -> None:
        self.undercut_alert = active
        self.update()

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        painter.fillRect(self.rect(), QColor("#090C12"))

        w = self.width() - 40
        h = self.height()
        ox = 20
        oy = 28
        bar_h = 44

        if self.total_laps <= 0 or w <= 50:
            return

        lap_w = w / float(self.total_laps)

        # 1. Chinese Subtitle: 轮胎寿命甘特图
        sub_font = QFont("Microsoft YaHei", 8, QFont.Bold)
        painter.setFont(sub_font)
        painter.setPen(QColor("#718096"))
        painter.drawText(ox, oy - 10, "轮胎寿命甘特图")

        # 2. Render Stint Chevron Bars
        font_main = QFont("Segoe UI", 9, QFont.Bold)
        font_sub = QFont("Consolas", 7)

        for i, (start, end, comp, color) in enumerate(self.stints):
            sx = ox + (start - 1) * lap_w
            sw = max(4.0, (end - start + 1) * lap_w)
            rect = QRectF(sx, oy, sw, bar_h)

            # Gradient filling
            grad = QLinearGradient(sx, oy, sx + sw, oy)
            grad.setColorAt(0.0, color)
            grad.setColorAt(1.0, color.darker(130))

            painter.setBrush(QBrush(grad))
            painter.setPen(QPen(QColor("#101520"), 1))

            # Rounded or angled stint block
            painter.drawRoundedRect(rect, 4, 4)

            # Stint Label (e.g. SOFT \n (L1-18))
            painter.setPen(QColor("#FFFFFF"))
            painter.setFont(font_main)
            painter.drawText(QRectF(sx, oy + 6, sw, 16), Qt.AlignCenter, comp)

            painter.setPen(QColor("#E2E8F0"))
            painter.setFont(font_sub)
            painter.drawText(QRectF(sx, oy + 24, sw, 14), Qt.AlignCenter, f"(L{start}-{end})")

        # 3. Horizontal Lap Ruler
        ruler_y = oy + bar_h + 16
        painter.setPen(QPen(QColor("#2D3748"), 1))
        painter.drawLine(ox, ruler_y, ox + w, ruler_y)

        # Scale tick marks (0, 10, 20, 30, 40, 50)
        tick_font = QFont("Consolas", 8)
        painter.setFont(tick_font)
        painter.setPen(QColor("#718096"))

        step_ticks = 10 if self.total_laps >= 30 else 5
        for l in range(0, self.total_laps + 1, step_ticks):
            lx = ox + l * lap_w
            painter.drawLine(int(lx), ruler_y, int(lx), ruler_y + 4)
            painter.drawText(QRectF(lx - 15, ruler_y + 6, 30, 14), Qt.AlignCenter, str(l))

        # 4. Current Lap Laser Needle Cursor (Glowing Cyan Line)
        cur_x = ox + (self.current_lap - 1) * lap_w
        glow_pen = QPen(QColor(0, 229, 255, 60), 6)
        painter.setPen(glow_pen)
        painter.drawLine(int(cur_x), oy - 6, int(cur_x), ruler_y + 12)

        laser_pen = QPen(QColor("#00E5FF"), 2)
        painter.setPen(laser_pen)
        painter.drawLine(int(cur_x), oy - 8, int(cur_x), ruler_y + 14)

        # Neon Badge tag e.g. "L12" at bottom of needle
        badge_w = 26
        badge_h = 16
        badge_rect = QRectF(cur_x - badge_w / 2, ruler_y + 2, badge_w, badge_h)
        painter.setBrush(QBrush(QColor("#00E5FF")))
        painter.setPen(Qt.NoPen)
        painter.drawRoundedRect(badge_rect, 3, 3)

        painter.setPen(QColor("#000000"))
        painter.setFont(QFont("Consolas", 8, QFont.Bold))
        painter.drawText(badge_rect, Qt.AlignCenter, f"L{self.current_lap}")


class StintPlannerPanel(QWidget):
    """Panel wrapper matching STINT PLANNER _ PIT WINDOW GANTT header and Plan buttons."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(6, 6, 6, 6)
        layout.setSpacing(6)

        # Header Title
        title_row = QHBoxLayout()
        self.lbl_title = QLabel("STINT PLANNER _ PIT WINDOW GANTT")
        self.lbl_title.setStyleSheet("color: #00E5FF; font-weight: 800; font-size: 11px; letter-spacing: 0.8px;")
        title_row.addWidget(self.lbl_title)
        title_row.addStretch()
        layout.addLayout(title_row)

        # Plan Selectors: PLAN A (2-Stop) | PLAN B (1-Stop) | PLAN C (Sprint)
        btn_row = QHBoxLayout()
        btn_row.setSpacing(8)

        self.btn_plan_a = QPushButton("PLAN A (2-Stop)")
        self.btn_plan_b = QPushButton("PLAN B (1-Stop)")
        self.btn_plan_c = QPushButton("PLAN C (Sprint)")

        for b in [self.btn_plan_a, self.btn_plan_b, self.btn_plan_c]:
            b.setCheckable(True)
            b.setStyleSheet("""
                QPushButton {
                    background-color: #0E131C;
                    border: 1px solid #1C2636;
                    border-radius: 4px;
                    color: #A0AEC0;
                    padding: 5px 12px;
                    font-size: 11px;
                    font-weight: 700;
                }
                QPushButton:checked {
                    background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 #132E42, stop:1 #0C1B27);
                    border: 1px solid #00E5FF;
                    color: #00E5FF;
                }
            """)

        self.btn_plan_a.setChecked(True)

        self.btn_plan_a.clicked.connect(lambda: self._select_plan("PLAN_A"))
        self.btn_plan_b.clicked.connect(lambda: self._select_plan("PLAN_B"))
        self.btn_plan_c.clicked.connect(lambda: self._select_plan("PLAN_C"))

        btn_row.addWidget(self.btn_plan_a)
        btn_row.addWidget(self.btn_plan_b)
        btn_row.addWidget(self.btn_plan_c)
        layout.addLayout(btn_row)

        # Gantt Canvas
        self.gantt = StintGanttWidget()
        layout.addWidget(self.gantt)

    def _select_plan(self, plan: str) -> None:
        self.btn_plan_a.setChecked(plan == "PLAN_A")
        self.btn_plan_b.setChecked(plan == "PLAN_B")
        self.btn_plan_c.setChecked(plan == "PLAN_C")
        self.gantt.set_plan(plan, self.gantt.total_laps, self.gantt.current_lap)
