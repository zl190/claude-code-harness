# claude-code-harness

A small, opinionated kit of hooks and tools for Claude Code, with audited evidence for every piece.

> **5-day audit on `secret-guard`: 27 secret-leak attempts, zero leaks. 19/19 deny precision.**
> **Reliability comparison on `remote`: 0/6 → 6/6 on background tasks across a laptop-sleep event.**
> The validator hooks caught their own author five times while the kit was being built. Full logs in `packages/*/validation.md`.

## What's in v0.1

Two packages. Each has its own directory under `packages/`, its own validation card, and its own install targets.

| Package | Primary interface | What it does |
|---------|-------------------|--------------|
| `secret-guard` | A `PreToolUse` hook (always on) | Blocks `Bash` commands that would expose secrets (API keys, credentials, env dumps). 8 deny patterns, 2 warn patterns. |
| `remote` | A **skill** Claude auto-invokes in a CC session | Delegates long or unattended work to a remote machine with `ANTHROPIC_API_KEY` auth. Survives laptop sleep. Under the hood: a bash CLI + skill + the ssh+rsync+tmux plumbing. |

Neither package ships what it has not measured. `secret-guard` ships with a 5-day precision audit. `remote` ships with a reliability comparison against a real session. Both validation cards are in the repo.

The `remote` package is **designed to be used from inside a Claude Code session**, not from a terminal. You tell Claude "delegate this to my server" and the skill handles task spec, execution, quality check, and retry. The CLI underneath is an implementation detail; you can invoke it manually if you need to, but the primary UX is skill-mediated.

## Quick start

```bash
git clone https://github.com/zl190/claude-code-harness
cd claude-code-harness
./install.sh                  # installs all default packages
```

That's it for the common case. The installer reads `registry.sh`, selects packages with `default_install: true`, and runs each one's install targets (copy files, merge `settings.json`, symlink the CLI, drop the skill).

## Install modes

```bash
./install.sh                           # install all default packages
./install.sh --interactive             # prompt yes/no per package
./install.sh --packages=secret-guard   # explicit list (comma-separated)
./install.sh --list                    # show available packages, exit
./install.sh --uninstall               # remove everything this kit installed
./install.sh --uninstall --packages=remote  # remove a specific package
```

You can also edit `registry.sh` before running `./install.sh` — flip `default_install="false"` for any package you want excluded from the default install.

## Evidence (scope, so you know what's here and what isn't)

Every package has a validation card at `packages/<id>/validation.md`. Each card has six sections: trigger verification, result audit (with a precision number or an honest "undefined"), idempotency test, independent review, end-to-end case with a real log excerpt, and a verdict + gaps list.

**What the kit ships:** audited evidence for its own two packages. The `secret-guard` card is about secret-guard's regex + enforcement log. The `remote` card is about the laptop-sleep reliability gap. Both cards are self-contained — they do not depend on you having any other hooks installed.

**What the kit does NOT ship:** evidence for hooks that belong to you, not this kit. If you want to validate your own custom hooks using the same methodology, use the `validation-card.conf` template in `packages/remote/examples/` — it encodes the six-section anti-sycophantic validator persona and produces the same card format. The results land in your own directory, not this repo.

| Package | Verdict | Confidence | Summary |
|---------|---------|------------|---------|
| `secret-guard` | SHIPPING_READY (deny tier) / NEEDS_FIX (warn tier — fix shipped in v0.1) | 4/5 | 19/19 deny precision on 27 events over 5 days. Warn tier had a reproducible false positive on `.jsonl` file names; regex anchor fix in this release. Documented bypass patterns in `packages/secret-guard/validation.md`. |
| `remote` | SHIPPING_READY | 4/5 | 0/6 → 6/6 reliability comparison (see `packages/remote/validation.md`). End-to-end smoke test reproduces the round trip in ~20 seconds. |

## How `remote` works (from inside a CC session)

The typical flow:

