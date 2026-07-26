# Agent contribution policy

Effective date: 2026-07-26

This repository requires every AI agent that changes project files to identify
and commit its own work before handoff.

## Attribution

- Use the exact identity format `[agent-name@model-name]`.
- Set the repository-local Git author name to that identity before committing.
- Prefix every agent-authored commit subject with the same identity.
- Use the actual agent and model identifiers; do not claim another agent or
  model.

Example:

```text
[Codex@gpt-5.6-sol] Add modem status validation
```

## Commit ownership

- Each agent commits only the changes it intentionally made or explicitly
  verified for inclusion.
- Do not silently include unrelated user or other-agent changes.
- Run relevant checks before committing and summarize their results in the
  commit body when material.
- Never commit credentials, private keys, local build environments, or
  temporary runtime state.

## Dates

- Git author and committer timestamps are the authoritative commit dates.
- Use `YYYY-MM-DD` for dates in filenames, reports, manifests, or release notes
  when an explicit date is useful.
- Do not rewrite historical dates merely to match the current work date.
