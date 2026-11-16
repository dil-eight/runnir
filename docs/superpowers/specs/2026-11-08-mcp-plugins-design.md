# Runnir Plugins For Claude Code And Codex

Status: design approved on 2026-11-08 on branch dilbarov/mcp-values. It installs the MCP tools of [MCP Tools For The Values Of Local Runs](2026-11-08-mcp-value-sets-design.md) with one command that is the same for every user, so the website can show it.

## Problem

Settings › MCP shows a command and a Codex block built from this Mac's paths: the app's folder and `~/Library/Application Support/<build>`. Text with a user's home folder cannot go on a website. A `claude mcp add` without `--scope user` only works in the folder it was run in. Codex reads `tool_timeout_sec` from `config.toml` by hand, or a set request waiting for the user's Save times out after 60 seconds. And an agent learns what the tools are for only from their descriptions.

## Decisions

| Question | Decision |
| --- | --- |
| What | One plugin, `runnir`, for Claude Code and for Codex, in a marketplace named `runnir` in the public repository `dil-eight/runnir`. Installed with `claude plugin marketplace add dil-eight/runnir` and `claude plugin install runnir@runnir`, or `codex plugin marketplace add dil-eight/runnir` and `codex plugin add runnir@runnir`. Claude Code's `/plugin` screen shows it once the marketplace is added |
| Where | `plugins/runnir/` with `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`; the marketplaces are `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` at the repository root. JSON and Markdown only |
| MCP server | `/Applications/Runnir.app/Contents/Helpers/runnir-core mcp`, named `runnir`: inline in Claude Code's `plugin.json`; for Codex in `codex.mcp.json` with `tool_timeout_sec = 300`. Each client reads only its own, as Codex keys are not Claude Code's |
| Builds | The plugin serves Runnir, Runnir Alpha and Runnir Beta (one app, `Runnir.app`) installed in `/Applications`. Runnir Dev, Runnir Local and an app elsewhere keep Settings › MCP's command |
| `--data-dir` | Optional: without it `runnir-core mcp` uses its own build's folder in Application Support, as the app's `RunnirBuild.folderName` names it (Runnir Dev, Runnir Local, Runnir). The build passes `RUNNIR_BUILD` to the Core with `-ldflags`; an empty or unknown value reads as dev, as in the app |
| Skill | `local-run-values`: when to use the tools (secrets or variables of Runnir's local runs), `repository` as the agent's working folder, list first, values only from the user or files they name, never echoing a secret, one call per set, what each refusal asks of the user |
| Settings › MCP | In Runnir, Runnir Alpha or Runnir Beta at `/Applications/Runnir.app` it shows the plugin's commands; elsewhere, and in Runnir Dev and Runnir Local, `claude mcp add --scope user <name> -- <helper> mcp` and a Codex block with `args = ["mcp"]`, no data folder in either |
| Versions | The plugin carries the app's version (0.1.0). The tools come from the Core at run time, so a new tool needs no new plugin; only the skill's text does |

## Not In This Change

A deep link that opens a client's install screen (neither client documents one); Claude Desktop's `.mcpb`; finding Runnir outside `/Applications`.

## Tests

- Core: `mcp` with and without `--data-dir`, the folder of each build value.
- `claude plugin validate` on the plugin and the marketplace.
- Both clients install the plugin from the repository folder into a throwaway config (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) and list its server and skill.
- By hand: Claude Code and Codex, with a copy of the plugin that points at Runnir Local, against the scenarios of the MCP spec.
