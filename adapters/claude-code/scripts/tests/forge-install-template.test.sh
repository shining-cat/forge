#!/usr/bin/env bash
# Hermetic packaging regression for both adapters: dry-run only, never install.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "  ✓ $name"; PASS=$((PASS+1))
  else
    echo "  ✗ $name"; FAIL=$((FAIL+1))
  fi
}

for runtime in claude-code copilot-cli; do
  adapter="$FORGE_ROOT/adapters/$runtime"
  home="$T/$runtime"
  if [ "$runtime" = claude-code ]; then
    tooling="$home/.claude"
  else
    tooling="$home/custom-copilot"
  fi
  mkdir -p "$tooling"
  cp "$SCRIPT_DIR/fixtures/check2-good.json" "$tooling/settings.json"
  cp "$SCRIPT_DIR/fixtures/check2-good.json" "$tooling/permissions-config.json"
  before="$(find "$home" -print | sort)"
  out="$(HOME="$home" COPILOT_HOME="$tooling" bash "$adapter/install.sh" \
    --vault-path "$home/vault" --dry-run 2>&1)"
  rc=$?
  check "$runtime: dry-run succeeds" test "$rc" -eq 0
  check "$runtime: script copy planned" grep -qF \
    "$adapter/scripts/forge-template.sh" <<< "$out"
  check "$runtime: runtime script destination" grep -qF \
    "$tooling/scripts/forge-template.sh" <<< "$out"
  check "$runtime: skeleton source packaged" grep -qF \
    "$FORGE_ROOT/core/vault-templates/shared-template.md" <<< "$out"
  check "$runtime: skeleton destination in tooling" grep -qF \
    "$tooling/skills/forge/templates/shared-template.md" <<< "$out"
  check "$runtime: executable source" test -x "$adapter/scripts/forge-template.sh"
  check "$runtime: dry-run creates no files or vault" test \
    "$before" = "$(find "$home" -print | sort)"
  check "$runtime: settings unchanged" cmp -s \
    "$SCRIPT_DIR/fixtures/check2-good.json" "$tooling/settings.json"
  check "$runtime: saved approvals unchanged" cmp -s \
    "$SCRIPT_DIR/fixtures/check2-good.json" "$tooling/permissions-config.json"
  if [ "$runtime" = claude-code ]; then
    # --dry-run reports permission counts; --preview lists the exact patterns.
    preview="$(HOME="$home" bash "$adapter/install.sh" --preview 2>&1)"
    rc=$?
    check "Claude: preview reports pending changes" test "$rc" -eq 1
    for pattern in "Bash($home/.claude/scripts/forge-template.sh:*)" \
      "Bash($home/.claude/scripts/forge-template.sh *)" \
      "Bash(~/.claude/scripts/forge-template.sh *)"; do
      check "Claude: permission planned: $pattern" grep -qF "$pattern" <<< "$preview"
    done
    for pattern in 'Bash($HOME/.claude/scripts/forge-template.sh:*)' \
      'Bash($HOME/.claude/scripts/forge-template.sh *)' \
      'Bash(~/.claude/scripts/forge-template.sh *)'; do
      check "Claude: permission in preview and apply: $pattern" test \
        "$(grep -Fc "\"$pattern\"" "$adapter/install.sh")" -eq 2
    done
    check "Claude: manifest includes script" grep -qF \
      '"$ADAPTER/scripts/forge-template.sh" "$CLAUDE_DIR/scripts/forge-template.sh"' "$adapter/install.sh"
    check "Claude: manifest includes skeleton" grep -qF \
      '"$FORGE_ROOT/core/vault-templates/shared-template.md" "$SKILLS_DIR/forge/templates/shared-template.md"' "$adapter/install.sh"
    check "Claude: chmod includes script" grep -qF \
      '"$CLAUDE_DIR/scripts/forge-template.sh" \' "$adapter/install.sh"
  else
    check "Copilot: generic executable installation planned" grep -qF \
      'chmod +x' <<< "$out"
  fi
done

echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
