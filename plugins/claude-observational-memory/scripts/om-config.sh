# om-config.sh — shared config and helpers for claude-observational-memory.
# Source this file from other scripts:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/om-config.sh"
# It also works when run standalone (sets CLAUDE_PLUGIN_ROOT fallback).

# Fallback so scripts remain testable outside a Claude Code hook context.
: "${CLAUDE_PLUGIN_ROOT:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

: "${OM_DIR:="${HOME}/.local/share/claude-observational-memory"}"
: "${OM_SESSIONS_DIR:="${OM_DIR}/sessions"}"
: "${OM_CONFIG:="${OM_DIR}/config.json"}"
: "${OM_LOG:="${OM_DIR}/debug/om.log"}"
: "${OM_LAST_INJECTED:="${OM_DIR}/last-injected.md"}"
: "${OM_RETENTION_MARKER:="${OM_DIR}/retention_last_run"}"

# om_config_get <key> [default] — prints a config value. Precedence: env var
# override > config.json > default. The env var name is derived from the key
# (camelCase -> OM_UPPER_SNAKE_CASE), e.g. observeAfterTokens ->
# OM_OBSERVE_AFTER_TOKENS. Set these in .claude/settings.json's `env` block —
# the same override mechanism Claude Code itself documents for
# CLAUDE_CODE_AUTO_COMPACT_WINDOW — instead of hand-editing config.json.
# Note: use has($k) so a boolean false is returned as "false", not treated as absent
# (jq's `//` operator would otherwise treat false like null).
om_config_get() {
  local key="$1" default="${2:-}"
  local env_name
  env_name="OM_$(printf '%s' "$key" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!env_name:-}" ]; then
    printf '%s' "${!env_name}"
    return 0
  fi
  [ -f "${OM_CONFIG}" ] || { printf '%s' "$default"; return 0; }
  local raw
  raw=$(jq -r --arg k "$key" 'if has($k) then (.[$k] | tostring) else "__OM_ABSENT__" end' "${OM_CONFIG}" 2>/dev/null)
  if [ -z "$raw" ] || [ "$raw" = "__OM_ABSENT__" ] || [ "$raw" = "null" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$raw"
  fi
}

# om_config_init — ensure data dir and default config exist. Per-session
# storage is created lazily by om_session_init, not here.
om_config_init() {
  mkdir -p "${OM_DIR}" "${OM_DIR}/debug" "${OM_SESSIONS_DIR}"
  if [ ! -f "${OM_CONFIG}" ]; then
    cat > "${OM_CONFIG}" <<'JSON'
{
  "observationsPoolMaxTokens": 8000,
  "observationsPoolTargetTokens": 4000,
  "observeAfterTokens": 5000,
  "reflectAfterTokens": 10000,
  "sessionRetentionDays": 30,
  "reflectOnPreCompact": true,
  "injectOnSessionStart": true
}
JSON
  fi
}

# --- Per-session storage paths. Every session gets its own directory, so
# observe/reflect/dropper/inject never need to filter a shared file by
# session_id — reading "this session's data" is just reading its own file.
# This also removes the read-modify-write race that a shared file would have
# between two concurrently running sessions. ---

om_session_dir() { printf '%s/%s' "${OM_SESSIONS_DIR}" "${1:-default}"; }
om_session_observations() { printf '%s/observations.jsonl' "$(om_session_dir "${1:-default}")"; }
om_session_reflections()  { printf '%s/reflections.jsonl'  "$(om_session_dir "${1:-default}")"; }
om_session_dropped()      { printf '%s/dropped.jsonl'      "$(om_session_dir "${1:-default}")"; }

