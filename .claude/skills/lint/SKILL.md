---
name: lint
description: Run ruff linter and formatter checks. Use when user says "lint", "check style", "format", or before committing.
argument-hint: "[optional: specific file path]"
allowed-tools: ["Read", "Bash"]
---

# Run Linter

## Steps

1. Run ruff lint check:
   ```bash
   uv run ruff check .
   ```

2. Run ruff format check:
   ```bash
   uv run ruff format --check .
   ```

3. If issues found, offer to auto-fix:
   ```bash
   uv run ruff check --fix .
   uv run ruff format .
   ```

4. Report results:
   - Number of issues found and fixed
   - Any remaining issues that need manual attention

## If specific file provided:

Replace `.` with the file path in all commands above.
