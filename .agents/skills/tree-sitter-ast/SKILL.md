---
name: tree-sitter-ast
description: >-
  Tree-sitter / AST Syntax and Semantic Structure Analyzer for Gemini Antigravity.
  Use this skill to inspect function signatures, scope boundaries, FFI C-struct member accesses,
  and build structural syntax trees for Lua and Python code.
---

# Tree-Sitter / AST Skill

A structural syntax and symbol analyzer providing deep AST-level inspection of Lua and Python codebases.

## Features
- Extracts function definitions, arguments, and return points.
- Analyzes C-struct and FFI access points (e.g. `car.xxx`, `sim.xxx`).
- Identifies control flow nesting, loop depths, and branch conditions.

## How to Run
```bash
python .agents/skills/tree-sitter-ast/scripts/ast_analyzer.py <file>
```
