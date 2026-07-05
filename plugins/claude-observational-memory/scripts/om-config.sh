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
  "injectOnSessionStart": true,
  "model": "claude-haiku-4-5-20251001"
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

# om_call_model <system_prompt> <user_prompt> <max_budget_usd> [json_schema]
# Prints the model's raw text response, or empty on any failure. Never fails
# the caller — always safe to use in `set -e` scripts.
om_call_model() {
  local system="$1" user="$2" budget="${3:-0.03}" schema="${4:-}"
  command -v claude >/dev/null 2>&1 || { om_log "model: claude CLI not found"; return 0; }
  local model
  model=$(om_config_get model claude-haiku-4-5-20251001)
  local args=(-p --bare --model "$model" --system-prompt "$system" --tools "" \
    --no-session-persistence --max-budget-usd "$budget" --output-format text)
  [ -n "$schema" ] && args+=(--json-schema "$schema")
  printf '%s' "$user" | claude "${args[@]}" 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

# om_run_reflect_pass <session_id> — distill this session's own observations
# (its own file — no filtering needed) not yet reflected into new reflections.
# Safe/cheap to call repeatedly; no-ops below a minimum batch size. On
# success, triggers dropper maintenance.
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
  local sys="You distill Claude Code session observations (JSONL, each with an id) into durable reflections: stable facts about the user, project, decisions, and constraints that a future session would need. Skip anything transient or already covered by an existing reflection. Cite only real observation ids from the input in supportingObservationIds. Emit zero reflections if nothing is durable enough."
  local user="Observations:
${obs_jsonl}"
  local resp
  resp=$(om_call_model "$sys" "$user" 0.05 "$schema")
  [ -z "$resp" ] && return 0

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
