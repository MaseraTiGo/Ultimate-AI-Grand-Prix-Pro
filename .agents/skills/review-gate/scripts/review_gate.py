#!/usr/bin/env python3
"""
review_gate.py
Static and dynamic code review gate.
"""

import os
import subprocess
import sys

def verify_agents_rules():
    print("[CHECK] Verifying AGENTS.md compliance...")
    # Check dual script sync
    f1 = "Ultimate AI Grand Prix Pro.lua"
    f2 = "Ultimate-AI-Grand-Prix-Pro.lua"
    if open(f1, "rb").read() != open(f2, "rb").read():
        print("  -> [FAIL] Entry scripts are not 100% byte identical!")
        return False
    print("  -> [PASS] Dual entry scripts 100% byte synchronized.")
    return True

def run_suite():
    print("[CHECK] Running regression suite...")
    cmd = [
        "python", "-c",
        "import lupa; from lupa import LuaRuntime; lua = LuaRuntime(unpack_returned_tuples=True); lua.execute(open('tests/test_grand_prix_pro.lua', 'r', encoding='utf-8').read())"
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"  -> [FAIL] Test suite failed:\n{res.stdout}\n{res.stderr}")
        return False
    print("  -> [PASS] Test suite passed cleanly.")
    return True

def main():
    print("=" * 60)
    print("  REVIEW-GATE QUALITY ASSURANCE CHECK")
    print("=" * 60)
    if verify_agents_rules() and run_suite():
        print("\n[VERDICT] PASS - Ready for integration.")
        sys.exit(0)
    else:
        print("\n[VERDICT] FAIL - Blocked by review gate.")
        sys.exit(1)

if __name__ == "__main__":
    main()
