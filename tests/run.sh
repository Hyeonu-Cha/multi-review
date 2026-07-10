#!/usr/bin/env bash
# Smoke tests for bin/multi-review, driven by a fake reviewer CLI — no real AI CLI,
# network, or gh needed (bash + jq + git only). Run: bash tests/run.sh
#
# Covers: fan-out + findings capture, JSON salvage (fence/prose-wrapped output),
# per-finding sanitization (malformed findings dropped), related-file context,
# workspace collision, context budgets, the posting path (fake gh), and flag plumbing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }

# ---- fixtures ----------------------------------------------------------------
cat > "$TMP/fixture.patch" <<'EOF'
diff --git a/src/app.py b/src/app.py
index 0000000..1111111 100644
--- a/src/app.py
+++ b/src/app.py
@@ -1,3 +1,4 @@
 def main():
+    x = 1 / 0
     return 0
EOF

mkconfig() {  # mkconfig <fake reviewer script> [reconciler cmd] — config for the fakes
  local rec="${2:-true}"
  cat > "$TMP/config.json" <<EOF
{
  "reviewers": [ { "name": "fake", "enabled": true, "cmd": "bash $1 {OUT}" } ],
  "instruction": "review {DIFF} per {PROMPT}; write findings to {OUT}",
  "reconciler": { "name": "true", "cmd": "$rec" }
}
EOF
}

run_engine() {  # run_engine — fan-out-only run with the current config; echoes output
  (cd "$ROOT" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
    bash bin/multi-review --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 2>&1)
}

findings_path() { grep -o 'FINDINGS\[fake\]=.*' <<<"$1" | cut -d= -f2; }

# ---- test 1: fan-out captures clean JSON findings ------------------------------
cat > "$TMP/fake1.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'JSON'
{"reviewer":"fake","findings":[{"file":"src/app.py","line":2,"side":"RIGHT","severity":"high","category":"bug","title":"division by zero","detail":"1/0 always raises","suggestion":null,"confidence":0.95}]}
JSON
EOF
mkconfig "$TMP/fake1.sh"
out="$(run_engine)"
if grep -q 'FINDINGS\[fake\]=' <<<"$out"; then ok "fan-out reports findings file"; else bad "fan-out reports findings file: $out"; fi
f="$(findings_path "$out")"
if [ -n "$f" ] && jq -e '.findings | length == 1' "$f" >/dev/null 2>&1; then
  ok "clean JSON findings pass through intact"
else bad "clean JSON findings pass through intact"; fi

# ---- test 2: fence/prose-wrapped JSON is salvaged, not dropped -----------------
cat > "$TMP/fake2.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'JSON'
Here are my findings:
```json
{"reviewer":"fake","findings":[{"file":"src/app.py","line":2,"side":"RIGHT","severity":"high","category":"bug","title":"division by zero","detail":"1/0 always raises","suggestion":null,"confidence":0.95}]}
```
JSON
EOF
mkconfig "$TMP/fake2.sh"
out="$(run_engine)"
f="$(findings_path "$out")"
if [ -n "$f" ] && jq -e '.findings | length == 1' "$f" >/dev/null 2>&1; then
  ok "fence/prose-wrapped JSON salvaged"
else bad "fence/prose-wrapped JSON salvaged: $out"; fi
if [ -n "$f" ] && [ -f "$f.raw" ]; then ok "salvage keeps the raw original"; else bad "salvage keeps the raw original"; fi

# ---- test 3: malformed individual findings are dropped, valid ones kept --------
cat > "$TMP/fake3.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'JSON'
{"reviewer":"fake","findings":[
  {"file":"src/app.py","line":2,"side":"RIGHT","severity":"high","category":"bug","title":"good","detail":"d","suggestion":null,"confidence":0.9},
  {"file":"src/app.py","line":"not-a-number","severity":"high","title":"bad line type"},
  {"line":3,"severity":"low","title":"missing file"}
]}
JSON
EOF
mkconfig "$TMP/fake3.sh"
out="$(run_engine)"
f="$(findings_path "$out")"
if [ -n "$f" ] && jq -e '.findings | length == 1' "$f" >/dev/null 2>&1 \
   && jq -e '.findings[0].title == "good"' "$f" >/dev/null 2>&1; then
  ok "malformed findings dropped, valid kept"
