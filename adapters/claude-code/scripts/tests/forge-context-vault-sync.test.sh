#!/usr/bin/env bash
# Tests forge-context.sh vault-sync — the grouped report + interactive commit
# path, plus the multi-repo extension (outer repo + nested private repos from
# VAULT_PRIVATE_ROOTS) and transient-artifact exclusion.
#
# Mirrors the topology in reference_vault_git_topology: an OUTER repo (personal
# GitHub) whose .gitignore excludes nested private roots, and a nested PRO/ repo
# carrying its OWN remote (Schibsted GHEC). Each repo pushes to its own origin.
#
# --commit is driven with FORGE_ASSUME_DEFAULTS=1 so the no-TTY default (auto-Y)
# fires deterministically without a controlling terminal.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0
chk()   { if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS+1)); else echo "  ✗ $1"; echo "      exp: $2"; echo "      got: $3"; FAIL=$((FAIL+1)); fi; }
has()   { if echo "$2" | grep -qF -- "$1"; then echo "  ✓ $3"; PASS=$((PASS+1)); else echo "  ✗ $3"; echo "      missing: $1"; FAIL=$((FAIL+1)); fi; }
hasnt() { if echo "$2" | grep -qF -- "$1"; then echo "  ✗ $3"; echo "      unexpected: $1"; FAIL=$((FAIL+1)); else echo "  ✓ $3"; PASS=$((PASS+1)); fi; }

commits() { git -C "$1" rev-list --count HEAD 2>/dev/null; }
ahead()   { git -C "$1" rev-list --count '@{u}..HEAD' 2>/dev/null; }  # 0 == fully pushed

# ── Fixture ─────────────────────────────────────────────────────────────
setup() {
  TMP=$(mktemp -d)
  ORIGINS=$(mktemp -d)
  TMP_CONF=$(mktemp)                       # conf lives OUTSIDE the vault tree
  cat > "$TMP_CONF" <<EOF
VAULT_PATH=$TMP
VAULT_PRIVATE_ROOTS=PRO
EOF
  mkdir -p "$TMP/_shared" "$TMP/PERSO/demo"   # project dir so get_vault_dir resolves the marker
  cat > "$TMP/_shared/forge-active" <<EOF
{"session_id":"test-session","project":"demo","started_at":"2026-07-09T11:00:00+0200","tmux_pane":null}
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export CLAUDE_CODE_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP" "$ORIGINS" "$TMP_CONF"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP ORIGINS TMP_CONF
}

# Init a git repo at $1 with a bare origin at $2, initial commit + upstream.
init_repo_with_origin() {
  local repo="$1" origin="$2" ignore="${3:-}"
  git init -q --bare "$origin"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@e
  git -C "$repo" config user.name t
  git -C "$repo" remote add origin "$origin"
  [ -n "$ignore" ] && printf '%s\n' "$ignore" > "$repo/.gitignore"
  echo scaffold > "$repo/SCAFFOLD.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m init
  git -C "$repo" push -q -u origin HEAD
}

# Outer repo ignores only PRO/ (real topology: _shared/ + PERSO/ are tracked).
# Seed a baseline file in each content dir BEFORE the initial commit so that
# later additions show as full paths in `git status --short` — git collapses
# fully-untracked dirs to `dir/`, which would hide filenames from the filter.
build_vault() {
  mkdir -p "$TMP/_shared" "$TMP/PERSO/forge" "$TMP/_templates"
  echo seed > "$TMP/_shared/.seed"
  echo seed > "$TMP/PERSO/forge/.seed"
  echo seed > "$TMP/_templates/.seed"
  init_repo_with_origin "$TMP" "$ORIGINS/outer.git" "PRO/"
  mkdir -p "$TMP/PRO"
  init_repo_with_origin "$TMP/PRO" "$ORIGINS/pro.git" ""
}

