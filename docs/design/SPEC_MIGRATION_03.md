# Spec Migration 03: Runtime Performance

This migration addresses five bottlenecks that cause the search pipeline to exceed eight minutes on Sonnet. The accepted changes deliver sub-three-minute execution for subset queries and sub-four-minute execution for all-sessions queries, while preserving the subagent isolation architecture.

## Migration 1: Pre-flight Validation Block

### Gap

`python3 --version` runs at Step 2.2.a, after the Pre-Step cold-start detection and all of Step 1 complete. For facet-insufficient queries, the orchestrator finishes session mapping, facet sufficiency determination, and manifest writing before a missing Python 3 installation triggers a hard stop. The Pre-Step cold-start import path also invokes Python 3 without a prior guard. On a machine without Python 3, one to two minutes of orchestration completes before the system surfaces an unrecoverable failure.

### Reasoning

Precondition checks belong at the system boundary. The existing guard in `scripts/summarize-session.sh` establishes this pattern: the `jq` check runs on line 3, before any logic executes. Applying the same discipline to `python3` surfaces failures in under five seconds rather than after a full pipeline execution.

The RUN_ID generation (`python3 -c "import uuid; ..."`) also depends on Python 3. Consolidating RUN_ID generation and the availability check into a single pre-flight block eliminates the possibility of a mismatch between steps and makes the dependency explicit.

### Changes

**`commands/session-search.md`**: Replace the current `RUN_ID` generation preamble with a named "Pre-flight" section as the first item under Orchestration, placed before the Pre-Step cold-start detection:

```
### Pre-flight

Run the following checks before any other step. Execute both commands:

```bash
python3 --version
RUN_ID=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
```

If `python3 --version` fails, print:

    Python 3 is required. Install it via Homebrew (macOS: brew install python3) or apt (Debian/Ubuntu: apt install python3). Stop.

Use RUN_ID in all temporary file paths below.
```

Remove the existing `RUN_ID` generation block that precedes the Pre-Step. Remove the `python3 --version` check from Step 2.2.a; that sub-step collapses into a direct task description without the availability check.

**Section 5.2** (`docs/design/SPEC.md`): Add "Pre-flight" as the first node in the orchestration overview diagram, positioned before "Pre-Step: Cold Start Detection."

**Section 13.5** (`docs/design/SPEC.md`): Update the "Python Not Available" error handling section to state that the pre-flight block detects the missing installation before any session mapping or cold-start import work begins.

### Files Affected

- `commands/session-search.md` (new Pre-flight section, removed standalone RUN_ID block, removed Step 2.2.a availability check)
- `docs/design/SPEC.md` (Sections 5.2, 13.5)

---

## Migration 2: Remove Missing Facets Glob Scan from Critical Path

### Gap

Step 1.8 instructs the orchestrator to use `Glob` to find all non-agent `*.jsonl` files in `~/.claude/projects/*/`, compare them against the session IDs in the facet partition files, and print a warning if any sessions lack facets. The scan fires on every query, including queries that already return meaningful results. On a machine with hundreds of project directories, this traversal adds thirty to ninety seconds to every run. The output is advisory: the orchestrator prints a message and continues regardless of what it finds.

### Reasoning

Work that does not change the output does not belong on the critical path. Every session without a facet is a session the query already excludes. The user receives the correct result for their matched session set whether or not the warning appears. Surfacing the backfill suggestion only when zero sessions match preserves discoverability at the one point where it provides actionable guidance: when the user receives no results and may not understand why.

### Changes

**`commands/session-search.md`**: Remove Step 1.8 entirely. Update Step 1.4 (the zero-match branch) from:

> If zero sessions match, inform the user and suggest broadening the query. Stop.

to:

> If zero sessions match, inform the user that no sessions matched the query. Note that older sessions may lack facets; suggest running `/insights` to backfill and broadening the search terms. Stop.

**Section 6.5** (`docs/design/SPEC.md`): Remove the "Missing Facets" subsection in its entirety.

**Section 4.6** (`docs/design/SPEC.md`): Clarify that the orchestrator reports the backfill guidance only when zero sessions match the query, not after every successful query.

**Section 5.2** (`docs/design/SPEC.md`): Remove the cross-reference step from the orchestration overview.

### Files Affected

- `commands/session-search.md` (remove Step 1.8, update Step 1.4 zero-match branch)
- `docs/design/SPEC.md` (remove Section 6.5, update Sections 4.6 and 5.2)

---

## Migration 3: Remove Extraction Manifest — Embed Session Paths in Subagent Prompt

### Gap

For facet-insufficient queries, Step 1.7 writes the matched session file paths as a JSON array to `/tmp/session-search-manifest-${RUN_ID}.json`. The extraction subagent then reads this file as its first tool call before writing the extraction script. The orchestrator holds the session file paths in memory at the point of subagent spawn. Routing the paths through a temporary file adds one Write tool call (orchestrator) and one Read tool call (Haiku subagent) to the critical path before any extraction logic runs.

