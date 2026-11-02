load helpers/common
setup() { setup_common; }
teardown() { teardown_common; }

# redact TEXT: run `offload redact -` on TEXT; output = redacted text.
redact() { printf '%s' "$1" | "$OFFLOAD" redact - ; }

@test "AWS access key id is masked" {
  k="AKIA$(rnd 16 A-Z2-7)"
  run --separate-stderr redact "id=$k end"
  [ "$status" -eq 0 ]
  [ "$output" = "id=[REDACTED:aws-access-token] end" ]
  [[ "$stderr" == *"aws-access-token x1"* ]]
  [[ "$stderr" != *"$k"* ]]
}

@test "GitHub, GitLab, Slack, Stripe, npm and Google tokens are masked" {
  t1="ghp_$(rnd 36)"; t2="github_pat_$(rnd 82 A-Za-z0-9_)"; t3="glpat-$(rnd 20)"
  t4="xoxb-$(rnd 11 0-9)-$(rnd 12 0-9)-$(rnd 24)"; t5="sk_live_$(rnd 30)"
  t6="npm_$(rnd 36 a-z0-9)"; t7="AIza$(rnd 35)"; t8="glrt-$(rnd 20)"
  run --separate-stderr redact "$t1 $t2 $t3 $t4 $t5 $t6 $t7 $t8 ."
  [ "$output" = "[REDACTED:github-pat] [REDACTED:github-fine-grained-pat] [REDACTED:gitlab-pat] [REDACTED:slack-bot-token] [REDACTED:stripe-access-token] [REDACTED:npm-access-token] [REDACTED:gcp-api-key] [REDACTED:gitlab-runner-token] ." ]
}

@test "LLM provider keys are masked" {
  run --separate-stderr redact "a sk-ant-api03-$(rnd 93 A-Za-z0-9_-)AA b gsk_$(rnd 52) c nvapi-$(rnd 64 A-Za-z0-9_-) d sk-proj-$(rnd 48 A-Za-z0-9_-) e"
  [ "$output" = "a [REDACTED:anthropic-api-key] b [REDACTED:groq-api-key] c [REDACTED:nvidia-api-key] d [REDACTED:openai-api-key] e" ]
}

@test "Yandex Cloud IAM token, API key and OAuth token are masked" {
  run --separate-stderr redact "iam t1.$(rnd 20).$(rnd 86 A-Za-z0-9_-) key AQVN$(rnd 36) oauth y0_$(rnd 55 A-Za-z0-9_-) end"
  [ "$output" = "iam [REDACTED:yandex-iam-token] key [REDACTED:yandex-api-key] oauth [REDACTED:yandex-oauth-token] end" ]
}

@test "JWT is masked" {
  run --separate-stderr redact "Cookie: s=eyJ$(rnd 30).eyJ$(rnd 40).$(rnd 43 A-Za-z0-9_-); path=/"
  [ "$output" = "Cookie: s=[REDACTED:jwt]; path=/" ]
}

