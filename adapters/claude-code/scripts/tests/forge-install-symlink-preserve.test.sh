#!/usr/bin/env bash
# Tests install.sh's install_symlink "preserve" policy — specifically the
# relocation-heal branch: an install-managed symlink whose source moved (e.g. a
# reference relocated core/ ↔ adapters/claude-code/) must be REPOINTED to the new
# source, not preserved as a dangling link. Only real-file customizations (the A2
# copy-convert-to-edit path) are preserved with a .upstream.<ts> sibling.
#
# Regression: 2026-08-11 — the core→adapter split of model-cost-posture.md /
# subagent-models.md left subagent-models.md's installed symlink pointing at the
# deleted core/ path (dangling), because write_upstream_sibling never touches dst.
#
# Hermetic: extracts the three real functions from install.sh at runtime (robust
# to line moves), stubs the globals they touch, and exercises each case in a tmp dir.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../../../../install.sh"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1 — $2"; FAIL=$((FAIL+1)); }

if [ ! -f "$INSTALL_SH" ]; then
  echo "  ✗ cannot locate install.sh at $INSTALL_SH"; exit 1
fi

# --- extract the real functions from install.sh (open line → next col-0 '}') ---
extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { f=1 }
    f { print }
    f && /^\}/ { exit }
  ' "$INSTALL_SH"
}

LIB="$(mktemp)"
{
  echo "DRY_RUN=false; DIM=''; NC=''; BACKUP_COUNT=0; PRUNED_SIBLING_COUNT=0"
  echo "warn() { :; }"
  extract_fn prune_old_upstream_siblings
  extract_fn write_upstream_sibling
  extract_fn install_symlink
} > "$LIB"
# shellcheck disable=SC1090
. "$LIB"

# Sanity: the fns loaded.
type install_symlink write_upstream_sibling prune_old_upstream_siblings >/dev/null 2>&1 \
  && ok "extracted install_symlink + deps from install.sh" \
  || { bad "extraction" "functions not defined after sourcing"; echo "── $PASS passed, $FAIL failed ──"; exit 1; }

# ── Case 1: dst missing → fresh symlink to src ──────────────────────────────
T=$(mktemp -d)
echo "SRC-NEW" > "$T/src-new.md"
install_symlink "$T/src-new.md" "$T/link.md" preserve
if [ -L "$T/link.md" ] && [ "$(readlink "$T/link.md")" = "$T/src-new.md" ]; then
  ok "missing dst → creates symlink to src"
else
  bad "missing dst" "link=$(readlink "$T/link.md" 2>/dev/null)"
fi
rm -rf "$T"

# ── Case 2: dst already correct → no-op, still points at src ─────────────────
T=$(mktemp -d)
echo "SRC" > "$T/src.md"
ln -s "$T/src.md" "$T/link.md"
install_symlink "$T/src.md" "$T/link.md" preserve
if [ "$(readlink "$T/link.md")" = "$T/src.md" ]; then
  ok "already-correct symlink → unchanged"
else
  bad "already-correct" "link=$(readlink "$T/link.md")"
fi
rm -rf "$T"

# ── Case 3 (THE FIX): dangling symlink (source deleted) → repointed to src ───
T=$(mktemp -d)
echo "NEW-SRC" > "$T/new-src.md"
ln -s "$T/gone-old-path.md" "$T/link.md"   # old target never existed / deleted
[ ! -e "$T/link.md" ] || bad "precondition" "link should dangle before fix"
install_symlink "$T/new-src.md" "$T/link.md" preserve
if [ -L "$T/link.md" ] && [ "$(readlink "$T/link.md")" = "$T/new-src.md" ] && [ -e "$T/link.md" ]; then
  ok "dangling symlink (relocated source) → repointed and resolves"
else
  bad "dangling repoint" "link=$(readlink "$T/link.md" 2>/dev/null) resolves=$([ -e "$T/link.md" ] && echo yes || echo no)"
fi
rm -rf "$T"

# ── Case 4: symlink to a DIFFERENT existing file (relocated, old still exists) ─
T=$(mktemp -d)
echo "OLD" > "$T/old.md"      # old source still on disk (e.g. rewritten, not moved)
echo "NEW" > "$T/new.md"
ln -s "$T/old.md" "$T/link.md"
install_symlink "$T/new.md" "$T/link.md" preserve
if [ "$(readlink "$T/link.md")" = "$T/new.md" ]; then
  ok "symlink to stale-but-existing target → repointed to new src"
else
  bad "relocate existing" "link=$(readlink "$T/link.md")"
fi
rm -rf "$T"

# ── Case 5: dst is a REAL user file → preserved, .upstream sibling written ────
T=$(mktemp -d)
echo "UPSTREAM" > "$T/src.md"
printf 'USER EDIT\n' > "$T/link.md"   # user copy-converted to a real file
install_symlink "$T/src.md" "$T/link.md" preserve
sib=$(ls "$T"/link.md.upstream.* 2>/dev/null | head -1 || true)
if [ ! -L "$T/link.md" ] && [ "$(cat "$T/link.md")" = "USER EDIT" ] && [ -n "$sib" ] && [ "$(cat "$sib")" = "UPSTREAM" ]; then
  ok "real user file → preserved, upstream captured in sibling"
else
  bad "real-file preserve" "islink=$([ -L "$T/link.md" ] && echo yes || echo no) sibling=${sib:-none}"
fi
rm -rf "$T"

rm -f "$LIB"
echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
