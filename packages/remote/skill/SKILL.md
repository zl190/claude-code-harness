---
name: claude-code-remote
description: Delegate Claude Code tasks to a remote machine that uses API-key auth. Use when a task might take > 30 minutes OR the user will close the laptop OR needs overnight execution OR needs to run many agents in parallel. Survives laptop sleep. Part of claude-code-harness kit.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# claude-code-remote — Delegate tasks to a remote machine

This skill teaches Claude when and how to delegate long-running or
unattended tasks to a remote machine using `claude-code-remote`, a CLI
tool installed as part of the `claude-code-harness` kit.

## Design layers (explicit per framework-panorama.md)

| Layer | Content in this skill | Where |
|-------|------------------------|-------|
| **1. Template** — shape of the output/artifact | `task.conf` shell-source format + QC field list | "What to produce" section below |
| **2. Persona** — who generates the work | The REMOTE agent is whoever the PROMPT defines it to be (validator, source-reader, etc.). THIS skill's persona is "the Claude that helps the user write + invoke task.conf" | "Common mistakes" + examples |
| **3. Procedure** — the sequence | snapshot → spawn → wait → recover → QC → retry (max 2) | "Architecture summary" + "How to invoke" |
| **4. Enforcement** — what blocks bad output | QC rubric L1 (schema) + L2 (content); retry with failure-context injection; `.INCOMPLETE` marker on exhausted retries | "After the task returns" |

**Note on the 5-part atomic unit gate:** unlike a hook rule (prompt + hook
script + test + fresh run + showcase), a *skill* rule is enforced at the
model layer via CC's auto-trigger-on-description, not at the shell layer
via exit 2. There is no hook script for "use this skill now" — that
decision lives in the model reading the `description:` frontmatter and
user keywords. The closest analog to the "test" part is
`packages/remote/tests/integration.sh`, which exercises the tool this
skill describes end-to-end against a real remote.

## When to invoke this skill

Trigger on any of these user signals:

- "delegate this to <remote>", "run on remote-host", "send this to the server"
- "run overnight", "I'll be out", "my laptop will sleep", "closing the lid"
- "too long for local", "don't want to wait at my desk"
- "validate N things in parallel", "run these batch"
- "remote task", "background agent that won't die"

Trigger proactively (no explicit user ask) when ALL of these hold:

1. You're about to spawn a background `Agent` tool task
2. The task plausibly runs > 30 minutes
3. The user has previously mentioned mobility, travel, or meeting schedules
4. A remote is known to be available (check `~/.ssh/config` or the user's
   `memory/feedback_mac-lid-close-kills-agents.md` for remote hostname)

**Do NOT invoke** for:

- Tasks < 5 minutes (local Bash tool is cheaper)
- Interactive tasks requiring user Q&A mid-run
- Tasks that write to local files the remote can't see

## Architecture summary

```
Mac terminal        ssh+rsync+tmux       Remote machine
   │                                          │
   ▼                                          │
claude-code-remote run task.conf              │
   │                                          │
   ├── snapshot (mirror local logs) ──────────┤
   ├── spawn (scp prompt + start tmux) ───────┤
   │                                          ▼
   │                              claude -p "<prompt>"
   │                              (uses ANTHROPIC_API_KEY,
   │                               no OAuth expiry)
   │                                          │
   ├── wait (poll for DONE marker) ───────────┤
   ├── recover (rsync output + QC)            │
   └── retry if QC fails (max 2 times)
```

## What to produce: a task.conf file

A task is declared in a shell-source `.conf` file. No YAML dependency.

**Minimum required fields:**

```bash
NAME=unique-task-name              # becomes tmux session id: ccr-<NAME>
REMOTE=remote-host                    # ssh alias; user's default is 'remote-host'
PROMPT="<full prompt with persona, context, success criteria>"

# At least one of the following to define what 'done' means:
OUTPUT_PATTERN="*.md"              # glob for files to recover
RECOVER_TO="$HOME/path/to/dest"    # where to place recovered files
```

