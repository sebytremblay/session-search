# Spec Migration 01: Robustness and Consistency Fixes

This document addresses five gaps identified in the original specification. Each section states the gap, the reasoning for accepting it, and the concrete changes required.

## Migration 1: Remove Interactive Prompt from Retroactive Summarization

### Gap

Section 4.6 instructs the orchestrator to ask the user for confirmation before generating missing summaries and wait for a response. Section 14.3 declares that the single-shot `/session-search` architecture does not support multi-turn conversation. These two sections contradict each other: a single-shot command cannot pause mid-execution for user input.

### Reasoning

The single-shot constraint is a deliberate architectural boundary. Breaking it to support one confirmation dialog introduces state management complexity that Section 14.3 explicitly rejects. The retroactive summarization workflow should degrade gracefully without requiring interaction.

### Changes

**Section 4.6** (`docs/design/SPEC.md`): Replace the current three-step flow with:

1. Print: "Found N sessions without summaries."
2. Print: "Run `summarize-session --backfill` to generate missing summaries."
3. Continue with the search using only the sessions that already have summaries.

**Section 6.3** (`docs/design/SPEC.md`): Update the unsummarized session handling to match the new Section 4.6 flow.

**Step 1 in command template** (`commands/session-search.md`): Remove any instruction to ask the user for confirmation. Add an instruction to print the warning and the copy-pasteable command, then proceed with available sessions.

### Files Affected

- `docs/design/SPEC.md` (Sections 4.6, 6.3)
- `commands/session-search.md` (Step 1)

---

## Migration 2: Add jq Dependency Check to Summarization Hook

### Gap

`summarize-session.sh` calls `jq` on lines 31, 49, 55, and 61 but never verifies that `jq` is installed. The spec checks for `python3` availability in Step 2 of the search command but omits the analogous check for `jq` in the hook. A missing `jq` binary produces a confusing "command not found" error mid-execution rather than a clear diagnostic at startup.

### Reasoning

Dependency checks belong at the top of any script that relies on external binaries. The spec already establishes this pattern for `python3`. Applying the same pattern to `jq` costs one line and eliminates a class of confusing failures.

### Changes

**`scripts/summarize-session.sh`**: Add the following guard immediately after `set -euo pipefail` and before any logic:

```bash
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed" >&2; exit 1; }
```

**Section 4 of the spec** (`docs/design/SPEC.md`): Document the `jq` dependency requirement in the summarization hook description.

### Files Affected

- `scripts/summarize-session.sh`
- `docs/design/SPEC.md` (Section 4)

---

## Migration 3: Add Retry Loop for Extraction Script Failures

### Gap

Step 2 instructs the extraction subagent to write and execute a Python script, then verify valid JSON output. The spec does not define what happens when the Python script crashes with a `SyntaxError`, `KeyError`, or other exception before writing any output. The subagent validates the output file but has no recovery path when the script never produces one.

### Reasoning

LLM-generated code can contain syntax errors, undefined variable references, or logic mistakes. A single failure does not indicate the approach is wrong; feeding the error back to the subagent and allowing a retry is standard practice for LLM-driven code generation. Two retries balance reliability against cost (each retry consumes a Haiku inference call).

### Changes

**Step 2 prompt template** (`commands/session-search.md` and `docs/design/SPEC.md` Section 7): Add a requirement after the existing "Verify the output file contains valid JSON" step:

```
7. If the script fails to execute or produces invalid JSON, read the stderr output,
   diagnose the error, fix the script, and re-execute. Allow up to 2 retries
   before reporting failure to the orchestrator.
```

**Section 13** (`docs/design/SPEC.md`): Add a new subsection "Extraction Script Failure" documenting the retry behavior:

> If the extraction script fails or produces invalid output, the extraction subagent reads the stderr, corrects the script, and re-executes. The subagent allows up to two retries. After three total attempts, the subagent reports failure and the orchestrator informs the user that extraction could not complete for the given query.

### Files Affected

