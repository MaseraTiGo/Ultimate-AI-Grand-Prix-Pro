---
name: search-replace-block
description: >-
  Search/Replace Block Matching and Editing Engine for Gemini Antigravity.
  Use this skill to perform precise multi-line search and replace operations,
  validate context uniqueness, and prevent unintended code corruptions.
---

# Search/Replace Block Skill

A precision search-and-replace block tool that parses SEARCH/REPLACE format chunks,
verifies target line uniqueness, and applies clean replacements.

## Features
- Validates that target content appears exactly once.
- Handles multi-line indentation and newline normalization.
- Dry-run validation to preview diffs before disk write.

## How to Run
```bash
python .agents/skills/search-replace-block/scripts/search_replace.py --file <file> --search <string> --replace <string>
```
