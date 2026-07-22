#!/usr/bin/env bash
set -euo pipefail
TAG="${1:?usage: $0 <tag> [github-repository]}"
REPOSITORY="${2:-ugmurthy/adaptiveagent}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *) echo "Unsupported Mac architecture: $(uname -m)" >&2; exit 1 ;;
esac
ASSET="adaptive-agent-runtime-${TAG}-darwin-${ARCH}.tar.gz"
URL="https://github.com/${REPOSITORY}/releases/download/${TAG}/${ASSET}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 "$URL" -o "$TMP/runtime.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://github.com/${REPOSITORY}/releases/download/${TAG}/checksums.txt" \
  -o "$TMP/checksums.txt"
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1; exit }' "$TMP/checksums.txt")"
[[ -n "$EXPECTED" ]] || { echo "No checksum published for ${ASSET}" >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$TMP/runtime.tar.gz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "Checksum mismatch for ${ASSET}" >&2; exit 1; }
tar -xzf "$TMP/runtime.tar.gz" -C "$TMP"
RUNTIME="$(find "$TMP" -type f -name agent-runtime -print -quit)"
[[ -n "$RUNTIME" ]] || { echo "Artifact does not contain agent-runtime" >&2; exit 1; }
install -m 755 "$RUNTIME" "$ROOT/Resources/AgentRuntime/agent-runtime"
echo "Installed ${TAG} runtime for ${ARCH}."
