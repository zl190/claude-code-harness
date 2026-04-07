---
artifact: reliability-comparison
date: 2026-04-07
session: claude-code-harness validation sprint
---

# Reliability comparison: Mac Agent tool vs claude-code-remote

## Setup

Same prompt, same model, same intent. Six independent validator agents,
each tasked with producing one validation card for a Claude Code hook
(`publish-gate-bash`, `research-gate`, `framework-audit-gate`,
`handoff-gate`, `task-verify`, `cc-live-brief`).

## Run A — Local Agent tool spawn (MacBook)

| Item | Value |
|------|-------|
| Spawn host | MacBook Pro |
| Auth | OAuth (Claude Code default) |
| Agents | 6 |
| Spawn time | 2026-04-07 ~14:34 local |
| Wall time | ~3 hours |
| Lid state | Closed for transport mid-run |
| Outputs produced | **0 of 6** |
| Tool calls per agent before death | 21–39 |
| Failure mode | All 6 returned `401 OAuth token has expired. Please obtain a new token or refresh your existing token.` on the final response (the validation-card Write call) |
| Time wasted | ~12 cumulative agent-hours |

Each dead agent had completed the actual reading work — they had read the
hook source, scanned the audit logs, classified events, written test
scripts. The token expired between the last tool call and the final
response, so all that work landed nowhere.

Root cause: closing the laptop suspends background processes. The OAuth
token sits unused. Eventually it expires. When the laptop wakes, the next
API call (the agent's final Write) fails 401. There is no in-flight
recovery for an expired token in a long-running background agent.

## Run B — claude-code-remote (remote-host)

| Item | Value |
|------|-------|
| Spawn host | Remote Linux box, reached via ssh |
| Auth | `ANTHROPIC_API_KEY` env var (no OAuth) |
| Agents | 6 (same prompts, same task list) |
| Spawn time | 2026-04-07 ~16:10 UTC |
| Wall time | ~8 minutes (parallel) |
| Lid state | Mac unrelated — remote box always awake |
| Outputs produced | **6 of 6** |
| Total content | 121 KB across 6 validation cards |
| Verdicts | 1 SHIPPING_READY, 5 NEEDS_FIX |

All six validation cards are at
`~/.claude/memory/validations/{publish-gate-bash,research-gate,
framework-audit-gate,handoff-gate,task-verify,cc-live-brief}.md`.

## Honest framing

This is **not** a "speed" comparison. Per-agent wall time is roughly
similar when both runs work — 5–8 minutes of real model effort for the
kind of validation card these tasks produced. The 3-hour Mac wall is
time spent dying, not time spent working.

This is a **reliability** comparison. The right way to read 0/6 vs 6/6
is:

> "The Mac path requires you to stay at your laptop. The remote path
> doesn't."

For a user who never carries their laptop, the Mac path is fully
sufficient. `claude-code-remote` exists for the "I need to leave the
desk" case.

## What this proves about the tool

`claude-code-remote` does not make any agent smarter, faster, or
cheaper. It changes one thing: where the agent runs. That one change
turns a 0% completion rate into a 100% completion rate when the user is
mobile.

## What this does not prove

- The tool is more "production grade" than ad-hoc shell. It is not. It
  is a thin wrapper around `ssh`, `rsync`, `tmux`, and `claude -p`.
- The tool adds new capabilities. It does not. The capabilities are all
  already in the underlying primitives.
- The remote box is more reliable than a laptop in general. Only the
  auth lifetime is different.

The value is **encoding the right defaults** so a tired user at 1 AM
doesn't have to remember the rsync paths, the tmux naming convention,
and the QC criteria. The tool is a small, opinionated convention.

## Methodology

This card follows the same audit format used in
[`claude-code-harness`](https://github.com/zl190/claude-code-harness)'s
`evidence/secret-guard-validation.md` — same 6-section structure,
adapted for a reliability comparison instead of a precision audit.
