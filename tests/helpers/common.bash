# Shared bats helpers for claude-offload.
bats_require_minimum_version 1.5.0

setup_common() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP
  export HOME="$TEST_TMP/home"
  export XDG_CACHE_HOME="$TEST_TMP/cache"
  mkdir -p "$HOME"
  export PATH="$BATS_TEST_DIRNAME/helpers/bin:$PATH"
  export OFFLOAD="$BATS_TEST_DIRNAME/../bin/offload"
  export OFFLOAD_TEST_LOG="$TEST_TMP/curl.log"
  export OFFLOAD_TEST_SCENARIO="$TEST_TMP/scenario"
  : > "$OFFLOAD_TEST_LOG"
  : > "$OFFLOAD_TEST_SCENARIO"
  unset GROQ_API_KEY NVIDIA_API_KEY CEREBRAS_API_KEY
  unset OFFLOAD_PROVIDERS OFFLOAD_TIMEOUT OFFLOAD_SMALL_LIMIT OFFLOAD_MAX_CHARS OFFLOAD_ENV_FILE
  unset OFFLOAD_GROQ_MODEL OFFLOAD_NVIDIA_MODEL OFFLOAD_CEREBRAS_MODEL
  unset OFFLOAD_GROQ_EXTRA OFFLOAD_NVIDIA_EXTRA OFFLOAD_CEREBRAS_EXTRA
  unset OFFLOAD_GATE OFFLOAD_GATE_LINES OFFLOAD_GATE_EXT OFFLOAD_GATE_FUSE
}

teardown_common() {
  [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# scenario HOST CODE BODY [DELAY]: the curl shim answers requests whose URL
# contains HOST with HTTP CODE and BODY, after sleeping DELAY seconds.
scenario() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-0}" >> "$OFFLOAD_TEST_SCENARIO"
}

# ok_body TEXT: a minimal chat-completion body whose content is TEXT.
ok_body() {
  jq -cn --arg c "$1" '{choices:[{message:{content:$c}}]}'
}

# log_hosts: the host column of the shim call log, in call order.
log_hosts() {
  cut -d'|' -f1 "$OFFLOAD_TEST_LOG"
}
