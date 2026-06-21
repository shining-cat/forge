#!/usr/bin/env bash
# forge-vault-symlinks.sh — manage machine-local vault symlinks.
#
# Why this exists:
#   A few vault entries are symlinks to machine-local paths OUTSIDE the vault
#   (e.g. sibling code repositories, dotfile logs). They must NOT be tracked
#   in git, because they (a) point to paths that differ per machine and
#   (b) cannot be represented on Android / SAF storage — the Obsidian mobile
#   client checks them out as "missing" and obsidian-git then commits their
#   deletion, corrupting the repo on every backup.
#
#   Instead we track a portable, mobile-safe manifest and regenerate the
#   symlinks per machine. The symlinks themselves are gitignored.
#
# Manifest: $VAULT_PATH/_shared/_meta/vault-symlinks.tsv
#   tab-separated:  <vault-relative-path>\t<target, leading ~ = $HOME>
#   lines beginning with # are ignored.
#
# Private roots: set VAULT_PRIVATE_ROOTS in forge.conf (comma-separated
#   top-level dirs, e.g. gitignored work areas) to exclude them from `capture`
#   so their paths never enter the shared manifest. Default: none.
#
# Subcommands:
#   generate   (default) (re)create every symlink from the manifest — idempotent
#   capture    rebuild the manifest from symlinks currently present in the vault
#   check      portability lint: report tracked symlinks + non-portable filenames
set -euo pipefail

CONF="${FORGE_CONF:-$HOME/.claude/forge.conf}"
[ -r "$CONF" ] || { echo "forge.conf not found at $CONF" >&2; exit 1; }
VAULT_PATH="$(awk -F= '/^VAULT_PATH=/{print $2; exit}' "$CONF")"
[ -n "$VAULT_PATH" ] || { echo "VAULT_PATH not set in $CONF" >&2; exit 1; }
PRIVATE_ROOTS="$(awk -F= '/^VAULT_PRIVATE_ROOTS=/{print $2; exit}' "$CONF")"
MANIFEST="$VAULT_PATH/_shared/_meta/vault-symlinks.tsv"

do_generate() {
  [ -r "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
  local rel tgt dest n=0 miss=0
  while IFS=$'\t' read -r rel tgt || [ -n "$rel" ]; do
    [ -z "$rel" ] && continue
    case "$rel" in \#*) continue ;; esac
    tgt="${tgt/#\~/$HOME}"
    dest="$VAULT_PATH/$rel"
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$tgt" "$dest"
    if [ -e "$tgt" ]; then
      n=$((n + 1))
    else
      echo "WARN target missing: $rel -> $tgt" >&2
      miss=$((miss + 1))
    fi
  done <"$MANIFEST"
  echo "regenerated $n symlink(s)$([ "$miss" -gt 0 ] && echo ", $miss with missing target")"
}

do_capture() {
  local tmp rel tgt r
  tmp="$(mktemp)"
  {
    echo "# vault machine-local symlinks — regenerate with: forge-vault-symlinks.sh generate"
    echo "# format: <vault-relative-path><TAB><target, leading ~ = \$HOME>"
  } >"$tmp"
  # Exclude .git and any configured private roots (VAULT_PRIVATE_ROOTS) — those
  # paths must never enter the shared manifest (separation; avoids leaking a
  # private path onto synced/mobile clones). They are managed out-of-band.
  local find_args=("$VAULT_PATH" -type l -not -path '*/.git/*')
  IFS=',' read -ra _roots <<<"$PRIVATE_ROOTS"
  for r in "${_roots[@]}"; do
    r="$(echo "$r" | tr -d '[:space:]')"
    [ -n "$r" ] && find_args+=(-not -path "$VAULT_PATH/$r/*")
  done
  find "${find_args[@]}" -print | sort | while read -r link; do
    rel="${link#"$VAULT_PATH"/}"
    tgt="$(readlink "$link")"
    tgt="${tgt/#"$HOME"/\~}"
    printf '%s\t%s\n' "$rel" "$tgt" >>"$tmp"
  done
  mv "$tmp" "$MANIFEST"
  echo "captured $(grep -cv '^#' "$MANIFEST") symlink(s) -> $MANIFEST"
}

do_check() {
  local rc=0 syms bad
  # 1) tracked symlinks — there should be none (gitignore + add to manifest)
  if git -C "$VAULT_PATH" rev-parse >/dev/null 2>&1; then
    syms="$(git -C "$VAULT_PATH" ls-files -s | awk '$1=="120000"{ $1=$2=$3=""; sub(/^   /,""); print }')"
    if [ -n "$syms" ]; then
      echo "FAIL tracked symlinks (gitignore them + add to the manifest):" >&2
      echo "$syms" | sed 's/^/  /' >&2
      rc=1
    fi
  fi
  # 2) non-portable filenames anywhere under the vault (illegal on Windows/Android/exFAT)
  bad="$(find "$VAULT_PATH" -not -path '*/.git/*' -name '*[<>:"|?*]*' -print 2>/dev/null | sed "s#$VAULT_PATH/##")"
  if [ -n "$bad" ]; then
    echo "FAIL non-portable filename(s) — rename (no chars  < > : \" | ? *):" >&2
    echo "$bad" | sed 's/^/  /' >&2
    rc=1
  fi
  [ "$rc" -eq 0 ] && echo "vault portability check: OK"
  return "$rc"
}

case "${1:-generate}" in
  generate) do_generate ;;
  capture) do_capture ;;
  check) do_check ;;
  *)
    echo "usage: forge-vault-symlinks.sh {generate|capture|check}" >&2
    exit 2
    ;;
esac
