#!/usr/bin/env bash
# offload-gate — Claude Code PreToolUse hook for the Read tool.
#
# Denies reading big log-like files directly and points Claude at `offload ask`.
# Fails open: any internal error, unknown input or missing dependency allows the
# read (no output, exit 0). Never exits non-zero.
#
# Env: OFFLOAD_GATE=0 disables; OFFLOAD_GATE_LINES (800); OFFLOAD_GATE_EXT
# ("log out txt"); OFFLOAD_GATE_FUSE seconds (600) during which a fresh
# "providers down" marker written by `offload ask` lets reads through.

trap 'exit 0' EXIT

gate() {
  [ "${OFFLOAD_GATE:-1}" != 0 ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local input tool ranged path cwd
  input=$(cat 2>/dev/null) || return 0
  [ -n "$input" ] || return 0
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || return 0
  [ "$tool" = Read ] || return 0
  ranged=$(printf '%s' "$input" | jq -r 'if (.tool_input.limit? // .tool_input.offset?) != null then "1" else "" end' 2>/dev/null) || return 0
  [ -z "$ranged" ] || return 0
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || return 0
  [ -n "$path" ] || return 0
  case "$path" in
    /*) ;;
    *) cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null); path="${cwd:-$PWD}/$path" ;;
  esac
  [ -f "$path" ] && [ -r "$path" ] || return 0

  # Fuse: `offload ask` found every provider down recently, so let Claude read.
  local marker="${XDG_CACHE_HOME:-$HOME/.cache}/offload/down" fuse="${OFFLOAD_GATE_FUSE:-600}" mtime now
  if [ -e "$marker" ]; then
    # GNU stat first: on GNU, "stat -f %m" is the *filesystem* mount point, not an error.
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || return 0
    case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
    now=$(date +%s)
    [ $((now - mtime)) -ge "$fuse" ] || return 0
  fi

  # Only log-like files: listed extensions, or anything under a logs/ directory.
  local matched="" ext e
  case "$path" in */logs/*) matched=1 ;; esac
  if [ -z "$matched" ]; then
    ext=${path##*.}
    [ "$ext" != "$path" ] || return 0
    for e in ${OFFLOAD_GATE_EXT:-log out txt}; do
      [ "$ext" = "$e" ] && matched=1
    done
  fi
  [ -n "$matched" ] || return 0

  local lines
  lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ') || return 0
  [ "$lines" -gt "${OFFLOAD_GATE_LINES:-800}" ] 2>/dev/null || return 0

  jq -cn --arg p "$path" --arg n "$lines" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("File \($p) has \($n) lines. Offload it instead of reading it: offload ask \"<what you need, and the answer language>\" \($p). If you need an exact spot afterwards, Read it with offset/limit.")
    }
  }'
}

gate
exit 0
