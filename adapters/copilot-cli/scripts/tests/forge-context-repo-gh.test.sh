#!/usr/bin/env bash
# Test runner for forge-context.sh repo-gh subcommand.
# Pure bash, no test framework dependency.
#
# Strategy: stub `gh` on PATH that records GH_HOST + args + cwd to a file;
# stub HOME to a temp dir (so zsh -ic doesn't source the user's .zshrc and
# shadow the gh stub with the per-cwd-routing function); set up fake git
# repos with different origin URL shapes; invoke repo-gh; assert that gh
# was called with the expected GH_HOST and that --jq filtering / error
# paths behave correctly.
#
# Covers:
#   1. --help → exit 0 with usage
#   2. No args → exit 2 with FAIL message
#   3. --repo override + GH_HOST detection from git@host: origin
#   4. GH_HOST detection from https://host/ origin
#   5. GH_HOST detection from ssh://git@host/ origin
#   6. GH_HOST parse failure (file:// origin) → exit 2
#   7. --jq filter pipes gh stdout through jq
#   8. Non-git --repo path → exit 2
#   9. No origin remote → exit 2
#  10. Active project fallback (marker + get_project_dir → repo)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"

PASS=0
FAIL=0

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  # `-e` disambiguates needles that begin with `--` (e.g. `--repo`) so old
  # BSD grep doesn't treat them as flags.
  if echo "$haystack" | grep -qF -e "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — output didn't contain: $needle"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL+1))
  fi
}

# Build a minimal forge.conf pointing at a temp vault. The vault gets a
# valid marker JSON so the active-project fallback test can exercise the
# get_project_dir lookup path.
mk_conf() {
  local vault; vault=$(mktemp -d)
  mkdir -p "$vault/_shared"
  # REPO_ROOTS is unused for explicit-repo tests but required by
  # get_project_dir; point at a temp dir so default lookups don't escape
  # to the developer's real repo roots.
  local repo_roots; repo_roots=$(mktemp -d)
  local conf; conf=$(mktemp)
  cat >"$conf" <<EOF
VAULT_PATH=$vault
FORGE_REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
REPO_ROOTS=$repo_roots
EOF
  # Return vault|conf|repo_roots so caller can plant project dirs.
  echo "$vault|$conf|$repo_roots"
}

# Build a git repo at $1 with origin URL $2. Empty commit so HEAD exists.
mk_repo() {
  local path="$1" origin_url="$2"
  mkdir -p "$path"
  git -C "$path" init -q 2>/dev/null
  git -C "$path" remote add origin "$origin_url" 2>/dev/null
  git -C "$path" -c user.email=t@e -c user.name=t commit --allow-empty -q -m init 2>/dev/null
}

# Stub gh that records GH_HOST + args + cwd to $1, then prints $2 to stdout.
# Returns exit code from $3 (default 0).
mk_gh_stub() {
  local record_file="$1" stdout_payload="${2:-}" exit_code="${3:-0}"
  local bindir; bindir=$(mktemp -d)
  cat >"$bindir/gh" <<EOF
#!/usr/bin/env bash
{
  echo "GH_HOST=\${GH_HOST:-<unset>}"
  echo "PWD=\$PWD"
  printf 'ARG: %s\n' "\$@"
} > "$record_file"
printf '%s' '$stdout_payload'
exit $exit_code
EOF
  chmod +x "$bindir/gh"
  echo "$bindir"
}

# Build a sandbox PATH (basic utilities only, no user-provided binaries).
# Caller prepends additional bin dirs (e.g. the gh stub).
mk_sandbox_path() {
  local sand; sand=$(mktemp -d)
  # Include `locale` because /etc/zshrc on macOS invokes it on shell startup;
  # without it, zsh -ic spams "command not found: locale" to stderr and our
  # 2>&1-capturing assertions pick up the noise.
  for cmd in bash sh awk sed grep cat head tail jq git basename dirname find sort uniq wc tr cut env mktemp date stat readlink rm touch ls chmod printf python3 cmp tee zsh locale; do
    [ -e "/bin/$cmd" ] && ln -sf "/bin/$cmd" "$sand/$cmd" 2>/dev/null
    [ -e "/usr/bin/$cmd" ] && ln -sf "/usr/bin/$cmd" "$sand/$cmd" 2>/dev/null
    [ -e "/opt/homebrew/bin/$cmd" ] && ln -sf "/opt/homebrew/bin/$cmd" "$sand/$cmd" 2>/dev/null
  done
  echo "$sand"
}

