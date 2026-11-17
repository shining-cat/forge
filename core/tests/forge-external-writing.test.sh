#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Instruction distribution only, not runtime filtering or live compliance.
require() {
  if ! grep -Fq -- "$2" "$ROOT/$1"; then
    printf 'FAIL: %s is missing external-writing safeguard: %s\n' "$1" "$2" >&2
    exit 1
  fi
}

reject() {
  if grep -Fq -- "$2" "$ROOT/$1"; then
    printf 'FAIL: %s retains conflicting writing guidance: %s\n' "$1" "$2" >&2
    exit 1
  fi
}

policy=core/references/lifecycle.md
for text in '## External writing' 'Jira tickets' 'PR titles and descriptions' \
  'Confluence pages' 'comments' 'Why/What' 'Jira accessible; PR technical' \
  'self-contained' 'Related issue keys and PR URLs' 'never replace essential context' \
  'private vault' 'paths, note links, backlinks' 'Do not paste private notes' \
  'Normal repository paths' 'omitted-work inventories' 'partial-ticket scope explicit' \
  'material limitations' 'Before handoff or publication' \
  'not permission to publish'; do
  require "$policy" "$text"
done

for role in keeper release architect; do
  require "core/roles/$role.md" '**External writing.** Before drafting or editing'
  require "core/roles/$role.md" 'read and apply'
  require "core/roles/$role.md" 'core/references/lifecycle.md#external-writing'
done
reject core/roles/release.md 'body that summarizes the change and includes a test plan'

for adapter in copilot-cli claude-code; do
  suffix=md
  installed='~/.claude/skills/forge/references/lifecycle.md'
  if [[ "$adapter" == copilot-cli ]]; then
    suffix=agent.md
    installed='${COPILOT_HOME:-$HOME/.copilot}/skills/forge/references/lifecycle.md'
  fi
  for role in keeper release architect; do
    file="adapters/$adapter/agents/forge-$role.$suffix"
    require "$file" '**External writing.** Before drafting or editing'
    require "$file" 'read and apply'
    require "$file" "$installed"
  done
  reject "adapters/$adapter/agents/forge-release.$suffix" \
    'Body includes a Summary section and a Test Plan section.'
  require "adapters/$adapter/skills/forge/SKILL.md" '**External writing:** Before drafting or editing'
  require "adapters/$adapter/skills/forge/SKILL.md" 'read and apply the External writing section in `references/lifecycle.md`'
  printf 'PASS: %s external-writing entry points\n' "$adapter"
done

require adapters/copilot-cli/install.sh '  lifecycle shared-templates; do'
require adapters/copilot-cli/install.sh 'copy_owned "$FORGE_ROOT/core/references/$ref.md" "$COPILOT_DIR/skills/forge/references/$ref.md"'
claude_install="$ROOT/adapters/claude-code/install.sh"
if [[ "$(grep -cE '^[[:space:]]*for ref in lifecycle[.]md ' "$claude_install")" -ne 2 ]]; then
  printf 'FAIL: lifecycle must remain in both Claude installer mapping lists\n' >&2
  exit 1
fi
require adapters/claude-code/install.sh '"$FORGE_ROOT/core/references/$ref" "$SKILLS_DIR/forge/references/$ref"'
require adapters/claude-code/install.sh 'install_symlink "$FORGE_ROOT/core/references/$ref" "$SKILLS_DIR/forge/references/$ref" preserve'
require docs/ROLES.md 'lifecycle.md#external-writing'
require docs/ROLES.md 'not runtime filtering or proof of live compliance'
require docs/ARCHITECTURE.md 'lifecycle.md#external-writing'
printf 'PASS: shared writing policy, installer mappings, and documentation\n'
