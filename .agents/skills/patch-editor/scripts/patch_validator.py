#!/usr/bin/env python3
"""
patch_validator.py
Validates dual-file byte synchronicity and Lua syntax integrity before committing.
"""

import os
import subprocess
import sys

def check_single_file_entry():
    f_main = "Ultimate-AI-Grand-Prix-Pro.lua"
    
    if not os.path.exists(f_main):
        print(f"[FAIL] Missing main entry file: {f_main}")
        return False
        
    root_lua = [f for f in os.listdir(".") if f.endswith(".lua")]
    if root_lua != [f_main]:
        extra = [f for f in root_lua if f != f_main]
        print(f"[FAIL] Only single entry file '{f_main}' allowed in root. Found extra: {extra}")
        return False
        
    size = os.path.getsize(f_main)
    print(f"[PASS] Single authoritative entry file '{f_main}' verified ({size} bytes).")
    return True

def run_tests():
    cmd = [
        sys.executable, "-c",
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
    ok_entry = check_single_file_entry()
    ok_test = run_tests()
    if ok_entry and ok_test:
        print("[SUCCESS] All patch verification gates passed.")
        sys.exit(0)
    else:
        print("[FAILURE] Patch verification gate failed.")
        sys.exit(1)

if __name__ == "__main__":
    main()
