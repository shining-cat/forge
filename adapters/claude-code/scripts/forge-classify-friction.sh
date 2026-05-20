#!/usr/bin/env bash
# forge-classify-friction.sh — classifies friction events to named patterns.
# Walks the decision tree defined in core/references/friction-classifier.md.
#
# Modes:
#   --interactive [--description "..."]            (default) prompts via stdin
#   --json-input <file|->  [--description "..."]   reads pre-answered questions from JSON
#
# Output: JSON to stdout:
#   { "pattern": "<slug>|needs_new_pattern", "description": "<...>",
#     "action_sketch": "<...>", "catalog_link": "<relative-path>" }

set -euo pipefail

MODE=""
JSON_INPUT=""
DESCRIPTION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --interactive) MODE="interactive"; shift ;;
    --json-input)  MODE="json"; JSON_INPUT="${2:-}"; shift 2 ;;
    --description) DESCRIPTION="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Default mode
if [ -z "$MODE" ]; then MODE="interactive"; fi

# Helper: read a yes/no answer from stdin in interactive mode
ask_yn() {
  local prompt="$1"; local ans
  while true; do
    printf '%s [Y/n] ' "$prompt" > /dev/tty
    read -r ans < /dev/tty || ans="Y"
    case "${ans:-Y}" in
      Y|y|Yes|yes) echo "true"; return ;;
      N|n|No|no)   echo "false"; return ;;
      *) echo "Please answer Y or N" > /dev/tty ;;
    esac
  done
}

# Read inputs (either from JSON file/stdin or interactively)
declare -A A
if [ "$MODE" = "json" ]; then
  if [ "$JSON_INPUT" = "-" ]; then
    raw=$(cat)
  else
    raw=$(cat "$JSON_INPUT")
  fi
  for k in q1_perm_prompt q2_safe_to_allowlist q3_glob_subtlety q4_wrap_safer q5_hook_misfire q6_prose_drift q7_verbatim q8_structured_drift; do
    v=$(echo "$raw" | jq -r --arg k "$k" '.[$k] // empty')
    A[$k]="$v"
  done
else
  A[q1_perm_prompt]=$(ask_yn "Q1. Was the friction a permission prompt?")
  if [ "${A[q1_perm_prompt]}" = "true" ]; then
    A[q2_safe_to_allowlist]=$(ask_yn "Q2. Is the operation safe to allowlist?")
    if [ "${A[q2_safe_to_allowlist]}" = "true" ]; then
      A[q3_glob_subtlety]=$(ask_yn "Q3. Does an existing allowlist pattern fail to match due to a glob subtlety?")
      if [ "${A[q3_glob_subtlety]}" = "false" ]; then
        A[q4_wrap_safer]=$(ask_yn "Q4. Is wrapping in a subcommand safer (many call sites)?")
      fi
    fi
  else
    A[q5_hook_misfire]=$(ask_yn "Q5. Was the friction a hook firing when it shouldn't have?")
    if [ "${A[q5_hook_misfire]}" = "false" ]; then
      A[q6_prose_drift]=$(ask_yn "Q6. Was the friction prose-discipline drift?")
      if [ "${A[q6_prose_drift]}" = "true" ]; then
        A[q7_verbatim]=$(ask_yn "Q7. Is the required output a verbatim string?")
      else
        A[q8_structured_drift]=$(ask_yn "Q8. Did the agent reconstruct structured multi-line text and drift?")
      fi
    fi
  fi
fi

# Walk the tree
pattern="needs_new_pattern"
action_sketch=""

if [ "${A[q1_perm_prompt]:-}" = "true" ]; then
  if [ "${A[q2_safe_to_allowlist]:-}" = "true" ]; then
    if [ "${A[q3_glob_subtlety]:-}" = "true" ]; then
      pattern="allowlist-patch"
      action_sketch="Add a precise Bash/Write/Edit pattern to ~/.claude/settings.json"
    elif [ "${A[q4_wrap_safer]:-}" = "true" ]; then
      pattern="wrapper-subcommand"
      action_sketch="Add a subcommand to forge-context.sh that performs the safe op"
    else
      pattern="allowlist-patch"
      action_sketch="Add the precise allow pattern (single call site)"
    fi
  else
    pattern="needs_new_pattern"
    action_sketch="Unsafe to allowlist — case-by-case review required"
  fi
elif [ "${A[q5_hook_misfire]:-}" = "true" ]; then
  pattern="marker-state-guard"
  action_sketch="Add marker-state check to the misfiring hook before its side effect"
elif [ "${A[q6_prose_drift]:-}" = "true" ]; then
  if [ "${A[q7_verbatim]:-}" = "true" ]; then
    pattern="hook-injection"
    action_sketch="Add (or extend) a Claude Code hook to inject the verbatim string"
  else
    pattern="needs_new_pattern"
    action_sketch="Stylistic discipline — no current script-replaceable pattern"
  fi
elif [ "${A[q8_structured_drift]:-}" = "true" ]; then
  pattern="template-slot"
  action_sketch="Convert the verbatim structure to a template with {{slot}} markers"
fi

# Catalog link
catalog_link="core/references/script-replacement-patterns.md"
if [ "$pattern" != "needs_new_pattern" ]; then
  catalog_link="${catalog_link}#${pattern}"
fi

jq -n \
  --arg p "$pattern" \
  --arg d "$DESCRIPTION" \
  --arg a "$action_sketch" \
  --arg c "$catalog_link" \
  '{pattern: $p, description: $d, action_sketch: $a, catalog_link: $c}'
