---
paths:
  - "*.py"
  - "tests/**"
---

# Quality Gates & Scoring Rubric

## Thresholds

- **80/100 = Commit** -- good enough to save
- **90/100 = PR** -- ready for deployment
- **95/100 = Excellence** -- aspirational

## Python Source Files (.py)

| Severity | Issue | Deduction |
|----------|-------|-----------|
| Critical | Syntax errors | -100 |
| Critical | Tests fail | -100 |
| Critical | Ruff lint errors (E, F categories) | -20 per error |
| Critical | Missing error handling for API calls | -15 |
| Critical | Hardcoded API keys or secrets | -50 |
| Major | Missing type hints on public functions | -5 |
| Major | No docstring on public functions | -3 |
| Major | Hardcoded file paths | -10 |
| Major | Missing async error handling | -10 |
| Minor | Ruff warnings (W, I categories) | -1 per warning |
| Minor | Long functions (>50 lines) | -2 |
| Minor | Unused imports | -1 |

## Test Files (tests/*.py)

| Severity | Issue | Deduction |
|----------|-------|-----------|
| Critical | Test doesn't actually assert anything | -20 |
| Critical | Test depends on external APIs without mocking | -15 |
| Major | Missing edge case coverage | -5 |
| Major | Test name doesn't describe what's being tested | -3 |
| Minor | Duplicate test logic | -1 |

## Enforcement

- **Score < 80:** Block commit. List blocking issues.
- **Score < 90:** Allow commit, warn. List recommendations.
- User can override with justification.

## Quality Reports

Generated **only at merge time**. Use `templates/quality-report.md` for format.
Save to `quality_reports/merges/YYYY-MM-DD_[branch-name].md`.
