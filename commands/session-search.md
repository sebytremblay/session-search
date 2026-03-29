---
description: Semantically search Claude Code session logs to extract custom insights
argument-hint: <query>
allowed-tools: [Bash, Read, Write, Agent, Glob, Grep]
---

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
