#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:?usage: $0 /absolute/path/to/trace-session-sidecar}"
if [[ ! -f "$SOURCE" ]]; then
  echo "Trace-session helper not found: $SOURCE" >&2
  echo "Compile packages/trace-session/src/trace-sidecar.ts with bun build --compile." >&2
  exit 1
fi
install -m 755 "$SOURCE" "$ROOT/Resources/TraceSession/trace-session-sidecar"
echo "Installed local trace-session helper."
