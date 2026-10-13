#!/usr/bin/env python3
"""
patch_validator.py
Validates dual-file byte synchronicity and Lua syntax integrity before committing.
"""

import os
import subprocess
import sys

def check_dual_file_sync():
    f1 = "Ultimate AI Grand Prix Pro.lua"
    f2 = "Ultimate-AI-Grand-Prix-Pro.lua"
    
    if not os.path.exists(f1) or not os.path.exists(f2):
        print(f"[FAIL] Missing main files: {f1} or {f2}")
        return False
        
    b1 = open(f1, "rb").read()
    b2 = open(f2, "rb").read()
    
    if b1 != b2:
        print(f"[FAIL] Byte mismatch between '{f1}' and '{f2}'. Lengths: {len(b1)} vs {len(b2)}")
        return False
    print(f"[PASS] Dual main files are 100% byte-identical ({len(b1)} bytes).")
    return True

def run_tests():
    cmd = [
        "python", "-c",
        "import lupa; from lupa import LuaRuntime; lua = LuaRuntime(unpack_returned_tuples=True); lua.execute(open('tests/test_grand_prix_pro.lua', 'r', encoding='utf-8').read())"
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        if res.returncode == 0:
            print("[PASS] Full test suite passed.")
            return True
        else:
            print(f"[FAIL] Tests failed:\n{res.stdout}\n{res.stderr}")
            return False
    except Exception as e:
        print(f"[ERROR] Test runner exception: {e}")
        return False

def main():
    print("=" * 60)
    print("  PATCH-EDITOR INTEGRITY VALIDATOR")
    print("=" * 60)
    ok_sync = check_dual_file_sync()
    ok_test = run_tests()
    if ok_sync and ok_test:
        print("[SUCCESS] All patch verification gates passed.")
        sys.exit(0)
    else:
        print("[FAILURE] Patch verification gate failed.")
        sys.exit(1)

if __name__ == "__main__":
    main()
