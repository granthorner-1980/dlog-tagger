#!/bin/bash
# Helpers for CHANGELOG.md, used by the Release workflow.
#   changelog.sh unreleased            print the body of the [Unreleased] section
#   changelog.sh stamp VERSION DATE    turn [Unreleased] into [VERSION] - DATE, add a fresh empty
#                                      [Unreleased] above it, and update the compare links
set -euo pipefail
FILE="${CHANGELOG:-CHANGELOG.md}"
REPO="https://github.com/granthorner-1980/dlog-tagger"

case "${1:-}" in
  unreleased)
    # lines after "## [Unreleased]" up to the next "## [" heading or the link block; trim blank edges
    awk '
      /^## \[Unreleased\]/ { on=1; next }
      on && (/^## \[/ || /^\[[^]]+\]: /) { exit }
      on { print }
    ' "$FILE" | sed -e '/./,$!d' | awk '{ a[NR]=$0 } END { n=NR; while (n>0 && a[n] ~ /^[[:space:]]*$/) n--; for (i=1;i<=n;i++) print a[i] }'
    ;;

  stamp)
    VERSION="$2"; DATE="$3"
    PREV=$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$FILE" | head -1 | tr -d '#[] ' || true)
    awk -v v="$VERSION" -v d="$DATE" -v repo="$REPO" -v prev="$PREV" '
      /^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next }
      /^\[Unreleased\]: / {
        print "[Unreleased]: " repo "/compare/v" v "...HEAD"
        if (prev != "") print "[" v "]: " repo "/compare/v" prev "...v" v
        else            print "[" v "]: " repo "/releases/tag/v" v
        next
      }
      { print }
    ' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    ;;

  *)
    echo "usage: $0 unreleased | stamp VERSION DATE" >&2; exit 2 ;;
esac