# om_session_init <session_id> — ensure this session's directory/files exist,
# and stamp last_touch with the current epoch. last_touch is the activity
# signal om_run_retention_pass uses to decide if a session is dead — it's
# updated on every hook invocation (Stop/PreCompact/SessionStart) regardless
# of whether observe/reflect actually produced anything, so a low-activity
# but still-open session is never mistaken for an abandoned one.
om_session_init() {
  local sid="${1:-default}" dir
  dir=$(om_session_dir "$sid")
  mkdir -p "$dir" 2>/dev/null
  [ -f "${dir}/observations.jsonl" ] || : > "${dir}/observations.jsonl"
  [ -f "${dir}/reflections.jsonl" ] || : > "${dir}/reflections.jsonl"
  [ -f "${dir}/dropped.jsonl" ] || : > "${dir}/dropped.jsonl"
  date -u +%s > "${dir}/last_touch" 2>/dev/null || true
}

# om_log <msg...> — append a timestamped line to the debug log.
om_log() {
  mkdir -p "${OM_DIR}/debug"
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "${OM_LOG}" 2>/dev/null || true
}

# om_new_id — print a 12-char lowercase hex id (matches Pi OM id shape).
om_new_id() {
  openssl rand -hex 6 2>/dev/null \
    || head -c 6 /dev/urandom | xxd -p 2>/dev/null \
    || printf '%s' "$(date +%s%N | md5sum 2>/dev/null | cut -c1-12)" \
    || printf '%s' "$(date +%s)$RANDOM" | md5 2>/dev/null | cut -c1-12
}

# --- Per-session watermark state (how far observe/reflect have progressed
# through a session's transcript) ---

om_state_file() {
  printf '%s/state.json' "$(om_session_dir "${1:-default}")"
}

# om_state_get <session_id> <key> <default> — note: uses ${3-0}, not ${3:-0},
# so an explicitly passed empty string default (e.g. om_state_get sid k "")
# is preserved instead of being coerced to "0". Only a truly omitted third
# argument falls back to "0".
om_state_get() {
  local sid="$1" key="$2" default="${3-0}"
  local f
  f=$(om_state_file "$sid")
  if [ ! -f "$f" ]; then
    printf '%s' "$default"
    return 0
  fi
  local v
  v=$(jq -r --arg k "$key" 'if has($k) then (.[$k]|tostring) else "__OM_ABSENT__" end' "$f" 2>/dev/null)
  if [ -z "$v" ] || [ "$v" = "__OM_ABSENT__" ] || [ "$v" = "null" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$v"
  fi
}

# om_state_set <session_id> <key> <numeric value>
om_state_set() {
  local sid="$1" key="$2" value="$3"
  local f
  f=$(om_state_file "$sid")
  mkdir -p "$(dirname "$f")" 2>/dev/null
  local cur='{}'
  [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null || echo '{}')
  jq -n --argjson cur "$cur" --arg k "$key" --argjson v "$value" '$cur + {($k): $v}' \
    > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null || om_log "state: failed to write $f"
}

# om_usage_tokens_at_line <transcript_path> <line> — real context-size tokens
# (input + cache_creation + cache_read, i.e. total prompt size for that API
# call — not a delta to sum) as of the last assistant turn at or before <line>.
# Used to measure actual transcript growth instead of a chars/4 estimate.
# Prints 0 if <line> is 0 or no assistant turn exists yet in that range.
om_usage_tokens_at_line() {
  local transcript="$1" line="$2"
  [ "$line" -le 0 ] && { printf '0'; return 0; }
  local last_usage
  last_usage=$(head -n "$line" "$transcript" 2>/dev/null \
    | jq -c 'select(.type=="assistant") | .message.usage' 2>/dev/null | tail -1)
  [ -z "$last_usage" ] && { printf '0'; return 0; }
  printf '%s' "$last_usage" | jq -r \
    '((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' \
    2>/dev/null || printf '0'
}

# om_model_caps_file — per-"provider:model:effort" and per-"provider:model:schema"
# cache recording whether that provider:model accepts the configured
# reasoning_effort value / native response_format:json_schema, so a
# combination that gets rejected is only ever probed once, not on every call.
# The effort entries are only populated when llmReasoningEffort is explicitly
# set to low/medium/high — the default ("default"/unset) never sends the
# field, so there's nothing to probe. The schema entries record "object" once
# a provider:model has been observed to reject json_schema (see
# om_call_model_unified) — absent means "assume json_schema works, try it
# first".
om_model_caps_file() { printf '%s/model-caps.json' "${OM_DIR}"; }

om_model_caps_get() {
  local key="$1" f
  f=$(om_model_caps_file)
  [ -f "$f" ] || { printf ''; return 0; }
  jq -r --arg m "$key" '.[$m] // empty' "$f" 2>/dev/null
}

om_model_caps_set() {
  local key="$1" val="$2" f cur='{}'
  f=$(om_model_caps_file)
  [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null || echo '{}')
  jq -n --argjson cur "$cur" --arg m "$key" --arg v "$val" '$cur + {($m): $v}' \
    > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null || om_log "model-caps: failed to write $f"
}

# om_llm_base_url <provider> — resolves a short provider name to its
# OpenAI-compatible API base URL, so the user never has to know or type one.
# `llmBaseUrl` (if set) always wins, for self-hosted/custom deployments of a
# known provider or a provider not in this list.
om_llm_base_url() {
  case "$1" in
    openai)      printf 'https://api.openai.com/v1' ;;
    openrouter)  printf 'https://openrouter.ai/api/v1' ;;
    gemini)      printf 'https://generativelanguage.googleapis.com/v1beta/openai' ;;
    deepseek)    printf 'https://api.deepseek.com/v1' ;;
    ollama)      printf 'http://localhost:11434/v1' ;;
    opencode-go) printf 'https://opencode.ai/zen/go/v1' ;;
    *)           printf '' ;;
  esac
}

