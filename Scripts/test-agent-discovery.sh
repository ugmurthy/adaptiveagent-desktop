#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${1:-$ROOT/Resources/AgentRuntime/agent-runtime}"

if [[ ! -x "$RUNTIME" ]]; then
  echo "Runtime is missing or not executable: $RUNTIME" >&2
  echo "Usage: $0 [path-to-agent-runtime]" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to validate and format the discovery response." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' \
  '{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":"1.19","clientInfo":{"name":"agent-discovery-smoke-test","version":"1.0.0"},"capabilities":{}}}' \
  '{"jsonrpc":"2.0","id":"agents-list","method":"agents/list","params":{}}' \
  | "$RUNTIME" >"$TMP/stdout" 2>"$TMP/stderr"

READY="$(sed -n '1p' "$TMP/stdout")"
INITIALIZED="$(sed -n '2p' "$TMP/stdout")"
DISCOVERY="$(sed -n '3p' "$TMP/stdout")"

if ! jq -e '
  .jsonrpc == "2.0" and
  .method == "runtime/ready" and
  .params.protocolVersion == "1.19" and
  (has("id") | not)
' >/dev/null <<<"$READY"; then
  echo "Runtime did not emit a valid protocol 1.19 runtime/ready notification:" >&2
  cat "$TMP/stdout" >&2
  exit 1
fi

if ! jq -e '
  .jsonrpc == "2.0" and
  .id == "initialize" and
  .result.protocolVersion == "1.19" and
  (.result.capabilities.methods | index("agents/list") != null)
' >/dev/null <<<"$INITIALIZED"; then
  echo "Runtime did not negotiate protocol 1.19 with agents/list support:" >&2
  cat "$TMP/stdout" >&2
  exit 1
fi

if ! jq -e '
  .jsonrpc == "2.0" and
  .id == "agents-list" and
  (.result.agents | type == "array") and
  (.result.diagnostics | type == "array")
' >/dev/null <<<"$DISCOVERY"; then
  echo "agents/list returned an invalid response:" >&2
  cat "$TMP/stdout" >&2
  exit 1
fi

echo "Agent discovery succeeded."
jq '{
  settingsPath: .result.settingsPath,
  currentAgent: .result.currentAgent,
  agentCount: (.result.agents | length),
  agents: .result.agents,
  diagnostics: .result.diagnostics
}' <<<"$DISCOVERY"

if [[ -s "$TMP/stderr" ]]; then
  echo >&2
  echo "Runtime diagnostics (stderr):" >&2
  cat "$TMP/stderr" >&2
fi
