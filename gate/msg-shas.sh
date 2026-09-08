#!/bin/sh
# msg-shas.sh: every commit sha a message CITES has to be on the branch the
# message is about to join. Called by .git/hooks/commit-msg, and runnable by
# hand over any message file.
#
# WHY IT EXISTS, and the case is not hypothetical. On 2026-09-07 a message was
# amended before pushing. The amend gave the commit a new sha, and the message
# of the NEXT commit, written before the amend and signed after it, kept citing
# the old one. Both went to shared history. `9ce3623` is still readable on the
# machine that made it, because an amended commit stays in the object store
# until it is pruned, so every check that asks "does this object exist" says yes
# and certifies a sha that no clone can resolve.
#
# THAT IS WHY THE TEST IS ANCESTRY AND NOT EXISTENCE, and the difference is the
# whole guard. Measured on this tree on 2026-09-08:
#
#   git cat-file -t 9ce3623                    -> commit
#   git merge-base --is-ancestor 9ce3623 HEAD  -> rc 1
#
# The first approves it. The second is the one that says no.
#
# WHAT IT DOES NOT DO, said here because a guard that hides its blind spots is
# worse than none:
#
#   - It cannot see a sha that is not in THIS object store. A sha from another
#     repository, or a typo that lands on nothing, resolves to no object and is
#     skipped. The guard is about citing a commit that this branch does not
#     carry, not about citing something unresolvable.
#   - A fresh clone does not have the dangling `9ce3623` either, so running this
#     there over the same message would pass. It runs where the commit is made,
#     which is the only place the dangling object exists and the only place the
#     message can still be fixed.
#   - It judges against HEAD, which during `git commit` is the parent of what is
#     being written and during `git commit --amend` is the commit BEING REPLACED.
#     An earlier version of this comment said nothing was lost there, and that
#     was wrong. A message CAN cite its own past sha, and under an amend that
#     sha is orphaned the instant the commit lands. Measured: a message reading
#     "this replaces 8a4c501" passed with OK during the amend, because a commit
#     is an ancestor of itself, and after the amend `merge-base --is-ancestor`
#     on it gives rc 1. That is the exact shape of the defect this guard exists
#     for, approved by the guard. It is closed below, in the HEAD branch.
#
# WHY 7 HEX AND WHY THE OBJECT FILTER, with the count that decided it. A message
# in this project routinely carries 16-hex file fingerprints, all-digit CI run
# ids, and plain numbers, and all of them match [0-9a-f]{7,40}. Over the 159
# messages of this history, 19 carry such a token and 46 distinct tokens appear.
#
# THE FIGURE THAT DECIDES IS 10, NOT 19, and the first version of this comment
# said 19. Carrying a token and being refused are different predicates, and the
# first version added them as if they were one: nine of those nineteen carry
# only tokens that ARE ancestors of their own parent. Measured by running the
# literal reading over the whole history, each message against its parent, it
# refuses TEN: ae8e5f9 46613f5 d3247e3 e9c2909 46f431e 48bd32d 9d002a6 b75c7b0
# 0e7066f 3a23d76. Ten in 159 is still a rate that gets a guard switched off, and
# it is still nine wrong refusals against one right one, so the decision stands
# and the count that sustains it is now the measured one.
#
# So a token is judged ONLY if this repository resolves it to a commit object.
# Re-measured over the whole history, each message against its own parent, the
# guard rejects exactly ONE message, `ae8e5f9`, for exactly one token,
# `9ce3623`: the defect it was written for, and zero false positives in 159.
#
# THE ONE THING THE GUARD CANNOT SEE BY ITSELF: whether the commit about to be
# written REPLACES the tip. Nothing in the environment of `commit-msg` says so.
# Measured: `GIT_AUTHOR_DATE` is set identically in both cases, no GIT_* variable
# differs, and `ORIG_HEAD` is absent in both. What does say so is the argv of the
# process that runs the hook, which is git itself, and it says so even through
# `git rebase -i` with `reword`, whose inner call reads
# `git commit --amend --no-gpg-sign -e --allow-empty`. So the HOOK reads it, the
# hook alone, because only the hook has git as its parent, and it tells this
# script through NAYLAMP_MSG_PUNTA:
#
#   intacta      the tip survives this commit; citing it is fine
#   reemplazada  this is an amend; citing the tip orphans that sha  -> REFUSED
#   desconocida  the argv could not be read                          -> REFUSED
#
# Unset means `intacta`, and that is deliberate rather than lax: a run outside a
# commit, which is what the signing list does, replaces nothing. The gate is the
# hook, and the hook never leaves it unset.
#
# Usage:
#   gate/msg-shas.sh <message file> [repo dir]
#
# Exit: 0 every cited sha is on the branch (or none is cited)
#       1 at least one cited sha is NOT on the branch; each is named
#       2 the check could not run, which is NOT a pass

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "msg-shas: usage: $0 <message file> [repo dir]" >&2
	exit 2
