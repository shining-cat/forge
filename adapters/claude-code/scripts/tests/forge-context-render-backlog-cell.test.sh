#!/usr/bin/env bash
# Tests forge-context.sh render-backlog-cell (final span-lane format).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS+1)); else echo "  ✗ $1"; echo "      exp: $2"; echo "      got: $3"; FAIL=$((FAIL+1)); fi; }
slot(){ printf '<span style="display:inline-block;width:1.3em;text-align:center">%s</span>' "$1"; }
O='<span style="white-space:nowrap;font-size:0.85em">'; C='</span>'
# effort
chk "effort S" "${O}$(slot 🟦)$(slot ·)$(slot ·)${C}<br>S" "$("$FC" render-backlog-cell effort S)"
chk "effort M" "${O}$(slot 🟦)$(slot 🟦)$(slot ·)${C}<br>M" "$("$FC" render-backlog-cell effort M)"
chk "effort L" "${O}$(slot 🟦)$(slot 🟦)$(slot 🟦)${C}<br>L" "$("$FC" render-backlog-cell effort L)"
chk "effort lc m" "${O}$(slot 🟦)$(slot 🟦)$(slot ·)${C}<br>M" "$("$FC" render-backlog-cell effort m)"
# impact
chk "impact L" "${O}$(slot 🟪)$(slot ·)$(slot ·)${C}<br>L" "$("$FC" render-backlog-cell impact L)"
chk "impact M" "${O}$(slot 🟪)$(slot 🟪)$(slot ·)${C}<br>M" "$("$FC" render-backlog-cell impact M)"
chk "impact H" "${O}$(slot 🟪)$(slot 🟪)$(slot 🟪)${C}<br>H" "$("$FC" render-backlog-cell impact H)"
# status (incl 7→4 collapse + new ⚪ open)
chk "status active"          '🟢<br>active'  "$("$FC" render-backlog-cell status active)"
chk "status underway→active" '🟢<br>active'  "$("$FC" render-backlog-cell status underway)"
chk "status partial→active"  '🟢<br>active'  "$("$FC" render-backlog-cell status partial)"
chk "status next"            '🟠<br>next'    "$("$FC" render-backlog-cell status next)"
chk "status open"            '⚪<br>open'    "$("$FC" render-backlog-cell status open)"
chk "status needs-triage→open" '⚪<br>open'  "$("$FC" render-backlog-cell status needs-triage)"
chk "status blocked"         '🔴<br>blocked' "$("$FC" render-backlog-cell status blocked)"
chk "status dormant→blocked" '🔴<br>blocked' "$("$FC" render-backlog-cell status dormant)"
chk "status low/fuzzy→blocked" '🔴<br>blocked' "$("$FC" render-backlog-cell status low/fuzzy)"
chk "status fuzzy→blocked"   '🔴<br>blocked' "$("$FC" render-backlog-cell status fuzzy)"
# error paths
"$FC" render-backlog-cell effort Q >/dev/null 2>&1; [ $? -eq 2 ] && { echo "  ✓ bad effort exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ bad effort"; FAIL=$((FAIL+1)); }
"$FC" render-backlog-cell impact S >/dev/null 2>&1; [ $? -eq 2 ] && { echo "  ✓ impact rejects S exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ impact S"; FAIL=$((FAIL+1)); }
"$FC" render-backlog-cell status bogus >/dev/null 2>&1; [ $? -eq 2 ] && { echo "  ✓ bad status exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ bad status"; FAIL=$((FAIL+1)); }
"$FC" render-backlog-cell nope M >/dev/null 2>&1; [ $? -eq 2 ] && { echo "  ✓ bad dim exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ bad dim"; FAIL=$((FAIL+1)); }
"$FC" render-backlog-cell effort >/dev/null 2>&1; [ $? -eq 2 ] && { echo "  ✓ missing value exit 2"; PASS=$((PASS+1)); } || { echo "  ✗ missing value"; FAIL=$((FAIL+1)); }
echo ""; echo "── Total: $PASS pass, $FAIL fail ──"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