else bad "malformed findings dropped, valid kept: $out"; fi

# ---- test 4: related unchanged files attached as context -----------------------
# A temp repo where the changed file has a same-folder sibling and an import target;
# both should land in the "Related unchanged files" prompt section, within budget.
REPO="$TMP/repo"
mkdir -p "$REPO/src" "$REPO/lib"
printf 'import util\n\ndef main():\n    return 0\n'      > "$REPO/src/app.py"
printf 'def guarded_handler():\n    check_auth()\n'      > "$REPO/src/sibling.py"
printf 'def util():\n    pass\n'                         > "$REPO/lib/util.py"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm init
mkconfig "$TMP/fake1.sh"
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2)"
if [ -n "$ws" ] && grep -q '## Related unchanged files' "$ws/prompt.md" \
   && grep -q '### src/sibling.py' "$ws/prompt.md"; then
  ok "same-folder sibling attached as related context"
else bad "same-folder sibling attached as related context: $out"; fi
if [ -n "$ws" ] && grep -q '### lib/util.py' "$ws/prompt.md"; then
  ok "imported file attached as related context"
else bad "imported file attached as related context"; fi
# changed file must appear once (changed section), never again under related
if [ -n "$ws" ] && [ "$(grep -c '### src/app.py' "$ws/prompt.md")" -eq 1 ]; then
  ok "changed file not re-attached as related"
else bad "changed file not re-attached as related"; fi
# budget 0 disables the feature entirely
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" RELATED_TOTAL_CAP=0 \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2)"
if [ -n "$ws" ] && ! grep -q '## Related unchanged files' "$ws/prompt.md"; then
  ok "RELATED_TOTAL_CAP=0 disables related context"
else bad "RELATED_TOTAL_CAP=0 disables related context"; fi

# ---- test 5: same-second runs get distinct workspaces ---------------------------
mkconfig "$TMP/fake1.sh"
o1="$(run_engine)"; o2="$(run_engine)"
w1="$(grep -o 'WORKSPACE=.*' <<<"$o1" | cut -d= -f2)"
w2="$(grep -o 'WORKSPACE=.*' <<<"$o2" | cut -d= -f2)"
if [ -n "$w1" ] && [ -n "$w2" ] && [ "$w1" != "$w2" ]; then
  ok "same-second runs get distinct workspaces"
else bad "same-second runs get distinct workspaces: '$w1' vs '$w2'"; fi

# ---- test 6: FULLFILE_TOTAL_CAP omits changed-file content beyond the budget ----
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" FULLFILE_TOTAL_CAP=1 \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2)"
if [ -n "$ws" ] && grep -q 'omitted here by the total context budget' "$ws/prompt.md" \
   && grep -q '1 omitted by total cap' <<<"$out"; then
  ok "FULLFILE_TOTAL_CAP omits over-budget changed files with a note"
else bad "FULLFILE_TOTAL_CAP omits over-budget changed files with a note: $out"; fi

# ---- tests 7-9: posting path, driven by a fake `gh` ------------------------------
# The riskiest code (writes to real PRs) gets a shim: fake gh serves the diff,
# intent, head SHA, and existing comments, and captures the reviews-API POST.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  "pr diff"*)              cat "$FAKE_GH_DIFF";;
  *"--json title,body"*)   printf 'Title: fix div by zero\n\nintent body\n';;
  *"--json headRefOid"*)   echo "$FAKE_GH_SHA";;
  *"--json url"*)          echo "";;   # no URL → snapshot falls back to working tree
  *"--json owner,name"*)   echo "own repo";;
  *"pulls/7/comments"*)    cat "$FAKE_GH_COMMENTS" 2>/dev/null || true;;
  *"pulls/7/reviews"*)     prev=""; for a in "$@"; do
                             [ "$prev" = "--input" ] && cp "$a" "$FAKE_GH_POSTED"
                             prev="$a"
                           done;;
  *) echo "fake-gh: unhandled: $args" >&2; exit 1;;
