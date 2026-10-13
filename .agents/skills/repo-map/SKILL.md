---
name: repo-map
description: >-
  Repository Map and Symbol Dependency Graph Generator for Gemini Antigravity.
  Use this skill to map project architecture, modules, exports, dependencies,
  and understand call graphs before making changes.
---

# Repo-Map Skill

A specialized repository mapper that scans the codebase, indexes all Lua, Python,
and JSON files, and generates an architectural symbol dependency graph.

## Features
- Scans all modules and discovers exported functions, state tables, and interfaces.
- Extracts `require(...)` dependency relationships.
- Generates ASCII and Markdown architectural maps with line numbers.

## How to Run
Run the repository mapping tool:
```bash
python .agents/skills/repo-map/scripts/build_repo_map.py
```
