#!/usr/bin/env bash
# scripts/summarize-session.sh
# SessionEnd hook: generates a structured facet for the completed session
# and stores it in a project-partitioned JSONL file.
# Heavy work (API call) runs in background via nohup + timeout.

set -euo pipefail
trap 'exit 0' ERR

# ---------------------------------------------------------------------------
# Synchronous checks (fast, must not block)
# ---------------------------------------------------------------------------

SESSION_ID="${SESSION_ID:?SESSION_ID environment variable must be set}"
STORE_DIR="$HOME/.claude/session-search"
FACETS_DIR="$STORE_DIR/facets"
ERROR_LOG="$STORE_DIR/errors.log"

# Require jq
if ! command -v jq >/dev/null 2>&1; then
  mkdir -p "$STORE_DIR"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SESSION_ID=${SESSION_ID} ERROR: jq is required but not installed" >> "$ERROR_LOG"
  exit 0
fi

# Locate the session JSONL file
SESSION_FILE=$(find "$HOME/.claude/projects" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -n 1)
if [ -z "$SESSION_FILE" ]; then
  mkdir -p "$STORE_DIR"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SESSION_ID=${SESSION_ID} ERROR: No session file found" >> "$ERROR_LOG"
  exit 0
fi

# Derive the project ID from the parent directory
PROJECT_ID=$(basename "$(dirname "$SESSION_FILE")")

mkdir -p "$FACETS_DIR"

# Duplicate detection
if grep -q "\"sessionId\":\"${SESSION_ID}\"" "$FACETS_DIR/${PROJECT_ID}.jsonl" 2>/dev/null; then
  exit 0
fi

# Extract first timestamp
FIRST_TIMESTAMP=$(head -n 1 "$SESSION_FILE" | jq -r '.timestamp // empty' 2>/dev/null || echo "")

# ---------------------------------------------------------------------------
# Detect timeout command
# ---------------------------------------------------------------------------

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout 30s"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout 30s"
else
  TIMEOUT_CMD=""
fi

# ---------------------------------------------------------------------------
# Launch background worker
# ---------------------------------------------------------------------------

nohup bash -c '
SESSION_ID="$1"
SESSION_FILE="$2"
PROJECT_ID="$3"
FIRST_TIMESTAMP="$4"
FACETS_DIR="$5"
ERROR_LOG="$6"
TIMEOUT_CMD="$7"

log_error() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SESSION_ID=${SESSION_ID} ERROR: $1" >> "$ERROR_LOG"
}

PROMPT="Analyze this Claude Code session and extract a structured facet. Read the session log at the provided file path.

RESPOND WITH ONLY A VALID JSON OBJECT matching this schema:
{
  \"sessionId\": \"use the session ID provided below\",
  \"underlying_goal\": \"What the user fundamentally wanted to achieve (one sentence)\",
  \"goal_categories\": {\"category_name\": count},
  \"outcome\": \"fully_achieved | mostly_achieved | partially_achieved | not_achieved | unclear_from_transcript\",
  \"user_satisfaction_counts\": {\"level\": count},
  \"claude_helpfulness\": \"unhelpful | slightly_helpful | moderately_helpful | very_helpful | essential\",
  \"session_type\": \"single_task | multi_task | iterative_refinement | exploration | quick_question\",
  \"friction_counts\": {\"friction_type\": count},
  \"friction_detail\": \"One sentence describing friction, or empty string\",
  \"primary_success\": \"none | fast_accurate_search | correct_code_edits | good_explanations | proactive_help | multi_file_changes | good_debugging\",
  \"brief_summary\": \"One sentence: what the user wanted and whether they got it\"
}

CRITICAL GUIDELINES:
1. goal_categories: Count ONLY what the USER explicitly asked for. Valid categories: debug_investigate, implement_feature, fix_bug, write_script_tool, refactor_code, configure_system, create_pr_commit, analyze_data, understand_codebase, write_tests, write_docs, deploy_infra, warmup_minimal
2. user_satisfaction_counts: Base ONLY on explicit user signals. Valid levels: frustrated, dissatisfied, likely_satisfied, satisfied, happy, unsure
3. friction_counts: Valid types: misunderstood_request, wrong_approach, buggy_code, user_rejected_action, claude_got_blocked, user_stopped_early, wrong_file_or_location, excessive_changes, slow_or_verbose, tool_failed, user_unclear, external_issue
4. Output ONLY the JSON object. No markdown fencing, no extra text.

Session ID: ${SESSION_ID}
Session file path: ${SESSION_FILE}"

FACET_JSON=$($TIMEOUT_CMD claude -p --model haiku "$PROMPT" 2>/dev/null) || {
  log_error "claude -p failed or timed out"
  exit 1
}

if ! echo "$FACET_JSON" | jq -e . >/dev/null 2>&1; then
  log_error "claude -p returned malformed JSON"
  exit 1
fi

AUGMENTED=$(echo "$FACET_JSON" | jq -c \
  --arg pid "$PROJECT_ID" \
  --arg ts "$FIRST_TIMESTAMP" \
  '. + {projectId: $pid, timestamp: $ts}') || {
  log_error "jq augmentation failed"
  exit 1
}

echo "$AUGMENTED" >> "$FACETS_DIR/${PROJECT_ID}.jsonl"
' _ "$SESSION_ID" "$SESSION_FILE" "$PROJECT_ID" "$FIRST_TIMESTAMP" "$FACETS_DIR" "$ERROR_LOG" "$TIMEOUT_CMD" > /dev/null 2>&1 &

exit 0
