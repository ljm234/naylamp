#!/bin/sh
# msg-cifras.sh: the step that re-derives a message's figures from the raw that
# sustains them, BEFORE signing. It is not a hook and it cannot be one: the hook
# does not know which raw backs a message, and whoever signs does.
#
# WHY IT EXISTS, and the case is measured. The message of 29b40a7 published the
# total of its own bench TWICE and both times wrong, "Forty-one rows, fifteen of
# them red, zero failing" and "Forty-nine rows, nineteen red, zero failing",
# while the bench that same commit adds measures 53 rows, 22 red, 0 failing. The
# two figures came from runs that had already been retired. Nobody re-read the
# message against the file, and it went to shared history.
#
# THE FIRST DESIGN WAS THROWN AWAY, and the reason belongs here because it is the
# reason this one is shaped like this. A checker over DIGITS finds nothing in
# that message: the wrong figures are spelled in English words. Measured on it,
# a digit scan returns 26 lines, all of them dates, ports, an RFC number and row
# indices, and neither of the two defects. So this reads number WORDS as well as
# digits, in English and in Spanish, which is what the two registers of this
# project actually use.
#
# THE SECOND DESIGN WAS THROWN AWAY TOO. It flagged every counted figure in the
# message that did not match the raw. Measured over the three messages of
# 2026-09-07 it produced false positives at once: a message legitimately says
# "three rows now" about a subset and "the bench goes to 23 rows" about an
# earlier stage of the same work. A guard that reds on correct prose gets
# switched off, so it does not decide which mention is the total.
#
# WHAT IT DOES DECIDE, and it is one thing, precise and true: IF YOU NAME A RAW
# AS SUSTAINING THIS MESSAGE, THE RAW'S OWN TOTAL HAS TO BE IN THE MESSAGE. Not
# every number in the message has to be in the raw; the raw's total has to be in
# the message. On 29b40a7 the raw's total is 53 rows and the message never says
# 53, so it refuses and prints both. On ae8e5f9 the raw's total is 25 rows and
# the message says "the bench to 25 rows", so it passes even though the same
# message also says 23 about an earlier stage.
#
# And the rule is self-consistent: name the raws whose totals the message quotes,
# and no others. A raw the message was never going to quote is not a raw that
# sustains it.
#
# Usage:
#   gate/msg-cifras.sh <message file> <raw> [raw...]
#
# Exit: 0 nothing to re-derive, or every named raw's total is in the message
#       1 a named raw's total is NOT in the message; both are printed
#       2 the step was skipped or could not run, which is NOT a pass

set -eu

if [ "$#" -lt 1 ]; then
	echo "msg-cifras: usage: $0 <message file> <raw> [raw...]" >&2
	exit 2
fi

MENSAJE="$1"
shift

if [ ! -r "${MENSAJE}" ]; then
	echo "msg-cifras: cannot read the message at ${MENSAJE}" >&2
	echo "msg-cifras: that is not a pass, it is the step failing to run" >&2
	exit 2
fi