- `commands/session-search.md` (Step 2 requirements)
- `docs/design/SPEC.md` (Section 7, Section 13)

---

## Migration 4: Formalize Aggregation Constraint for Extraction Output

### Gap

For "all sessions" queries, the extraction script processes every session file and writes results to a JSON output file. The analysis subagent then reads this file into its context window. With hundreds of sessions, raw per-entry data extraction could produce output exceeding the analysis subagent's effective context, leading to truncated analysis or degraded quality.

The spec's walked examples already demonstrate good aggregation practice (the ROI example computes per-session metrics, the skill extraction example limits to top-N). But the Step 2 prompt template does not formalize this constraint, leaving it to the subagent's discretion.

### Reasoning

Formalizing the aggregation constraint in the prompt template ensures consistent behavior across all query types, not just the walked examples. The extraction script should output counts, top-N lists, and statistical aggregates rather than raw arrays of per-entry data.

### Changes

**Step 2 prompt template** (`commands/session-search.md` and `docs/design/SPEC.md` Section 7): Add the following requirement to the subagent prompt:

```
The output JSON must stay under 50,000 characters. Aggregate data within the Python
script: compute counts, top-N lists, averages, and statistical summaries rather than
emitting raw per-entry arrays. The analysis subagent receives this output in its
context window, so token efficiency is a hard constraint.
```

### Files Affected

- `commands/session-search.md` (Step 2 requirements)
- `docs/design/SPEC.md` (Section 7)

---

## Migration 5: Align Temp File Paths with UUID Convention

### Gap

The spec's design sections (2.2, 5.3, 7.3) specify temp file paths with UUID suffixes: `/tmp/session-search-<uuid>.py`, `/tmp/session-search-<uuid>.json`. The command template in Appendix B (which became `commands/session-search.md`) uses fixed paths: `/tmp/session-search-extract.py`, `/tmp/session-search-manifest.json`, `/tmp/session-search-output.json`. This internal inconsistency means two concurrent `/session-search` invocations in different terminals would overwrite each other's temporary files.

### Reasoning

The spec already made the correct design decision in Sections 2.2 and 7.3. The command template simply was not updated to match. Aligning the implementation with the existing design eliminates the race condition at zero design cost.

### Changes

**`commands/session-search.md`**: At the top of the orchestration section, add an instruction to generate a run ID:

```
Before starting, generate a unique run identifier by executing:
RUN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
```

Then replace all fixed temp paths:
- `/tmp/session-search-manifest.json` becomes `/tmp/session-search-manifest-${RUN_ID}.json`
- `/tmp/session-search-extract.py` becomes `/tmp/session-search-extract-${RUN_ID}.py`
- `/tmp/session-search-output.json` becomes `/tmp/session-search-output-${RUN_ID}.json`

Update the cleanup section to use the same variables.

**`docs/design/SPEC.md` Appendix B**: Update to match the command template.

### Files Affected

- `commands/session-search.md` (all temp file references)
- `docs/design/SPEC.md` (Appendix B)

---

## Items Reviewed and Discarded

The following feedback items were evaluated and rejected:

| Item | Reason for Rejection |
|------|---------------------|
| **flock for concurrent JSONL appends** | Index lines are ~200-400 bytes, takeaways ~400-900 bytes. Both fall under local filesystem atomicity thresholds. `flock` is not available as a CLI on macOS by default, making the recommendation non-portable. The duplicate-check grep already prevents the most visible failure mode. Section 13.8 already acknowledges and accepts this risk. |
| **File path length limits (hash project ID)** | The plugin does not create project directories. Claude Code owns those paths. The plugin reads existing paths and stores `projectId` as a JSONL string field. If the OS accepted the path when Claude Code created it, the plugin can read it. |
| **Model naming (use full model IDs)** | `haiku` is a valid Claude Code model alias that resolves to the current Haiku version. Full model IDs like `claude-3-5-haiku-20241022` would couple the spec to specific model releases. |
