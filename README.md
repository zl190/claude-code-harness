# claude-code-harness

Hooks that block dangerous operations in Claude Code, with audited evidence.

> **5-day audit, 27 secret-leak attempts, zero leaks. 19/19 deny precision.**
> The validator hook caught its own author twice while writing the validation report.

## Why this exists

Claude Code can run `git push`, read `.env` files, and call `printenv` on your behalf. Most of the time that's fine. The rest of the time, you only find out you exposed `ANTHROPIC_API_KEY` after it has scrolled off your terminal.

`claude-code-harness` is a small kit of pre-tool-use hooks that block specific dangerous patterns before the tool runs. v0.0 ships exactly **one** hook —— `secret-guard` —— because it is the only one with audited precision data. More hooks are validated and added as their numbers come in.

## Quick start

```bash
git clone https://github.com/zl190/claude-code-harness
cd claude-code-harness
./install.sh
```

That's three commands. The installer does:

1. Copies `hooks/secret-guard.sh` into `~/.claude/scripts/claude-code-harness/`
2. Merges a PreToolUse Bash hook entry into `~/.claude/settings.json` (idempotent — re-running is a no-op)
3. Backs up your existing `settings.json` first
4. Prints a one-line success banner with the hook path

Verify it's live by trying to do something it should block:

```bash
# In a Claude Code session:
echo $ANTHROPIC_API_KEY
# Expected: PreToolUse blocks the call with a "secret-guard BLOCKED" message
```

## What `secret-guard` blocks

Two tiers. Deny tier blocks the call with a clear message. Warn tier lets the call through but adds a reminder.

| Tier | Pattern | Example caught |
|------|---------|----------------|
| Deny | `echo` of any env var matching `*KEY|*TOKEN|*SECRET|*PASSWORD|*AUTH|*CREDENTIAL` | `echo $ANTHROPIC_API_KEY` |
| Deny | `cat`/`tail`/`head`/`bat` on `.env`, `.netrc`, `.aws/credentials`, `~/.ssh/id_*`, etc. | `cat ~/.aws/credentials` |
| Deny | `printenv` or `env` with no args (full dump) | `env \| grep API_KEY` |
| Deny | `export -p` (dumps all exports) | `export -p` |
| Deny | `diff` on `.env` files | `diff .env .env.prod` |
| Deny | `python -c` / `node -e` reading `os.environ` / `process.env` | `python -c 'import os; print(os.environ)'` |
| Deny | SSH remote command reading secrets | `ssh prod 'cat ~/.env'` |
| Warn | `grep` on key-like terms in config files | `grep API_KEY app.json` |
| Warn | Reading shell rc files | `cat ~/.bashrc` |

The full pattern list is in `hooks/secret-guard.sh` (96 lines, no dependencies, read it yourself in 5 minutes).

## Evidence

The audit data backing the headline number lives in `evidence/secret-guard-validation.md`. It contains:

- All 27 enforcement events from a 5-day window (raw `enforcement.jsonl` excerpt)
- Manual classification (true positive vs false positive) for each
- Two live catches that happened **while writing the validation card** (one true positive, one confirmed false positive in the warn tier — disclosed honestly)
- Independent review notes, including known bypass patterns
- Idempotency test script

The card is intentionally honest about the warn tier's confirmed false positive (~12% on `.jsonl` log files) and known bypass methods (nested `bash -c`, variable indirection, awk/sed/perl reading credentials). Read it before you trust the headline.

## What this kit does NOT do

- ❌ Catches every possible secret leak (it's enumeration-based, not capability-based)
- ❌ Sends anything anywhere (no telemetry, no analytics, no network)
- ❌ Modifies your existing hooks (additive merge, never overwrites)
- ❌ Replace your existing security tooling (this is a Claude-Code-specific layer)
- ❌ Provide audit trails for your team's compliance (it logs locally only)

## Roadmap

Each new hook gets validated using the same audit method as `secret-guard` before it ships. No hook reaches v0.x until its validation card hits SHIPPING_READY. The audit format is in `evidence/secret-guard-validation.md` — copy it for new hooks.

- [x] **v0.0** — `secret-guard`: DENY tier 19/19 in 5-day audit; WARN regex `.jsonl` anchor fix shipped
- [ ] **v0.1** — additional hooks; cards land in `evidence/` as each one reaches SHIPPING_READY
- [ ] **v0.2** — content-aware checks (current gate is enumeration-based regex; v0.2 explores capability detection)

## FAQ

**Will this break my workflow?** It blocks 8 specific dangerous patterns. The deny tier showed 19/19 true positives in a 5-day audit window. The warn tier (which only adds an advisory message, never blocks) had a confirmed reproducible false positive on `.jsonl` log file paths in v0.0-pre — now anchored with a regex fix in this release.

**How do I uninstall?** Run `./uninstall.sh`. It removes the hook entry from `settings.json` (preserving everything else) and deletes the installed script. Your CC config is otherwise untouched.

**Does it phone home?** No. Pure local. Read the source.

**What if the hook crashes?** PreToolUse hooks that exit non-zero with no decision JSON fall back to allow. The hook is 96 lines of pure regex matching with zero state — read every line yourself.

**Can I add my own patterns?** Yes — edit `hooks/secret-guard.sh` after install. The regex set is enumeration-based by design.

## License

MIT. See `LICENSE`.

## Credit

Built by Y.L. Validation methodology from a Claude Code pipeline confidence sprint. The hook source is adapted from a private dotfiles repo and re-published here under MIT.
