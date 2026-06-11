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
  "profile": "",
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
sleep 2  # out/<timestamp> dirs are second-granular; avoid colliding workspaces

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
sleep 2

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

# ---- test 4: help/flag plumbing -------------------------------------------------
if bash "$ROOT/bin/multi-review" --help | grep -q -- '--max-comments'; then
  ok "--max-comments documented in --help"
else bad "--max-comments documented in --help"; fi
if out="$(cd "$ROOT" && bash bin/multi-review --max-comments x 2>&1)"; [ $? -ne 0 ] && grep -q 'positive integer' <<<"$out"; then
  ok "--max-comments rejects non-numeric values"
else bad "--max-comments rejects non-numeric values"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