# om_llm_default_model <provider> — used only when `llmModel` is unset, so
# setting just `llmProvider` + `llmApiKey` works out of the box (override any
# entry any time via `llmModel`/`OM_LLM_MODEL`). `opencode-go` has no default:
# its model catalog is curated per-account (see `/models` in the opencode
# CLI), so `llmModel` must be set explicitly for that provider.
om_llm_default_model() {
  case "$1" in
    openai)     printf 'gpt-5.4-nano' ;;
    openrouter) printf 'meta-llama/llama-3.1-8b-instruct' ;;
    gemini)     printf 'gemini-3.1-flash-lite' ;;
    # deepseek-chat is deprecated 2026-07-24 in favor of deepseek-v4-flash
    # (same non-thinking model, renamed) — see api-docs.deepseek.com.
    deepseek)   printf 'deepseek-v4-flash' ;;
    ollama)     printf 'llama3.2' ;;
    *)          printf '' ;;
  esac
}

# om_chat_body <system> <user> <schema> <model> <max_tokens> <effort> <format>
# Builds an OpenAI-compatible /chat/completions request body. <effort> empty
# omits reasoning_effort entirely, for models that don't support thinking.
# <format> selects how <schema> (if any) is enforced: "schema" sends native
# response_format:json_schema,strict:true; "object" sends response_format:
# json_object instead, for providers that reject or silently ignore
# json_schema (see om_call_model_unified). Either way, whenever a schema is
# present its JSON text is also appended to the system prompt as a plain-text
# instruction — cheap, and the only signal a provider that ignores
# response_format entirely (e.g. Ollama's OpenAI-compat route) actually gets.
om_chat_body() {
  local system="$1" user="$2" schema="$3" model="$4" max_tokens="$5" effort="$6" format="$7"
  local sys_eff="$system"
  [ -n "$schema" ] && sys_eff="${system}

Respond with a single JSON object matching this schema, and nothing else: ${schema}"
  jq -n \
    --arg model "$model" --arg system "$sys_eff" --arg user "$user" \
    --argjson max_tokens "$max_tokens" --arg effort "$effort" --arg schema "$schema" --arg format "$format" \
    '{model: $model, max_tokens: $max_tokens,
      messages: [{role:"system", content:$system}, {role:"user", content:$user}]}
     + (if $effort != "" then {reasoning_effort: $effort} else {} end)
     + (if $schema != "" and $format == "schema" then
          {response_format: {type:"json_schema", json_schema: {name:"om_output", strict:true, schema:($schema|fromjson)}}}
        elif $schema != "" and $format == "object" then
          {response_format: {type:"json_object"}}
        else {} end)' 2>/dev/null || true
}

