# Workflow Intelligence And Execution

Status: design; no workflow engine or sandbox implementation in the foundation.

Scope update: offline inspection/editing/actionlint and compatible opt-in act/Docker execution are required by FR-05/FR-06 of [MVP v0.1](../product/specification.md). The AI generation pipeline, automatic optimization and artifact-reuse sections below are later design work, not MVP prerequisites.

## Deterministic Workflow Engine

Core will parse workflows into structured intermediate definitions, inspect dependencies, permissions, cache opportunities, duplicate builds and artifact reuse, and generate YAML from verified templates. AI explains findings and proposes definitions; deterministic code owns correctness.

Pipeline: user request -> AI intent -> structured definition -> Go YAML generator -> actionlint -> security/compatibility validation -> optional sandbox test -> diff preview -> explicit approval -> apply. Approval is required for any local or remote workflow modification. Every explanation should link findings or relevant log lines; unsupported conclusions are hypotheses.

## Static First

Start with parsing, actionlint, dependency inspection, execution plans and compatibility reports. Later prototype compatible Linux jobs with Docker/act. Do not build a custom CI executor. Docker alone is not a security sandbox for untrusted workflows. Execution requires temporary workspaces, resource limits, bounded credentials/network/filesystem access and explicit consent; strong isolation may require a dedicated VM. Treat workflow scripts, action dependencies and logs as untrusted. Native macOS/iOS simulator execution has a separate platform policy and runner path.

## Build Once, Deploy Anytime

Model logical pipelines across multiple actual GitHub runs. The public GitHub API cannot arbitrarily resume skipped jobs in an existing run. A compatible opt-in deployment workflow consumes a trusted artifact from an explicit build reference, avoiding unnecessary rebuilds.

Track repository, commit SHA, workflow run ID, run attempt, artifact ID/provenance, deployment target and deployment run ID. Validate producer, commit, integrity, expiry, compatibility and authorization before reuse; mutable names alone cannot establish provenance. Offer templates and enhanced integration as opt-in diffs. Production deployment always needs explicit authorization outside the model.
