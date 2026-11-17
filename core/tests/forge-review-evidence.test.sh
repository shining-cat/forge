#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Instruction contracts only: this does not prove live agent compliance.
require() {
  if ! grep -Fq -- "$2" "$ROOT/$1"; then
    printf 'FAIL: %s is missing review safeguard: %s\n' "$1" "$2" >&2
    exit 1
  fi
}

reject() {
  if grep -Fq -- "$2" "$ROOT/$1"; then
    printf 'FAIL: %s retains conflicting review guidance: %s\n' "$1" "$2" >&2
    exit 1
  fi
}

unreviewed='Review status: not reviewed (Petra to dispatch Reviewer)'
require core/roles/architect.md 'Do not review your own plan or originate a Reviewer verdict.'
require core/roles/architect.md "$unreviewed"
require core/roles/impl.md 'Require Petra-verified plan review evidence matching the plan revision'
require core/roles/impl.md 'If only the vault log is missing'
require core/roles/impl.md 'Missing, stale, or mismatched evidence blocks implementation'
require core/roles/impl.md 'Plan approval is not code approval.'
require core/roles/impl.md "$unreviewed"
require core/roles/reviewer.md 'Only Reviewer issues review verdicts'
require core/roles/reviewer.md 'stage (plan/code), artifact, and revision/scope actually inspected'
require core/roles/reviewer.md 'A model-authored identifier is not proof of provenance.'

for adapter in copilot-cli claude-code; do
  base="adapters/$adapter"
  suffix=md
  [[ "$adapter" != copilot-cli ]] || suffix=agent.md
  architect="$base/agents/forge-architect.$suffix"
  impl="$base/agents/forge-impl.$suffix"
  reviewer="$base/agents/forge-reviewer.$suffix"
  dispatch="$base/references/subagent-models.md"
  forge="$base/skills/forge/SKILL.md"

  require "$architect" 'return its path and revision to Petra for a separate Reviewer dispatch'
  require "$architect" 'Do not review your own plan or originate a Reviewer verdict.'
  require "$architect" "$unreviewed"
  reject "$architect" 'they see only the final PASS'
  require "$impl" 'Require Petra-verified plan review evidence matching the plan revision'
  require "$impl" 'If only the vault log is missing'
  require "$impl" 'Missing, stale, or mismatched evidence blocks implementation'
  require "$impl" 'Plan approval is not code approval.'
  require "$impl" "$unreviewed"
  reject "$impl" 'the referenced plan does not have a PASS verdict'
  require "$reviewer" 'stage (plan/code), artifact, and revision/scope actually inspected'
  require "$reviewer" 'report the gap without issuing PASS'
  require "$reviewer" 'A model-authored identifier is not proof of provenance.'
  require "$reviewer" '**Verdict:** PASS / FAIL / ESCALATE'
  require "$forge" 'Only Reviewer issues review verdicts'
  require "$forge" 'flag unsupported claims and keep the affected gate closed'
  require "$forge" 'evidence protocol in `references/subagent-models.md`'
  require "$dispatch" 'This applies to every role, including Release and Keeper'
  require "$dispatch" 'wait for completion'
  require "$dispatch" 'Preserve FAIL/ESCALATE; absent or failed reviews are unreviewed.'
  require "$dispatch" 'Cross-check the result against the actual Reviewer dispatch metadata'
  require "$dispatch" 'missing, stale, or mismatched evidence cannot open the gate'
  require "$dispatch" 'unrelated edits outside the reviewed scope do not invalidate it'
  require "$dispatch" 'Plan approval is not code approval.'
  require "$dispatch" 'Flag unsupported Reviewer/PASS claims from non-reviewer outputs'
  require "$dispatch" 'Keeper must not upgrade a producer claim into a review.'
  require "$dispatch" 'A missing vault log alone is not a missing review'
  require "$dispatch" 'Report persistence failures without fabricating a result'
  require "$dispatch" 'follow the existing Refiner/maintainer-mode friction policy'
  require "$dispatch" 'there is no runtime hook validating review-result provenance'
  printf 'PASS: %s review-evidence instruction contracts\n' "$adapter"
done

require docs/ROLES.md 'Only Reviewer issues review verdicts'
require docs/ROLES.md 'not runtime enforcement or proof of live compliance'
printf 'PASS: core review-evidence contracts and documentation\n'
