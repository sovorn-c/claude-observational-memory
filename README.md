# claude-observational-memory

Observational memory for Claude Code — captures session **observations**, **reflects** them into durable memory, **injects** memory into new sessions, and **recalls** entries by id.

## Problem

Claude Code's context window is finite. A session worked on over weeks or months — resumed across many sittings, not run as one unbroken process — will eventually fill it, and Claude Code compacts: it summarizes and discards the raw transcript so the session can keep going. That's the built-in fix for a finite context window, but it's lossy — a decision, a constraint, a stated preference, why an approach was rejected, none of that survives unless it happened to make the auto-generated summary. That's what actually stops a session from spanning weeks or months in practice: not that it can't be resumed, but that each compaction along the way quietly erodes what it remembers.

This plugin closes that gap: it distills what happens during a session into small structured notes continuously, before compaction ever needs to discard anything, and re-injects them every time that session resumes. With it, one session genuinely can be worked on for weeks or months — compaction stops costing you context you'd otherwise have to re-derive or re-explain, no vector database, embedding model, or larger context window required.

## Install

This repo is a Claude Code **marketplace** named `sovorn-c-om` containing one plugin, `claude-observational-memory`.

**From GitHub (shared):**

```text
/plugin marketplace add sovorn-c/claude-observational-memory
/plugin install claude-observational-memory@sovorn-c-om
```

**From a local path (this machine):**

```text
/plugin marketplace add /Users/sovorn/dev/claude-observational-memory
/plugin install claude-observational-memory@sovorn-c-om
```

After install, restart the session so hooks register.

**Updating:** third-party marketplaces like this one do **not** auto-update by default — Claude Code only auto-updates official Anthropic marketplaces unless you opt in. To pick up fixes/changes:

```text
/plugin marketplace update sovorn-c-om
/reload-plugins
```

Or enable it once so future updates are automatic: `/plugin` → **Marketplaces** → `sovorn-c-om` → **Enable auto-update**.

## Requirements

