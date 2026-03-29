# Session Search Plugin Specification

## 1. Overview

The Session Search plugin semantically searches Claude Code session logs to extract user-specified insights. Two components power the plugin: a **SessionEnd hook** that automatically summarizes each session on exit, and a **`/session-search` slash command** that orchestrates search and analysis across the summarized history. The plugin defaults to scanning all projects on the machine, giving users a single entry point into their entire Claude Code history. All output renders directly in the terminal.

## 2. Plugin File Layout

### 2.1 Plugin Directory Tree

```
session-search/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   └── session-search.md
├── hooks/
│   └── hooks.json
├── scripts/
│   └── summarize-session.sh
└── docs/
    └── design/
        └── SPEC.md
```

### 2.2 Runtime Data Paths

| Path | Purpose |
|------|---------|
| `~/.claude/session-search/index.jsonl` | Lightweight session index (one line per session) |
| `~/.claude/session-search/takeaways.jsonl` | Rich session takeaways (one line per session) |
| `~/.claude/projects/<project-id>/<session-id>.jsonl` | Raw session log files (read-only, owned by Claude Code) |
| `/tmp/session-search-<uuid>.py` | Ephemeral extraction scripts (created and deleted per invocation) |
| `/tmp/session-search-<uuid>.json` | Ephemeral extraction output (created and deleted per invocation) |

## 3. Session Log Schema Reference

This section serves as the authoritative reference that extraction subagents receive. The detail here enables a Python developer to write correct parsing code without inspecting raw files.

### 3.1 File Location and Format

- **Path pattern:** `~/.claude/projects/<project-id>/<session-id>.jsonl`
- **Project ID derivation:** The absolute path of the project directory with slashes replaced by dashes. For example, `/Users/jane/myproject` becomes `-Users-jane-myproject`.
- **Format:** JSONL (one JSON object per line, chronologically ordered)

### 3.2 Entry Types

| Type | Description |
|------|-------------|
| `user` | User messages containing direct text input or tool results |
| `assistant` | Model responses containing thinking blocks, text, and tool calls |
| `progress` | Hook execution and subagent progress tracking |
| `file-history-snapshot` | File state snapshots for undo operations |
| `system` | System events (subtypes: `local_command`, `turn_duration`, `compact_boundary`, `informational`) |

### 3.3 Universal Fields

The following fields appear on `user` and `assistant` entries:

| Field | Type | Description |
|-------|------|-------------|
| `uuid` | string | Unique entry identifier |
| `parentUuid` | string or null | Links entries into a conversation tree |
| `timestamp` | string | ISO 8601 timestamp |
| `type` | string | Entry type discriminator |
| `sessionId` | string | UUID of the session |
| `cwd` | string | Working directory at time of entry |
| `version` | string | Claude Code version |
| `gitBranch` | string | Current git branch |
| `isSidechain` | boolean | Whether the entry belongs to a side chain |

### 3.4 User Entry Structure

- `message.role`: always `"user"`
- `message.content`: either a plain string (direct user input) or an array of content blocks
- Content block types in arrays:
  - `{"type": "text", "text": "..."}` for text segments
  - `{"type": "tool_result", "tool_use_id": "...", "content": [...]}` for tool results
- Additional fields: `toolUseResult` (structured result data), `sourceToolAssistantUUID` (points to the original tool call)

**Direct user input example:**

```json
{
  "type": "user",
  "uuid": "a1b2c3d4",
  "parentUuid": null,
  "timestamp": "2026-03-29T14:30:00.000Z",
  "sessionId": "sess-uuid-1234",
  "cwd": "/Users/jane/myproject",
  "version": "1.0.0",
  "gitBranch": "main",
  "message": {
    "role": "user",
    "content": "Fix the failing unit test in auth_test.py"
  }
}
```

**Tool result example:**

```json
{
  "type": "user",
  "uuid": "e5f6g7h8",
  "parentUuid": "prev-uuid",
  "timestamp": "2026-03-29T14:30:05.000Z",
  "sessionId": "sess-uuid-1234",
  "message": {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "tool-uuid-5678",
        "content": [{"type": "text", "text": "File contents here..."}]
      }
    ]
  },
  "toolUseResult": {
    "type": "tool_result",
    "tool_use_id": "tool-uuid-5678",
    "content": "File contents here..."
  }
}
```

### 3.5 Assistant Entry Structure

- `message.role`: always `"assistant"`
- `message.model`: model identifier (e.g., `"claude-opus-4-6"`, `"claude-sonnet-4-6"`, `"claude-haiku-4-5-20251001"`)
- `message.content`: array of content blocks:
  - `{"type": "thinking", "thinking": "...", "signature": "..."}` for extended thinking
  - `{"type": "text", "text": "..."}` for response text
  - `{"type": "tool_use", "id": "...", "name": "...", "input": {...}}` for tool calls
- `message.usage`: `{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}`

**Assistant response example:**

```json
{
  "type": "assistant",
  "uuid": "i9j0k1l2",
  "parentUuid": "a1b2c3d4",
  "timestamp": "2026-03-29T14:30:02.000Z",
  "sessionId": "sess-uuid-1234",
  "message": {
    "role": "assistant",
    "model": "claude-sonnet-4-6",
    "content": [
      {"type": "thinking", "thinking": "The user wants me to fix a test...", "signature": "base64..."},
      {"type": "text", "text": "Let me read the failing test file."},
      {"type": "tool_use", "id": "tool-uuid-5678", "name": "Read", "input": {"file_path": "/Users/jane/myproject/auth_test.py"}}
    ],
    "usage": {
      "input_tokens": 1500,
      "output_tokens": 200,
      "cache_creation_input_tokens": 500,
      "cache_read_input_tokens": 1000
    }
  }
}
```

