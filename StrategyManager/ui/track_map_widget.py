"""
PySide6 Real-Time Circuit Radar & Track Map Widget
==================================================
Faithful recreation of HUD image circuit visualizer:
- Neon cyan dual-contour racetrack ribbon with sector dividers (Sector 1 / 2 / 3)
- Rotating semi-transparent green/cyan scanning radar beam
- Sector markers (T1, T2, T3) and speed trap callouts
- Corner brackets for sci-fi telemetry framing
- Color-coded driver pills (M3, T1, G4, etc.)
- Ghost pit-out rejoin predictor
"""

import math
from typing import Dict, Any, List, Optional
from PySide6.QtCore import Qt, QRectF, QPointF, QTimer
from PySide6.QtWidgets import QWidget
from PySide6.QtGui import (
    QPainter, QPen, QColor, QBrush, QFont, QRadialGradient, QConicalGradient
)


class TrackMapWidget(QWidget):
    """Futuristic neon HUD circuit map with radar sweep effect."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setMinimumSize(380, 240)
        self.cars_data: List[Dict[str, Any]] = []
        self.selected_car_idx: int = -1
        self.ghost_rejoin_spline: Optional[float] = None
        self.yellow_flags: bool = False

        # Radar scan animation
        self.radar_angle: float = 0.0
        self.radar_timer = QTimer(self)
        self.radar_timer.timeout.connect(self._step_radar)
        self.radar_timer.start(35) # ~30 FPS radar sweep

    def _step_radar(self) -> None:
        self.radar_angle = (self.radar_angle + 1.8) % 360.0
        self.update()

    def update_telemetry(self, cars: List[Dict[str, Any]], selected_idx: int = -1, ghost_spline: Optional[float] = None) -> None:
        self.cars_data = cars
        self.selected_car_idx = selected_idx
        self.ghost_rejoin_spline = ghost_spline
        self.update()

    def set_yellow_flags(self, active: bool) -> None:
        self.yellow_flags = active
        self.update()

    def _spline_to_screen(self, s: float, cx: float, cy: float, rx: float, ry: float) -> QPointF:
        """Rounded rectangle / capsule racetrack formula matching UI image."""
        # 4 straight + curve segments
        angle = (s * 2.0 * math.pi) - (math.pi / 2.0)
        # Flattened oval track
        x = cx + rx * math.cos(angle)
        y = cy + ry * math.sin(angle)
        return QPointF(x, y)

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        w = self.width()
        h = self.height()
        rect = self.rect()

        # 1. Dark Cyber Background
        painter.fillRect(rect, QColor("#090C12"))

        # 2. Corner Bracket Guides (HUD Frame)
        bracket_pen = QPen(QColor("#253245"), 1.5)
        painter.setPen(bracket_pen)
        b_len = 14
        # Top-Left
        painter.drawLine(8, 8, 8 + b_len, 8)
        painter.drawLine(8, 8, 8, 8 + b_len)
        # Top-Right
        painter.drawLine(w - 8, 8, w - 8 - b_len, 8)
        painter.drawLine(w - 8, 8, w - 8, 8 + b_len)
        # Bottom-Left
        painter.drawLine(8, h - 8, 8 + b_len, h - 8)
        painter.drawLine(8, h - 8, 8, h - 8 - b_len)
        # Bottom-Right
        painter.drawLine(w - 8, h - 8, w - 8 - b_len, h - 8)
        painter.drawLine(w - 8, h - 8, w - 8, h - 8 - b_len)

        cx = w / 2.0
        cy = h / 2.0
        rx = max(20.0, (w / 2.0) - 55.0)
        ry = max(20.0, (h / 2.0) - 45.0)

        # 3. Rotating Radar Beam (Conical scanning wedge from center)
        painter.save()
        radar_rad = min(rx, ry) * 1.3
        radar_cone = QConicalGradient(cx, cy, -self.radar_angle)
        radar_cone.setColorAt(0.0, QColor(0, 229, 255, 60))
        radar_cone.setColorAt(0.12, QColor(0, 229, 255, 15))
        radar_cone.setColorAt(0.18, QColor(0, 229, 255, 0))
        radar_cone.setColorAt(1.0, QColor(0, 229, 255, 0))

        painter.setBrush(QBrush(radar_cone))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(QPointF(cx, cy), radar_rad, radar_rad)
        painter.restore()

        # Radar Crosshairs / Rings
        cross_pen = QPen(QColor("#141D2A"), 1, Qt.DashLine)
        painter.setPen(cross_pen)
        painter.drawLine(int(cx - rx * 0.9), int(cy), int(cx + rx * 0.9), int(cy))
        painter.drawLine(int(cx), int(cy - ry * 0.9), int(cx), int(cy + ry * 0.9))

        # 4. Multi-ribbon Track Outline (Outer glow + Dual lane)
        num_steps = 140
        spline_pts = [self._spline_to_screen(i / float(num_steps), cx, cy, rx, ry) for i in range(num_steps + 1)]

        # Outer Neon Glow
        glow_color = QColor("#D69E2E") if self.yellow_flags else QColor("#00E5FF")
        glow_pen = QPen(QColor(glow_color.red(), glow_color.green(), glow_color.blue(), 30), 12, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        painter.setPen(glow_pen)
        painter.setBrush(Qt.NoBrush)
        for i in range(len(spline_pts) - 1):
            painter.drawLine(spline_pts[i], spline_pts[i + 1])

        # Core Sharp Ribbon
        core_pen = QPen(glow_color, 2, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        painter.setPen(core_pen)
        for i in range(len(spline_pts) - 1):
            painter.drawLine(spline_pts[i], spline_pts[i + 1])

        # Inner Dotted Centerline
        dotted_pen = QPen(QColor("#1A3045"), 1, Qt.DotLine)
        painter.setPen(dotted_pen)
        for i in range(len(spline_pts) - 1):
            painter.drawLine(spline_pts[i], spline_pts[i + 1])

        # 5. Sector Callout Labels
        label_font = QFont("Consolas", 8, QFont.Bold)
        painter.setFont(label_font)
        painter.setPen(QColor("#5A6B82"))

        # "SECTOR 1 / 2 / 3" top and bottom
        painter.drawText(QRectF(cx - 80, cy - ry - 24, 160, 16), Qt.AlignCenter, "SECTOR 1 / 2 / 3")
        painter.drawText(QRectF(cx - 80, cy + ry + 10, 160, 16), Qt.AlignCenter, "SECTOR 1 / 2 / 3")

        # 6. Sector Checkpoint Markers (T1, T2, T3)
        marker_color = QColor("#00E5FF")
        for s_mark, text in [(0.25, "T1"), (0.50, "T2"), (0.75, "T3")]:
            pt = self._spline_to_screen(s_mark, cx, cy, rx, ry)
            painter.setBrush(QBrush(QColor("#0E1622")))
            painter.setPen(QPen(marker_color, 1))
            painter.drawEllipse(pt, 8, 8)
            painter.setPen(QColor("#00E5FF"))
            painter.drawText(QRectF(pt.x() - 8, pt.y() - 8, 16, 16), Qt.AlignCenter, text)

        # 7. Ghost Pit-Out Rejoin Predictor
        if self.ghost_rejoin_spline is not None:
            gpt = self._spline_to_screen(self.ghost_rejoin_spline, cx, cy, rx, ry)
            painter.setBrush(QBrush(QColor(0, 229, 255, 50)))
            painter.setPen(QPen(QColor("#00E5FF"), 2, Qt.DashLine))
            painter.drawEllipse(gpt, 11, 11)
            painter.setPen(QColor("#00E5FF"))
            painter.drawText(int(gpt.x() + 14), int(gpt.y() + 4), "GHOST PIT-OUT")

        # 8. Render All Cars with Cyber Badges (M3, T1, G4 etc.)
        car_font = QFont("Segoe UI", 7, QFont.Bold)
        painter.setFont(car_font)

        badge_colors = [
            QColor("#E53E3E"), # Red
            QColor("#ECC94B"), # Yellow
            QColor("#00E5FF"), # Cyan
            QColor("#B83280"), # Magenta
            QColor("#48BB78"), # Green
            QColor("#ED8936"), # Orange
            QColor("#9F7AEA"), # Purple
        ]

        for car in self.cars_data:
            c_idx = car.get("i", car.get("car_index", 0))
            s = car.get("s", car.get("spline_position", 0.0))
            pos = car.get("p", car.get("position", c_idx + 1))
            pt = self._spline_to_screen(s, cx, cy, rx, ry)

            is_selected = (c_idx == self.selected_car_idx)
            color = QColor("#00F59B") if is_selected else badge_colors[c_idx % len(badge_colors)]

            # Car circular pill badge
            rad = 8 if is_selected else 6.5
            painter.setBrush(QBrush(color))
            painter.setPen(QPen(QColor("#FFFFFF"), 1.5 if is_selected else 0.8))
            painter.drawEllipse(pt, rad, rad)

            # Center text inside pill (e.g. "M3", "T1", or car pos)
            label = f"{pos}"
            painter.setPen(QColor("#000000"))
            painter.drawText(QRectF(pt.x() - rad, pt.y() - rad, rad * 2, rad * 2), Qt.AlignCenter, label)
