# IPC Contract v1

> The app's runtime transport is the persistent local gRPC API described in [Core gRPC API v1](grpc-api.md) ([ADR 0004](../decisions/0004-single-core-process-grpc.md)). This document describes the earlier one-shot JSON-RPC stdio transport, which is kept for the version handshake (`runnir rpc`, `core.v1.version`; the app still uses it once at launch to read the Core version) and is not extended.

Status: implemented for version metadata only.

## Transport

The app launches its bundled `Contents/Helpers/runnir-core rpc` directly with Foundation Process. No shell or executable discovery from a repository is involved. The environment is reduced to LANG; the child working directory is its bundle helper directory. stdout contains protocol frames only, stderr is diagnostic-only and must never echo requests or secrets.

Frames are UTF-8 JSON objects delimited by LF. Maximum JSON frame size: 65,536 bytes. Oversize input terminates the server with a nonzero exit status. The Go adapter handles sequential requests until stdin EOF; the initial desktop transport sends one request, closes stdin, and waits for exit. The desktop version request is small; response size is bounded and a five-second timeout kills and reaps the child. Cancellation is observed before/after exchange; cleanup may take up to that timeout. No background daemon or listening socket is created.

This is a restricted [JSON-RPC 2.0](https://www.jsonrpc.org/specification) profile: single objects only, no batches. Valid notifications receive no response. String IDs are preferred; Core also accepts numeric/null IDs and echoes them. Desktop clients require exact ID correlation and exactly one result or error.

## Method

`core.v1.version`: no params, or empty object/array. No authentication, network, filesystem scope or approval is needed.

```json
{"jsonrpc":"2.0","id":"desktop-1","method":"core.v1.version"}
```

```json
{"jsonrpc":"2.0","id":"desktop-1","result":{"version":"0.1.0-dev","protocolVersion":1}}
```

Product version and IPC version are independent. Unknown methods return -32601; malformed JSON -32700; invalid envelope or unsupported batch -32600; invalid params -32602. Error responses have no result and contain a code/message pair. Invalid envelopes use null ID. Clients reject unknown protocol versions before attempting domain calls. Breaking changes require a new method namespace and protocol negotiation; compatible additive result fields may be ignored.

The machine-readable version envelopes are in `contracts/ipc/v1/version.schema.json`. CLI `version` returns the result object directly, without an RPC envelope.

## Session Contracts

Desktop window restoration sessions and Core credential/process sessions are separate concepts. [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md) requires shared workspace services/events behind versioned IPC, independent of window identity. The shared repository contexts and event stream now live in the [gRPC API](grpc-api.md); the shared database and sync writer are still not implemented. The one-shot transport here must not be described as a streaming or shared-runtime implementation. Core stays app-owned with no permanent daemon; no process is resumed from session.json.

Repository capability grants, credential lifetimes, request cancellation and action approval are not implemented. Define and test these before adding domain operations. A path or boolean supplied by an AI/client cannot grant access or approve an action. Scope grants must resolve symlinks and prevent traversal; consequential approvals bind repository, operation, inputs, artifact identity, expiry and single-use action ID through a trusted local authority. Keep tokens out of JSON tool results and audit data.

MCP will be a separate stdio entry point with its own initialization and protocol contracts, reusing Core services. `runnir rpc` is not an MCP server. What an MCP adapter would still need from the Core is listed in [MCP readiness](mcp.md#readiness-against-the-grpc-core-api).
