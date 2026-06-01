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
   │  get diff  →  build shared review prompt
   ├─ WezTerm pane: claude  → claude.json  ┐
   ├─ WezTerm pane: codex   → codex.json   ├─ structured findings (JSON), not screen-scraped
   ├─ WezTerm pane: agy     → agy.json     ┘
   └─ reconcile pass (one CLI) → review.md  →  optional `gh pr review`
```

Each reviewer writes JSON findings to a file (reliable), while the WezTerm panes let you
**watch the models work live**. A final reconcile pass merges duplicates, boosts
issues multiple models agree on, drops noise, and ranks by severity.

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
CLI runs (e.g. `claude --version`). If WezTerm isn't available, `--no-tmux` runs the
reviewers as background jobs (no live panes) as a fallback.

## Usage

```bash
bin/multi-review 42                 # review GitHub PR #42
bin/multi-review --diff my.patch    # review a saved diff
bin/multi-review --base origin/main # review current branch vs base (default)

bin/multi-review 42 --reviewers claude,agy   # override reviewer set
bin/multi-review 42 --post                   # post combined review to the PR
bin/multi-review 42 --no-tmux                # background jobs instead of panes
```

Output is printed and saved to `out/<timestamp>/review.md`.

## Configuration — `config/reviewers.json`

Each reviewer is a name + a command template. Placeholders:

- `{PROMPT}` — file containing the review prompt **+ the diff**
- `{OUT}` — file the reviewer must write its JSON findings to

```json
{ "name": "claude", "enabled": true, "cmd": "claude -p \"$(cat {PROMPT})\" | tee {OUT}" }
```

Toggle reviewers with `enabled`, pick the merge model with `reconciler`.
**Adjust the `cmd` flags to match each CLI's real headless/print mode** — these are
sensible defaults but each CLI evolves (e.g. `agy` non-interactive flags).

## Billing note

If you authenticate the CLIs with your **subscription** (e.g. `claude` via OAuth login),
runs draw from your plan's rate limits — no per-token charge. If `ANTHROPIC_API_KEY` is
set in the environment it **overrides** the subscription and bills per token, so unset it
for subscription-based runs.

## Status

Windows/WezTerm is the supported target at this stage. The WezTerm pane-spawn +
completion-detection mechanism is verified working on Windows (Git Bash). End-to-end
review still needs the reviewer CLIs installed and authenticated; the `cmd` flag defaults
in `reviewers.json` may need tuning per CLI version (e.g. `agy` non-interactive flags).