esac
EOF
chmod +x "$TMP/bin/gh"
# Reconciler emits REQUEST_CHANGES + 3 comments: two share line+severity but differ
# by title (regression check for the fp-collision fix), one is lowest-ranked.
cat > "$TMP/fakerec.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'JSON'
{"body":"combined review","event":"REQUEST_CHANGES","comments":[
  {"path":"src/app.py","line":2,"side":"RIGHT","body":"[[high]] div by zero A\ndetail A"},
  {"path":"src/app.py","line":2,"side":"RIGHT","body":"[[high]] div by zero B\ndetail B"},
  {"path":"src/app.py","line":2,"side":"RIGHT","body":"[[low]] minor C\ndetail C"}]}
JSON
EOF
export FAKE_GH_DIFF="$TMP/fixture.patch" FAKE_GH_SHA="0123456789abcdef0123456789abcdef01234567"
export FAKE_GH_COMMENTS="$TMP/gh-comments.txt" FAKE_GH_POSTED="$TMP/gh-posted.json"
mkconfig "$TMP/fake1.sh" "bash $TMP/fakerec.sh {OUT}"
post_run() {  # post_run [extra engine flags...] — PR-mode --post run under the fake gh
  (cd "$REPO" && PATH="$TMP/bin:$PATH" MULTI_REVIEW_CONFIG="$TMP/config.json" \
    bash "$ROOT/bin/multi-review" 7 --post --max-comments 2 --timeout 60 "$@" 2>&1)
}

# test 7: first post — pinned, downgraded, capped, fingerprinted
rm -f "$FAKE_GH_POSTED"; : > "$FAKE_GH_COMMENTS"
out="$(post_run)"
if [ -f "$FAKE_GH_POSTED" ] \
   && jq -e --arg sha "$FAKE_GH_SHA" '.commit_id == $sha' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '.event == "COMMENT"' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '.comments | length == 2' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '.body | contains("omitted by --max-comments")' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '[.comments[].body | contains("multi-review:fp:")] | all' "$FAKE_GH_POSTED" >/dev/null; then
  ok "post: commit_id pinned, REQUEST_CHANGES downgraded, capped at 2, fp markers added"
else bad "post: commit_id pinned, REQUEST_CHANGES downgraded, capped at 2, fp markers added: $out"; fi
if jq -r '.comments[].body' "$FAKE_GH_POSTED" 2>/dev/null \
   | grep -o 'multi-review:fp:[0-9a-f]\{12\}' | sort | uniq -d | grep -q .; then
  bad "post: same-line same-severity findings get distinct fingerprints"
else ok "post: same-line same-severity findings get distinct fingerprints"; fi

# test 8: re-run with those comments already on the PR — nothing new posted
jq -r '.comments[].body' "$FAKE_GH_POSTED" > "$FAKE_GH_COMMENTS"
rm -f "$FAKE_GH_POSTED"
out="$(post_run)"
if grep -q 'skipped 2 finding(s) already posted' <<<"$out" \
   && grep -q 'nothing new to post' <<<"$out" && [ ! -f "$FAKE_GH_POSTED" ]; then
  ok "post: re-run dedupes already-posted findings, posts nothing"
else bad "post: re-run dedupes already-posted findings, posts nothing: $out"; fi

# test 9: --block lets REQUEST_CHANGES through
: > "$FAKE_GH_COMMENTS"; rm -f "$FAKE_GH_POSTED"
out="$(post_run --block)"
if [ -f "$FAKE_GH_POSTED" ] && jq -e '.event == "REQUEST_CHANGES"' "$FAKE_GH_POSTED" >/dev/null; then
  ok "post: --block preserves REQUEST_CHANGES"
else bad "post: --block preserves REQUEST_CHANGES: $out"; fi

# ---- test 10: help/flag plumbing -------------------------------------------------
if bash "$ROOT/bin/multi-review" --help | grep -q -- '--max-comments'; then
  ok "--max-comments documented in --help"
else bad "--max-comments documented in --help"; fi
if out="$(cd "$ROOT" && bash bin/multi-review --max-comments x 2>&1)"; [ $? -ne 0 ] && grep -q 'positive integer' <<<"$out"; then
  ok "--max-comments rejects non-numeric values"
else bad "--max-comments rejects non-numeric values"; fi

