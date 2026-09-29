package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"
)

var replacements = map[string]string{
	"${SPOKE_NAME}":                 "staging-cluster",
	"${PRINCIPAL_EXTERNAL_HOST}":    "argocd-agent-principal-x-argocd-x-hub.vcluster-hub.svc.cluster.local",
	"${RESOURCE_PROXY_CA}":          "BASE64_CA",
	"${RESOURCE_PROXY_CLIENT_CERT}": "BASE64_CERT",
	"${RESOURCE_PROXY_CLIENT_KEY}":  "BASE64_KEY",
}

var unresolvedVariable = regexp.MustCompile(`\$\{[A-Z0-9_]+\}`)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("unable to determine repository test path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), ".."))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

func renderTemplate(t *testing.T, path string) string {
	t.Helper()
	text := readFile(t, path)
	for old, newValue := range replacements {
		text = strings.ReplaceAll(text, old, newValue)
	}
	if unresolved := unresolvedVariable.FindAllString(text, -1); len(unresolved) > 0 {
		t.Fatalf("unresolved variables in %s: %v", path, unresolved)
	}
	return text
}

func yamlDocuments(text string) []string {
	parts := regexp.MustCompile(`(?m)^---\s*$`).Split(text, -1)
	docs := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			docs = append(docs, part)
		}
	}
	return docs
}

func mustContain(t *testing.T, text, want string) {
	t.Helper()
	if !strings.Contains(text, want) {
		t.Fatalf("expected content to contain %q", want)
	}
}

func mustNotContain(t *testing.T, text, unwanted string) {
	t.Helper()
	if strings.Contains(text, unwanted) {
		t.Fatalf("expected content not to contain %q", unwanted)
	}
}

func TestShellScriptsParse(t *testing.T) {
	root := repoRoot(t)
	for _, name := range []string{"bootstrap.sh", "diagnose.sh"} {
		name := name
		t.Run(name, func(t *testing.T) {
			cmd := exec.Command("bash", "-n", filepath.Join(root, name))
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("bash -n failed: %v\n%s", err, out)
			}
		})
	}
}

