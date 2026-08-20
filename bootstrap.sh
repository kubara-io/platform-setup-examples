#!/usr/bin/env bash
set -euo pipefail

HOST_CTX="${HOST_CTX:-kind-kubara-poc}"
HUB_CTX="${HUB_CTX:-vcluster-hub}"
AGENT_VERSION="${AGENT_VERSION:-v0.9.0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.14.4}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.8.0}"
REDIS_IMAGE="${REDIS_IMAGE:-docker.io/library/redis:8.2-alpine}"
TMP_DIR=""

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<USAGE
Usage:
  ./bootstrap.sh init
  ./bootstrap.sh add-spoke <name>
  ./bootstrap.sh resume-spoke <name>
  ./bootstrap.sh smoke-test <name>
USAGE
  exit 1
}

validate_spoke_name() {
  local name="$1"
  if ! [[ "$name" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
    echo "Invalid spoke name '$name'. It must be RFC-1123 compatible." >&2
    exit 1
  fi
}

wait_for_secret_key() {
  local ctx="$1" ns="$2" secret="$3" key="$4"
  for _ in {1..90}; do
    if kubectl --context="$ctx" -n "$ns" get secret "$secret" -o "jsonpath={.data.${key}}" 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for $ns/$secret key $key" >&2
  return 1
}

principal_external_host() {
  echo "argocd-agent-principal-x-argocd-x-hub.vcluster-hub.svc.cluster.local"
}

host_principal_service_ip() {
  kubectl --context="$HOST_CTX" -n vcluster-hub \
    get svc argocd-agent-principal-x-argocd-x-hub \
    -o jsonpath='{.spec.clusterIP}'
}

host_hub_api_service_ip() {
  kubectl --context="$HOST_CTX" -n vcluster-hub get svc hub -o jsonpath='{.spec.clusterIP}'
}

ensure_redis_ready() {
  local ctx="$1"
  echo "==> Ensuring Redis is pullable and Ready on ${ctx}: ${REDIS_IMAGE}"
  kubectl --context="$ctx" -n argocd set image deployment/argocd-redis \
    redis="$REDIS_IMAGE"
  if ! kubectl --context="$ctx" -n argocd rollout status deployment/argocd-redis --timeout=240s; then
    echo "Redis failed to become Ready on ${ctx}. Recent events:" >&2
    kubectl --context="$ctx" -n argocd get pods -l app.kubernetes.io/name=argocd-redis -o wide >&2 || true
    kubectl --context="$ctx" -n argocd get events --sort-by=.lastTimestamp | tail -30 >&2 || true
    return 1
  fi
}

init_hub() {
  echo "==> Recreating Kind host cluster"
  kind delete cluster --name kubara-poc || true
  kind create cluster --name kubara-poc

  echo "==> Creating Hub vCluster"
  vcluster create hub -n vcluster-hub --context "$HOST_CTX" --connect=false
  vcluster connect hub -n vcluster-hub --context "$HOST_CTX" \
    --kube-config-context-name "$HUB_CTX" --background-proxy
  kubectl --context="$HUB_CTX" wait --for=condition=Ready nodes --all --timeout=120s

  echo "==> Installing cert-manager"
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
  helm --kube-context="$HUB_CTX" upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true --wait --timeout 10m

  kubectl --context="$HUB_CTX" create namespace argocd --dry-run=client -o yaml | \
    kubectl --context="$HUB_CTX" apply -f -

  echo "==> Installing the official Argo CD PRINCIPAL topology (no application-controller on Hub)"
  kubectl --context="$HUB_CTX" apply -n argocd --server-side \
    -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/argo-cd/principal?ref=${AGENT_VERSION}"

  ensure_redis_ready "$HUB_CTX"

  echo "==> Creating CA"
  kubectl --context="$HUB_CTX" apply -f manifests/hub/01-ca-setup.yaml
  kubectl --context="$HUB_CTX" wait --for=condition=Ready certificate/kubara-ca \
    -n cert-manager --timeout=120s
  local ca_b64
  ca_b64="$(kubectl --context="$HUB_CTX" -n cert-manager get secret kubara-ca-secret -o jsonpath='{.data.tls\.crt}')"
  cat <<YAML | kubectl --context="$HUB_CTX" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-agent-ca
  namespace: argocd
type: Opaque
data:
  ca.crt: ${ca_b64}
YAML

  export PRINCIPAL_EXTERNAL_HOST
  PRINCIPAL_EXTERNAL_HOST="$(principal_external_host)"
  envsubst '${PRINCIPAL_EXTERNAL_HOST}' < manifests/hub/02-mtls-certs.yaml | \
    kubectl --context="$HUB_CTX" apply -f -
  kubectl --context="$HUB_CTX" wait --for=condition=Ready certificate/argocd-agent-principal-tls \
    -n argocd --timeout=120s
  kubectl --context="$HUB_CTX" wait --for=condition=Ready certificate/argocd-agent-resource-proxy-tls \
    -n argocd --timeout=120s

  echo "==> Installing the official argocd-agent Principal ${AGENT_VERSION}"
  kubectl --context="$HUB_CTX" apply -n argocd \
    -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/principal?ref=${AGENT_VERSION}"

  kubectl --context="$HUB_CTX" -n argocd patch configmap argocd-agent-params --type merge -p \
    '{"data":{
      "principal.listen.host":"",
      "principal.allowed-namespaces":"*",
      "principal.tls.client-cert.require":"true",
      "principal.tls.client-cert.match-subject":"true",
      "principal.tls.server.root-ca-secret-name":"argocd-agent-ca",
      "principal.resource-proxy.ca.secret-name":"argocd-agent-ca",
      "principal.auth":"mtls:subject:CN=([^,]+)",
      "principal.jwt.allow-generate":"true"
    }}'

  kubectl --context="$HUB_CTX" -n argocd patch configmap argocd-cmd-params-cm --type merge -p \
    '{"data":{
      "application.namespaces":"*",
      "redis.server":"argocd-agent-redis-proxy:6379"
    }}'

  kubectl --context="$HUB_CTX" -n argocd rollout restart deployment/argocd-agent-principal
  kubectl --context="$HUB_CTX" -n argocd rollout status deployment/argocd-agent-principal --timeout=180s
  kubectl --context="$HUB_CTX" -n argocd rollout restart deployment/argocd-server
  kubectl --context="$HUB_CTX" -n argocd rollout status deployment/argocd-server --timeout=180s

  kubectl --context="$HUB_CTX" apply -f manifests/hub/04-managed-app-project.yaml

  echo "Hub initialized."
  echo "NOTE: principal.jwt.allow-generate=true is acceptable only for this local POC."
  echo "For production, create argocd-agent-jwt with 'argocd-agentctl jwt create-key'."
}