# The reader of counted figures, shared by the message and the raws. Two orders
# are read because the two registers of this project write them differently:
# "53 filas" and "filas: 24" are both totals, and an extractor that only knew one
# of them would be blind to half the evidence it is pointed at.
LECTOR='
function valor(t,   a, b, p) {
	t = tolower(t)
	if (t ~ /^[0-9]+$/) return t + 0
	if (t in PAL) return PAL[t]
	p = index(t, "-")
	if (p > 0) {
		a = substr(t, 1, p - 1); b = substr(t, p + 1)
		if ((a in PAL) && (b in PAL) && PAL[a] >= 20) return PAL[a] + PAL[b]
	}
	return -1
}
BEGIN {
	split("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen", E, " ")
	for (i = 1; i <= 20; i++) PAL[E[i]] = i - 1
	split("twenty thirty forty fifty sixty seventy eighty ninety", D, " ")
	for (i = 1; i <= 8; i++) PAL[D[i]] = (i + 1) * 10
	split("cero uno una dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince dieciseis diecisiete dieciocho diecinueve veinte", S, " ")
	V["cero"]=0; V["uno"]=1; V["una"]=1; V["dos"]=2; V["tres"]=3; V["cuatro"]=4
	V["cinco"]=5; V["seis"]=6; V["siete"]=7; V["ocho"]=8; V["nueve"]=9; V["diez"]=10
	V["once"]=11; V["doce"]=12; V["trece"]=13; V["catorce"]=14; V["quince"]=15
	V["dieciseis"]=16; V["diecisiete"]=17; V["dieciocho"]=18; V["diecinueve"]=19
	V["veinte"]=20; V["veintiun"]=21; V["veintiuno"]=21; V["veintiuna"]=21
	V["veintidos"]=22; V["veintitres"]=23; V["veinticuatro"]=24; V["veinticinco"]=25
	V["veintiseis"]=26; V["veintisiete"]=27; V["veintiocho"]=28; V["veintinueve"]=29
	V["treinta"]=30; V["cuarenta"]=40; V["cincuenta"]=50; V["sesenta"]=60
	V["setenta"]=70; V["ochenta"]=80; V["noventa"]=90
	for (k in V) PAL[k] = V[k]
	NOM["rows"]="filas"; NOM["row"]="filas"; NOM["filas"]="filas"; NOM["fila"]="filas"
	NOM["red"]="rojas"; NOM["rojas"]="rojas"; NOM["rojos"]="rojas"
	NOM["failing"]="falla"; NOM["falla"]="falla"; NOM["failures"]="falla"
	NOM["verdicts"]="veredictos"; NOM["veredictos"]="veredictos"
	NOM["findings"]="hallazgos"; NOM["hallazgos"]="hallazgos"
}
{
	# EL PUNTO Y EL GUION BAJO NO SEPARAN, y esa linea la puso una medida. Con
	# ellos como separador, `phase_red launches three mutant daemons` daba
	# rojas=3 y `P2.red.barrier` ofrecia otro `red` suelto: el nombre de una
	# fase se leia como el nombre de un recuento. Manteniendolos dentro del
	# token, `phase_red` y `P2.red.barrier` no son ningun nombre contado, y
	# `red.` al final de una frase se recupera recortando los signos de los
	# bordes.
	# UNA COMA CORTA LA VENTANA, y sin esto el lector fabricaba totales que el
	# crudo no dice. Medido sobre la linea que imprime gate/p2-guard-test.sh,
	# `filas: 24, veredictos rojos obtenidos: 15, filas que no cuadran: 0`: la
	# ventana de tres saltaba la coma y sacaba `veredictos=24` por `24,
	# veredictos` y `filas=15` por `15, filas`. Dos de los tres totales eran
	# invencion, y nombrar ese crudo hacia rechazar un mensaje correcto. Se
	# recorre CAMPO a campo, y un recuento no cruza una coma ni un punto y coma.
	n_campos = split($0, CAMPOS, /[,;]/)
	for (ci = 1; ci <= n_campos; ci++) {
	linea = CAMPOS[ci]
	gsub(/[^A-Za-z0-9._-]+/, " ", linea)
	n = split(linea, T, " ")
	for (i = 1; i <= n; i++) {
		t = T[i]
		gsub(/^[._-]+|[._-]+$/, "", t)
		T[i] = t
	}
	for (i = 1; i <= n; i++) {
		v = valor(T[i])
		salto = 0
		# DECENA MAS UNIDAD, que el guion no leia y hacia rechazar prosa
		# correcta. Medido: `Twenty two rows` daba filas=2 y filas=20, y
		# `Cincuenta y tres filas` daba filas=3. Se admite la decena seguida de
		# unidad, con o sin `y`/`and` en medio. Lo que sigue SIN leerse son las
		# centenas, en los dos idiomas, y va declarado en vez de disimulado.
		if (v >= 20 && v % 10 == 0) {
			u = -1
			if (i + 1 <= n) u = valor(T[i+1])
			if (u >= 1 && u <= 9) { v = v + u; salto = 1 }
			else if (i + 2 <= n && (tolower(T[i+1]) == "y" || tolower(T[i+1]) == "and")) {
				u = valor(T[i+2])
				if (u >= 1 && u <= 9) { v = v + u; salto = 2 }
			}
		}
		if (v >= 0) {
			# numero primero, nombre despues, ventana de tres desde el final
			# del numero, para que la decena compuesta no se coma la ventana
			for (j = i + salto + 1; j <= i + salto + 3 && j <= n; j++)
				if (tolower(T[j]) in NOM) { print NOM[tolower(T[j])] "=" v; break }
		}
	}
	}
	# NOMBRE PRIMERO SOLO CON DOS PUNTOS DETRAS, que es como los bancos de este
	# arbol escriben un total: `filas: 24`. Sin la restriccion, una frase como
	# "red rows appeared 3 times" daria un recuento que nadie afirmo. Se mira la
	# linea SIN tocar, porque los dos puntos son justo lo que el gsub borra.
	cruda = $0
	while (match(cruda, /[A-Za-z]+[ \t]*:[ \t]*[A-Za-z0-9-]+/)) {
		trozo = substr(cruda, RSTART, RLENGTH)
		cruda = substr(cruda, RSTART + RLENGTH)
		p = index(trozo, ":")
		nom = tolower(substr(trozo, 1, p - 1))
		gsub(/[ \t]+/, "", nom)
		val = substr(trozo, p + 1)
		gsub(/[ \t]+/, "", val)
		if ((nom in NOM)) {
			v = valor(val)
			if (v >= 0) print NOM[nom] "=" v
		}
	}
}'

