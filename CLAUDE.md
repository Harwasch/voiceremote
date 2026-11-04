@AGENTS.md

<!-- claude-ops pointer: keep everything below this block Claude-specific -->
## Working model
This repo is run by one coordinator thread. Coordinators follow the claude-ops playbook:
`/ops:orchestrate` (plugin `ops`, marketplace `Harwasch/claude-ops`).
In a cloud session the plugin is not loaded; read it at
https://github.com/Harwasch/claude-ops/blob/main/plugins/ops/skills/orchestrate/SKILL.md
The coordinator's log is `.claude/ops/LOG.md` (git-ignored, in the main checkout).

## Claude only
<!-- MCP servers, skills, desktop tools; anything Codex can't use -->
- The living design doc is a Claude Doc: https://claude.ai/artifact/651nezV4iFEWVa28gKaKFe
