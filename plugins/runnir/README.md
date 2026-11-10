# Runnir Plugin For Claude Code And Codex

Runnir is a macOS app for GitHub Actions. This plugin lets Claude Code or Codex drive it for the repositories you opened in Runnir:

- Read: workspaces, workflows with actionlint's problems, what a pull request, push, merge or tag starts (`runnir_plan_scenario`), runs on GitHub with their jobs and logs, pull requests, and local runs with their output.
- Run locally: `runnir_start_local_run` runs a scenario's workflows on your Mac with act, as Run Locally does, and `runnir_get_local_run` follows it.
- Act on GitHub: start a workflow (`runnir_dispatch_workflow`), cancel or re-run a run.
- Values: `runnir_list_value_sets` and `runnir_set_values` fill in the secrets and variables local runs read. Secret values never come back.

Agents act without a click. Runnir asks you in its window only before saving values and before running macOS jobs without the macOS sandbox. Settings › MCP › Allow actions turns every action off; reading keeps working.

The plugin brings two skills: `github-actions` (why a run failed, running locally before a push, acting on GitHub) and `local-run-values`.

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

Then ask the agent, in a repository you opened in Runnir, why its last CI run failed, or to run its pull request workflows locally.

## Other Builds And Places

Runnir Dev, Runnir Local and a Runnir outside `/Applications` are not reached by the plugin. Settings › MCP in that Runnir shows the command for Claude Code and the block for Codex's `config.toml`.

## Secrets

A secret you give an agent passes through it and its model before it reaches Runnir. Runnir never returns a secret's value to a client and never logs one.
