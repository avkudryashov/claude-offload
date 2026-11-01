load helpers/common
setup() {
  setup_common
  HOOK=$BATS_TEST_DIRNAME/../hooks/offload-gate.sh
  cd "$TEST_TMP"
  seq 1 801 > big.log
  seq 1 10 > small.log
  seq 1 5000 > big.go
  mkdir -p logs
  seq 1 801 > logs/app.json
}
teardown() { teardown_common; }

hook() {
  printf '{"hook_event_name":"PreToolUse","tool_name":"Read","cwd":"%s","tool_input":%s}' "$TEST_TMP" "$1" | bash "$HOOK"
}
decision() { echo "$output" | jq -r .hookSpecificOutput.permissionDecision; }
reason() { echo "$output" | jq -r .hookSpecificOutput.permissionDecisionReason; }

@test "denies a big .log with valid JSON naming the path" {
  run hook '{"file_path":"'"$TEST_TMP"'/big.log"}'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .hookSpecificOutput.hookEventName)" = PreToolUse ]
  [ "$(decision)" = deny ]
  [[ "$(reason)" == "File $TEST_TMP/big.log has 801 lines. Offload it instead of reading it: offload ask \"<what you need, and the answer language>\" $TEST_TMP/big.log. If you need an exact spot afterwards, Read it with offset/limit." ]]
}

@test "allows a small .log" {
  run hook '{"file_path":"'"$TEST_TMP"'/small.log"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows a big source file" {
  run hook '{"file_path":"'"$TEST_TMP"'/big.go"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "denies inside a logs directory regardless of extension" {
  run hook '{"file_path":"'"$TEST_TMP"'/logs/app.json"}'
  [ "$(decision)" = deny ]
}

@test "allows ranged reads" {
  run hook '{"file_path":"'"$TEST_TMP"'/big.log","limit":50}'
  [ -z "$output" ]
  run hook '{"file_path":"'"$TEST_TMP"'/big.log","offset":10}'
  [ -z "$output" ]
}

@test "relative path with spaces resolves against cwd" {
  mkdir -p "my dir"
  seq 1 801 > "my dir/x.log"
  run hook '{"file_path":"my dir/x.log"}'
  [ "$(decision)" = deny ]
  [[ "$(reason)" == *"my dir/x.log has 801 lines"* ]]
}

@test "fresh marker opens the fuse, stale marker does not" {
  mkdir -p "$XDG_CACHE_HOME/offload"
  touch "$XDG_CACHE_HOME/offload/down"
  run hook '{"file_path":"'"$TEST_TMP"'/big.log"}'
  [ -z "$output" ]
  OFFLOAD_GATE_FUSE=0 run hook '{"file_path":"'"$TEST_TMP"'/big.log"}'
  [ "$(decision)" = deny ]
}

@test "OFFLOAD_GATE=0 disables the gate" {
  OFFLOAD_GATE=0 run hook '{"file_path":"'"$TEST_TMP"'/big.log"}'
  [ -z "$output" ]
}

@test "OFFLOAD_GATE_LINES and OFFLOAD_GATE_EXT are honoured" {
  OFFLOAD_GATE_LINES=5 run hook '{"file_path":"'"$TEST_TMP"'/small.log"}'
  [ "$(decision)" = deny ]
  OFFLOAD_GATE_EXT="go" run hook '{"file_path":"'"$TEST_TMP"'/big.go"}'
  [ "$(decision)" = deny ]
  OFFLOAD_GATE_EXT="go" run hook '{"file_path":"'"$TEST_TMP"'/big.log"}'
  [ -z "$output" ]
}

@test "missing file fails open" {
  run hook '{"file_path":"'"$TEST_TMP"'/none.log"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed JSON fails open" {
  run bash -c "echo 'not json' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "other tools fail open" {
  run bash -c "printf '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty stdin fails open" {
  run bash -c "bash '$HOOK' </dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "finishes fast on a 200k-line file" {
  seq 1 200000 > huge.log
  start=$(date +%s)
  run hook '{"file_path":"'"$TEST_TMP"'/huge.log"}'
  [ $(( $(date +%s) - start )) -le 2 ]
  [ "$(decision)" = deny ]
}
