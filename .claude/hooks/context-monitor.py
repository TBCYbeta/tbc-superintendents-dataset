#!/usr/bin/env python3
"""
Context Usage Monitor Hook

Monitors context usage via tool call count heuristic and provides warnings:
- At 80%: Info-level warning (auto-compact approaching)
- At 90%: Caution-level warning (complete current task with full quality)

Hook Event: PostToolUse (on common tools)
"""

import json
import os
import sys
import time
from pathlib import Path

CYAN = "\033[0;36m"
YELLOW = "\033[0;33m"
RED = "\033[0;31m"
NC = "\033[0m"

THRESHOLD_WARN = 80
THRESHOLD_CRITICAL = 90
THROTTLE_INTERVAL = 60


def get_session_dir() -> Path:
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not project_dir:
        return Path.home() / ".claude" / "sessions" / "default"

    import hashlib
    project_hash = hashlib.md5(project_dir.encode()).hexdigest()[:8]
    session_dir = Path.home() / ".claude" / "sessions" / project_hash
    session_dir.mkdir(parents=True, exist_ok=True)
    return session_dir


def read_cache() -> dict:
    cache_file = get_session_dir() / "context-monitor-cache.json"
    if not cache_file.exists():
        return {}
    try:
        return json.loads(cache_file.read_text())
    except (json.JSONDecodeError, IOError):
        return {}


def save_cache(data: dict) -> None:
    cache_file = get_session_dir() / "context-monitor-cache.json"
    try:
        cache_file.write_text(json.dumps(data, indent=2))
    except IOError:
        pass


def estimate_context_percentage() -> float:
    cache = read_cache()
    tool_calls = cache.get("tool_calls", 0) + 1
    cache["tool_calls"] = tool_calls
    save_cache(cache)
    MAX_TOOL_CALLS = 150
    return min((tool_calls / MAX_TOOL_CALLS) * 100, 100)


def is_throttled(percentage: float) -> bool:
    cache = read_cache()
    last_check = cache.get("last_check_time", 0)
    now = time.time()
    if percentage < THRESHOLD_WARN and (now - last_check) < THROTTLE_INTERVAL:
        return True
    cache["last_check_time"] = now
    save_cache(cache)
    return False


def main() -> int:
    try:
        json.load(sys.stdin)
    except (json.JSONDecodeError, IOError):
        pass

    percentage = estimate_context_percentage()

    if is_throttled(percentage):
        return 0

    cache = read_cache()

    if percentage >= THRESHOLD_CRITICAL and not cache.get("shown_warn_90", False):
        cache["shown_warn_90"] = True
        save_cache(cache)
        print(f"\n{RED}Context at {percentage:.0f}% -- auto-compact approaching{NC}")
        print(f"{YELLOW}Actions to consider:{NC}")
        print("  - Save key decisions to the session log")
        print("  - Ensure current plan status is updated")
        print("  - Mark completed todos as done\n")
        return 2

    if percentage >= THRESHOLD_WARN and not cache.get("shown_warn_80", False):
        cache["shown_warn_80"] = True
        save_cache(cache)
        print(f"\n{YELLOW}Context at {percentage:.0f}%{NC}")
        print("Auto-compact will handle context management automatically.\n")
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
