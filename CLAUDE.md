# CLAUDE.md

**Project:** TBC Superintendents Dataset
**Institution:** Yale School of Management / The Broad Center
**Branch:** master

---

## Core Principles

- **Plan first** -- enter plan mode before non-trivial tasks; save plans to `quality_reports/plans/`
- **Verify after** -- run checks and confirm output at the end of every task
- **Quality gates** -- nothing ships below 80/100
- **[LEARN] tags** -- when corrected, save `[LEARN:category] wrong -> right` to MEMORY.md

---

## Folder Structure

```
tbc-superintendents-dataset/
├── CLAUDE.md                    # This file
├── .claude/                     # Rules, skills, agents, hooks
├── data/
│   ├── raw/                     # Original state datasets (23 states)
│   └── processed/               # combined_superintendents.csv + global IDs
├── scripts/                     # R import scripts + Python ID assignment
├── disambiguation/              # LLM-based cross-state matching pipeline
│   └── output/                  # Disambiguation results + critic scores
├── output/                      # Figures, tables, memo
├── quality_reports/             # Plans, session logs
└── templates/                   # Session log, quality report templates
```

---

## Commands

```bash
# R: Run all state imports and merge
Rscript scripts/02_run_all.R

# Python: Assign global superintendent IDs (after disambiguation)
python3 scripts/04_assign_global_ids.py

# Disambiguation: Single case test
cd disambiguation && uv run python main.py test --name "Name" \
    --district1 "D1" --state1 ST --year1 YYYY \
    --district2 "D2" --state2 ST --year2 YYYY

# Disambiguation: Full pipeline
cd disambiguation && uv run python process_with_retry.py input.csv output.csv

# Disambiguation: Standalone critic
cd disambiguation && uv run python critic.py output.csv --matches-only
```

---

## Quality Thresholds

| Score | Gate | Meaning |
|-|-|-|
| 80 | Commit | Good enough to save |
| 90 | PR | Ready for deployment |
| 95 | Excellence | Aspirational |

---

## Skills Quick Reference

| Command | What It Does |
|-|-|
| `/commit [msg]` | Stage, commit, PR, merge |
| `/learn [name]` | Extract discovery into persistent skill |
| `/context-status` | Show session health + context usage |
| `/deep-audit` | Repository-wide consistency audit |
| `/critique [csv]` | Adversarial audit of disambiguation results |
| `/lint` | Run ruff check + format (disambiguation/) |
| `/test` | Run pytest suite (disambiguation/) |
| `/review-code [file]` | Code quality review |

---

## Key Data Files

| File | Description |
|-|-|
| `data/processed/combined_superintendents.csv` | 180,388 rows, 23 states, within-state super_id |
| `data/processed/combined_superintendents_global.csv` | Same + global_id (cross-state merged) |
| `disambiguation/output/cross_state_matches_output_merged.csv` | 1,512 cross-state disambiguation results |
| `disambiguation/output/critic_2026-03-05_084008_passed.csv` | 264 confirmed cross-state matches |

---

## Current Metrics

### Main Dataset
- 180,388 superintendent-year rows across 23 states (1990-2024)
- 31,334 unique within-state super_ids
- 31,144 unique global_ids (190 cross-state merges from 264 confirmed matches)

### Disambiguation Pipeline (cross-state)
- Accuracy: 99.0%, Precision: 97.4%, Recall: 100.0% (200-case test set)
- Production: 1,512 cases -> 264 confirmed matches (after critic filter)