# om_chat_request <body> <base_url> <api_key> — one request/response round
# trip; prints the assistant's text content, or empty on any HTTP/parse
# failure (never surfaces status codes to the caller — see
# om_call_model_unified for how that empty result is interpreted). Reasoning
# models (e.g. deepseek-v4-flash) spend an unpredictable, sometimes large,
# share of max_tokens on internal chain-of-thought before ever emitting
# content — if that reasoning alone exhausts max_tokens, finish_reason comes
# back "length" with message.content empty. That's a truncation, not the
# model legitimately finding nothing to say, so it's logged distinctly
# instead of looking identical to a genuine empty result.
om_chat_request() {
  local body="$1" base_url="$2" api_key="$3"
  local resp content finish_reason
  # 25s, not the Stop hook's full 60s budget: the schema-fallback path in
  # om_call_model_unified can make two of these calls back to back, and both
  # need to fit inside that budget or the whole hook gets killed mid-flight.
  resp=$(curl -sS --max-time 25 "${base_url%/}/chat/completions" \
    -H "Authorization: Bearer ${api_key}" -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null || true)
  content=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
  if [ -z "$content" ]; then
    finish_reason=$(printf '%s' "$resp" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null || true)
    [ "$finish_reason" = "length" ] && om_log "model: response truncated (finish_reason=length) before any content was emitted — raise llmMaxTokens if this recurs"
  fi
  printf '%s' "$content"
}

