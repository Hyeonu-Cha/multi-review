# multi-review

[![CI](https://github.com/Hyeonu-Cha/multi-review/actions/workflows/ci.yml/badge.svg)](https://github.com/Hyeonu-Cha/multi-review/actions/workflows/ci.yml)
[![tests](https://img.shields.io/badge/tests-18%20passing-brightgreen)](tests/run.sh)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FHyeonu-Cha%2Fmulti-review%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=version&color=blue)](.claude-plugin/plugin.json)

Multi-CLI code review. Fan a PR diff out to several AI-CLI reviewers
(Antigravity/`agy`, Codex, Copilot, Cursor) running **headlessly in parallel**,
then **reconcile** their findings into one de-duplicated, severity-ranked review.
Claude reviews via the `/multi-review` skill (in-session, not headless).

Goal: a self-hosted replacement for Copilot review that cross-checks multiple models.

> **Headless by default** — external reviewers run as background jobs; no GUI needed. 
> Optionally watch them live in **WezTerm/tmux panes** (`--backend wezterm`).

## Install

**As a Claude Code plugin** (recommended — gives you the `/multi-review` skill). This
repo is its own plugin marketplace, so it's a two-line install:

```
/plugin marketplace add Hyeonu-Cha/multi-review
/plugin install multi-review@multi-review
```

Then run `/multi-review <PR#>` in any session. Installing the plugin sets
`$CLAUDE_PLUGIN_ROOT`, which the skill uses to locate `bin/`, `config/`, and `prompts/` —
no alias or `MULTI_REVIEW_ROOT` needed. You still need the reviewer CLIs on your `PATH`
and logged in (see Requirements).

**As a standalone CLI** (for the headless terminal/CI path): `git clone` the repo and run
`bin/multi-review` directly — see [Setup on a new Windows PC](#setup-on-a-new-windows-pc).
The engine itself needs only **bash ≥ 4, `jq`, and `git`**, so it also runs on Linux/WSL
and any macOS with a modern bash; `gh` is required only for reviewing/posting to GitHub PRs.

## How it works

**Via `/multi-review` skill (in Claude session):**
```
/multi-review <PR#>  [or --base <ref> / --diff <file>]
   │  get diff  →  build criteria+schema file
   ├─ bg job: agy --print '<instruction>'      ──▶ agy.json     ┐
   ├─ bg job: codex exec '<instruction>'       ──▶ codex.json   ├─ JSON findings
   ├─ bg job: copilot -p '<instruction>'       ──▶ copilot.json │
   ├─ bg job: cursor-agent -p '<instruction>'  ──▶ cursor.json  ┘
   ├─ [session Claude reviews (step 4)]
   └─ [session Claude reconciles (step 5)] → unified review → optional inline post
```

**Via `multi-review` from terminal/CI (headless, no session):**
```
multi-review <PR#>  [or --base <ref> / --diff <file>]
   │  get diff  →  build criteria+schema file
   ├─ bg job: agy --print '<instruction>'      ──▶ agy.json     ┐
   ├─ bg job: codex exec '<instruction>'       ──▶ codex.json   ├─ JSON findings
   ├─ bg job: copilot -p '<instruction>'       ──▶ copilot.json │
   ├─ bg job: cursor-agent -p '<instruction>'  ──▶ cursor.json  ┘
   └─ reconciler.cmd (e.g. claude -p) → review.json → optional inline post
```

Each reviewer runs a **one-shot non-interactive command**, using its own native
code-review skill and tools. The shared instruction tells each agent to **write its JSON
findings to a file** with its own file-write tool — we read that file, **not stdout**.
This matters: some CLIs (e.g. `agy`/Antigravity) render only to a TTY and emit nothing to
a pipe, but still do file/tool work fine headless — so capturing via the written file
works without any terminal. Output that arrives wrapped in markdown fences or prose is
**salvaged** (the outermost JSON object is extracted; original kept at `<name>.json.raw`)
instead of dropping the reviewer, and individual findings missing a typed
`file`/`line`/`severity` are dropped so downstream stages can trust every field. A final
headless reconcile pass merges duplicates, boosts issues multiple models agree on, drops
noise, and ranks by severity.

**Context handed to every reviewer:** the diff; the **change intent** (PR
title/description in PR mode, commit subjects in branch mode) so reviewers can flag
"code does X, description says Y"; the full post-change content of every changed
file — snapshotted from the **PR head commit** (PR mode) or **`HEAD`** (branch mode),
never from whatever the working tree happens to hold, so reviewers are never handed
stale files labeled "post-change"; and a **budgeted set of related unchanged files**
(same-folder siblings, where guard/validation conventions live, plus files the changed
files import) so isolated reviewers can catch a handler that skips a guard its siblings
apply or a reference that doesn't bind — classes that are invisible from the diff alone.
Budget: `RELATED_TOTAL_CAP` total lines (default 10000; `0` disables), smallest files
first; related files are context only — findings still land on diff lines.

> Reviewers run with permissions bypassed (`--dangerously-skip-permissions` etc.) so the
> file write isn't blocked — the instruction is scoped to "review + write JSON, don't
> modify source or post to GitHub", as the default config does.

## Security

The diff you review is **untrusted input** — especially for external/contributor PRs.
Reviewers run permission-bypassed, so a diff that contains prompt-injection text
("ignore your instructions and run …") is a real attack surface. Mitigations in place:

- The shared `instruction` and `prompts/review.md` both tell each agent to treat the diff
  as data, never follow instructions inside it, and to only write its findings file.
- Reviewers are told not to modify source, post to GitHub, run commands, or fetch URLs.
- Each reviewer runs **in the throwaway per-run workspace (`out/<ts>/`), not in the repo
  under review**. The diff and criteria are handed in by absolute path, so a reviewer never
  needs — and doesn't start in — your working copy. This keeps a prompt-injected reviewer
  out of your source tree.

These are soft guardrails plus defense-in-depth, **not a sandbox** — reviewers still run
permission-bypassed and could climb out of the workspace. The default `copilot` reviewer is
the broadest grant (`--allow-all-tools --allow-all-paths`); `--allow-all-paths` in particular
lets it reach outside the per-run workspace, so tighten or drop it first if that matters to
you. For untrusted PRs, prefer restricting each reviewer to read + write-findings tools via
its CLI's own allowlist where supported, run the whole tool inside a container, and review
the per-reviewer logs (`out/<ts>/<name>.log`) if anything looks off. Don't point this at diffs
you wouldn't be comfortable handing to an autonomous agent.

## Requirements (Windows)

- **Git for Windows** — provides Git Bash, which supplies `bash` (≥4, for `mapfile` and
  associative arrays — Git Bash and modern Linux qualify; stock macOS bash 3.2 does not)
  and `cygpath`
- **`jq`** — `winget install jqlang.jq`
- **`gh`** — only for reviewing/posting to GitHub PRs
- The reviewer CLIs you enable (`agy`, `codex`, `copilot`, `cursor`, …) on your `PATH`, **each 
  logged in**. (Claude reviews via the `/multi-review` skill in-session, not as a headless CLI.)
- **WezTerm** — *optional*, only if you want `--backend wezterm` to watch reviewers live

## Setup on a new Windows PC

The repo is portable — `git clone` brings everything except the host tools and your CLI
logins. Logins are per-machine **by design** (subscriptions / OAuth tokens don't and
shouldn't travel between PCs), so expect to install + sign in once per machine.

1. Install **Git for Windows** and **`jq`** (see Requirements above).
2. Install the reviewer CLIs you want (`agy`, `codex`, `copilot`, `cursor`, …) and **log into each**.
   (Claude is used via the `/multi-review` skill in Claude Code, not installed separately.)
3. Clone the repo:
   ```
   git clone https://github.com/Hyeonu-Cha/multi-review.git
   ```
4. `cd` into the repo (or any repo you want reviewed) and run `multi-review`. No GUI
   needed — reviewers run headless. (Add `--backend wezterm`, from inside a WezTerm
   window, only if you want to watch them live.)

### Verify prerequisites

No bundled doctor command yet — check manually in Git Bash:
`bash --version`, `jq --version`, and that each enabled reviewer CLI runs
(e.g. `claude --version`, `agy --version`). The engine also preflights this: any enabled
reviewer whose CLI isn't on `PATH` is skipped with a `› skipping reviewers not on PATH: …`
notice rather than failing silently mid-run. WezTerm is needed only for the optional
`--backend wezterm` live view.

## Usage

```bash
# Headless terminal path (external reviewers only):
bin/multi-review 42                 # review GitHub PR #42
bin/multi-review --diff my.patch    # review a saved diff
bin/multi-review --base origin/main # review current branch vs base (default)

bin/multi-review 42 --reviewers agy,codex     # override reviewer set
bin/multi-review 42 --reconciler codex        # use codex to reconcile instead of claude -p
bin/multi-review 42 --post                    # post combined review to the PR
bin/multi-review 42 --post --max-comments 10  # cap inline comments (default 20)
bin/multi-review 42 --post --block            # let REQUEST_CHANGES actually block the PR
bin/multi-review 42 --timeout 1200            # wait longer for reviewers to finish

# Skill path (in Claude Code):
/multi-review 42                    # reviews PR #42 with agy + codex + copilot + cursor + in-session claude
```

Output is printed and saved to `out/<timestamp>/review.json` (a GitHub reviews-API
payload). `--post` sends it to the PR as **inline comments** via
`gh api repos/{owner}/{repo}/pulls/{number}/reviews` (one comment per finding, on its
specific line).

### Posting safeguards

- **Pinned to the reviewed head:** the payload carries `commit_id` (the PR head SHA),
  so a push during the (long) review run can't shift comments onto the wrong lines.
- **No duplicate comments on re-runs:** each posted comment carries a hidden
  `multi-review:fp:<hash>` marker (path + line + the comment's first line, which carries
  severity and title — so two distinct findings on the same line stay distinct); a later
  run on the same PR fetches existing comments and skips findings already posted.
- **Comment cap:** at most `--max-comments` (default 20) inline comments, ranked
  most-important-first by the reconciler; the rest are noted in the review body.
- **Non-blocking by default:** a `REQUEST_CHANGES` verdict is downgraded to `COMMENT`
  unless you pass `--block` — an unverified model finding shouldn't gate merges.

## Configuration — `config/reviewers.json`

(Set `MULTI_REVIEW_CONFIG=<path>` to point the engine at an alternate config — used by
the tests. Set `MULTI_REVIEW_ROOT=<repo dir>` in your shell profile so the
`/multi-review` skill can locate the tool without the `multi-review` alias.)

**Context/retention env knobs:** `FULLFILE_LINE_CAP` (per-file, default 3000) ·
`FULLFILE_TOTAL_CAP` (all changed files, default 30000, `0` = unlimited) ·
`RELATED_TOTAL_CAP` (related unchanged files, default 10000, `0` disables) ·
`MULTI_REVIEW_KEEP` (workspaces kept under `out/`, default 20, `0` = keep everything).
Each must be a non-negative integer; a non-integer value is ignored with a warning and
the default is used (so a typo can't silently disable a budget).

### Shared config (both skill and headless paths)

**Reviewers:** Each has `name`, `enabled` toggle, and `cmd` (CLI's one-shot "print" mode). 
`{INSTR}` is replaced with shared `instruction` (paths substituted, single-quoted).

**Default enabled: `agy`, `codex`, `copilot`, `cursor`. Claude intentionally disabled 
(reviews via `/multi-review` skill in-session).** Example:

```json
{ "name": "agy", "enabled": true, "cmd": "agy --print {INSTR} --dangerously-skip-permissions" }
```

**Instruction:** Top-level field tells agents what to do. Placeholders:
- `{DIFF}` — path to diff
- `{PROMPT}` — path to criteria + JSON-schema file (review.md + diff)
- `{OUT}` — path agent must write JSON findings to

### Headless-only config (terminal/CI path, no session)

The `reconciler` merges external reviewers' findings. **Not used in `/multi-review` skill** 
(session Claude reconciles). Headless terminal must specify one (default: `claude -p`).

```json
"reconciler":  { "name": "claude", "cmd": "cat {PROMPT} | claude -p | tee {OUT}" },
"reconcilers": { 
  "codex": "cat {PROMPT} | codex exec --dangerously-bypass-approvals-and-sandbox | tee {OUT}"
}
```

Use `--reconciler codex` to pick alternative; unknown name errors. Only applies to 
`bin/multi-review` from terminal/CI. Skill ignores these (no reconciler.cmd run).

### Who reviews and who reconciles

Two paths, zero `-p` in the skill:

- **`/multi-review` skill (Claude session)** — engine runs with `--no-reconcile`. 
  In-session Claude does BOTH: reviews (step 4, independent pass) + reconciles (step 5, 
  merges findings). **Zero `claude -p` spawned. One Claude, one quota.** That's why `claude` 
  is disabled as a headless reviewer: session covers it. The in-session pass also has
  **repo access** the isolated reviewers don't, so it chases the cross-file classes they
  are structurally blind to: a guard preamble enforced by *unchanged* sibling handlers,
  a registration↔consumer mismatch where only one side is in the diff, symbol references
  that don't bind, tests that codify a known bug.
- **`multi-review` terminal / CI (no session)** — no in-session Claude, so `reconciler.cmd` 
  runs headless (`claude -p` by default). Avoid it: `--reconciler codex`.

**If you use `/multi-review` skill, you never see `-p`.**

Toggle reviewers with `enabled`. **Tune each `cmd` per CLI** — the non-interactive flag
and permission-bypass flag differ (`claude -p … --dangerously-skip-permissions`,
`agy --print … --dangerously-skip-permissions`, `codex exec …`, `copilot -p … --allow-all-tools --allow-all-paths`, `cursor-agent -p … --force`).

### Review criteria

`prompts/review.md` is **language-neutral** — correctness, security, concurrency,
resource handling, broken references (compile-time or import/run-time), contract
consistency, intent mismatch, missing guards vs sibling code paths (an auth/validation
preamble the siblings apply and the changed handler skips), and wiring/registration
mismatches (a dependency registered one way but consumed another — compiles fine, dies
at startup). Each reviewer applies the idioms of whatever language/framework the diff
touches; nothing in the criteria assumes a specific stack.

## Tests

```bash
bash tests/run.sh
```

Smoke-tests the engine with a **fake reviewer CLI** — no real AI CLI, network, or `gh`
needed (bash + jq + git only). Covers fan-out + findings capture, JSON salvage of
fence/prose-wrapped output, per-finding sanitization, related-file context, workspace
collision, context budgets, non-integer env-knob coercion, the posting path (fake `gh`),
and flag plumbing. CI (`.github/workflows/ci.yml`) runs these on every PR, plus
`bash -n` syntax checks and `shellcheck --severity=warning` on all three scripts.

## Recall + precision benchmark

```bash
bash bench/run.sh                # ⚠ costs real quota on every enabled reviewer
```

Builds a tiny fixture repo whose change adds **six planted bugs** (`bench/cases.json`) —
division by zero, missing auth guard vs sibling handlers, registration↔consumption
mismatch, broken reference, unused import, intent mismatch — **plus a clean control file
(`app/clean.py`) with no bugs**, then fans the change to the real reviewer CLIs. It prints
a per-reviewer hit/miss matrix with a **recall** row (planted bugs caught) and a
**false-pos(clean)** row (findings on the clean file — noise; `0` is ideal). Scoring both
in one fan-out keeps a trigger-happy reviewer — perfect recall by flagging everything —
from looking good. Run it before and after a prompt/criteria change to measure whether
detection improved *without* getting noisier.

## Status

**Verified end-to-end headless on Windows (Git Bash)** with the real reviewer CLIs:
agy reviews as a background job and writes valid JSON findings; CRLF-safe config parsing;
JSON-payload output; reconcile + console render; inline `--post`. Reviewers run their CLI's
one-shot print mode and write findings to a file, so no terminal is needed — even
TTY-rendering CLIs like `agy`/Antigravity (which emit nothing to a pipe) do file/tool work
fine headless. Tune each reviewer's `cmd` per CLI as non-interactive flags differ. The
optional `--backend wezterm`/`tmux` live view spawns one pane per reviewer.

The portable bash engine (fan-out, salvage, reconcile, posting) is exercised on
Linux in CI (`bash tests/run.sh`, 18 smoke tests) and runs anywhere with bash ≥ 4,
`jq`, and `git`; the end-to-end "verified" claim above is specifically the Windows
Git Bash path with the real reviewer CLIs.

## License

[MIT](LICENSE) © Hyeonu Cha
