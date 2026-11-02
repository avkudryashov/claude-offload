load helpers/common
setup() {
  setup_common
  for h in api.groq.com integrate.api.nvidia.com api.cerebras.ai; do scenario "$h" 200 '{"data":[]}'; done
}
teardown() { teardown_common; }

@test "doctor with no keys exits 1 and names every env var" {
  run "$OFFLOAD" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"groq: no key (GROQ_API_KEY)"* ]]
  [[ "$output" == *"nvidia: no key (NVIDIA_API_KEY)"* ]]
  [[ "$output" == *"cerebras: no key (CEREBRAS_API_KEY)"* ]]
}

@test "env var key is used and never printed" {
  GROQ_API_KEY=gsk_secret_value run "$OFFLOAD" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"groq: key present (GROQ_API_KEY), models HTTP 200"* ]]
  [[ "$output" != *gsk_secret_value* ]]
  grep -q '^api.groq.com|.*|Bearer gsk_secret_value$' "$OFFLOAD_TEST_LOG"
}

@test "key from ~/.env survives an unquoted ampersand line and quotes" {
  printf 'AD_PASS=a&b\nGROQ_API_KEY="gsk_from_file"\nNVIDIA_API_KEY=%s\n' "'nvapi_x'" > "$HOME/.env"
  run "$OFFLOAD" doctor
  [ "$status" -eq 0 ]
  grep -q '|Bearer gsk_from_file$' "$OFFLOAD_TEST_LOG"
  grep -q '|Bearer nvapi_x$' "$OFFLOAD_TEST_LOG"
}

@test "value keeps everything after the first equals sign" {
  printf 'GROQ_API_KEY=abc=def\n' > "$HOME/.env"
  run "$OFFLOAD" doctor
  grep -q '|Bearer abc=def$' "$OFFLOAD_TEST_LOG"
}

@test "env var wins over file" {
  printf 'GROQ_API_KEY=from_file\n' > "$HOME/.env"
  GROQ_API_KEY=from_env run "$OFFLOAD" doctor
  grep -q '|Bearer from_env$' "$OFFLOAD_TEST_LOG"
}

@test "OFFLOAD_ENV_FILE overrides, then ~/.config/offload/env, then ~/.env" {
  mkdir -p "$HOME/.config/offload"
  printf 'GROQ_API_KEY=cfg\n' > "$HOME/.config/offload/env"
  printf 'GROQ_API_KEY=dot\n' > "$HOME/.env"
  run "$OFFLOAD" doctor
  grep -q '|Bearer cfg$' "$OFFLOAD_TEST_LOG"
  printf 'GROQ_API_KEY=custom\n' > "$TEST_TMP/custom.env"
  : > "$OFFLOAD_TEST_LOG"
  OFFLOAD_ENV_FILE=$TEST_TMP/custom.env run "$OFFLOAD" doctor
  grep -q '|Bearer custom$' "$OFFLOAD_TEST_LOG"
}

@test "doctor reports a failing models call without printing the key" {
  : > "$OFFLOAD_TEST_SCENARIO"
  scenario api.groq.com 401 '{"error":"bad"}'
  GROQ_API_KEY=gsk_zz run "$OFFLOAD" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"groq: key present (GROQ_API_KEY), models HTTP 401"* ]]
  [[ "$output" != *gsk_zz* ]]
}
