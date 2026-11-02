load helpers/common
setup() { setup_common; export GROQ_API_KEY=g NVIDIA_API_KEY=n; }
teardown() { teardown_common; }

body_jq() { jq -r "$1" "$OFFLOAD_TEST_LOG.body"; }

@test "ask without input sends the instruction as the only user message" {
  scenario api.groq.com 200 "$(ok_body Madrid)"
  run --separate-stderr "$OFFLOAD" ask "Capital of Spain, one word"
  [ "$status" -eq 0 ]
  [ "$output" = Madrid ]
  [ "$stderr" = "[groq openai/gpt-oss-120b]" ]
  grep -q '^api.groq.com|openai/gpt-oss-120b|' "$OFFLOAD_TEST_LOG"
  [ "$(body_jq '.messages | length')" -eq 1 ]
  [ "$(body_jq '.messages[0].role')" = user ]
  [ "$(body_jq '.messages[0].content')" = "Capital of Spain, one word" ]
}

@test "ask with a file sends instruction as system and file as user" {
  scenario api.groq.com 200 "$(ok_body ok)"
  printf 'line1\nline2\n' > "$TEST_TMP/in.txt"
  run "$OFFLOAD" ask "Summarize" "$TEST_TMP/in.txt"
  [ "$status" -eq 0 ]
  [ "$(body_jq '.messages[0].role')" = system ]
  [ "$(body_jq '.messages[0].content')" = Summarize ]
  [ "$(body_jq '.messages[1].role')" = user ]
  [ "$(body_jq '.messages[1].content | @json')" = '"line1\nline2\n"' ]
  [ "$(body_jq '.temperature')" = 0.2 ]
}

@test "ask with - reads stdin" {
  scenario api.groq.com 200 "$(ok_body 4)"
  run --separate-stderr bash -c "echo '2+2=?' | '$OFFLOAD' ask 'Answer with a number' -"
  [ "$status" -eq 0 ]
  [ "$output" = 4 ]
  [ "$(body_jq '.messages[1].content | @json')" = '"2+2=?\n"' ]
}

@test "ask without second argument never waits on stdin" {
  scenario api.groq.com 200 "$(ok_body ok)"
  mkfifo "$TEST_TMP/fifo"
  ( sleep 5 > "$TEST_TMP/fifo" & )
  run bash -c "'$OFFLOAD' ask 'hi' < '$TEST_TMP/fifo' & p=\$!; for i in 1 2 3 4 5 6; do kill -0 \$p 2>/dev/null || exit 0; sleep 0.5; done; kill \$p; exit 99"
  [ "$status" -eq 0 ]
}

@test "missing input file is a usage error" {
  run "$OFFLOAD" ask "x" "$TEST_TMP/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
  [ ! -s "$OFFLOAD_TEST_LOG" ]
}

@test "no instruction is a usage error" {
  run "$OFFLOAD" ask
  [ "$status" -eq 2 ]
}

@test "-m without -p is a usage error" {
  run "$OFFLOAD" ask -m x "hi"
  [ "$status" -eq 2 ]
  [[ "$output" == *"-m requires -p"* ]]
}

@test "input above OFFLOAD_MAX_CHARS is refused before any request" {
  head -c 500 /dev/zero | tr '\0' a > "$TEST_TMP/big"
  OFFLOAD_MAX_CHARS=100 run "$OFFLOAD" ask "x" "$TEST_TMP/big"
  [ "$status" -eq 2 ]
  [[ "$output" == *"input is 500 chars, limit 100"* ]]
  [ ! -s "$OFFLOAD_TEST_LOG" ]
}

@test "instruction with quotes, dollar and backslash reaches the provider verbatim" {
  scenario api.groq.com 200 "$(ok_body ok)"
  run "$OFFLOAD" ask 'say "hi" $HOME \ done'
  [ "$status" -eq 0 ]
  [ "$(body_jq '.messages[0].content')" = 'say "hi" $HOME \ done' ]
}

@test "empty content falls back to reasoning_content" {
  scenario api.groq.com 200 '{"choices":[{"message":{"content":"","reasoning_content":"thought answer"}}]}'
  run --separate-stderr "$OFFLOAD" ask "x"
  [ "$status" -eq 0 ]
  [ "$output" = "thought answer" ]
}

@test "key never appears in output on error" {
  scenario api.groq.com 401 '{"error":{"message":"bad key"}}'
  scenario integrate.api.nvidia.com 401 '{"error":{"message":"bad"}}'
  GROQ_API_KEY=gsk_hidden run "$OFFLOAD" ask "x"
  [ "$status" -eq 1 ]
  [[ "$output" != *gsk_hidden* ]]
}

# --- routing, fallback, fuse ---

@test "small input goes to groq first" {
  scenario api.groq.com 200 "$(ok_body ok)"
  run "$OFFLOAD" ask "x"
  [ "$(log_hosts | head -1)" = api.groq.com ]
}

