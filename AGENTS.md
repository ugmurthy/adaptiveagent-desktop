Agent runtime integration

Architecture boundary

This SwiftUI application bundles and launches the Adaptive Agent
agent-runtime executable.

The executable is built from @adaptive-agent/desktop-bridge using:

bun run --cwd packages/desktop-bridge compile

This produces:

packages/desktop-bridge/dist/agent-runtime

In this repository:

- Call this component the agent runtime process or runtime bridge.
- Do not introduce or restore a legacy Sidecar service, sidecar framework,
  sidecar-specific API, HTTP server, WebSocket transport, or XPC protocol.
- The Swift application launches agent-runtime as a managed child process.
- Communication with that process exclusively uses protocol "1.10", which
  uses JSON-RPC 2.0 over newline-delimited stdin/stdout.
- Protocol "1.10" is the only supported protocol version.
- Do not emit, accept, or depend on the removed protocol-v1
  { "version", "id", "type" } envelope, including during startup.
- Do not fall back to protocol v1 when protocol "1.10" negotiation fails.
  Report an incompatible-runtime error instead.
- Treat a legacy-shaped message from the runtime as an incompatible-runtime or
  protocol error rather than attempting to decode it.
- Do not reimplement agent execution, tools, model calls, persistence,
  approvals, retries, or run recovery in Swift. Those responsibilities belong
  to agent-runtime.
- Swift owns process lifecycle, JSON-RPC request correlation, notification
  handling, protocol compatibility checks, and UI state presentation.

Transport contract

agent-runtime uses newline-delimited JSON:

- Swift writes one UTF-8 JSON object followed by \n to process stdin.
- Swift reads one UTF-8 JSON object per line from process stdout.
- Every protocol message, including the initial runtime/ready message, uses
  a JSON-RPC 2.0 envelope.
- Process stderr contains diagnostics only and must never be parsed as protocol
  data.
- Do not assume one FileHandle read callback equals one JSON message. Buffer
  bytes and split complete messages on newline boundaries.
- Requests may execute concurrently and responses may arrive out of order.
  Correlate every response using its JSON-RPC id.
- Runtime notifications do not contain an id and must be processed
  independently from responses.
- JSON-RPC batch requests are unsupported.
- Client-originated JSON-RPC notifications are unsupported. Every Swift
  request must contain an id.
- Request IDs are strings or finite numbers and must not be coerced.
- A message without "jsonrpc": "2.0" is not a valid runtime protocol
  message.

Required startup sequence

1. Launch the bundled agent-runtime executable.
2. Read its JSON-RPC runtime/ready notification.
3. Verify that params.protocolVersion is exactly the string "1.10".
4. If the version is missing or unsupported, terminate the process and report
   an incompatible-runtime error. Do not attempt a protocol-v1 fallback.
5. Send the JSON-RPC initialize request shown below.
6. Verify that the successful response selects protocol "1.10".
7. Send runtime/initialize.
8. Only after both initialization operations succeed, issue methods that
   require the persistent agent runtime, such as agent/run.
9. Before normal termination, send runtime/shutdown, wait for its response,
   and then close stdin.

The startup message is a JSON-RPC notification. It has no request id:

{
"jsonrpc": "2.0",
"method": "runtime/ready",
"params": {
"protocolVersion": "1.10",
"bridgeVersion": "0.1.0",
"pid": 1234
}
}

The first outbound request must negotiate protocol "1.10" using JSON-RPC
2.0:

{
"jsonrpc": "2.0",
"id": "initialize",
"method": "initialize",
"params": {
"protocolVersion": "1.10",
"clientInfo": {
"name": "<Swift application name>",
"version": "<application version>"
},
"capabilities": {}
}
}

protocolVersion must be the JSON string "1.10", never the number 1.10.
JSON numeric values cannot distinguish 1.10 from 1.1.

After protocol negotiation, initialize the persistent agent runtime separately:

{
"jsonrpc": "2.0",
"id": "runtime-initialize",
"method": "runtime/initialize",
"params": {
"cwd": "/workspace",
"runtimeMode": "postgres",
"approvalMode": "manual",
"clarificationMode": "interactive"
}
}

Protocol initialization and agent runtime initialization are separate:

- initialize negotiates the bridge protocol and must succeed before other
  JSON-RPC methods are used.
- runtime/initialize creates the persistent agent runtime and model/runtime
  dependencies.
- runtime/info and supported CLI inspection methods may be used after
  protocol initialization without eagerly creating the agent runtime.
- Agent operations such as agent/run require runtime/initialize to have
  completed successfully.

All messages use JSON-RPC 2.0 before, during, and after initialization. There is
no legacy-shaped bootstrap exception.

Removed protocol-v1 format

The following format is removed and must never be emitted by Swift:

{
"version": 1,
"id": "hello",
"type": "hello"
}

agent-runtime rejects this shape with a JSON-RPC INVALID_REQUEST error both
before and after protocol initialization. Receiving such an error does not
indicate that the client should retry using protocol v1.

JSON-RPC envelopes

Request:

{
"jsonrpc": "2.0",
"id": "request-1",
"method": "agent/run",
"params": {
"goal": "Summarize this repository"
}
}

Successful response:

{
"jsonrpc": "2.0",
"id": "request-1",
"result": {}
}

Error response:

{
"jsonrpc": "2.0",
"id": "request-1",
"error": {
"code": -32602,
"message": "Invalid parameters",
"data": {
"protocolCode": "INVALID_PARAMS"
}
}
}

Runtime event notification:

{
"jsonrpc": "2.0",
"method": "agent/event",
"params": {
"schemaVersion": 1,
"type": "run.status_changed",
"runId": "..."
}
}

Runtime notifications are distinguished from responses by the presence of
method and the absence of id. Do not attempt to correlate notifications
with pending requests.

API usage rules

Prefer typed JSON-RPC methods for persistent desktop operations:

- agent/run
- agent/chat
- run/resume
- run/retry
- run/recover
- run/continue
- run/interrupt
- run/inspect
- run/replay
- run/steer
- interaction/resolveApproval
- interaction/resolveClarification

Use cli/execute only for non-interactive CLI functionality that has no typed
JSON-RPC method. Do not use cli/execute as the normal implementation of run,
chat, approval, clarification, steering, or recovery workflows.

Provider credentials and DATABASE_URL must be supplied through the runtime
process environment. Never place credentials in JSON-RPC parameters, logs, or
persisted UI state.

Tests required when changing the runtime client

Tests must cover:

- Parsing the initial JSON-RPC runtime/ready notification.
- Verifying that runtime/ready.params.protocolVersion is exactly the string
  "1.10".
- Verifying that runtime/ready has no id.
- Negotiating protocol "1.10" as a string.
- Ensuring every outbound request contains "jsonrpc": "2.0" and an id.
- Rejecting or surfacing unsupported protocol versions without protocol-v1
  fallback.
- Rejecting a legacy-shaped startup or operational message rather than
  attempting to decode it.
- Buffering fragmented stdout data until a complete newline-delimited message
  is available.
- Parsing multiple JSON messages received in one stdout chunk.
- Correlating out-of-order responses by request ID.
- Dispatching runtime/ready, agent/event, and cli/output notifications
  separately from responses.
- Decoding JSON-RPC errors and error.data.protocolCode.
- Separating protocol initialization from runtime/initialize.
- Preventing agent operations before runtime/initialize succeeds.
- Graceful runtime/shutdown, including waiting for its response before
  closing stdin.
- Unexpected child-process termination.
- Verifying that no Swift code emits or expects the removed
  {version,id,type} protocol-v1 format.
