load helpers/common
setup() {
  setup_common
  INST=$BATS_TEST_DIRNAME/../install.sh
  mkdir -p "$HOME/.claude"
  echo '{"model":"opus","permissions":{"allow":["Bash(ls)"]}}' > "$HOME/.claude/settings.json"
}
teardown() { teardown_common; }

settings() { jq -r "$1" "$HOME/.claude/settings.json"; }

@test "install links the binary and copies the skill, no hook by default" {
  run bash "$INST"
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/offload" ]
  [ "$("$HOME/.local/bin/offload" --version)" = "offload 0.1.0" ]
  [ -f "$HOME/.claude/skills/offload/SKILL.md" ]
  [ "$(settings .hooks)" = null ]
  [ "$(settings .model)" = opus ]
}

@test "--hook merges the entry, keeps other keys, is idempotent, backs up" {
  run bash "$INST" --hook
  [ "$status" -eq 0 ]
  run bash "$INST" --hook
  [ "$status" -eq 0 ]
  [ "$(settings '.hooks.PreToolUse | length')" -eq 1 ]
  [ "$(settings '.hooks.PreToolUse[0].matcher')" = Read ]
  [ "$(settings '.hooks.PreToolUse[0].hooks[0].type')" = command ]
  [[ "$(settings '.hooks.PreToolUse[0].hooks[0].command')" == *"/hooks/offload-gate.sh"* ]]
  [ "$(settings '.hooks.PreToolUse[0].hooks[0].timeout')" = 10 ]
  [ "$(settings .model)" = opus ]
  [ "$(settings '.permissions.allow[0]')" = "Bash(ls)" ]
  ls "$HOME/.claude/"settings.json.bak.* >/dev/null
}

@test "--hook preserves an existing unrelated PreToolUse entry" {
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]}}' > "$HOME/.claude/settings.json"
  run bash "$INST" --hook
  [ "$status" -eq 0 ]
  [ "$(settings '.hooks.PreToolUse | length')" -eq 2 ]
  [ "$(settings '.hooks.PreToolUse[0].matcher')" = Bash ]
}

@test "--uninstall removes everything it added and keeps the rest" {
  bash "$INST" --hook
  run bash "$INST" --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/offload" ]
  [ ! -e "$HOME/.claude/skills/offload" ]
  [ "$(settings '.hooks.PreToolUse | length')" -eq 0 ]
  [ "$(settings .model)" = opus ]
}

@test "--uninstall keeps an unrelated PreToolUse entry" {
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]}}' > "$HOME/.claude/settings.json"
  bash "$INST" --hook
  bash "$INST" --uninstall
  [ "$(settings '.hooks.PreToolUse | length')" -eq 1 ]
  [ "$(settings '.hooks.PreToolUse[0].matcher')" = Bash ]
}

@test "warns about a competing delegate skill" {
  mkdir -p "$HOME/.claude/skills/delegate"
  run bash "$INST"
  [ "$status" -eq 0 ]
  [[ "$output" == *delegate* ]]
}

@test "works when settings.json does not exist" {
  rm "$HOME/.claude/settings.json"
  run bash "$INST" --hook
  [ "$status" -eq 0 ]
  [ "$(settings '.hooks.PreToolUse | length')" -eq 1 ]
}

@test "prints the manual settings snippet" {
  run bash "$INST"
  [[ "$output" == *'"PreToolUse"'* ]]
  [[ "$output" == *offload-gate.sh* ]]
}

@test "OFFLOAD_BIN_DIR relocates the symlink" {
  OFFLOAD_BIN_DIR=$TEST_TMP/bin run bash "$INST"
  [ "$status" -eq 0 ]
  [ -L "$TEST_TMP/bin/offload" ]
}

@test "unknown flag is a usage error" {
  run bash "$INST" --nope
  [ "$status" -eq 2 ]
}

@test "hook command is shell-quoted and runs from a checkout path with a space" {
  mkdir -p "$TEST_TMP/my repo"
  cp -R "$BATS_TEST_DIRNAME/../bin" "$BATS_TEST_DIRNAME/../hooks" "$BATS_TEST_DIRNAME/../skill" "$BATS_TEST_DIRNAME/../install.sh" "$TEST_TMP/my repo/"
  run bash "$TEST_TMP/my repo/install.sh" --hook
  [ "$status" -eq 0 ]
  cmd=$(settings '.hooks.PreToolUse[0].hooks[0].command')
  run sh -c "$cmd </dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$TEST_TMP/my repo/install.sh" --uninstall
  [ "$(settings '.hooks.PreToolUse | length')" -eq 0 ]
}