# Empty HOME so zsh -ic doesn't source the user's .zshrc and shadow gh.
mk_clean_home() {
  mktemp -d
}

echo "=== forge-context repo-gh ==="

# ── 1 — --help ─────────────────────────────────────────────────────────
echo ""
echo "Check 1 — --help prints usage and exits 0"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
out=$(FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" repo-gh --help 2>&1); ec=$?
assert_eq "--help exit code is 0" "0" "$ec"
assert_contains "--help mentions usage" "Usage:" "$out"
assert_contains "--help mentions --repo" "--repo" "$out"
assert_contains "--help mentions --jq" "--jq" "$out"
rm -rf "$VAULT" "$REPO_ROOTS"; rm -f "$CONF"

# ── 2 — no args → exit 2 ──────────────────────────────────────────────
echo ""
echo "Check 2 — missing gh args → FAIL with exit 2"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d); mk_repo "$REPO" "git@github.com:o/r.git"
out=$(FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" repo-gh --repo "$REPO" 2>&1); ec=$?
assert_eq "missing-args exit code is 2" "2" "$ec"
assert_contains "missing-args FAIL message" "no gh arguments" "$out"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO"; rm -f "$CONF"

# ── 3 — --repo override + git@host: origin → correct GH_HOST ──────────
echo ""
echo "Check 3 — git@host: origin → GH_HOST=host, gh called with right args"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d)
mk_repo "$REPO" "git@github.example.com:owner/repo.git"
REC=$(mktemp)
BINDIR=$(mk_gh_stub "$REC" "pr-view-output")
SAND=$(mk_sandbox_path)
HOME_DIR=$(mk_clean_home)
out=$(FORGE_CONF_OVERRIDE="$CONF" PATH="$BINDIR:$SAND" HOME="$HOME_DIR" \
      "$SCRIPT" repo-gh --repo "$REPO" pr view 12345 --json title 2>&1); ec=$?
assert_eq "happy-path exit code is 0" "0" "$ec"
assert_eq "stdout is gh's stdout" "pr-view-output" "$out"
assert_contains "GH_HOST recorded as github.example.com" "GH_HOST=github.example.com" "$(cat "$REC")"
assert_contains "cwd was the repo dir" "PWD=$REPO" "$(cat "$REC")"
assert_contains "gh args passed through (pr)" "ARG: pr" "$(cat "$REC")"
assert_contains "gh args passed through (view)" "ARG: view" "$(cat "$REC")"
assert_contains "gh args passed through (12345)" "ARG: 12345" "$(cat "$REC")"
assert_contains "gh args passed through (--json)" "ARG: --json" "$(cat "$REC")"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO" "$BINDIR" "$SAND" "$HOME_DIR"; rm -f "$CONF" "$REC"

# ── 4 — https://host/ origin → correct GH_HOST ────────────────────────
echo ""
echo "Check 4 — https://host/ origin → GH_HOST=host"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d)
mk_repo "$REPO" "https://github.example.com/owner/repo"
REC=$(mktemp); BINDIR=$(mk_gh_stub "$REC")
SAND=$(mk_sandbox_path); HOME_DIR=$(mk_clean_home)
FORGE_CONF_OVERRIDE="$CONF" PATH="$BINDIR:$SAND" HOME="$HOME_DIR" \
  "$SCRIPT" repo-gh --repo "$REPO" auth status >/dev/null 2>&1
assert_contains "GH_HOST from https URL" "GH_HOST=github.example.com" "$(cat "$REC")"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO" "$BINDIR" "$SAND" "$HOME_DIR"; rm -f "$CONF" "$REC"

# ── 5 — ssh://git@host/ origin → correct GH_HOST ──────────────────────
echo ""
echo "Check 5 — ssh://git@host/ origin → GH_HOST=host"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d)
mk_repo "$REPO" "ssh://git@github.example.com/owner/repo"
REC=$(mktemp); BINDIR=$(mk_gh_stub "$REC")
SAND=$(mk_sandbox_path); HOME_DIR=$(mk_clean_home)
FORGE_CONF_OVERRIDE="$CONF" PATH="$BINDIR:$SAND" HOME="$HOME_DIR" \
  "$SCRIPT" repo-gh --repo "$REPO" auth status >/dev/null 2>&1
assert_contains "GH_HOST from ssh:// URL" "GH_HOST=github.example.com" "$(cat "$REC")"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO" "$BINDIR" "$SAND" "$HOME_DIR"; rm -f "$CONF" "$REC"