- `bash`, `jq`, `openssl` (id generation), `curl` (LLM calls)
- An API key from an OpenAI-compatible LLM provider, set as `llmApiKey` (see Configuration) — required for observe/reflect to run at all. [DeepSeek](https://api-docs.deepseek.com/) and [OpenCode Zen](https://opencode.ai/) (`opencode-go`) are cheap options to start with.

## Commands

```text
/claude-observational-memory:status           show storage usage and config
/claude-observational-memory:reflect          manually run a reflection pass
/claude-observational-memory:recall <id|q>    recall an entry by id or search
```

## How it works

```mermaid
flowchart TD
    subgraph Hooks["Claude Code hooks"]
        Stop["Stop"]
        PreCompact["PreCompact"]
        SessionStart{"SessionStart<br/>startup vs. resume/compact/clear"}
    end
    Commands["/recall, /status commands"]

    Model{{"unified LLM route<br/>(OpenAI-compatible API)"}}
    Consolidate("Consolidate engine<br/>observe → reflect → dropper → retention")
    Session(["Session context"])
    Inject("Inject engine")
    Query("Recall / status engine")

    Storage[("Per-session storage<br/>~/.local/share/claude-observational-memory")]

    Stop --> Consolidate
    PreCompact --> Consolidate
    Commands --> Query
    SessionStart -->|"resume / compact / clear:<br/>same session_id"| Inject
    SessionStart -.->|"startup:<br/>new session_id, starts empty"| Session

    Consolidate -.->|"model call"| Model
    Consolidate -->|"reads & writes"| Storage
    Query -->|"reads & writes"| Storage
    Inject -->|"reads & writes"| Storage

    Inject -->|"reflections + observations"| Session
    Query -->|"output to"| Session
```

Every session gets its own storage directory — observe, reflect, the dropper, and injection only ever touch that session's own files, so two sessions running concurrently (e.g. two terminal tabs) never race on the same file. A brand-new session (`SessionStart` with `source: startup`) always starts empty; memory only carries forward across `resume` and `compact` of the *same* session_id. `recall` and `status` are the exceptions — they deliberately glob across every session directory, since one's a manual lookup and the other's an aggregate view, not automatic context injection.

`om-inject.sh` avoids re-showing the same content on every injection: each session tracks `lastFullFoldTs`, the boundary of its last full fold. Normally injection is **incremental** — only reflections/observations after that boundary — and that window keeps accumulating across multiple incremental injections until a full fold resets it. A **full fold** (show everything, move the boundary to now) fires instead if the active observation pool exceeds `observationsPoolMaxTokens`, or no fold has happened yet this session — so a consolidation backlog never silently falls outside the window.

Observe and reflect are gated by real token growth, not tool-call count: each assistant turn's recorded `usage` in the session transcript (`input_tokens` + cache tokens) gives an actual context-size delta since the last watermark. `Stop` is the closest thing Claude Code's hook model has to a continuous token clock, since there's no `turn_end`/background-task hook to poll continuously. No hook but `Stop` and `PreCompact` ever makes a model call, so tool calls themselves are never slowed down.

Memory lives in `~/.local/share/claude-observational-memory/`, one directory per session:

```text
sessions/<session_id>/observations.jsonl  distilled observations, each tagged with a relevance (low/medium/high/critical)
sessions/<session_id>/reflections.jsonl   durable facts/decisions/preferences distilled from this session's observations
sessions/<session_id>/dropped.jsonl       tombstones for observations archived out of this session's active pool (still recallable by id)
sessions/<session_id>/state.json          this session's transcript-line watermarks for the observe/reflect token clock
sessions/<session_id>/last_touch          epoch timestamp of this session's last hook activity, used by retention
retention_last_run   epoch timestamp of the last retention sweep
config.json           settings
model-caps.json        per-model cache of whether a configured reasoning_effort was accepted (see Configuration)
debug/om.log          hook log
last-injected.md      most recent injected summary
```

## Configuration

Preferred: set env vars in `.claude/settings.json`'s `env` block — the same override mechanism Claude Code itself documents for `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (see Notes below), so all tuning lives in one familiar place instead of a separate file. The env var name is the config key in `OM_UPPER_SNAKE_CASE`, e.g. `observeAfterTokens` -> `OM_OBSERVE_AFTER_TOKENS`:

```json
{
  "env": {
    "OM_OBSERVE_AFTER_TOKENS": "5000",
    "OM_REFLECT_AFTER_TOKENS": "10000"
  }
}
```

Alternative: edit `~/.local/share/claude-observational-memory/config.json` directly (created on first run, values shown by `/claude-observational-memory:status`). Env vars take precedence over this file; this file takes precedence over the hardcoded defaults below.

```json
{
  "observationsPoolMaxTokens": 8000,
  "observationsPoolTargetTokens": 4000,
  "observeAfterTokens": 5000,
  "reflectAfterTokens": 10000,
  "sessionRetentionDays": 30,
  "reflectOnPreCompact": true,
  "injectOnSessionStart": true
}
```

| Key | Env var | Default | What it does |
|---|---|---|---|
| `observeAfterTokens` | `OM_OBSERVE_AFTER_TOKENS` | `5000` | Real token growth (from each turn's recorded `usage`, not an estimate) that triggers an observe pass. Lower = more frequent, smaller model calls. |
| `reflectAfterTokens` | `OM_REFLECT_AFTER_TOKENS` | `10000` | Real token growth of already-observed-but-unreflected content that triggers a reflect pass. |
| `observationsPoolTargetTokens` | `OM_OBSERVATIONS_POOL_TARGET_TOKENS` | `4000` | Steady-state size the dropper archives the active pool back down to after a successful reflect pass. Keep well below `observationsPoolMaxTokens`. |
| `observationsPoolMaxTokens` | `OM_OBSERVATIONS_POOL_MAX_TOKENS` | `8000` | Ceiling, not steady-state target. Caps how much `om-inject.sh` prints (× 4 chars/token), and forces a full fold instead of incremental once the active pool exceeds it. |
| `sessionRetentionDays` | `OM_SESSION_RETENTION_DAYS` | `30` | Days of no hook activity before a session's entire directory is deleted outright (not a tombstone). `0` or lower disables. Checked every `Stop`, pruned at most once/day. |
| `reflectOnPreCompact` | `OM_REFLECT_ON_PRE_COMPACT` | `true` | Whether the `PreCompact` safety-net reflect pass runs at all. |
| `injectOnSessionStart` | `OM_INJECT_ON_SESSION_START` | `true` | Whether `SessionStart` injects memory into context at all. |

### Unified LLM route

Observe and reflect always call an OpenAI-compatible `/chat/completions` provider — there is no bundled fallback, so `llmApiKey` must be set or observe/reflect silently no-op (logged to `debug/om.log`, never a hard failure). [DeepSeek](https://api-docs.deepseek.com/) and [OpenCode Zen](https://opencode.ai/) (`opencode-go`) are good picks to start with: both are cheap, and neither requires the OAuth/subscription juggling that trying to shell out to the `claude` CLI for this would (see Notes below for why that route was dropped). Just set:

```json
{
  "env": {
    "OM_LLM_PROVIDER": "deepseek",
    "OM_LLM_API_KEY": "sk-...",
    "OM_LLM_MODEL": "deepseek-v4-flash",
    "OM_LLM_MAX_BUDGET_USD": "0.05"
  }
}
```

`OM_LLM_MODEL` and `OM_LLM_MAX_BUDGET_USD` above are shown explicitly because both have sane defaults (per-provider default model, `$0.05`) — set them only if you want to override.

| Key (env var) | Default | What it does |
|---|---|---|
| `llmApiKey` (`OM_LLM_API_KEY`) | unset | **Required.** Observe/reflect no-op until this is set. Env-only — never written to `config.json` by `om_config_init`, so a secret never ends up in a plain file just from running the plugin. |
| `llmProvider` (`OM_LLM_PROVIDER`) | `openai` | One of `openai`, `openrouter`, `gemini`, `deepseek`, `ollama`, `opencode-go`. Resolves internally to that provider's API base URL, so you don't need to know or type one. |
| `llmModel` (`OM_LLM_MODEL`) | per-provider, see below | Optional for every provider except `opencode-go`, whose model catalog is curated per-account (check `/models` in the `opencode` CLI or your OpenCode Zen dashboard) and so requires it explicitly. Freely override the default for any provider. |
| `llmBaseUrl` (`OM_LLM_BASE_URL`) | resolved from `llmProvider` | Override for a provider/base URL not in the built-in list — self-hosted, a proxy, Azure OpenAI, a local vLLM server, etc. When set, `llmProvider` can be anything; it's just used as a cache-key label at that point. |
| `llmMaxTokens` (`OM_LLM_MAX_TOKENS`) | `2048` | Output token cap for unified-route calls. |
| `llmMaxBudgetUsd` (`OM_LLM_MAX_BUDGET_USD`) | `0.05` | Pre-call budget guard: a rough worst-case estimate (~4 chars/token on the prompt, output capped at `llmMaxTokens`, priced at a deliberately conservative flat $2/1M-token ceiling) that skips the call outright if exceeded. This is a safety net against an unexpectedly large chunk or `llmMaxTokens` value, not real billing accounting — it replaces the role the old `claude --max-budget-usd` flag played before that CLI route was dropped (see Notes below). |
| `llmReasoningEffort` (`OM_LLM_REASONING_EFFORT`) | `default` | `default` never sends `reasoning_effort` at all, so the model uses its own native default — no probing, no overhead. `low`, `medium`, or `high` sends that value; if the provider rejects it, the call transparently retries once without the field and remembers the outcome in `model-caps.json`, so future calls for that `llmProvider`+`llmModel`+`llmReasoningEffort` combination skip straight to whichever shape actually works. |

Per-provider default model, used when `llmModel` is unset:

| Provider | Default model |
|---|---|
| `openai` | `gpt-5.4-nano` |
| `openrouter` | `meta-llama/llama-3.1-8b-instruct` |
| `gemini` | `gemini-3.1-flash-lite` |
| `deepseek` | `deepseek-v4-flash` (`deepseek-chat` is deprecated 2026-07-24 — same model, renamed) |
| `ollama` | `llama3.2` |
| `opencode-go` | none — `llmModel` is required |

By default (`llmReasoningEffort` unset/`default`) the unified route never sends `reasoning_effort` at all — each model just runs in its own native mode, thinking or not. Set `llmReasoningEffort` to `low`, `medium`, or `high` to opt in; if the provider/model rejects that value, the call automatically falls back to omitting the field and caches the outcome per `llmProvider`+`llmModel`+`llmReasoningEffort` in `model-caps.json`, so it only ever probes once.

## Notes and limitations

- Claude Code auto-compacts on its own as a session approaches the model's real context window, not a fixed token count — on a large window (e.g. ~1M tokens) that may not trigger until very late, delaying reflection along with it. Set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in the `env` block above (150,000–250,000 is a reasonable starting range), or `export` it before starting `claude`, to make it fire on a predictable schedule that matches this plugin's cadence. Only affects sessions started after the change. See [Explore the context window](https://code.claude.com/docs/en/context-window).
- `SessionStart` injects memory as plain-text stdout — the mechanism Claude Code documents for this hook — rather than a plugin hook's JSON `additionalContext` field, which is less consistently reliable for plugin-sourced hooks. The plain-stdout path used here hasn't been empirically confirmed reliable in this plugin either, though. If memory doesn't appear at startup, add the hook directly to `~/.claude/settings.json` as a workaround.
- This is a file-backed design, not an integration with Claude Code's own context ledger — plugins can't read that ledger or trigger compaction themselves, only react to it.
- The dropper is deterministic (oldest-covered-first), not model-judged — cheaper than asking a model which observations are safe to remove, at the cost of nuance (it can't choose to keep an old-but-still-load-bearing observation just because it's technically covered).
- The unified LLM route assumes an OpenAI-compatible `/chat/completions` shape; a provider with a different auth header or response envelope needs changes to `om_call_model_unified` in `scripts/om-config.sh`.
- Earlier versions shelled out to the `claude` CLI (`claude -p --bare ...`) for observe/reflect, piggybacking on Claude Code's own auth. That was dropped: `--bare` mode — needed to keep each call small and cheap — explicitly disables OAuth/keychain auth and requires `ANTHROPIC_API_KEY` regardless (per Claude Code's own docs), so it was never actually free of a separate API key; and without `--bare`, plain `claude -p` reloads hooks/skills/plugins/CLAUDE.md on every call, tens of thousands of tokens of fixed overhead for what's otherwise a small extraction prompt. The unified LLM route avoids both problems.

## License

MIT
