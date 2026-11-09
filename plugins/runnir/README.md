# Runnir Plugin For Claude Code And Codex

Runnir runs GitHub Actions workflows on your Mac. This plugin lets Claude Code or Codex fill in the secrets and variables those local runs read:

- `runnir_list_value_sets` lists a workspace's sets (the Repository and its environments), the names its jobs read and which are missing. Secret values never come back.
- `runnir_set_values` saves values into one set after you press Save in Runnir. Runnir keeps them in your Mac's Keychain.

The plugin also brings the `local-run-values` skill, which tells the agent when and how to use the two tools.

## Install

Runnir must be in `/Applications` and running.

Claude Code:

```bash
claude plugin marketplace add dil-eight/runnir
claude plugin install runnir@runnir
```

In a Claude Code session you can instead run `/plugin marketplace add dil-eight/runnir` and install Runnir from the `/plugin` screen.

Codex:

```bash
codex plugin marketplace add dil-eight/runnir
codex plugin add runnir@runnir
```

Then ask the agent, in a repository you opened in Runnir, to set up the secrets and variables of its local runs.

## Other Builds And Places

Runnir Dev, Runnir Local and a Runnir outside `/Applications` are not reached by the plugin. Settings › MCP in that Runnir shows the command for Claude Code and the block for Codex's `config.toml`.

## Secrets

A secret you give an agent passes through it and its model before it reaches Runnir. Runnir never returns a secret's value to a client and never logs one.
