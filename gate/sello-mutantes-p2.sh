#!/usr/bin/env bash
# Mutation sweep over the seal of gate/p2.sh (DEFER-098).
#
# WHAT IT MEASURES. Each mutant rewinds ONE decision of the seal and the bench
# gate/p2-iron-test.sh is run against the mutated tree. What it publishes is which rows
# FALL: a mutant that knocks down no row is a decision the bench does not
# watch, and that is the whole question.
#
# THE MUTATED TREE IS A COPY AND NOT THE WORKING ONE. gate/ is copied WITHOUT gate/out,
# which is 183 MiB of artifacts, and the bench creates its own inside the copy.
#
# IT LIVES IN THE TREE AND NOT IN THE WORKSPACE, and the first version had it the other way.
# The argument for keeping it out was that this is not a guard but the
# instrument that MEASURES a guard, and that is still true; what did not hold
# is the conclusion. A new file in the workspace trips the hard rule of
# DEFER-079, which asks for an earlier copy of everything touched and cannot tell
# a new file from an old one nobody copied; its own comment says so. And
# the argument of substance is better than the one of form: the sentence "the mutants bite" is worth nothing if whoever reads it cannot derive it again. Here it can,
# against the same tree, with one command.
#
# IT IS NOT A CI STEP, and this is decided by measuring and not by habit. WHAT IT COSTS
# IS PRINTED BY THE SWEEP ITSELF on its last line, which is why there is no figure
# written here: a clock figure kept in a comment goes stale as soon as
# a mutant is added or the bench grows a row, and both have happened to this one
# in a single day. It would fit in a pipeline easily. What does not fit is its SHAPE: each
# mutant matches an EXACT STRING of gate/p2.sh and stops if it does not find it
# exactly once, which is what makes it honest by hand and poisonous in a pipeline. Any
# legitimate edit of those lines would turn the branch red with a message about the
# sweep and not about the change, and a CI that goes red for working gets switched off. It
# is run by hand when the seal is touched, which is exactly when its answer matters.
#
# Usage:
#   bash gate/sello-mutantes-p2.sh <repository path> <parent directory>
set -uo pipefail

# THE DELETE DOES NOT TAKE ITS PATH FROM AN ARGUMENT, and the first version of this script did:
# it did `rm -rf -- "$2"` on whatever it was handed. That is clause 23 broken in the
# most expensive place, because the way out of that clause is that a path that can do
# harm is written literally or VALIDATED before the command. Here the second is done and
# on top of that it is blunted: the second argument is a PARENT directory that has
# to exist already, and the workshop is a child of it with a name this script chooses and
# that carries its pid inside. What is deleted is always that path built by the
# script, never the one it is given, and it is checked to be so before deleting it.
#
# AND IT REFUSES OUT LOUD WITHOUT ARGUMENTS instead of dying with a `$1: unbound
# variable`, which is what it did. A script that breaks with the shell's raw error
# does not say what to do, and its exit status is confused with that of a measurement.
if [ "$#" -lt 2 ]; then
	cat >&2 <<'USO'
usage: bash gate/sello-mutantes-p2.sh <repository path> <parent directory for the workshop>

  The workshop is created INSIDE the parent, with a name of its own and the pid inside, and it is
  the only thing this script deletes. The parent has to exist already and is not touched.

  It exits 0 if the control stays at zero and no mutant comes out silent, 1 if not, and 2 if
  the check could not be made, which is neither a pass nor a failure.
USO
	exit 2
fi
REPO="$1"
PADRE="$2"
[ -d "${REPO}/gate" ] && [ -f "${REPO}/go.work" ] || {
	echo "sello-mutantes: ${REPO} does not look like the root of this repository" >&2; exit 2; }
[ -d "${PADRE}" ] || {
	echo "sello-mutantes: ${PADRE} does not exist, and this script does not create the parent directory" >&2; exit 2; }
TALLER="${PADRE}/naylamp-sello-mutantes-$$"
case "${TALLER}" in
	"${PADRE}/naylamp-sello-mutantes-"[0-9]*) ;;
	*) echo "sello-mutantes: the workshop ${TALLER} does not have the shape this script deletes by" >&2; exit 2 ;;