fi

MENSAJE="$1"
REPO="${2:-.}"

if [ ! -r "${MENSAJE}" ]; then
	echo "msg-shas: cannot read the message at ${MENSAJE}" >&2
	echo "msg-shas: that is not a pass, it is the check failing to run" >&2
	exit 2
fi

if ! git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1; then
	echo "msg-shas: ${REPO} is not a git repository, so no sha can be judged" >&2
	echo "msg-shas: that is not a pass, it is the check failing to run" >&2
	exit 2
fi

# The comment character is read rather than assumed: `core.commentChar` can be
# set to anything, and a hard-coded `#` would silently start reading comment
# lines as message text on a machine that changed it.
MARCA="$(git -C "${REPO}" config --get core.commentChar 2>/dev/null || true)"
# `auto` is a valid value since git 2.45 and `config --get` returns the literal
# string, not the character git will pick. Taking it at face value made the cut
# below match nothing: measured, the same message that gives rc 0 with the
# default gave rc 1 with `core.commentChar=auto`, because the diff of
# `git commit -v` was being read as message text. With `auto` git still uses `#`
# unless the body already contains it, so `#` is the right fallback here and the
# residual case is declared: a body that forces git to pick another character.
case "${MARCA}" in ''|auto) MARCA='#' ;; esac

# HEAD, and an unborn HEAD is answered rather than skipped. A repository with no
# commits cannot have a cited sha on its branch, so any token that resolves to a
# commit there is by definition not an ancestor, and the loop below says so with
# the sha named. Reaching this with no cited sha still passes.
PUNTA="$(git -C "${REPO}" rev-parse --verify --quiet HEAD 2>/dev/null || true)"

# The body that git will actually keep. Two things get cut, and both have bitten
# somebody somewhere: comment lines, which git strips, and everything from the
# scissors marker down, which is where `git commit -v` puts the diff. The diff is
# not comment-prefixed, so without this cut a hex literal inside a patch would be
# judged as a cited sha.
CUERPO="$(mktemp "${TMPDIR:-/tmp}/msg-shas.XXXXXX")"
trap 'rm -f -- "${CUERPO}" 2>/dev/null || true' EXIT
awk -v m="${MARCA}" '
	index($0, m " ------------------------ >8 ------------------------") == 1 { exit }
	index($0, m) == 1 { next }
	# The trailer `git cherry-pick -x` writes names a commit of ANOTHER branch by
	# construction, and git wrote it, not the author. Judging it turned an
	# ordinary amend of a cherry-picked commit into a refusal, measured. It is
	# dropped rather than judged, and that is a declared hole: a sha smuggled in
	# a line of that exact shape is not seen.
	/^[[:space:]]*\(cherry picked from commit [0-9a-fA-F]+\)[[:space:]]*$/ { next }
	{ print }
' "${MENSAJE}" > "${CUERPO}"

# The tokens. Splitting on every non-alphanumeric byte is what keeps `run34178`
# and `sha16abc` from being read as bare hex: a token is the WHOLE alphanumeric
# run or it is nothing, so a hex string glued to a letter outside [a-f] never
# matches. Then 7 to 40, which is the range a git object name can be abbreviated
# to; 41 and up cannot be one.
# UPPERCASE COUNTS, and it did not before. git resolves `C108109` exactly like
# `c108109`, so a message citing a sha in capitals walked past a lowercase-only
# filter: measured end to end, a commit citing a foreign sha in capitals entered
# the history with `OK, the message cites no sha`.
TOKENS="$(tr -c '0-9a-zA-Z' '\n' < "${CUERPO}" | grep -xE '[0-9a-fA-F]{7,40}' | sort -u || true)"

if [ -z "${TOKENS}" ]; then
	echo "msg-shas: OK, the message cites no sha"
	exit 0
fi

fuera=0
juzgados=0
saltados=0

