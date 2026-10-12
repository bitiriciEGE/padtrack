#!/usr/bin/env bash
# Turns test results and compiler/test errors from the build logs into GitHub annotations,
# so they show up on the run page (and through the API) without opening the raw logs.
set -u

for log in "$@"; do
  [ -f "$log" ] || continue
  name=$(basename "$log" .log)

  summary=$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$log" | tail -1)
  [ -n "$summary" ] && echo "::notice title=$name::$summary"

  errors=$(grep -E "(error:|: error |\*\* BUILD FAILED|\*\* TEST FAILED|Fatal error)" "$log" \
    | grep -v "warning:" | sed -E 's#^/Users/runner/work/[^/]+/[^/]+/##' | awk '!seen[$0]++' | head -40)
  if [ -n "$errors" ]; then
    message=$(printf '%s\n' "$errors" | sed 's/%/%25/g' | awk '{ printf "%s%%0A", $0 }')
    echo "::error title=$name::$message"
  fi
done
