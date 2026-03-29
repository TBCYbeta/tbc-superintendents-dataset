---
name: deep-audit
description: |
  Deep consistency audit of the superintendent disambiguation repository.
  Launches 4 parallel specialist agents to find code bugs, pipeline
  inconsistencies, documentation drift, and test gaps. Then fixes all
  issues and loops until clean.
  Use when: after making broad changes, before releases, or when user says
  "audit", "find inconsistencies", "check everything".
author: Superintendent Disambiguation Project
version: 1.0.0
allowed-tools: ["Read", "Write", "Edit", "Bash", "Glob", "Grep", "Task"]
---

# /deep-audit -- Repository Consistency Audit

Run a comprehensive consistency audit, fix all issues found, and loop until clean.

## When to Use

- After broad changes (new features, refactors, pipeline changes)
- Before sharing code with collaborators
- When the user asks to "audit", "find inconsistencies", or "check everything"

## Workflow

### PHASE 1: Launch 4 Parallel Audit Agents

Launch these 4 agents simultaneously:

#### Agent 1: Python Code Quality
- `uv run ruff check .` -- all lint clean
- `uv run ruff format --check .` -- all formatting clean
- No unused imports in new/modified files
- No hardcoded API keys or secrets (`grep -r "sk-or-\|sk-ant-\|tvly-"`)
- `_is_funds_exhausted` duplication between main.py and critic.py is intentional (don't flag)

#### Agent 2: Pipeline Consistency
- `RESULT_HEADERS` in `process_with_retry.py` matches `main.py`
- `process_with_retry.py` imports match actual exports from `main.py`, `critic.py`, `retry_errors.py`
- `retry_errors.py` `row_key()` used consistently for case matching
- Output CSV schema: all columns present, critic columns blank for non-matches
- `--max-retries` default is >= 10 (not the old default of 2)

#### Agent 3: Documentation Consistency
- CLAUDE.md commands section matches actual CLI interfaces
- CLAUDE.md metrics section matches latest production run data
- README.md setup instructions work (`uv sync`, `.env` setup)
- MEMORY.md matches current project state
- Skills table in CLAUDE.md matches actual `.claude/skills/` directories

#### Agent 4: Test Coverage
- All public functions in `critic.py` have tests
- All model classes (`CriticCriterion`, `CriticResult`) have tests
- Test fixtures use `tmp_path` (not hardcoded paths)
- No tests import from `process_with_retry.py` at module level (heavy imports)
- `uv run pytest tests/test_critic.py -v` passes

### PHASE 2: Triage Findings

Categorize each finding:
- **Genuine bug**: Fix immediately
- **Pre-existing**: Note but don't fix (e.g., lint issues in disambiguator.py)
- **False alarm**: Discard

### PHASE 3: Fix All Issues

Apply fixes. For each fix:
1. Read the file first
2. Apply the fix
3. Verify (`ruff check`, `pytest`)

### PHASE 4: Re-verify

After fixing, run:
```bash
uv run ruff check . && uv run ruff format --check .
uv run pytest tests/test_critic.py -v
```

### PHASE 5: Loop or Declare Clean

- If new issues found -> fix and loop again
- If zero genuine issues -> declare clean and report summary
- **Max loops: 3**

## Known Pre-Existing Issues (Don't Flag)

- `disambiguator.py`: W291 trailing whitespace, F541 f-string (in agent prompt strings)
- `main.py`: W293 blank line whitespace
- `tests/test_html_extraction.py`: F401 unused pytest import

## Output Format

```
## Audit Results

### Issues Found: X genuine, Y pre-existing, Z false alarms

| # | Severity | File | Issue | Status |
|---|----------|------|-------|--------|
| 1 | Critical | file.py:42 | Description | Fixed |

### Verification
- [ ] ruff check clean (new files only)
- [ ] pytest passes
- [ ] No secrets in codebase

### Result: [CLEAN | N issues remaining]
```
