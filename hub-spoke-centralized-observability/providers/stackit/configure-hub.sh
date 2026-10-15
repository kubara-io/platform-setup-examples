#!/usr/bin/env bash

set -euo pipefail

: "${STACKIT_SM_ID:?Set STACKIT_SM_ID}"
: "${STACKIT_SM_RW_USERNAME:?Set STACKIT_SM_RW_USERNAME}"

STACKIT_SM_SERVER="${STACKIT_SM_SERVER:-https://prod.sm.eu01.stackit.cloud}"
HUB_CONTEXT="${HUB_CONTEXT:-kind-hub-cluster}"

STORE_NAME="${STORE_NAME:-observability-mtls-writer}"
CREDENTIAL_SECRET="${CREDENTIAL_SECRET:-stackit-sm-rw-credentials}"

kubectl --context "${HUB_CONTEXT}" get namespace observability >/dev/null

read -r -s -p "STACKIT Secrets Manager RW password: " PASSWORD
echo

kubectl --context "${HUB_CONTEXT}" \
  -n observability create secret generic "${CREDENTIAL_SECRET}" \
  --from-literal=password="${PASSWORD}" \
  --dry-run=client -o yaml \
  | kubectl --context "${HUB_CONTEXT}" apply -f -

unset PASSWORD

cat <<YAML | kubectl --context "${HUB_CONTEXT}" apply -f -
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
          username: "${STACKIT_SM_RW_USERNAME}"
          secretRef:
            name: ${CREDENTIAL_SECRET}
            key: password
YAML

echo
echo "Hub mTLS writer:"
kubectl --context "${HUB_CONTEXT}" \
  -n observability get secretstore "${STORE_NAME}"
