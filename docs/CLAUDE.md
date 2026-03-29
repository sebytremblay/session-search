# docs/

## What is here

- `design/CLAUDE.md` - Details how to perform spec migrations.
- `design/SPEC.md` - Authoritative specification for the Session Search plugin. Covers the SessionEnd hook, the `/session-search` slash command, session log schema, error handling, and walked examples.
- `design/SPEC_MIGRATION_*.md` - Numbered migration documents that record changes to the spec after initial publication. Each migration addresses a set of gaps, documents the reasoning, and lists the concrete file changes.
- `guides/WRITING_STYLE.md` - Prose style rules for all user-facing text (no contractions, active voice, no em dashes, present habitual tense). Apply these when writing output templates, PR descriptions, or documentation.
- `guides/example-plugin/` - Reference implementation of a Claude Code plugin. Shows the directory layout, `plugin.json`, commands, skills, and MCP server configuration.

## Constraints

- All user-facing prose must follow `guides/WRITING_STYLE.md`.
- The spec is authoritative for v0 scope decisions. Do not implement features the spec marks as out of scope without updating the spec first.