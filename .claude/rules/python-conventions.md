---
paths:
  - "*.py"
  - "tests/**/*.py"
---

# Python Code Conventions

## Style

- Line length: 100 (configured in pyproject.toml)
- Target: Python 3.11+
- Linter: ruff (select E, F, I, W; ignore E501 for pydantic-ai tool docstrings)
- Formatter: ruff format
- Type hints on all public functions

## Project Patterns

- **CLI:** click with `@cli.command()` decorators in `main.py`
- **Models:** Pydantic BaseModel with field validators in `models.py`
- **Agent:** pydantic-ai Agent with structured output (`DisambiguationResult`)
- **Async:** All agent/tool functions are async; use `asyncio.run()` at CLI boundary
- **Imports:** `from dotenv import load_dotenv` + `load_dotenv()` MUST come before other imports in entry points

## Error Handling

- Use exponential backoff for API retries (see `process_case_with_retry`)
- Detect OpenRouter funds exhaustion via `_is_funds_exhausted()`
- Detect Tavily quota exceeded and skip retries for that case
- Always clear content store between cases: `get_store().clear()`

## Dependencies

- Use `uv add` to add new dependencies (updates pyproject.toml + uv.lock)
- Use `uv run` prefix for all Python execution
- Dev dependencies in `[dependency-groups] dev` section

## Testing

- Test files in `tests/` directory
- Naming: `test_*.py` files, `test_*` functions
- Use `pytest` (via `uv run pytest`)
- Mock external APIs (Tavily, OpenRouter) in tests -- don't hit real endpoints

## File I/O

- Support both CSV and XLSX formats
- Use `encoding="utf-8-sig"` for CSV reads (handles BOM)
- Year fields can be int (single year) or str (range like "2007-2014")
