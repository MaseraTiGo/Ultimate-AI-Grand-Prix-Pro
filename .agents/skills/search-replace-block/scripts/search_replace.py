#!/usr/bin/env python3
"""
search_replace.py
Precise search and replace block matcher.
"""

import argparse
import sys

def apply_replacement(filepath, search_block, replace_block, dry_run=False):
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
        
    occurrences = content.count(search_block)
    if occurrences == 0:
        print(f"[ERROR] Target block not found in {filepath}!")
        return False
    elif occurrences > 1:
        print(f"[ERROR] Target block appears {occurrences} times in {filepath}. Ambiguous match!")
        return False
        
    new_content = content.replace(search_block, replace_block, 1)
    if dry_run:
        print(f"[DRY RUN] Search block matched uniquely in {filepath}. Would replace successfully.")
        return True
        
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"[SUCCESS] Successfully replaced block in {filepath}.")
    return True

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True)
    parser.add_argument("--search", required=True)
    parser.add_argument("--replace", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    
    ok = apply_replacement(args.file, args.search, args.replace, args.dry_run)
    sys.exit(0 if ok else 1)