# Dirty both repos: tracked-content groups in outer, a transient upstream
# artifact that must be skipped, and content in the nested PRO repo.
dirty_vault() {
  echo cp > "$TMP/_shared/current-checkpoint.md"
  mkdir -p "$TMP/PERSO/forge"
  echo cp > "$TMP/PERSO/forge/current-checkpoint.md"
  mkdir -p "$TMP/_templates"
  echo tmpl > "$TMP/_templates/draft.md.upstream.20260625-112515"
  mkdir -p "$TMP/PRO/alpha"
  echo log > "$TMP/PRO/alpha/breadcrumbs.log"
}

# ── Check 1 — report mode: groups both repos, no commits, skips upstream ──
echo "Check 1 — report mode lists outer + nested groups, commits nothing"
setup; build_vault; dirty_vault
outer_before=$(commits "$TMP"); pro_before=$(commits "$TMP/PRO")
out=$("$FC" vault-sync 2>&1)
has "=== Vault sync: $TMP ==="        "$out" "outer repo header"
has "--- Group: _shared ---"          "$out" "outer _shared group"
has "--- Group: PERSO ---"            "$out" "outer PERSO group"
has "### Nested repo: PRO ###"        "$out" "nested PRO section"
has "--- Group: alpha ---"             "$out" "nested alpha group"
has "skipped 1 transient"             "$out" "upstream artifact skip noted"
hasnt "upstream"                      "$(echo "$out" | grep -- '--- Group')" "no upstream group"
chk  "outer commit count unchanged"  "$outer_before" "$(commits "$TMP")"
chk  "PRO commit count unchanged"    "$pro_before"   "$(commits "$TMP/PRO")"
teardown

# ── Check 2 — --commit: commits + pushes both repos, excludes upstream ────
echo ""
echo "Check 2 — --commit commits both repos, pushes each origin, skips upstream"
setup; build_vault; dirty_vault
outer_before=$(commits "$TMP"); pro_before=$(commits "$TMP/PRO")
out=$(FORGE_ASSUME_DEFAULTS=1 "$FC" vault-sync --commit 2>&1)
# outer gained 2 commits (_shared, PERSO)
chk "outer +2 commits" "$((outer_before + 2))" "$(commits "$TMP")"
# nested PRO gained 1 commit (alpha)
chk "PRO +1 commit"    "$((pro_before + 1))"   "$(commits "$TMP/PRO")"
# upstream artifact never tracked, still on disk
hasnt "upstream" "$(git -C "$TMP" ls-files)" "upstream artifact not committed"
[ -f "$TMP/_templates/draft.md.upstream.20260625-112515" ] \
  && { echo "  ✓ upstream artifact left on disk"; PASS=$((PASS+1)); } \
  || { echo "  ✗ upstream artifact vanished"; FAIL=$((FAIL+1)); }
# both repos fully pushed (nothing ahead of upstream)
chk "outer fully pushed" "0" "$(ahead "$TMP")"
chk "PRO fully pushed"   "0" "$(ahead "$TMP/PRO")"
teardown

# ── Check 3 — re-run after commit: upstream-only dirt reports clean ───────
echo ""
echo "Check 3 — re-run: only the skipped upstream artifact remains → clean"
setup; build_vault; dirty_vault
FORGE_ASSUME_DEFAULTS=1 "$FC" vault-sync --commit >/dev/null 2>&1
out=$("$FC" vault-sync 2>&1)
has "Clean. Nothing to sync." "$out" "outer reports clean (upstream filtered out)"
teardown

# ── Check 4 — fully clean vault: both repos report clean, no-op ───────────
echo ""
echo "Check 4 — clean vault reports clean for both repos"
setup; build_vault
out=$("$FC" vault-sync 2>&1)
has "=== Vault sync: $TMP ==="   "$out" "outer header present"
has "### Nested repo: PRO ###"   "$out" "nested PRO section present"
n=$(echo "$out" | grep -c "Clean. Nothing to sync.")
chk "both repos report clean" "2" "$n"
teardown

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "───────────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
