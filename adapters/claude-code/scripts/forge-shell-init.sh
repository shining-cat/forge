# Forge shell init — auto-wraps interactive `claude` invocations in tmux
# so Petra (the Forge orchestrator) can spawn Pattern A agent teams as
# tmux panes without requiring user pre-setup at launch time.
#
# Sourced from your shell rc by forge install.sh:
#   [ -f ~/.claude/forge-shell-init.sh ] && source ~/.claude/forge-shell-init.sh
#
# Bypass for one shell session:  export FORGE_NO_TMUX_WRAP=1
# Bypass automatic when:  not interactive, already in tmux, or tmux missing.

claude() {
  if [ -n "${FORGE_NO_TMUX_WRAP:-}" ] \
     || [ ! -t 0 ] || [ ! -t 1 ] \
     || [ -n "${TMUX:-}" ] \
     || ! command -v tmux >/dev/null 2>&1; then
    command claude "$@"
    return $?
  fi

  local session_name="claude-$$"
  if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    exec tmux -CC new -s "$session_name" "command claude $*"
  else
    exec tmux new -s "$session_name" "command claude $*"
  fi
}
