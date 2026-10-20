#!/usr/bin/env bash

set -euo pipefail

SPOKE_NAME="${1:-}"

if [[ -z "${SPOKE_NAME}" ]]; then
  echo "Usage: $0 <spoke-name>"
  exit 1
fi

if ! [[ "${SPOKE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "Invalid spoke name: ${SPOKE_NAME}"
  exit 1
fi

OUTPUT="hub-spoke-centralized-observability/spokes/${SPOKE_NAME}.yaml"

if [[ -e "${OUTPUT}" ]]; then
  echo "Spoke descriptor already exists: ${OUTPUT}"
  exit 1
fi

cat > "${OUTPUT}" <<YAML
name: ${SPOKE_NAME}
YAML

echo "Created ${OUTPUT}"
echo
echo "Prerequisites for ${SPOKE_NAME}:"
echo "  - cluster is registered in Argo CD as ${SPOKE_NAME}"
echo "  - Kubara external-secrets component is enabled"
echo "  - SecretStore observability-mtls-reader exists on the spoke"
echo
echo "After this descriptor is committed, the ApplicationSets create:"
echo "  - hub Certificate"
echo "  - hub PushSecret"
echo "  - spoke ExternalSecret"