for t in ${TOKENS}; do
	# How many objects this prefix names. Zero means it is not a sha of this
	# store at all, which is the fingerprint and run-id case. More than one
	# means the message names something that does not identify a single
	# commit, and that is refused rather than skipped: an ambiguous citation
	# is unreadable, and this house does not read unreadable as pass.
	# THE STATE OF THE PIPELINE IS THE STATE OF `tr`, NOT OF GIT, and the first
	# version read it as if it were git's. Measured with a `git` that exits 3 on
	# this question: the guard turned a REFUSED into an OK and skipped the token
	# as "not a sha". A script whose header says three times that a failure to
	# run is not a pass had its one fail-open here. The state is captured and
	# decided, which is the form clause 18 fixes for this tree.
	lista="$(git -C "${REPO}" rev-parse --disambiguate="${t}" 2>/dev/null)" && rc_git=0 || rc_git=$?
	if [ "${rc_git}" -ne 0 ] && [ -n "${lista}" ]; then
		echo "msg-shas: REFUSED, git could not be asked about ${t} (rc ${rc_git}), so it cannot be cleared" >&2
		fuera=$((fuera + 1))
		continue
	fi
	if [ "${rc_git}" -ne 0 ] && [ -z "${lista}" ]; then
		# git says nothing AND fails. It cannot be told apart from a token that
		# names no object, and this house does not read that as a pass.
		echo "msg-shas: REFUSED, git failed (rc ${rc_git}) while resolving ${t}, so it cannot be cleared" >&2
		fuera=$((fuera + 1))
		continue
	fi
	cuantos="$(printf '%s' "${lista}" | grep -c . || true)"
	case "${cuantos}" in ''|*[!0-9]*) cuantos=0 ;; esac

	if [ "${cuantos}" -eq 0 ]; then
		saltados=$((saltados + 1))
		continue
	fi

	if [ "${cuantos}" -gt 1 ]; then
		echo "msg-shas: REFUSED, ${t} names ${cuantos} objects in this repository and identifies no single commit" >&2
		fuera=$((fuera + 1))
		continue
	fi

	oid="${lista}"
	tipo="$(git -C "${REPO}" cat-file -t "${oid}" 2>/dev/null || true)"

	# cat-file appears here for the one job it can do, naming the TYPE of an
	# object, and never as the verdict. A tree or a blob whose name happens to
	# be spelled in the message is not a cited commit and is not this guard's
	# business. An unreadable type is refused, not skipped.
	if [ -z "${tipo}" ]; then
		echo "msg-shas: REFUSED, the type of ${t} could not be read, so it cannot be cleared" >&2
		fuera=$((fuera + 1))
		continue
	fi
	if [ "${tipo}" != commit ]; then
		saltados=$((saltados + 1))
		continue
	fi

	juzgados=$((juzgados + 1))

	if [ -z "${PUNTA}" ]; then
		echo "msg-shas: REFUSED, the message cites commit ${t} (${oid}) and this branch has no commits yet" >&2
		fuera=$((fuera + 1))
		continue
	fi

	# CITING THE TIP IS THE CASE THE FIRST VERSION GOT WRONG. A commit is an
	# ancestor of itself, so `merge-base --is-ancestor` says yes and, under an
	# amend, the tip is replaced and the cited sha is orphaned the instant the
	# commit lands. Measured before this branch existed: a message reading
	# "this replaces 8a4c501" passed with OK during its own amend.
	if [ "${oid}" = "${PUNTA}" ]; then
		case "${NAYLAMP_MSG_PUNTA:-intacta}" in
			intacta)
				continue
				;;
			reemplazada)
				echo "msg-shas: REFUSED, the message cites the tip ${t} (${oid}) and this commit REPLACES the tip" >&2
				echo "msg-shas:   an amend gives the tip a new sha, so that citation is orphaned the moment it lands" >&2
				echo "msg-shas:   cite the parent, or say what the commit does without naming the sha" >&2
				fuera=$((fuera + 1))
				continue
				;;
			*)
				echo "msg-shas: REFUSED, the message cites the tip ${t} (${oid}) and whether this commit replaces the tip could not be read" >&2
				echo "msg-shas:   unreadable is not a pass: if this is an amend the citation is orphaned" >&2
				fuera=$((fuera + 1))
				continue
				;;
		esac
	fi

	if git -C "${REPO}" merge-base --is-ancestor "${oid}" "${PUNTA}" 2>/dev/null; then
		continue
	fi

	echo "msg-shas: REFUSED, the message cites commit ${t} (${oid}) and it is NOT on this branch" >&2
	echo "msg-shas:   HEAD is ${PUNTA}" >&2
	echo "msg-shas:   an amended or rewritten commit stays readable HERE and is on no branch" >&2
	fuera=$((fuera + 1))
done

if [ "${fuera}" -gt 0 ]; then
	echo "msg-shas: ${fuera} cited sha(s) are not on this branch; fix the message, not the check" >&2
	exit 1
fi

echo "msg-shas: OK, ${juzgados} cited commit sha(s) on this branch, ${saltados} token(s) that name no commit here"
exit 0
