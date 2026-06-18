#!/bin/bash
# forge-credential-guard — PreToolUse hook (Bash)
#
# Asks for confirmation when a Bash command would INSPECT a credential-bearing
# file with a content-printing verb (grep/cat/head/tail/sed/awk/strings/…).
# The danger it guards against: a value-capturing read (e.g.
# `grep -i artifactory ~/.gradle/gradle.properties`) echoes the secret into the
# tool output, where it persists in the conversation transcript — an
# irreversible leak (see [[2026-06-15-credential-leak-via-greedy-grep]]).
#
# Decision: "ask" (not deny). The prompt is the circuit-breaker — it makes both
# Claude and the user reconsider before the value is printed. Legitimate reads
# (credential migration, key-only/count-only verification) remain possible by
# approving. The comprehensive discipline lives in
# core/references/credential-discipline.md; this hook is the high-confidence
# backstop for the most common concrete credential files.
#
# Always-on: unlike the vault guards, this is NOT gated on the forge-active
# marker. Credential safety is not session-specific — once installed, it fires
# for every Bash call (main session and subagents alike; a background subagent
# that cannot answer the prompt auto-denies, which is the safe default for a
# credential read).
#
# Fail-safe: any parse problem or non-match → allow (exit 0).

set -euo pipefail

INPUT="$(cat)"

TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // empty')"
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty')"
[ -z "$CMD" ] && exit 0

# Content-printing verbs (NOT `ls`/`stat`/`file` — those don't print contents).
# Anchored to a command-word boundary so `wildcat foo` doesn't match `cat`.
VERB='(^|[|&;[:space:]])(grep|egrep|fgrep|rg|cat|bat|batcat|head|tail|less|more|sed|awk|strings|xxd|od|hexdump|nl|tac|cut)[[:space:]]'

# Curated, high-confidence credential-bearing files. Deliberately NOT matching
# bare substrings like "token"/"secret" — that would prompt on every
# `grep token src/`. The prose rule carries the exhaustive list for discipline;
# this list is the machinery backstop.
CREDFILE='(gradle\.properties|\.netrc|\.npmrc|\.pypirc|\.git-credentials|\.pgpass|\.my\.cnf|\.htpasswd|\.aws/credentials|\.docker/config\.json|\.ssh/|id_rsa|id_dsa|id_ecdsa|id_ed25519|\.env($|[^[:alnum:]])|\.(pem|key|p12|pfx|keystore|jks|asc|gpg)($|[^[:alnum:]])|(secrets?|credentials)\.(json|ya?ml|env|txt|properties|conf))'

# Both an inspection verb AND a credential-file reference must be present.
echo "$CMD" | grep -Eq "$VERB"     || exit 0
echo "$CMD" | grep -Eq "$CREDFILE" || exit 0

MATCH="$(echo "$CMD" | grep -Eo "$CREDFILE" | head -1 || true)"
[ -z "$MATCH" ] && MATCH="a credential-bearing file"

REASON="[forge] This command inspects $MATCH — a credential-bearing file. Reading it can echo secret values into the transcript (an irreversible leak).
Prefer the tool's own validation instead of reading the file: ./gradlew tasks, aws sts get-caller-identity, gh auth status, npm whoami, etc. The tool's success/failure IS the verification.
If you must read it (e.g. credential migration with explicit authorization): use key-only (grep -oE '^[A-Z_]+') or count-only (grep -c) patterns that never print a value.
See core/references/credential-discipline.md."

jq -n --arg reason "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": $reason
  }
}'
exit 0
