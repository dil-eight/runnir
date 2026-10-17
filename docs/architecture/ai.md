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

## Local Offer Matching

With user-selected repository access, deterministic extractors derive stack/features locally from bounded manifests and workflows. AI may explain the match and ask about unknown requirements. Match a downloaded offer catalog locally; never send extracted stack, repository identifiers or code to the catalog service. Ranking uses fit, eligibility, cost and user preferences, independently of commission. See [catalog contract](../architecture/offers-catalog.md).
