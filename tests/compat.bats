# Everything must run on the system bash, which is 3.2 on macOS.
load helpers/common
setup() {
  setup_common
  export GROQ_API_KEY=g
  [ -x /bin/bash ] || skip "no /bin/bash on this system"
}
teardown() { teardown_common; }

@test "system bash runs --version" {
  run /bin/bash "$OFFLOAD" --version
  [ "$status" -eq 0 ]
  [ "$output" = "offload 0.1.0" ]
}

@test "system bash runs providers" {
  run /bin/bash "$OFFLOAD" providers
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "system bash runs ask through the shim" {
  scenario api.groq.com 200 "$(ok_body ok)"
  run --separate-stderr /bin/bash "$OFFLOAD" ask "x"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "system bash runs doctor" {
  scenario api.groq.com 200 '{}'
  run /bin/bash "$OFFLOAD" doctor
  [ "$status" -eq 0 ]
}

@test "system bash runs the hook" {
  seq 1 801 > "$TEST_TMP/a.log"
  run bash -c "printf '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$TEST_TMP/a.log\"}}' | /bin/bash '$BATS_TEST_DIRNAME/../hooks/offload-gate.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *deny* ]]
}

@test "system bash runs the installer" {
  mkdir -p "$HOME/.claude"
  run /bin/bash "$BATS_TEST_DIRNAME/../install.sh" --hook
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/offload" ]
}

@test "system bash runs redact" {
  run bash -c "printf 'password=hunter2hunter2' | /bin/bash '$OFFLOAD' redact - 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "password=[REDACTED:secret-assignment]" ]
}
