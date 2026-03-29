---
name: run
description: Run the superintendent disambiguation CLI. Use when user says "run it", "test a case", "process file", or "disambiguate".
argument-hint: "[test --name ... | process input.csv output.csv]"
allowed-tools: ["Read", "Bash"]
---

# Run CLI

## Single Case Test

```bash
uv run python main.py test \
    --name "Superintendent Name" \
    --district1 "First District" --state1 XX --year1 YYYY \
    --district2 "Second District" --state2 XX --year2 YYYY \
    -m z-ai/glm-4.6
```

## Batch Processing

```bash
uv run python main.py process input.csv output.csv
```

With options:
```bash
uv run python main.py process input.csv output.csv \
    --unique-districts 2 \
    -m z-ai/glm-4.6 \
    -v
```

## Batch with Retry Wrapper

```bash
uv run python process_with_retry.py input.csv output.csv
```

## Troubleshooting

- **API key errors:** Check `.env` has valid `OPENROUTER_API_KEY` and `TAVILY_API_KEY`
- **Funds exhausted:** Add credits to OpenRouter account
- **Tavily quota:** Check Tavily usage limits
- **Timeout:** Increase timeout or check network connectivity
