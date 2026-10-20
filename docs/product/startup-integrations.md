# Startup Integrations

Status: specification only. No tools are installed and no cloud resources or affiliate accounts are created by this iteration.

MVP scheduling: Docker/OrbStack/act readiness supports required v0.1 local execution. DigitalOcean/doctl, landing deployments and offer matching/catalog work are deferred and do not gate v0.1. The [current MVP specification](specification.md) supersedes earlier parallel implementation priorities.

## Docker And OrbStack

When a user requests compatible Linux workflow execution, inspect tool readiness through a future typed Core adapter: Docker CLI present, chosen context, engine reachable, platform/architecture and act availability. Support Docker Desktop and OrbStack's Docker-compatible engine on macOS; portable Core can also use Linux Docker Engine. Never silently switch the global context or select a remote daemon.

If absent, offer vendor installation guidance at the point of need. Distinguish missing CLI, stopped engine and unsupported job. Static parsing/actionlint/planning must work without a container engine. Do not install both engines by default.

Prefer opening official installers/instructions. On macOS, Homebrew commands may be shown for user execution after checking Homebrew availability; the app must not silently write to global tool directories. Any later in-app installer needs a reviewed system integration design, explicit installation consent, verified downloads and license acceptance. Installing tools does not grant workflow execution permission.

OrbStack is free for personal non-commercial use; business/commercial use requires a license. Docker Desktop has a conditional small-business free allowance. Show current terms before choosing. Neither engine establishes a secure sandbox for arbitrary workflows; see [execution architecture](../architecture/workflow-intelligence.md).

Sources: [OrbStack install](https://docs.orbstack.dev/install), [OrbStack pricing](https://orbstack.dev/pricing), [Docker Desktop license](https://docs.docker.com/subscription-billing/desktop-license/).

## DigitalOcean And doctl

Plan a typed Core DigitalOcean adapter for account readiness, App Platform specs, deployment preview/status and explicitly approved creation/update. Desktop credentials stay in Keychain; headless credential design must be settled separately. No token in argv, repository, diagnostic output or affiliate catalog.

Detect doctl only when the integration is requested; offer official install steps (macOS: `brew install doctl`) or verified vendor binaries. Installation is optional and separately authorized. Do not run `doctl auth init` from Runnir: its persistent CLI configuration conflicts with Runnir's Keychain-only credential policy. Prefer the official API through a scoped credential broker. Evaluate any future doctl invocation for config persistence and process-environment exposure; this is unresolved, not completed auth.

Preview destination, source disclosure, resource type, build settings, estimated recurring charges/limits and rollback before provisioning. Grant the hosting provider repository access only for an explicitly chosen deployment. Never auto-upgrade a static site to paid compute or auto-approve production deployment.

Sources: [doctl installation](https://docs.digitalocean.com/reference/doctl/how-to/install/), [App Platform static sites](https://docs.digitalocean.com/products/app-platform/how-to/manage-static-sites/).

## Static Next.js Landing Template

Offer a reviewed export template for a user's project: static output only, no SSR, API routes, server actions, ISR or default server image optimizer. Validate export compatibility and routes before claiming deployability. The template is documentation in [Next static deployment](../templates/digitalocean-next-static.md); Runnir itself adds no Node/React runtime.

DigitalOcean currently offers up to three static-only apps free with 1 GiB outbound transfer per app; extra apps and overage can cost money. Eligibility, domains and provider terms must be checked at deployment time. Referral signup credit is separate from this free tier and may expire. Describe this as a conditional free-tier option, not permanently free hosting.

Sources: [App Platform pricing](https://docs.digitalocean.com/products/app-platform/details/pricing/), [Next.js static exports](https://nextjs.org/docs/app/guides/static-exports).

## Repository-Relevant Offers

Opt-in local analysis extracts bounded manifests/configuration from a user-selected repository. Start with package manifests, workflow YAML and container definitions; no secret files, `.git` history, dependencies or broad indexing. Treat executable configuration as text, never import/execute it for detection. Traverse safely within the repository and follow size/count limits.

Produce local facts with evidence and confidence: framework, static export suitability, container requirements, declared database/email/observability tools and existing integrations. The repository cannot reliably reveal company size, revenue, location, funding or existing vendor account eligibility; ask only when needed and keep answers local.

Match facts against the public catalog deterministically; AI can explain relevance and uncertainties. Example: static-export configuration -> static hosting candidate; Docker-based Linux job -> optional engine setup; existing observability SDK -> review the current service rather than propose a redundant one. Do not infer a purchase need merely because a dependency exists.

Rank by user goal, technical fit, eligibility, actual cost, privacy and preference. Commission never increases rank. Show a brief reason, supporting local evidence, caveats, verification date, referral disclosure, direct vendor option and dismiss/hide controls. Keep offers contextual and optional; no unsolicited chat advertising, automatic enrollment, analytics SDK insertion or purchases.

Live affiliate URLs and programs live outside the app bundle in a signed catalog. No real referral URLs have been supplied. Initial catalog examples use direct official links only. See [catalog architecture](../architecture/offers-catalog.md) and [research register](../research/startup-offers.md).
