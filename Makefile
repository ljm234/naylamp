GO := go
GOLANGCI := golangci-lint
MODULES := ./engine/...

.PHONY: build test test-race lint vet fmt bench tidy ci

build:
	$(GO) build $(MODULES)

test:
	$(GO) test $(MODULES)

test-race:
	$(GO) test -race $(MODULES)

vet:
	$(GO) vet $(MODULES)

lint:
	cd engine && $(GOLANGCI) run ./...

fmt:
	$(GO) fmt $(MODULES)

bench:
	$(GO) test -bench=. -benchmem $(MODULES)

tidy:
	cd engine && $(GO) mod tidy

ci: build vet lint test
