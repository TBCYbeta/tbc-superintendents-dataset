---
name: context-status
description: |
  Show current context status and session health.
  Use to check how much context has been used, whether auto-compact is
  approaching, and what state will be preserved.
author: Claude Code Academic Workflow
version: 1.0.0
allowed-tools: ["Read", "Bash", "Glob"]
---

# /context-status -- Check Session Health

Show the current session status including context usage estimate, active plan,
and preservation state.

## Workflow

### Step 1: Check Context Monitor Cache

```bash
cat ~/.claude/sessions/*/context-monitor-cache.json 2>/dev/null | head -20
```

### Step 2: Find Active Plan

```bash
ls -lt quality_reports/plans/*.md 2>/dev/null | head -3
```

### Step 3: Find Session Log

```bash
ls -lt quality_reports/session_logs/*.md 2>/dev/null | head -1
```

### Step 4: Check Running Background Tasks

```bash
# Any pipeline runs in progress?
ps aux | grep "process_with_retry\|critic.py\|main.py" | grep -v grep
```

### Step 5: Report Status

Format the output:

```
Session Status
-----------------
Context Usage:  ~XX% (estimated)
Auto-compact:   [approaching | not imminent]

Active Plan
File:   quality_reports/plans/YYYY-MM-DD_description.md
Status: [draft | approved | in_progress | completed]

Session Log
File:   quality_reports/session_logs/YYYY-MM-DD_description.md

Preservation Check
  Pre-compact hook: [configured | missing]
  Post-compact restore: [configured | missing]
  Session state will be saved before compaction
```
