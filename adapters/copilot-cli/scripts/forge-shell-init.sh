# Forge shell init — auto-wraps interactive `claude` invocations in tmux
# so Petra (the Forge orchestrator) can spawn Pattern A agent teams as
# tmux panes without requiring user pre-setup at launch time.
#
# Sourced from your shell rc by forge install.sh:
#   [ -f $COPILOT_DIR/forge-shell-init.sh ] && source $COPILOT_DIR/forge-shell-init.sh
#
# Bypass for one shell session:  export FORGE_NO_TMUX_WRAP=1
# Bypass automatic when:  not interactive, already in tmux, or tmux missing.
#
# Folder-trust anchor: the tmux session (and every agent-team fan-out pane,
# which inherits the session cwd) launches from FORGE_TRUST_ANCHOR — the single
# folder the user trusts ONCE. This stops parallel fan-out panes from each
# re-hitting GitHub Copilot CLI's folder-trust gate ("Do you trust the files in this
# folder?"). install.sh bakes FORGE_TRUST_ANCHOR into $COPILOT_DIR/forge.conf,
# derived from VAULT_PATH + REPO_ROOTS via `forge-context.sh trust-anchor`.
# If unset or no longer a directory, the wrapper falls back to no -c (panes
# launch from the shell cwd, as before).

claude() {
  if [ -n "${FORGE_NO_TMUX_WRAP:-}" ] \
     || [ ! -t 0 ] || [ ! -t 1 ] \
     || [ -n "${TMUX:-}" ] \
     || ! command -v tmux >/dev/null 2>&1; then
    command claude "$@"
    return $?
  fi

  local session_name="claude-$$"
  local tmux_conf="$COPILOT_DIR/forge-tmux.conf"

  # Resolve the trust anchor (baked into forge.conf at install time).
  local forge_conf="$COPILOT_DIR/forge.conf"
  local trust_anchor=""
  if [ -f "$forge_conf" ]; then
    trust_anchor="$(grep '^FORGE_TRUST_ANCHOR=' "$forge_conf" 2>/dev/null | cut -d= -f2- || true)"
  fi

  # iTerm gets tmux control mode (-CC). Unquoted expansion is intentional and
  # portable: empty → zero words (zsh removes it, bash splits to nothing);
  # "-CC" → a single word in both shells.
  local cc_flag=""
  [ "${TERM_PROGRAM:-}" = "iTerm.app" ] && cc_flag="-CC"

  if [ -n "$trust_anchor" ] && [ -d "$trust_anchor" ]; then
    exec tmux -f "$tmux_conf" $cc_flag new -c "$trust_anchor" -s "$session_name" "command claude $*"
  else
    exec tmux -f "$tmux_conf" $cc_flag new -s "$session_name" "command claude $*"
  fi
}