CAJA="$(mktemp -d "${TMPDIR:-/tmp}/msg-cifras.XXXXXX")"
trap 'rm -rf -- "${CAJA}" 2>/dev/null || true' EXIT

# Only the body git keeps, for the same reason msg-shas.sh cuts it: a figure
# inside a comment or inside the diff of `git commit -v` is not a claim.
MARCA="$(git config --get core.commentChar 2>/dev/null || true)"
case "${MARCA}" in ''|auto) MARCA='#' ;; esac
awk -v m="${MARCA}" '
	index($0, m " ------------------------ >8 ------------------------") == 1 { exit }
	index($0, m) == 1 { next }
	{ print }
' "${MENSAJE}" > "${CAJA}/cuerpo"

awk "${LECTOR}" "${CAJA}/cuerpo" | sort -u > "${CAJA}/del-mensaje"

# A MESSAGE THIS STEP CANNOT READ IS NOT A MESSAGE WITHOUT FIGURES, and the
# difference decides. If no raw was named there is nothing to compare against and
# an empty reading is genuinely nothing to do. But if a raw WAS named, the author
# is asserting that this message quotes that raw's total, and an empty reading
# means the extractor did not understand what the message says: hundreds in
# either language, a register it does not carry, a shape nobody foresaw. Passing
# there is the fail-open this step exists to avoid, and it was open: with the
# Spanish table rewound, a message written entirely in Spanish numerals yielded
# nothing and the step said OK.
if [ ! -s "${CAJA}/del-mensaje" ]; then
	if [ "$#" -eq 0 ]; then
		echo "msg-cifras: OK, the message states no counted figure and no raw was named, so there is nothing to re-derive"
		exit 0
	fi
	echo "msg-cifras: REFUSED, a raw was named and this step read NO counted figure in the message" >&2
	echo "msg-cifras:   either the message does not quote that raw, or its figures are written in a form this step cannot read" >&2
	echo "msg-cifras:   hundreds are not read in either language; that limit is known and declared" >&2
	exit 1
fi

