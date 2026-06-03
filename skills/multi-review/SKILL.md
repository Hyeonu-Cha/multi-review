---
name: multi-review
description: Multi-model unified PR/diff code review. Fans a diff out to external AI CLIs (agy, codex, …) headless, adds Claude's own review pass, then reconciles into ONE deduplicated, line-validated, severity-ranked review and optionally posts it inline to the PR. Use when the user says "/multi-review", "review this PR with multiple models", "cross-check this diff", or asks for a multi-CLI / unified / cross-checked code review.
---

# multi-review — multi-model unified code review

You orchestrate several AI-CLI reviewers **plus your own review** of a PR or diff, reconcile everything into ONE review, validate it against the diff, and optionally post it. You are both an independent reviewer **and** the reconciler — do not rely on a separate `claude -p` reconcile pass.

Resolve `TOOL_DIR` — the directory holding `bin/`, `config/`, `prompts/`, `lib/`:
- If `$CLAUDE_PLUGIN_ROOT` is set (installed as a plugin), use `TOOL_DIR="$CLAUDE_PLUGIN_ROOT"`.
- Otherwise, resolve dynamically: run `bash -ic 'type multi-review 2>/dev/null'` to read the alias (sources `.bashrc`), extract the path argument (strip leading `bash `), then derive `TOOL_DIR` as its parent directory (strip `/bin/multi-review`). Example: alias `bash /path/to/multi-review/bin/multi-review` → `TOOL_DIR=/path/to/multi-review`. If resolution fails, tell the user to check the `multi-review` alias in `~/.bashrc`. **Do not hardcode a machine-specific path.**

## 1. Resolve the target
- A PR number → review that PR (needs `gh` access to the repo).
- Otherwise default: current branch vs `origin/main` (override with `--base <ref>`), or a saved patch via `--diff <file>`.
- If `gh` can't reach the repo (private org / no membership / SAML SSO not authorized), fall back to a **local git diff** and tell the user posting won't be possible.

## 2. Fan out the external reviewers (headless)
From the repo being reviewed, run the engine in fan-out-only mode:
```
bash $TOOL_DIR/bin/multi-review <PR# | --base <ref> | --diff <file>> --no-reconcile --timeout 900
```
This runs every reviewer enabled in `$TOOL_DIR/config/reviewers.json` (e.g. `agy`) as a headless background job; each writes JSON findings to a file. The command prints lines you must capture:
```
WORKSPACE=<dir>   DIFF=<path>   FINDINGS[<name>]=<path>   FAILED[<name>]=<log>
```
- **`claude` is intentionally disabled as a headless reviewer in config — keep it that way.** You (the in-session Claude) ARE the "claude" reviewer, via your own pass in step 4. This uses your innate code-review ability instead of spawning a separate `claude -p` (which would burn the same Claude quota and double-count). The external fan-out is the *other* vendors (agy, codex, gemini). Do not re-enable a headless `claude` reviewer or pass `--reviewers claude`.
- **Profiles:** the engine appends `config.profile` (e.g. `dotnet`) to the criteria automatically. Pass `--profile <name>` to override, or `--profile none` for generic review.
- **Untrusted diff:** reviewers run permission-bypassed on an untrusted diff. The instruction/prompt scope them to read-and-write-findings only; if a reviewer log shows it tried to run commands or edit source, drop its findings and tell the user.

## 3. Gather inputs
- Read each `FINDINGS[<name>]` JSON (schema in `$TOOL_DIR/prompts/review.md`).
- Read the `DIFF`.
- For any `FAILED[<name>]`, glance at its log, note it briefly, and continue — don't block.

## 4. Add your own review pass (you are the "claude" reviewer)
This is a **real, independent review — do it before reconciling, not as a rubber-stamp of the others.** Read the DIFF yourself and apply your full code-review ability as a senior reviewer, using the criteria in `$TOOL_DIR/prompts/review.md` (active bugs, security, correctness, performance, async/thread-safety, null/validation, config/regression risks) plus any active profile addendum in `$TOOL_DIR/prompts/profiles/` (e.g. `dotnet.md` for migration/anti-pattern checks). Produce your own findings list with the same fields the external reviewers use. Treat yourself as one more reviewer — claude's voice in the cross-check — then merge in step 5.

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