# ── 6 — file:// origin → FAIL with parse error ────────────────────────
echo ""
echo "Check 6 — file:// origin → cannot parse host, exit 2"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d); OTHER=$(mktemp -d)
mk_repo "$REPO" "file://$OTHER"
out=$(FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" repo-gh --repo "$REPO" auth status 2>&1); ec=$?
assert_eq "unparseable-origin exit code is 2" "2" "$ec"
assert_contains "unparseable-origin FAIL message" "cannot parse host" "$out"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO" "$OTHER"; rm -f "$CONF"

# ── 7 — --jq filter pipes stdout through jq ───────────────────────────
echo ""
echo "Check 7 — --jq filter applied to gh stdout"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d)
mk_repo "$REPO" "git@github.com:o/r.git"
REC=$(mktemp)
# gh stub emits a JSON object; --jq picks out the title field.
BINDIR=$(mk_gh_stub "$REC" '{"title":"hello","state":"OPEN"}')
SAND=$(mk_sandbox_path); HOME_DIR=$(mk_clean_home)
out=$(FORGE_CONF_OVERRIDE="$CONF" PATH="$BINDIR:$SAND" HOME="$HOME_DIR" \
      "$SCRIPT" repo-gh --repo "$REPO" --jq '.title' pr view 1 --json title,state 2>&1); ec=$?
assert_eq "jq-filtered exit code is 0" "0" "$ec"
# jq output for `.title` of {"title":"hello",...} is the string "hello"
assert_eq "jq filter applied" '"hello"' "$out"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO" "$BINDIR" "$SAND" "$HOME_DIR"; rm -f "$CONF" "$REC"

# ── 8 — non-git --repo path → exit 2 ──────────────────────────────────
echo ""
echo "Check 8 — non-git --repo → FAIL with exit 2"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
PLAIN=$(mktemp -d)
out=$(FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" repo-gh --repo "$PLAIN" pr list 2>&1); ec=$?
assert_eq "non-git exit code is 2" "2" "$ec"
assert_contains "non-git FAIL message" "not a git repository" "$out"
rm -rf "$VAULT" "$REPO_ROOTS" "$PLAIN"; rm -f "$CONF"

# ── 9 — no origin remote → exit 2 ─────────────────────────────────────
echo ""
echo "Check 9 — repo with no origin remote → FAIL with exit 2"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
REPO=$(mktemp -d)
mkdir -p "$REPO"; git -C "$REPO" init -q 2>/dev/null
# Deliberately no `git remote add origin`
out=$(FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" repo-gh --repo "$REPO" pr list 2>&1); ec=$?
assert_eq "no-origin exit code is 2" "2" "$ec"
assert_contains "no-origin FAIL message" "no origin remote" "$out"
rm -rf "$VAULT" "$REPO_ROOTS" "$REPO"; rm -f "$CONF"

# ── 10 — Active project fallback: marker → get_project_dir → repo ────
echo ""
echo "Check 10 — active project marker auto-resolves --repo"
IFS='|' read -r VAULT CONF REPO_ROOTS <<< "$(mk_conf)"
# Plant a project under REPO_ROOTS at depth 1 (flat layout): ROOT/myproj/
REPO="$REPO_ROOTS/myproj"
mk_repo "$REPO" "git@github.com:o/myproj.git"
# Write JSON marker that points at myproj.
cat > "$VAULT/_shared/forge-active" <<EOF
{"session_id":"test","project":"myproj","started_at":"2026-06-18T00:00:00+0000","tmux_pane":null}
EOF
REC=$(mktemp); BINDIR=$(mk_gh_stub "$REC")
SAND=$(mk_sandbox_path); HOME_DIR=$(mk_clean_home)
# No --repo given → script must resolve via marker + get_project_dir
out=$(FORGE_CONF_OVERRIDE="$CONF" PATH="$BINDIR:$SAND" HOME="$HOME_DIR" \
      "$SCRIPT" repo-gh auth status 2>&1); ec=$?
assert_eq "active-project resolution exit code is 0" "0" "$ec"
assert_contains "cwd was the auto-resolved repo" "PWD=$REPO" "$(cat "$REC")"
assert_contains "GH_HOST recorded" "GH_HOST=github.com" "$(cat "$REC")"
rm -rf "$VAULT" "$REPO_ROOTS" "$BINDIR" "$SAND" "$HOME_DIR"; rm -f "$CONF" "$REC"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
