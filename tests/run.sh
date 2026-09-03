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
                             if [ "$prev" = "--input" ]; then
                               # Mimic the reviews API: with FAKE_GH_REJECT_INLINE=1 a payload
                               # carrying ANY inline comment is refused wholesale (that is what
                               # GitHub does for one out-of-range line); a body-only payload
                               # still succeeds, which is exactly what the retry sends.
                               if [ "${FAKE_GH_REJECT_INLINE:-0}" = 1 ] \
                                  && [ "$(jq '.comments|length' "$a")" -gt 0 ]; then
                                 echo '{"message":"Validation Failed","errors":[{"field":"line","code":"invalid"}]}' >&2
                                 exit 1
                               fi
                               cp "$a" "$FAKE_GH_POSTED"
                             fi
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
# Mirror the engine's subtree-kill capability: job control on non-Windows, taskkill on
# Windows. Both tests 12 and 13 now exercise a real kill on Git Bash too.
if [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* && "$OSTYPE" != win* ]]; then subtree_kill=1
elif command -v taskkill >/dev/null 2>&1; then subtree_kill=1
else subtree_kill=0; fi
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
( cd "$ROOT" || exit; export MULTI_REVIEW_CONFIG="$TMP/config.json"
  exec bash bin/multi-review --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 ) >/dev/null 2>&1 &
engine_pid=$!
gc2=""
for _ in $(seq 1 60); do gc2="$(cat "$GC_PID2" 2>/dev/null)"; [ -n "$gc2" ] && break; sleep 0.5; done  # reviewer up (<=30s)
if [ "$subtree_kill" -eq 0 ]; then
  ok "INT/TERM reviewer cleanup (skipped: no process-group support)"
elif [ -z "$gc2" ]; then
  bad "INT/TERM cleanup: reviewer never started (setup issue, not the trap)"
else
  kill -TERM "$engine_pid" 2>/dev/null
  # bash defers a trapped signal until the running foreground command returns, and the wait
  # loop sits in `sleep 5`, so cleanup can lag up to ~5s — poll well past that (grandchild
  # sleeps 300, so a long poll can't false-pass).
  dead=0
  for _ in $(seq 1 32); do ! kill -0 "$gc2" 2>/dev/null && { dead=1; break; }; sleep 0.5; done
  if [ "$dead" -eq 1 ]; then ok "INT/TERM group-kills reviewers (no orphan on interrupt)"
  else bad "INT/TERM group-kills reviewers (orphan survived on interrupt)"; fi
fi
[ -n "$gc2" ] && kill "$gc2" 2>/dev/null; kill "$engine_pid" 2>/dev/null; true

# ---- test 14: reconcile input carries the code context ---------------------------
# The reconciler judges each finding's CLAIM against the source, so its input must carry the
# same changed-file snapshots the reviewers got. With only the diff it can confirm a line
# exists but never whether the asserted defect is real — which is what lets plausible-but-
# false findings survive on agreement alone.
RECON_COPY="$TMP/recon_in.md"; rm -f "$RECON_COPY"
cat > "$TMP/fakerec.sh" <<EOF
#!/usr/bin/env bash
cp "\$1" "$RECON_COPY"
printf '%s' '{"body":"ok","event":"COMMENT","comments":[]}' > "\$2"
EOF
mkconfig "$TMP/fake1.sh" "bash $TMP/fakerec.sh {PROMPT} {OUT}"
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --timeout 60 2>&1)"
if [ -f "$RECON_COPY" ] \
   && grep -q 'Code under review' "$RECON_COPY" \
   && grep -q 'Full content of changed files' "$RECON_COPY" \
   && grep -q 'src/app.py' "$RECON_COPY"; then
  ok "reconcile input carries changed-file context for claim verification"
else bad "reconcile input carries changed-file context: $out"; fi

