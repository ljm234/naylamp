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
#
# gate/out holds two kinds of thing and only one of them is disposable. The
# disposable kind is what a run regenerates: the cross-compiled test binaries,
# the mutant copies, and the directories a run creates and often leaves empty.
# The other kind is evidence that a sealed claim cites, and it is not
# regenerable in any useful sense, because the run that produced it cost VM
# hours that nobody is going to pay twice. Deleting that to save disk is the one
# mistake this target must not make, and until this change it did: the line below
# used to take everything except certs, which included the iron run of Phase 1 and
# the rehearsal whose figures are the denominator of the sizing factor.
#
# The rule is explicit rather than clever, so that it scales without a list
# somebody has to remember to update. A TOP-LEVEL directory under gate/out
# survives clean if it carries a file named SEALED, and that file says who cites
# the directory and why it is kept; the sweep only looks one level down, so a
# marker any deeper saves nothing. Top-level logs survive by extension, because a
# console log is what the register cites by name. Everything else goes. This
# target reads the seal and never writes one: gate/p1.sh writes its own at the
# end of a run, and the two that predate this change were written by hand with
# the reason inside. What survives a clean is the run's own claim, not a guess
# this target gets to make.
PRUNE := -name .git -o -path ./gate/out/certs -o \( -type d -exec test -e {}/SEALED \; \)
#
# AND IT REFUSES BEFORE IT SWEEPS. Keeping what carries a seal is only half the
# defence: the other half was that nothing wrote the seal by itself, so the first
# artifact born without one went silently. The guard below lists the iron
# artifacts (p<n>-<run id>, never a rehearsal's p<n>-local-) that hold something
# and carry no SEALED, and stops with a non-zero status without removing anything,
# which turns a silent loss into a stop. Overriding is explicit and named, never
# the default:
#
#   make clean UNSEALED_OK=1
#
# AND IT NAMES EVERY PHASE, WHICH IT DID NOT UNTIL 2026-09-06. The predicate
# listed p1-* alone, so a gate/out/p2-<run id> written by an iron run of
# gate/p2.sh would have carried no seal past a guard that never looked at it, and
# the sweep below WOULD have taken it: that sweep excludes only certs, *.log and
# whatever carries a SEALED file, so it does not care about the prefix. Guard and
# sweep disagreeing about which names matter is the same defect this block
# already fixed once for the empty ones.
#
# It asks by SHAPE, p[0-9]-, and not by a list of the phases that exist today.
# Naming p1 and p2 by hand would have reopened the same hole in silence the day a
# p3- appeared, which is the failure the PRUNE line above already says it exists
# to avoid: "so that it scales without a list somebody has to remember to
# update". The rehearsal exclusion follows the same shape, p[0-9]-local-.
#
# It was written before the first p2 iron artifact existed rather than after
# losing one, and that sentence used to end "because gate/p2.sh's iron path
# refuses to run". It does not refuse any more: the iron path landed on
# 2026-09-07, and until 2026-09-08 it created gate/out/p2-<run id> and wrote
# SEALED zero times, so every run of it would have arrived at this guard and
# stopped a clean for ever. That is DEFER-098, and it is closed in gate/p2.sh and
# not here: this target reads seals and never writes one. Row 8 of
# gate/clean-guard-test.sh puts the old p1-only predicate back and measures that
# the loss was real.
#
# THE EMPTY ONES ARE NOT CAUGHT, and the first version of this guard did catch
# them and left no way out. A p1-<run id> that a phase created and never wrote to
# has nothing to keep, and gate/p1.sh refuses to seal an empty directory for that
# reason, so catching it here meant a directory that could be neither sealed nor
# cleaned. The sweep below takes it, which is what should happen to it, and on
# emptiness this predicate and gate/p1.sh's ask the same question. The two asking
# different questions was the defect.
#
# ON THE NAME they do NOT match, and saying they did was wrong from 2026-09-06,
# when this one grew to cover p2: gate/p1.sh's is_iron_artifact knows only p1 and
# demands the full shape p1-<stamp>Z-<pid>, while this one accepts any p<n>- that
# is not a rehearsal. That is deliberate and it is the safer direction here. That
# function decides whether to WRITE a seal, so it is strict on purpose; this guard
# decides whether to DELETE, so a name it does not recognise must stop it rather
# than be swept. A predicate that refuses too much costs a run of make clean
# UNSEALED_OK=1; one that refuses too little costs the artifact.
#
# gate/p1.sh seals asks the same question without needing this target, so
# reaching this guard means something went wrong rather than that somebody
# forgot.
#
# AND THE EMPTINESS TEST DISCOUNTS THE RUNNING MARKER, for the same reason
# gate/p1.sh's does. Several places in this tree ask whether an artifact is empty,
# and on 2026-09-07 they learned about the marker one at a time: one at first, then
# three after a reader counted, then the rest after a second reader found a fourth
# inside phase_hygiene. No count is written here, for the reason two blocks down:
# the way to keep them in step is to grep for `ls -A` before adding another.
# A reader measured the state that left reachable: a directory whose sole file is
# RUNNING is empty to seal_artifact, which will not seal it, and full to this
# guard and to unsealed_iron_artifacts, which refuse to clean it and report it as
# unsealed. Neither sealable nor cleanable, which is exactly what the empty
# exception above exists to prevent. The three ask the same question again.
# AND IT REFUSES WHILE A RUN IS STILL WRITING, which is piece five of DEFER-074 and
# was a hole with two incidents before it was a line of code. On 2026-08-28 this
# sweep took a live rehearsal's directory out from under a running gate, halfway
# through a 50k recall; on 2026-09-07 it did it again, and the preflight caught the
# aftermath with four replicas still alive. The seal guard below cannot help: it
# protects FINISHED artifacts, and it excludes the rehearsal prefix on purpose.
#
# THE PREDICATE IS THE PROCESS AND NOT THE FILE. A directory is protected while it
# carries a RUNNING file whose pid is alive. A marker whose process is gone does NOT
# protect anything: that is deliberate, because a run killed with -9 would otherwise
# block every future clean, which is how a defence gets removed for being in the way.
# It is named on its way out rather than swept in silence.
#
# WHAT IT DOES NOT COVER, with no cardinal in front because the list is right
# below and counts itself. Clause 11:
#
#   pid REUSE. A stale marker whose number now belongs to some unrelated process
#   reads as alive and blocks a clean until somebody removes it by hand. That is the
#   cheap side of the trade.
#
#   THE 2026-08-28 INCIDENT WAS OPEN FOR ONE DAY AND IS NOT ANY MORE. That one was a
#   gate/p1.sh rehearsal, and when this block was first written gate/p1.sh wrote no
#   marker: grep -c RUNNING gate/p1.sh gave 0, so a live NAYLAMP_P1_LOCAL=1 run was
#   swept exactly as it had been then, and row 5 of gate/clean-guard-test.sh
#   certified that in green. That was written here on purpose, because this block
#   narrates two incidents as its reason and it would have been dishonest to let it
#   imply both were covered. On 2026-09-07 the marker landed in gate/p1.sh too and
#   that count stopped being zero; row 9b of the bench now covers that family, and
#   row 9c fails if either call is taken out of that file. No figure is written
#   here on purpose: a count of a file, kept outside the file, moves every time the
#   file is edited, and this one went from 13 to 18 inside a single day. These
#   lines are kept
#   rather than deleted because the gap was real for a day and the reason it closed
#   is the same reason it should never have been left open: p1.sh is the script that
#   runs the Phase 1 iron session, which is where a sweep in flight costs most.
#
#   A PID THIS USER CANNOT SIGNAL. kill -0 returns non-zero for EPERM just as it
#   does for ESRCH, so a live process owned by somebody else used to read as gone
#   and get swept with a reassuring message. That is the expensive direction, so the
#   check below asks ps as well, and only calls a marker stale when NEITHER sees the
#   process.
#
# The loop below splits on whitespace, which is safe here and not in general: every
# path it walks is gate/out/<artifact>/RUNNING, and the artifact name comes from a
# run id this tree validates for shape before it creates anything. A directory put
# there by hand with a space in its name would break it, and that is the assumption
# rather than a guarantee.
#
# THE OVERRIDE IS ITS OWN, AND THAT IS THE POINT. UNSEALED_OK=1 means "yes, delete
# this FINISHED artifact that carries no seal"; it must not also mean "yes, kill the
# run that is being paid for right now". Measured on 2026-09-07: with the two sharing
# a valve, make clean UNSEALED_OK=1 took a live rehearsal's directory without
# printing a single line about it, which is the 2026-08-28 scene word for word. The
# refusal below has its own switch and its own name:
#
#   make clean KILL_RUNNING_OK=1
#
UNSEALED_OK ?=
KILL_RUNNING_OK ?=
clean:
	@test ! -d gate/out || { \
		alive=; stale=; \
		for m in $$(find gate/out -mindepth 2 -maxdepth 2 -name RUNNING -print 2>/dev/null); do \
			d=$$(basename "$$(dirname "$$m")"); \
			p=$$(sed -n 's/^pid: //p' "$$m" | head -n1); \
			case "$$p" in ''|0|*[!0-9]*) stale="$$stale $$d(no usable pid)"; continue ;; esac; \
			if kill -0 "$$p" 2>/dev/null || ps -p "$$p" >/dev/null 2>&1; then alive="$$alive $$d(pid $$p)"; \
			else stale="$$stale $$d(pid $$p, gone)"; fi; \
		done; \
		if [ -n "$$alive" ] && [ -z "$(KILL_RUNNING_OK)" ]; then \
			echo "make: refusing to clean: a gate run is still writing:$$alive" >&2; \
			echo "make: its RUNNING marker carries a pid that is alive. Wait for it, or stop it." >&2; \
			echo "make: UNSEALED_OK=1 does NOT override this one, on purpose. The switch that" >&2; \
			echo "make: kills a paid run has to be typed on purpose: make clean KILL_RUNNING_OK=1" >&2; \
			exit 1; \
		fi; \
		if [ -n "$$stale" ]; then \
			echo "make: sweeping the remains of runs that did not finish:$$stale" >&2; \
		fi; \
	}
	@test ! -d gate/out || { \
		u=$$(find gate/out -mindepth 1 -maxdepth 1 -type d \
			-name 'p[0-9]-*' ! -name 'p[0-9]-local-*' \
			! -exec test -e {}/SEALED \; \
			-exec sh -c 'test -n "$$(ls -A "$$1" | grep -vx RUNNING)"' _ {} \; -print | sed 's#.*/##' | tr '\n' ' '); \
		if [ -n "$$u" ] && [ -z "$(UNSEALED_OK)" ]; then \
			echo "make: refusing to clean: iron artifacts with no SEALED file: $$u" >&2; \
			echo "make: seal one by writing gate/out/<name>/SEALED with who cites it and why it is kept," >&2; \
			echo "make: or run: make clean UNSEALED_OK=1" >&2; \
			exit 1; \
		fi; \
	}
	test ! -d gate/out || find gate/out -mindepth 1 -maxdepth 1 \
		! -name certs ! -name '*.log' \
		! -exec test -e {}/SEALED \; \
		-exec rm -rf -- {} +
	find . \( $(PRUNE) \) -prune -o -type f \( -name '*_result.txt' -o -name '*_bench.txt' \) -exec rm -f -- {} +
	find . \( $(PRUNE) \) -prune -o -type f \( -name '*.test' -o -name '*.out' \) -exec rm -f -- {} +
	find . \( $(PRUNE) \) -prune -o -type f -name '.DS_Store' -exec rm -f -- {} +
	rm -f -- naylampd engine/naylampd naylamp
