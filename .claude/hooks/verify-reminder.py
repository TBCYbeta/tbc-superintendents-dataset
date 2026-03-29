#!/usr/bin/env python3
"""
Verification Reminder Hook

Non-blocking reminder that fires on Write/Edit to Python source files
to remind about running tests and linting before marking a task as done.

Hook Event: PostToolUse (matcher: "Write|Edit")
Returns: Exit code 0 (non-blocking)
"""

import json
import os
import sys
import time
from pathlib import Path

CYAN = "\033[0;36m"
GREEN = "\033[0;32m"
NC = "\033[0m"

VERIFY_EXTENSIONS = {
    ".py": "run `uv run pytest` and `uv run ruff check .`",
}

SKIP_EXTENSIONS = [
    ".md", ".txt", ".rst",
    ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg",
    ".lock", ".env", ".gitignore",
    ".csv", ".xlsx",
    ".svg", ".png", ".jpg", ".pdf",
]

SKIP_DIRS = [
    "/quality_reports/",
    "/templates/",
    "/.claude/",
    "/archive/",
    "/__pycache__/",
]


def get_session_dir() -> Path:
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not project_dir:
        return Path.home() / ".claude" / "sessions" / "default"

    import hashlib
    project_hash = hashlib.md5(project_dir.encode()).hexdigest()[:8]
    session_dir = Path.home() / ".claude" / "sessions" / project_hash
    session_dir.mkdir(parents=True, exist_ok=True)
    return session_dir


def should_skip(file_path: str) -> bool:
    path = Path(file_path)
    if path.suffix.lower() in SKIP_EXTENSIONS:
        return True
    for skip_dir in SKIP_DIRS:
        if skip_dir in file_path:
            return True
    name = path.name.lower()
    if name.startswith("test_") or name.endswith("_test.py"):
        return True
    return False


def needs_verification(file_path: str) -> tuple[bool, str]:
    path = Path(file_path)
    suffix = path.suffix.lower()
    if suffix in VERIFY_EXTENSIONS:
        return True, VERIFY_EXTENSIONS[suffix]
    return False, ""


def was_recently_reminded(file_path: str) -> bool:
    cache_file = get_session_dir() / "verify-reminder-cache.json"
    try:
        if cache_file.exists():
            cache = json.loads(cache_file.read_text())
        else:
            cache = {}
    except (json.JSONDecodeError, IOError):
        cache = {}

    last_reminder = cache.get(file_path, 0)
    now = time.time()
    cache[file_path] = now
    cache = {k: v for k, v in cache.items() if now - v < 300}

    try:
        cache_file.write_text(json.dumps(cache))
    except IOError:
        pass

    return (now - last_reminder) < 60


def main() -> int:
    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, IOError):
        return 0

    tool_input = hook_input.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    if not file_path:
        return 0
    if should_skip(file_path):
        return 0

    needs_verify, action = needs_verification(file_path)
    if not needs_verify:
        return 0
    if was_recently_reminded(file_path):
        return 0

    filename = Path(file_path).name
    print(f"\n{CYAN}Verification reminder:{NC} {filename}")
    print(f"   -> {GREEN}{action}{NC} before marking task complete\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
