# claude-observational-memory

Observational memory for Claude Code — captures session **observations**, **reflects** them into durable memory, **injects** memory into new sessions, and **recalls** entries by id.

It adapts the [`pi-observational-memory`](https://github.com/elpapi42/pi-observational-memory) concept to Claude Code's hook-based, file-backed extension model.

## How it works

```text
PostToolUse / Stop   →  om-observe.sh   →  observations.jsonl
PreCompact           →  om-reflect.sh   →  reflections.jsonl   (distills observations via an LLM)
SessionStart         →  om-inject.sh    →  stdout injected into context (compact summary with ids)
recall <id>          →  om-recall.sh    →  exact entry by id, or text search
```

Memory lives in `~/.local/share/claude-observational-memory/`:

```text
observations.jsonl   captured events (tool calls, prompts, stops)
reflections.jsonl    distilled, durable facts/decisions/preferences
config.json          settings
debug/om.log         hook log
last-injected.md     most recent injected summary
```

## Install

This repo is a Claude Code **marketplace** named `sovorn-g-om` containing one plugin, `claude-observational-memory`.

**From GitHub (shared):**

```text
/plugin marketplace add sovorn-g/claude-observational-memory
/plugin install claude-observational-memory@sovorn-g-om
```

**From a local path (this machine):**

```text
/plugin marketplace add /Users/sovorn/dev/claude-observational-memory
/plugin install claude-observational-memory@sovorn-g-om
```

After install, restart the session so hooks register.

## Commands

```text
/claude-observational-memory:status           show storage usage and config
/claude-observational-memory:reflect          manually run a reflection pass
/claude-observational-memory:recall <id|q>    recall an entry by id or search
```

## Configuration

Edit `~/.local/share/claude-observational-memory/config.json` (created on first run):

```json
{
  "observationsPoolMaxTokens": 4000,
  "reflectOnPreCompact": true,
  "injectOnSessionStart": true,
  "reflectionProvider": "claude-cli"
}
```

`reflectionProvider`:

- `claude-cli` (default) — uses `claude -p` for reflection. Requires the Claude Code CLI on PATH.
- `anthropic-api` — uses the Anthropic API. Requires `ANTHROPIC_API_KEY`.

## Requirements

- `bash`, `jq`, `openssl` (id generation)
- Claude Code CLI (for the default `claude-cli` reflection provider)

## Notes and limitations

- Claude Code does **not** auto-compact. `PreCompact` fires only on `/compact` (manual or agent-invoked). Reflection therefore runs when you compact.
- SessionStart injects memory as plain-text stdout, which Claude Code adds to context. In some Claude Code versions, plugin `SessionStart` hooks may not surface output (see [anthropics/claude-code#16538](https://github.com/anthropics/claude-code/issues/16538)). If memory does not appear at startup, add the hook directly to `~/.claude/settings.json` as a workaround.
- This is a file-backed adaptation, not a context-ledger embedding like the Pi extension. Claude Code does not expose an internal session ledger to plugins.

## License

MIT
