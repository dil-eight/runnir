# AI Architecture

Status: design. No chat, model adapter or AI runtime is implemented in this foundation.

Scheduling update: AI is optional future v0.3 work. The [v0.1 specification](../product/specification.md) takes precedence over earlier AI-first implementation priorities; no model/provider infrastructure is needed for MVP completion.

Swift owns the native chat and AgentOrchestrator. Providers return typed intents and tool requests; Go Core performs portable deterministic analysis and domain operations. Views do not call providers directly. Tool requests pass through application/Core policy and approval enforcement outside the model.

## Providers

| Provider | Role | Policy |
| --- | --- | --- |
| Apple Foundation Models | Default on-device intent recognition, tool selection, summaries and structured responses on compatible Macs | Check runtime/device/OS availability; retain dashboard and deterministic tools when unavailable |
| Runnir CI Model | Optional specialized local model; initial evaluation candidate Qwen3 4B | Approximately 2–3 GB quantized weights is an estimate, not memory footprint; evaluate quality, license, runtime and memory before adoption |
| Codex | Optional supported App Server or SDK integration | Follow official auth requirements; ChatGPT subscription does not imply arbitrary API access |
| Claude | Optional official API/SDK integration | No undocumented subscription credential reuse |
| Ollama / LM Studio | Future local adapters | Verify endpoint and whether inference stays local |

Download/load the optional model only after opt-in. Do not run multiple models concurrently by default. No paid AI requirement; no premature fine-tuning. LoRA/QLoRA is an experiment after a representative CI benchmark demonstrates need.

## Data And Tools

Consent is scoped by provider, repository and data category (source, workflows, logs, metadata). Minimize and redact context; default to on-device processing. Logs and workflows cannot override instructions, grant permissions or cause unreviewed tool execution. No unrestricted command tool.

Failure analysis cites log spans. Workflow generation uses structured definitions, templates, Go generation, actionlint and compatibility/security checks before a diff and explicit approval. Calculations of CI cost and repeated builds remain deterministic.

## Prompt Prefix Caching

Status: design rules for v0.3; nothing is built.

Providers reuse a request's computation when its beginning matches a recent request byte for byte: Claude's prompt caching on the API, the KV cache of llama.cpp, Ollama and LM Studio for local models. Runnir's AI work fits this well: a large context that stays the same (instructions, tools, workflow files, a job's log) and a short question that changes. On Claude a cached read costs a fraction of normal input and answers sooner. Without it, every follow-up question about a failed job pays for the whole log again.

| Use | Shared prefix | Varying tail |
| --- | --- | --- |
| Explaining a failed job | Instructions, the workflow file at the run's commit, the job graph, the log tail the Core read (up to 2 MiB) | The user's questions about it |
| Chat in a workspace | Runnir's tools, the workspace's workflow files, actionlint diagnostics | The conversation |
| Generating or repairing a workflow | Instructions, templates, the current file | Each round of generate, check in the Core, feed back the errors |

Rules for the context the Core assembles:

- **Order:** tools, then the system prompt, then repository context, then the log, then the question. A change to any byte invalidates everything after it.
- **Deterministic bytes:** the Core renders the context: workflow files in sorted order, JSON with sorted keys, no times, paths, request ids or other per-request values in the prefix. Two requests about the same run produce the same prefix.
- **Volatile data last:** freshness, the state of an active run, the current time go after the cached part. New operator instructions in a conversation are appended as a system message, not written into the top-level system prompt, so the history stays cached.
- **One tool list:** every request sends the same sorted set of tools; what a mode may not use is refused by the Core's policy, not left out of the request.
- **Lifetime to fit the use:** someone reading a failed job comes back after minutes, so the explanation's prefix uses the 1-hour lifetime, or is warmed (a request that generates nothing) when the panel opens; a generate-and-check loop stays inside the 5-minute default.
- **Measured:** each answer's cached and written input tokens are recorded with the request, so a prefix that stopped matching shows up as reads falling to zero.
- **Consent first:** caching changes nothing about what leaves the Mac. A log or workflow is sent only under the consent above; the provider keeps the cache for its lifetime and never shares it outside the account.

The MCP server (v0.3, [MCP](mcp.md)) follows the same rule from the other side: the descriptions of its tools land in the prefix of the external client's requests, so the tool catalog (`mcp/runnir-tools.json`) is kept in a stable, sorted order and changes only with a release.

## Local Offer Matching

With user-selected repository access, deterministic extractors derive stack/features locally from bounded manifests and workflows. AI may explain the match and ask about unknown requirements. Match a downloaded offer catalog locally; never send extracted stack, repository identifiers or code to the catalog service. Ranking uses fit, eligibility, cost and user preferences, independently of commission. See [catalog contract](../architecture/offers-catalog.md).