add_spoke() {
  local spoke="${1:-}"
  [[ -n "$spoke" ]] || usage
  validate_spoke_name "$spoke"

  export SPOKE_NAME="$spoke"
  local spoke_ctx="vcluster-${spoke}"
  TMP_DIR="$(mktemp -d)"
  umask 077

  echo "==> Creating spoke vCluster: $spoke"
  vcluster create "$spoke" -n "vcluster-${spoke}" --context "$HOST_CTX" --connect=false
  vcluster connect "$spoke" -n "vcluster-${spoke}" --context "$HOST_CTX" \
    --kube-config-context-name "$spoke_ctx" --background-proxy
  kubectl --context="$spoke_ctx" wait --for=condition=Ready nodes --all --timeout=120s

  kubectl --context="$spoke_ctx" create namespace argocd --dry-run=client -o yaml | \
    kubectl --context="$spoke_ctx" apply -f -
  kubectl --context="$HUB_CTX" create namespace "$spoke" --dry-run=client -o yaml | \
    kubectl --context="$HUB_CTX" apply -f -

  echo "==> Issuing two separate client identities"
  envsubst '${SPOKE_NAME}' < manifests/hub/spoke-cert-template.yaml | \
    kubectl --context="$HUB_CTX" apply -f -
  envsubst '${SPOKE_NAME}' < manifests/hub/resource-proxy-client-cert-template.yaml | \
    kubectl --context="$HUB_CTX" apply -f -
  envsubst '${SPOKE_NAME}' < manifests/hub/eso-rbac-template.yaml | \
    kubectl --context="$HUB_CTX" apply -f -

  kubectl --context="$HUB_CTX" wait --for=condition=Ready \
    "certificate/${spoke}-agent-client-cert" -n "$spoke" --timeout=120s
  kubectl --context="$HUB_CTX" wait --for=condition=Ready \
    "certificate/${spoke}-resource-proxy-client-cert" -n argocd --timeout=120s

  echo "==> Registering the spoke as an Argo CD cluster through the resource proxy"
  export RESOURCE_PROXY_CA RESOURCE_PROXY_CLIENT_CERT RESOURCE_PROXY_CLIENT_KEY
  RESOURCE_PROXY_CA="$(kubectl --context="$HUB_CTX" -n argocd get secret "${spoke}-resource-proxy-client-tls" -o jsonpath='{.data.ca\.crt}')"
  RESOURCE_PROXY_CLIENT_CERT="$(kubectl --context="$HUB_CTX" -n argocd get secret "${spoke}-resource-proxy-client-tls" -o jsonpath='{.data.tls\.crt}')"
  RESOURCE_PROXY_CLIENT_KEY="$(kubectl --context="$HUB_CTX" -n argocd get secret "${spoke}-resource-proxy-client-tls" -o jsonpath='{.data.tls\.key}')"
  envsubst '${SPOKE_NAME} ${RESOURCE_PROXY_CA} ${RESOURCE_PROXY_CLIENT_CERT} ${RESOURCE_PROXY_CLIENT_KEY}' \
    < manifests/hub/argo-cluster-template.yaml | kubectl --context="$HUB_CTX" apply -f -

  echo "==> Installing the official managed-agent Argo CD execution plane"
  kubectl --context="$spoke_ctx" apply -n argocd --server-side \
    -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/argo-cd/agent-managed?ref=${AGENT_VERSION}"

  ensure_redis_ready "$spoke_ctx"

  echo "==> Bootstrapping agent TLS once; ESO will own refresh afterward"
  local cert key ca
  cert="$(kubectl --context="$HUB_CTX" -n "$spoke" get secret "${spoke}-agent-client-tls" -o jsonpath='{.data.tls\.crt}')"
  key="$(kubectl --context="$HUB_CTX" -n "$spoke" get secret "${spoke}-agent-client-tls" -o jsonpath='{.data.tls\.key}')"
  ca="$(kubectl --context="$HUB_CTX" -n "$spoke" get secret "${spoke}-agent-client-tls" -o jsonpath='{.data.ca\.crt}')"
  cat <<YAML | kubectl --context="$spoke_ctx" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-agent-client-tls
  namespace: argocd
type: kubernetes.io/tls
data:
  tls.crt: ${cert}
  tls.key: ${key}
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-agent-ca
  namespace: argocd
type: Opaque
data:
  ca.crt: ${ca}
YAML

  echo "==> Installing official argocd-agent Agent ${AGENT_VERSION}"
  kubectl --context="$spoke_ctx" apply -n argocd \
    -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/agent?ref=${AGENT_VERSION}"

  local principal_host principal_ip
  principal_host="$(principal_external_host)"
  principal_ip="$(host_principal_service_ip)"
  [[ -n "$principal_ip" ]] || { echo "Could not discover host-synced Principal Service IP" >&2; exit 1; }

  kubectl --context="$spoke_ctx" -n argocd patch configmap argocd-agent-params --type merge -p \
    "{\"data\":{
      \"agent.mode\":\"managed\",
      \"agent.server.address\":\"${principal_host}\",
      \"agent.server.port\":\"443\",
      \"agent.creds\":\"mtls:\",
      \"agent.tls.secret-name\":\"argocd-agent-client-tls\",
      \"agent.tls.root-ca-secret-name\":\"argocd-agent-ca\"
    }}"

  kubectl --context="$spoke_ctx" -n argocd patch deployment argocd-agent-agent --type merge -p \
    "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"${principal_ip}\",\"hostnames\":[\"${principal_host}\"]}]}}}}"

  kubectl --context="$spoke_ctx" -n argocd rollout status deployment/argocd-agent-agent --timeout=180s

  configure_eso_for_spoke "$spoke" "$spoke_ctx"

  echo "Spoke $spoke onboarded."
  echo "Run: ./bootstrap.sh smoke-test $spoke"
}

