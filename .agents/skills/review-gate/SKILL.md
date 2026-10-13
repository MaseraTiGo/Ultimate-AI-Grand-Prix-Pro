---
name: review-gate
description: >-
  Code Review Gate and Quality Assurance Guard for Gemini Antigravity.
  Use this skill to run static code checks, AGENTS.md rule validation, regression
  testing, and ensure zero runtime memory allocation in critical paths.
---

# Review-Gate Skill

A comprehensive review gate that enforces all operational guidelines, architectural
contracts, and regression suites before code is accepted.

## Features
- Runs full integration and unit tests.
- Checks compliance with AGENTS.md constraints (zero allocation, pcall bounds checks).
- Scans for forbidden API patterns or crash-prone struct accesses.

## How to Run
```bash
python .agents/skills/review-gate/scripts/review_gate.py
```
