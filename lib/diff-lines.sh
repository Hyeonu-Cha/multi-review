#!/usr/bin/env bash
# Enumerate every addressable line of a unified diff as TSV:
#
#   <path>\t<side>\t<line>\t<kind>[\t<content>]
#
#   side     RIGHT = new-file numbering, LEFT = old-file numbering
#   kind     added | removed | context
#   content  only with --with-content: the line text with its +/-/space prefix stripped
#            (may itself contain tabs — consumers must take "everything after field 4")
#
# This is the only place that walks `@@ -old,n +new,m @@` hunk headers. Consumers:
#   * bench/run.sh — localization scoring. A finding whose (path, side, line) is not in
#     this set 422s when posted, so the finding is lost entirely, not merely misplaced.
#   * bin/multi-review — finding annotation (on_diff / introduced), the judge's added-line
#     set, the posting filter, and (--with-content) the static checks over added lines.
#
# Usage: bash lib/diff-lines.sh [--with-content] <diff-file>
set -euo pipefail
WITH_CONTENT=0
if [ "${1:-}" = "--with-content" ]; then WITH_CONTENT=1; shift; fi
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: diff-lines.sh [--with-content] <diff-file>" >&2; exit 2; }

awk -v wc="$WITH_CONTENT" '
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
  # content column: the line minus its one-char prefix; empty for the trimmed blank line
  function tail(s) { return wc ? "\t" substr(s, 2) : "" }
  /^$/ { print path "\tRIGHT\t" new "\tcontext" (wc ? "\t" : ""); new++; old++; next }  # blank context line (space trimmed)
  /^\+/ { print path "\tRIGHT\t" new "\tadded" tail($0);   new++; next }
  /^-/  { print path "\tLEFT\t"  old "\tremoved" tail($0); old++; next }
  /^ /  { print path "\tRIGHT\t" new "\tcontext" tail($0); new++; old++; next }
  { inhunk = 0 }                                        # anything else ends the hunk body
' "$1"
