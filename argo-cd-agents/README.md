# Argo CD Agent managed-mode Hub/Spoke POC

A local Kind and vCluster proof of concept for Argo CD Agent managed mode.

The Hub owns `Application` and `AppProject` resources. Each spoke runs its own Agent and application controller, reconciles workloads locally, and sends status back to the Hub. The Hub never connects directly to a spoke Kubernetes API.

> [!IMPORTANT]
> This is a local POC, not a production architecture. It uses broad permissions, self-signed TLS, and `hostAliases` to make nested vClusters work.

## What it proves

- An Agent authenticates to the Principal with mTLS.
- The Hub distributes `AppProject` and `Application` resources to a spoke.
- The spoke reconciles a guestbook workload and returns `Synced` and `Healthy` status.
- Hub Argo CD reads live resources through the Principal resource proxy.

The baseline uses `argocd-agent v0.9.0` and namespace-based agent mapping. A Hub `Application` in the `staging-cluster` namespace routes to the Agent named `staging-cluster`.

## Topology

```text
Hub vCluster
  argocd-server, repo-server, Redis
  Principal, Redis proxy, resource proxy
  cert-manager
          |
          | outbound gRPC + mTLS
          v
Spoke vCluster
  Agent, application-controller, repo-server, Redis
  External Secrets Operator
  workload Kubernetes API
```

The Hub has no application controller. The spoke does. That detail matters, it is where reconciliation happens.

## Requirements

- Docker-compatible container runtime
- `kind`, `kubectl`, `helm`, `vcluster`, and `envsubst` from GNU `gettext`
- Go 1.23 or later for tests
- Internet access to pull images and fetch GitHub-hosted Kustomize manifests

`bootstrap.sh` defaults to:

| Dependency | Version or image |
|---|---|
| Argo CD Agent | `v0.9.0` |
| cert-manager | `v1.14.4` |
| External Secrets Operator | `2.8.0` |
| Redis | `docker.io/library/redis:8.2-alpine` |

The Agent overlays still consume Argo CD's `stable` manifest. `AGENT_VERSION` alone does not pin every dependency. Vendor or pin that manifest before production use.

## Quick start

```bash
chmod +x bootstrap.sh diagnose.sh
./bootstrap.sh init
./bootstrap.sh add-spoke staging-cluster
./bootstrap.sh smoke-test staging-cluster
```

Add another spoke with:

```bash
./bootstrap.sh add-spoke production-cluster
./bootstrap.sh smoke-test production-cluster
```

Spoke names must follow RFC 1123. The scripts use the name for both the Agent identity and Hub routing namespace.

## Test the repository

Run the checks used in CI:

```bash
make check
```

They run `bash -n`, render the YAML templates, and check the topology contracts. In particular, they catch the easy-to-miss rule that Agents connect to Principal Service port `443`, not container port `8443`.

The end-to-end test needs a running POC and changes cluster resources:

```bash
RUN_E2E=1 E2E_SPOKE=staging-cluster go test ./tests/e2e -count=1 -v
```

Or:

```bash
make e2e E2E_SPOKE=staging-cluster
```

## Configuration

```bash
HOST_CTX=kind-kubara-poc
HUB_CTX=vcluster-hub
AGENT_VERSION=v0.9.0
CERT_MANAGER_VERSION=v1.14.4
ESO_CHART_VERSION=2.8.0
REDIS_IMAGE=docker.io/library/redis:8.2-alpine
```

For example:

```bash
REDIS_IMAGE=registry.example.com/mirror/redis:8.2-alpine ./bootstrap.sh init
```

## TLS, Redis, and networking

Each spoke uses two client certificates signed by the same CA. The Agent certificate identifies the Agent to Principal gRPC. The resource-proxy certificate lets Hub Argo CD request live resources for that Agent. They must have different private keys. Do not use the Principal server certificate as a client certificate.

Hub `argocd-server` must use the Principal Redis proxy:

```yaml
data:
  redis.server: argocd-agent-redis-proxy:6379
```

The nested-vCluster setup adds `hostAliases` for the Principal DNS name in the Agent Pod and the Hub API DNS name in the ESO Pod. Those aliases use host-synchronized Service IPs, which survive Pod restarts. Do not copy this arrangement into production. Use routable DNS and normal cross-cluster networking.

## Diagnostics

```bash
./diagnose.sh staging-cluster

# Agent connection
kubectl --context=vcluster-staging-cluster -n argocd \
  logs deployment/argocd-agent-agent --tail=100

# Principal authentication and events
kubectl --context=vcluster-hub -n argocd \
  logs deployment/argocd-agent-principal --tail=100

# Spoke workload
kubectl --context=vcluster-staging-cluster -n guestbook \
  get deployment,pod,svc -o wide
```

## Before production

- Replace the self-signed CA, generated JWT key, long-lived ESO token, broad RBAC, and wildcard AppProject policy.
- Remove `hostAliases`, pin or vendor Argo CD, use approved image registries and digests, and enforce NetworkPolicies.
- Test Principal and Redis failure behavior. Add metrics, centralized logs, alerts, and a certificate-expiry process.
- Never commit private keys, service-account tokens, kubeconfigs, or generated TLS material.

## References

- [Argo CD Agent: getting started](https://argocd-agent.readthedocs.io/latest/getting-started/)
- [Argo CD Agent: managed sync protocol](https://argocd-agent.readthedocs.io/latest/concepts/sync-protocol/)
- [Argo CD Agent: mapping modes](https://argocd-agent.readthedocs.io/latest/concepts/agent-mapping/)
- [Argo CD Agent: authentication](https://argocd-agent.readthedocs.io/latest/configuration/authentication/)
- [Argo CD Agent: live resources](https://argocd-agent.readthedocs.io/latest/user-guide/live-resources/)
