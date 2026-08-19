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
#
# The compiled output goes by the same principle, and the three binary paths are
# spelled out rather than matched because .gitignore anchors them for a reason it
# states: an unanchored pattern with no slash matches at any depth, and the
# source packages engine/cmd/naylampd and engine/naylamp would be in its way.
# Naming the files exactly cannot reach a directory, and the -type f on the sweep
# below cannot either.
#
# THE SWEEP STARTS AT THE REPOSITORY ROOT rather than at engine/, which is the
# whole of what makes it scale. Rooting it at engine/ made the convention true of
# one directory instead of the repository: an artifact dropped by anything under
# services/, dashboard/, infra/ or gate/ matched the naming rule, was ignored by
# git, and then survived every clean. .gitignore's own patterns moved with it on
# the same day and for the same reason, spelled out there. Adding a package or a
# benchmark now needs no edit here: name the output <something>_result.txt or
# <something>_bench.txt and it is already ignored and already swept.
#
# TWO PRUNES, and the second one was missed on the first attempt. .git is pruned
# rather than trusted to hold no matching name, by name rather than by path so a
# nested one is covered too. gate/out/certs is pruned because the line above it
# goes out of its way to keep that directory, and a root-anchored sweep would
# otherwise walk straight back into it and delete by name whatever the exception
# was protecting by directory. Nothing in there is named that way today, which is
# exactly the kind of luck that stops holding quietly.
#
# The sweep uses -exec rm over -delete on purpose: -delete implies -depth, which
# silently turns -prune into a no-op, so the two do not compose and the
# safe-looking spelling would be the wrong one.
#
# ONE FILE THE TREE DOES NOT GENERATE, and the widening is written down rather
# than slipped in. .DS_Store comes from the Finder, not from a build, so it sits
# outside the sentence this target opens with. It is swept anyway, for the
# reason the sweep exists at all: it is already ignored, so nothing will ever
# ask about it, and one was sitting at the repository root, last written on 12
# August, without anyone choosing to keep it. An mtime says when a file was
# written and not how long it sat there, so the date goes in that shape. What
# deleting one costs is that directory's Finder view state, which nothing in
# this tree sets, so what comes back is the default. It goes through the same
# PRUNE as the two sweeps above, so .git and the gate identities are as safe
# from this line as from those. This is the whole of the widening: a name, not
# a class. An editor or a tool that starts dropping state in the tree gets its
# own line here and its own line in .gitignore, and the argument is made then
# rather than pre-approved now.
PRUNE := -name .git -o -path ./gate/out/certs
clean:
	test ! -d gate/out || find gate/out -mindepth 1 -maxdepth 1 ! -name certs -exec rm -rf -- {} +
	find . \( $(PRUNE) \) -prune -o -type f \( -name '*_result.txt' -o -name '*_bench.txt' \) -exec rm -f -- {} +
	find . \( $(PRUNE) \) -prune -o -type f \( -name '*.test' -o -name '*.out' \) -exec rm -f -- {} +
	find . \( $(PRUNE) \) -prune -o -type f -name '.DS_Store' -exec rm -f -- {} +
	rm -f -- naylampd engine/naylampd naylamp
