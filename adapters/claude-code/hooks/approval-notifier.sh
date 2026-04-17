#!/bin/bash
# Sends macOS notification when Claude Code needs approval

# Read hook input from stdin
input=$(cat)

# Extract tool name and check if it requires approval
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

requires_approval=false

if [[ "$tool_name" == "Bash" ]]; then
  command=$(echo "$input" | jq -r '.tool_input.command // empty')

  # Built-in patterns that typically require approval
  if [[ "$command" == git\ commit* ]] || \
     [[ "$command" == git\ push* ]] || \
     [[ "$command" == gh\ pr\ create* ]] || \
     [[ "$command" == curl* ]]; then
    requires_approval=true
  fi

  # Extra patterns from ~/.claude/approval-patterns.conf (one glob per line)
  if [ "$requires_approval" = false ] && [ -f "$HOME/.claude/approval-patterns.conf" ]; then
    while IFS= read -r pattern; do
      [[ -z "$pattern" || "$pattern" == \#* ]] && continue
      if [[ "$command" == $pattern ]]; then
        requires_approval=true
        break
      fi
    done < "$HOME/.claude/approval-patterns.conf"
  fi
elif [[ "$tool_name" == "WebFetch" ]]; then
  requires_approval=true
fi

# Send notification if approval is needed
if [ "$requires_approval" = true ]; then
  terminal-notifier -title "Claude Code" -message "Needs your approval" -sound Submarine -group "claude-code-approval" &>/dev/null &
fi

# Exit 0 = implicit allow (no JSON needed for pass-through)
