#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${AGENT_RUNTIME:-$ROOT/Resources/AgentRuntime/agent-runtime}"

usage() {
  cat >&2 <<'EOF'
Usage: test-context.sh <subcommand> [arguments and options]

Subcommands:
  create <name> --ref <run:id|session:id> [--ref ...]
                [--description <text>] [--force] [--dry-run]
  list
  show <name>
  delete <name> [--dry-run]

All subcommands accept --cwd <directory> and --output <format>.
Set AGENT_RUNTIME=/path/to/agent-runtime to test a different executable.

Examples:
  ./Scripts/test-context.sh list
  ./Scripts/test-context.sh create demo --ref run:RUN_ID --description "Manual test" --dry-run
  ./Scripts/test-context.sh show demo
  ./Scripts/test-context.sh delete demo --dry-run
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

case "$1" in
  create|list|show|delete) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unsupported context subcommand: $1" >&2
    usage
    exit 2
    ;;
esac

if [[ ! -x "$RUNTIME" ]]; then
  echo "Runtime is missing or not executable: $RUNTIME" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to construct and validate JSON-RPC messages." >&2
  exit 1
fi

ARGS=("context" "$@")
HAS_CWD=false
for ARG in "${ARGS[@]}"; do
  case "$ARG" in
    --cwd|--cwd=*) HAS_CWD=true ;;
  esac
done
if [[ "$HAS_CWD" == false ]]; then
  ARGS+=("--cwd" "$PWD")
fi

ARGV_JSON="$(jq -cn --args '$ARGS.positional' -- "${ARGS[@]}")"
EXECUTE_REQUEST="$(jq -cn --argjson argv "$ARGV_JSON" '{
  jsonrpc: "2.0",
  id: "context",
  method: "cli/execute",
  params: {argv: $argv}
}')"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' \
  '{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":"1.19","clientInfo":{"name":"context-smoke-test","version":"1.0.0"},"capabilities":{}}}' \
  "$EXECUTE_REQUEST" \
  | "$RUNTIME" >"$TMP/protocol" 2>"$TMP/runtime-stderr"

if ! jq -s -e '
  any(.[];
    .jsonrpc == "2.0" and
    .method == "runtime/ready" and
    .params.protocolVersion == "1.19" and
    (has("id") | not)
  ) and
  any(.[];
    .id == "initialize" and
    .result.protocolVersion == "1.19" and
    (.result.capabilities.methods | index("cli/execute") != null)
  )
' "$TMP/protocol" >/dev/null; then
  echo "Runtime did not negotiate protocol 1.19 with cli/execute support:" >&2
  cat "$TMP/protocol" >&2
  exit 1
fi

while IFS= read -r MESSAGE; do
  if [[ "$(jq -r '.method // empty' <<<"$MESSAGE")" != "cli/output" ]] ||
     [[ "$(jq -r '.params.requestId // empty' <<<"$MESSAGE")" != "context" ]]; then
    continue
  fi
  if [[ "$(jq -r '.params.stream // empty' <<<"$MESSAGE")" == "stderr" ]]; then
    jq -r '.params.line' <<<"$MESSAGE" >&2
  else
    jq -r '.params.line' <<<"$MESSAGE"
  fi
done <"$TMP/protocol"

RESULT="$(jq -c 'select(.id == "context")' "$TMP/protocol" | tail -n 1)"
if [[ -z "$RESULT" ]]; then
  echo "cli/execute did not return a response." >&2
  exit 1
fi

if ! jq -e '.error == null and .result.exitCode == 0 and .result.timedOut == false' \
  >/dev/null <<<"$RESULT"; then
  echo "Context command failed:" >&2
  jq . <<<"$RESULT" >&2
  exit 1
fi

if [[ -s "$TMP/runtime-stderr" ]]; then
  echo "Runtime diagnostics (stderr):" >&2
  cat "$TMP/runtime-stderr" >&2
fi

jq -r '"Context command succeeded: " + (.result.argv | join(" "))' <<<"$RESULT" >&2