@test "private key block is masked whole" {
  key=$(printf -- '-----BEGIN RSA PRIVATE KEY-----\n%s\n%s\n-----END RSA PRIVATE KEY-----' "$(rnd 64)" "$(rnd 64)")
  run --separate-stderr redact "before
$key
after"
  [ "$output" = "before
[REDACTED:private-key]
after" ]
}

@test "password in a URL is masked, user and host kept" {
  run --separate-stderr redact "dsn=postgres://app:$(rnd 12)@db.local:5432/main"
  [ "$output" = "dsn=postgres://app:[REDACTED:url-password]@db.local:5432/main" ]
}

@test "Authorization header value is masked" {
  run --separate-stderr redact "Authorization: Bearer $(rnd 40 A-Za-z0-9._-)
authorization: Basic $(rnd 24)=="
  [ "$output" = "Authorization: Bearer [REDACTED:authorization-header]
authorization: Basic [REDACTED:authorization-header]" ]
}

@test "password-like assignments are masked even with low entropy" {
  run --separate-stderr redact 'DB_PASSWORD=hunter2hunter2
password: "qwerty123"
client_secret = abcabcabc
"api_key": "aaaaaaaa1"'
  [ "$output" = 'DB_PASSWORD=[REDACTED:secret-assignment]
password: "[REDACTED:secret-assignment]"
client_secret = [REDACTED:secret-assignment]
"api_key": "[REDACTED:secret-assignment]"' ]
}

@test "placeholders and references are not masked" {
  input='password=${DB_PASSWORD}
password: <your-password>
token: ****
secret=$SECRET_VALUE
password: changeme
token_count=12'
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
}

@test "high-entropy value next to a weak keyword is masked, low-entropy is not" {
  run --separate-stderr redact "auth_header_value=$(rnd 32) access_level=readonly_users"
  [ "$output" = "auth_header_value=[REDACTED:generic-api-key] access_level=readonly_users" ]
}

@test "long high-entropy base64 is masked; hex digests, UUIDs and git SHAs are not" {
  b64=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
  sha=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  input="data: $b64
image: nginx@sha256:$sha
id 3f2504e0-4f89-41d3-9a0c-0305e82c3301 commit 9fceb02d0ae598e95dc970b74767f19372d61af8"
  run --separate-stderr redact "$input"
  [ "$output" = "data: [REDACTED:high-entropy-base64]
image: nginx@sha256:$sha
id 3f2504e0-4f89-41d3-9a0c-0305e82c3301 commit 9fceb02d0ae598e95dc970b74767f19372d61af8" ]
}

@test "Kubernetes Secret data values are masked" {
  run --separate-stderr redact "apiVersion: v1
kind: Secret
data:
  password: $(printf 'S3cr3t-%s' "$(rnd 10)" | base64)
  username: YWRtaW4="
  [[ "$output" == *"password: [REDACTED:"* ]]
  [[ "$output" == *"username: YWRtaW4="* ]]
}

@test "plain log lines pass through untouched" {
  input='2026-11-01T22:13:38Z INFO request id=42 path=/api/v1/users status=200 took=12ms
E1101 kubelet.go:2412] "Error syncing pod" pod="default/api-7d9f8b6c5-x2x9q"'
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
  [ -z "$stderr" ]
}

@test "the report counts per rule and never contains a secret" {
  a="ghp_$(rnd 36)"; b="ghp_$(rnd 36)"
  run --separate-stderr redact "$a $b password=hunter2hunter2"
  [[ "$stderr" == *"[redact] masked 3: github-pat x2, secret-assignment x1"* ]]
  [[ "$stderr" != *"$a"* ]]
  [[ "$stderr" != *hunter2* ]]
}

@test "PII is kept by default and masked with OFFLOAD_REDACT_PII=1" {
  input="mail ops@example.com card 4111 1111 1111 1111 bad 4111 1111 1111 1112"
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
  OFFLOAD_REDACT_PII=1 run --separate-stderr redact "$input"
  [ "$output" = "mail [REDACTED:email] card [REDACTED:credit-card] bad 4111 1111 1111 1112" ]
}

@test "redact reads a file argument" {
  printf 'password=hunter2hunter2\n' > "$TEST_TMP/f"
  run --separate-stderr "$OFFLOAD" redact "$TEST_TMP/f"
  [ "$status" -eq 0 ]
  [ "$output" = "password=[REDACTED:secret-assignment]" ]
}

@test "400K characters are redacted in under 10 seconds" {
  { for i in $(seq 1 4000); do printf 'line %s user=%s ok\n' "$i" "$(printf '%080d' "$i")"; done; } > "$TEST_TMP/big"
  start=$(date +%s)
  run "$OFFLOAD" redact "$TEST_TMP/big"
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -lt 10 ]
}

# --- gitleaks integration ---

fake_gitleaks() {
  mkdir -p "$TEST_TMP/gl"
  cat > "$TEST_TMP/gl/gitleaks" <<'SH'
#!/usr/bin/env bash
# Fake gitleaks: report every "CUSTOM-" word as a finding of rule custom-rule.
report=""
while [ $# -gt 0 ]; do case "$1" in --report-path|-r) report=$2; shift 2 ;; *) shift ;; esac; done
[ -n "${FAKE_GITLEAKS_FAIL:-}" ] && exit 9
grep -oE 'CUSTOM-[A-Za-z0-9]+' | jq -R '{RuleID: "custom-rule", Secret: .}' | jq -s . > "$report"
exit 0
SH
  chmod +x "$TEST_TMP/gl/gitleaks"
  export PATH="$TEST_TMP/gl:$PATH"
}

@test "gitleaks findings are masked when gitleaks is installed" {
  fake_gitleaks
  run --separate-stderr redact "a CUSTOM-abc123 b"
  [ "$output" = "a [REDACTED:custom-rule] b" ]
  [[ "$stderr" == *"custom-rule x1"* ]]
}

@test "OFFLOAD_GITLEAKS=0 skips gitleaks" {
  fake_gitleaks
  OFFLOAD_GITLEAKS=0 run --separate-stderr redact "a CUSTOM-abc123 b"
  [ "$output" = "a CUSTOM-abc123 b" ]
}

@test "a failing gitleaks warns and the built-in rules still apply" {
  fake_gitleaks
  FAKE_GITLEAKS_FAIL=1 run --separate-stderr redact "a CUSTOM-abc123 password=hunter2hunter2"
  [ "$status" -eq 0 ]
  [ "$output" = "a CUSTOM-abc123 password=[REDACTED:secret-assignment]" ]
  [[ "$stderr" == *"gitleaks failed"* ]]
}

@test "Kubernetes apiGroup and other dotted names are not masked" {
  input='- apiGroup: rbac.authorization.k8s.io
  apiVersion: networking.k8s.io/v1
  authority: auth.example.internal'
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
}

@test "checksum, hash and digest values are not masked" {
  sha=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  input="checksum/kerberos-keytab: $sha
config-hash-key: $sha
apikey_digest=$sha"
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
}

@test "identifier-shaped key names are not masked" {
  input="          configMapKeyRef:
            key: Serilog__WriteTo__1__Args__facility
            key: ConnectionStrings__DefaultConnection
            key: app.kubernetes.io_component-name
            key: SerilogWriteToGrayLogTransportType"
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
}

@test "a keyword at the end of a line does not mask the next line" {
  input="        - serviceAccountToken:
            expirationSeconds: 3607
            path: token"
  run --separate-stderr redact "$input"
  [ "$output" = "$input" ]
}

@test "an unterminated or short key header does not break the engine" {
  input="  key=\$(printf -- '-----BEGIN RSA PRIVATE KEY-----\\n%s\\n%s\\n-----END RSA PRIVATE KEY-----' a b)
$(for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "line $i: postgres://app:[x]@db.local:5432/main [REDACTED:url-password]"; done)
-----BEGIN OPENSSH PRIVATE KEY-----
$(rnd 300)"
  run --separate-stderr redact "$input"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 15 ]
  [ "${lines[0]}" = "${input%%$'\n'*}" ]
}