@test "large input goes to nvidia first" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  head -c 20001 /dev/zero | tr '\0' a > "$TEST_TMP/big"
  run "$OFFLOAD" ask "x" "$TEST_TMP/big"
  [ "$status" -eq 0 ]
  [ "$(log_hosts | head -1)" = integrate.api.nvidia.com ]
}

@test "OFFLOAD_SMALL_LIMIT moves the boundary" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  printf 'ab' > "$TEST_TMP/two"
  OFFLOAD_SMALL_LIMIT=1 run "$OFFLOAD" ask "x" "$TEST_TMP/two"
  [ "$(log_hosts | head -1)" = integrate.api.nvidia.com ]
}

@test "groq 429 falls through to nvidia and reports the failure" {
  scenario api.groq.com 429 '{"error":{"message":"rate limited"}}'
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  run --separate-stderr "$OFFLOAD" ask "x"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [[ "$stderr" == *"[groq] 429: rate limited"* ]]
  [[ "$stderr" == *"[nvidia nvidia/nemotron-3.5-lightning-30b-a3b]"* ]]
  [ ! -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "timeout counts as availability failure and falls through" {
  scenario api.groq.com 200 "$(ok_body late)" 3
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  OFFLOAD_TIMEOUT=1 run --separate-stderr "$OFFLOAD" ask "x"
  [ "$output" = ok ]
  [[ "$stderr" == *"[groq] curl:28"* ]]
}

@test "all providers down writes the marker and exits 1" {
  scenario api.groq.com 503 '{}'
  scenario integrate.api.nvidia.com 500 '{}'
  run "$OFFLOAD" ask "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"all providers failed"* ]]
  [ -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "client-only failures do not write the marker" {
  scenario api.groq.com 413 '{"error":{"message":"too large"}}'
  scenario integrate.api.nvidia.com 400 '{}'
  run "$OFFLOAD" ask "x"
  [ "$status" -eq 1 ]
  [ ! -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "mixed failures with one availability failure write the marker" {
  scenario api.groq.com 413 '{}'
  scenario integrate.api.nvidia.com 502 '{}'
  run "$OFFLOAD" ask "x"
  [ "$status" -eq 1 ]
  [ -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "success removes an existing marker" {
  mkdir -p "$XDG_CACHE_HOME/offload"
  touch "$XDG_CACHE_HOME/offload/down"
  scenario api.groq.com 200 "$(ok_body ok)"
  run "$OFFLOAD" ask "x"
  [ ! -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "200 without choices is a client failure" {
  scenario api.groq.com 200 '{"error":"oops"}'
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  run --separate-stderr "$OFFLOAD" ask "x"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ ! -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "-p restricts to one provider and -m overrides the model" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  run --separate-stderr "$OFFLOAD" ask -p nvidia -m mistralai/mistral-large "x"
  [ "$status" -eq 0 ]
  [ "$(log_hosts)" = integrate.api.nvidia.com ]
  grep -q '|mistralai/mistral-large|' "$OFFLOAD_TEST_LOG"
  [[ "$stderr" == *"[nvidia mistralai/mistral-large]"* ]]
}

@test "-p unknown is a usage error" {
  run "$OFFLOAD" ask -p nope "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown provider"* ]]
}

@test "OFFLOAD_PROVIDERS sets the order" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  OFFLOAD_PROVIDERS="nvidia groq" run "$OFFLOAD" ask "x"
  [ "$(log_hosts | head -1)" = integrate.api.nvidia.com ]
}

@test "provider without key is skipped with a note" {
  unset NVIDIA_API_KEY
  scenario api.groq.com 200 "$(ok_body ok)"
  OFFLOAD_PROVIDERS="nvidia groq" run --separate-stderr "$OFFLOAD" ask "x"
  [ "$output" = ok ]
  [[ "$stderr" == *"[nvidia] no key (NVIDIA_API_KEY)"* ]]
  [ "$(log_hosts)" = api.groq.com ]
}

@test "nvidia body disables thinking by default and OFFLOAD_NVIDIA_EXTRA overrides" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  run "$OFFLOAD" ask -p nvidia "x"
  [ "$(body_jq '.chat_template_kwargs.enable_thinking')" = false ]
  OFFLOAD_NVIDIA_EXTRA='{}' run "$OFFLOAD" ask -p nvidia "x"
  [ "$(body_jq '.chat_template_kwargs')" = null ]
}

@test "OFFLOAD_GROQ_MODEL overrides the default everywhere" {
  scenario api.groq.com 200 "$(ok_body ok)"
  OFFLOAD_GROQ_MODEL=qwen/qwen3.8-27b run --separate-stderr "$OFFLOAD" ask "x"
  grep -q '|qwen/qwen3.8-27b|' "$OFFLOAD_TEST_LOG"
  [[ "$stderr" == *"[groq qwen/qwen3.8-27b]"* ]]
  OFFLOAD_GROQ_MODEL=qwen/qwen3.8-27b run "$OFFLOAD" providers
  [[ "${lines[0]}" == *qwen/qwen3.8-27b* ]]
}

@test "body never carries max_tokens" {
  scenario api.groq.com 200 "$(ok_body ok)"
  run "$OFFLOAD" ask "x"
  [ "$(body_jq '.max_tokens')" = null ]
}

# --- review fixes ---

@test "1.2M-char input is sent whole when OFFLOAD_MAX_CHARS allows it" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  head -c 1200000 /dev/zero | tr '\0' a > "$TEST_TMP/huge"
  OFFLOAD_MAX_CHARS=2000000 run --separate-stderr "$OFFLOAD" ask "x" "$TEST_TMP/huge"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  grep -q '^integrate.api.nvidia.com|[^|]*|1200000|' "$OFFLOAD_TEST_LOG"
}

@test "exec errors never open the fuse" {
  scenario api.groq.com exit:126 ''
  scenario integrate.api.nvidia.com exit:127 ''
  run "$OFFLOAD" ask "x"
  [ "$status" -eq 1 ]
  [ ! -e "$XDG_CACHE_HOME/offload/down" ]
}

@test "stdout ends with exactly one newline" {
  scenario api.groq.com 200 "$(ok_body Madrid)"
  raw=$("$OFFLOAD" ask "x" 2>/dev/null; printf x)
  [ "$raw" = "$(printf 'Madrid\nx')" ]
}

@test "non-JSON error body is shown in the failure line" {
  scenario api.groq.com 502 '<html>bad gateway</html>'
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  run --separate-stderr "$OFFLOAD" ask "x"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[groq] 502: <html>bad gateway</html>"* ]]
}

@test "transport errors are described in words" {
  scenario integrate.api.nvidia.com 200 "$(ok_body ok)"
  run --separate-stderr "$OFFLOAD" ask "x"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[groq] curl:7: connection failed"* ]]
}

@test "a directory as input is a usage error" {
  run "$OFFLOAD" ask "x" "$TEST_TMP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
}

# --- redaction ---

@test "secrets in the input never reach the provider" {
  scenario api.groq.com 200 "$(ok_body ok)"
  tok="ghp_$(rnd 36)"
  printf 'log line token %s\npassword=hunter2hunter2\n' "$tok" > "$TEST_TMP/in"
  run --separate-stderr "$OFFLOAD" ask "Summarize" "$TEST_TMP/in"
  [ "$status" -eq 0 ]
  ! grep -q "$tok" "$OFFLOAD_TEST_LOG.body"
  ! grep -q hunter2 "$OFFLOAD_TEST_LOG.body"
  grep -q 'REDACTED:github-pat' "$OFFLOAD_TEST_LOG.body"
  [[ "$stderr" == *"[redact] masked 2"* ]]
}

@test "secrets in the instruction are masked too" {
  scenario api.groq.com 200 "$(ok_body ok)"
  run "$OFFLOAD" ask "Is password=hunter2hunter2 strong?"
  [ "$(body_jq '.messages[0].content')" = "Is password=[REDACTED:secret-assignment] strong?" ]
}

@test "OFFLOAD_REDACT=block refuses with exit 3 and sends nothing" {
  scenario api.groq.com 200 "$(ok_body ok)"
  printf 'password=hunter2hunter2\n' > "$TEST_TMP/in"
  OFFLOAD_REDACT=block run "$OFFLOAD" ask "x" "$TEST_TMP/in"
  [ "$status" -eq 3 ]
  [[ "$output" == *"secret-assignment x1"* ]]
  [ ! -s "$OFFLOAD_TEST_LOG" ]
}

@test "OFFLOAD_REDACT=block sends clean input" {
  scenario api.groq.com 200 "$(ok_body ok)"
  printf 'just a log line\n' > "$TEST_TMP/in"
  OFFLOAD_REDACT=block run "$OFFLOAD" ask "x" "$TEST_TMP/in"
  [ "$status" -eq 0 ]
}

@test "OFFLOAD_REDACT=off sends the input as is" {
  scenario api.groq.com 200 "$(ok_body ok)"
  printf 'password=hunter2hunter2\n' > "$TEST_TMP/in"
  OFFLOAD_REDACT=off run --separate-stderr "$OFFLOAD" ask "x" "$TEST_TMP/in"
  grep -q hunter2hunter2 "$OFFLOAD_TEST_LOG.body"
  [[ "$stderr" != *"[redact]"* ]]
}

@test "an unknown OFFLOAD_REDACT value is a usage error" {
  OFFLOAD_REDACT=maybe run "$OFFLOAD" ask "x"
  [ "$status" -eq 2 ]
}
