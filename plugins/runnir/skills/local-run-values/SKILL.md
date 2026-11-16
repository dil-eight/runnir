---
name: local-run-values
description: Use when the user wants to set, fill in, copy or check the secrets or variables that Runnir's local runs of GitHub Actions workflows use (for example "set up the secrets for local runs", "put my .env into Runnir", "which values is Runnir missing"). Uses the runnir_list_value_sets and runnir_set_values tools.
---

# Values For Runnir's Local Runs

Runnir runs a repository's GitHub Actions workflows on the user's Mac. The secrets and variables those local runs read live in Runnir, in sets: `Repository`, and one per environment (such as `production` or `staging`). An environment without its own value uses the Repository's. These values are local to the Mac; they are not the repository's secrets on GitHub.

## Steps

1. Call `runnir_list_value_sets` with `repository` set to the absolute path of the repository you are working in (its root folder). A workspace's name also works when it is unique.
2. Read what comes back. Each set lists names, each a secret or a variable, with a state: `saved`, `from_repository` (the environment uses the Repository's value), `missing` (a job needs it and it has no value) or `not_needed` (no value, and no job needs one). A secret's value is never returned; a variable's may be.
3. Get the values only from the user or from files they point you to (for example `.env` or `.env.local`). Never make up a value, and never take one from a file the user did not mention. Ask which set a value belongs to when it is not clear; put it in the Repository unless it differs per environment.
4. Call `runnir_set_values` once per set, with all of that set's names: `secrets` and `variables` as objects of name to value. A name is a secret or a variable as the list says.
5. The call waits while Runnir shows the change in its own window and the user presses Save or Cancel, for up to five minutes. Tell the user to look at Runnir.
6. Report the saved names. Never repeat a secret's value in the chat, in a file or in a command.

## When A Call Is Refused

- "Runnir is not running": ask the user to open Runnir, then try again.
- The repository is not a registered workspace: ask the user to open its folder in Runnir (Open Workspace), then try again.
- "Cancelled in Runnir": nothing was saved. Do not call again unless the user asks.
- Not answered in time: ask the user whether to try again.
- A name was refused: GitHub's rules apply. Letters, digits and `_`, not starting with a digit or `GITHUB_` (`GITHUB_TOKEN` is allowed: a local run has no token of its own). At most 100 names and 48 KiB a value in one call.

To clear a value, the user does it in Runnir's Secrets and Variables; these tools only list and save.

A secret given to these tools passes through you and your model on its way to Runnir. Tell the user so when they are about to paste one.