esac
rm -rf -- "${PADRE}/naylamp-sello-mutantes-$$"; mkdir -p "${TALLER}/gate/out"
for f in "${REPO}"/gate/*.sh "${REPO}"/gate/*.txt; do cp "${f}" "${TALLER}/gate/"; done
cp "${REPO}/go.work" "${TALLER}/" 2>/dev/null || true
# AND THE ENGINE SOURCES, which until 2026-09-09 did not come along. The
# workshop carried `gate/` and nothing else, and that was enough while the bench only looked at
# itself. It stopped being enough as soon as a row entered that CASTS a literal against the
# object that produces it: row 17db pulls `LITERAL_LIDER` out of `caliente()` and looks for it in
# `engine/`, and in a workshop without `engine/` that column comes out `no` ALWAYS. The symptom
# was immediate and ugly: `17db` appeared in the falling-row list of EVERY
# mutant, including the ones that touch nothing of its own, which means the sweep was
# measuring a bench running in a broken tree and calling it a bite. Only the
# `.go` files are copied, 144 files and 1.3 MB; nothing is compiled here.
(cd "${REPO}" && find engine -name '*.go' -print0) | while IFS= read -r -d '' g; do
	mkdir -p "${TALLER}/$(dirname "${g}")"
	cp "${REPO}/${g}" "${TALLER}/${g}"
done

# THE IDS HAVE TO BE UNIQUE, AND IT IS CHECKED BEFORE SPENDING EIGHTEEN MINUTES.
# On 2026-09-09 four mutants were added choosing `M51`, `M52` and
# `M53`, which already existed -two as mutants and one as a HALF-. Nothing failed: the
# sweep ran all eight and published its report with THREE PAIRS OF HOMONYMOUS LINES,
# each pair saying different things and with no way to know which was which. A report
# like that is not re-derivable, which is the only thing this script produces. The guard is
# STATIC and runs before copying anything, because the failure is known by reading the file
# and making it wait until the end would cost the whole run to say the same thing.
IDS_REPES="$(grep -oE '^(mutante|mitad) M[0-9a-z]+' "$0" | awk '{print $2}' | sort | uniq -d | tr '\n' ' ')"
if [ -n "${IDS_REPES%% }" ] && [ -n "${IDS_REPES}" ]; then
	echo "sello-mutantes: there are repeated mutant ids and the report could not be read: ${IDS_REPES}" >&2
	echo "sello-mutantes: each mutant or half carries an id of its own; the highest in use is seen with grep -oE '^(mutante|mitad) M[0-9]+' over this file" >&2
	exit 2
fi

T_INICIO="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || echo 0)"
echo "MUTATION SWEEP: the seal of gate/p2.sh against gate/p2-iron-test.sh"
echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "machine: $(sysctl -n hw.model 2>/dev/null || uname -m), $(uname -sr)"
echo "tree: $(cd "${REPO}" && git rev-parse --short HEAD), $(cd "${REPO}" && git status --porcelain | wc -l | tr -d ' ') uncommitted entries"
echo "workshop: ${TALLER}"
echo

CONTROL=0; MUTANTES=0; MUDOS=0; MITADES=0; MITADES_MAL=0
corre() {
	# NO PATH FROM THIS MACHINE IN HERE, and the first version carried one: the
	# toolchain directory of whoever wrote it, glued to the PATH. A script
	# committed with a machine's path inside is a script that only runs on that
	# machine and does not say so. Measured: gate/p2-iron-test.sh does not invoke go once, so
	# the inherited PATH is enough; and if it ever did, failing by saying "go: no
	# such file" is better than running with the wrong toolchain in silence.
	bash "${TALLER}/gate/p2-iron-test.sh" 2>/dev/null
}
control() {
	# THE CONTROL RESTORES EVERY SCRIPT and not only p2.sh, since the sweep
	# can mutate more than one: otherwise the last mutant of the preflight would stay
	# mounted and the control would measure a tree that is not the repository's.
	for f in "${REPO}"/gate/*.sh; do cp "${f}" "${TALLER}/gate/"; done
	cp "${REPO}/gate/p2.sh" "${TALLER}/gate/p2.sh"
	local n salida
	salida="$(corre)"
	n="$(printf '%s' "${salida}" | grep -cE '^ROW .* FAILING ' || true)"
	CONTROL="${n}"
	if ! printf '%s' "${salida}" | grep -q '^RESULTADO: '; then
		echo "CONTROL   unmutated: the bench ABORTS. Without a green control this sweep says nothing" >&2
		CONTROL=-1
		return
	fi
	printf 'CONTROL   unmutated: %s rows failing, and the bench reaches its summary\n' "${n}"
	echo
}
# THE MUTATION IS APPLIED IN ONE PLACE, and before it lived copied inside `mutante`.
# When `mitad` entered, a second copy of the same heredoc would have been needed, and two
# copies of a predicate are two places to fix it: the class this record
# pursues by name. It is moved out to a function and both call it.
aplica_mutacion() {
	/usr/bin/python3 - "$1" "$2" "$3" <<'FINDELPYTHON'
import sys
p, viejo, nuevo = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
if s.count(viejo) != 1:
    sys.stderr.write('the mutation does not bite where this sweep believes: %d occurrences\n' % s.count(viejo))
    raise SystemExit(3)
open(p, 'w', encoding='utf-8').write(s.replace(viejo, nuevo))
FINDELPYTHON
}

# A THIRD OUTCOME, and it enters on 2026-09-08 because the two that were there were not
# enough to tell the truth. A property can be defended by TWO
# independent guards, and then a mutant that removes ONLY ONE comes out silent without
# that meaning nobody watches it: it means the other one stops it. Counting it as
# FAILING is clause 15 again, an instrument that answers the opposite of
# what happens. `mitad` declares that case: it is EXPECTED silent, and what is a finding is
# that it BITES, because then the defence was not double and the prose that says so is
# wrong. The half that really breaks the property, removing both, goes separately and as an
# ordinary mutant.
mitad() {
	local etiqueta="$1" viejo="$2" nuevo="$3" glosa="$4" salida caidas
	local objeto="${5:-p2.sh}"
	MUTANTES=$((MUTANTES + 1))
	MITADES=$((MITADES + 1))
	for f in "${REPO}"/gate/*.sh; do cp "${f}" "${TALLER}/gate/"; done
	cp "${REPO}/gate/${objeto}" "${TALLER}/gate/${objeto}"
	if ! aplica_mutacion "${TALLER}/gate/${objeto}" "${viejo}" "${nuevo}"; then
		printf '%-5s MOUNT FAILURE: the mutation could not be applied   %s\n' "${etiqueta}" "${glosa}"
		MITADES_MAL=$((MITADES_MAL + 1))
		return
	fi
	salida="$(corre)"
	caidas="$(printf '%s' "${salida}" | grep -E '^ROW .* FAILING ' | awk '{print $2}' | tr '\n' ' ')"
	if ! printf '%s' "${salida}" | grep -q '^RESULTADO: '; then
		printf '%-5s UNEXPECTED  the bench ABORTS with half a guard removed   %s\n' "${etiqueta}" "${glosa}"
		MITADES_MAL=$((MITADES_MAL + 1))
	elif [ -z "${caidas}" ]; then
		printf '%-5s HALF  silent AS EXPECTED: the other guard alone stops it   %s\n' "${etiqueta}" "${glosa}"
	else
		printf '%-5s UNEXPECTED  BITES, fall: %-14s the defence was NOT double   %s\n' "${etiqueta}" "${caidas}" "${glosa}"
		MITADES_MAL=$((MITADES_MAL + 1))
	fi
}

mutante() {
	local etiqueta="$1" viejo="$2" nuevo="$3" caidas
	# THE FIFTH ARGUMENT IS THE FILE, and by default it is gate/p2.sh, which is where
	# almost everything this sweep measures lives. It enters on 2026-09-09 with
	# the five iron blockers: two of them, the deployment and the starting
	# state of the hosts, live in gate/p2-preflight.sh, and a sweep that only knows how
	# to mutate one file can say nothing about their rows. The mutated file is RESTORED
	# when each mutant finishes, so that one does not take the next one
	# down with it.
	local objeto="${5:-p2.sh}"
	MUTANTES=$((MUTANTES + 1))
	for f in "${REPO}"/gate/*.sh; do cp "${f}" "${TALLER}/gate/"; done
	cp "${REPO}/gate/${objeto}" "${TALLER}/gate/${objeto}"
	if ! aplica_mutacion "${TALLER}/gate/${objeto}" "${viejo}" "${nuevo}"; then
		printf '%-5s MOUNT FAILURE: the mutation could not be applied   %s\n' "${etiqueta}" "$4"
		MUDOS=$((MUDOS + 1))
		return
	fi
	local salida
	salida="$(corre)"
	caidas="$(printf '%s' "${salida}" | grep -E '^ROW .* FAILING ' | awk '{print $2}' | tr '\n' ' ')"
	if ! printf '%s' "${salida}" | grep -q '^RESULTADO: '; then
		printf '%-5s BITES  the bench ABORTS and does not reach its summary   %s\n' "${etiqueta}" "$4"
	elif [ -z "${caidas}" ]; then
		printf '%-5s SILENT  NO ROW FALLS   <-- nobody watches that decision   %s\n' "${etiqueta}" "$4"
		MUDOS=$((MUDOS + 1))
	else
		printf '%-5s BITES  fall: %-18s %s\n' "${etiqueta}" "${caidas}" "$4"
	fi
}

control

mutante M1 '
	seal_artifact
	# THE CONDITION ASKS WHETHER THERE WAS SOMETHING TO SEAL.' '
	# MUTANT M1: seal AFTER sweeping
	# THE CONDITION ASKS WHETHER THERE WAS SOMETHING TO SEAL.' 'sealing AFTER sweeping, not before'

mutante M2 '			[ -n "$(ls -A "${d}" 2>/dev/null | grep -vx RUNNING)" ] || continue' \
'			[ -n "$(ls -A "${d}" 2>/dev/null)" ] || continue' 'the sweep counts the RUNNING marker as content'

mutante M3 "					printf 'closed:      %s\n' \"\${marca}\" ;;" '					;;' 'the seal is finished WITHOUT a closed line'

mutante M4 "					printf 'verdicts:    %s\n' \"\${VERDICTS# }\"" "					printf '%s\n' \"\${linea}\"" 'the seal is finished without rewriting the verdicts'

mutante M5 '	[ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ] || return 0
	if [ -e "${OUT_LOCAL}/SEALED" ]; then' '	if [ -e "${OUT_LOCAL}/SEALED" ]; then' 'seal_artifact seals an empty artifact too'

mutante M6 '	elif [ "$(grep -m1 '"'"'^expected:'"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" = "${esperada}" ] \
		&& [ "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" -ge "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED" 2>/dev/null)" ]; then' \
'	elif true; then' 'the whole condition that decides whether the rewrite is published is removed'

mutante M6b '		&& [ "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" -ge "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED" 2>/dev/null)" ]; then' \
'		; then' 'only the line COUNT half of that condition'

mutante M7 '		[ "${SELLO_ESCRITO_AQUI}" -eq 1 ] && return 0
		echo "gate: ${OUT_LOCAL}/SEALED exists and THIS run did not write it, so nothing here is touched and no seal is completed" >&2
		return 0' '		return 0' 'the branch that confesses a seal this run did not write is removed'

mutante M8 '	case "${OUT_LOCAL}" in
		"${OUT_DIR}/p2-${RUN_ID}") ;;
		*)
			echo "gate: the seal was written but NOT completed: ${OUT_LOCAL} is not p2-${RUN_ID}" >&2
			return 0 ;;
	esac' '	:' 'completa_el_sello accepts any artifact name'

mutante M9 '		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: the rewrite did not match the seal it came from, so nothing was moved on top of it" >&2' \
'		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: the rewrite did not match the seal it came from, so nothing was moved on top of it" >&2' \
'the rejection branch DELETES the seal instead of the file beside it'

mutante M10 '	elif [ "${vistas}" -eq 0 ]; then
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal has no verdicts line, so it was left exactly as it was and carries no closed line" >&2' \
'	elif false; then
		:' 'the anti-vacuity of a seal with no verdicts line is removed'

mutante M11 '	[ "${SELLO_ESCRITO_AQUI}" -eq 1 ] || return 0
	[ -f "${OUT_LOCAL}/SEALED" ] || return 0' '	[ -f "${OUT_LOCAL}/SEALED" ] || return 0' \
'completa_el_sello without the clause 30 flag'

# M12 ENTERS THROUGH A READER, and its finding was this: of the three rejection rows,
# row 17p was backed by no mutant, so it was written by anticipation and
# the prose said the opposite. This mutant backs it: it removes the branch that
# tells "nothing could be written beside it" apart from the other negatives, so that a
# directory without permission falls into the branch below and the function confesses the wrong
# cause.
mutante M12 '	if [ ! -s "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" ]; then
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: nothing could be written beside it, so that seal now looks like one from a run that did not reach its end, and there is no way to say otherwise from inside a directory that cannot be written" >&2
	elif [ "${vistas}" -eq 0 ]; then' '	if [ "${vistas}" -eq 0 ]; then' \
'the branch that separates "nothing could be written beside it" from the other negatives is removed'

# M18 REWINDS THE GRAVEST DEFECT THIS PASS FOUND, and a bench did not find it:
# a reader reading the script found it. The bare `ask_on` followed by
# `rc_a=$?` killed phase_hygiene_fierro on the first round under `set -e`, so
# the seal sweep never ran on iron. Only row 17r can see it,
# because it is the only one that runs the whole phase instead of calling the seal's
# functions one by one.
mutante M18 '		rc_a="$(ask_on "$n" '"'"'pid=$(cat naylamp/naylampd-mutante.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'"'"'; echo $?)"' \
'		ask_on "$n" '"'"'pid=$(cat naylamp/naylampd-mutante.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'"'"'
		rc_a=$?' \
'the ask_on of the first loop of the iron hygiene is a bare command again'

# M13 AND M14 CLOSE THE LAST TWO ROWS NO MUTANT TOUCHED of those that are
# reachable. The ones left with no mutant behind them are said in the header of the
# bench and are all the DESCRIPTIVE half of a pair: 17c and 17d are the "after" and
# the "before" of 17b and 17e, 17h asserts the absence of remains on the happy path,
# where nothing is left behind, and 17f measures the byte by byte identity of `expected:`,
# which is not reachable from outside the function and is declared in writing.
mutante M13 '		fail "P2.hygiene: p2 iron artifacts under gate/out with no SEALED file, which make clean will refuse to sweep:${sin}"' \
'		note "P2.hygiene: p2 iron artifacts under gate/out with no SEALED file:${sin}"' \
'the sweep NAMES the unsealed artifacts but stops turning the phase red'

mutante M14 '	if [ "${ES_FIERRO}" -eq 1 ] && [ ! -e "${OUT_LOCAL}/SEALED" ] \
		&& [ -d "${OUT_LOCAL}" ] && [ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ]; then' \
'	if [ "${ES_FIERRO}" -eq 1 ]; then' \
'the "this run did not seal" line fires without asking whether there is a seal or whether there was anything to seal'

# M15 TO M17 ENTER THROUGH THE SAME READER THAT MEASURED THE SILENT DECISIONS: three guards
# written that no row knocked down. Each one now has its row and its mutant.
mutante M15 '	if [ "${ES_FIERRO}" -eq 1 ] && [ ! -e "${OUT_LOCAL}/SEALED" ] \
		&& [ -d "${OUT_LOCAL}" ] && [ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ]; then
		fail "P2.hygiene: this run wrote an artifact and did not seal it, so make clean will refuse to sweep gate/out until somebody seals it by hand"
	fi' '	:' \
'the only guard that speaks of the run in progress is removed WHOLE'

mutante M16 '		while IFS= read -r linea || [ -n "${linea}" ]; do' '		while IFS= read -r linea; do' \
'the rewrite loses the last line when it does not end in a newline'

mutante M17 '	if [ ! -s "${OUT_LOCAL}/SEALED" ]; then
		rm -f -- "${OUT_LOCAL}/SEALED"
		echo "gate: the seal could NOT be written at ${OUT_LOCAL}/SEALED, so this run'"'"'s artifact is unsealed and make clean will refuse to sweep gate/out" >&2
		return 0
	fi' '	:' \
'seal_artifact announces the seal without checking that it was written'

# M19 TO M23: THE CAP ON REHEARSAL ARTIFACTS, which enters on
# 2026-09-08 with the decision of whoever commissions it. Each one rewinds a different half and the
# row that catches it is written beside it.
mutante M19 '		[ "${nombre}" = "${propio}" ] && continue' '		:' \
'the cap can take away the artifact of the run IN PROGRESS'

mutante M20 '		[ "${n}" -le "${CONSERVA_ENSAYOS}" ] && continue' '		[ "${n}" -le 0 ] && continue' \
'the cap drops to zero and takes away everything that is not from this run'

mutante M21 '	[ "${ES_FIERRO}" -eq 1 ] && { printf '"'"'0'"'"'; return 0; }' '	:' \
'the rehearsal sweep runs on an iron run too'

# M22 HAS TO REMOVE BOTH GUARDS AT ONCE, and the two earlier versions
# removed one each and both came out SILENT. That was not a hole: the
# property "the cap never touches an iron artifact" is defended by TWO
# INDEPENDENT guards, the `ls` pattern that decides what is looked at and the `case` that decides
# what is deleted, and with either of the two standing iron survives. Widening the
# pattern alone leaves the `case` refusing with its warning; removing the `case` alone leaves the
# pattern bringing not one iron name into the loop. **A mutant coming out silent
# because ANOTHER guard stops it is not the same as coming out silent because nobody looks**, and the
# only way to separate the two things is a mutant that removes them together. This one
# removes them, and row 17x falls. The two silent versions are named here instead of
# deleted, because the useful conclusion is that this property has a double defence and that
# is only known by having measured it.
mitad M22 '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-local-[0-9]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue' '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-[0-9a-z]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue' \
'FIRST HALF: the cap pattern is widened and brings the IRON artifacts into the loop'

mitad M22b '		case "${nombre}" in
			p2-local-[0-9]*Z-[0-9]*)
				rm -rf -- "${OUT_DIR}/${nombre}"
				retirados=$((retirados + 1)) ;;
			*)
				echo "gate: NOT removing ${d}: not a rehearsal artifact of this gate" >&2 ;;
		esac' '		rm -rf -- "${OUT_DIR}/${nombre}"
		retirados=$((retirados + 1))' \
'SECOND HALF: the case that refuses what is not a rehearsal name is removed'

mutante M22c '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-local-[0-9]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue
		# THIS RUN'"'"'S OWN NEVER, and it is excluded BY NAME and not by trusting that
		# it is the most recent. The bench relies on its own being the newest; that
		# is true until the day two runs overlap, and then one deletes the other'"'"'s
		# live artifact. An explicit exclusion does not have that day.
		[ "${nombre}" = "${propio}" ] && continue
		n=$((n + 1))
		[ "${n}" -le "${CONSERVA_ENSAYOS}" ] && continue
		# THE MARKER TAKES PRECEDENCE OVER THE CAP, and this is the missing line. An
		# artifact whose run is still LIVE is not removed for being old: the cap is a
		# rule about what has already finished. And the one carrying a marker whose
		# process died is removed, but saying so, because its remains are information.
		# The cap'"'"'s count is NOT given back to the live one: it takes its place in the
		# window just like any other, and the only change is that it is not deleted.
		case "$(marcador_de "${d}")" in
			vivo)
				echo "gate: NOT removing ${d}: its run is still alive, marker and live pid inside" >&2
				continue ;;
			ilegible)
				echo "gate: NOT removing ${d}: it carries a marker whose pid cannot be read, and that is not the same as being dead" >&2
				continue ;;
			muerto)
				echo "gate: removing ${d} under the cap: it carries the marker of an unfinished run" >&2 ;;
		esac
		# Clause 23: the path is made of OUT_DIR plus a name that has just been
		# checked against the exact form by which this script deletes, and what is not
		# that form is said out loud instead of being deleted.
		case "${nombre}" in
			p2-local-[0-9]*Z-[0-9]*)
				rm -rf -- "${OUT_DIR}/${nombre}"
				retirados=$((retirados + 1)) ;;
			*)
				echo "gate: NOT removing ${d}: not a rehearsal artifact of this gate" >&2 ;;
		esac
	done' '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-[0-9a-z]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue
		[ "${nombre}" = "${propio}" ] && continue
		n=$((n + 1))
		[ "${n}" -le "${CONSERVA_ENSAYOS}" ] && continue
		rm -rf -- "${OUT_DIR}/${nombre}"
		retirados=$((retirados + 1))
	done' \
'BOTH AT ONCE: the cap looks at everything starting with p2- and deletes without checking the shape or the marker'

mutante M23 '		[ -d "${OUT_DIR}/p2-local-${id}" ] && continue' '		:' \
'the fleet is retired even though its artifact is still there'

# M24 TO M27: THE MARKER OVER THE CAP, which enters on 2026-09-09
# after measuring that the cap was taking away a live run. Each one rewinds one
# of the four decisions and the row that catches it is written beside it.
mutante M24 '		case "$(marcador_de "${d}")" in
			vivo)
				echo "gate: NOT removing ${d}: its run is still alive, marker and live pid inside" >&2
				continue ;;
			ilegible)
				echo "gate: NOT removing ${d}: it carries a marker whose pid cannot be read, and that is not the same as being dead" >&2
				continue ;;
			muerto)
				echo "gate: removing ${d} under the cap: it carries the marker of an unfinished run" >&2 ;;
		esac' '		:' \
'the cap deletes by age again without looking at the marker: the incident for the THIRD time'

mutante M25 '			ilegible)
				echo "gate: NOT removing ${d}: it carries a marker whose pid cannot be read, and that is not the same as being dead" >&2
				continue ;;' '			ilegible) ;;' \
'an unreadable pid is treated as dead: two answers where there are three'

mutante M26 '	if kill -0 "${pid}" 2>/dev/null || ps -p "${pid}" >/dev/null 2>&1; then
		printf '"'"'vivo'"'"'
	else
		printf '"'"'muerto'"'"'
	fi' '	printf '"'"'muerto'"'"'' \
'marcador_de says DEAD always, which means no marker protects'

mutante M27 '	[ -f "${d}/RUNNING" ] || { printf '"'"'sin-marcador'"'"'; return 0; }' '	[ -f "${d}/RUNNING" ] && { printf '"'"'vivo'"'"'; return 0; }' \
'the predicate becomes the FILE and not the process: an orphan marker blocks the cap forever'

# M28 TO M37: THE FIVE IRON BLOCKERS, each rewound to the shape it
# had when an external reader found them. Two of them live in
# gate/p2-preflight.sh, which is why this sweep learned to mutate more than one
# file.
mutante M28 '	if [ "${ES_FIERRO}" -eq 1 ]; then
		banner_fierro
	else
		banner_ensayo
	fi' '	banner_ensayo' \
'the banner loses its iron branch: the artifact declares itself a loopback rehearsal again'

mutante M29 '		if [ "${ES_FIERRO}" -eq 1 ]; then
			echo "gate: all IRON checks passed (${EXPECTED})"
		else
			echo "gate: all rehearsal checks passed (${EXPECTED})"
		fi' '		echo "gate: all rehearsal checks passed (${EXPECTED})"' \
'the LAST line of the log says rehearsal again on an iron run'

mutante M30 '		out="$(run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO} -group '"'"'${mgroup}'"'"' -dim ${DIM} -op put -id 7 -vec '"'"'$(vec_for 7)'"'"' ; echo __RC__=\$?" 2>&1)"' \
'		out="$("${BIN}" client -listen "${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO}" -group "${mgroup}" -dim "${DIM}" -op put -id 7 -vec "$(vec_for 7)" </dev/null 2>&1)"' \
'the mutant client runs on this laptop again, against an address this machine does not have'

# M31 REWINDS THE DEFECT AND DOES NOT BREAK THE FILE, which is what the first
# version did: it cut the python heredoc in half and left the quotes
# unmatched, so the bench died of syntax. That counts as detection in this
# sweep, and it is fine that it counts, but it is not what this was meant to measure: a mutant
# has to leave a script that RUNS and does what it did before, not one that does not start.
mutante M31 '	ask_on "${n}" "python3 -c \"
import os
d = os.path.dirname('"'"'${TESTIGO_REMOTO}'"'"') or '"'"'.'"'"'
f = os.open('"'"'${TESTIGO_REMOTO}'"'"', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(f, b'"'"'\\0'"'"' * ${TESTIGO_SEMILLA})
os.fsync(f)
os.close(f)
h = os.open(d, os.O_RDONLY)
os.fsync(h)
os.close(h)
\""' '	ask_on "${n}" "head -c ${TESTIGO_SEMILLA} /dev/zero > ${TESTIGO_REMOTO} && sync"' \
'the witness goes back to the GLOBAL sync: the instrument annulling what it measures'

mutante M32 '		if committed "${out}"; then
			echo "put ${id} ${vec} confirmed" >> "${MANIFEST}"' '		echo "put ${id} ${vec} uncertain" >> "${MANIFEST}"
		if committed "${out}"; then
			echo "put ${id} ${vec} confirmed" >> "${MANIFEST}"' \
'the in-flight writer notes uncertain BEFORE sending: every id becomes ambiguous, including the ones that came back with their ack'

mutante M33 '			seguidos=$(( seguidos + 1 ))
			[ "${seguidos}" -ge "${EN_VUELO_FALLOS_SEGUIDOS}" ] && break' '			seguidos=$(( seguidos + 1 ))' \
'the in-flight writer loses its bound of consecutive failures and goes on against three machines that no longer answer'

mutante M34 '	if "${GATE_DIR}/deploy.sh" >/dev/null 2>&1; then' '	if true; then' \
'the hot half stops deploying the binary and the certificates' p2-preflight.sh

mutante M35 '	if "${GATE_DIR}/cluster.sh" start >/dev/null 2>&1; then' '	if true; then' \
'the hot half stops raising the fleet' p2-preflight.sh

mutante M36 '	paso "naylamp/data, naylamp/logs and naylamp/data-mutante EMPTY on the three, checked and not assumed"' \
'	paso "naylamp/data not looked at"' \
'the hot half stops demanding the starting state of the hosts' p2-preflight.sh

mutante M37 '			'"'"'sudo -n test -w /proc/sysrq-trigger'"'"' >/dev/null 2>&1; then' \
'			'"'"'true'"'"' >/dev/null 2>&1; then' \
'the sudo of the cut stops being exercised before the cut' p2-preflight.sh

# M38 TO M44: WHAT THE SECOND ROUND OF THE EXTERNAL READER UNCOVERED. Two of these
# rewind defects the previous fix introduced, which means this sweep
# now also watches what the house broke while fixing itself.
mutante M38 '    if estado == INCIERTO:
        continue' '    pass' \
'the live set stops looking at the state again: the uncertain lines are demanded present and the run comes out red saying the engine lost an acked write'

mutante M39 'ID_EN_VUELO_DESDE=100' 'ID_EN_VUELO_DESDE=500' \
'the in-flight range goes back to 500: id 512 gives the ZERO vector and thirty ids collide with those of the workload'

mutante M40 '	choques="$(comprueba_rango_en_vuelo)"
	if [ "${choques}" != "0 0" ]; then' '	choques="0 0"
	if false; then' \
'the range guard stops running before writing'

mutante M41 '		printf '"'"'%s %s\n'"'"' "${id}" "${vec}" >> "${OUT_LOCAL}/en-vuelo-enviados.txt"' '		:' \
'what was sent stops being noted before sending it: a death between the ack and its line leaves a committed id out of the manifest'

mutante M42 '		grep -q "^put ${id} ${vec} confirmed\$" "${MANIFEST}" 2>/dev/null && continue
		grep -q "^put ${id} ${vec} uncertain\$" "${MANIFEST}" 2>/dev/null && continue' '		grep -q "^put ${id} ${vec} confirmed\$" "${MANIFEST}" 2>/dev/null && continue' \
'the fold stops being idempotent and duplicates lines when called twice'

mutante M43 '	if [ "${acks_en_vuelo}" -gt 0 ]; then' '	if true; then' \
'P2.cut.envuelo turns green without there having been a single in-flight ack'

mutante M44 '	# shellcheck disable=SC2086
	wait ${pids_corte_rojo}' '	wait' \
'phase_red_fierro waits again with a bare wait behind its cut'

# M45 TO M49: THE THIRD ROUND OF THE EXTERNAL READER. The first of these rewinds a
# defect introduced by the fix of the SECOND round, which means this sweep
# now watches three layers of fixes over fixes.
mutante M45 '	end_check P2.cut.fired

	# THE IN-FLIGHT VERDICT GOES BEHIND THIS PHASE'"'"'S end_check, never inside: it opens
	# its own block with its own begin_check, and sharing it was erasing the FAILs
	# of P2.cut.fired.
	veredicto_en_vuelo' '	veredicto_en_vuelo
	end_check P2.cut.fired' \
'veredicto_en_vuelo goes back INSIDE the P2.cut.fired block and its begin_check erases the FAILs of the phase'

mutante M46 '			'"'"'find naylamp/data naylamp/logs naylamp/data-mutante -mindepth 1 2>/dev/null | grep -c . ; echo __FIN__'"'"' 2>/dev/null || true)"
		case "${antes}" in' \
'			'"'"'ls -A naylamp/data naylamp/logs naylamp/data-mutante 2>/dev/null | grep -c . ; echo __FIN__'"'"' 2>/dev/null || true)"
		case "${antes}" in' \
'the precondition counts with ls -A again, which gives three over three empty directories' p2-preflight.sh

mutante M47 '		ok "the fleet elected a leader, and host ${quien} wrote it with ${LITERAL_LIDER}; the three were asked because only the one that WINS leaves that line"' \
'		ok "the fleet elected a leader, read from host 1"' \
'the leader message stops saying which of the three was read' p2-preflight.sh

# M50 TO M53: THE FOURTH LAYER. The first three rewind what the third round
# of the reader found; the last one rewinds the guard of the class.
mutante M50 '	veredicto_en_vuelo' '	# the verdict goes away from here' \
'the phase stops calling the in-flight verdict: P2.cut.envuelo is not registered and the iron list misses it'

mutante M51 '	if grep -q '"'"'^ack '"'"' "${OUT_LOCAL}/en-vuelo.txt" 2>/dev/null; then
		note "the in-flight writer has at least one acknowledged write; cutting now, so its age at the cut is as close to zero as this gate can put it"' \
'	if false; then
		note "the in-flight writer has at least one acknowledged write; cutting now, so its age at the cut is as close to zero as this gate can put it"' \
'the cut stops waiting for the first ack of the in-flight writer'

mutante M52 '	if [ -n "${PID_EN_VUELO:-}" ]; then
		kill "${PID_EN_VUELO}" 2>/dev/null || true
		wait "${PID_EN_VUELO}" 2>/dev/null || true
	fi' '	:' \
'the trap stops killing the in-flight writer, which survives the abort writing behind the seal'

# M53 IS EXPECTED SILENT AND ITS REASON LIVES IN ANOTHER FILE, which is what ties the two
# instruments together. Its place, `escribe_running` inside `phase_build`, is DECLARED
# in gate/sitio-test.sh with this reason written: exercising phase_build would be
# cross-compiling and deploying binaries inside a bench that exists so as not to
# power on anything. So it is not that nobody looks: it is that looking there costs more than
# that bench can spend, and it is said where it is read.
mitad M53 '	escribe_running
	if [ "${ES_FIERRO}" -eq 1 ]; then' '	if [ "${ES_FIERRO}" -eq 1 ]; then' \
'phase_build stops writing the RUNNING marker: its place is DECLARED exempt in gate/sitio-test.sh'

echo
# THE RESULT LINE IN THE HOUSE SHAPE, `RESULTADO: <n> rows, <n> failing`, and not in
# one of its own. A row of this sweep is ONE MUTANT, and a failing row is a SILENT
# mutant: a decision no row of the bench watches. It is written
# this way because the figures of a commit message are re-derived from the raw with
# gate/msg-cifras.sh, and that step reads the total by this exact shape; a summary
# line with a shape of its own gave it a total of zero and the step refused the
# message over a figure the raw does carry, only written another way.
echo "and the unmutated CONTROL gave ${CONTROL} rows failing over the whole bench"
if [ "${MITADES}" -ne 0 ]; then
	echo "${MITADES} of those are HALVES of a double defence: they are expected silent, and ${MITADES_MAL} came out otherwise"
fi
# ---- THE FOUR THE FOURTH ROUND LEFT UNBACKED -----------------------------------
#
# THE CENSUS FOUND THEM AND NOT I. After closing the fourth round the list of
# rows some mutant knocks down was crossed against the new rows, and FOUR did not appear:
# 17db, 17ic, 17ib and 17ie. And the IDS WERE CHOSEN BADLY the first time: M51, M52 and
# M53 already existed, two as mutants and one as a HALF, so the report came out
# with three pairs of homonymous lines and no way to know which was which. They go as
# M54, M55 and M56, behind the highest there was. A row with no mutant behind it is a row nobody has
# seen turn red, which is an unchecked assertion. And the crossing paid off at
# once: row 17ic came out green because of its OWN PROSE, because the comment that explains
# the fix CITES the broken shape and the grep matched the citation instead of the code.

mutante M47b "	local LITERAL_LIDER='role=leader'" \
"	local LITERAL_LIDER='became leader'" \
'the leader literal goes back to the phrase the engine does NOT write' p2-preflight.sh

mutante M54 '		( if testigo_arma "$n"; then echo 0; else echo 1; fi > "${OUT_LOCAL}/arma-rc-${n}" ) &' \
'		( testigo_arma "$n"; echo $? > "${OUT_LOCAL}/arma-rc-${n}" ) &' \
'the parallel arming loses its errexit exemption: with one arm failing, the subshell dies before writing its rc'

mutante M55 '	wait ${pids_arma}' \
'	:' \
'the arms are launched in the background and NOT waited for: the cut comes before the seeds are in place'

mutante M56 '	if [ "${acks_en_vuelo}" -gt 0 ]; then' \
'	if [ "${acks_en_vuelo}" -gt 999 ]; then' \
'the in-flight verdict never reaches pass, even with acks'

T_FIN="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || echo 0)"
/usr/bin/python3 -c "print('clock: %.1f s end to end, %s bench runs, the control run included' % (${T_FIN} - ${T_INICIO}, ${MUTANTES} + 1))" 2>/dev/null || true
echo "RESULTADO: ${MUTANTES} rows, $((MUDOS + MITADES_MAL)) failing"
rm -rf -- "${PADRE}/naylamp-sello-mutantes-$$"
[ "${MUDOS}" -eq 0 ] && [ "${MITADES_MAL}" -eq 0 ] && [ "${CONTROL}" -eq 0 ] || exit 1
exit 0
