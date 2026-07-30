GO := go
GOLANGCI := golangci-lint
MODULES := ./engine/...

# SCALE_TIMEOUT bounds the heavy scale/benchmark tests, which build large
# indexes and can run for many minutes.
SCALE_TIMEOUT := 60m

.PHONY: build test test-scale test-race lint vet fmt bench tidy vuln ci clean

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

# vuln scans the module for known vulnerabilities. The scanner is pinned to
# @latest on purpose: the vulnerability database is a moving target, so the newest
# scanner is wanted. It analyzes the code as compiled by the active toolchain, so
# it needs Go 1.26.5 or later, the minimum go.mod declares; an older local Go
# would report the toolchain's own vulnerabilities, which is correct. The module
# has no external dependencies, so the standard library and toolchain are the
# whole surface, and the scanner runs as a tool without joining them.
vuln:
	cd engine && $(GO) run golang.org/x/vuln/cmd/govulncheck@latest ./...

fmt:
	$(GO) fmt $(MODULES)

bench:
	$(GO) test -bench=. -benchmem -timeout $(SCALE_TIMEOUT) -run '^$$' $(MODULES)

tidy:
	cd engine && $(GO) mod tidy

# ci mirrors the pipeline. vuln comes last because, unlike the hermetic targets
# before it, it reaches the network to fetch the scanner and the vulnerability
# database.
ci: build vet lint test vuln

# clean removes what the tree generates. It is written against the conventions
# .gitignore already declares rather than against a list of files: gate/out is the
# whole of the gate's local build and run output, and the heavy tests leave
# <name>_result.txt and <name>_bench.txt beside the package that produced them.
#
# TWO EXCEPTIONS, both because removing them costs more than keeping them. The
# NAYLAMP_*GATE*.txt run artifacts stay: deleting one throws away a run on three
# cloud hosts that no local rebuild can recreate. gate/out/certs stays because
# gate/build.sh mints the identities once and reuses them, and a clean that
# rotated them would leave the hosts on the old CA until the next deploy, which
# shows up as a cluster that never elects a leader. Rotate by hand when rotating
# is what you meant.
#
# `git clean -X` would look like the obvious implementation and is not used: it
# takes every ignored path, and some of those are local tool and environment
# configuration that happens to be untracked rather than output.
clean:
	test ! -d gate/out || find gate/out -mindepth 1 -maxdepth 1 ! -name certs -exec rm -rf -- {} +
	find engine -type f \( -name '*_result.txt' -o -name '*_bench.txt' \) -delete
