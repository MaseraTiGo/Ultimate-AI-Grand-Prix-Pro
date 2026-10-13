---
name: diff-aware-ripper
description: >-
  Diff-Aware Code Searcher and Blast Radius Ripper for Gemini Antigravity.
  Use this skill to inspect git diffs, discover all modified symbols, functions,
  and trace their references and downstream callers across the entire repository.
---

# Diff-Aware & Ripper Skill

A git-diff aware analysis tool that traces the blast radius of changes.

## Features
- Inspects git diff (working tree, staged, or recent commits).
- Identifies all modified function names, variables, and API calls.
- Scans all files across the repository to locate downstream consumers and callers.

## How to Run
```bash
python .agents/skills/diff-aware-ripper/scripts/diff_ripper.py
```