# ---- test 11: non-integer cap env vars are coerced, not crashed ------------------
# A non-integer cap used to spam "integer expression expected" (one per changed file)
# and silently disable the budget. It must now coerce to the default with a warning and
# still produce findings. $REPO (from test 4) has src/app.py, matching fixture.patch.
mkconfig "$TMP/fake1.sh"
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" FULLFILE_TOTAL_CAP=abc \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 2>&1)"
if ! grep -q 'integer expression expected' <<<"$out" \
   && grep -q "ignoring non-integer FULLFILE_TOTAL_CAP='abc'" <<<"$out" \
   && grep -q 'FINDINGS\[fake\]=' <<<"$out"; then
  ok "non-integer cap env var coerced to default with a warning, no crash"
else bad "non-integer cap env var coerced to default with a warning, no crash: $out"; fi

# ---- test 12: none-backend timeout kills the reviewer's whole subtree ------------
# A hung reviewer's child used to be orphaned on timeout — the engine killed only the
# wrapper bash, leaving the CLI (and its children) running and burning credits. Job control
# (set -m) now puts each reviewer in its own process group so the timeout kills the whole
# group. Gated on non-Windows (Git Bash has no reliable portable subtree kill).
GC_PID="$TMP/orphan.pid"; rm -f "$GC_PID"
cat > "$TMP/fake_hang.sh" <<EOF
#!/usr/bin/env bash
# spawn a grandchild that would outlive an orphaned wrapper, record it, then hang. sleep is
# long enough that it can't exit on its own within the test window (which would false-pass).
( exec sleep 300 ) &
echo \$! > "$GC_PID"
wait
EOF
mkconfig "$TMP/fake_hang.sh"
out="$(cd "$ROOT" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash bin/multi-review --diff "$TMP/fixture.patch" --no-reconcile --timeout 1 2>&1)"
sleep 2  # let the kill propagate
# mirror the engine's process-group capability detection: job control on non-Windows
if [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* && "$OSTYPE" != win* ]]; then subtree_kill=1; else subtree_kill=0; fi
if [ "$subtree_kill" -eq 0 ]; then
  ok "none-backend timeout subtree kill (skipped: no process-group support)"
elif grep -q timeout <<<"$out" && [ -f "$GC_PID" ] && gc="$(cat "$GC_PID")" \
     && [ -n "$gc" ] && ! kill -0 "$gc" 2>/dev/null; then
  ok "none-backend timeout kills the reviewer's whole subtree"
else
  [ -f "$GC_PID" ] && kill "$(cat "$GC_PID")" 2>/dev/null
  bad "none-backend timeout kills the reviewer's whole subtree (orphan survived): $out"
fi

# ---- test 13: INT/TERM cleans up reviewers (Ctrl-C must not orphan them) ----------
# Reviewers run in their own process groups (set -m), so the engine's trap must group-kill
# them on interrupt — without it a Ctrl-C kills the engine but leaves the CLIs running. Same
# capability gate as test 12; reuses $subtree_kill computed above.
GC_PID2="$TMP/orphan2.pid"; rm -f "$GC_PID2"
cat > "$TMP/fake_hang2.sh" <<EOF
#!/usr/bin/env bash
( exec sleep 300 ) &
echo \$! > "$GC_PID2"
wait
EOF
mkconfig "$TMP/fake_hang2.sh"
( cd "$ROOT"; export MULTI_REVIEW_CONFIG="$TMP/config.json"
  exec bash bin/multi-review --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 ) >/dev/null 2>&1 &
engine_pid=$!
for _ in $(seq 1 20); do [ -s "$GC_PID2" ] && break; sleep 0.5; done  # wait for reviewer to come up
kill -TERM "$engine_pid" 2>/dev/null
dead=0
for _ in $(seq 1 10); do
  gc2="$(cat "$GC_PID2" 2>/dev/null)"
  { [ -n "$gc2" ] && ! kill -0 "$gc2" 2>/dev/null; } && { dead=1; break; }
  sleep 0.5
done
if [ "$subtree_kill" -eq 0 ]; then
  ok "INT/TERM reviewer cleanup (skipped: no process-group support)"
elif [ "$dead" -eq 1 ]; then
  ok "INT/TERM group-kills reviewers (no orphan on interrupt)"
else
  bad "INT/TERM group-kills reviewers (orphan survived on interrupt)"
fi
gc2="$(cat "$GC_PID2" 2>/dev/null)"; [ -n "$gc2" ] && kill "$gc2" 2>/dev/null; kill "$engine_pid" 2>/dev/null; true

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
