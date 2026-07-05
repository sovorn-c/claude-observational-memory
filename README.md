# claude-observational-memory

Observational memory for Claude Code — captures session **observations**, **reflects** them into durable memory, **injects** memory into new sessions, and **recalls** entries by id.

It adapts the [`pi-observational-memory`](https://github.com/elpapi42/pi-observational-memory) concept to Claude Code's hook-based, file-backed extension model.

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

## Requirements

- `bash`, `jq`, `openssl` (id generation)
- Claude Code CLI (`claude`) on PATH — required for both observe distillation and reflection

## Commands

```text
/claude-observational-memory:status           show storage usage and config
/claude-observational-memory:reflect          manually run a reflection pass
/claude-observational-memory:recall <id|q>    recall an entry by id or search
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
  "injectOnSessionStart": true,
  "model": "claude-haiku-4-5-20251001"
}
```

- `model` — used for observe, reflect, and (implicitly) the dropper's coverage bookkeeping, via `claude -p --model <model>`. Defaults to a cheap, fast model rather than whatever your interactive session is using, since these calls run automatically in the background and shouldn't bill at your main model's rate.
- `observeAfterTokens` / `reflectAfterTokens` — real token-growth thresholds (from each assistant turn's recorded `usage`, not an estimate) that gate observe and reflect, matching Pi's setting names and intent. Lower values mean more frequent, smaller model calls.
- `observationsPoolTargetTokens` — the dropper's steady-state goal: after a successful reflect pass, if the active (non-dropped) observation pool exceeds this size, the dropper archives the oldest observations already covered by a reflection until the pool is back near this target. Never touches observations no reflection has covered yet. Should be meaningfully *smaller* than `observationsPoolMaxTokens` below — this is where the pool normally sits, not the alarm threshold.
- `observationsPoolMaxTokens` — the full-fold pressure point (same term Pi uses): a much higher ceiling than the target above. Two effects: (1) caps how much text `om-inject.sh` prints at session-start (truncates to this budget in chars ×4); (2) if the active pool ever exceeds it, `om-inject.sh` forces a full fold instead of incremental — meaning the dropper has fallen behind and something's not being consolidated fast enough. Keep this well above `observationsPoolTargetTokens`, or the full-fold trigger fires on every injection even when the dropper is behaving normally.
- `sessionRetentionDays` — since memory is scoped per `session_id` (see How it works), a session that's never resumed again would otherwise sit in storage forever. Once a session's directory has had no hook activity for this many days, it's deleted outright — unlike the dropper, this isn't a tombstone, it's gone. Set to `0` or lower to disable. Checked on every `Stop`, but actual pruning runs at most once per day.

## How it works

```text
Stop        →  om-consolidate.sh  →  observations.jsonl   (observe: structured, multi-item, once this session's real token growth crosses observeAfterTokens)
                                  →  reflections.jsonl    (reflect: once this session's observed-but-unreflected growth crosses reflectAfterTokens; skipped on any turn observe just ran)
                                  →  dropper: archives this session's active observations a fresh reflection now covers, once its pool exceeds observationsPoolTargetTokens
                                  →  retention: deletes any session's data untouched for sessionRetentionDays (rate-limited to once/day)
PreCompact  →  om-reflect.sh      →  reflections.jsonl    (safety net — forces one more reflect pass for this session before compaction, in case the clock above hasn't caught up)
SessionStart →  om-inject.sh      →  stdout injected into context (this session's own reflections + observations since the last fold, by id)
recall <id> →  om-recall.sh       →  exact entry by id, or text search (unscoped — searches across all sessions)
```

Every session gets its own storage directory, so observe, reflect, the dropper, and injection never filter a shared file — reading or writing "this session's data" is just reading or writing its own files, with no other session ever touched. This also means two sessions running concurrently (e.g. two terminal tabs) can never race on the same file. A brand-new session (`SessionStart` with `source: startup`) always starts with an empty directory, exactly like Pi's per-session-tree fold; memory only carries forward across `resume` and `compact` of the *same* session_id, which is what lets one long-running session span days or weeks. Different sessions never see each other's memory, even in the same project — this is deliberate scoping, not project-level sharing. (`recall` and `status` are the exceptions: they deliberately glob across every session directory, since recall is a manual on-demand lookup and status is an aggregate view, not automatic context injection.)

`om-inject.sh` mirrors Pi's incremental-vs-full-fold distinction rather than always dumping everything. Each session tracks `lastFullFoldTs` — the boundary of its last *full* fold. Normally an injection is **incremental**: it shows only reflections/observations with a timestamp after that boundary, and that set keeps *accumulating* across multiple incremental injections (it does not reset on every single injection, only when a full fold happens — matching Pi's "carried from the last full-fold boundary forward" behavior). If the active (non-dropped) observation pool exceeds `observationsPoolMaxTokens`, or no fold has happened yet for this session, it does a **full fold** instead — shows everything, and moves `lastFullFoldTs` forward to now. This keeps repeat injections (e.g. several compactions within one long session) from re-showing the same already-seen content indefinitely, while still guaranteeing nothing silently falls outside the window if consolidation ever falls behind.

Observe and reflect are gated by real token growth, not tool-call count: each assistant turn in the session's own transcript file (`transcript_path`, included in every hook payload) records its actual context size in `message.usage` (`input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`); the clock is the delta between that value at the current line and at the last watermark. This mirrors Pi's `observeAfterTokens`/`reflectAfterTokens` token-clock design as closely as Claude Code's hook model allows, since Claude Code has no `turn_end`/background-task hook to poll continuously — `Stop` (once per agent turn) is the closest available checkpoint. No hook makes a model call except `Stop` and `PreCompact`, so tool calls themselves are never slowed down.

Memory lives in `~/.local/share/claude-observational-memory/`, one directory per session:

```text
sessions/<session_id>/observations.jsonl  distilled observations, each tagged with a relevance (low/medium/high/critical)
sessions/<session_id>/reflections.jsonl   durable facts/decisions/preferences distilled from this session's observations
sessions/<session_id>/dropped.jsonl       tombstones for observations archived out of this session's active pool (still recallable by id)
sessions/<session_id>/state.json          this session's transcript-line watermarks for the observe/reflect token clock
sessions/<session_id>/last_touch          epoch timestamp of this session's last hook activity, used by retention
retention_last_run   epoch timestamp of the last retention sweep
config.json           settings
debug/om.log          hook log
last-injected.md      most recent injected summary
```

## Notes and limitations

- Claude Code auto-compacts on its own as a session approaches the model's actual context window — it's not a fixed token count, and `PreCompact` fires on that automatic compaction as well as manual/agent-invoked `/compact`. On a large context window (e.g. ~1M tokens), auto-compact — and therefore reflection — may not trigger until very late in a session. To make it fire at a predictable point that matches this plugin's cadence, set before starting Claude Code:

  ```bash
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000
  ```

  Lower values compact (and reflect) sooner; 150,000–250,000 is a reasonable starting range. See [Explore the context window](https://code.claude.com/docs/en/context-window). This only takes effect for a session started *after* the variable is exported — an already-running session won't pick it up.
- SessionStart injects memory as plain-text stdout, which Claude Code documents as being added to context for this hook. This is a separate mechanism from plugin hooks' JSON `additionalContext` field, which has known issues for plugin-sourced hooks (see [anthropics/claude-code#16538](https://github.com/anthropics/claude-code/issues/16538)) — but the plain-stdout path used here hasn't been empirically confirmed reliable in this plugin either. If memory does not appear at startup, add the hook directly to `~/.claude/settings.json` as a workaround.
- This is a file-backed adaptation, not a context-ledger embedding like the Pi extension. Claude Code does not expose an internal session ledger to plugins, and plugins cannot programmatically trigger compaction the way Pi's extension API can — this plugin only ever reacts to compaction, it never initiates it.
- The dropper is deterministic (oldest-covered-first), not model-judged like Pi's — it never asks a model which observations are safe to remove, it just archives the oldest ones a reflection already covers once the pool is over target. Cheaper and simpler than Pi's judgment-based version, at the cost of some nuance (Pi can, for example, choose to keep an old-but-still-load-bearing observation even if it's technically covered).
- Observe and reflect only call the `claude` CLI (`claude -p --model <model>`) — there's no support for an external provider/API key (OpenAI, etc.) as an alternative backend today.

## License

MIT