### Reasoning

The manifest file serves as an interface between two sequential steps, but no concurrency requires this interface. The orchestrator spawns the extraction subagent synchronously and can place the paths directly in the subagent prompt. Embedding the paths eliminates two file operations and reduces the Haiku subagent's startup sequence from three steps (read manifest, write script, execute script) to two (write script, execute script). For a daily sync query with four matched sessions, each path measures approximately eighty characters. A forty-session all-sessions query produces roughly 3,200 characters of path data, well within prompt size limits.

The extraction script replaces the `sys.argv[1]` manifest read with a `SESSION_PATHS` list literal defined at the top of the script. The `OUTPUT_PATH` constant retains the parameterized temp path using RUN_ID.

### Changes

**`commands/session-search.md`**: Remove Step 1.7 (the manifest write instruction). In the Step 2 subagent prompt, replace the "Session Files" block:

> **Session Files**
> Read the manifest at `/tmp/session-search-manifest-${RUN_ID}.json` for the list of session file paths.

with:

> **Session Files**
> Process the following session file paths (insert the resolved paths from Step 1 as a JSON array literal):
> ```
> SESSION_PATHS = [
>   "/path/to/session1.jsonl",
>   "/path/to/session2.jsonl"
> ]
> OUTPUT_PATH = "/tmp/session-search-output-${RUN_ID}.json"
> ```
> Define these as top-level constants at the start of the extraction script. Do not read paths from a file argument.

Remove `/tmp/session-search-manifest-${RUN_ID}.json` from the cleanup block.

**Section 2.2** (`docs/design/SPEC.md`): Remove the manifest temp file path (`/tmp/session-search-<uuid>.py manifest`) from the Runtime Data Paths table. The table retains the extraction script path and the extraction output path.

**Section 7.2** (`docs/design/SPEC.md`): Update the subagent prompt template to show the embedded-paths pattern rather than the manifest file reference. Remove the manifest-read requirement from the Requirements list.

**Section 7.4** (`docs/design/SPEC.md`): Update the Script Requirements section to state that session paths arrive as a `SESSION_PATHS` list literal defined at the top of the script, not via `sys.argv`.

**Sections 9.1, 9.2, and 9.3** (`docs/design/SPEC.md`): Update the Python extraction script examples in all three walked examples. Replace the `main()` function's `sys.argv[1]` manifest read with a top-level `SESSION_PATHS = [...]` constant. Replace `sys.argv[2]` with a top-level `OUTPUT_PATH = "/tmp/session-search-output-<uuid>.json"` constant. Update the orchestration narrative in each Step 2 section to remove the manifest write.

### Files Affected

- `commands/session-search.md` (remove Step 1.7, update Step 2 subagent prompt Session Files block, update cleanup)
- `docs/design/SPEC.md` (Sections 2.2, 7.2, 7.4, 9.1, 9.2, 9.3)

---

## Migration 4: Use Haiku for Analysis Subagent

### Gap

Section 8.1 specifies "default session model (inherits from the user's Claude Code configuration)" for the analysis subagent. On Sonnet or Opus, the analysis subagent takes ninety to one hundred twenty seconds to produce output. The analysis task does not require a frontier model: the subagent reads structured JSON data (extracted session records or facet arrays) and fills a predefined format. It performs no open-ended reasoning, no tool planning, and no multi-step problem solving. Haiku processes the same structured input in fifteen to thirty seconds with equivalent output quality for all three canonical query types.

### Reasoning

The analysis subagent's bottleneck is not reasoning depth. The extraction subagent and facet-sufficiency logic already reduce the raw session data to well-structured fields. The bottleneck is inference latency on a model sized for general-purpose tasks. Haiku's speed advantage (approximately five to eight times faster than Sonnet on output-bound tasks) applies directly here because the analysis subagent reads a file and produces formatted output in one inference pass. The quality of a standup summary, ROI table, or skill candidate list depends on the quality of the extracted data, not on the reasoning capacity of the model that formats it.

### Changes

**`commands/session-search.md`**: Update the Step 3 `Agent` tool call to specify `model: haiku`.

**Section 8.1** (`docs/design/SPEC.md`): Replace:

