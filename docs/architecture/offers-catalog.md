# External Offer Catalog And Local Matching

Status: contract/design, no fetcher, matcher or recommendation UI implemented.

This is unscheduled post-MVP work; it is not a v0.1 dependency. See the [roadmap](../product/roadmap.md).

## Distribution

Publish a static versioned catalog from a separate maintained repository or static HTTPS endpoint. It is independent of app releases and not bundled as live marketing data. Only the schema, verification code/public keys and approved origin policy belong in the app; documentation examples are not app resources.

Prefer an opt-in manual refresh initially. Fetch the same public catalog for every user, with no repository/stack/profile query parameters, cookies, account IDs, fingerprinting or click reporting. The hosting service necessarily sees a connection IP; explain this when enabling downloads. Cache only a verified catalog in app-managed storage. Core operation works offline with no offers.

Use detached signatures over exact catalog bytes (proposed Ed25519), a pinned verification key, schema version, monotonic revision, issue/expiry timestamps and a bounded payload. Specify key rotation/revocation before launch. Reject invalid signatures, expired catalogs, unsupported schemas, rollbacks, excessive entries and unsafe URLs. Signed data remains untrusted content.

Catalog entries carry ID, provider, category, program type, direct URL, optional approved affiliate URL, disclosure, source/terms URLs, eligibility, supported stack tags, cost caveats, checked/expiry dates, regions and enabled status. Affiliate onboarding and allowed promotional surfaces must be reviewed before enabling a link. Do not assume referral credit programs permit unrestricted commercial promotion in desktop software.

No scripts, install commands, YAML templates, executable code, model instructions or provider credentials in the catalog. Installer recipes and typed deployment templates are separately reviewed/versioned application capabilities. A catalog update cannot add tools, grant repository access or alter approvals.

Require HTTPS and approved provider/affiliate-network destinations; validate the entire redirect policy and reject custom schemes, embedded credentials and localhost/private-network targets. Open links only after user action; display the destination and affiliate relationship. Provide an equivalent direct link. Templates and navigation never include user/repository data in referral parameters.

## Matching Boundary

Selected repository -> bounded deterministic local facts -> eligibility/compatibility filters -> transparent ranking -> optional local AI explanation -> user-selected link.

The matcher runs in Core as a pure service. It receives local facts and verified catalog entries, not filesystem or network access. Swift orchestrates consent and presentation. The catalog server receives none of the local facts. AI does not invent eligibility, savings, coupon terms or payout amounts.

Use declarative matching tags, not downloaded rules that execute code. Distinguish inferred compatibility from proven deployment compatibility; check Next.js export locally before offering the static template. User-declared constraints override inferred preferences. Negative matches (already using provider, incompatible region, paid commercial license) are first-class.

## Required Verification Before Shipping

Test signature/expiry/rollback/URL rejection, offline behavior, scope/traversal limits, executable-config avoidance, incorrect eligibility, irrelevant/duplicate suppression, redaction and commission-independent ranking. Verify each program's terms for desktop placement, disclosures and brand usage with the program owner. No catalog service or affiliate program is live yet.
