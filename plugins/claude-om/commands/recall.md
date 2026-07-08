---
description: Recall an observational memory entry by id or search by query
argument-hint: [--all] <id|query>
---

Look up observational memory for: `$ARGUMENTS`

!`${CLAUDE_PLUGIN_ROOT}/scripts/om-recall.sh $ARGUMENTS`

Id lookups always search every session (an id is a unique key). Text-query searches default to the current session only; pass `--all` as the first argument to search every session instead. If a memory entry was found, explain its content and how it relates to the current work. If the results are a list of matches, summarize the most relevant ones. If nothing was found, say so plainly and do not fabricate a memory.
