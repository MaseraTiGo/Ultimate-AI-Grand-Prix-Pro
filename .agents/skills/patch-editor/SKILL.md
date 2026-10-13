---
name: patch-editor
description: >-
  Surgical Patch Editor and Safe Code Modification Engine for Gemini Antigravity.
  Use this skill to validate multi-file edits, ensure zero accidental side-effects,
  and verify patch integrity before committing.
---

# Patch-Editor Skill

A surgical patch editing and verification skill designed to ensure clean, atomic,
and idempotent code modifications.

## Features
- Validates unified diffs and replacement chunks before applying.
- Checks file integrity, syntax validity, and whitespace consistency.
- Enforces dual-entry file synchronization (e.g. `Ultimate AI Grand Prix Pro.lua` and `Ultimate-AI-Grand-Prix-Pro.lua`).

## How to Run
Run patch validation:
```bash
python .agents/skills/patch-editor/scripts/patch_validator.py
```