### 3.6 Progress Entry Structure

- `data.type`: either `hook_progress` or `agent_progress`
- Hook progress carries: `hookEvent`, `hookName`, `command`
- Agent progress carries: embedded `message` (nested assistant entry), `prompt` (text sent to subagent)
- Both carry: `parentToolUseID`, `toolUseID`

### 3.7 Common Tool Names

Extraction scripts should expect the following tool names in `tool_use` content blocks:

`Read`, `Edit`, `Write`, `Bash`, `Glob`, `Grep`, `Agent`, `AskUserQuestion`, `Skill`, `ToolSearch`, `WebFetch`, `WebSearch`, `TaskCreate`, `TaskUpdate`, `NotebookEdit`

## 4. Component 1: Session Summarizer

### 4.1 Trigger Mechanism

- **Hook event:** `SessionEnd`
- **Fires on:** all session exits, including quit, `/clear`, `/new`, Ctrl+C, and any other termination
- **Execution:** asynchronous (does not block the user's terminal)

### 4.2 Hook Configuration

`hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/summarize-session.sh"
          }
        ]
      }
    ]
  }
}
```

### 4.3 Summarization Flow

1. The shell script receives the session ID via environment variable.
2. The script locates the session JSONL file by scanning `~/.claude/projects/*/` for a matching filename.
3. The script derives the project ID from the parent directory name.
4. The script invokes `claude -p` with a summarization prompt, passing the session file path.
5. `claude -p` reads the session log and generates a structured JSON summary.
6. The script parses the JSON output and appends one line to `index.jsonl` and one line to `takeaways.jsonl`.
7. Before appending, the script checks for duplicate session IDs by searching the index file. If the session ID already exists, the script skips the append.

### 4.4 Summarization Prompt

The following text passes verbatim to `claude -p`:

```
You summarize Claude Code session logs. Read the session log at the file path provided and produce a JSON object with exactly three fields:

1. "sessionId": the session's UUID (extracted from the sessionId field in any entry)
2. "summary": a single sentence describing the primary intent of the session (what the user set out to accomplish)
3. "takeaways": a paragraph of three to five sentences covering: the user's intent, key tradeoffs encountered, struggle areas or blockers, the outcome, and any notable decisions

Output ONLY the JSON object. No markdown fencing, no extra text.
```

### 4.5 Storage Schema

**`index.jsonl` line format:**

```json
{"sessionId": "uuid", "projectId": "-Users-jane-myproject", "timestamp": "2026-03-29T14:30:00.000Z", "summary": "Fix failing authentication unit test caused by mocked token expiry."}
```

**`takeaways.jsonl` line format:**

```json
{"sessionId": "uuid", "takeaways": "The user needed to fix a flaky authentication test that intermittently failed due to hardcoded token expiry timestamps. The initial approach of mocking the clock proved fragile, so the session pivoted to using relative time deltas. Claude identified the root cause within two iterations after reading the test fixtures. The fix required updating three test files and the shared auth helper module."}
```

### 4.6 Retroactive Summarization

When the search command encounters session IDs lacking summaries, the orchestrator:

1. Prints: "Found N sessions without summaries."
2. Prints: "Run `summarize-session --backfill` to generate missing summaries."
3. Continues the search using only sessions that already have summaries in the index.

## 5. Component 2: Session Search

### 5.1 Command Definition

- **Slash command:** `/session-search <query>`
- **File:** `commands/session-search.md`
- **Allowed tools:** `Bash, Read, Write, Agent, Glob, Grep`

### 5.2 Orchestration Overview

```
User query ($ARGUMENTS)
  │
  ▼
Step 1: Session Mapping
  Read index.jsonl. Match query against summaries
  (or select all). Produce session ID list.
  │
  ▼
Step 2: Data Extraction
  Spawn subagent with session log schema + task context.
  Subagent writes a Python script, executes it,
  persists results to /tmp/session-search-<uuid>.json.
  │
  ▼
Step 3: Analysis
  Spawn analysis subagent with custom system prompt.
  Subagent reads extracted data, produces final output.
  Print to terminal.
```

## 6. Step 1: Session Mapping

### 6.1 Query Classification

The orchestrator classifies the query into two categories:

- **All sessions:** queries containing keywords like "all," "every," "entire history," "everything," or queries that inherently require comprehensive coverage (ROI analysis, pattern detection, skill extraction)
- **Subset:** time-bounded queries ("today," "this week," "last month"), project-specific queries, or topic-specific queries

### 6.2 All-Sessions Path

1. Read `~/.claude/session-search/index.jsonl`.
2. Collect every session ID and its corresponding project directory.
3. Resolve each session ID to its JSONL file path: `~/.claude/projects/<projectId>/<sessionId>.jsonl`.

### 6.3 Subset Path

1. Read `~/.claude/session-search/index.jsonl`.
2. Apply time-based filters by parsing the `timestamp` field against date constraints in the query.
3. Apply project-based filters by matching the `projectId` field.
4. For semantic filtering, compare the query against each line's `summary` field.
5. Select sessions whose summaries indicate relevance to the query.

### 6.4 Missing Summaries

After collecting session IDs, the orchestrator cross-references against known session files in `~/.claude/projects/*/`:

1. Use `Glob` to find all `*.jsonl` files matching session UUID patterns.
2. Compare against session IDs present in `index.jsonl`.
3. If unsummarized sessions exist, print a warning with the count of unsummarized sessions and a copy-pasteable backfill command (per Section 4.6).

## 7. Step 2: Data Extraction

### 7.1 Subagent Configuration

- **Model:** `haiku` (optimized for speed and cost on structured extraction tasks)
- **Tools:** `Bash, Read, Write`
- **Context:** `fork` (runs in isolated subagent)

### 7.2 Subagent Prompt Template

```
You write and execute Python 3 scripts that extract data from Claude Code session logs.

## Session Log Schema
[The orchestrator pastes the full schema reference from Section 3]

## Task
[Dynamically generated description of what data to extract, tailored to the user's query]

## Session Files
[List of absolute file paths to relevant session JSONL files]

## Requirements
1. Write a Python 3 script to /tmp/session-search-<uuid>.py
2. Use only standard library modules (json, os, sys, re, datetime, collections, pathlib)
3. The script reads the listed JSONL files line by line using json.loads()
4. Skip malformed lines with a try/except around json.loads()
5. Extract the data described in the Task section
6. Write output as JSON to /tmp/session-search-<uuid>.json
7. Execute the script: python3 /tmp/session-search-<uuid>.py
8. Verify the output file contains valid JSON
9. If the script fails to execute or produces invalid JSON, read the stderr output, diagnose the error, fix the script, and re-execute. Allow up to 2 retries before reporting failure.
10. The output JSON must stay under 50,000 characters. Aggregate data within the script: compute counts, top-N lists, averages, and statistical summaries rather than emitting raw per-entry arrays. The analysis subagent receives this output in its context window, so token efficiency is a hard constraint.
11. Report the output file path
```

### 7.3 Rationale for Code Generation

Each use case demands different data from the session logs:

- ROI analysis requires timestamps, tool call counts, session durations, and correction patterns.
- Daily sync summaries require user prompts, file modifications, and git operations.
- Skill extraction requires normalized prompt text and tool sequence patterns.

A generated script adapts to each query without maintaining a library of hardcoded extractors. The subagent understands the session log schema and writes targeted extraction logic for the specific task.

### 7.4 Script Requirements

- **Language:** Python 3
- **Dependencies:** standard library only (no pip installs)
- **Input:** reads JSONL files line by line (never loads full file into memory)
- **Output:** writes a single JSON file to `/tmp/`
- **Error handling:** skip malformed lines, log skipped count to stderr
- **Lifecycle:** the orchestrator deletes both the script and output file after Step 3 completes

## 8. Step 3: Analysis

### 8.1 Subagent Configuration

- **Model:** default session model (inherits from the user's Claude Code configuration)
- **Tools:** `Read, Bash`

### 8.2 System Prompt Construction

The orchestrator builds a task-specific system prompt for the analysis subagent. Each prompt includes:

1. The user's original query (verbatim)
2. The analysis methodology (tailored to the query type)
3. Output format expectations
4. Writing style constraints: no contractions, active voice, no em dashes, present habitual tense

The orchestrator does not use a generic analysis prompt. Each invocation receives a custom prompt that reflects the specific task, the data schema of the extracted JSON, and the desired output structure.

### 8.3 Output

The analysis subagent reads the extracted JSON from `/tmp/session-search-<uuid>.json` and produces a formatted analysis. All output prints directly to the terminal. The plugin does not persist analysis results to disk.

## 9. Walked Examples

Each example walks through the complete three-step flow with concrete artifacts: session mapping logic, the Python extraction script, the analyzer system prompt, and the terminal output.

### 9.1 ROI Analysis

**User query:**

```
/session-search What is my return on investment from using Claude Code?
```

#### Step 1: Session Mapping

The orchestrator classifies the query as "all sessions" because ROI calculation demands comprehensive coverage across every recorded interaction. The orchestrator reads `~/.claude/session-search/index.jsonl`, parses each line, and collects all session IDs regardless of project or date. The index yields 47 sessions spanning 8 distinct projects.

The orchestrator builds a JSON manifest of session file paths:

```json
[
  "/Users/jane/.claude/projects/-Users-jane-myproject/abc123.jsonl",
  "/Users/jane/.claude/projects/-Users-jane-myproject/def456.jsonl",
  "/Users/jane/.claude/projects/-Users-jane-api-server/aaa111.jsonl"
]
```

The orchestrator writes the manifest to a temporary file and prepares the extraction step.

#### Step 2: Data Extraction

**Task description sent to extraction subagent:**

> Extract per-session metadata for ROI calculation from each session file listed in the input manifest. For each session, compute: session duration (elapsed time between first and last entry), number of user messages (entries where type equals "user" and message.content holds a string), number of assistant tool calls grouped by tool name, number of tool errors (user entries containing a tool_result block with is_error set to true), count of user correction messages (user string messages following an assistant message that contain words like "no", "wrong", "undo", "revert", "actually", "instead"), the text of the first user prompt, total input and output tokens from assistant message.usage fields, and whether the session contains git commits (Bash tool_use entries where input.command contains "git commit"). Write the result as a JSON array to the output path.

**Python script the subagent writes and executes:**

```python
#!/usr/bin/env python3
"""Extract per-session metadata for ROI calculation."""
import json
import sys
import re
from datetime import datetime

CORRECTION_WORDS = re.compile(
    r'\b(no|wrong|undo|revert|actually|instead|fix that)\b', re.IGNORECASE
)

def parse_session(path):
    entries = []
    with open(path, 'r') as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                continue
    if not entries:
        return None

    first_ts = entries[0].get('timestamp', '')
    last_ts = entries[-1].get('timestamp', '')
    try:
        start = datetime.fromisoformat(first_ts.replace('Z', '+00:00'))
        end = datetime.fromisoformat(last_ts.replace('Z', '+00:00'))
        duration_sec = (end - start).total_seconds()
    except (ValueError, AttributeError):
        duration_sec = 0

    user_messages = 0
    first_prompt = None
    tool_calls = {}
    tool_errors = 0
    corrections = 0
    has_git_commit = False
    total_input_tokens = 0
    total_output_tokens = 0
    prev_type = None

    for entry in entries:
        etype = entry.get('type')
        content = entry.get('message', {}).get('content')

        if etype == 'user' and isinstance(content, str):
            user_messages += 1
            if first_prompt is None:
                first_prompt = content[:200]
            if prev_type == 'assistant' and CORRECTION_WORDS.search(content):
                corrections += 1

        if etype == 'user' and isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'tool_result':
                    if block.get('is_error'):
                        tool_errors += 1

        if etype == 'assistant' and isinstance(content, list):
            usage = entry.get('message', {}).get('usage', {})
            total_input_tokens += usage.get('input_tokens', 0)
            total_output_tokens += usage.get('output_tokens', 0)
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'tool_use':
                    name = block.get('name', 'unknown')
                    tool_calls[name] = tool_calls.get(name, 0) + 1
                    if name == 'Bash':
                        cmd = block.get('input', {}).get('command', '')
                        if 'git commit' in cmd:
                            has_git_commit = True

        prev_type = etype

    return {
        'session_id': entries[0].get('sessionId', ''),
        'project': path.split('/')[-2],
        'duration_sec': duration_sec,
        'user_messages': user_messages,
        'first_prompt': first_prompt or '',
        'tool_calls': tool_calls,
        'tool_errors': tool_errors,
        'corrections': corrections,
        'has_git_commit': has_git_commit,
        'total_input_tokens': total_input_tokens,
        'total_output_tokens': total_output_tokens
    }

def main():
    with open(sys.argv[1], 'r') as f:
        session_paths = json.load(f)

    results = []
    for path in session_paths:
        record = parse_session(path)
        if record:
            results.append(record)

    with open(sys.argv[2], 'w') as f:
        json.dump(results, f, indent=2)

if __name__ == '__main__':
    main()
```

The script writes its output to `/tmp/session-search-<uuid>.json`.

#### Step 3: Analysis

**Custom system prompt the orchestrator constructs for the analysis subagent:**

> You are a developer productivity analyst. Read the extracted session data from the provided JSON file. For each session, estimate the manual developer effort the task would have required without AI assistance by examining: the number and variety of tool calls (more tools and files touched indicate higher complexity), session duration as a proxy for Claude-augmented time, correction count as an indicator of iteration overhead, and whether git commits occurred (signaling completed deliverables).
>
> Apply these estimation heuristics: sessions under 5 minutes with fewer than 5 tool calls map to simple lookups (manual equivalent: 3x the Claude time). Sessions between 5 and 30 minutes with 5 to 30 tool calls map to moderate implementation tasks (manual equivalent: 4x). Sessions over 30 minutes or with more than 30 tool calls map to complex multi-file work (manual equivalent: 5x). Sessions containing corrections reduce the multiplier by 0.5 for each correction beyond two.
>
> Classify each session into a category based on the first prompt and tool usage: debug, implement feature, refactor, write tests, or config/setup. Produce an executive summary (2-3 sentences), a key metrics block, and a category breakdown table. Follow these writing rules: no contractions, active voice, present tense, no em dashes.

**Terminal output the user sees:**

```
ROI Analysis: 47 Sessions Across 8 Projects
============================================

Claude Code sessions span 12 weeks of development activity, accumulating
approximately 38 hours of augmented coding time. Conservative estimates
place the manual equivalent at 156 hours, yielding a net savings of 118
hours (a 4.1x productivity multiplier).

Key Metrics
───────────────────────────────────────────
  Sessions analyzed           47
  Total Claude time           38.2 hours
  Estimated manual equivalent 156.4 hours
  Net time saved              118.2 hours
  Avg multiplier              4.1x
  ─────────────────────────────────────
  Positive ROI sessions       39  (83%)
  Neutral ROI sessions         5  (11%)
  Negative ROI sessions        3   (6%)

Category Breakdown
───────────────────────────────────────────────────────────────
  Category          Sessions   Claude hrs   Manual est   Mult
  ─────────────────────────────────────────────────────────────
  Implement feature       18      16.4 h      72.8 h     4.4x
  Debug                   12       9.1 h      38.2 h     4.2x
  Refactor                 8       6.3 h      24.5 h     3.9x
  Write tests              5       3.8 h      13.3 h     3.5x
  Config / setup           4       2.6 h       7.6 h     2.9x

Three sessions produced negative ROI: two involved repeated corrections
to UI layout code where Claude lacked visual context, and one required
extensive manual rework of a database migration that the model generated
with incorrect column constraints.
```

---

### 9.2 Daily Sync Summary

**User query:**

```
/session-search Summarize what I worked on today for my team standup
```

#### Step 1: Session Mapping

The orchestrator classifies the query as "subset" because the word "today" constrains the time window to the current date. The orchestrator reads `~/.claude/session-search/index.jsonl` and filters entries whose `timestamp` falls on 2026-03-29. Four sessions match, all belonging to project `-Users-jane-api-server`.

#### Step 2: Data Extraction

**Task description sent to extraction subagent:**

> Extract a chronological record of work performed in each session. For each session, collect all user messages where message.content holds a string (direct prompts, not tool results), all tool_use entries from assistant messages (capturing the tool name and key input fields: file_path for Read, Edit, and Write; command for Bash; pattern for Grep and Glob), and any git commit commands found in Bash tool_use entries. Group the data by session, ordered by timestamp. Write the JSON output to the specified path.

**Python script the subagent writes and executes:**

```python
#!/usr/bin/env python3
"""Extract chronological work record for daily summary."""
import json
import sys

TOOL_KEY_FIELDS = {
    'Read': ['file_path'],
    'Edit': ['file_path'],
    'Write': ['file_path'],
    'Bash': ['command'],
    'Grep': ['pattern', 'glob'],
    'Glob': ['pattern'],
}

def extract_session(path):
    entries = []
    with open(path, 'r') as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                continue
    if not entries:
        return None

    session_id = entries[0].get('sessionId', '')
    start_time = entries[0].get('timestamp', '')
    user_prompts = []
    tools_used = []
    git_commits = []

    for entry in entries:
        etype = entry.get('type')
        content = entry.get('message', {}).get('content')

        if etype == 'user' and isinstance(content, str):
            user_prompts.append({
                'timestamp': entry.get('timestamp', ''),
                'text': content[:300]
            })

        if etype == 'assistant' and isinstance(content, list):
            for block in content:
                if not isinstance(block, dict) or block.get('type') != 'tool_use':
                    continue
                name = block.get('name', '')
                inp = block.get('input', {})
                key_fields = {}
                for field in TOOL_KEY_FIELDS.get(name, []):
                    val = inp.get(field, '')
                    if val:
                        key_fields[field] = (
                            val[:150] if isinstance(val, str) else val
                        )
                tools_used.append({
                    'timestamp': entry.get('timestamp', ''),
                    'name': name,
                    'input': key_fields
                })
                if name == 'Bash' and 'git commit' in inp.get('command', ''):
                    git_commits.append({
                        'timestamp': entry.get('timestamp', ''),
                        'command': inp.get('command', '')[:200]
                    })

    return {
        'session_id': session_id,
        'start_time': start_time,
        'user_prompts': user_prompts,
        'tools_used': tools_used,
        'git_commits': git_commits
    }

def main():
    with open(sys.argv[1], 'r') as f:
        session_paths = json.load(f)

    results = []
    for path in session_paths:
        record = extract_session(path)
        if record:
            results.append(record)

    results.sort(key=lambda r: r['start_time'])

    with open(sys.argv[2], 'w') as f:
        json.dump(results, f, indent=2)

if __name__ == '__main__':
    main()
```

#### Step 3: Analysis

**Custom system prompt the orchestrator constructs for the analysis subagent:**

> You are a technical writer producing a standup summary for a software team. Read the extracted session data from the provided JSON file. For each session, collapse the user prompts and tool activity into one or two concrete work items written in imperative mood (e.g., "Add rate limiting middleware to /api/v2 endpoints"). Classify each work item as one of: feature, bugfix, refactor, or research.
>
> Produce a 1-3 sentence executive summary describing the day at a high level, followed by categorized bullet lists. Infer specifics from file paths, command text, and user prompts. Do not include session IDs or timestamps in the output. Follow these writing rules: no contractions, active voice, present tense, no em dashes, no weak openers ("There is", "It is").

**Terminal output the user sees:**

```
Standup Summary: 2026-03-29
============================

Today focused on hardening the API server authentication layer and
resolving a pagination regression reported in issue #342. Four sessions
produced five deliverables across two categories.

Features
  - Add JWT refresh token rotation to the /auth/refresh endpoint,
    including a 7-day sliding window expiry and Redis-backed token
    family tracking
  - Implement request rate limiting middleware on all /api/v2
    endpoints using a token bucket algorithm (100 req/min default,
    configurable per API key)

Bug Fixes
  - Fix off-by-one error in cursor-based pagination that caused the
    final page to duplicate the last record (resolves #342)
  - Correct timezone handling in the audit log timestamps: store all
    values as UTC and convert to the caller's timezone on read
  - Update the OpenAPI spec to reflect the new rate-limit response
    headers (X-RateLimit-Remaining, X-RateLimit-Reset)
```

---

### 9.3 Skill Extraction

**User query:**

```
/session-search Find repeated patterns across my sessions that could become reusable skills
```

#### Step 1: Session Mapping

The orchestrator classifies the query as "all sessions" because pattern detection across behaviors requires the broadest possible sample. The orchestrator reads `~/.claude/session-search/index.jsonl` and collects every session ID. The index contains 47 sessions across 8 projects.

#### Step 2: Data Extraction

**Task description sent to extraction subagent:**

> Identify repeated behavioral patterns across all sessions. Extract all user messages where message.content holds a string (direct prompts), normalize each prompt by lowercasing and stripping file paths (using a regex matching sequences like /path/to/file.ext) and removing quoted strings. Build a frequency table of two-word and three-word n-grams from all normalized prompts across all sessions. Also extract tool_use sequences from each assistant entry: the ordered list of tool names called within a single assistant response. Count how often each unique tool sequence appears across all sessions. For each session, output the session_id, the first user prompt text, all normalized prompts, and all tool_use sequences. Also output global aggregates: the top 30 n-grams with their counts and the top 20 tool sequences with their counts and example session IDs. Write the JSON output to the specified path.

**Python script the subagent writes and executes:**

```python
#!/usr/bin/env python3
"""Extract repeated behavioral patterns for skill candidate identification."""
import json
import sys
import re
from collections import defaultdict

PATH_PATTERN = re.compile(r'[/\\][\w./\\-]+\.\w+')
QUOTED_PATTERN = re.compile(r'["\'].*?["\']')

def normalize(text):
    text = text.lower()
    text = PATH_PATTERN.sub('<PATH>', text)
    text = QUOTED_PATTERN.sub('<STR>', text)
    return text

def ngrams(text, n):
    words = text.split()
    return [' '.join(words[i:i+n]) for i in range(len(words) - n + 1)]

def process_session(path):
    entries = []
    with open(path, 'r') as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except (json.JSONDecodeError, ValueError):
                continue
    if not entries:
        return None

    session_id = entries[0].get('sessionId', '')
    first_prompt = None
    normalized_prompts = []
    tool_sequences = []

    for entry in entries:
        etype = entry.get('type')
        content = entry.get('message', {}).get('content')

        if etype == 'user' and isinstance(content, str):
            if first_prompt is None:
                first_prompt = content[:200]
            normalized_prompts.append(normalize(content))

        if etype == 'assistant' and isinstance(content, list):
            seq = []
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'tool_use':
                    seq.append(block.get('name', 'unknown'))
            if seq:
                tool_sequences.append(seq)

    return {
        'session_id': session_id,
        'first_prompt': first_prompt or '',
        'normalized_prompts': normalized_prompts,
        'tool_sequences': tool_sequences
    }

def main():
    with open(sys.argv[1], 'r') as f:
        session_paths = json.load(f)

    sessions = []
    all_prompts = []
    seq_counter = defaultdict(lambda: {'count': 0, 'sessions': []})

    for path in session_paths:
        record = process_session(path)
        if not record:
            continue
        sessions.append(record)
        all_prompts.extend(record['normalized_prompts'])

        for seq in record['tool_sequences']:
            key = ' -> '.join(seq)
            seq_counter[key]['count'] += 1
            sid = record['session_id']
            if sid not in seq_counter[key]['sessions']:
                seq_counter[key]['sessions'].append(sid)

    ngram_counts = defaultdict(int)
    for prompt in all_prompts:
        for n in (2, 3):
            for gram in ngrams(prompt, n):
                if '<PATH>' not in gram and '<STR>' not in gram:
                    ngram_counts[gram] += 1

    top_ngrams = sorted(ngram_counts.items(), key=lambda x: -x[1])[:30]
    top_sequences = sorted(
        seq_counter.items(), key=lambda x: -x[1]['count']
    )[:20]

    output = {
        'sessions': [
            {
                'session_id': s['session_id'],
                'first_prompt': s['first_prompt'],
                'prompt_count': len(s['normalized_prompts']),
                'sequence_count': len(s['tool_sequences'])
            }
            for s in sessions
        ],
        'top_ngrams': [
            {'ngram': g, 'count': c} for g, c in top_ngrams
        ],
        'top_tool_sequences': [
            {
                'sequence': k,
                'count': v['count'],
                'example_sessions': v['sessions'][:3]
            }
            for k, v in top_sequences
        ]
    }

    with open(sys.argv[2], 'w') as f:
        json.dump(output, f, indent=2)

if __name__ == '__main__':
    main()
```

#### Step 3: Analysis

**Custom system prompt the orchestrator constructs for the analysis subagent:**

> You are a developer experience expert specializing in workflow automation. Read the extracted pattern data from the provided JSON file. Identify behaviors that appear in 3 or more sessions and involve multi-step tool workflows (sequences of 3 or more tool calls). For each candidate, examine the n-gram data and tool sequences together to infer the user intent and the repeatable procedure.
>
> For each skill candidate, produce: a suggested skill name (kebab-case, concise), the frequency (number of sessions where the pattern appeared), a trigger condition describing when the skill should activate, numbered workflow steps describing what the skill performs, and a draft SKILL.md outline containing the frontmatter fields (name, description, version) and a body section explaining the skill behavior.
>
> Rank candidates by frequency descending. Output a header line with the total candidate count, then each numbered candidate. Follow these writing rules: no contractions, active voice, present tense, no em dashes, no weak openers.

**Terminal output the user sees:**

```
Skill Candidates: 5 Patterns Detected Across 47 Sessions
==========================================================

1. test-and-fix (14 sessions, 30%)

   Trigger: The user asks to run tests or fix failing tests.

   Workflow:
     1. Read the test file to understand existing structure
     2. Execute the test suite via Bash
     3. Grep the source code for the failing function or module
     4. Edit the source file to apply the fix
     5. Re-run the test suite to confirm the fix

   Draft SKILL.md:
     ---
     name: test-and-fix
     description: >
       Activate when the user requests test execution and the run
       produces failures. Reads test output, locates the root cause
       in source code, applies a fix, and validates by re-running.
     version: 1.0.0
     ---
     The skill reads the test command output, extracts failing test
     names and error messages, searches the codebase for the relevant
     source locations, applies minimal corrective edits, and
     re-executes the suite to confirm all tests pass.

2. explore-then-implement (11 sessions, 23%)

   Trigger: The user describes a feature that requires understanding
   existing code structure before writing new code.

   Workflow:
     1. Glob for files matching the relevant module or directory
     2. Read 2-4 files to understand existing patterns
     3. Grep for related symbols or interfaces
     4. Write or Edit one or more files to implement the feature
     5. Execute Bash to run linting or type checks

   Draft SKILL.md:
     ---
     name: explore-then-implement
     description: >
       Activate when the user requests a new feature and the codebase
       requires exploration before implementation. Surveys file
       structure, reads existing patterns, then writes new code that
       matches established conventions.
     version: 1.0.0
     ---
     The skill surveys the target module via Glob, reads key files to
     extract naming conventions and architectural patterns, searches
     for related interfaces with Grep, implements the requested
     feature using Write or Edit, and validates with a lint or
     type-check pass.

3. commit-with-context (8 sessions, 17%)

   Trigger: The user asks to commit changes or requests a commit
   message.

   Workflow:
     1. Execute git status and git diff via Bash
     2. Read modified files to understand the change context
     3. Execute git add with specific file paths via Bash
     4. Execute git commit with a contextual message via Bash

   Draft SKILL.md:
     ---
     name: commit-with-context
     description: >
       Activate when the user requests a git commit. Inspects the
       working tree, reads changed files for context, and produces
       a descriptive commit message summarizing intent.
     version: 1.0.0
     ---
     The skill runs git status and git diff to inventory changes,
     reads modified files to understand the purpose of each change,
     stages specific files, and commits with a message that captures
     the intent rather than restating the diff.

4. debug-from-error (6 sessions, 13%)

   Trigger: The user pastes an error message or stack trace, or a
   Bash command produces stderr output.

   Workflow:
     1. Grep the codebase for symbols mentioned in the error
     2. Read the file and surrounding context at the error location
     3. Edit the source to fix the identified issue
     4. Execute the original command via Bash to verify the fix

   Draft SKILL.md:
     ---
     name: debug-from-error
     description: >
       Activate when the user shares an error message or a tool
       execution produces an error. Traces the error to its source,
       applies a fix, and re-executes to verify resolution.
     version: 1.0.0
     ---
     The skill parses the error output for file references and symbol
     names, searches the codebase to locate the relevant source,
     reads surrounding context to understand the failure, applies the
     minimal fix, and reruns the failing command to confirm resolution.

5. refactor-rename (4 sessions, 9%)

   Trigger: The user asks to rename a function, variable, or module
   across the codebase.

   Workflow:
     1. Grep the codebase for all occurrences of the target symbol
     2. Read each file containing the symbol to confirm context
     3. Edit each file to apply the rename
     4. Execute the test suite via Bash to detect breakage

   Draft SKILL.md:
     ---
     name: refactor-rename
     description: >
       Activate when the user requests renaming a symbol across the
       codebase. Finds all occurrences, applies consistent renames,
       and runs tests to verify nothing breaks.
     version: 1.0.0
     ---
     The skill searches for every occurrence of the target name using
     Grep, reads each containing file to distinguish true references
     from coincidental string matches, applies the rename via Edit
     with replace_all, and runs the project test suite to catch
     regressions.
```

## 10. Plugin Manifest: `plugin.json`

The plugin manifest lives at `.claude-plugin/plugin.json` and declares the plugin to the Claude Code runtime.

```json
{
  "name": "session-search",
  "description": "Semantically search Claude Code session logs to extract custom insights including ROI analysis, work summaries, and skill extraction",
  "version": "0.1.0",
  "author": {
    "name": "Sebastian Tremblay"
  },
  "license": "MIT"
}
```

The `name` field serves as the unique identifier across all installed plugins. The `description` field drives plugin discovery: Claude Code matches user queries against this text when deciding which plugin capabilities to surface, so the description should contain the key action verbs and nouns a user might type. The `version` field follows semantic versioning and tracks the plugin release independently of Claude Code itself.

## 11. Command File: `commands/session-search.md`

### Frontmatter

```yaml
---
description: Semantically search Claude Code session logs to extract custom insights
argument-hint: <query>
allowed-tools: [Bash, Read, Write, Agent, Glob, Grep]
---
```

### Command Body

The following markdown forms the body of `commands/session-search.md`, placed after the frontmatter:

````markdown
# Session Search

The user invoked this command with query: $ARGUMENTS

## Orchestration

Execute these three steps in sequence.

Before starting, generate a unique run identifier:
```bash
RUN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
```
Use this identifier in all temporary file paths below.

### Step 1: Session Mapping

1. Read `~/.claude/session-search/index.jsonl`. If the file does not exist or contains zero lines, inform the user that no sessions have been summarized yet and suggest running retroactive summarization. Stop.
2. Parse each line as JSON. Each line contains: `sessionId`, `projectId`, `timestamp`, and `summary`.
3. Classify the query:
   - **All sessions**: queries about aggregate statistics, broad patterns, ROI, or skill extraction select every session.
   - **Subset**: queries about a specific time range ("today", "this week"), project, or topic select only sessions whose `summary` or `timestamp` fields match the query intent.
4. Produce a list of matching session IDs and resolve each to its file path: `~/.claude/projects/<projectId>/<sessionId>.jsonl`.
5. If the query requires richer context for session selection, read the corresponding entries from `~/.claude/session-search/takeaways.jsonl` (keyed by `sessionId`) to access the 3-5 sentence takeaways for each session.
6. If zero sessions match, inform the user and suggest broadening the query. Stop.
7. If any session files exist in `~/.claude/projects/` that lack entries in `index.jsonl`, print: "Found N sessions without summaries. Run `summarize-session --backfill` to generate missing summaries." Continue with the sessions that already have summaries.
8. Write the matched file paths as a JSON array to `/tmp/session-search-manifest-${RUN_ID}.json`.

### Step 2: Data Extraction

1. Verify Python 3 availability by running `python3 --version`. If the command fails, print installation instructions and stop.
2. Determine what data the analysis step needs based on the user's query. Write a clear task description specifying exactly which fields to extract from the session logs.
3. Spawn a subagent using the Agent tool with model `haiku` and the following prompt structure:

   > You write and execute Python 3 scripts that extract data from Claude Code session logs.
   >
   > ## Session Log Schema
   > Session logs reside at `~/.claude/projects/<project-id>/<session-id>.jsonl`. Each line contains a JSON object. Key entry types:
   > - `user` entries: `message.content` holds either a string (direct user input) or an array of content blocks (tool results with `type: "tool_result"`)
   > - `assistant` entries: `message.content` holds an array with `{type: "thinking"}`, `{type: "text"}`, and `{type: "tool_use", name: "...", input: {...}}` blocks. `message.model` identifies the model. `message.usage` contains token counts.
   > - Universal fields: `uuid`, `timestamp` (ISO 8601), `sessionId`, `cwd`, `gitBranch`
   >
   > ## Task
   > [Insert the task description from above]
   >
   > ## Session Files
   > Read the manifest at `/tmp/session-search-manifest-${RUN_ID}.json` for the list of session file paths.
   >
   > ## Requirements
   > 1. Write a Python 3 script to `/tmp/session-search-extract-${RUN_ID}.py`
   > 2. Use only standard library modules (json, os, sys, re, datetime, collections, pathlib)
   > 3. Read JSONL files line by line. Skip malformed lines with try/except around json.loads()
   > 4. Write output as JSON to `/tmp/session-search-output-${RUN_ID}.json`
   > 5. Execute: `python3 /tmp/session-search-extract-${RUN_ID}.py`
   > 6. Verify the output file contains valid JSON
   > 7. If the script fails to execute or produces invalid JSON, read the stderr output, diagnose the error, fix the script, and re-execute. Allow up to 2 retries before reporting failure.
   > 8. The output JSON must stay under 50,000 characters. Aggregate data within the script: compute counts, top-N lists, averages, and statistical summaries rather than emitting raw per-entry arrays. The analysis subagent receives this output in its context window, so token efficiency is a hard constraint.

4. Wait for the subagent to complete.

### Step 3: Analysis

1. Build a system prompt tailored to the user's query. The prompt must include:
   - The user's original query (verbatim)
   - Analysis methodology specific to the query type
   - Output format expectations
   - Writing style constraints: no contractions, active voice, present tense, no em dashes
2. Spawn an analysis subagent using the Agent tool with the custom system prompt:

   > Read the extracted session data from `/tmp/session-search-output-${RUN_ID}.json` and answer the following query:
   >
   > **User query**: $ARGUMENTS
   >
   > [Insert tailored analysis instructions]
   >
   > Print the complete analysis directly to the terminal using markdown formatting.

3. Wait for the subagent to complete.

### Cleanup

Remove temporary files:
```
rm -f /tmp/session-search-manifest-${RUN_ID}.json /tmp/session-search-extract-${RUN_ID}.py /tmp/session-search-output-${RUN_ID}.json
```
````

## 12. Summarization Script: `scripts/summarize-session.sh`

The summarization script runs as the hook handler invoked on `SessionEnd`. The hook passes session metadata through environment variables. The script expects `SESSION_ID` to contain the session identifier. The script verifies `jq` availability at startup and exits with a diagnostic message if the binary is not found.

```bash
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
```

The script follows a linear flow: locate, check, summarize, parse, append. Each failure mode produces a descriptive message on stderr and exits with a non-zero status, leaving the index files unmodified. The `set -euo pipefail` directive ensures any unexpected failure halts execution immediately rather than silently corrupting data.

## 13. Error Handling and Edge Cases

### 13.1 Empty Index

The orchestrator detects an empty or missing `index.jsonl` during Step 1 and informs the user that no sessions have been summarized. The response suggests running retroactive summarization against existing session files.

### 13.2 Missing Session Files

A session ID in the index may reference a JSONL file that no longer exists on disk. The extraction subagent skips any file path that fails to open, logs the missing path, and continues processing the remaining sessions. The final analysis notes how many sessions were unavailable.

### 13.3 Malformed JSONL Lines

The extraction script wraps each `json.loads()` call in a try/except block. Lines that raise a `JSONDecodeError` increment a skip counter silently. Processing continues with the next line. The script never terminates due to a single malformed entry.

### 13.4 `claude -p` Failure

The summarization script checks the exit code of `claude -p`. A non-zero exit code triggers an error message to stderr that includes the session ID, and the script exits without writing to any index file. Subsequent hook invocations for other sessions proceed independently.

### 13.5 Python Not Available

Before the extraction subagent writes its script, the orchestrator runs `python3 --version` and inspects the exit code. A missing Python 3 installation causes the orchestrator to print platform-specific installation instructions (Homebrew for macOS, apt for Debian/Ubuntu) and halt execution.

### 13.6 No Matching Sessions

The query classification in Step 1 may produce zero matching sessions after filtering the index. The orchestrator informs the user that no sessions matched the query criteria and suggests broadening the search terms or adjusting the time range.

### 13.7 Large Session Files

Session logs can exceed 10 MB for long-running sessions. The extraction script opens each file with a standard file handle and iterates line by line, never calling `read()` or `readlines()` on the entire file. Memory usage remains proportional to the size of a single JSONL line rather than the total file size.

### 13.8 Concurrent Hook Execution

Multiple `SessionEnd` events may fire within a short window when a user closes several sessions simultaneously. The append-only JSONL format tolerates concurrent writes at the filesystem level for typical usage patterns. The duplicate-check grep in the summarization script prevents the same session from producing multiple index entries.

### 13.9 Missing Summary Store Directory

The summarization script calls `mkdir -p ~/.claude/session-search/` before any file operations. The `-p` flag creates the directory if absent and succeeds silently if the directory already exists, eliminating the need for a separate existence check.

### 13.10 Extraction Script Failure

If the extraction script fails to execute or produces invalid output, the extraction subagent reads the stderr, corrects the script, and re-executes. The subagent allows up to two retries. After three total attempts, the subagent reports failure and the orchestrator informs the user that extraction could not complete for the given query.

## 14. Out of Scope for v0

1. **Persistent search history.** Storing past queries and results adds complexity without clear value until usage patterns emerge from real sessions.
2. **Vector embedding search.** Semantic similarity search over embeddings requires a vector store dependency that exceeds the minimal footprint goal of v0.
3. **Interactive follow-up queries.** Multi-turn conversation within the plugin command requires state management that the single-shot `/session-search` architecture does not support.
4. **Web UI or HTML report generation.** Visual output formats demand front-end tooling and a rendering pipeline orthogonal to the core search functionality.
5. **Cross-machine session search.** Aggregating session logs from multiple machines requires a sync or upload mechanism that introduces network dependencies.
6. **Session log export or backup.** Export functionality duplicates what users can already achieve with standard file-copy tools against the known directory structure.
7. **Configurable output destinations.** Output routing adds option complexity; v0 prints to the terminal and lets users redirect as needed.
8. **Custom extraction script templates.** The subagent already generates extraction logic dynamically from the natural language query, making templates a premature optimization.