#!/usr/bin/env bash
# Tests do_recover's "Your vault (local history)" section — specifically the
# multi-repo extension that discovers nested .git directories one level deep
# under VAULT_PATH and audits each independently.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_CONTEXT="$SCRIPT_DIR/../forge-context.sh"

PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  TMP_CONF="$TMP/forge.conf"
  echo "VAULT_PATH=$TMP" > "$TMP_CONF"
  echo "REPO_ROOTS=$TMP/repos" >> "$TMP_CONF"
  mkdir -p "$TMP/_shared" "$TMP/repos/demo"
  # Real git repo on the mock project so recover's `git -C $PROJECT_DIR ...`
  # calls don't exit non-zero under set -euo pipefail (which would abort
  # recover before reaching the vault-state section).
  git -C "$TMP/repos/demo" init -q 2>/dev/null
  git -C "$TMP/repos/demo" -c user.email=t@e -c user.name=t \
    commit --allow-empty -q -m init 2>/dev/null

  mkdir -p "$TMP/PERSO/demo/tasks/open" "$TMP/PERSO/demo/tasks/resolved"
  cat > "$TMP/_shared/forge-active" <<EOF
{"session_id":"test-session","project":"demo","started_at":"2026-05-21T13:00:00+0200","tmux_pane":null}
EOF
  export FORGE_CONF_OVERRIDE="$TMP_CONF"
  export CLAUDE_CODE_SESSION_ID="test-session"
}

teardown() {
  rm -rf "$TMP"
  unset FORGE_CONF_OVERRIDE CLAUDE_CODE_SESSION_ID TMP TMP_CONF
}

# Initialize the vault as a git repo with a fake origin. Commits SCAFFOLD.md
# AND a .gitignore that ignores test scaffolding + nested-repo subtree (PRO/)
# so they don't show up as untracked drift — mirrors the real vault setup
# (per reference_vault_git_topology: outer's .gitignore excludes nested PRO).
init_outer_vault() {
  local origin_url="${1:-https://github.com/example/outer-vault.git}"
  git -C "$TMP" init -q 2>/dev/null
  git -C "$TMP" remote add origin "$origin_url" 2>/dev/null
  cat > "$TMP/.gitignore" <<'EOF'
_shared/
PERSO/
PRO/
repos/
forge.conf
EOF
  echo "scaffold" > "$TMP/SCAFFOLD.md"
  git -C "$TMP" -c user.email=t@e -c user.name=t add .gitignore SCAFFOLD.md 2>/dev/null
  git -C "$TMP" -c user.email=t@e -c user.name=t commit -q -m "init" 2>/dev/null
}

# Initialize a nested repo (e.g. PRO/) with its own origin.
init_nested_vault() {
  local sub="$1"
  local origin_url="${2:-git@github.example.io:org/inner-vault.git}"
  mkdir -p "$TMP/$sub"
  git -C "$TMP/$sub" init -q 2>/dev/null
  git -C "$TMP/$sub" remote add origin "$origin_url" 2>/dev/null
  echo "scaffold" > "$TMP/$sub/SCAFFOLD.md"
  git -C "$TMP/$sub" -c user.email=t@e -c user.name=t add SCAFFOLD.md 2>/dev/null
  git -C "$TMP/$sub" -c user.email=t@e -c user.name=t commit -q -m "init" 2>/dev/null
}

