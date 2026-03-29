#!/bin/bash
# macOS desktop notification when Claude needs attention
INPUT=$(cat)
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude needs attention"')
TITLE=$(echo "$INPUT" | jq -r '.title // "Claude Code"')
osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\"" 2>/dev/null
exit 0
