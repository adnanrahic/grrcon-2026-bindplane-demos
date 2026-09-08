#!/usr/bin/env bash
# Refreshes samples/palo-alto.log from a blitz checkout.
#
# The lines are copied VERBATIM from blitz's palo-alto/csv package: 15 lines
# across 13 PAN-OS log types, each carrying a "%b %e %T localhost " prefix that
# renders to a syslog header. That prefix is load-bearing -- Bindplane's Palo
# Alto blueprint opens with a "Strip Syslog Header" regex expecting it, so do
# not trim it.
#
# Vendored rather than bind-mounted so the stack needs no blitz clone. Run this
# only to pick up upstream changes; a clone is required for THIS script, not for
# running the demo.
#
# NOTE: palo-alto.log cannot contain comments -- filegen emits every non-empty
# line verbatim as a log record.

set -euo pipefail

REPO="${BLITZ_REPO:-../blitz}"
SRC="$REPO/generator/filegen/embeddedlibrary/data_library/palo-alto/csv"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/palo-alto.log"

[ -d "$SRC" ] || { echo "no blitz checkout at $REPO (set BLITZ_REPO)" >&2; exit 1; }

for f in $(ls "$SRC"/*.log | sort); do grep -h . "$f"; done > "$OUT"

printf 'wrote %s (%s lines, %s log types)\n' \
  "$OUT" "$(grep -c . "$OUT")" "$(awk -F',' '{print $4}' "$OUT" | sort -u | grep -c .)"