# om_call_model_unified <system> <user> <schema> — generic OpenAI-compatible
# /chat/completions route. Resolves `llmProvider` (default "openai") to a
# base URL and default model internally, so the user only has to set
# llmProvider, llmModel (optional), and llmApiKey. `llmReasoningEffort`
# (default "default") controls reasoning_effort: "default" omits the field
# entirely so the model uses its own native default — no probing, zero
# overhead. "low"/"medium"/"high" sends that value and, if this provider:model
# hasn't already been cached as rejecting it, tries it first; on rejection,
# falls back to omitting the field and caches the outcome so future calls for
# the same provider:model:effort skip straight to the working shape.
#
# Structured output goes through the same probe-and-cache shape: native
# response_format:json_schema is tried first for any provider:model not
# already cached as rejecting it; on empty content, retries once with
# response_format:json_object (schema spelled out in the prompt text instead)
# and caches that so future calls for the same provider:model skip straight
# to it. Several "OpenAI-compatible" providers don't actually support
# json_schema on /chat/completions (DeepSeek only documents json_object;
# Ollama's OpenAI-compat route silently ignores json_schema rather than
# honoring or rejecting it; OpenRouter only passes it through for models that
# support it themselves) — this makes that a one-time cost per provider:model
# instead of a permanent silent failure.
om_call_model_unified() {
  local system="$1" user="$2" schema="$3"
  local provider model base_url api_key max_tokens effort cache_key caps body content
  local schema_mode schema_cache_key
  provider=$(om_config_get llmProvider "openai")
  model=$(om_config_get llmModel "")
  [ -n "$model" ] || model=$(om_llm_default_model "$provider")
  base_url=$(om_config_get llmBaseUrl "")
  [ -n "$base_url" ] || base_url=$(om_llm_base_url "$provider")
  api_key=$(om_config_get llmApiKey "")
  max_tokens=$(om_config_get llmMaxTokens 8192)
  effort=$(om_config_get llmReasoningEffort "default")
  case "$effort" in
    low|medium|high) ;;
    *) effort="" ;;
  esac

  if [ -z "$base_url" ] || [ -z "$model" ]; then
    om_log "model: llmProvider '$provider' unrecognized and no llmBaseUrl/llmModel set"
    printf ''
    return 0
  fi

  schema_mode="schema"
  if [ -n "$schema" ]; then
    schema_cache_key="${provider}:${model}:schema"
    [ "$(om_model_caps_get "$schema_cache_key")" = "object" ] && schema_mode="object"
  fi

  if [ -n "$effort" ]; then
    cache_key="${provider}:${model}:${effort}"
    caps=$(om_model_caps_get "$cache_key")

    if [ "$caps" != "no" ]; then
      body=$(om_chat_body "$system" "$user" "$schema" "$model" "$max_tokens" "$effort" "$schema_mode")
      content=$(om_chat_request "$body" "$base_url" "$api_key")
      if [ -n "$content" ]; then
        [ "$caps" = "yes" ] || om_model_caps_set "$cache_key" yes
        printf '%s' "$content"
        return 0
      fi
      om_model_caps_set "$cache_key" no
      om_log "model: $cache_key rejected reasoning_effort=$effort, retrying without it"
    fi
  fi

  body=$(om_chat_body "$system" "$user" "$schema" "$model" "$max_tokens" "" "$schema_mode")
  content=$(om_chat_request "$body" "$base_url" "$api_key")

  if [ -z "$content" ] && [ -n "$schema" ] && [ "$schema_mode" = "schema" ]; then
    om_log "model: ${provider}:${model} rejected structured response_format:json_schema, retrying with json_object"
    om_model_caps_set "${provider}:${model}:schema" object
    body=$(om_chat_body "$system" "$user" "$schema" "$model" "$max_tokens" "" "object")
    content=$(om_chat_request "$body" "$base_url" "$api_key")
  fi

  printf '%s' "$content"
}