```
You (in a CC session):   "Delegate this blog QC to my server. I'm leaving."

Claude (skill triggers): [reads ~/.claude/skills/claude-code-remote/SKILL.md]
                         [writes a task.conf matching your intent]
                         [invokes claude-code-remote run <task.conf> via Bash]

Claude (behind the scenes, via the CLI):
    snapshot  — rsync local state files to remote
    spawn     — scp prompt + inputs + start tmux running `claude -p`
                (remote uses ANTHROPIC_API_KEY — no OAuth expiry)
    wait      — poll run.log for DONE marker
    recover   — rsync outputs back, run QC, retry (max 2) on failure
    report    — verdict + paths

Claude (back to you):    "Done. Here's the recovered output and the run log."
```

You never see or write the task.conf by hand unless you want to. The skill generates it from your intent; the CLI executes it; Claude reports back.

### Under the hood (for the curious)

A task is a small shell-source `.conf` file (no YAML). The skill generates these automatically, but you can also write one by hand:

```bash
# packages/remote/examples/hello-world.conf
NAME=hello-world
REMOTE=remote-host                    # your ssh alias
PROMPT="Write 'hello world' to ~/cc-remote-output/hello-world/output.txt"
OUTPUT_PATTERN="output.txt"
RECOVER_TO="$HOME/.cache/claude-code-remote/recovered/hello-world"
QC_REQUIRED_SECTIONS="hello world"
QC_MIN_SIZE=10
RETRY_MAX=2
TIMEOUT=300
```

Then:

```bash
claude-code-remote run examples/hello-world.conf
```

A real-world template that produces a 6-section validation card with an anti-sycophantic validator persona is at `packages/remote/examples/validation-card.conf`. The skill uses this template when Claude is asked to "validate a hook".

## Running the same hooks on both machines

`remote` does **not** reinvent enforcement on the remote side. It invokes `claude -p` on the remote, which reads that machine's own `~/.claude/settings.json`. If you also install this kit on the remote (`git clone && ./install.sh` there too), the same hooks fire in both environments — your local laptop and the remote server run the same gates. If you only install it on one side, only that side has the gates. No automatic cross-machine sync is attempted.

## Roadmap

- [x] **v0.1** — `secret-guard` (hook) + `remote` (tool + skill), registry-driven installer, interactive / explicit-list install modes, full audit cards per package
- [ ] **v0.2** — third package (candidate: `handoff-gate`, which reached SHIPPING_READY in an adjacent audit); optional PreToolUse advisory hook for `remote` to nudge Claude toward delegation on risky agent spawns
- [ ] **v0.3** — content-aware secret detection (current is enumeration-based regex); cross-machine install sync helper

## FAQ

**Does this tool send anything over the network?** No. Pure local. The `remote` package uses your existing ssh + rsync; there is no telemetry, no analytics, no cloud.

**What if I only want one package?** Use `--packages=secret-guard` or `--packages=remote`, or run `--interactive` and say no to the ones you don't want.

**How do I uninstall cleanly?** `./install.sh --uninstall` removes every file and settings entry this kit installed. Your other hooks and scripts are untouched. Your logs are preserved at `~/.claude/logs/`.

**What if the `secret-guard` hook crashes?** `PreToolUse` hooks that exit non-zero without a `permissionDecision` JSON fall back to allow. The hook is 96 lines of regex matching with no state — you can read every line yourself.

**Does `remote` work if my laptop sleeps mid-task?** Yes. That is what it exists for. The remote tmux session keeps going under its own auth. On your next session, run `claude-code-remote status` to see what finished and `claude-code-remote recover all` to pull the results back.

**Where is the package I could add next?** Fork the repo, copy `packages/secret-guard/` as a template, write a validation card with real audit data (the six sections matter), add an entry to `registry.sh`, and send a PR. The kit's own `--list` command will show it after `./install.sh`.

## License

MIT. See `LICENSE`.

## Credit

Built by Y.L. as a working wedge against the practitioner gap that Galster et al. documented in February 2026: most AI coding tool setups have no executable enforcement. This kit is one practitioner's attempt to close it for themselves first — every package had to catch its own author before it was allowed to ship.
