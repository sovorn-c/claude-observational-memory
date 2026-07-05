---
name: recall
description: Retrieve exact source context for a specific observational memory entry by its 12-character hex id. Use when the user asks why you believe something, what supports a prior claim or decision, or when you need precise details behind a compacted memory.
---

# Recall

When observational memory is injected at session start, each entry appears with a 12-character hex id in brackets, for example `[a1b2c3d4e5f6]`.

## When to recall

- The user asks "why do you think that?", "what's your evidence?", or "what did we decide earlier?"
- You need the full original context behind a compacted reflection.
- The user references a prior decision, constraint, bug, or preference you only partially remember.

## How to recall

Run the recall script with an id or keyword:

!`${CLAUDE_PLUGIN_ROOT}/scripts/om-recall.sh "<id-or-keyword>"`

Or use the slash command:

```
/claude-observational-memory:recall <id-or-keyword>
```

A 12-character hex id returns that exact entry. Any other text searches observations and reflections for matches.

## Rules

- Prefer recalling over guessing. If no id is available and no search hit is relevant, say you do not have a specific memory entry rather than fabricating one.
- Ids are stable across sessions, so it is safe to reference them in your reasoning.
- Recall is read-only and never modifies memory.
