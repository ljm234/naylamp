#!/bin/sh
# msg-sitio.sh: the message file is where the convention puts it, and the
# argument the signing command will consume resolves to exactly ONE file.
#
# WHY IT EXISTS, and the case is from 2026-09-08. A commit message was written
# to `<repo>/mensajes/01`. The convention of this house is
# `<workspace>/mensajes/NN-nombre-commit-msg.txt`, OUTSIDE the repository. The
# signing command takes its message through a glob over the convention
# directory; that glob matched nothing, the `-F` argument came out empty, and
# `git commit` failed. HEAD did not move and the three files stayed staged.
#
# THE FAILURE SURFACES WHERE THE ARGUMENT IS CONSUMED, NOT WHERE IT WAS MADE,
# which is the whole reason this is a separate step. Nothing complains when a
# file is written to the wrong path: the write succeeds. The break appears
# later, in another command, as an empty expansion, and an empty expansion is
# the one shape a shell hands over without a word.
#
# AND THE SECOND HALF IS WORSE THAN THE FIRST. A `mensajes/` directory inside
# the repository is a trap even when nobody is signing: a `git add -A` commits
# it as an ordinary file, and a commit message becomes tree content forever.
# `.gitignore` now carries `/mensajes/`, which makes that impossible; this check
# exists because ignoring it SILENTLY would hide the path mistake that broke the
# signing in the first place. Ignored is not the same as absent, and this says
# so out loud.
#
# Usage:
#   gate/msg-sitio.sh '<path or glob>'      quote it: the expansion is ours
#
# On success it prints the single resolved path on stdout, so it can also be
# used inline. On failure it prints nothing on stdout, so an inline use gets an
# empty argument and fails loudly rather than committing something else.
#
# Exit: 0 exactly one file, at the convention path, and no trap in the repo
#       1 the argument does not resolve to one file there, or the trap is set
#       2 the check could not run, which is NOT a pass

set -eu

if [ "$#" -eq 0 ]; then
	echo "msg-sitio: usage: $0 '<path or glob>'" >&2
	COMPLETO=1; exit 2
fi
if [ "$#" -gt 1 ]; then
	# MORE THAN ONE ARGUMENT IS NOT A USAGE ERROR, it is the answer. It means the
	# caller left the pattern unquoted and the shell already expanded it into
	# several words, which is the same "matches more than one" this guard exists
	# to refuse. The first version returned 2 here, the code reserved for "could
	# not run", so a reader could not tell a broken invocation from a real
	# verdict.
	echo "msg-sitio: REFUSED, the pattern was expanded by the caller into $# files and the signing takes one" >&2
	for a in "$@"; do echo "msg-sitio:     ${a}" >&2; done
	echo "msg-sitio:   quote the pattern so the expansion is counted here" >&2
	COMPLETO=1; exit 1
fi

GATE_DIR="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "${GATE_DIR}/.." && pwd)"
CONVENCION="$(cd "${RAIZ}/.." && pwd)/mensajes"

# THE TRAP FIRST, because it bites even when nobody is signing.
# AT ANY DEPTH, and the first version only looked at the root. Measured by a
# reader: `gate/mensajes/01` is invisible to a root-only check AND is not covered
# by a `/mensajes/` line in .gitignore, so it is at once unseen here and
# committable by `git add -A`, which is the exact outcome this refuses to allow.
TRAMPA="$(find "${RAIZ}" -name mensajes -not -path '*/.git/*' 2>/dev/null | head -n 1)"
if [ -n "${TRAMPA}" ]; then
	echo "msg-sitio: REFUSED, ${TRAMPA} exists INSIDE the repository" >&2
	echo "msg-sitio:   the convention is ${CONVENCION}/NN-name-commit-msg.txt, OUTSIDE" >&2
	echo "msg-sitio:   a mensajes/ in here is a trap: .gitignore keeps it out of a commit," >&2
	echo "msg-sitio:   but the signing glob still looks outside and finds nothing" >&2
	COMPLETO=1; exit 1
fi

if [ ! -d "${CONVENCION}" ]; then
	echo "msg-sitio: REFUSED, the convention directory ${CONVENCION} does not exist" >&2
	echo "msg-sitio:   mkdir it, and write the message inside" >&2
	COMPLETO=1; exit 1
fi

# THE EXPANSION IS OURS AND IT GETS COUNTED, which is what was not done. A glob
# that matches nothing looks exactly like one that matches one, and the shell
# hands it over without a word. Here it is counted before being handed on.
PATRON="$1"
CAJA="$(mktemp -d "${TMPDIR:-/tmp}/msg-sitio.XXXXXX")"
# THE COMPLETION FLAG, and it weighs more here than in a bench: an EXIT trap
# SWALLOWS the exit status when the script dies under `set -e` or `set -u`,
# measured in this machine's `/bin/sh`, which is bash 3.2. A guard dying halfway
# exited ZERO, that is, saying it PASSES. Measured before writing this: with an
# undefined variable placed before a single token is looked at, rc 0. Preserving
# `$?` inside the trap does not fix it, because by then it is already 0; the flag
# does, and in every shell.
COMPLETO=0
limpia_y_cierra() {
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "$(basename "$0"): ABORTED before deciding; this is NOT a pass" >&2
		rm -rf -- "${CAJA}" 2>/dev/null || true
		COMPLETO=1; exit 2
	fi
	rm -rf -- "${CAJA}" 2>/dev/null || true
}
trap limpia_y_cierra EXIT

