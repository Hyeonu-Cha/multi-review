# code-review-mcp

Multi-CLI code review. Fan a PR diff out to several AI-CLI reviewers
(Claude, Codex, Antigravity/`agy`, Gemini, …) running side by side in **tmux panes**,
then **reconcile** their findings into one de-duplicated, severity-ranked review.

Goal: a self-hosted replacement for Copilot review that cross-checks multiple models.

## How it works

```
multi-review <PR>                         (or --diff file / current branch vs --base)
   │  get diff  →  build shared review prompt
   ├─ tmux pane: claude  → claude.json  ┐
   ├─ tmux pane: codex   → codex.json   ├─ structured findings (JSON), not screen-scraped
   ├─ tmux pane: agy     → agy.json     ┘
   └─ reconcile pass (one CLI) → review.md  →  optional `gh pr review`
```

Each reviewer writes JSON findings to a file (reliable), while the tmux panes let you
**watch the models work live**. A final reconcile pass merges duplicates, boosts
issues multiple models agree on, drops noise, and ranks by severity.

## Requirements

- `bash`, `tmux`, `jq`
- `gh` (only for reviewing/posting to GitHub PRs)
- The reviewer CLIs you enable (`claude`, `codex`, `agy`, `gemini`, …) on your `PATH`

> Designed for a Linux/WSL environment (where `tmux` and `agy` live). Use `--no-tmux`
> to run reviewers as background jobs where tmux isn't available.

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

Authored and syntax-checked. The live tmux run needs a Linux/WSL host with the CLIs
installed; flag defaults in `reviewers.json` may need tuning per CLI version.
