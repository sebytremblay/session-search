# Spec Migration 02: Facet Integration

This migration replaces the summary and takeaways storage format with Anthropic-compatible facets, adds cold-start import logic, introduces facet-first query optimization, and abandons the legacy index files.

## Migration 1: Replace Summary Storage with Facet Partitions

### Gap

Sections 2.2, 4.3-4.6 define a dual-file storage format (`index.jsonl` + `takeaways.jsonl`) with flat summaries. This format lacks the structured metadata that Anthropic's facet system provides: outcome, helpfulness, friction counts, session type, goal categories, and satisfaction levels. Every query must parse raw session logs even when structured fields could answer directly.

### Reasoning

Facets provide richer metadata per session at equivalent storage cost. Aligning with Anthropic's schema enables importing existing facets from `/insights` and creates a shared vocabulary across Claude Code tooling. Project-partitioned JSONL files (`~/.claude/session-search/facets/<projectId>.jsonl`) scale better than a single global file as session counts grow, and concurrent hook writes from different projects never contend on the same file.

### Changes

**Section 2.2** (`docs/design/SPEC.md`): Replace `index.jsonl` and `takeaways.jsonl` paths with `facets/<projectId>.jsonl` and `errors.log`.

**Section 4.3** (`docs/design/SPEC.md`): Rewrite summarization flow for facet generation with background execution via `nohup` + `timeout 30s`.

**Section 4.4** (`docs/design/SPEC.md`): Replace summarization prompt with facet extraction prompt producing 11 structured fields.

**Section 4.5** (`docs/design/SPEC.md`): Replace storage schema with facet partition line format (sessionId, projectId, timestamp, underlying_goal, goal_categories, outcome, user_satisfaction_counts, claude_helpfulness, session_type, friction_counts, friction_detail, primary_success, brief_summary).

**Section 4.6** (`docs/design/SPEC.md`): Replace retroactive summarization guidance with cold-start import flow.

**New Section 4.7** (`docs/design/SPEC.md`): Error observability via `errors.log`.

**New Section 4.8** (`docs/design/SPEC.md`): Cold-start detection and import from `~/.claude/usage-data/facets/`.

### Files Affected

- `docs/design/SPEC.md` (Sections 2.2, 4.3-4.8, 13)
- `scripts/summarize-session.sh` (full rewrite)

---

## Migration 2: Facet-First Query Optimization

### Gap

Section 7 sends all queries through raw session log extraction via Python scripts. For queries answerable from structured metadata (outcome distributions, helpfulness ratings, friction analysis, goal category breakdowns), the extraction subagent and Python script are unnecessary overhead.

### Reasoning

Skipping raw log parsing for facet-sufficient queries eliminates the extraction subagent call entirely, reducing latency and cost by one LLM invocation. The facet schema covers a meaningful subset of common queries: satisfaction trends, friction patterns, session type distributions, and goal category analysis all resolve from facet fields alone.

### Changes

**Section 5.2** (`docs/design/SPEC.md`): Add facet-first decision branch to orchestration overview, including new Pre-Step for cold-start detection.

**Section 6** (`docs/design/SPEC.md`): Rewrite session mapping to read facet partition files instead of `index.jsonl`, add facet-sufficiency determination.

**Section 7** (`docs/design/SPEC.md`): Add facet-sufficient fast path that bypasses extraction subagent entirely.

**Extraction subagent prompt** (`docs/design/SPEC.md` Section 7, `commands/session-search.md` Step 2): Update to receive facet data as supplementary context alongside raw session manifest.

### Files Affected

- `docs/design/SPEC.md` (Sections 5.2, 6, 7)
- `commands/session-search.md` (Steps 1 and 2)

---

## Migration 3: Cold-Start Import Flow

### Gap

The spec assumes the SessionEnd hook populates the index over time. New installs have zero data. Anthropic's `/insights` command may have already generated facets for past sessions at `~/.claude/usage-data/facets/`. The spec provides no mechanism to leverage this existing data.

### Reasoning

Importing existing facets eliminates the cold-start problem for users who have previously run `/insights`. For users without existing facets, inline generation for small session counts (five or fewer) provides immediate value without excessive API calls. The five-session threshold caps query-time latency at approximately 25-75 seconds. Beyond five sessions, the user generates facets asynchronously via `/insights`.

### Changes

**New Section 4.8** (`docs/design/SPEC.md`): Cold-start detection (absence of `~/.claude/session-search/facets/` directory) and import flow.

**Section 6** (`docs/design/SPEC.md`): Add Pre-Step before session mapping that checks for cold-start condition.

**Import logic**: Read from `~/.claude/usage-data/facets/<session-id>.json` and `~/.claude/usage-data/session-meta/<session-id>.json` to derive projectId and timestamp.

### Files Affected

- `docs/design/SPEC.md` (new Section 4.8, updated Section 6)
- `commands/session-search.md` (new Pre-Step)

---

## Migration 4: Abandon Legacy Storage Format

### Gap

After facet adoption, the old `index.jsonl` and `takeaways.jsonl` files become orphaned. References to these files throughout the spec and command template create confusion.

### Reasoning

Converting old summaries to facets costs more than regeneration. The old format contains only a one-sentence summary and a takeaway paragraph; these cannot populate structured facet fields (outcome, helpfulness, friction counts) without re-reading raw session logs. Regenerating from scratch via the hook or `/insights` import produces higher-quality facets. The old files remain on disk but the plugin no longer reads them.

### Changes

**`docs/design/SPEC.md`**: Remove all references to `index.jsonl` and `takeaways.jsonl`.

**`commands/session-search.md`**: Remove all references to `index.jsonl` and `takeaways.jsonl`.

The old files are not deleted; they are simply ignored.

### Files Affected

- `docs/design/SPEC.md` (all references)
- `commands/session-search.md` (all references)

---

## Items Reviewed and Discarded

| Item | Reason for Rejection |
|------|---------------------|
| **Convert old summaries to facets** | The old summary/takeaways format cannot populate structured facet fields (outcome, friction, helpfulness) without re-reading raw logs. Conversion costs the same as regeneration but produces lower-quality output. |
| **Store facets in a single global file** | A single `facets.jsonl` grows unbounded. Project-partitioned files enable faster reads when filtering by project and avoid contention from concurrent hook writes across different projects. |
| **Use snake_case field names to match Anthropic** | Claude Code session logs use camelCase (`sessionId`, `parentUuid`). Aligning with the host application's convention reduces cognitive friction for developers reading the data. The import step renames `session_id` to `sessionId`. |
| **Synchronous hook execution** | Blocking the session exit on a Haiku API call adds 2-4 seconds of latency to every session termination. Background execution via `nohup` with a 30-second timeout guard provides the same result without degrading the user experience. |
