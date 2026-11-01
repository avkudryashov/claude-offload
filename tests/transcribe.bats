load helpers/common
setup() { setup_common; export GROQ_API_KEY=g; echo audio > "$TEST_TMP/a.m4a"; }
teardown() { teardown_common; }

@test "transcribe posts the file to groq whisper" {
  scenario api.groq.com 200 'hello world'
  run "$OFFLOAD" transcribe "$TEST_TMP/a.m4a"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
  grep -q "^api.groq.com||0|file=@$TEST_TMP/a.m4a;model=whisper-large-v3-turbo;response_format=text|Bearer g$" "$OFFLOAD_TEST_LOG"
}

@test "extra -F args pass through after --" {
  scenario api.groq.com 200 'ok'
  run "$OFFLOAD" transcribe "$TEST_TMP/a.m4a" -- -F language=ru
  [ "$status" -eq 0 ]
  grep -q ';language=ru|' "$OFFLOAD_TEST_LOG"
}

@test "missing file is a usage error" {
  run "$OFFLOAD" transcribe "$TEST_TMP/none"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
}

@test "no file argument is a usage error" {
  run "$OFFLOAD" transcribe
  [ "$status" -eq 2 ]
}

@test "missing groq key is a config error" {
  unset GROQ_API_KEY
  run "$OFFLOAD" transcribe "$TEST_TMP/a.m4a"
  [ "$status" -eq 2 ]
  [[ "$output" == *GROQ_API_KEY* ]]
}

@test "non-200 from groq is reported and exits 1" {
  scenario api.groq.com 413 '{"error":{"message":"file too large"}}'
  run "$OFFLOAD" transcribe "$TEST_TMP/a.m4a"
  [ "$status" -eq 1 ]
  [[ "$output" == *"413"* ]]
  [[ "$output" == *"file too large"* ]]
}
