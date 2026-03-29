## Spec Migration Process

When external feedback, bug reports, or design reviews identify gaps in `design/SPEC.md`, follow this process to incorporate changes:

### 1. Audit from First Principles

Do not accept feedback at face value. For each item:

- **Reproduce the claim.** Read the spec sections referenced. Confirm the gap exists and is not already addressed elsewhere.
- **Assess ownership.** Determine whether the issue belongs to this plugin or to an external system (Claude Code, the OS, etc.). Discard items outside the plugin's scope.
- **Evaluate cost vs. benefit.** A fix that introduces non-portable dependencies, adds complexity for negligible risk, or solves a hypothetical problem does not belong in the spec. Discard these with a documented reason.
- **Check for existing mitigations.** The spec may already acknowledge and accept the risk. If the existing rationale holds, discard the item.

Produce two lists: accepted items (with reasoning) and discarded items (with rejection reasoning). Both lists appear in the migration document.

### 2. Write the Migration Document

Create `design/SPEC_MIGRATION_NN.md` where NN is the next sequential number (zero-padded). The document follows this structure:

```markdown
# Spec Migration NN: <Title>

<One-sentence summary of what this migration addresses.>

## Migration 1: <Name>

### Gap
<What the spec gets wrong or omits, with section references.>

### Reasoning
<Why this was accepted, grounded in first principles.>

### Changes
<Concrete edits: which sections, which files, what the new text says.>

### Files Affected
<Bulleted list of file paths.>

---

## Items Reviewed and Discarded

| Item | Reason for Rejection |
|------|---------------------|
| ... | ... |
```

### 3. Implement the Changes

Apply all accepted changes to the affected files:

- **`docs/design/SPEC.md`** — Update the relevant sections to reflect the new design.
- **`commands/session-search.md`** — Keep the command template in sync with the spec. The command file is what the orchestrator actually executes; the spec is the reference. They must agree.
- **`scripts/summarize-session.sh`** — Apply any hook-related changes.

Use subagents to parallelize independent file modifications when three or more files are affected.

### 4. Verify Consistency

After implementation, confirm:

- The command template (`commands/session-search.md`) matches the corresponding sections in `SPEC.md`.
- The hook script (`scripts/summarize-session.sh`) matches its spec description.
- Discarded items produced no file changes.
- The migration document accurately reflects what was changed and what was not.
