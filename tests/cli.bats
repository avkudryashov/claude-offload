load helpers/common
setup() { setup_common; }
teardown() { teardown_common; }

@test "--version prints version" {
  run "$OFFLOAD" --version
  [ "$status" -eq 0 ]
  [ "$output" = "offload 0.1.0" ]
}

@test "--help prints synopsis" {
  run "$OFFLOAD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"offload ask"* ]]
  [[ "$output" == *"offload transcribe"* ]]
}

@test "no args is a usage error" {
  run "$OFFLOAD"
  [ "$status" -eq 2 ]
}

@test "unknown subcommand is a usage error" {
  run "$OFFLOAD" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "providers lists the three ids with key env" {
  run "$OFFLOAD" providers
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == groq*GROQ_API_KEY ]]
  [[ "${lines[1]}" == nvidia*NVIDIA_API_KEY ]]
  [[ "${lines[2]}" == cerebras*CEREBRAS_API_KEY ]]
}

@test "curl shim replays a scenario and logs the call" {
  scenario api.example.com 418 '{"x":1}'
  run curl -sS --max-time 5 -w '\n%{http_code}' https://api.example.com/v1/x \
    -H 'Authorization: Bearer k' \
    -d '{"model":"m","messages":[{"role":"user","content":"abc"}]}'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '{"x":1}' ]
  [ "${lines[1]}" = 418 ]
  [ "$(cat "$OFFLOAD_TEST_LOG")" = "api.example.com|m|3||Bearer k" ]
}

@test "curl shim times out when delay exceeds max-time" {
  scenario slow.example.com 200 '{}' 3
  run curl -sS --max-time 1 https://slow.example.com/
  [ "$status" -eq 28 ]
}