configure_eso_for_spoke() {
  local spoke="$1"
  local spoke_ctx="$2"
  export SPOKE_NAME="$spoke"

  echo "==> Installing ESO ${ESO_CHART_VERSION} for certificate rotation"
  helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
  helm repo update >/dev/null
  helm --kube-context="$spoke_ctx" upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version "$ESO_CHART_VERSION" \
    --set installCRDs=true \
    --wait --timeout 10m

  kubectl --context="$spoke_ctx" wait --for=condition=Established \
    crd/secretstores.external-secrets.io --timeout=120s
  kubectl --context="$spoke_ctx" wait --for=condition=Established \
    crd/externalsecrets.external-secrets.io --timeout=120s

  local hub_api_ip
  hub_api_ip="$(host_hub_api_service_ip)"
  if [[ -n "$hub_api_ip" ]]; then
    kubectl --context="$spoke_ctx" -n external-secrets patch deployment external-secrets --type merge -p \
      "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"${hub_api_ip}\",\"hostnames\":[\"hub.vcluster-hub.svc.cluster.local\"]}]}}}}"
    kubectl --context="$spoke_ctx" -n external-secrets rollout status deployment/external-secrets --timeout=180s
  fi

  wait_for_secret_key "$HUB_CTX" "$spoke" "eso-token-${spoke}" token
  local eso_token eso_ca
  eso_token="$(kubectl --context="$HUB_CTX" -n "$spoke" get secret "eso-token-${spoke}" -o jsonpath='{.data.token}')"
  eso_ca="$(kubectl --context="$HUB_CTX" -n "$spoke" get secret "eso-token-${spoke}" -o jsonpath='{.data.ca\.crt}')"
  cat <<YAML | kubectl --context="$spoke_ctx" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hub-api-auth
  namespace: argocd
type: Opaque
data:
  token: ${eso_token}
  ca.crt: ${eso_ca}
YAML

  envsubst '${SPOKE_NAME}' < manifests/spoke/eso-sync-template.yaml | \
    kubectl --context="$spoke_ctx" apply -f -

  echo "==> Waiting for ESO SecretStore"
  for _ in {1..60}; do
    if kubectl --context="$spoke_ctx" -n argocd get secretstore hub-cluster-store \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      break
    fi
    sleep 2
  done
  kubectl --context="$spoke_ctx" -n argocd get secretstore hub-cluster-store || true
  kubectl --context="$spoke_ctx" -n argocd get externalsecret sync-agent-client-tls || true
  kubectl --context="$spoke_ctx" -n argocd get externalsecret sync-agent-root-ca || true

  echo "==> Restarting the agent after final certificate-sync configuration"
  kubectl --context="$spoke_ctx" -n argocd rollout restart deployment/argocd-agent-agent
  kubectl --context="$spoke_ctx" -n argocd rollout status deployment/argocd-agent-agent --timeout=180s
}