# ── Check 1 — outer-only vault: single repo labelled with hostname ──────
echo "Check 1 — outer-only vault, clean state, labelled with host"
setup
init_outer_vault "https://github.com/example/outer-vault.git"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q "Your vault (local history)" \
  && { echo "  ✓ vault state section present"; PASS=$((PASS+1)); } \
  || { echo "  ✗ vault state section missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE '\[vault root → github\.com\]' \
  && { echo "  ✓ outer labelled with [vault root → github.com]"; PASS=$((PASS+1)); } \
  || { echo "  ✗ outer label missing or wrong"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE '\[vault root → github\.com\] Clean' \
  && { echo "  ✓ outer reported clean"; PASS=$((PASS+1)); } \
  || { echo "  ✗ outer not reported clean"; FAIL=$((FAIL+1)); }
teardown

# ── Check 2 — nested repo discovered + labelled separately ──────────────
echo ""
echo "Check 2 — nested repo discovered, both labelled, both audited"
setup
init_outer_vault "https://github.com/example/outer-vault.git"
init_nested_vault "PRO" "git@github.example.io:org/inner-vault.git"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -qE '\[vault root → github\.com\]' \
  && { echo "  ✓ outer labelled"; PASS=$((PASS+1)); } \
  || { echo "  ✗ outer label missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE '\[PRO/ → github\.example\.io\]' \
  && { echo "  ✓ nested labelled with subpath and host"; PASS=$((PASS+1)); } \
  || { echo "  ✗ nested label missing or wrong"; FAIL=$((FAIL+1)); }
teardown

# ── Check 3 — SSH-alias origin parses to alias as the "host" ────────────
echo ""
echo "Check 3 — SSH alias origin (git@alias:owner/repo) renders alias as host"
setup
init_outer_vault "git@my-ssh-alias:owner/outer-vault.git"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -qE '\[vault root → my-ssh-alias\]' \
  && { echo "  ✓ SSH alias parsed as host"; PASS=$((PASS+1)); } \
  || { echo "  ✗ SSH alias not parsed correctly"; FAIL=$((FAIL+1)); }
teardown

# ── Check 4 — no remote configured renders "(no remote)" ───────────────
echo ""
echo "Check 4 — repo without remote labelled (no remote)"
setup
# init_outer_vault but without adding origin
git -C "$TMP" init -q 2>/dev/null
cat > "$TMP/.gitignore" <<'EOF'
_shared/
PERSO/
PRO/
repos/
forge.conf
EOF
echo "scaffold" > "$TMP/SCAFFOLD.md"
git -C "$TMP" -c user.email=t@e -c user.name=t add .gitignore SCAFFOLD.md 2>/dev/null
git -C "$TMP" -c user.email=t@e -c user.name=t commit -q -m "init" 2>/dev/null

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -qE '\[vault root \(no remote\)\]' \
  && { echo "  ✓ no-remote label rendered"; PASS=$((PASS+1)); } \
  || { echo "  ✗ no-remote label missing"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE '\[vault root \(no remote\)\] Clean\. \(No remote' \
  && { echo "  ✓ clean-no-remote status text"; PASS=$((PASS+1)); } \
  || { echo "  ✗ clean-no-remote status text missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 5 — nested repo drift fires the multi-repo nudge ──────────────
echo ""
echo "Check 5 — nested repo drift fires the multi-repo nudge"
setup
init_outer_vault "https://github.com/example/outer-vault.git"
init_nested_vault "PRO" "git@github.example.io:org/inner-vault.git"
# Plant 11 dirty files in PRO (above VAULT_DRIFT_DIRTY_FILES=10) — outer stays clean.
for i in $(seq 1 11); do
  echo "dirt $i" > "$TMP/PRO/dirt$i.txt"
done

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -qE '\[vault root → github\.com\] Clean' \
  && { echo "  ✓ outer still reported clean"; PASS=$((PASS+1)); } \
  || { echo "  ✗ outer wrongly flagged"; FAIL=$((FAIL+1)); }
echo "$out" | grep -qE '\[PRO/ → github\.example\.io\] Dirty: 11' \
  && { echo "  ✓ nested PRO drift counted"; PASS=$((PASS+1)); } \
  || { echo "  ✗ nested PRO drift not counted correctly"; FAIL=$((FAIL+1)); }
echo "$out" | grep -q '\[!\] Your vault has drift' \
  && { echo "  ✓ multi-repo drift nudge fired"; PASS=$((PASS+1)); } \
  || { echo "  ✗ multi-repo drift nudge missing"; FAIL=$((FAIL+1)); }
teardown

# ── Check 6 — clean outer alone does NOT fire drift nudge ───────────────
echo ""
echo "Check 6 — clean state across all repos suppresses drift nudge"
setup
init_outer_vault "https://github.com/example/outer-vault.git"
init_nested_vault "PRO" "git@github.example.io:org/inner-vault.git"

out=$("$FORGE_CONTEXT" recover 2>&1)
echo "$out" | grep -q '\[!\] Your vault has drift' \
  && { echo "  ✗ drift nudge wrongly fired on clean state"; FAIL=$((FAIL+1)); } \
  || { echo "  ✓ no drift nudge on clean state"; PASS=$((PASS+1)); }
teardown

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
