---
name: review-code
description: Run code review agents on specified files. Use when user says "review", "check code quality", "audit", or before major commits.
argument-hint: "[file or directory to review]"
allowed-tools: ["Read", "Write", "Bash", "Task"]
---

# Code Review

## Steps

1. **Identify scope:** Determine which files to review (from argument or recent changes via `git diff`)

2. **Select agents** based on file types:
   - `*.py` source files -> code-reviewer agent
   - `tests/*.py` -> test-reviewer agent
   - `disambiguator.py` or `tools.py` -> domain-reviewer agent (in addition to code-reviewer)

3. **Run agents** (in parallel where independent):
   - Spawn Task agents for each reviewer
   - Each agent reads the file(s) and produces a report

4. **Synthesize results:**
   - Combine all agent reports
   - Deduplicate findings
   - Prioritize: Critical -> Major -> Minor
   - Calculate overall quality score

5. **Present summary:**
   - Overall score (X/100)
   - Critical issues (must fix)
   - Major issues (should fix)
   - Minor issues (nice to fix)
   - Save full report to `quality_reports/`
