# redact.jq — mask secrets (and optionally PII) in text before it leaves the machine.
#
# Input:  null (use -n). Args: --rawfile text FILE, --argjson pii true|false,
#         --slurpfile gitleaks REPORT (a gitleaks JSON report, or [[]] for none).
# Output: {"text": <masked text>, "counts": {"<rule-id>": n, ...}}
#
# Every match is replaced with "[REDACTED:<rule-id>]". Token patterns follow the
# gitleaks default ruleset (https://github.com/gitleaks/gitleaks, MIT License,
# Copyright (c) 2019 Zachary Rice); the high-entropy threshold follows
# detect-secrets (Base64HighEntropyString, limit 4.5).

def tag($id): "[REDACTED:" + $id + "]";

# Shannon entropy in bits per character.
def entropy:
  explode | length as $n
  | if $n == 0 then 0
    else group_by(.) | map(length / $n | -(. * log2)) | add end;

# Values that are references or placeholders, not secrets.
def placeholder:
  test("^(\\$\\{.*\\}|\\$[A-Za-z_][A-Za-z0-9_]*|<[^>]*>|\\*+|[xX.]+|[0-9]+|change_?me|redacted|null|none|nil|true|false|undefined|example|your[_-].*|xxx.*|\\{\\{.*\\}\\})$"; "i");

# Whole-match rules: regex -> rule id. Order matters: specific before generic.
def token_rules: [
  ["private-key", "(?i)-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----(?>(?:(?!-----END)[\\s\\S]){16,})-----END[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----"],
  ["aws-access-token", "\\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}\\b"],
  ["github-fine-grained-pat", "\\bgithub_pat_\\w{82}"],
  ["github-pat", "\\bghp_[0-9a-zA-Z]{36}\\b"],
  ["github-oauth", "\\bgho_[0-9a-zA-Z]{36}\\b"],
  ["github-app-token", "\\b(?:ghu|ghs)_[0-9a-zA-Z]{36}\\b"],
  ["github-refresh-token", "\\bghr_[0-9a-zA-Z]{36}\\b"],
  ["gitlab-pat", "\\bglpat-[\\w-]{20,}"],
  ["gitlab-runner-token", "\\bglrt-[\\w-]{20,}"],
  ["gitlab-deploy-token", "\\bgldt-[\\w-]{20,}"],
  ["slack-bot-token", "\\bxoxb-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*"],
  ["slack-user-token", "\\bxox[pe](?:-[0-9]{10,13}){3}-[a-zA-Z0-9-]{28,34}"],
  ["slack-app-token", "(?i)\\bxapp-\\d-[A-Z0-9]+-\\d+-[a-z0-9]+"],
  ["slack-webhook-url", "(?:https?://)?hooks\\.slack\\.com/(?:services|workflows|triggers)/[A-Za-z0-9+/]{43,56}"],
  ["stripe-access-token", "\\b(?:sk|rk)_(?:test|live|prod)_[a-zA-Z0-9]{10,99}\\b"],
  ["anthropic-api-key", "\\bsk-ant-(?:api03|admin01)-[\\w-]{93}AA(?![\\w-])"],
  ["openai-api-key", "\\bsk-(?:proj|svcacct|admin)-[\\w-]{20,}|\\bsk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20}\\b"],
  ["groq-api-key", "\\bgsk_[A-Za-z0-9]{40,}\\b"],
  ["nvidia-api-key", "\\bnvapi-[\\w-]{40,}"],
  ["cerebras-api-key", "\\bcsk-[a-z0-9]{40,}\\b"],
  ["gcp-api-key", "\\bAIza[\\w-]{35}(?![\\w-])"],
  ["npm-access-token", "\\bnpm_[A-Za-z0-9]{36}\\b"],
  ["sendgrid-api-token", "\\bSG\\.[\\w-]{22}\\.[\\w-]{43}(?![\\w-])"],
  ["telegram-bot-token", "\\b[0-9]{8,10}:AA[A-Za-z0-9_-]{33}(?![\\w-])"],
  ["yandex-iam-token", "\\bt1\\.[A-Za-z0-9_-]+=*\\.[A-Za-z0-9_-]{86}=*"],
  ["yandex-api-key", "\\bAQVN[A-Za-z0-9_-]{35,38}(?![\\w-])"],
  ["yandex-oauth-token", "\\by0_[A-Za-z0-9_-]{50,}"],
  ["jwt", "\\bey[A-Za-z0-9_-]{17,}\\.ey[A-Za-z0-9/\\\\_-]{17,}\\.(?:[A-Za-z0-9/\\\\_-]{10,}={0,2})?"]
];

def apply_tokens:
  reduce token_rules[] as $r (.; gsub($r[1]; tag($r[0])));

# Values that are names, not secrets: lowercase dotted names such as
# rbac.authorization.k8s.io or networking.k8s.io/v1.
def dotted_name:
  test("^[a-z0-9-]+(\\.[a-z0-9-]+)+(/[a-z0-9.-]+)*$");

