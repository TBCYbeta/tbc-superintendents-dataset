---
paths:
  - "*.py"
  - "tests/**"
---

# Task Completion Verification Protocol

**At the end of EVERY task, Claude MUST verify the output works correctly.** This is non-negotiable.

## For Python Source Changes:

1. Run `uv run ruff check .` to verify no lint errors
2. Run `uv run ruff format --check .` to verify formatting
3. Run `uv run pytest` to verify tests pass
4. If the change affects CLI behavior, run a quick smoke test with `uv run python main.py --help`
5. Report verification results

## For Agent Prompt Changes (disambiguator.py):

1. All standard Python verification steps above
2. Run a single test case to verify agent behavior:
   ```
   uv run python main.py test --name "Test Name" \
       --district1 "District A" --state1 TX --year1 2020 \
       --district2 "District B" --state2 TX --year2 2022
   ```
3. Compare behavior against known ground truth if available

## For Test Changes:

1. Run the full test suite: `uv run pytest -v`
2. Verify new tests actually test something meaningful (not just passing trivially)
3. Check for flaky tests (async timing, network dependencies)

## For Pipeline Runs (process_with_retry.py):

1. Verify output CSV exists and has correct row count (must match input)
2. Check for `critic_score` and `critic_grade` columns on high-confidence "same" rows
3. Verify critic report written to `quality_reports/critic_*.md`
4. Verify companion CSV and `_passed.csv` written alongside report
5. Check no intermediate files left behind (`*_initial.csv`, `*_merged_*.csv`)

## For Critic Runs (critic.py):

1. Verify markdown report written to `quality_reports/`
2. Verify companion CSV written (same stem as report)
3. If `--matches-only`: verify `_passed.csv` written with CONFIRMED cases only
4. Check grade distribution is reasonable (not all CONFIRMED or all SUSPECT)

## Common Pitfalls:

- **Forgetting `uv run` prefix**: All Python commands must use `uv run` to use the project's virtualenv
- **Async code**: Changes to async functions may not surface errors until runtime
- **API keys**: Tests that hit real APIs (Tavily, OpenRouter) need `.env` configured
- **Content store state**: `get_store().clear()` between test cases to avoid cross-contamination
- **Output row count**: Pipeline must produce exactly as many rows as input cases; the sanity check in `process_with_retry.py` catches this

## Verification Checklist:

```
[ ] Ruff check passes (no lint errors in new/modified files)
[ ] Ruff format passes (no formatting issues)
[ ] Pytest passes (all tests green)
[ ] Smoke test runs (CLI responds correctly)
[ ] Output file row count matches input (for pipeline runs)
[ ] No API keys in committed files
[ ] Reported results to user
```