resume_spoke() {
  local spoke="${1:-}"
  [[ -n "$spoke" ]] || usage
  validate_spoke_name "$spoke"
  local spoke_ctx="vcluster-${spoke}"

  kubectl config get-contexts "$spoke_ctx" >/dev/null 2>&1 || {
    echo "Missing kubeconfig context $spoke_ctx. Run add-spoke first." >&2
    exit 1
  }
  kubectl --context="$HUB_CTX" get namespace "$spoke" >/dev/null 2>&1 || {
    echo "Missing Hub namespace $spoke. Run add-spoke first." >&2
    exit 1
  }
  kubectl --context="$spoke_ctx" -n argocd get deployment argocd-agent-agent >/dev/null 2>&1 || {
    echo "Missing argocd-agent-agent on $spoke. Run add-spoke first." >&2
    exit 1
  }

  ensure_redis_ready "$HUB_CTX"
  ensure_redis_ready "$spoke_ctx"

  configure_eso_for_spoke "$spoke" "$spoke_ctx"
  echo "Spoke $spoke resume completed."
  echo "Run: ./bootstrap.sh smoke-test $spoke"
}

smoke_test() {
  local spoke="${1:-}"
  [[ -n "$spoke" ]] || usage
  validate_spoke_name "$spoke"
  local spoke_ctx="vcluster-${spoke}"

  echo "==> Principal must be connected"
  kubectl --context="$HUB_CTX" -n argocd logs deployment/argocd-agent-principal --tail=100 | \
    grep -E "$spoke|connected|Authenticated|queue" || true

  echo "==> Project must already be on the spoke before testing an Application"
  for _ in {1..60}; do
    if kubectl --context="$spoke_ctx" -n argocd get appproject managed-agents >/dev/null 2>&1; then
      kubectl --context="$spoke_ctx" -n argocd get appproject managed-agents -o name
      break
    fi
    sleep 2
  done
  kubectl --context="$spoke_ctx" -n argocd get appproject managed-agents >/dev/null 2>&1 || {
    echo "ERROR: managed-agents AppProject was not synchronized to ${spoke}. Run ./diagnose.sh ${spoke}." >&2
    exit 1
  }

  if [[ "$spoke" == "staging-cluster" ]]; then
    kubectl --context="$HUB_CTX" apply -f test-app.yaml
  else
    sed "s/staging-cluster/${spoke}/g; s/staging-guestbook/${spoke}-guestbook/g" test-app.yaml | \
      kubectl --context="$HUB_CTX" apply -f -
  fi

  local app_name
  if [[ "$spoke" == "staging-cluster" ]]; then
    app_name="staging-guestbook"
  else
    app_name="${spoke}-guestbook"
  fi

  echo "==> Waiting for Application to appear on the workload cluster"
  for _ in {1..60}; do
    if kubectl --context="$spoke_ctx" -n argocd get application "$app_name" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl --context="$spoke_ctx" -n argocd get application "$app_name" >/dev/null 2>&1 || {
    echo "ERROR: Application $app_name did not arrive on $spoke. Run ./diagnose.sh $spoke." >&2
    return 1
  }

  echo "==> Waiting for the workload-side Argo CD controller to report Synced/Healthy"
  for _ in {1..90}; do
    local sync health
    sync="$(kubectl --context="$spoke_ctx" -n argocd get application "$app_name" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl --context="$spoke_ctx" -n argocd get application "$app_name" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      kubectl --context="$spoke_ctx" -n argocd get application "$app_name" -o wide
      echo "==> Verifying the Hub receives the status update"
      kubectl --context="$HUB_CTX" -n "$spoke" get application "$app_name" -o wide
      echo "==> Verifying workload resources exist on the spoke"
      kubectl --context="$spoke_ctx" -n guestbook get deployment,pod,svc -o wide

      echo "==> Verifying the Hub does not run the guestbook workload"
      if kubectl --context="$HUB_CTX" get namespace guestbook >/dev/null 2>&1; then
        local hub_workload
        hub_workload="$(kubectl --context="$HUB_CTX" -n guestbook get deployment,pod,svc -o name 2>/dev/null || true)"
        if [[ -n "$hub_workload" ]]; then
          echo "ERROR: guestbook workload unexpectedly exists on the Hub:" >&2
          echo "$hub_workload" >&2
          return 1
        fi
      fi

      echo "Smoke test passed: $spoke / $app_name is Synced and Healthy; workload is on the spoke only."
      return 0
    fi
    sleep 2
  done

  echo "ERROR: $app_name arrived on $spoke but did not become Synced/Healthy in time." >&2
  kubectl --context="$spoke_ctx" -n argocd get application "$app_name" -o yaml >&2 || true
  return 1
}

case "${1:-}" in
  init) init_hub ;;
  add-spoke) add_spoke "${2:-}" ;;
  resume-spoke) resume_spoke "${2:-}" ;;
  smoke-test) smoke_test "${2:-}" ;;
  *) usage ;;
esac