# The step cannot be skipped in silence. A message WITH figures and no raw named
# is the exact state that put two retired totals into shared history.
if [ "$#" -eq 0 ]; then
	echo "msg-cifras: REFUSED, the message states counted figures and no raw was named" >&2
	echo "msg-cifras: what the message claims:" >&2
	sed 's/^/msg-cifras:   /' "${CAJA}/del-mensaje" >&2
	echo "msg-cifras: name the raw that sustains them: $0 ${MENSAJE} <raw>" >&2
	exit 2
fi

# The anchor for a raw's own total, written out rather than guessed. These are
# the three shapes the benches of this tree print, and a raw that matches none
# of them is refused instead of silently contributing nothing.
ANCLA='^[[:space:]]*(RESULTADO|RESUMEN|resumen|filas)[[:space:]]*:'

fuera=0
: > "${CAJA}/todos-los-totales"

for crudo in "$@"; do
	# A RETIRED RUN IS NOT EVIDENCE, and this is the hole that mattered most:
	# the defect this step exists for was two totals taken from runs that had
	# already been retired, and the first version cleared the guilty message with
	# rc 0 when pointed at the very file the wrong figures came from. Clause 27
	# of the protocol puts the word RETIRADA in the NAME, so the name is where
	# this reads it.
	case "${crudo}" in
		*RETIRADA*|*retirada*|*Retirada*)
			echo "msg-cifras: REFUSED, ${crudo} is a RETIRED run and a retired run is not evidence" >&2
			echo "msg-cifras:   clause 27 puts RETIRADA in the name; name the run that stands" >&2
			fuera=$((fuera + 1))
			continue
			;;
	esac
	if [ ! -r "${crudo}" ]; then
		echo "msg-cifras: REFUSED, cannot read the raw at ${crudo}" >&2
		fuera=$((fuera + 1))
		continue
	fi
	grep -E "${ANCLA}" "${crudo}" > "${CAJA}/lineas" 2>/dev/null || true
	if [ ! -s "${CAJA}/lineas" ]; then
		echo "msg-cifras: REFUSED, ${crudo} carries no total line this step knows how to read" >&2
		echo "msg-cifras:   expected a line starting with RESULTADO:, RESUMEN:, resumen: or filas:" >&2
		fuera=$((fuera + 1))
		continue
	fi
	awk "${LECTOR}" "${CAJA}/lineas" | sort -u > "${CAJA}/del-crudo"
	if [ ! -s "${CAJA}/del-crudo" ]; then
		echo "msg-cifras: REFUSED, the total line of ${crudo} yielded no counted figure" >&2
		fuera=$((fuera + 1))
		continue
	fi
	cat "${CAJA}/del-crudo" >> "${CAJA}/todos-los-totales"
	while IFS= read -r par; do
		if grep -qxF "${par}" "${CAJA}/del-mensaje"; then
			continue
		fi
		nombre="${par%%=*}"
		valor="${par#*=}"
		echo "msg-cifras: REFUSED, ${crudo} totals ${nombre}=${valor} and the message never says it" >&2
		dice="$(grep "^${nombre}=" "${CAJA}/del-mensaje" | sed "s/^${nombre}=//" | tr '\n' ' ' || true)"
		if [ -n "${dice}" ]; then
			echo "msg-cifras:   the message says ${nombre}: ${dice}" >&2
		else
			echo "msg-cifras:   the message states no ${nombre} at all" >&2
		fi
		fuera=$((fuera + 1))
	done < "${CAJA}/del-crudo"
done

if [ "${fuera}" -gt 0 ]; then
	echo "msg-cifras: ${fuera} total(s) of the named raws are not in the message; re-derive before signing" >&2
	exit 1
fi

n_tot="$(sort -u "${CAJA}/todos-los-totales" | grep -c . || true)"
echo "msg-cifras: OK, the ${n_tot} total(s) of the named raw(s) all appear in the message"
exit 0
