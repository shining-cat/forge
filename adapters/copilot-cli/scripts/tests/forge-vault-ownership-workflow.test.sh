#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
for adapter in copilot-cli claude-code; do
  skills="$ROOT/adapters/$adapter/skills"
  agent="$ROOT/adapters/$adapter/agents"
  if [[ "$adapter" == copilot-cli ]]; then
    agent="$agent/forge-keeper.agent.md"
    refiner="$ROOT/adapters/$adapter/agents/forge-refiner.agent.md"
    architect="$ROOT/adapters/$adapter/agents/forge-architect.agent.md"
  else
    agent="$agent/forge-keeper.md"
    refiner="$ROOT/adapters/$adapter/agents/forge-refiner.md"
    architect="$ROOT/adapters/$adapter/agents/forge-architect.md"
  fi

  grep -Fq 'Keeper executes every authored vault mutation' "$skills/forge/SKILL.md"
  grep -Fq 'This includes typed `forge-context.sh`' "$skills/keeper/SKILL.md"
  grep -Fq 'Verify the result and report a denied or failed write' "$agent"
  grep -Fq 'After Keeper writes and reads back the checkpoint' "$skills/forge-checkpoint/SKILL.md"
  grep -Fq 'preserve the braindump and report the failure' "$skills/forge-checkpoint/SKILL.md"
  grep -Fq 'if Keeper is unavailable, report/defer' "$skills/refiner/SKILL.md"
  grep -Fq 'If Keeper cannot complete it, report the failure' "$skills/forge-exit/SKILL.md"
  grep -Fq 'Keeper executes and verifies all authored vault mutations' "$skills/forge-weekly/SKILL.md"
  grep -Fq 'If any required write failed or was deferred, do not mark the wrap done' "$skills/forge-weekly/SKILL.md"
  grep -Fq 'have Keeper delete the authored vault review doc' "$skills/promote-from-review/SKILL.md"
  grep -Fq 'Dispatch Keeper synchronously with the classified event' "$refiner"
  grep -Fq 'have Keeper record and verify the resolution' "$refiner"
  grep -Fq 'Dispatch Keeper synchronously to write and verify the plan' "$architect"
  printf '  ✓ %s authored-write dispatch and failure contracts\n' "$adapter"
done

jq -e '[.hooks.PreToolUse[] | select(.bash | contains("forge-vault-write-guard.sh"))] | length == 0' \
  "$ROOT/adapters/copilot-cli/hooks/forge.json" > /dev/null
jq -e '[.hooks.PreToolUse[] | select(.bash | contains("forge-vault-plan-guard.sh"))] | length == 1' \
  "$ROOT/adapters/copilot-cli/hooks/forge.json" > /dev/null
printf '  ✓ Copilot retains plan protection without unsupported identity gate\n'
