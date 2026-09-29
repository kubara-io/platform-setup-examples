.PHONY: test vet lint fmt fmt-check check e2e smoke-staging

GO ?= go
E2E_SPOKE ?= staging-cluster

# Fast repository contract tests. No Kubernetes cluster is required.
test: lint fmt-check
	$(GO) test ./... -count=1

# Standard Go static analysis.
vet:
	$(GO) vet ./...

# Shell syntax validation for the orchestration scripts.
lint:
	bash -n bootstrap.sh
	bash -n diagnose.sh

# Format Go test tooling.
fmt:
	gofmt -w tests

# CI-safe formatting check.
fmt-check:
	@files="$$(find tests -type f -name '*.go' -print)"; \
	if [ -n "$$files" ]; then \
		unformatted="$$(gofmt -l $$files)"; \
		if [ -n "$$unformatted" ]; then \
			echo "Go files need gofmt:"; \
			echo "$$unformatted"; \
			exit 1; \
		fi; \
	fi

# Run the complete fast validation suite used by CI.
check: test vet

# Opt-in Go e2e wrapper against an already-running local POC.
e2e:
	RUN_E2E=1 E2E_SPOKE=$(E2E_SPOKE) $(GO) test ./tests/e2e -count=1 -v

# Direct shell equivalent for an existing staging POC.
smoke-staging:
	./bootstrap.sh smoke-test staging-cluster