**Quality-control fields (strongly recommended):**

```bash
QC_REQUIRED_SECTIONS="§1 §2 §3"    # required substrings in output
QC_REQUIRED_FRONTMATTER="verdict"  # required ^field: lines
QC_MIN_SIZE=100                    # bytes; override if output is short
```

**Reliability fields (defaults are sensible):**

```bash
RETRY_MAX=2                        # max retries on QC failure
TIMEOUT=1800                       # seconds; default 30 min
```

**Optional input files to scp to remote:**

```bash
INPUTS=(
  "$HOME/.claude/scripts/some-hook.sh"
  "/path/to/reference.md"
)
```

## Templates to copy from

Two example confs ship with the kit:

| Template | Use for |
|----------|---------|
| `$REPO/packages/remote/examples/hello-world.conf` | Smoke test / round trip verification |
| `$REPO/packages/remote/examples/validation-card.conf` | Producing a 6-section validation card for a Claude Code hook (real use case from session 38) |

Copy the template that best matches, edit the fields, invoke the CLI.

## How to invoke (three modes)

### One-shot: snapshot + spawn + wait + recover in one command

```bash
claude-code-remote run /path/to/task.conf
```

Returns when recovered + QC'd, OR when timeout hit, OR when retries
exhausted. This is the default mode — use it unless you have reason not to.

### Spawn + later recover (for batches)

```bash
# Spawn N tasks without waiting
for conf in task-1.conf task-2.conf task-3.conf; do
  claude-code-remote spawn "$conf"
done

# Check progress
claude-code-remote status

# Recover everything when they're done
claude-code-remote recover all
```

### Attach to a live task (for debugging)

```bash
claude-code-remote attach hello-world   # opens remote tmux session
```

## After the task returns

On success, look for:

1. The output file(s) in `$RECOVER_TO/`
2. The execution log at `$RECOVER_TO/<NAME>.run.log` — full stdout/stderr
   from the remote agent including every tool call
3. Any retries that happened will be noted in the run.log

On QC failure after max retries, the staging directory will contain a
`.INCOMPLETE` marker at `~/.cache/claude-code-remote/staging/<NAME>/.INCOMPLETE`.
Read the `run.log` in that directory to see what the agent produced.

## Common mistakes to avoid

- **Default `QC_MIN_SIZE=100` rejects short outputs.** Set
  `QC_MIN_SIZE=10` for simple test tasks.
- **Embedding `echo $VAR`** in the PROMPT where VAR ends in KEY/TOKEN/
  SECRET will trigger the secret-guard hook on the local Mac when you
  invoke claude-code-remote. Use `${VAR}` or rewrite.
- **Omitting QC_REQUIRED_SECTIONS** means only file existence is checked —
  any empty-but-present file will count as a pass. Always specify at
  least one required substring.
- **Forgetting INPUTS for hook sources.** The remote agent can't see
  your local `~/.claude/scripts/` unless you list files in `INPUTS`
  (or the remote has dotfiles symlinked).
- **Using a remote that sleeps.** claude-code-remote solves laptop sleep
  on the driver side, but the remote must stay awake. A Mac Mini on
  battery is NOT a good remote.

## How this skill relates to the harness kit

`claude-code-remote` is one of two packages in
[`claude-code-harness`](https://github.com/zl190/claude-code-harness):

| Package | What it does |
|---------|--------------|
| `secret-guard` | Blocks dangerous local commands (secret leaks) |
| `remote` (this one) | Moves long tasks to a remote machine |

Both are installed by the same `./install.sh`. Both have audited
validation cards in `packages/<id>/validation.md`.

## Related memory

- `~/.claude/memory/project_claude-code-remote.md` — full design memo
  (persona, template, planning, test, QC rubric layers)
- `~/.claude/memory/feedback_mac-lid-close-kills-agents.md` — the
  original pain point this tool solves
- `~/.claude/memory/project_gate-pool-registry.md` — the broader
  "registry of trusted harness components" idea this kit implements
