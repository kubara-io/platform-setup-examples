#!/usr/bin/env bash
set -euo pipefail

HUB_CTX="${HUB_CTX:-vcluster-hub}"
HOST_CTX="${HOST_CTX:-kind-kubara-poc}"
SPOKE_NAME="${1:-staging-cluster}"
SPOKE_CTX="${SPOKE_CTX:-vcluster-${SPOKE_NAME}}"

section() {
  printf '\n=== %s ===\n' "$1"
}

section "versions / images"
kubectl --context="$HUB_CTX" -n argocd get deploy argocd-agent-principal \
  -o jsonpath='principal={.spec.template.spec.containers[0].image}{"\n"}' || true
kubectl --context="$SPOKE_CTX" -n argocd get deploy argocd-agent-agent \
  -o jsonpath='agent={.spec.template.spec.containers[0].image}{"\n"}' || true
kubectl --context="$HUB_CTX" -n argocd get deploy argocd-redis \
  -o jsonpath='hub-redis={.spec.template.spec.containers[0].image}{"\n"}' || true
kubectl --context="$SPOKE_CTX" -n argocd get deploy argocd-redis \
  -o jsonpath='spoke-redis={.spec.template.spec.containers[0].image}{"\n"}' || true

section "Hub component placement — application-controller must be absent"
kubectl --context="$HUB_CTX" -n argocd get deploy,statefulset,pod -o wide || true

section "Spoke execution plane"
kubectl --context="$SPOKE_CTX" -n argocd get deploy,statefulset,pod,svc -o wide || true

section "Redis health"
kubectl --context="$HUB_CTX" -n argocd get pod,svc,endpoints \
  -l app.kubernetes.io/name=argocd-redis -o wide || true
kubectl --context="$SPOKE_CTX" -n argocd get pod,svc,endpoints \
  -l app.kubernetes.io/name=argocd-redis -o wide || true

section "Principal service ports"
kubectl --context="$HUB_CTX" -n argocd get svc argocd-agent-principal \
  -o jsonpath='{range .spec.ports[*]}name={.name} port={.port} targetPort={.targetPort}{"\n"}{end}' || true

section "Principal config"
kubectl --context="$HUB_CTX" -n argocd get cm argocd-agent-params -o jsonpath='allowed-namespaces={.data.principal\.allowed-namespaces}{"\n"}auth={.data.principal\.auth}{"\n"}require-client-cert={.data.principal\.tls\.client-cert\.require}{"\n"}match-subject={.data.principal\.tls\.client-cert\.match-subject}{"\n"}' || true

section "Hub Argo CD server config"
kubectl --context="$HUB_CTX" -n argocd get cm argocd-cmd-params-cm \
  -o jsonpath='application.namespaces={.data.application\.namespaces}{"\n"}redis.server={.data.redis\.server}{"\n"}' || true

section "Agent config"
kubectl --context="$SPOKE_CTX" -n argocd get cm argocd-agent-params -o jsonpath='mode={.data.agent\.mode}{"\n"}server={.data.agent\.server\.address}:{.data.agent\.server\.port}{"\n"}creds={.data.agent\.creds}{"\n"}tls-secret={.data.agent\.tls\.secret-name}{"\n"}ca-secret={.data.agent\.tls\.root-ca-secret-name}{"\n"}redis={.data.agent\.redis\.address}{"\n"}' || true

section "Agent local vCluster hostAliases"
kubectl --context="$SPOKE_CTX" -n argocd get deploy argocd-agent-agent \
  -o jsonpath='{.spec.template.spec.hostAliases}{"\n"}' || true

section "Host-synchronized Principal service"
kubectl --context="$HOST_CTX" -n vcluster-hub get svc \
  argocd-agent-principal-x-argocd-x-hub -o wide || true

section "ESO certificate synchronization"
kubectl --context="$SPOKE_CTX" -n external-secrets get pods -o wide || true
kubectl --context="$SPOKE_CTX" -n argocd get secretstore hub-cluster-store || true
kubectl --context="$SPOKE_CTX" -n argocd get externalsecret \
  sync-agent-client-tls sync-agent-root-ca || true

section "Certificate metadata — no private keys are printed"
kubectl --context="$SPOKE_CTX" -n argocd get secret argocd-agent-client-tls \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | \
  openssl x509 -noout -subject -issuer -dates -ext extendedKeyUsage 2>/dev/null || true
kubectl --context="$HUB_CTX" -n argocd get secret argocd-agent-principal-tls \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d | \
  openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || true

section "Project distribution"
kubectl --context="$HUB_CTX" -n argocd get appproject managed-agents -o wide || true
kubectl --context="$SPOKE_CTX" -n argocd get appproject managed-agents -o wide || true

section "Application distribution"
kubectl --context="$HUB_CTX" -n "$SPOKE_NAME" get application -o wide || true
kubectl --context="$SPOKE_CTX" -n argocd get application -o wide || true

section "Resource-proxy cluster registration — secret values remain redacted"
printf 'name=cluster-%s\nserver=' "$SPOKE_NAME"
kubectl --context="$HUB_CTX" -n argocd get secret "cluster-${SPOKE_NAME}" \
  -o jsonpath='{.data.server}' 2>/dev/null | base64 -d || true
echo

section "Workload namespace"
kubectl --context="$SPOKE_CTX" -n guestbook get deployment,pod,svc -o wide || true

section "Recent Principal logs"
kubectl --context="$HUB_CTX" -n argocd logs deploy/argocd-agent-principal --tail=120 || true

section "Recent Agent logs"
kubectl --context="$SPOKE_CTX" -n argocd logs deploy/argocd-agent-agent --tail=120 || true