# ---- test 15: FULLFILE_LINE_CAP=0 means unlimited, not "truncate to nothing" ------
# 0 is the "no limit" sentinel for the other caps. Without special-casing it here, 0 meant
# head -n 0 per changed file (an empty fenced block) AND skipped every related file, because
# the related loop drops anything larger than the per-file cap — silently emptying context.
mkconfig "$TMP/fake1.sh"
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" FULLFILE_LINE_CAP=0 \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2 | tr -d '\r')"
if [ -n "$ws" ] && [ -f "$ws/prompt.md" ] \
   && grep -q 'def main' "$ws/prompt.md" \
   && ! grep -q 'showing first 0' "$ws/prompt.md" \
   && grep -q 'sibling.py' "$ws/prompt.md"; then
  ok "FULLFILE_LINE_CAP=0 disables the per-file limit instead of emptying context"
else bad "FULLFILE_LINE_CAP=0 disables the per-file limit: $out"; fi

# ---- test 16: C# type references resolve to related context ----------------------
# C# `using` names a NAMESPACE, not a file, so Tier 2 reduced `using MyApp.Services;` to
# `Services` and matched no filename — a changed .cs file got zero forward context. Tier 3
# resolves referenced type identifiers to same-named files instead. Framework types must
# NOT drag anything in (there is no Task.cs), and the same-folder sibling still applies.
# FooService lives in a DIFFERENT folder, so Tier 1 (same-folder siblings) cannot reach it —
# Tier 3 is the only path, which is what makes this test fail on the pre-fix engine.
CSREPO="$TMP/csrepo"
mkdir -p "$CSREPO/src/Api" "$CSREPO/src/Services"
cat > "$CSREPO/src/Services/FooService.cs" <<'EOF'
namespace MyApp.Services;
public class FooService {
    public string Get(string id) => id;
}
EOF
cat > "$CSREPO/src/Api/FooController.cs" <<'EOF'
using System.Threading.Tasks;
using MyApp.Services;
namespace MyApp.Api;
public class FooController {
    public string Handle(string id) => new FooService().Get(id);
}
EOF
git -C "$CSREPO" init -q
git -C "$CSREPO" -c user.name=t -c user.email=t@t add -A
git -C "$CSREPO" -c user.name=t -c user.email=t@t commit -qm init
cat > "$TMP/cs.patch" <<'EOF'
diff --git a/src/Api/FooController.cs b/src/Api/FooController.cs
index 1111111..2222222 100644
--- a/src/Api/FooController.cs
+++ b/src/Api/FooController.cs
@@ -3,4 +3,5 @@ namespace MyApp.Api;
 public class FooController {
     public string Handle(string id) => new FooService().Get(id);
+    public string Extra(string id) => new FooService().Get(id);
 }
EOF
mkconfig "$TMP/fake1.sh"
out="$(cd "$CSREPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash "$ROOT/bin/multi-review" --diff "$TMP/cs.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2 | tr -d '\r')"
if [ -n "$ws" ] && [ -f "$ws/prompt.md" ] && grep -q 'FooService.cs' "$ws/prompt.md"; then
  ok "C# type reference resolves to related context (Tier 3)"
else bad "C# type reference resolves to related context: $out"; fi

# ---- test 17: hunk parser maps diff lines to real file line numbers --------------
# The whole point: a finding's line must be the NEW-FILE line number, not its position in
# the diff text. This is what localization scoring checks against, and what tells a
# pre-existing `context` line apart from an `added` one.
cat > "$TMP/hunks.patch" <<'EOF'
diff --git a/src/app.py b/src/app.py
index 0000000..1111111 100644
--- a/src/app.py
+++ b/src/app.py
@@ -1,3 +1,4 @@
 def main():
+    x = 1 / 0
     return 0
