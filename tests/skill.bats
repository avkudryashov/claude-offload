load helpers/common
setup() { setup_common; SKILL=$BATS_TEST_DIRNAME/../skill/SKILL.md; }
teardown() { teardown_common; }

frontmatter() { awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f' "$SKILL"; }
body() { awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {f=0; b=1; next} b' "$SKILL"; }

@test "skill is named offload" {
  [ -f "$SKILL" ]
  frontmatter | grep -q '^name: offload$'
}

@test "description carries trigger phrases and the negative rule" {
  d=$(frontmatter | grep '^description:')
  [[ "$d" == *"summarize this log"* ]]
  [[ "$d" == *"transcribe"* ]]
  [[ "$d" == *"not for decisions"* ]]
}

@test "body documents the commands and the escape hatch" {
  b=$(body)
  [[ "$b" == *"offload ask"* ]]
  [[ "$b" == *"offload transcribe"* ]]
  [[ "$b" == *"offload doctor"* ]]
  [[ "$b" == *"offset/limit"* ]]
  [[ "$b" == *"answer language"* ]]
  [[ "$b" == *"secrets"* ]]
}

@test "body stays short" {
  [ "$(body | wc -l | tr -d ' ')" -le 40 ]
}