# om_call_model <system_prompt> <user_prompt> [json_schema]
# Prints the model's raw text response, or empty on any failure. Never fails
# the caller — always safe to use in `set -e` scripts. Always routes through
# the unified OpenAI-compatible endpoint; requires `llmApiKey` to be set.
om_call_model() {
  local system="$1" user="$2" schema="${3:-}"
  local api_key
  api_key=$(om_config_get llmApiKey "")
  if [ -z "$api_key" ]; then
    om_log "model: llmApiKey not set; observe/reflect disabled"
    printf ''
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { om_log "model: curl not found for unified LLM route"; return 0; }
  om_call_model_unified "$system" "$user" "$schema" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# om_run_reflect_pass <session_id> — distill this session's own observations
# (its own file — no filtering needed) not yet reflected into new reflections.
# Safe/cheap to call repeatedly; no-ops below a minimum batch size. On
# success, triggers dropper maintenance. Returns 1 (rather than the usual
# always-0) only when the model call itself failed to return usable content
# (empty/truncated) — every other early exit (nothing to reflect, below
# minimum batch size, zero reflections legitimately decided) returns 0. The
# caller (om-consolidate.sh) uses this to avoid advancing its reflect
# watermark on a failed attempt, so the same window is retried at the next
# opportunity instead of waiting through another full growth threshold.
om_run_reflect_pass() {
  local sid="${1:-default}"
  local obs_file refl_file
  obs_file=$(om_session_observations "$sid")
  refl_file=$(om_session_reflections "$sid")
  [ -s "$obs_file" ] || return 0

  local last_ts=""
  if [ -s "$refl_file" ]; then
    last_ts=$(jq -r '.ts // empty' "$refl_file" 2>/dev/null | sort -r | head -1)
  fi
  [ -z "$last_ts" ] && last_ts="1970-01-01T00:00:00Z"

  local obs_jsonl
  obs_jsonl=$(jq -c --arg t "$last_ts" 'select(.ts > $t)' "$obs_file" 2>/dev/null || true)
  [ -z "$obs_jsonl" ] && return 0

  local count
  count=$(printf '%s\n' "$obs_jsonl" | grep -c . 2>/dev/null || echo 0)
  [ "${count:-0}" -lt 3 ] && return 0

  local schema='{"type":"object","properties":{"reflections":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"supportingObservationIds":{"type":"array","items":{"type":"string"}}},"required":["content","supportingObservationIds"]}}},"required":["reflections"]}'
  local sys="This is a simple, direct distillation task — answer immediately without extended step-by-step reasoning or deliberation. You distill Claude Code session observations (JSONL, each with an id) into durable reflections: stable facts about the user, project, decisions, and constraints that a future session would need. Skip anything transient or already covered by an existing reflection. Cite only real observation ids from the input in supportingObservationIds. Emit zero reflections if nothing is durable enough."
  local user="Observations:
${obs_jsonl}"
  local resp
  resp=$(om_call_model "$sys" "$user" "$schema")
  if [ -z "$resp" ]; then
    om_log "reflect: model call returned no usable content for $count observations (session $sid); not advancing watermark, will retry next opportunity"
    return 1
  fi

  local allowed_ids
  allowed_ids=$(printf '%s\n' "$obs_jsonl" | jq -s '[.[].id]' 2>/dev/null || echo '[]')
  local now added=0
  now=$(date -u +%FT%TZ)
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    local content sup_ids rid
    content=$(printf '%s' "$item" | jq -r '.content // empty' 2>/dev/null)
    [ -z "$content" ] && continue
    sup_ids=$(printf '%s' "$item" | jq -c --argjson allowed "$allowed_ids" \
      '[.supportingObservationIds[]? | select(. as $i | $allowed | index($i))]' 2>/dev/null || echo '[]')
    [ "$sup_ids" = "[]" ] && continue
    rid=$(om_new_id)
    jq -nc --arg id "$rid" --arg ts "$now" --arg sid "$sid" --arg content "$content" --argjson sup "$sup_ids" \
      '{id:$id,ts:$ts,session_id:$sid,content:$content,supportingObservationIds:$sup}' \
      >> "$refl_file" 2>/dev/null && added=$((added + 1))
  done < <(printf '%s' "$resp" | jq -c '.reflections[]?' 2>/dev/null || true)

  om_log "reflect: wrote $added reflection(s) from $count observations (session $sid)"
  [ "$added" -gt 0 ] && om_run_dropper_pass "$sid"
  return 0
}

# om_run_dropper_pass <session_id> — once this session's observations are
# covered by one of its own reflections, archive the oldest covered ones out
# of its active pool once it exceeds observationsPoolTargetTokens. Never
# touches uncovered observations. Dropped ids go to this session's
# dropped.jsonl as tombstones; the original entries stay in this session's
# observations.jsonl and remain recallable by id.
om_run_dropper_pass() {
  local sid="${1:-default}"
  local obs_file refl_file dropped_file
  obs_file=$(om_session_observations "$sid")
  refl_file=$(om_session_reflections "$sid")
  dropped_file=$(om_session_dropped "$sid")
  [ -s "$obs_file" ] || return 0
  [ -s "$refl_file" ] || return 0

  local target
  target=$(om_config_get observationsPoolTargetTokens 4000)

  local dropped_ids='[]'
  [ -s "$dropped_file" ] && dropped_ids=$(jq -s '[.[].id]' "$dropped_file" 2>/dev/null || echo '[]')

  local active
  active=$(jq -c --argjson dropped "$dropped_ids" \
    'select(.id as $i | ($dropped | index($i)) | not)' "$obs_file" 2>/dev/null || true)
  [ -z "$active" ] && return 0

  local active_chars active_tokens
  active_chars=$(printf '%s\n' "$active" | jq -r '.content' 2>/dev/null | wc -c | tr -d ' ')
  active_chars=${active_chars:-0}
  active_tokens=$(( active_chars / 4 ))
  [ "$active_tokens" -le "$target" ] && return 0

  local covered_ids
  covered_ids=$(jq -s '[.[].supportingObservationIds[]?] | unique' "$refl_file" 2>/dev/null || echo '[]')

  local now to_remove removed_tokens=0 removed=0
  now=$(date -u +%FT%TZ)
  to_remove=$(( active_tokens - target ))

  while IFS= read -r obs; do
    [ "$removed_tokens" -ge "$to_remove" ] && break
    local oid ocontent is_covered
    oid=$(printf '%s' "$obs" | jq -r '.id')
    ocontent=$(printf '%s' "$obs" | jq -r '.content')
    is_covered=$(printf '%s' "$covered_ids" | jq --arg i "$oid" 'index($i) != null' 2>/dev/null || echo false)
    if [ "$is_covered" = "true" ]; then
      jq -nc --arg id "$oid" --arg ts "$now" '{id:$id,ts:$ts}' >> "$dropped_file" 2>/dev/null
      removed_tokens=$(( removed_tokens + (${#ocontent} / 4) ))
      removed=$((removed + 1))
    fi
  done < <(printf '%s\n' "$active" | jq -c -s 'sort_by(.ts) | .[]' 2>/dev/null || true)

  om_log "dropper: archived $removed observation(s) (~${removed_tokens} tokens); pool was ${active_tokens}/${target} (session $sid)"
  return 0
}

# om_run_retention_pass — permanently deletes an entire session directory
# (observations, reflections, dropped-tombstones, state) once that session's
# last_touch (stamped by om_session_init on every Stop/PreCompact/
# SessionStart) is older than sessionRetentionDays (default 30; <=0 disables).
# Unlike the dropper — which only tombstones observations already covered by
# a reflection, keeping them recallable — this is disk hygiene for sessions
# old enough they will never be resumed again, so it deletes outright.
# Per-session directories make this a plain rm -rf per stale session, no
# cross-file filtering needed. Rate-limited to run at most once per day via a
# marker file, since it scans every session directory; safe/cheap to call on
# every Stop.
om_run_retention_pass() {
  local days
  days=$(om_config_get sessionRetentionDays 30)
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  [ "$days" -le 0 ] && return 0

  local now_epoch last_epoch
  now_epoch=$(date -u +%s)
  if [ -f "$OM_RETENTION_MARKER" ]; then
    last_epoch=$(cat "$OM_RETENTION_MARKER" 2>/dev/null || echo 0)
    case "$last_epoch" in ''|*[!0-9]*) last_epoch=0 ;; esac
    [ $(( now_epoch - last_epoch )) -lt 86400 ] && return 0
  fi
  mkdir -p "${OM_DIR}" 2>/dev/null
  printf '%s' "$now_epoch" > "$OM_RETENTION_MARKER" 2>/dev/null

  [ -d "$OM_SESSIONS_DIR" ] || return 0

  local cutoff_epoch=$(( now_epoch - days * 86400 ))
  local pruned=0 dir touch_epoch
  for dir in "$OM_SESSIONS_DIR"/*/; do
    [ -d "$dir" ] || continue
    touch_epoch=$(cat "${dir}last_touch" 2>/dev/null || echo 0)
    case "$touch_epoch" in ''|*[!0-9]*) touch_epoch=0 ;; esac
    if [ "$touch_epoch" -lt "$cutoff_epoch" ]; then
      rm -rf "$dir" 2>/dev/null && pruned=$((pruned + 1))
    fi
  done

  om_log "retention: pruned ${pruned} stale session(s) with no activity in ${days}d"
  return 0
}