@@ -10,2 +11,2 @@ def other():
-    old_line()
+    new_line()
EOF
dl="$(bash "$ROOT/lib/diff-lines.sh" "$TMP/hunks.patch")"
if grep -qx 'src/app.py	RIGHT	2	added'   <<<"$dl" \
   && grep -qx 'src/app.py	RIGHT	1	context' <<<"$dl" \
   && grep -qx 'src/app.py	RIGHT	3	context' <<<"$dl" \
   && grep -qx 'src/app.py	LEFT	10	removed' <<<"$dl" \
   && grep -qx 'src/app.py	RIGHT	11	added'  <<<"$dl"; then
  ok "hunk parser maps added/context/removed lines to file line numbers"
else bad "hunk parser maps added/context/removed lines: $dl"; fi

# ---- test 18: blank context line doesn't desync the hunk parser ------------------
# Some diff producers emit a blank context line with the leading space trimmed. Treating it
# as "end of hunk" silently dropped every later line in that hunk and shifted the numbering
# of everything after it — a wrong line number here is an unpostable finding, not a warning.
printf 'diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1,4 +1,5 @@\n line1\n\n+added\n line4\n' > "$TMP/blank.patch"
dlb="$(bash "$ROOT/lib/diff-lines.sh" "$TMP/blank.patch")"
if grep -qx 'x.py	RIGHT	2	context' <<<"$dlb" \
   && grep -qx 'x.py	RIGHT	3	added' <<<"$dlb" \
   && grep -qx 'x.py	RIGHT	4	context' <<<"$dlb"; then
  ok "blank context line keeps hunk line numbering in sync"
else bad "blank context line keeps hunk line numbering in sync: $dlb"; fi

# ---- test 19: judge input carries the added-line set ------------------------------
# The judge must not charge a pre-existing defect to this PR, and reading `+` prefixes off
# the diff is exactly the call it gets wrong. The fixture adds ONE line (src/app.py:2);
# lines 1 and 3 are context, so the annotation must say "2" and nothing else.
RECON_COPY2="$TMP/recon_in2.md"; rm -f "$RECON_COPY2"
cat > "$TMP/fakerec2.sh" <<EOF
#!/usr/bin/env bash
cp "\$1" "$RECON_COPY2"
printf '%s' '{"body":"ok","event":"COMMENT","comments":[]}' > "\$2"
EOF
mkconfig "$TMP/fake1.sh" "bash $TMP/fakerec2.sh {PROMPT} {OUT}"
out="$(cd "$REPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash "$ROOT/bin/multi-review" --diff "$TMP/fixture.patch" --timeout 60 2>&1)"
if [ -f "$RECON_COPY2" ] \
   && grep -q 'Lines this change introduced' "$RECON_COPY2" \
   && grep -qx 'src/app.py: 2' "$RECON_COPY2"; then
  ok "judge input lists the lines the change actually introduced"
else bad "judge input lists introduced lines: $out"; fi

# ---- test 20: an unpostable line is filtered out, not left to sink the review -----
# The reviews API rejects the WHOLE review if one comment names a line the diff doesn't
# expose. The fixture diff exposes src/app.py lines 1-3 only, so a finding on line 4242 must
# be stripped from .comments and its text carried into .body instead of being lost.
cat > "$TMP/fake_badline.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'JSON'
{"reviewer":"fake","findings":[
 {"file":"src/app.py","line":2,"side":"RIGHT","severity":"high","category":"bug","title":"real one","detail":"on a diff line","suggestion":null,"confidence":0.9},
 {"file":"src/app.py","line":4242,"side":"RIGHT","severity":"high","category":"bug","title":"ghost line","detail":"not in the diff","suggestion":null,"confidence":0.9}
]}
JSON
EOF
cat > "$TMP/passthru_rec.sh" <<'EOF'
#!/usr/bin/env bash
jq '{body:"## PR Review", event:"COMMENT",
     comments:[.findings[]|{path:.file,line:.line,side:.side,body:("[[HIGH]] "+.title)}]}' \
  "$(ls -1 "$(dirname "$1")"/*.json | grep -v '_' | head -1)" > "$2"
