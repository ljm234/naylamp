GO := go
GOLANGCI := golangci-lint
MODULES := ./engine/...

# SCALE_TIMEOUT bounds the heavy scale/benchmark tests, which build large
# indexes and can run for many minutes.
SCALE_TIMEOUT := 60m

.PHONY: build test test-scale test-race lint vet fmt bench tidy ci

build:
	$(GO) build $(MODULES)

# test runs the fast suite used in everyday development and CI. The -short flag
# skips the heavy scale tests (tens of thousands of vectors and up), keeping
# this quick. Run make test-scale to exercise those explicitly.
test:
	$(GO) test -short $(MODULES)

# test-scale runs the heavy scale tests that are skipped by make test. They
# build large indexes to observe recall and build behavior at size, so they get
# a long timeout.
test-scale:
	$(GO) test -run 'Scale' -timeout $(SCALE_TIMEOUT) -v $(MODULES)

test-race:
	$(GO) test -short -race $(MODULES)

vet:
	$(GO) vet $(MODULES)

lint:
	cd engine && $(GOLANGCI) run ./...

fmt:
	$(GO) fmt $(MODULES)

bench:
	$(GO) test -bench=. -benchmem -timeout $(SCALE_TIMEOUT) -run '^$$' $(MODULES)

tidy:
	cd engine && $(GO) mod tidy

ci: build vet lint test