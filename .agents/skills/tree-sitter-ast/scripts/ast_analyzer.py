#!/usr/bin/env python3
"""
ast_analyzer.py
AST and syntax structure analyzer for Lua files.
Inspects function signatures, control flows, and member accesses (e.g. car.xxx, physics.xxx, ac.xxx).
"""

import re
import sys

def analyze_lua_ast(filepath):
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
        
    functions = []
    ffi_member_accesses = set()
    physics_calls = set()
    
    for i, line in enumerate(lines, 1):
        line_clean = re.sub(r'--.*$', '', line).strip()
        if not line_clean:
            continue
            
        # Function definitions
        m_fn = re.match(r'^(?:local\s+)?function\s+([A-Za-z0-9_.:]+)\s*\(([^)]*)\)', line_clean)
        if m_fn:
            functions.append({
                "name": m_fn.group(1),
                "params": [p.strip() for p in m_fn.group(2).split(",") if p.strip()],
                "line": i
            })
            
        # Member accesses on car or sim
        for m in re.finditer(r'\b(car|c|sim)\.([A-Za-z0-9_]+)\b', line_clean):
            ffi_member_accesses.add((m.group(1), m.group(2), i))
            
        # Physics API calls
        for m in re.finditer(r'\b(physics\.[A-Za-z0-9_]+)\b', line_clean):
            physics_calls.add((m.group(1), i))
            
    return {
        "file": filepath,
        "functions": functions,
        "ffi_accesses": sorted(ffi_member_accesses, key=lambda x: x[2]),
        "physics_calls": sorted(physics_calls, key=lambda x: x[1])
    }

def main():
    if len(sys.argv) < 2:
        print("Usage: ast_analyzer.py <file.lua>")
        sys.exit(1)
        
    filepath = sys.argv[1]
    res = analyze_lua_ast(filepath)
    print("=" * 60)
    print(f"  AST & SYNTAX STRUCTURE ANALYSIS: {filepath}")
    print("=" * 60)
    print(f"\n[FUNCTIONS DEFINED] ({len(res['functions'])})")
    for fn in res["functions"]:
        params = ", ".join(fn["params"])
        print(f"  L{fn['line']:03d}: {fn['name']}({params})")
        
    print(f"\n[PHYSICS API INVOCATIONS] ({len(res['physics_calls'])})")
    for call, line in res["physics_calls"]:
        print(f"  L{line:03d}: {call}")

if __name__ == "__main__":
    main()