EOF
mkconfig "$TMP/fake_badline.sh" "bash $TMP/passthru_rec.sh {PROMPT} {OUT}"
rm -f "$FAKE_GH_POSTED"; : > "$FAKE_GH_COMMENTS"
out="$(post_run)"
if [ -f "$FAKE_GH_POSTED" ] \
   && jq -e '[.comments[].line] | index(4242) | not' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '[.comments[].line] | index(2) != null' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '.body | contains("4242")' "$FAKE_GH_POSTED" >/dev/null; then
  ok "post: off-diff comment filtered out and carried into the review body"
else bad "post: off-diff comment filtered: $out"; fi

# ---- test 21: a rejected inline post degrades to body-only, not to nothing --------
# If GitHub still refuses the inline comments, the whole review used to be lost under set -e.
# It must retry body-only so the findings still reach the PR.
rm -f "$FAKE_GH_POSTED"; : > "$FAKE_GH_COMMENTS"
out="$(FAKE_GH_REJECT_INLINE=1 post_run)"
if [ -f "$FAKE_GH_POSTED" ] \
   && jq -e '.comments | length == 0' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '.body | contains("rejected the inline comments")' "$FAKE_GH_POSTED" >/dev/null \
   && jq -e '.body | contains("src/app.py:2")' "$FAKE_GH_POSTED" >/dev/null; then
  ok "post: inline rejection falls back to a body-only review instead of losing it"
else bad "post: inline rejection falls back to body-only: $out"; fi

# ---- test 22: reverse references attach the CONSUMER of a changed symbol ----------
# web/routes.py calls handle_request(), which svc/handler.py defines. Nothing in tiers 1-3
# can reach it: it's in a different folder (not a Tier 1 sibling), handler.py doesn't import
# it (Tier 2 looks the other way), and Tier 3 is .cs/.java/.kt only. Only a reverse-reference
# lookup finds a caller — which is where wiring/guard evidence actually lives.
RVREPO="$TMP/rvrepo"; mkdir -p "$RVREPO/svc" "$RVREPO/web"
cat > "$RVREPO/svc/handler.py" <<'EOF'
def handle_request(session, payload):
    return {"ok": True}
EOF
cat > "$RVREPO/web/routes.py" <<'EOF'
from svc.handler import handle_request


def route(session, payload):
    return handle_request(session, payload)
EOF
git -C "$RVREPO" init -q
git -C "$RVREPO" -c user.name=t -c user.email=t@t add -A
git -C "$RVREPO" -c user.name=t -c user.email=t@t commit -qm init
cat > "$TMP/rv.patch" <<'EOF'
diff --git a/svc/handler.py b/svc/handler.py
index 1111111..2222222 100644
--- a/svc/handler.py
+++ b/svc/handler.py
@@ -1,2 +1,3 @@
 def handle_request(session, payload):
+    audit(session)
     return {"ok": True}
EOF
mkconfig "$TMP/fake1.sh"
out="$(cd "$RVREPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash "$ROOT/bin/multi-review" --diff "$TMP/rv.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2 | tr -d '\r')"
if [ -n "$ws" ] && [ -f "$ws/prompt.md" ] && grep -q 'web/routes.py' "$ws/prompt.md"; then
  ok "reverse references attach a consumer of the changed symbol (Tier 4)"
else bad "reverse references attach a consumer: $out"; fi

