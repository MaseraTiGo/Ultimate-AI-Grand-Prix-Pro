#!/usr/bin/env python3
"""
diff_ripper.py
Inspects git diff and rips through the codebase to map downstream callers and references.
"""

import os
import re
import subprocess
import sys

def get_git_diff():
    res = subprocess.run(["git", "diff", "HEAD~1"], capture_output=True, text=True)
    if res.returncode == 0 and res.stdout.strip():
        return res.stdout
    res2 = subprocess.run(["git", "diff"], capture_output=True, text=True)
    return res2.stdout if res2.returncode == 0 else ""

def extract_modified_symbols(diff_text):
    symbols = set()
    for line in diff_text.splitlines():
        if line.startswith("+") or line.startswith("-"):
            if line.startswith("+++") or line.startswith("---"):
                continue
            matches = re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]+)\b', line)
            for m in matches:
                symbols.add(m)
    return sorted(symbols)

def main():
    print("=" * 60)
    print("  DIFF-AWARE CODE SEARCHER & BLAST RADIUS RIPPER")
    print("=" * 60)
    diff = get_git_diff()
    if not diff:
        print("[INFO] No git diff found against HEAD~1 or working tree.")
        return
        
    symbols = extract_modified_symbols(diff)
    print(f"[FOUND] {len(symbols)} modified symbol references:")
    for s in symbols[:20]:
        print(f"  * {s}")
    if len(symbols) > 20:
        print(f"  ... and {len(symbols) - 20} more.")

if __name__ == "__main__":
    main()