func TestRepositoryYAMLTemplatesRenderWithBasicDocumentShape(t *testing.T) {
	root := repoRoot(t)
	paths, err := filepath.Glob(filepath.Join(root, "manifests", "hub", "*.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	spokePaths, err := filepath.Glob(filepath.Join(root, "manifests", "spoke", "*.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	paths = append(paths, spokePaths...)
	paths = append(paths, filepath.Join(root, "test-app.yaml"))
	sort.Strings(paths)
	if len(paths) == 0 {
		t.Fatal("no YAML templates found")
	}

	for _, path := range paths {
		path := path
		t.Run(strings.TrimPrefix(path, root+string(filepath.Separator)), func(t *testing.T) {
			docs := yamlDocuments(renderTemplate(t, path))
			if len(docs) == 0 {
				t.Fatal("no YAML documents found after rendering")
			}
			for i, doc := range docs {
				if !regexp.MustCompile(`(?m)^apiVersion:\s*\S+`).MatchString(doc) {
					t.Errorf("document %d has no apiVersion", i+1)
				}
				if !regexp.MustCompile(`(?m)^kind:\s*\S+`).MatchString(doc) {
					t.Errorf("document %d has no kind", i+1)
				}
			}
		})
	}
}

func TestCertificateRolesAreSeparated(t *testing.T) {
	root := repoRoot(t)
	serverCerts := renderTemplate(t, filepath.Join(root, "manifests/hub/02-mtls-certs.yaml"))
	agentCert := renderTemplate(t, filepath.Join(root, "manifests/hub/spoke-cert-template.yaml"))
	proxyCert := renderTemplate(t, filepath.Join(root, "manifests/hub/resource-proxy-client-cert-template.yaml"))

	if got := strings.Count(serverCerts, "- server auth"); got != 2 {
		t.Fatalf("expected two server-auth certificates, got %d", got)
	}
	mustContain(t, agentCert, "- client auth")
	mustContain(t, proxyCert, "- client auth")
	mustContain(t, agentCert, "commonName: staging-cluster")
	mustContain(t, proxyCert, "commonName: staging-cluster")
	mustContain(t, agentCert, "secretName: staging-cluster-agent-client-tls")
	mustContain(t, proxyCert, "secretName: staging-cluster-resource-proxy-client-tls")
	mustNotContain(t, agentCert, "staging-cluster-resource-proxy-client-tls")
}

func TestPrincipalCertificateContainsCrossVClusterDNSName(t *testing.T) {
	root := repoRoot(t)
	certs := renderTemplate(t, filepath.Join(root, "manifests/hub/02-mtls-certs.yaml"))
	mustContain(t, certs, "argocd-agent-principal-x-argocd-x-hub.vcluster-hub.svc.cluster.local")
}

func TestManagedAppProjectSupportsNamespaceMapping(t *testing.T) {
	root := repoRoot(t)
	project := renderTemplate(t, filepath.Join(root, "manifests/hub/04-managed-app-project.yaml"))
	mustContain(t, project, "sourceNamespaces:")
	mustContain(t, project, `- "*"`)
	mustContain(t, project, "destinations:")
	mustContain(t, project, `name: "*"`)
}

func TestClusterSecretUsesResourceProxyAndMutualTLS(t *testing.T) {
	root := repoRoot(t)
	secret := renderTemplate(t, filepath.Join(root, "manifests/hub/argo-cluster-template.yaml"))
	mustContain(t, secret, `name: "staging-cluster"`)
	mustContain(t, secret, "argocd-agent-resource-proxy")
	mustContain(t, secret, ":9090?agentName=staging-cluster")
	mustContain(t, secret, `"insecure": false`)
	mustContain(t, secret, `"caData": "BASE64_CA"`)
	mustContain(t, secret, `"certData": "BASE64_CERT"`)
	mustContain(t, secret, `"keyData": "BASE64_KEY"`)
}

func TestApplicationUsesManagedNamespaceRouting(t *testing.T) {
	root := repoRoot(t)
	app := renderTemplate(t, filepath.Join(root, "test-app.yaml"))
	mustContain(t, app, "namespace: staging-cluster")
	mustContain(t, app, "project: managed-agents")
	mustContain(t, app, "agentName=staging-cluster")
	mustContain(t, app, "namespace: guestbook")
}

func TestExternalSecretsSyncExpectedAgentTLSMaterial(t *testing.T) {
	root := repoRoot(t)
	eso := renderTemplate(t, filepath.Join(root, "manifests/spoke/eso-sync-template.yaml"))
	for _, want := range []string{
		"name: hub-cluster-store",
		"name: sync-agent-client-tls",
		"name: sync-agent-root-ca",
		"name: argocd-agent-client-tls",
		"name: argocd-agent-ca",
		"key: staging-cluster-agent-client-tls",
	} {
		mustContain(t, eso, want)
	}
}

func TestBootstrapArchitectureContracts(t *testing.T) {
	root := repoRoot(t)
	text := readFile(t, filepath.Join(root, "bootstrap.sh"))
	normalized := strings.ReplaceAll(text, `\"`, `"`)

	tests := []struct {
		name string
		fn   func(*testing.T)
	}{
		{"agent version pinned", func(t *testing.T) { mustContain(t, text, `AGENT_VERSION="${AGENT_VERSION:-v0.9.0}"`) }},
		{"official principal topology", func(t *testing.T) {
			mustContain(t, text, "install/kubernetes/argo-cd/principal?ref=${AGENT_VERSION}")
			mustNotContain(t, text, `helm --kube-context="$HUB_CTX" upgrade --install argocd`)
		}},
		{"managed spoke execution plane", func(t *testing.T) {
			mustContain(t, text, "install/kubernetes/argo-cd/agent-managed?ref=${AGENT_VERSION}")
			mustContain(t, normalized, `"agent.mode":"managed"`)
		}},
		{"principal service port is 443", func(t *testing.T) {
			mustContain(t, normalized, `"agent.server.port":"443"`)
			mustNotContain(t, normalized, `"agent.server.port":"8443"`)
		}},
		{"hub uses Redis proxy", func(t *testing.T) {
			mustContain(t, text, `"redis.server":"argocd-agent-redis-proxy:6379"`)
			mustContain(t, text, `"application.namespaces":"*"`)
		}},
		{"explicit mutual TLS", func(t *testing.T) {
			mustContain(t, text, `"principal.auth":"mtls:subject:CN=([^,]+)"`)
			mustContain(t, text, `"principal.tls.client-cert.require":"true"`)
			mustContain(t, text, `"principal.tls.client-cert.match-subject":"true"`)
			mustContain(t, normalized, `"agent.creds":"mtls:"`)
		}},
		{"Redis readiness checked", func(t *testing.T) {
			mustContain(t, text, `ensure_redis_ready "$HUB_CTX"`)
			mustContain(t, text, `ensure_redis_ready "$spoke_ctx"`)
		}},
		{"official ESO chart", func(t *testing.T) {
			mustContain(t, text, "external-secrets/external-secrets")
			mustNotContain(t, text, "./external-secrets")
		}},
		{"ESO diagnostics names", func(t *testing.T) {
			mustContain(t, text, "externalsecret sync-agent-client-tls")
			mustContain(t, text, "externalsecret sync-agent-root-ca")
			mustNotContain(t, text, `externalsecret "sync-${spoke}-mtls-cert"`)
		}},
		{"smoke test waits for healthy sync", func(t *testing.T) {
			mustContain(t, text, `[[ "$sync" == "Synced" && "$health" == "Healthy" ]]`)
			mustContain(t, text, "Smoke test passed:")
			mustContain(t, text, "Verifying the Hub does not run the guestbook workload")
		}},
	}

	for _, tc := range tests {
		t.Run(tc.name, tc.fn)
	}
}

func TestDocumentationContracts(t *testing.T) {
	root := repoRoot(t)
	readme := readFile(t, filepath.Join(root, "README.md"))
	for _, heading := range []string{
		"## Status",
		"## Architecture",
		"## Quick start",
		"## Testing",
		"## TLS and certificate model",
		"## Redis model",
		"## Production hardening",
		"## Open-source repository readiness",
	} {
		mustContain(t, readme, heading)
	}
}