# ---- test 23: `from pkg import mod` attaches mod, even past the sibling cap --------
# Reproduces a miss the benchmark caught end-to-end. Tier 1 attaches at most 3 same-folder
# siblings; here app/ holds four, so one is cut. Tier 2 must rescue the one the change
# actually imports — it used to extract only `app` (the package DIRECTORY, matching no
# file), so app/util.py was never attached, the judge could not confirm a real
# broken-reference finding against it, and dropped the bug.
IMPREPO="$TMP/imprepo"; mkdir -p "$IMPREPO/app"
printf 'def helper():\n    return 42\n'                    > "$IMPREPO/app/util.py"
printf 'def check(session):\n    pass\n'                   > "$IMPREPO/app/auth.py"
printf 'def a():\n    pass\n'                              > "$IMPREPO/app/aaa.py"
printf 'def b():\n    pass\n'                              > "$IMPREPO/app/bbb.py"
printf 'def c():\n    pass\n'                              > "$IMPREPO/app/ccc.py"
printf 'from app import util\n\n\ndef go():\n    return util.helper()\n' > "$IMPREPO/app/stats.py"
git -C "$IMPREPO" init -q
git -C "$IMPREPO" -c user.name=t -c user.email=t@t add -A
git -C "$IMPREPO" -c user.name=t -c user.email=t@t commit -qm init
cat > "$TMP/imp.patch" <<'EOF'
diff --git a/app/stats.py b/app/stats.py
index 1111111..2222222 100644
--- a/app/stats.py
+++ b/app/stats.py
@@ -3,3 +3,4 @@ from app import util
 def go():
+    return util.helper_all()
     return util.helper()
EOF
mkconfig "$TMP/fake1.sh"
out="$(cd "$IMPREPO" && MULTI_REVIEW_CONFIG="$TMP/config.json" \
  bash "$ROOT/bin/multi-review" --diff "$TMP/imp.patch" --no-reconcile --timeout 60 2>&1)"
ws="$(grep -o 'WORKSPACE=.*' <<<"$out" | cut -d= -f2 | tr -d '\r')"
if [ -n "$ws" ] && [ -f "$ws/prompt.md" ] && grep -q '### app/util.py' "$ws/prompt.md"; then
  ok "from-import attaches the imported module past the sibling cap"
else bad "from-import attaches the imported module: $out"; fi

# ---- test 24: malformed multi-line keys are sanitised, not propagated -------------
# start_line arrives null, as a string, or swapped past `line` so the range runs backwards;
# the reviews API refuses every one. The finding itself is still real, so the bad KEYS are
# dropped and it posts as a single-line comment — and dropped means ABSENT, since an
# explicit null is rejected too. A genuine range (start_line < line) must survive intact.
cat > "$TMP/fake_ml.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'JSON'
{"reviewer":"fake","findings":[
 {"file":"src/app.py","line":2,"side":"right","severity":"high","category":"bug","title":"lowercase side","detail":"d","confidence":0.9},
 {"file":"src/app.py","line":2,"start_line":null,"start_side":null,"severity":"high","category":"bug","title":"null range","detail":"d","confidence":0.9},
 {"file":"src/app.py","line":2,"start_line":9,"start_side":"RIGHT","severity":"high","category":"bug","title":"backwards range","detail":"d","confidence":0.9},
 {"file":"src/app.py","line":3,"start_line":1,"start_side":"right","severity":"high","category":"bug","title":"good range","detail":"d","confidence":0.9}
]}
JSON
EOF
mkconfig "$TMP/fake_ml.sh"
out="$(run_engine)"
f="$(findings_path "$out")"
if [ -n "$f" ] \
   && [ "$(jq -r '[.findings[] | select(.title=="lowercase side") | .side] | first' "$f")" = "RIGHT" ] \
   && [ "$(jq -r '[.findings[] | select(.title=="null range") | has("start_line")] | first' "$f")" = "false" ] \
   && [ "$(jq -r '[.findings[] | select(.title=="backwards range") | has("start_line")] | first' "$f")" = "false" ] \
   && [ "$(jq -r '[.findings[] | select(.title=="backwards range")] | length' "$f")" = "1" ] \
   && [ "$(jq -r '[.findings[] | select(.title=="good range") | .start_line] | first' "$f")" = "1" ] \
   && [ "$(jq -r '[.findings[] | select(.title=="good range") | .start_side] | first' "$f")" = "RIGHT" ]; then
  ok "malformed multi-line keys dropped, valid range and side normalised"
else bad "malformed multi-line keys sanitised: $(cat "$f" 2>/dev/null)"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
