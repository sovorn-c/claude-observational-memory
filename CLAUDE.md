# claude-observational-memory

## Releasing changes: bump the plugin version every time

`plugins/claude-observational-memory/.claude-plugin/plugin.json` has a `version` field. The marketplace manifest (`.claude-plugin/marketplace.json`) has no version of its own — it only points at the plugin's source path. Claude Code's `/plugin update` (and auto-update) decides whether there's anything new by comparing that `version` string, not the git commit SHA.

**Rule: any commit that changes plugin behavior (scripts, hooks, commands, README-documented config) must bump `version` in the same commit.** Even a trivial patch bump (`0.1.0` -> `0.1.1`) is enough. If the version is left unchanged, users who already installed the plugin will never see the update — `/plugin marketplace update` refreshes the local clone, but `/plugin update`/auto-update will still report "already latest" because the version string didn't move.

This was missed on the commit that dropped the `claude` CLI route from observe/reflect (`022e038`) — behavior changed but `version` stayed at `0.1.0`. Don't repeat that: bump version alongside behavior changes going forward.
