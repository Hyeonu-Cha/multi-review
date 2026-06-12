#!/usr/bin/env bash
# Smoke tests for bin/multi-review, driven by a fake reviewer CLI — no real AI CLI,
# network, or gh needed (bash + jq + git only). Run: bash tests/run.sh
#
# Covers: fan-out + findings capture, JSON salvage (fence/prose-wrapped output),
# per-finding sanitization (malformed findings dropped), and help/flag plumbing.
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

mkconfig() {  # mkconfig <fake reviewer script> — config pointing at the fake CLI
  cat > "$TMP/config.json" <<EOF
{
  "reviewers": [ { "name": "fake", "enabled": true, "cmd": "bash $1 {OUT}" } ],
  "instruction": "review {DIFF} per {PROMPT}; write findings to {OUT}",
  "reconciler": { "name": "true", "cmd": "true" }
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

# ---- test 7: help/flag plumbing -------------------------------------------------
if bash "$ROOT/bin/multi-review" --help | grep -q -- '--max-comments'; then
  ok "--max-comments documented in --help"
else bad "--max-comments documented in --help"; fi
if out="$(cd "$ROOT" && bash bin/multi-review --max-comments x 2>&1)"; [ $? -ne 0 ] && grep -q 'positive integer' <<<"$out"; then
  ok "--max-comments rejects non-numeric values"
else bad "--max-comments rejects non-numeric values"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
