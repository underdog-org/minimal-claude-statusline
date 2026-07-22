#!/bin/sh
#
# claude-status-line installer — POSIX sh, works via `curl -fsSL ... | sh`.
#
#   Install:    curl -fsSL <RAW_URL>/install.sh | sh
#   Uninstall:  curl -fsSL <RAW_URL>/install.sh | sh -s -- uninstall
#
# Steps:
#   1. Place statusline.sh at ~/.claude/statusline.sh (copy locally, else download).
#   2. Merge a statusLine block into ~/.claude/settings.json atomically via jq.
# Idempotent: re-running just overwrites the statusLine key.
#
set -eu

# --- config -----------------------------------------------------------------
REPO_RAW="https://raw.githubusercontent.com/rong/claude-status-line/main"
CLAUDE_DIR="${HOME}/.claude"
SCRIPT_DEST="${CLAUDE_DIR}/statusline.sh"
SETTINGS="${CLAUDE_DIR}/settings.json"

# --- helpers ----------------------------------------------------------------
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[32m==>\033[0m %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"; }

# --- uninstall --------------------------------------------------------------
uninstall() {
  need jq
  if [ -f "$SETTINGS" ]; then
    tmp=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    info "removed statusLine from $SETTINGS"
  fi
  [ -f "$SCRIPT_DEST" ] && rm -f "$SCRIPT_DEST" && info "removed $SCRIPT_DEST"
  info "done. restart Claude Code."
}

# --- install ----------------------------------------------------------------
install() {
  need jq
  mkdir -p "$CLAUDE_DIR"

  # 1. place the status line script — prefer a local copy, else download.
  here=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd || true)
  if [ -n "$here" ] && [ -f "$here/statusline.sh" ]; then
    cp "$here/statusline.sh" "$SCRIPT_DEST"
    info "copied statusline.sh -> $SCRIPT_DEST"
  else
    need curl
    curl -fsSL "$REPO_RAW/statusline.sh" -o "$SCRIPT_DEST" \
      || die "failed to download statusline.sh"
    info "downloaded statusline.sh -> $SCRIPT_DEST"
  fi
  chmod +x "$SCRIPT_DEST"

  # 2. atomically merge the statusLine block into settings.json.
  [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
  tmp=$(mktemp)
  jq --arg cmd "$SCRIPT_DEST" '
    .statusLine = {
      type: "command",
      command: $cmd,
      refreshInterval: 10,
      padding: 0
    }
  ' "$SETTINGS" > "$tmp" || { rm -f "$tmp"; die "failed to update $SETTINGS (invalid JSON?)"; }
  mv "$tmp" "$SETTINGS"
  info "configured statusLine in $SETTINGS"

  info "done. restart Claude Code (accept the workspace-trust dialog if asked)."
}

# --- dispatch ---------------------------------------------------------------
case "${1:-install}" in
  install)   install ;;
  uninstall) uninstall ;;
  *)         die "unknown command: $1 (use 'install' or 'uninstall')" ;;
esac
