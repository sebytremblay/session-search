#!/usr/bin/env bash
set -euo pipefail

# scripts/summarize-session.sh
# Summarizes a completed Claude Code session and appends to the summary store.

SESSION_ID="${SESSION_ID:?SESSION_ID environment variable must be set}"
STORE_DIR="$HOME/.claude/session-search"
INDEX_FILE="$STORE_DIR/index.jsonl"
TAKEAWAYS_FILE="$STORE_DIR/takeaways.jsonl"

# Locate the session JSONL file across all projects
SESSION_FILE=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -n 1)
if [ -z "$SESSION_FILE" ]; then
  echo "ERROR: No session file found for ${SESSION_ID}" >&2
  exit 1
fi

# Derive the project ID from the parent directory name
PROJECT_ID=$(basename "$(dirname "$SESSION_FILE")")

# Ensure the summary store directory exists
mkdir -p "$STORE_DIR"

# Skip if this session already has a summary
if [ -f "$INDEX_FILE" ] && grep -q "\"sessionId\":\"${SESSION_ID}\"" "$INDEX_FILE"; then
  exit 0
fi

# Extract the timestamp of the first entry
FIRST_TIMESTAMP=$(head -n 1 "$SESSION_FILE" | jq -r '.timestamp // empty' 2>/dev/null || echo "")

# Invoke claude -p with the summarization prompt
SUMMARY_JSON=$(claude -p --model haiku \
  "You summarize Claude Code session logs. Read the session log at the following path and produce a JSON object with exactly three fields:

1. \"sessionId\": the session UUID (use: ${SESSION_ID})
2. \"summary\": a single sentence describing the primary intent of the session
3. \"takeaways\": a paragraph of three to five sentences covering the user intent, key tradeoffs, struggle areas, the outcome, and notable decisions

Output ONLY the JSON object. No markdown fencing, no extra text.

Session file path: ${SESSION_FILE}" 2>/dev/null) || {
  echo "ERROR: claude -p failed for session ${SESSION_ID}" >&2
  exit 1
}

# Validate that the output parses as JSON
if ! echo "$SUMMARY_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: claude -p returned malformed JSON for session ${SESSION_ID}" >&2
  exit 1
fi

# Construct the index entry
INDEX_LINE=$(echo "$SUMMARY_JSON" | jq -c \
  --arg pid "$PROJECT_ID" \
  --arg ts "$FIRST_TIMESTAMP" \
  '{sessionId: .sessionId, projectId: $pid, timestamp: $ts, summary: .summary}')

# Construct the takeaways entry
TAKEAWAYS_LINE=$(echo "$SUMMARY_JSON" | jq -c \
  '{sessionId: .sessionId, takeaways: .takeaways}')

# Append to both files
echo "$INDEX_LINE" >> "$INDEX_FILE"
echo "$TAKEAWAYS_LINE" >> "$TAKEAWAYS_FILE"
