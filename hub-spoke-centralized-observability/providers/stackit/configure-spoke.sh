#!/usr/bin/env bash

set -euo pipefail

SPOKE_NAME="${1:-}"

if [[ -z "${SPOKE_NAME}" ]]; then
  echo "Usage: $0 <spoke-name>"
  exit 1
fi

: "${STACKIT_SM_ID:?Set STACKIT_SM_ID}"
: "${STACKIT_SM_RO_USERNAME:?Set STACKIT_SM_RO_USERNAME}"

STACKIT_SM_SERVER="${STACKIT_SM_SERVER:-https://prod.sm.eu01.stackit.cloud}"
SPOKE_CONTEXT="${SPOKE_CONTEXT:-kind-${SPOKE_NAME}}"

STORE_NAME="${STORE_NAME:-observability-mtls-reader}"
CREDENTIAL_SECRET="${CREDENTIAL_SECRET:-stackit-sm-ro-credentials}"

kubectl --context "${SPOKE_CONTEXT}" get namespace observability >/dev/null

read -r -s -p "STACKIT Secrets Manager RO password: " PASSWORD
echo

kubectl --context "${SPOKE_CONTEXT}" \
  -n observability create secret generic "${CREDENTIAL_SECRET}" \
  --from-literal=password="${PASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl --context "${SPOKE_CONTEXT}" apply -f -

unset PASSWORD

cat <<YAML | kubectl --context "${SPOKE_CONTEXT}" apply -f -
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: ${STORE_NAME}
  namespace: observability
spec:
  provider:
    vault:
      server: ${STACKIT_SM_SERVER}
      path: ${STACKIT_SM_ID}
      version: v2
      auth:
        userPass:
          path: userpass
          username: "${STACKIT_SM_RO_USERNAME}"
          secretRef:
            name: ${CREDENTIAL_SECRET}
            key: password
YAML

echo
echo "Spoke mTLS reader:"
kubectl --context "${SPOKE_CONTEXT}" \
  -n observability get secretstore "${STORE_NAME}"
