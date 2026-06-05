#!/usr/bin/env bash
# Test runner for forge-context.sh review-sync subcommand.
# Pure bash, no test framework dependency.
#
# Strategy: stub `gh` on PATH with canned responses, plant fake review docs
# under a temp vault, set forge-active marker for an active-mode test, then
# invoke review-sync and assert the rows match the expected format.
#
# Five cases:
#   1. Active mode, 2 merged + 1 open PR refs → 2 ~-prefixed rows
#   2. --backfill mode, 2 projects with reviews → both surface
#   3. No review docs → silent (exit 0, no output)
#   4. `gh` missing → silent (graceful)
#   5. Filename-only PR ref extraction (filename contains pr-NNN, body doesn't)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"

PASS=0
FAIL=0

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — output didn't contain: $needle"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✗ $name — output contained '$needle' but shouldn't"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  else
    echo "  ✓ $name"
    PASS=$((PASS+1))
  fi
}

assert_empty() {
  local name="$1" actual="$2"
  if [ -z "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected empty, got: $actual"
    FAIL=$((FAIL+1))
  fi
}

# Build a sandbox vault with the active project's reviews dir + a fake git
# repo (review-sync requires one to resolve a remote URL). $1=project name,
# $2... = review doc names to plant.
mk_vault_with_reviews() {
  local project="$1"; shift
  local vault; vault=$(mktemp -d)
  mkdir -p "$vault/_shared"

  # Active project structure
  local proj_path="$vault/PERSO/$project"
  mkdir -p "$proj_path/tasks/reviews"

  # Fake repo (review-sync needs origin remote to resolve host+repo)
  local repos="$vault/repos/$project"
  mkdir -p "$repos"
  git -C "$repos" init -q 2>/dev/null
  git -C "$repos" remote add origin "git@github.com:fake-org/$project.git"
  git -C "$repos" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null

  # Plant review docs
  local doc
  for doc in "$@"; do
    cat > "$proj_path/tasks/reviews/$doc" <<EOF
# Review for some PR

Body content referencing #12345 or other things.
EOF
  done

  # Marker (active mode test)
  cat > "$vault/_shared/forge-active" <<EOF
{"session_id":"test","project":"$project","started_at":"2026-06-05T12:00:00+0200","tmux_pane":null}
EOF

  # conf override
  local conf; conf=$(mktemp)
  cat > "$conf" <<EOF
VAULT_PATH=$vault
REPO_ROOTS=$vault/repos
EOF
  echo "$vault|$conf"
}

# Build a fake `gh` binary on PATH that returns canned state per PR number.
# Arg: GH_FIXTURE_FILE — path to a tab-separated map "pr-num<TAB>state<TAB>title"
# Args after that are passed to the stub via env GH_FIXTURE_FILE.
mk_gh_stub() {
  local fixture="$1"
  local bindir; bindir=$(mktemp -d)
  cat > "$bindir/gh" <<EOF
#!/bin/bash
# Stub gh: parse \`gh pr view <num> --repo X --json state,title\`,
# look up canned state from \$GH_FIXTURE_FILE.
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  PR_NUM="\$3"
  FIXTURE="$fixture"
  if [ -f "\$FIXTURE" ]; then
    while IFS=\$'\t' read -r num state title; do
      if [ "\$num" = "\$PR_NUM" ]; then
        printf '{"state":"%s","title":"%s"}\n' "\$state" "\$title"
        exit 0
      fi
    done < "\$FIXTURE"
  fi
  # No fixture entry → simulate gh failure (silent)
  exit 1
fi
echo "stub-gh: unsupported call: \$*" >&2
exit 1
EOF
  chmod +x "$bindir/gh"
  echo "$bindir"
}

echo "=== forge-context review-sync ==="

# ── 1 — Active mode, 2 merged + 1 open PR refs ─────────────────────────
echo ""
echo "Check 1 — active mode: surfaces only merged/closed PRs"
IFS='|' read -r VAULT CONF <<< "$(mk_vault_with_reviews demo \
  '2026-06-01-pr-100-review.md' \
  '2026-06-02-pr-200-review.md' \
  '2026-06-03-pr-300-review.md')"
FIXTURE=$(mktemp)
{
  printf '100\tMERGED\tFirst merged thing\n'
  printf '200\tMERGED\tSecond merged thing\n'
  printf '300\tOPEN\tStill in review\n'
} > "$FIXTURE"
BINDIR=$(mk_gh_stub "$FIXTURE")
out=$(FORGE_CONF_OVERRIDE="$CONF" CLAUDE_CODE_SESSION_ID="test" \
      PATH="$BINDIR:$PATH" "$SCRIPT" review-sync 2>&1)
assert_contains "#100 surfaces (MERGED)"     "~ #100"      "$out"
assert_contains "#200 surfaces (MERGED)"     "~ #200"      "$out"
assert_not_contains "#300 suppressed (OPEN)" "~ #300"      "$out"
assert_contains "cleanup queued cue"         "cleanup queued" "$out"
rm -rf "$VAULT" "$BINDIR"; rm -f "$CONF" "$FIXTURE"

# ── 2 — --backfill mode, multiple projects ─────────────────────────────
echo ""
echo "Check 2 — --backfill mode: surfaces across projects"
IFS='|' read -r VAULT CONF <<< "$(mk_vault_with_reviews demoA '2026-06-01-pr-111-review.md')"
# Add a second project
mkdir -p "$VAULT/PERSO/demoB/tasks/reviews"
cat > "$VAULT/PERSO/demoB/tasks/reviews/2026-06-02-pr-222-review.md" <<EOF
# Review for #222
body content
EOF
mkdir -p "$VAULT/repos/demoB"
git -C "$VAULT/repos/demoB" init -q 2>/dev/null
git -C "$VAULT/repos/demoB" remote add origin "git@github.com:fake-org/demoB.git"
git -C "$VAULT/repos/demoB" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null

FIXTURE=$(mktemp)
{
  printf '111\tMERGED\tAlpha\n'
  printf '222\tMERGED\tBeta\n'
} > "$FIXTURE"
BINDIR=$(mk_gh_stub "$FIXTURE")
out=$(FORGE_CONF_OVERRIDE="$CONF" PATH="$BINDIR:$PATH" \
      "$SCRIPT" review-sync --backfill 2>&1)
assert_contains "demoA PR surfaces" "~ #111" "$out"
assert_contains "demoB PR surfaces" "~ #222" "$out"
rm -rf "$VAULT" "$BINDIR"; rm -f "$CONF" "$FIXTURE"

# ── 3 — No review docs → silent ────────────────────────────────────────
echo ""
echo "Check 3 — no review docs → silent"
IFS='|' read -r VAULT CONF <<< "$(mk_vault_with_reviews emptyproj)"
# (no docs planted; tasks/reviews exists but is empty)
FIXTURE=$(mktemp); : > "$FIXTURE"
BINDIR=$(mk_gh_stub "$FIXTURE")
out=$(FORGE_CONF_OVERRIDE="$CONF" CLAUDE_CODE_SESSION_ID="test" \
      PATH="$BINDIR:$PATH" "$SCRIPT" review-sync 2>&1)
assert_empty "no output when reviews dir empty" "$out"
rm -rf "$VAULT" "$BINDIR"; rm -f "$CONF" "$FIXTURE"

# ── 4 — `gh` missing → silent (graceful) ───────────────────────────────
echo ""
echo "Check 4 — gh missing → silent"
IFS='|' read -r VAULT CONF <<< "$(mk_vault_with_reviews demo '2026-06-01-pr-100-review.md')"
# Sandbox PATH without gh — give it only basics
SANDBOX=$(mktemp -d)
for cmd in bash sh awk sed grep cat head jq git basename dirname find sort uniq wc tr cut env mktemp date stat readlink rm touch ls chmod printf python3 cmp tail; do
  [ -e "/bin/$cmd" ] && ln -sf "/bin/$cmd" "$SANDBOX/$cmd" 2>/dev/null
  [ -e "/usr/bin/$cmd" ] && ln -sf "/usr/bin/$cmd" "$SANDBOX/$cmd" 2>/dev/null
done
out=$(FORGE_CONF_OVERRIDE="$CONF" CLAUDE_CODE_SESSION_ID="test" \
      PATH="$SANDBOX" "$SCRIPT" review-sync 2>&1)
assert_empty "no output when gh missing" "$out"
rm -rf "$VAULT" "$SANDBOX"; rm -f "$CONF"

# ── 5 — Filename-only PR extraction ────────────────────────────────────
echo ""
echo "Check 5 — extracts PR num from filename even when body doesn't mention it"
IFS='|' read -r VAULT CONF <<< "$(mk_vault_with_reviews demo '2026-06-01-pr-555-followup.md')"
# Overwrite body to NOT mention #555 anywhere
cat > "$VAULT/PERSO/demo/tasks/reviews/2026-06-01-pr-555-followup.md" <<'EOF'
# Some review

Body content with no PR ref.
EOF
FIXTURE=$(mktemp)
printf '555\tMERGED\tFilename-only extraction\n' > "$FIXTURE"
BINDIR=$(mk_gh_stub "$FIXTURE")
out=$(FORGE_CONF_OVERRIDE="$CONF" CLAUDE_CODE_SESSION_ID="test" \
      PATH="$BINDIR:$PATH" "$SCRIPT" review-sync 2>&1)
assert_contains "#555 extracted from filename" "~ #555" "$out"
rm -rf "$VAULT" "$BINDIR"; rm -f "$CONF" "$FIXTURE"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
