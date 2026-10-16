"""
Industrial Dark-Mode Telemetry Stylesheet (#0F1115)
===================================================
High-contrast FIA Pit Wall styling for PySide6 desktop suite.
"""

PITWALL_STYLE = """
QWidget {
    background-color: #0F1115;
    color: #E0E4EB;
    font-family: "Segoe UI", "Roboto", "Consolas", monospace;
    font-size: 13px;
}

QTabWidget::pane {
    border: 1px solid #1E232B;
    background-color: #12151B;
}

QTabBar::tab {
    background-color: #161A22;
    color: #8C93A0;
    padding: 8px 18px;
    font-weight: bold;
    border: 1px solid #1E232B;
    border-bottom: none;
    margin-right: 2px;
}

QTabBar::tab:selected {
    background-color: #1F2430;
    color: #00E5FF;
    border-top: 2px solid #00E5FF;
}

QTabBar::tab:hover {
    color: #FFFFFF;
}

QGroupBox {
    border: 1px solid #252B36;
    border-radius: 4px;
    margin-top: 14px;
    padding-top: 14px;
    font-weight: bold;
    color: #00E5FF;
}

QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    left: 10px;
    padding: 0 4px;
    background-color: #0F1115;
}

QTableWidget {
    background-color: #12151B;
    gridline-color: #1F2430;
    border: 1px solid #1E232B;
    selection-background-color: #263345;
    selection-color: #FFFFFF;
    font-family: "Consolas", monospace;
    font-size: 12px;
}

QHeaderView::section {
    background-color: #181C24;
    color: #8C93A0;
    padding: 6px;
    border: 1px solid #1E232B;
    font-weight: bold;
}

QPushButton {
    background-color: #1A202C;
    border: 1px solid #2D3748;
    border-radius: 4px;
    color: #E2E8F0;
    padding: 6px 14px;
    font-weight: bold;
}

QPushButton:hover {
    background-color: #2D3748;
    border-color: #4A5568;
    color: #FFFFFF;
}

QPushButton:pressed {
    background-color: #171923;
}

QPushButton:disabled {
    background-color: #12151B;
    border-color: #1E232B;
    color: #4A5568;
}

/* Priority Action Buttons */
QPushButton#btn_box {
    background-color: #742A2A;
    border-color: #E53E3E;
    color: #FFF5F5;
}

QPushButton#btn_box:hover {
    background-color: #9B2C2C;
}

QPushButton#btn_push {
    background-color: #276749;
    border-color: #38A169;
    color: #F0FFF4;
}

QPushButton#btn_push:hover {
    background-color: #2F855A;
}

QPushButton#btn_save {
    background-color: #2B6CB0;
    border-color: #3182CE;
    color: #EBF8FF;
}

QPushButton#btn_save:hover {
    background-color: #2C5282;
}

QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox {
    background-color: #161A22;
    border: 1px solid #2D3748;
    border-radius: 3px;
    color: #E2E8F0;
    padding: 4px 8px;
    font-family: "Consolas", monospace;
}

QLineEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus, QComboBox:focus {
    border-color: #00E5FF;
}

QTextEdit, QPlainTextEdit {
    background-color: #0B0D11;
    border: 1px solid #1E232B;
    color: #00FF66;
    font-family: "Consolas", monospace;
    font-size: 11px;
}

QScrollBar:vertical {
    border: none;
    background: #0F1115;
    width: 8px;
    margin: 0;
}

QScrollBar::handle:vertical {
    background: #2D3748;
    min-height: 20px;
    border-radius: 4px;
}

QScrollBar::handle:vertical:hover {
    background: #4A5568;
}

QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
    height: 0px;
}
"""
