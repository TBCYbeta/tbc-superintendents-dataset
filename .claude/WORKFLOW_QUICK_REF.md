# Workflow Quick Reference

**Model:** Contractor (you direct, Claude orchestrates)

---

## The Loop

```
Your instruction
    |
[PLAN] (if multi-file or unclear) -> Show plan -> Your approval
    |
[EXECUTE] Implement, verify, done
    |
[REPORT] Summary + what's ready
    |
Repeat
```

---

## I Ask You When

- **Design forks:** "Option A (fast) vs. Option B (robust). Which?"
- **Scope question:** "Also refactor Y while here, or focus on X?"
- **Data ambiguity:** "Input CSV has unexpected column. Assume X?"
- **Destructive actions:** pushing code, deleting files, force operations

---

## I Just Execute When

- Code fix is obvious (bug, pattern application)
- Verification (lint, tests, output CSV checks)
- Documentation (session logs, memory updates)
- Pipeline runs (after you approve, I run and monitor)

---

## Quality Gates (No Exceptions)

| Score | Action |
|-|-|
| >= 80 | Ready to commit |
| >= 90 | Ready for PR / sharing |
| < 80 | Fix blocking issues |

---

## Non-Negotiables

- `uv run ruff check .` clean on new/modified files before commit
- `uv run pytest tests/test_critic.py` passes before commit
- No API keys committed (`.env` is gitignored)
- Output CSV row count must match input case count
- Session log updated every 15 responses (hook-enforced)

---

## Pipeline Commands

```bash
# Single case test
uv run python main.py test --name "Name" --district1 "D1" --state1 ST --year1 YYYY --district2 "D2" --state2 ST --year2 YYYY

# Full pipeline (disambiguate + retry + critic)
uv run python process_with_retry.py input.csv output.csv

# Standalone critic
uv run python critic.py output.csv --matches-only
uv run python critic.py output.csv --case "Name"
```

---

## Match Decision Rule

A confirmed match requires ALL THREE:
1. `prediction` = "same"
2. `confidence` = "high"
3. `critic_score` >= 18 (CONFIRMED)

Everything else = non-match.
