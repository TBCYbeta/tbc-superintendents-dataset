---
name: test
description: Run the pytest test suite. Use when user says "run tests", "check tests", "test it", or after making code changes.
argument-hint: "[optional: specific test file or -k pattern]"
allowed-tools: ["Read", "Bash"]
---

# Run Tests

## Steps

1. Run the full test suite:
   ```bash
   uv run pytest -v
   ```

2. If a specific file or pattern was provided:
   ```bash
   uv run pytest -v [argument]
   ```

3. Report results:
   - Total tests, passed, failed, skipped
   - For any failures: show the error message and relevant code
   - Suggest fixes for failures if obvious

## Troubleshooting

- **ModuleNotFoundError:** Run `uv sync` to install dependencies
- **Missing .env:** Ensure `.env` exists with `OPENROUTER_API_KEY` and `TAVILY_API_KEY`
- **Async errors:** Check for missing `@pytest.mark.asyncio` decorators
