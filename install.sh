#!/usr/bin/env bash
# install.sh — link the offload CLI, install the Claude Code skill and,
# optionally, register the Read hook in ~/.claude/settings.json.
#
#   ./install.sh            link bin + copy skill
#   ./install.sh --hook     also register hooks/offload-gate.sh
#   ./install.sh --uninstall  remove the link, the skill and the hook entry
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
BIN_DIR=${OFFLOAD_BIN_DIR:-$HOME/.local/bin}
SKILL_DIR=$HOME/.claude/skills/offload
SETTINGS=$HOME/.claude/settings.json
HOOK_CMD=$REPO/hooks/offload-gate.sh

usage() { echo "usage: install.sh [--hook] [--uninstall]" >&2; exit 2; }

mode=install
hook=0
for arg in "$@"; do
  case "$arg" in
    --hook) hook=1 ;;
    --uninstall) mode=uninstall ;;
    *) usage ;;
  esac
done

backup_settings() {
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  fi
}

# write_settings JQ_FILTER — apply a jq filter to settings.json (created if missing).
write_settings() {
  local tmp
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  backup_settings
  tmp=$(mktemp)
  jq --arg cmd "$HOOK_CMD" "$1" "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
}

# Hook entries are identified by a command ending in /hooks/offload-gate.sh
# (optionally followed by the closing quote of a shell-quoted path).
# $cmd below is a jq variable, not a shell one.
# shellcheck disable=SC2016
REMOVE_FILTER='
  if .hooks and .hooks.PreToolUse then
    .hooks.PreToolUse |= map(select((.hooks // []) | any(.command? // "" | test("/hooks/offload-gate\\.sh'"'"'?$")) | not))
  else . end'
# shellcheck disable=SC2016
ADD_FILTER="$REMOVE_FILTER"'
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher: "Read", hooks: [{type: "command", command: ($cmd | @sh), timeout: 10}]}])'

snippet() {
  cat <<SNIP

To register the hook by hand, merge this into $SETTINGS:
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Read",
        "hooks": [ { "type": "command", "command": "'$HOOK_CMD'", "timeout": 10 } ] }
    ]
  }
}
SNIP
}

if [ "$mode" = uninstall ]; then
  rm -f "$BIN_DIR/offload"
  rm -rf "$SKILL_DIR"
  [ -f "$SETTINGS" ] && write_settings "$REMOVE_FILTER"
  echo "removed $BIN_DIR/offload, $SKILL_DIR and the hook entry (settings backup kept)"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required (brew install jq / apt install jq)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "install.sh: curl is required" >&2; exit 1; }

mkdir -p "$BIN_DIR"
ln -sfn "$REPO/bin/offload" "$BIN_DIR/offload"
echo "linked $BIN_DIR/offload -> $REPO/bin/offload"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "warning: $BIN_DIR is not on PATH" >&2 ;;
esac

mkdir -p "$SKILL_DIR"
cp "$REPO/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "installed skill $SKILL_DIR/SKILL.md"
if [ -d "$HOME/.claude/skills/delegate" ]; then
  echo "warning: $HOME/.claude/skills/delegate exists; two skills with the same triggers compete, remove the old one" >&2
fi

if [ "$hook" -eq 1 ]; then
  write_settings "$ADD_FILTER"
  echo "registered PreToolUse hook $HOOK_CMD in $SETTINGS (backup kept)"
else
  echo "hook not registered (run with --hook, or merge the snippet below)"
fi
snippet
