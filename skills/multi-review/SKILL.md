---
name: multi-review
description: Multi-model unified PR/diff code review. Fans a diff out to external AI CLIs (agy, codex, …) headless, adds Claude's own review pass, then reconciles into ONE deduplicated, line-validated, severity-ranked review and optionally posts it inline to the PR. Use when the user says "/multi-review", "review this PR with multiple models", "cross-check this diff", or asks for a multi-CLI / unified / cross-checked code review.
---

# multi-review — multi-model unified code review

You orchestrate several AI-CLI reviewers **plus your own review** of a PR or diff, reconcile everything into ONE review, validate it against the diff, and optionally post it. You are both an independent reviewer **and** the reconciler — do not rely on a separate `claude -p` reconcile pass.

`TOOL_DIR=/c/Users/ericc/EricVault/Personal/code-review-mcp` (the engine + `config/reviewers.json` live here).

## 1. Resolve the target
- A PR number → review that PR (needs `gh` access to the repo).
- Otherwise default: current branch vs `origin/main` (override with `--base <ref>`), or a saved patch via `--diff <file>`.
- If `gh` can't reach the repo (private org / no membership / SAML SSO not authorized), fall back to a **local git diff** and tell the user posting won't be possible.

## 2. Fan out the external reviewers (headless)
From the repo being reviewed, run the engine in fan-out-only mode:
```
bash $TOOL_DIR/bin/multi-review <PR# | --base <ref> | --diff <file>> --no-reconcile --timeout 600
```
This runs every reviewer enabled in `$TOOL_DIR/config/reviewers.json` (e.g. `agy`) as a headless background job; each writes JSON findings to a file. The command prints lines you must capture:
```
WORKSPACE=<dir>   DIFF=<path>   FINDINGS[<name>]=<path>   FAILED[<name>]=<log>
```

## 3. Gather inputs
- Read each `FINDINGS[<name>]` JSON (schema in `$TOOL_DIR/prompts/review.md`).
- Read the `DIFF`.
- For any `FAILED[<name>]`, glance at its log, note it briefly, and continue — don't block.

## 4. Add your own review pass
Independently review the DIFF yourself as a senior reviewer, using the criteria in `$TOOL_DIR/prompts/review.md` (active bugs, security, correctness, performance, async/thread-safety, null/validation, config, and — for .NET — migration/anti-pattern/regression risks). Treat yourself as one more reviewer.

## 5. Reconcile + validate (this is the point of the skill)
- **Merge duplicates** across the external reviewers and your own; record who raised each (`raised by: …`). Agreement raises confidence.
- **Validate against the diff:** for every finding, confirm its `file` + `line` + `side` actually appear in the DIFF. Drop or correct any finding whose line isn't in the diff (kills hallucinated lines and avoids 422s on posting).
- **Drop noise:** remove false positives, pure style nits, and low-confidence single-source items you judge wrong.
- **Rank** by severity then confidence.

## 6. Deliver
- **Default:** present the unified review — a one-line verdict (`REQUEST_CHANGES` if any `[[CRITICAL]]`/`[[HIGH]]`, else `COMMENT`), then each finding as `[[SEVERITY]] file:line — what's wrong, why, production impact, fix, _raised by …_`.
- **Post only if** the user asks AND it's an **open** PR you can access. Confirm before posting to a real PR, then:
  ```
  gh api repos/{owner}/{repo}/pulls/{N}/reviews
  ```
  with `body` (header), `event`, and `comments[]` — one inline comment per finding. `side`: `RIGHT` + new-file line for added/unchanged lines, `LEFT` + old-file line for removed lines; add `start_line`/`start_side` only for multi-line ranges; omit null keys. Verify each line is on the chosen side or the call 422s.
- If posting isn't possible (no access, or PR already merged → inline reviews not allowed), say so and offer to save the review to a markdown file.

## Notes
- **Scalable:** add reviewers by setting `enabled: true` in `config/reviewers.json` (codex, gemini, …); this skill picks them up automatically.
- `agy`/Antigravity renders only to a TTY but does file/tool work fine headless — that's why the engine captures via the file each agent writes, not stdout.
- The plain `bin/multi-review` (without `--no-reconcile`) is the headless/CI path; this skill is the interactive path where you add a model and do the reconcile with judgment.
