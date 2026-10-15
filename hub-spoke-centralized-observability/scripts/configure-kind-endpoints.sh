#!/usr/bin/env bash

set -euo pipefail

HUB_IP="${1:-}"

if [[ -z "${HUB_IP}" ]]; then
  if command -v docker >/dev/null 2>&1; then
    HUB_IP="$(
      docker inspect hub-cluster-control-plane \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
        2>/dev/null || true
    )"
  fi
fi

if [[ -z "${HUB_IP}" ]]; then
  echo "Usage: $0 <hub-kind-container-ip>"
  echo
  echo "Example:"
  echo "  $0 <hub-kind-container-ip>"
  exit 1
fi

if ! [[ "${HUB_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid IPv4 address: ${HUB_IP}"
  exit 1
fi

PROJECT_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"

python3 - "${PROJECT_ROOT}" "${HUB_IP}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
hub_ip = sys.argv[2]

files = [
    root / "spoke/alloy/values.yaml",
    root / "hub/loki/values.yaml",
    root / "hub/thanos/resources.yaml",
    root / "hub/pki/leaf-certificates.yaml",
]

patterns = {
    r"loki\.observability\.example\.com":
        f"loki.{hub_ip}.traefik.me",

    r"thanos\.observability\.example\.com":
        f"thanos.{hub_ip}.traefik.me",

    r"loki\.\d+\.\d+\.\d+\.\d+\.traefik\.me":
        f"loki.{hub_ip}.traefik.me",

    r"thanos\.\d+\.\d+\.\d+\.\d+\.traefik\.me":
        f"thanos.{hub_ip}.traefik.me",
}

for path in files:
    text = path.read_text()
    updated = text

    for pattern, replacement in patterns.items():
        updated = re.sub(pattern, replacement, updated)

    path.write_text(updated)
    print(f"updated: {path.relative_to(root)}")

print()
print(f"Hub telemetry endpoints configured for {hub_ip}")
PY