# The candidates are filtered by EXISTENCE, so that a pattern matching nothing
# cannot slip through as its own literal text, which is what a shell does by
# default.
# AN EMPTY IFS FOR THE EXPANSION, and no intermediate file, and both by
# measurement. With the default IFS, `for c in ${PATRON}` splits on spaces BEFORE
# the glob expands, so a file named "01-with space-...txt" counted as two and a
# literal path carrying a space was refused while the same file by glob passed.
# And counting by writing lines into a file breaks on a newline inside the name:
# one single file counted as two, and the message said "matches 2 files" with one
# in front of it.
IFS_ANTES="${IFS-}"
IFS=""
n=0
UNICO=""
VARIOS=""
for c in ${PATRON}; do
	[ -f "${c}" ] || continue
	n=$((n + 1))
	UNICO="${c}"
	VARIOS="${VARIOS}${c}
"
done
IFS="${IFS_ANTES}"

if [ "${n}" -eq 0 ]; then
	echo "msg-sitio: REFUSED, '${PATRON}' matches no file" >&2
	echo "msg-sitio:   this is exactly what broke the signing: the -F is left empty" >&2
	echo "msg-sitio:   what ${CONVENCION} holds:" >&2
	ls -1 "${CONVENCION}" 2>/dev/null | sed 's/^/msg-sitio:     /' >&2 || true
	[ -z "$(ls -A "${CONVENCION}" 2>/dev/null || true)" ] && echo "msg-sitio:     (empty)" >&2
	COMPLETO=1; exit 1
fi

if [ "${n}" -gt 1 ]; then
	echo "msg-sitio: REFUSED, '${PATRON}' matches ${n} files and the signing takes one" >&2
	printf '%s' "${VARIOS}" | sed 's/^/msg-sitio:     /' >&2
	COMPLETO=1; exit 1
fi

# A SYMLINK IS REFUSED, naming its target. `-f` follows the link, so a link
# sitting in the convention directory and pointing anywhere at all passed: the
# checks below judged the LINK's path while the signing would read the TARGET's
# content. Measured by a reader with a link into the working tree, which is the
# very thing the trap check exists to stop.
if [ -h "${UNICO}" ]; then
	echo "msg-sitio: REFUSED, ${UNICO} is a symbolic link, pointing at $(readlink "${UNICO}" 2>/dev/null || echo '?')" >&2
	echo "msg-sitio:   the checks here judge the path and the signing reads the target; put the file itself here" >&2
	COMPLETO=1; exit 1
fi

# AND IT HAS TO BE READABLE, not merely to exist. `-f` is an existence test, and
# the header promises "the argument the signing will consume": a file that
# cannot be read cannot be consumed. Measured with mode 000: it passed.
if [ ! -r "${UNICO}" ]; then
	echo "msg-sitio: REFUSED, ${UNICO} exists but cannot be read" >&2
	COMPLETO=1; exit 1
fi

ABS="$(cd "$(dirname "${UNICO}")" && pwd)/$(basename "${UNICO}")"

# AND IT HAS TO BE WHERE THE CONVENTION SAYS, not merely somewhere readable. A
# message inside the working tree is the trap above under another name.
case "${ABS}" in
	"${CONVENCION}"/*) ;;
	*)
		echo "msg-sitio: REFUSED, ${ABS} is not in ${CONVENCION}" >&2
		echo "msg-sitio:   the convention puts the message OUTSIDE the repository, which is where the glob looks" >&2
		COMPLETO=1; exit 1
		;;
esac

# THE "INSIDE THE WORKING TREE" BRANCH WAS REMOVED, and the reason is worth more
# than the branch was. It could not be reached: to get here the case above has
# already required ABS to start with <workspace>/mensajes/, and the working tree
# is <workspace>/<repo>, a sibling. A reader proved it by deleting the branch and
# watching no row go red. Dead code that looks like a defence is worse than no
# defence, because it is counted as one.

# The name: NN-<something>-commit-msg.txt. This warns and does not refuse,
# because what breaks the signing is the place and not the name, and a rule that
# refuses on shape where the defect is of place gets switched off.
case "$(basename "${ABS}")" in
	[0-9][0-9]-*-commit-msg.txt) ;;
	*)
		echo "msg-sitio: warning, the name does not follow NN-name-commit-msg.txt: $(basename "${ABS}")" >&2
		;;
esac

printf '%s\n' "${ABS}"
COMPLETO=1; exit 0
