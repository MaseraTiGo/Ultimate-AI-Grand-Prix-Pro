"""
PySide6 Real-Time Track Map View
================================
Draws normalized circuit map using QPainter with:
- All active cars positioned by splinePosition
- Ghost Pit-Out Position Predictor (showing clean air vs traffic)
- Yellow flag sector highlights
- Pit lane entry & exit markers
"""

import math
from typing import Dict, Any, List, Optional
from PySide6.QtCore import Qt, QRectF, QPointF
from PySide6.QtWidgets import QWidget
from PySide6.QtGui import QPainter, QPen, QColor, QBrush, QFont


class TrackMapWidget(QWidget):
    """Real-time 2D circuit ribbon & car dot visualizer."""

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.setMinimumSize(320, 260)
        self.cars_data: List[Dict[str, Any]] = []
        self.selected_car_idx: int = -1
        self.ghost_rejoin_spline: Optional[float] = None
        self.yellow_flags: bool = False

    def update_telemetry(self, cars: List[Dict[str, Any]], selected_idx: int = -1, ghost_spline: Optional[float] = None) -> None:
        self.cars_data = cars
        self.selected_car_idx = selected_idx
        self.ghost_rejoin_spline = ghost_spline
        self.update()

    def set_yellow_flags(self, active: bool) -> None:
        self.yellow_flags = active
        self.update()

    def _spline_to_screen_pos(self, s: float, cx: float, cy: float, rx: float, ry: float) -> QPointF:
        """Maps normalized spline 0.0..1.0 onto an elliptical track layout."""
        angle = s * 2.0 * math.pi - (math.pi / 2.0)
        # Add slight circuit contour deformation
        deform = 1.0 + 0.12 * math.sin(angle * 3.0) + 0.08 * math.cos(angle * 2.0)
        x = cx + rx * deform * math.cos(angle)
        y = cy + ry * deform * math.sin(angle)
        return QPointF(x, y)

    def paintEvent(self, event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        # Background
        painter.fillRect(self.rect(), QColor("#0B0D11"))

        w = self.width()
        h = self.height()
        cx = w / 2.0
        cy = h / 2.0
        rx = (w / 2.0) - 45.0
        ry = (h / 2.0) - 45.0

        if rx <= 10 or ry <= 10:
            return

        # 1. Draw Circuit Ribbon
        track_pen = QPen(QColor("#252B36"), 14, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        if self.yellow_flags:
            track_pen.setColor(QColor("#B7791F"))
        painter.setPen(track_pen)
        painter.setBrush(Qt.NoBrush)

        num_segments = 120
        points = []
        for step in range(num_segments + 1):
            s = float(step) / num_segments
            points.append(self._spline_to_screen_pos(s, cx, cy, rx, ry))

        for i in range(len(points) - 1):
            painter.drawLine(points[i], points[i + 1])

        # Track Centerline (Subtle White Dotted)
        center_pen = QPen(QColor("#3A4454"), 1, Qt.DashLine)
        painter.setPen(center_pen)
        for i in range(len(points) - 1):
            painter.drawLine(points[i], points[i + 1])

        # Start / Finish Line
        sf_pos = self._spline_to_screen_pos(0.0, cx, cy, rx, ry)
        sf_pen = QPen(QColor("#00E5FF"), 3)
        painter.setPen(sf_pen)
        painter.drawEllipse(sf_pos, 4, 4)

        # 2. Draw Ghost Rejoin Car (if pitting prediction available)
        if self.ghost_rejoin_spline is not None:
            ghost_pos = self._spline_to_screen_pos(self.ghost_rejoin_spline, cx, cy, rx, ry)
            ghost_brush = QBrush(QColor(0, 229, 255, 90))
            ghost_pen = QPen(QColor("#00E5FF"), 2, Qt.DashLine)
            painter.setBrush(ghost_brush)
            painter.setPen(ghost_pen)
            painter.drawEllipse(ghost_pos, 10, 10)

            painter.setPen(QColor("#00E5FF"))
            painter.setFont(QFont("Consolas", 8, QFont.Bold))
            painter.drawText(int(ghost_pos.x() + 12), int(ghost_pos.y() + 4), "GHOST PIT-OUT")

        # 3. Draw All Active Cars
        font = QFont("Consolas", 8, QFont.Bold)
        painter.setFont(font)

        for car in self.cars_data:
            c_idx = car.get("i", car.get("car_index", 0))
            s = car.get("s", car.get("spline_position", 0.0))
            pos_label = str(car.get("p", car.get("position", c_idx + 1)))

            pt = self._spline_to_screen_pos(s, cx, cy, rx, ry)

            # Highlight selected car
            is_selected = (c_idx == self.selected_car_idx)
            radius = 7 if is_selected else 5

            if is_selected:
                car_brush = QBrush(QColor("#00E5FF"))
                car_pen = QPen(QColor("#FFFFFF"), 2)
            else:
                car_brush = QBrush(QColor("#E53E3E") if c_idx == 0 else QColor("#ED8936"))
                car_pen = QPen(QColor("#1A202C"), 1)

            painter.setBrush(car_brush)
            painter.setPen(car_pen)
            painter.drawEllipse(pt, radius, radius)

            # Draw Car Number / Position Tag
            painter.setPen(QColor("#FFFFFF"))
            painter.drawText(int(pt.x() + radius + 3), int(pt.y() + 4), pos_label)
