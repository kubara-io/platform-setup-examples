package e2e

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

// TestManagedSpokeSmoke wraps the existing cluster-aware smoke test in Go.
// It is intentionally opt-in because it requires a running Kind/vCluster POC.
func TestManagedSpokeSmoke(t *testing.T) {
	if os.Getenv("RUN_E2E") != "1" {
		t.Skip("set RUN_E2E=1 to run against an existing POC environment")
	}

	spoke := os.Getenv("E2E_SPOKE")
	if spoke == "" {
		spoke = "staging-cluster"
	}

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("unable to resolve repository path")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))

	cmd := exec.Command(filepath.Join(root, "bootstrap.sh"), "smoke-test", spoke)
	cmd.Dir = root
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("managed-spoke smoke test failed: %v", err)
	}
}
