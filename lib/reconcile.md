You are the lead reviewer reconciling code-review findings from several independent
reviewers (different AI CLIs). Each reviewer produced a JSON object with a `findings`
array, concatenated below. Produce **one** clean, de-duplicated review **as a single
JSON payload ready to POST to the GitHub reviews API**.

## Rules

- **Merge duplicates**: if two+ reviewers flag the same underlying issue (same file +
  overlapping lines + same root cause), collapse into one comment. Note who raised it.
- **Boost agreement**: issues flagged by multiple reviewers are more trustworthy — keep
  them and reflect agreement in the body line.
- **Resolve conflicts**: if reviewers disagree, keep the finding, note the disagreement,
  and lower its weight.
- **Drop noise**: remove false positives, pure style nits, and low-confidence items only
  one reviewer raised that you judge incorrect.
- **Rank**: order comments by severity then confidence (most important first).
- **Preserve line targeting**: carry each finding's `file`→`path`, `line`, `side`, and
  any `start_line`/`start_side` through unchanged so the comment lands on the right line.

## Output format — STRICT

Output **only** a single JSON object, no prose before/after, no markdown fences. It must
be a valid payload for `POST /repos/{owner}/{repo}/pulls/{number}/reviews`:

```
{
  "body": "## 📋 PR Review\n\nReconciled from N independent reviewers. Inline comments and, where determinable, ready-to-use suggestions are attached to the relevant lines.",
  "event": "REQUEST_CHANGES",
  "comments": [
    {
      "path": "path/to/file.ext",
      "line": 123,
      "side": "RIGHT",
      "body": "[[SEVERITY]] What is wrong, why, and its production impact.\n\n```suggestion\nexact replacement code\n```\n\n_raised by: claude, agy · confidence: 0.9_"
    }
  ]
}
```

Payload rules:

- `event`: `"REQUEST_CHANGES"` if any comment is `[[CRITICAL]]` or `[[HIGH]]`; otherwise
  `"COMMENT"`.
- Each comment body starts with the severity tag in double brackets
  (`[[CRITICAL]]`/`[[HIGH]]`/`[[MEDIUM]]`/`[[LOW]]`), then the description, then an
  optional ` ```suggestion ``` ` block (only when a concrete line replacement exists),
  then a final `_raised by: … · confidence: …_` line.
- Include `start_line` and `start_side` **only** for multi-line findings; **omit** these
  keys entirely otherwise (do not emit `null` — the API rejects it).
- Omit the suggestion block when the fix needs a redesign; describe the fix in prose.
- If there are no real findings, output exactly:
  `{"body":"## 📋 PR Review\n\nNo blocking issues found.","event":"APPROVE","comments":[]}`

## Reviewer outputs to reconcile