> **Model:** default session model (inherits from the user's Claude Code configuration)

with:

> **Model:** `haiku` (optimized for speed on structured formatting and summarization tasks)

### Files Affected

- `commands/session-search.md` (Step 3 Agent call, add `model: haiku`)
- `docs/design/SPEC.md` (Section 8.1)

---

## Migration 5: Pre-define Analysis Templates in the Command Template

### Gap

Step 3.1 instructs the orchestrator to "build a system prompt tailored to the user's query" including analysis methodology, output format expectations, and writing style constraints. The orchestrator reasons about the query type and generates this prompt from scratch on every run, consuming a full Sonnet inference turn before the analysis subagent spawns. The walked examples in Section 9 establish that three categories account for the vast majority of queries: time/project-bounded summarization (daily sync, this week), all-sessions analytical (ROI, satisfaction, friction, helpfulness), and all-sessions pattern detection (skills, repeated behaviors). Within each category, the methodology does not change between runs; only the user query and data source vary.

### Reasoning

Prompt construction is not creative work for these established categories. The orchestrator iterates over the same analysis methodology and output format requirements each time. Embedding three named templates in the command file converts prompt construction from a reasoning task to a selection: the orchestrator reads the query classification from Step 1, selects the matching template, and substitutes the user query verbatim. This eliminates one Sonnet inference turn before the analysis subagent spawns. For unrecognized query types, a minimal generic fallback template preserves the ability to handle novel queries.

### Changes

**`commands/session-search.md`**: Add an "Analysis Templates" reference section between the Pre-flight block and the Pre-Step. Define three named templates and one fallback:

- **`TEMPLATE_SUBSET_SUMMARY`**: For time/project-bounded summarization queries. Instructs the analysis subagent to collapse session activity into concrete work items per session, classify each as feature, bugfix, refactor, or research, and produce a 1-3 sentence executive summary followed by categorized bullet lists. Applies writing style constraints: no contractions, active voice, present tense, no em dashes, no weak openers.

- **`TEMPLATE_ALL_ANALYTICAL`**: For ROI, satisfaction, friction, and helpfulness analyses. Instructs the analysis subagent to compute aggregate metrics from the structured data, apply the productivity multiplier heuristics documented in Section 9.1, and produce a key metrics block with a category breakdown table.

- **`TEMPLATE_ALL_PATTERN`**: For skill extraction and repeated behavior detection. Instructs the analysis subagent to identify patterns appearing in three or more sessions, rank by frequency descending, and produce numbered skill candidates with trigger conditions and workflow steps.

- **`TEMPLATE_GENERIC_FALLBACK`**: For unclassified queries. Instructs the analysis subagent to produce a structured response to the user's query from the available data, with writing style constraints applied.

Replace Step 3.1 with:

> Select the analysis template that matches the query classification from Step 1:
> - Subset queries: use TEMPLATE_SUBSET_SUMMARY
> - All-sessions queries requiring computed metrics or ratings: use TEMPLATE_ALL_ANALYTICAL
> - All-sessions queries requiring behavioral patterns or skill detection: use TEMPLATE_ALL_PATTERN
> - Queries that match none of the above: use TEMPLATE_GENERIC_FALLBACK
>
> Substitute the user's query verbatim into the template's query placeholder. Substitute the data source path (facets file or extraction output file) into the template's data source placeholder.

**Section 8.2** (`docs/design/SPEC.md`): Replace the prompt construction description with a template selection description. Document the four template names, their target query categories, and the fallback behavior. Note that the templates embed the writing style constraints from `docs/guides/WRITING_STYLE.md` so the orchestrator does not need to re-specify them at runtime.

### Files Affected

- `commands/session-search.md` (new Analysis Templates section, updated Step 3.1)
- `docs/design/SPEC.md` (Section 8.2)

---

## Items Reviewed and Discarded

| Item | Reason for Rejection |
|------|---------------------|
| **Inline extraction (eliminate Haiku subagent)** | Running extraction in the orchestrator's main thread pollutes the context window with the session log schema, Python code, and execution output, increasing token count on every subsequent inference turn. Subagent isolation keeps the orchestrator context lean for the remaining steps. |
| **Inline analysis (eliminate analysis subagent)** | Running analysis in the orchestrator's main thread adds the extracted JSON output and analysis reasoning to the orchestrator context. The analysis subagent starts from a clean context with only the data it needs, producing faster and more focused output. |
| **Pre-built extraction scripts** | Shipping hardcoded scripts for ROI, daily sync, and skill extraction creates a maintenance burden when the session log schema evolves. SPEC.md Sections 7.3 and 14.8 document the rationale for dynamic script generation: each query type demands different fields, and the extraction subagent adapts without a library of hardcoded extractors. |
| **Caching extracted data between queries** | Caching introduces statefulness into a single-shot command. SPEC.md Section 14.3 explicitly excludes persistent search history and multi-turn state from v0 scope. |
| **Stdout capture instead of temp output file** | The Bash tool output carries an uncertain size ceiling depending on the Claude Code runtime. Routing extraction results through a temp file maintains a well-understood, size-bounded interface between the extraction subagent and the analysis subagent. |
| **Reducing the 50,000-character extraction limit** | The limit protects the analysis subagent's effective context on all-sessions queries. Reducing it risks truncating data necessary for accurate ROI or pattern analyses. |
