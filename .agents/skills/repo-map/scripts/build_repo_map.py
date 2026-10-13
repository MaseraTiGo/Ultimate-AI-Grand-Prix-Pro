#!/usr/bin/env python3
"""
build_repo_map.py
Repository Map and Symbol Dependency Graph Generator.
Scans Lua codebase, extracts modules, dependencies, exports, and call graphs.
"""

import os
import re
import sys

def parse_lua_file(filepath):
    exports = []
    requires = []
    functions = []
    
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
        
    for i, line in enumerate(lines, 1):
        line_s = line.strip()
        # require patterns
        for m in re.finditer(r'require\s*\(?["\']([^"\']+)["\']\)?', line_s):
            req = m.group(1)
            if req not in requires:
                requires.append(req)
        # function definitions
        m_fn = re.match(r'^(?:local\s+)?function\s+([A-Za-z0-9_.:]+)\s*\(', line_s)
        if m_fn:
            fn_name = m_fn.group(1)
            functions.append((fn_name, i))
            if fn_name.startswith("M.") or fn_name.startswith("script."):
                exports.append((fn_name, i))
                
    return {
        "path": filepath,
        "requires": requires,
        "functions": functions,
        "exports": exports
    }

def main():
    root_dir = "."
    if len(sys.argv) > 1:
        root_dir = sys.argv[1]
        
    lua_files = []
    for root, dirs, files in os.walk(root_dir):
        if ".git" in root or ".agents" in root:
            continue
        for f in files:
            if f.endswith(".lua"):
                lua_files.append(os.path.normpath(os.path.join(root, f)))
                
    results = {}
    for lf in sorted(lua_files):
        results[lf] = parse_lua_file(lf)
        
    print("=" * 80)
    print("  ULTIMATE AI GRAND PRIX PRO - REPOSITORY MAP & SYMBOL GRAPH")
    print("=" * 80)
    
    for lf, data in results.items():
        print(f"\n[MODULE] {lf}")
        if data["requires"]:
            print(f"  -> Dependencies: {', '.join(data['requires'])}")
        if data["exports"]:
            print("  -> Exports / Public API:")
            for exp, line in data["exports"]:
                print(f"     L{line:03d}: {exp}")
        if not data["exports"] and data["functions"]:
            print(f"  -> Internal Functions: {len(data['functions'])} functions")

if __name__ == "__main__":
    main()
