---
name: commit
description: Stage, commit, and optionally create PR. Use when user says "commit", "save progress", "create PR", or "push".
argument-hint: "[commit message]"
allowed-tools: ["Read", "Bash"]
---

# Git Commit Workflow

## Pre-Commit Checks

1. Run verification:
   ```bash
   uv run ruff check .
   uv run ruff format --check .
   uv run pytest -v
   ```

2. If any check fails: stop and report. Do not commit with failing tests or lint errors.

## Commit Steps

1. Review changes:
   ```bash
   git status
   git diff
   ```

2. Stage relevant files:
   ```bash
   git add [files]
   ```

3. Never stage: `.env`, `*.xlsx`, `.claude/`, `.mcp.json`

4. Commit with descriptive message:
   ```bash
   git commit -m "message"
   ```

5. If user requested PR:
   ```bash
   git push -u origin HEAD
   gh pr create --title "Title" --body "Description"
   ```

## Commit Message Format

Use conventional format:
- `feat: add new feature`
- `fix: fix bug description`
- `refactor: restructure module`
- `test: add tests for X`
- `docs: update documentation`
