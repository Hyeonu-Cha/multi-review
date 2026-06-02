# code-review-mcp

Multi-CLI code review. Fan a PR diff out to several AI-CLI reviewers
(Claude, Codex, Antigravity/`agy`, Gemini, …) running side by side in **WezTerm panes**,
then **reconcile** their findings into one de-duplicated, severity-ranked review.

Goal: a self-hosted replacement for Copilot review that cross-checks multiple models.

> **Platform: Windows (WezTerm).** This is the only supported setup at this stage.
> The code has a `tmux` backend for Linux/WSL too, but it's untested and undocumented
> for now.

## How it works

```
multi-review <PR>                         (or --diff file / current branch vs --base)
   │  get diff  →  build criteria+schema file
   ├─ WezTerm pane: claude (interactive) ──send instruction──▶ claude.json ┐
   ├─ WezTerm pane: agy    (interactive) ──send instruction──▶ agy.json    ├─ JSON findings
   ├─ WezTerm pane: …      (interactive) ──send instruction──▶ ….json      ┘
   └─ headless reconcile pass → review.json  →  optional inline post via reviews API
```

Each reviewer runs as a **real interactive CLI in its own WezTerm pane**, using its own
native code-review skill and tools — so you watch the models work live. The orchestrator
sends each pane an instruction (via `wezterm send-text`) telling it to review the diff and
**write its JSON findings to a file** with its own file-write tool (reliable, no
screen-scraping). A final headless reconcile pass merges duplicates, boosts issues
multiple models agree on, drops noise, and ranks by severity.

> Reviewers run with permission prompts disabled (`--dangerously-skip-permissions` etc.)
> so the file write isn't blocked — scope the instruction to "review + write JSON, do not
> modify source or post to GitHub", as the default config does.

## Requirements (Windows)

- **Git for Windows** — provides Git Bash, which supplies `bash` and `cygpath`
- **WezTerm** — the pane multiplexer (https://wezterm.org)
- **`jq`** — `winget install jqlang.jq`
- **`gh`** — only for reviewing/posting to GitHub PRs
- The reviewer CLIs you enable (`claude`, `codex`, `agy`, `gemini`, …) on your `PATH`,
  **each logged in**

## Setup on a new Windows PC

The repo is portable — `git clone` brings everything except the host tools and your CLI
logins. Logins are per-machine **by design** (subscriptions / OAuth tokens don't and
shouldn't travel between PCs), so expect to install + sign in once per machine.

1. Install **Git for Windows**, **WezTerm**, and **`jq`** (see Requirements above).
2. Install the reviewer CLIs you want (`claude`, `codex`, …) and **log into each**.
3. Clone the repo:
   ```
   git clone https://github.com/Hyeonu-Cha/code-review-mcp.git
   ```
4. **Open a WezTerm window**, `cd` into the repo, and run `multi-review` from there.
   The pane backend splits *that* window into one pane per reviewer, so it must be
   launched from inside WezTerm — that's how it knows which window to split.

### Verify prerequisites

No bundled doctor command yet — check manually in Git Bash:
`bash --version`, `jq --version`, `wezterm --version`, and that each enabled reviewer
CLI runs (e.g. `claude --version`). Reviewers run interactively in panes, so a running
WezTerm window (or tmux on Linux/WSL) is required — there is no headless fallback.

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

Each reviewer has a `name`, an `enabled` toggle, a `launch` command (the CLI started
**interactively** with permission prompts disabled), and a `ready_wait` (seconds to let
it boot before the instruction is sent):

```json
{ "name": "claude", "enabled": true, "launch": "claude --dangerously-skip-permissions", "ready_wait": 8 }
```

A shared `instruction` (top level) is sent to every pane. Placeholders:

- `{DIFF}` — path to the diff
- `{PROMPT}` — path to the criteria + JSON-schema file (`prompts/review.md` + the diff)
- `{OUT}` — path the agent must write its JSON findings to

The `reconciler` runs **headless** (stdin) to merge the findings:

```json
"reconciler": { "name": "claude", "cmd": "cat {PROMPT} | claude -p | tee {OUT}" }
```

Toggle reviewers with `enabled`. **Tune `launch` / `ready_wait` per CLI** — each CLI's
interactive flags and boot time differ, and `ready_wait` must be long enough that the
prompt is ready before the instruction is sent.

## Status

Windows/WezTerm is the supported target. The CRLF-safe config parsing, headless reconcile
(claude), JSON-payload output, and inline `--post` are verified working on Windows (Git
Bash). The **interactive pane-driving** path (spawn → `send-text` → agent writes JSON) is
new and must be exercised from inside a real WezTerm window; expect to tune each reviewer's
`launch` flags, `ready_wait`, and the `instruction` per CLI. `agy`'s headless `-p` mode was
unreliable, which is why reviewers now run interactively.
