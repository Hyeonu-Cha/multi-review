#!/usr/bin/env bash
# Enumerate every addressable line of a unified diff as TSV:
#
#   <path>\t<side>\t<line>\t<kind>
#
#   side  RIGHT = new-file numbering, LEFT = old-file numbering
#   kind  added | removed | context
#
# This is the only place that walks `@@ -old,n +new,m @@` hunk headers. Two consumers:
#   * bench/run.sh — localization scoring. A finding whose (path, side, line) is not in
#     this set 422s when posted, so the finding is lost entirely, not merely misplaced.
#   * pre-existing/context annotation — a finding on a `context` line was NOT introduced
#     by the change, which is the top false-positive class.
#
# Usage: bash lib/diff-lines.sh <diff-file>
set -euo pipefail
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: diff-lines.sh <diff-file>" >&2; exit 2; }

awk '
  { sub(/\r$/, "") }                                    # tolerate CRLF diffs
  /^--- / { next }                                      # old-file header, not a removal
  /^\+\+\+ / {                                          # new-file header: start a file
      path = $0
      sub(/^\+\+\+ "?b\//, "", path); sub(/"$/, "", path)
      if (path == "/dev/null") path = ""                # deleted file: nothing addressable
      next
  }
  /^@@ / {                                              # @@ -old[,cnt] +new[,cnt] @@
      match($0, /-[0-9]+/); old = substr($0, RSTART + 1, RLENGTH - 1) + 0
      match($0, /\+[0-9]+/); new = substr($0, RSTART + 1, RLENGTH - 1) + 0
      inhunk = 1
      next
  }
  path == "" || !inhunk { next }                        # preamble (diff --git, index, …)
  /No newline at end of file/ { next }                  # git no-newline marker
  /^\+/ { print path "\tRIGHT\t" new "\tadded";   new++; next }
  /^-/  { print path "\tLEFT\t"  old "\tremoved"; old++; next }
  /^ /  { print path "\tRIGHT\t" new "\tcontext"; new++; old++; next }
  { inhunk = 0 }                                        # anything else ends the hunk body
' "$1"