# Values built from dictionary-like words and short numbers, such as
# Serilog__WriteTo__1__Args__facility: configuration key names, not secrets.
def identifier_name:
  split("[_.-]+"; null) | map(select(. != ""))
  | all(test("^([A-Z]?[a-z]{2,}([A-Z][a-z]+)*|[A-Z]{2,5}|[0-9]{1,3})$"))
    and (length > 1 or (.[0] | test("^[A-Z][a-z]+([A-Z][a-z]+)+$")));

# Hex values under checksum/digest/hash keys are integrity hashes, not secrets.
# They get an invisible marker so no rule matches them, and lose it at the end.
def digest_marker: "\ue000\ue001";
def protect_digests:
  gsub("(?<p>(?i)(?:checksum|digest|hash|sha(?:1|256|512)?|fingerprint)[\\w./-]{0,40}[\"']?\\s*[:=]\\s*[\"']?)(?<s>[0-9a-fA-F]{32,128}\\b)";
       .p + digest_marker + .s);
def unprotect_digests: gsub(digest_marker; "");

# Rules that keep a prefix (?<p>...) and mask only the secret (?<s>...).
def mask_value($id; $re; $min_entropy):
  gsub($re; if (.s | placeholder) or (.s | startswith(digest_marker))
               or ((.s | entropy) < $min_entropy)
            then .p + .s else .p + tag($id) end);

# Like mask_value, for keyword rules where the value may be a name or a hash.
def mask_keyed($id; $re; $min_entropy):
  gsub($re; if (.s | placeholder) or (.s | dotted_name) or (.s | identifier_name)
               or ((.s | entropy) < $min_entropy)
            then .p + .s else .p + tag($id) end);

def apply_contextual:
  # user:password@host in URLs
  mask_value("url-password"; "(?<p>\\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s:/@\\[\\]]+:)(?<s>[^\\s@/\\[\\]]+)(?=@)"; 0)
  # Authorization: Bearer|Basic|Token <value>
  | mask_value("authorization-header"; "(?<p>(?i)\\bauthorization[\"']?\\s*[:=]\\s*[\"']?(?:bearer|basic|token)\\s+)(?<s>[A-Za-z0-9._~+/=-]{8,})"; 0)
  # password = ..., api_key: "...", CLIENT_SECRET=... — masked regardless of entropy
  | mask_value("secret-assignment"; "(?<p>(?i)\\b[\\w.-]{0,40}?(?:passw(?:or)?d|passwd|pwd|secret|token|api[_-]?key|apikey|private[_-]?key|access[_-]?key)[\\w.-]{0,20}[\"']?[ \\t]*(?:=|:)[ \\t]*[\"']?)(?<s>[^\\s\"'`,;\\[\\]<>{}()]{6,})"; 0)
  # gitleaks generic-api-key: weaker keywords, needs entropy >= 3.5. The match
  # starts at the keyword (gitleaks also matches up to 50 chars before it; that
  # prefix is never masked and costs O(n*50) backtracking).
  | mask_keyed("generic-api-key"; "(?<p>(?i)(?:access|auth|(?-i:[Aa]pi|API)|credential|creds|key|passw(?:or)?d|secret|token)(?:[ \\t\\w.-]{0,20})[ \\t'\"]{0,3}(?:=|>|:{1,3}=|\\|\\||:|=>|\\?=|,)[`'\" \\t=]{0,5})(?<s>[\\w.=-]{10,150}|[a-z0-9][a-z0-9+/]{11,}={0,3})(?=[`'\"\\s;]|\\\\[nr]|$)"; 3.5)
  # detect-secrets Base64HighEntropyString: long base64 runs with entropy >= 4.5
  | mask_value("high-entropy-base64"; "(?<p>)(?<![A-Za-z0-9+/=_-])(?<s>[A-Za-z0-9+/_-]{40,}={0,2})(?![A-Za-z0-9+/=_-])"; 4.5);

def luhn:
  [explode[] | select(. >= 48 and . <= 57) | . - 48] | reverse
  | to_entries
  | map(if .key % 2 == 1 then (.value * 2 | if . > 9 then . - 9 else . end) else .value end)
  | add % 10 == 0;

def apply_pii:
  gsub("\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b"; tag("email"))
  | gsub("(?<c>\\b(?:\\d[ -]?){12,18}\\d\\b)"; if (.c | luhn) then tag("credit-card") else .c end);

# Literal replacement of gitleaks findings, longest secret first.
def apply_gitleaks($findings):
  reduce ($findings | map(select((.Secret // "") | length >= 4))
          | sort_by(.Secret | length) | reverse)[] as $f
    (.; split($f.Secret) | join(tag($f.RuleID // "gitleaks")));

def count_tags: [scan("\\[REDACTED:([A-Za-z0-9_.-]+)\\]") | .[0]];

($text | count_tags) as $before
| $text
| apply_gitleaks(($gitleaks[0] // []) | if type == "array" then . else [] end)
| apply_tokens
| protect_digests
| apply_contextual
| if $pii then apply_pii else . end
| unprotect_digests
| . as $out
| ($out | count_tags) as $after
| {text: $out,
   counts: (reduce $after[] as $id ({}; .[$id] += 1)
            | reduce $before[] as $id (.; .[$id] -= 1)
            | with_entries(select(.value > 0)))}
