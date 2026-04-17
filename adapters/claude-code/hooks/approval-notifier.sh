#!/bin/bash
# Sends macOS notification when Claude Code needs approval

# Read hook input from stdin
input=$(cat)

# Extract tool name and check if it requires approval
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
tool_input=$(echo "$input" | jq -r '.tool_input // empty')

# Tools that typically require approval (based on your settings.json "ask" list)
# WebFetch, git commit, git push, gh pr create, curl, acli jira edit/transition/comment/create
requires_approval=false

if [[ "$tool_name" == "Bash" ]]; then
  command=$(echo "$input" | jq -r '.tool_input.command // empty')

  # Check if command matches patterns in "ask" list
  if [[ "$command" == git\ commit* ]] || \
     [[ "$command" == git\ push* ]] || \
     [[ "$command" == gh\ pr\ create* ]] || \
     [[ "$command" == curl* ]] || \
     [[ "$command" == acli\ jira\ workitem\ edit* ]] || \
     [[ "$command" == acli\ jira\ workitem\ transition* ]] || \
     [[ "$command" == acli\ jira\ workitem\ comment\ create* ]] || \
     [[ "$command" == acli\ jira\ workitem\ create* ]]; then
    requires_approval=true
  fi
elif [[ "$tool_name" == "WebFetch" ]]; then
  requires_approval=true
fi

# Send notification if approval is needed
if [ "$requires_approval" = true ]; then
  terminal-notifier -title "Claude Code" -message "Needs your approval" -sound Submarine -group "claude-code-approval" &>/dev/null &
fi

# Exit 0 = implicit allow (no JSON needed for pass-through)
