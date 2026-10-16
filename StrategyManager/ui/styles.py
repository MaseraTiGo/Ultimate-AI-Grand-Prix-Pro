"""
Cyberpunk / Industrial F1 Telemetry QSS Stylesheet
===================================================
Pixel-faithful recreation of the HUD UI design:
- Dark navy/cyan cyber palette (#080A0F, #0E121A, #141A24)
- Neon cyan accents (#00E5FF) and laser glow borders
- Pill badge buttons, F1 flag badges, compound badges
- High-contrast typography with monospace numeric support
"""

PITWALL_STYLE = """
/* Base Application Window */
QMainWindow, QWidget {
    background-color: #080A0F;
    color: #CFD7E6;
    font-family: "Segoe UI", -apple-system, "Roboto", "Microsoft YaHei", sans-serif;
    font-size: 12px;
}

/* ScrollBars */
QScrollBar:vertical {
    background: #0A0D14;
    width: 6px;
    margin: 0px;
}
QScrollBar::handle:vertical {
    background: #1F2838;
    min-height: 20px;
    border-radius: 3px;
}
QScrollBar::handle:vertical:hover {
    background: #00E5FF;
}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
    height: 0px;
}
QScrollBar:horizontal {
    background: #0A0D14;
    height: 6px;
    margin: 0px;
}
QScrollBar::handle:horizontal {
    background: #1F2838;
    min-width: 20px;
    border-radius: 3px;
}

/* Tabs */
QTabWidget::pane {
    border: 1px solid #141A24;
    background-color: #0A0D13;
    border-radius: 4px;
}

QTabBar::tab {
    background-color: #0E131C;
    color: #728096;
    padding: 7px 18px;
    font-weight: 700;
    font-size: 11px;
    letter-spacing: 0.5px;
    border: 1px solid #18202D;
    border-bottom: none;
    border-top-left-radius: 4px;
    border-top-right-radius: 4px;
    margin-right: 4px;
}

QTabBar::tab:selected {
    background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 #122133, stop:1 #0A1017);
    color: #00E5FF;
    border: 1px solid #00E5FF;
    border-bottom: 2px solid #00E5FF;
}

QTabBar::tab:hover:!selected {
    color: #E2E8F0;
    background-color: #151D2A;
}

/* Cyber Box Containers */
QGroupBox {
    border: 1px solid #16202E;
    border-radius: 6px;
    background-color: #0C1017;
    margin-top: 22px;
    padding-top: 14px;
    padding-bottom: 8px;
    padding-left: 8px;
    padding-right: 8px;
    font-weight: 800;
    font-size: 11px;
    color: #00E5FF;
    letter-spacing: 0.8px;
}

QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 14px;
    top: 4px;
    padding: 0 6px;
    background-color: #080A0F;
}

/* Tables */
QTableWidget {
    background-color: #0B0E14;
    gridline-color: #121822;
    border: 1px solid #141D2A;
    border-radius: 4px;
    selection-background-color: #142438;
    selection-color: #FFFFFF;
    font-family: "Consolas", "Courier New", monospace;
    font-size: 11px;
}

QHeaderView::section {
    background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 #111722, stop:1 #0C1017);
    color: #6C7A90;
    padding: 5px 8px;
    border: none;
    border-bottom: 1px solid #182333;
    border-right: 1px solid #121822;
    font-weight: 700;
    font-size: 10px;
    letter-spacing: 0.5px;
}

/* Inputs & Combos */
QComboBox, QSpinBox, QDoubleSpinBox, QLineEdit {
    background-color: #0E131C;
    border: 1px solid #1A2433;
    border-radius: 4px;
    color: #E2E8F0;
    padding: 5px 10px;
    font-family: "Consolas", monospace;
    font-size: 11px;
}

QComboBox:hover, QSpinBox:hover, QLineEdit:hover {
    border-color: #00E5FF;
}

QComboBox::drop-down {
    border: none;
    width: 20px;
}

QComboBox::down-arrow {
    image: none;
    border-left: 4px solid transparent;
    border-right: 4px solid transparent;
    border-top: 5px solid #00E5FF;
    margin-right: 6px;
}

QComboBox QAbstractItemView {
    background-color: #0E131C;
    border: 1px solid #00E5FF;
    selection-background-color: #14273E;
    color: #FFFFFF;
}

/* Generic Buttons */
QPushButton {
    background-color: #101620;
    border: 1px solid #1C2636;
    border-radius: 4px;
    color: #B2BDCD;
    padding: 7px 14px;
    font-weight: 700;
    font-size: 11px;
    letter-spacing: 0.5px;
}

QPushButton:hover {
    background-color: #17202E;
    border-color: #00E5FF;
    color: #FFFFFF;
}

QPushButton:pressed {
    background-color: #0B0F16;
}

QPushButton:disabled {
    background-color: #090C12;
    border-color: #121822;
    color: #3F4A5C;
}

/* Tactical Action Buttons (Right Sidebar) */
QPushButton#btn_box {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #6B1720, stop:1 #4A0E15);
    border: 1px solid #E53E3E;
    border-radius: 4px;
    color: #FFFFFF;
    font-weight: 900;
    font-size: 12px;
    padding: 10px;
    letter-spacing: 1px;
}
QPushButton#btn_box:hover {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #8E202C, stop:1 #6B1720);
    border-color: #FF5E5E;
}

QPushButton#btn_cancel_box {
    background: #111620;
    border: 1px solid #233145;
    border-radius: 4px;
    color: #A0AEC0;
    font-weight: 700;
    font-size: 11px;
    padding: 8px;
}
QPushButton#btn_cancel_box:hover {
    background: #1A2230;
    border-color: #CBD5E0;
    color: #FFFFFF;
}

QPushButton#btn_push {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #124A2E, stop:1 #0A331E);
    border: 1px solid #25D366;
    border-radius: 4px;
    color: #FFFFFF;
    font-weight: 800;
    font-size: 12px;
    padding: 9px;
    letter-spacing: 0.5px;
}
QPushButton#btn_push:hover {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #17633D, stop:1 #104C2D);
    border-color: #48BB78;
}

QPushButton#btn_save {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #113658, stop:1 #0B243B);
    border: 1px solid #00E5FF;
    border-radius: 4px;
    color: #FFFFFF;
    font-weight: 800;
    font-size: 12px;
    padding: 9px;
    letter-spacing: 0.5px;
}
QPushButton#btn_save:hover {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #164875, stop:1 #10385B);
    border-color: #63B3ED;
}

QPushButton#btn_tactical_neutral {
    background-color: #0E131C;
    border: 1px solid #1C2636;
    border-radius: 4px;
    color: #B2BDCD;
    font-weight: 700;
    font-size: 11px;
    padding: 8px;
}
QPushButton#btn_tactical_neutral:hover {
    background-color: #151D2A;
    border-color: #00E5FF;
    color: #FFFFFF;
}

/* Top Bar Pill Master Buttons */
QPushButton#btn_pill_on {
    background-color: #0B2219;
    border: 1px solid #00F59B;
    border-radius: 14px;
    color: #00F59B;
    font-weight: 800;
    font-size: 11px;
    padding: 4px 14px;
}
QPushButton#btn_pill_off {
    background-color: #1A1A24;
    border: 1px solid #4A5568;
    border-radius: 14px;
    color: #718096;
    font-weight: 800;
    font-size: 11px;
    padding: 4px 14px;
}

QPushButton#btn_pill_sc_normal {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #2E2006, stop:1 #1C1303);
    border: 1px solid #ECC94B;
    border-radius: 14px;
    color: #ECC94B;
    font-weight: 800;
    font-size: 11px;
    padding: 4px 14px;
}
QPushButton#btn_pill_sc_active {
    background: qlineargradient(x1:0, y1:0, x2:1, y2:0, stop:0 #D69E2E, stop:1 #975A16);
    border: 1px solid #ECC94B;
    border-radius: 14px;
    color: #000000;
    font-weight: 900;
    font-size: 11px;
    padding: 4px 14px;
}

QPushButton#btn_pill_locked {
    background-color: #2D1515;
    border: 1px solid #E53E3E;
    border-radius: 14px;
    color: #FC8181;
    font-weight: 800;
    font-size: 11px;
    padding: 4px 14px;
}
QPushButton#btn_pill_open {
    background-color: #0B2219;
    border: 1px solid #38A169;
    border-radius: 14px;
    color: #48BB78;
    font-weight: 800;
    font-size: 11px;
    padding: 4px 14px;
}

/* Status Bar */
QStatusBar {
    background-color: #06080C;
    color: #5A6678;
    border-top: 1px solid #101620;
    font-size: 10px;
    font-family: "Consolas", monospace;
}
"""
