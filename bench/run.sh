#!/usr/bin/env bash
# Recall benchmark: builds a tiny fixture repo with planted bugs (bench/cases.json),
# fans the change out to the REAL reviewer CLIs, and scores each reviewer's findings
# against the expected cases. This is how you measure whether a prompt/criteria tweak
# actually improved detection — instead of guessing.
#
# COSTS REAL QUOTA on every enabled reviewer — opt-in, NOT part of tests/run.sh.
#
# Usage:
#   bash bench/run.sh                          # all enabled reviewers, default timeout
#   bash bench/run.sh --reviewers agy,copilot  # subset
#   bash bench/run.sh --timeout 1200           # slow models
#
# A finding scores a hit when: same file, line within ±3, and title+detail matches
# the case's keyword pattern (so co-located cases can't cross-credit each other).
set -euo pipefail

# Windows jq emits CRLF; strip CR so values feeding shell vars/--argjson stay clean.
jqr() { jq "$@" | tr -d '\r'; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES="$ROOT/bench/cases.json"
TMPR="$(mktemp -d)"
trap 'rm -rf "$TMPR"' EXIT

# ---- build the fixture repo ---------------------------------------------------
# Base commit: sibling handlers that all apply an auth guard, a registry that
# registers "db", a util module with helper(). The change commit adds app/stats.py
# with six planted bugs (see bench/cases.json) under an intent that claims the
# endpoint is read-only.
REPO="$TMPR/repo"
mkdir -p "$REPO/app"

cat > "$REPO/app/auth.py" <<'EOF'
def check_session(session):
    if not session.get("user"):
        raise PermissionError("no session")
EOF

cat > "$REPO/app/handlers.py" <<'EOF'
from app import auth


def get_profile(session, user_id):
    auth.check_session(session)
    return {"user": user_id}


def update_profile(session, user_id, data):
    auth.check_session(session)
    return {"updated": user_id, "data": data}
EOF

cat > "$REPO/app/registry.py" <<'EOF'
_services = {}


def register(name, factory):
    _services[name] = factory


def resolve(name):
    return _services[name]()


def bootstrap():
    register("db", lambda: object())
EOF

cat > "$REPO/app/util.py" <<'EOF'
def helper():
    return 42
EOF

git -C "$REPO" init -q
git -C "$REPO" -c user.name=bench -c user.email=b@b add -A
git -C "$REPO" -c user.name=bench -c user.email=b@b commit -qm "base app"
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

# The change under review — line numbers here must match bench/cases.json.
cat > "$REPO/app/stats.py" <<'EOF'
import hashlib

from app import registry, util


def get_stats(session, bucket_count):
    db = registry.resolve("db_client")
    total = util.helper_all()
    per_bucket = total / bucket_count
    purge_old_records(db)
    return {"per_bucket": per_bucket}


def purge_old_records(db):
    db.delete_old()
EOF
git -C "$REPO" -c user.name=bench -c user.email=b@b add -A
git -C "$REPO" -c user.name=bench -c user.email=b@b commit -qm "Add read-only stats endpoint"

# ---- fan out to the real reviewers ---------------------------------------------
echo "› benchmark repo: $REPO (base $BASE_SHA)"
out="$(cd "$REPO" && bash "$ROOT/bin/multi-review" --base "$BASE_SHA" --no-reconcile "$@" 2>&1)" || true
echo "$out"
echo

# ---- score each reviewer against the cases --------------------------------------
declare -A FINDINGS
while IFS= read -r line; do
  name="${line#FINDINGS[}"; name="${name%%]=*}"
  FINDINGS["$name"]="${line#*=}"
done < <(grep -o 'FINDINGS\[[^]]*\]=.*' <<<"$out" | tr -d '\r')

if [ "${#FINDINGS[@]}" -eq 0 ]; then
  echo "no reviewer produced findings — nothing to score" >&2
  exit 1
fi

mapfile -t IDS   < <(jqr -r '.[].id' "$CASES")
mapfile -t NAMES < <(printf '%s\n' "${!FINDINGS[@]}" | sort)

printf '%-22s' "case"
for n in "${NAMES[@]}"; do printf '%-10s' "$n"; done
printf '%s\n' "union"

declare -A TOTAL
union_hits=0
for id in "${IDS[@]}"; do
  file="$(jqr -r --arg id "$id" '.[] | select(.id==$id) | .file' "$CASES")"
  cl="$(jqr -r --arg id "$id" '.[] | select(.id==$id) | .line' "$CASES")"
  pat="$(jqr -r --arg id "$id" '.[] | select(.id==$id) | .pattern' "$CASES")"
  printf '%-22s' "$id"
  union=0
  for n in "${NAMES[@]}"; do
    hit="$(jqr -r --arg f "$file" --argjson l "$cl" --arg p "$pat" '
      [.findings[]
        | select((.file == $f) or ((.file|tostring) | endswith($f)))
        | select(((.line - $l) | if . < 0 then -. else . end) <= 3)
        | select((((.title // "") + " " + (.detail // "")) | test($p; "i")))
      ] | length' "${FINDINGS[$n]}" 2>/dev/null || echo 0)"
    if [ "${hit:-0}" -gt 0 ]; then
      printf '%-10s' "HIT"; TOTAL["$n"]=$(( ${TOTAL["$n"]:-0} + 1 )); union=1
    else
      printf '%-10s' "-"
    fi
  done
  if [ "$union" -eq 1 ]; then printf '%s\n' "HIT"; union_hits=$((union_hits+1)); else printf '%s\n' "-"; fi
done

printf '%-22s' "recall"
for n in "${NAMES[@]}"; do printf '%-10s' "${TOTAL[$n]:-0}/${#IDS[@]}"; done
printf '%s\n' "$union_hits/${#IDS[@]}"
echo
echo "union = caught by at least one reviewer (pipeline recall before reconcile;"
echo "the in-session Claude pass and reconcile can only add, not subtract)."
