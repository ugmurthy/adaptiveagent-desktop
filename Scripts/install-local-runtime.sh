#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/../repo/packages/desktop-bridge/dist/agent-runtime}"
if [[ ! -f "$SOURCE" ]]; then
  echo "Runtime not found: $SOURCE" >&2
  echo "Pass the path to a locally built standalone agent-runtime executable." >&2
  exit 1
fi
install -m 755 "$SOURCE" "$ROOT/Resources/AgentRuntime/agent-runtime"
echo "Installed local runtime."
