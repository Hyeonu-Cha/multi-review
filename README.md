# multi-review

Multi-CLI code review. Fan a PR diff out to several AI-CLI reviewers
(Claude, Antigravity/`agy`, Codex, Gemini, …) running **headlessly in parallel**,
then **reconcile** their findings into one de-duplicated, severity-ranked review.

Goal: a self-hosted replacement for Copilot review that cross-checks multiple models.

> **Headless by default** — reviewers run as background jobs; no GUI needed. Optionally
> run them in **WezTerm/tmux panes** (`--backend wezterm`) if you want to watch live.

## How it works

```
multi-review <PR>                         (or --diff file / current branch vs --base)
   │  get diff  →  build criteria+schema file
   ├─ bg job: claude -p '<instruction>'   ──▶ claude.json ┐
   ├─ bg job: agy --print '<instruction>' ──▶ agy.json     ├─ JSON findings (files)
   ├─ bg job: …            '<instruction>' ──▶ ….json      ┘
   └─ headless reconcile pass → review.json  →  optional inline post via reviews API
```

Each reviewer runs a **one-shot non-interactive command**, using its own native
code-review skill and tools. The shared instruction tells each agent to **write its JSON
findings to a file** with its own file-write tool — we read that file, **not stdout**.
This matters: some CLIs (e.g. `agy`/Antigravity) render only to a TTY and emit nothing to
a pipe, but still do file/tool work fine headless — so capturing via the written file
works without any terminal. A final headless reconcile pass merges duplicates, boosts
issues multiple models agree on, drops noise, and ranks by severity.

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

These are soft guardrails. For untrusted PRs, prefer restricting each reviewer to
read + write-findings tools via its CLI's own allowlist where supported, and review the
per-reviewer logs (`out/<ts>/<name>.log`) if anything looks off. Don't point this at diffs
you wouldn't be comfortable handing to an autonomous agent.

## Requirements (Windows)

- **Git for Windows** — provides Git Bash, which supplies `bash` (≥4, for `mapfile` and
  associative arrays — Git Bash and modern Linux qualify; stock macOS bash 3.2 does not)
  and `cygpath`
- **`jq`** — `winget install jqlang.jq`
- **`gh`** — only for reviewing/posting to GitHub PRs
- The reviewer CLIs you enable (`claude`, `agy`, `codex`, `gemini`, …) on your `PATH`,
  **each logged in**
- **WezTerm** — *optional*, only if you want `--backend wezterm` to watch reviewers live

## Setup on a new Windows PC

The repo is portable — `git clone` brings everything except the host tools and your CLI
logins. Logins are per-machine **by design** (subscriptions / OAuth tokens don't and
shouldn't travel between PCs), so expect to install + sign in once per machine.

1. Install **Git for Windows** and **`jq`** (see Requirements above).
2. Install the reviewer CLIs you want (`claude`, `agy`, …) and **log into each**.
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
(e.g. `claude --version`, `agy --version`). WezTerm is needed only for the optional
`--backend wezterm` live view.

## Usage

```bash
bin/multi-review 42                 # review GitHub PR #42
bin/multi-review --diff my.patch    # review a saved diff
bin/multi-review --base origin/main # review current branch vs base (default)

bin/multi-review 42 --reviewers claude,agy   # override reviewer set
bin/multi-review 42 --post                   # post combined review to the PR
bin/multi-review 42 --timeout 1200           # wait longer for reviewers to finish
```

Output is printed and saved to `out/<timestamp>/review.json` (a GitHub reviews-API
payload). `--post` sends it to the PR as **inline comments** via
`gh api repos/{owner}/{repo}/pulls/{number}/reviews` (one comment per finding, on its
specific line), with `event` set to `REQUEST_CHANGES` when any CRITICAL/HIGH finding
exists, else `COMMENT`.

## Configuration — `config/reviewers.json`

Each reviewer has a `name`, an `enabled` toggle, and a `cmd` — the CLI's one-shot
"print" mode invoked with the instruction. `{INSTR}` is replaced with the shared
`instruction` (paths substituted, single-quoted automatically):

```json
{ "name": "claude", "enabled": true, "cmd": "claude -p {INSTR} --dangerously-skip-permissions" }
```

The shared `instruction` (top level) tells the agent what to do. Placeholders:

- `{DIFF}` — path to the diff
- `{PROMPT}` — path to the criteria + JSON-schema file (`prompts/review.md` + the diff)
- `{OUT}` — path the agent must write its JSON findings to

The `reconciler` is the **default** headless (stdin) merge pass. To let
`--reconciler <name>` pick a different CLI, add that name to the `reconcilers` map:

```json
"reconciler":  { "name": "claude", "cmd": "cat {PROMPT} | claude -p | tee {OUT}" },
"reconcilers": { "gemini": "cat {PROMPT} | gemini -p --yolo | tee {OUT}" }
```

`--reconciler gemini` then runs the `gemini` entry; an unknown name errors instead of
silently falling back to claude.

Toggle reviewers with `enabled`. **Tune each `cmd` per CLI** — the non-interactive flag
and permission-bypass flag differ (`claude -p … --dangerously-skip-permissions`,
`agy --print … --dangerously-skip-permissions`, `codex exec …`, `gemini -p … --yolo`).

### Language/framework profile

`prompts/review.md` is now **generic**. Set a top-level `"profile"` to append an addendum
from `prompts/profiles/<name>.md` to the criteria — e.g. `"profile": "dotnet"` for the
ASP.NET Core / .NET 9 migration checks. Override per run with `--profile <name>` (or
`--profile none` to force generic). Add your own profile by dropping a `<name>.md` in
`prompts/profiles/`.

## Status

Windows is the supported target. **Verified end-to-end headless on Windows (Git Bash):**
agy reviews as a background job and writes valid JSON findings; CRLF-safe config parsing;
JSON-payload output; reconcile + console render; inline `--post`. Reviewers run their CLI's
one-shot print mode and write findings to a file, so no terminal is needed — even
TTY-rendering CLIs like `agy`/Antigravity (which emit nothing to a pipe) do file/tool work
fine headless. Tune each reviewer's `cmd` per CLI as non-interactive flags differ. The
optional `--backend wezterm`/`tmux` live view spawns one pane per reviewer.
