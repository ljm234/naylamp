#!/usr/bin/env bash
# p2-iron-test.sh: the bench for the iron path of gate/p2.sh.
#
# It fires the predicates the iron cut turns on, from BOTH sides: the shape that
# is in the tree today, and a mutant that rewinds each decision to what it was
# before 2026-09-07. A row that only passes on the good shape proves nothing; the
# pair is what says the decision lives in code and not in prose.
#
# THE DANGEROUS OBJECT HERE IS THE STUB ssh, and it is built so it cannot
# fabricate. It answers only for the documentation-range fleet (RFC 5737) that
# this file sets, only under NAYLAMP_RED_ARM=1, and it runs the remote commands
# for real inside fake home directories. gate/common.sh already refuses a
# documentation address unless NAYLAMP_RED_ARM is set, so a real gate that found
# this stub in front of the real ssh would die at its first probe.
#
# The workspace is gate/out/banco-iron-p2, a literal path, rebuilt from scratch every
# run and removed when the rows are green. It is swept by make clean either way,
# and that is true because of the name: see the block beside the definition.
set -uo pipefail

# WHO THIS BENCH IS, said on its FIRST line of output and in a form that is not
# prose. It comes in on 2026-09-08. The sweep that reviews the archive of
# corridas/ classified each capture by looking in the BODY for the text of some of
# its rows, and that has two measured holes: the text of a row gets rewritten,
# and then the captures of that bench stop existing for the sweep with nobody
# noticing; and a WRITTEN report that cites a few rows is counted as a run,
# which is how four analyses of the archive ended up counted as captures. A
# citation always lives in the middle of a file, never on its first line, so
# this line tells a run apart from a citation of a run.
echo "BANCO: p2-iron-test"

. "$(dirname "$0")/entorno.sh"

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# THE WORKSHOP IS NOT CALLED p2-SOMETHING, and the old name, gate/out/p2-iron-test, was a
# defect measured by a reader. The `make clean` guard refuses by SHAPE,
# `p[0-9]-* ! p[0-9]-local-*`, so that name matched it: while the bench
# was running, a `make clean` in another terminal refused, and a killed bench left a
# directory that the guard protects and that nothing can seal. The header of this
# file said "It is swept by make clean either way", which was FALSE with that
# name and is true with this one. From the day this bench goes into CI, which is today,
# that stops being a nuisance confined to this machine.
BANCO="${GATE_DIR}/out/banco-iron-p2"

FALLAS=0
ROJAS=0
FILAS=0
# THE COMPLETION FLAG, and it comes in on 2026-09-08 with this bench: the
# day it starts running in CI. An EXIT trap swallows the exit status when
# the script dies halfway, so an aborted bench reads as a green step. This one
# had the trap and not the flag, that is, exactly the half that is needed for the
# failure to be silent.
#
# THE COUNT IS RE-DERIVED AND NOT RECITED, because the first version of this
# comment said "the other three benches" and "a fourth place", and both figures
# were false; a reader caught them by counting. On 2026-09-08 gate/ held EIGHT benches and SEVEN already
# carried the flag: this was the only one without it. And in ci.yml FOUR bench
# steps already ran, not three, so this is the FIFTH. The command that re-derives it is
# `grep -c "ABORTADO antes del resumen" gate/*-test.sh` file by file, and
# `grep 'run: ./gate/' .github/workflows/ci.yml` for the steps.
COMPLETO=0
# A ROW MAY NOT APPLY ON THIS MACHINE, and then it is not counted as a row.
# It is the same shape as gate/sello-test.sh: counting it as OK would publish a pass
# that nobody ran, and counting it as FAILING would turn CI red for the absence of something
# that the environment cannot give. It is declared, counted separately, and its reason is printed.
OMITIDAS=0
no_aplica() {
	OMITIDAS=$((OMITIDAS + 1))
	printf 'ROW %-4s NO APLICA %s\n' "$1" "$2"
}
fila() {
	local id="$1" quiero="$2" tengo="$3" porque="$4"
	FILAS=$((FILAS + 1))
	if [ "${quiero}" = "${tengo}" ]; then
		printf 'ROW %-4s OK    %s\n' "${id}" "${porque}"
	else
		printf 'ROW %-4s FAILING %s (queria [%s], salio [%s])\n' "${id}" "${porque}" "${quiero}" "${tengo}"
		FALLAS=$((FALLAS + 1))
	fi
}
roja() {
	local id="$1" quiero="$2" tengo="$3" porque="$4"
	ROJAS=$((ROJAS + 1))
	fila "${id}" "${quiero}" "${tengo}" "RED ${porque}"
}

# THE NAME OF THIS FUNCTION IS NOT ACCIDENTAL AND THE TRAP IS REGISTERED AFTER
# SOURCING p2.sh. The first version called it al_salir, which is exactly the
# name that gate/p2.sh gives to its own, so on sourcing it the definition from p2.sh
# OVERWROTE this bench's own and the trap ended up calling the one from p2.sh: the bench was not
# swept, its directory stayed in gate/out, and the artifact with an iron
# name that rows 15 to 17 create stayed as well, where `make clean` refuses
# to touch it for carrying no seal. Four of them stayed until the
# measured cleanup at the close found them. A bench that dirties what the gate
# protects is worse than one that fails.
barre_el_banco() {
	local rc=$?
	set +e
	# The artifact with an iron name that this bench creates is ALWAYS removed, with
	# its literal path and the run id inside, whether it fails or not: if it stayed, `make clean`
	# would refuse to sweep gate/out whole until somebody sealed it by hand.
	# THE TRAP LOOKS AT ARTEFACTO_REAL AND NOT AT OUT_LOCAL, and this is a correction of
	# 2026-09-08 that a reader brought in by killing the bench on purpose. The rows
	# of the seal MOVE OUT_LOCAL, OUT_DIR and RUN_ID to fake workshops to set up
	# their cases, and put them back by hand when they finish. An `exit` inside one of those
	# windows left the trap comparing the fake path against the real one:
	# the guard did not match, "NO retiro" was printed naming the WRONG path, and the
	# real iron artifact stayed in gate/out with its SEALED inside and with no
	# `closed:` line. That is, a FABRICATED artifact that reads as a killed iron
	# run, and that `make clean` never sweeps for carrying a seal. Measured: the
	# bench killed halfway through the block 17n-17q left
	# gate/out/p2-<run id>/{RUNNING,hygiene.log,SEALED}.
	#
	# ARTEFACTO_REAL is set ONCE, right after sourcing p2.sh, and no row
	# touches it. The shape guard stays, because what justifies an `rm -rf` is not
	# where the variable came from but that the path has been checked before it is used.
	if [ -n "${ARTEFACTO_REAL:-}" ] && [ "${ARTEFACTO_REAL}" = "${GATE_DIR}/out/$(basename "${ARTEFACTO_REAL}")" ] \
		&& [ "$(basename "${ARTEFACTO_REAL}" | cut -c1-3)" = "p2-" ]; then
		rm -rf -- "${GATE_DIR}/out/$(basename "${ARTEFACTO_REAL}")"
	elif [ -n "${ARTEFACTO_REAL:-}" ]; then
		echo "p2-iron-test: NO retiro ${ARTEFACTO_REAL}: no es la ruta que este banco sabe borrar" >&2
	fi
	# AND THE FAKE WORKSHOPS LIVE INSIDE THE BENCH, so they go away with it; but
	# first the write permission has to be given back, because row 17p puts a
	# directory in mode 500 and a bench killed between that chmod and its reversal leaves a
	# tree that neither `rm -rf` nor `make clean` can remove. Measured by a reader.
	[ -d "${BANCO}" ] && chmod -R u+w "${BANCO}" 2>/dev/null
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "p2-iron-test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2
		echo "p2-iron-test: el banco queda en gate/out/banco-iron-p2" >&2
		exit 1
	fi
	if [ "${rc}" -eq 0 ] && [ "${FALLAS}" -eq 0 ]; then
		cd "${GATE_DIR}/out" && rm -rf banco-iron-p2
		echo "p2-iron-test: todas las filas verdes; el banco y su artefacto se barren"
	else
		echo "p2-iron-test: ${FALLAS} filas en FALLA o un aborto; el banco queda en gate/out/banco-iron-p2" >&2
	fi
}

[ -d "${BANCO}" ] && { cd "${GATE_DIR}/out" && rm -rf banco-iron-p2; }
mkdir -p "${BANCO}/bin" "${BANCO}/casa" "${BANCO}/estado"
: > "${BANCO}/llave"
chmod 600 "${BANCO}/llave"

# ---- the ssh and scp stub -----------------------------------------------------
#
# Each fake host has its own home. The stub translates the address to the
# home and runs the command inside it, for real. A host marked "muerto" does not
# answer and exits 255, which is what ssh does when the transport drops, and it is
# the case that tells NO apart from UNREADABLE.
cat > "${BANCO}/bin/ssh" <<'SSHFIN'
#!/usr/bin/env bash
if [ "${NAYLAMP_RED_ARM:-}" != 1 ]; then
	echo "p2-iron-test stub ssh: refusing to answer without NAYLAMP_RED_ARM=1" >&2
	exit 255
fi
destino=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o|-i) shift 2 ;;
		-q|-r) shift ;;
		*) destino="$1"; shift; break ;;
	esac
done
host="${destino#*@}"
case "${host}" in
	192.0.2.1) n=1 ;;
	192.0.2.2) n=2 ;;
	192.0.2.3) n=3 ;;
	*) echo "stub ssh: unknown host ${host}" >&2; exit 255 ;;
esac
casa="${BANCO_CASA}/${n}"
[ -f "${BANCO_ESTADO}/${n}.muerto" ] && exit 255
cd "${casa}" || exit 255
# The absolute kernel paths are rewritten to the fake home: it is the only
# way for the primitives to be exercised AS THEY ARE WRITTEN, reading
# /proc/sys/kernel/..., instead of with a version of the script adapted to the bench.
orden="$*"
orden="${orden//\/proc\//${casa}/proc/}"
# A NODE CAN FAIL AT ARMING ALONE, and it has to be possible to ask for it. The seeding of the
# canary and its arming are two different trips and the gate treats them differently: without
# seeding the phase leaves before doing anything, and without arming the node is noted and the phase goes on.
# To exercise the second path the arming has to be denied LETTING the seeding through,
# and that is why breaking the file will not do: that breaks the seeding first. The arming
# is the only trip that makes a `>>` on the canary; the seeding uses python with
# O_TRUNC. That shape is matched and not a length, which would change the day somebody
# moves TESTIGO_COLA.
if [ -f "${BANCO_ESTADO}/${n}.no-arma" ]; then
	case "${orden}" in *">> naylamp/testigo-corte.bin"*) exit 1 ;; esac
fi
bash -c "${orden}"
SSHFIN
chmod +x "${BANCO}/bin/ssh"

cat > "${BANCO}/bin/scp" <<'SCPFIN'
#!/usr/bin/env bash
if [ "${NAYLAMP_RED_ARM:-}" != 1 ]; then
	echo "p2-iron-test stub scp: refusing without NAYLAMP_RED_ARM=1" >&2
	exit 255
fi
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|-i) shift 2 ;;
		-q|-r) shift ;;
		*) args+=("$1"); shift ;;
	esac
done
origen="${args[0]}"; destino="${args[1]}"
traduce() {
	local p="$1" h n
	case "${p}" in
		*@*:*) h="${p#*@}"; h="${h%%:*}"
		       case "${h}" in
		           192.0.2.1) n=1 ;; 192.0.2.2) n=2 ;; 192.0.2.3) n=3 ;;
		           *) echo "" ; return 1 ;;
		       esac
		       printf '%s/%s/%s' "${BANCO_CASA}" "${n}" "${p#*:}" ;;
		*) printf '%s' "${p}" ;;
	esac
}
o="$(traduce "${origen}")" || exit 255
d="$(traduce "${destino}")" || exit 255
mkdir -p "$(dirname "${d}")" 2>/dev/null
cp -R "${o}" "${d}" 2>/dev/null
SCPFIN
chmod +x "${BANCO}/bin/scp"

for n in 1 2 3; do
	mkdir -p "${BANCO}/casa/${n}/naylamp/data" "${BANCO}/casa/${n}/naylamp/logs" "${BANCO}/casa/${n}/naylamp/bin"
	# The two kernel readings go by their ABSOLUTE path, so the fake
	# home keeps them under its own prefix and the stub rewrites /proc to point there.
	mkdir -p "${BANCO}/casa/${n}/proc/sys/kernel/random"
	printf '176\n' > "${BANCO}/casa/${n}/proc/sys/kernel/sysrq"
	printf 'aaaa-bbbb-cccc-000%s\n' "${n}" > "${BANCO}/casa/${n}/proc/sys/kernel/random/boot_id"
	printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/${n}/naylamp/bin/naylampd"
done

export BANCO_CASA="${BANCO}/casa"
export BANCO_ESTADO="${BANCO}/estado"
export PATH="${BANCO}/bin:${PATH}"
export NAYLAMP_RED_ARM=1
export NAYLAMP_GATE_HOSTS=192.0.2.1,192.0.2.2,192.0.2.3
export NAYLAMP_GATE_PRIVATE=198.51.100.1,198.51.100.2,198.51.100.3
export NAYLAMP_GATE_KEY="${BANCO}/llave"
export NAYLAMP_GATE_USER=nadie
export NAYLAMP_P2_SOURCE_ONLY=1

echo "=============================================================================="
echo "BANCO DEL CAMINO DE FIERRO DE gate/p2.sh"
echo "fecha: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "flota de mentira: ${NAYLAMP_GATE_HOSTS} (RFC 5737), stub ssh bajo NAYLAMP_RED_ARM=1"
echo "=============================================================================="
echo

# shellcheck source=p2.sh
source "${GATE_DIR}/p2.sh" >/dev/null 2>&1
# Only NOW, with p2.sh already loaded and its names in place, is the trap armed.
# The iron artifact of THIS run, captured before any row
# can move OUT_LOCAL. It is the only thing the trap deletes under gate/out.
ARTEFACTO_REAL="${OUT_LOCAL}"
trap barre_el_banco EXIT
echo "-- cargado en modo fierro: ES_FIERRO=${ES_FIERRO}, artefacto $(basename "${ARTEFACTO_REAL}") --"
echo

# ---- 1 to 5: the sysrq reading, which is not a flat mask ----------------------
fila 1  "si" "$(sysrq_permite_reinicio 176 && echo si || echo no)" "sysrq=176, el valor real de naylamp-1, permite el reinicio"
fila 2  "si" "$(sysrq_permite_reinicio 1   && echo si || echo no)" "sysrq=1 habilita todas las funciones"
roja 3  "no" "$(sysrq_permite_reinicio 0   && echo si || echo no)" "sysrq=0 NO permite: el corte seria un no-op y todo verde de abajo mentiria"
roja 4  "no" "$(sysrq_permite_reinicio 16  && echo si || echo no)" "sysrq=16 es una mascara SIN el bit 128, y leerla como bitmask plano la daria por buena"
roja 5  "no" "$(sysrq_permite_reinicio 'cat: /proc/sys/kernel/sysrq: Permission denied' && echo si || echo no)" "una respuesta que no es un numero NO es un permiso"

# ---- 6 to 8: lineas_listening returns ONE line, always ------------------------
FLEET="${BANCO}/flota"; mkdir -p "${FLEET}"
printf 'arranca\nnada aqui\n' > "${FLEET}/node1.log"
printf 'arranca\nlistening on x\n' > "${FLEET}/node2.log"
# The predicate is "the value does NOT carry a newline inside". Counting with wc -l
# over an output without a final newline gives 0 and not 1, and the first version of these
# rows wrote it that way: a predicate that does not measure what its text says, inside
# the bench written to catch exactly that.
saltos_en() { printf '%s' "$1" | tr -cd '\n' | wc -c | tr -d ' '; }
fila 6 "0" "$(saltos_en "$(lineas_listening 1)")" "log que existe SIN la linea: CERO saltos dentro del valor (el defecto metia uno)"
fila 7 "0" "$(lineas_listening 1)" "y su valor es 0"
fila 8 "1" "$(lineas_listening 2)" "log con la linea: 1"
fila 9 "0" "$(lineas_listening 9)" "log que no existe: 0"
fila 10 "1" "$( set +e; [ "$(lineas_listening 1)" -gt 0 ] >/dev/null 2>&1; echo $? )" "la comparacion devuelve 1, que es FALSO; antes devolvia 2, que es un error de sintaxis disfrazado de falso"

# ---- 11 and 12: entry_log_bytes has a third outcome, UNREADABLE ---------------
mkdir -p "${FLEET}/node1/data"
head -c 100 /dev/zero > "${FLEET}/node1/data/raft-1.log"
head -c 50  /dev/zero > "${FLEET}/node1/data/raft-2.log"
fila 11 "150" "$(entry_log_bytes 1)" "suma los segmentos legibles"
# The unreadable file is set up with a CIRCULAR symbolic link and not with chmod
# 000: the first version used chmod and rows 12 and 33 came out green for the
# wrong reason, because stat reads METADATA and not content, so a file
# without read permission still gives its size. A loop of links makes
# stat fail for real, which is what these rows want.
mkdir -p "${FLEET}/node2/data"
ln -sf "raft-1.log" "${FLEET}/node2/data/raft-1.log"
roja 12 "2" "$( entry_log_bytes 2 >/dev/null 2>&1; echo $? )" "un segmento que stat no puede leer devuelve 2, y no un total corto en silencio"

# ---- 13 and 14: the iron artifact is called p2-, which is what make clean protects
fila 13 "p2" "$(basename "${OUT_LOCAL}" | cut -d- -f1)" "en fierro el artefacto es p2-<run id>, o sea el que la guarda del Makefile exige sellado"
fila 14 "1" "$(printf '%s' "$(basename "${OUT_LOCAL}")" | grep -c '^p2-[0-9]')" "y NO p2-local-, que es el que make clean barre sin preguntar"

# ---- 15 to 17: the RUNNING marker knows the iron name -------------------------
mkdir -p "${OUT_LOCAL}"
escribe_running
fila 15 "1" "$(grep -c "^run: $(basename "${OUT_LOCAL}")\$" "${OUT_LOCAL}/RUNNING")" "el marcador lleva dentro el nombre de fierro"
retira_running
fila 16 "0" "$( [ -f "${OUT_LOCAL}/RUNNING" ] && echo 1 || echo 0 )" "y la retirada lo encuentra por su literal de fierro"
escribe_running
GUARDA_OUT="${OUT_LOCAL}"
OUT_LOCAL="${GATE_DIR}/out/p2-un-tercer-nombre"
roja 17 "1" "$(retira_running 2>&1 | grep -c 'NOT removed')" "y con un tercer nombre se niega EN VOZ ALTA en vez de callarse"
OUT_LOCAL="${GUARDA_OUT}"
rm -f -- "${OUT_LOCAL}/RUNNING"

# ---- 17a to 17u: THE SEAL OF THE IRON ARTIFACT, DEFER-098 ---------------------
#
# WHY THESE ROWS LIVE HERE AND NOT IN gate/p2-guard-test.sh. That bench runs
# the REHEARSAL, and the rehearsal never seals: seal_artifact returns on its first
# line with ES_FIERRO other than 1, which is deliberate, because a p2-local- is
# swept by any make clean and a seal inside would be the evidence mark
# put on what is not one. A bench that cannot see the object does not prove it,
# and this file already carries that lesson written further up. Here p2.sh is loaded
# in iron mode, so the object exists: OUT_LOCAL is a real p2-<run id>.
#
# AND THEY FIRE FROM BOTH SIDES, which is what this bench says about itself on its
# first line. Each decision of the seal is measured in today's shape and in the shape
# it would have without it, because a row that only passes on the good shape does not
# tell "the decision is in the code" apart from "the decision is in the prose".
RUN_STARTED=1
SUBCOMANDO=all
ARRANCO_A="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EXPECTED="P2.build P2.hygiene"
VERDICTS=" P2.build=pass "

# The sweep returns the count of those it visited glued to the list of those that do not
# carry a seal, so the question "does it name ME" is asked by the name and not
# by the count: another p2-<run id> in gate/out would move the count and say nothing
# about this artifact.
esta_en_el_barrido() {
	case " $(artefactos_de_fierro_sin_sello) " in
		*" $(basename "${OUT_LOCAL}") "*) printf 'si' ;;
		*) printf 'no' ;;
	esac
}
# Counts the words of one line of the seal. grep -c exits 1 when it counts
# zero, which here is a value and not an error, and that is why the text is read and never the
# exit status.
palabras_de() { sed -n "s/^$1:  *//p" "${OUT_LOCAL}/SEALED" | tr ' ' '\n' | grep -c . ; }

# THE STATE OF ROW 17a IS SET UP HERE AND IS NOT INHERITED, and a reader measured what
# it cost: the row demands that the artifact have ONLY the marker inside, and that
# state was left by rows 15 to 17, not by it. One extra file in any row
# before it and 17a flips with nobody noticing. Now it redoes it from scratch.
rm -rf -- "${OUT_LOCAL}"
mkdir -p "${OUT_LOCAL}"
escribe_running
seal_artifact
roja 17a "no|no" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(esta_en_el_barrido)" "con solo el marcador dentro NO se sella y el barrido NO lo nombra: es la excepcion del vacio, y seal_artifact, el barrido y la guarda del Makefile la preguntan igual"

printf 'lo que esta corrida escribio\n' > "${OUT_LOCAL}/hygiene.log"
roja 17b "no|si" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(esta_en_el_barrido)" "con contenido y sin sello el barrido LO NOMBRA, y esa es la linea que pone roja a P2.hygiene y la que make clean convierte en una negativa"

seal_artifact
ESPERADA_ANTES="$(grep -m1 '^expected:' "${OUT_LOCAL}/SEALED")"
fila 17c "si|no" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(esta_en_el_barrido)" "y en cuanto el sello esta escrito, el barrido deja de nombrarlo: es la linea del barrido que salta un artefacto sellado. El ORDEN de las dos operaciones no lo mide esta fila, lo mide la 17k, y decir aqui que si era describirse de mas"

roja 17d "0|1|2" "$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")|$(palabras_de verdicts)|$(palabras_de expected)" "el sello a medias no lleva closed y trae MENOS veredictos que esperados, que es la forma que una corrida matada y una completa compartian en gate/p1.sh hasta el 8 de septiembre de 2026"

# The run reaches its end: the hygiene emits the verdict that was missing and the
# trap finishes the seal. It is the sequence of al_salir, without the trap.
record_verdict P2.hygiene pass
completa_el_sello
fila 17e "1|2|2" "$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")|$(palabras_de verdicts)|$(palabras_de expected)" "terminado, lleva UNA linea closed y tantos veredictos como esperados: una corrida completa y una matada dejan de tener la misma forma"
fila 17f "${ESPERADA_ANTES}" "$(grep -m1 '^expected:' "${OUT_LOCAL}/SEALED")" "la linea expected sale identica byte a byte, que es por la que dos sellos se comparan. Lo que esta fila mide es el brazo VERBATIM del bucle, no la guarda que compara: quitando esa guarda entera el banco sigue verde, medido, y por que no se puede alcanzar desde fuera va escrito en el bloque de la 17n"

completa_el_sello
fila 17g "1|1" "$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")|$(grep -c '^verdicts:' "${OUT_LOCAL}/SEALED")" "dos pasadas dejan UNA sola closed y UNA sola verdicts: terminar un sello ya terminado no lo duplica"
fila 17h "0" "$(ls -1 "${OUT_LOCAL}" | grep -c '^SEALED\.a-medias$')" "y no sobrevive ningun SEALED.a-medias dentro de un artefacto que el sello protege de make clean"

# 17i HAS TWO HALVES AND THE FIRST VERSION HAD ONLY ONE, which is a finding
# of a reader: measured only by the echo, a p2.sh with the flag line removed and
# its echo left in place would shout "THIS run did not write it" on the second normal
# call of EVERY run, which is the ordinary case, and the row stayed green. The
# missing half is that one: with the flag set, the second call is SILENT.
roja 17i "0|1|1" "$(seal_artifact 2>&1 | grep -c 'did not write it')|$( SELLO_ESCRITO_AQUI=0; seal_artifact 2>&1 | grep -c 'did not write it')|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")" "con la bandera puesta la segunda llamada de la corrida NO dice nada, y sin ella un sello que esta corrida no escribio se dice en voz alta y no se toca: la bandera de la clausula 30, y aqui basta una porque ningun subcomando de este guion adopta el id de otra corrida"

# 17u: A SEAL THAT COULD NOT BE WRITTEN IS NOT ANNOUNCED AS WRITTEN, and this row
#      comes in with the guard that makes it possible. Measured on this machine's bash 3.2, a
#      `{ ...; } > file` group whose destination cannot be created prints
#      its error, returns 1 and does NOT trigger `set -e`, so the flag went to 1 and
#      the console said "sealed the artifact" with no file in existence. The row
#      demands the three things: there is no seal, the flag is still at zero, and it is said.
GUARDA_OUT="${OUT_LOCAL}"
OUT_LOCAL="${BANCO}/artefacto-sin-permiso"
rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'contenido\n' > "${OUT_LOCAL}/manifest.txt"
GUARDA_RUNID2="${RUN_ID}"; RUN_ID="$(basename "${GUARDA_OUT}" | sed 's/^p2-//')"
mv -- "${OUT_LOCAL}" "${BANCO}/p2-${RUN_ID}"; OUT_LOCAL="${BANCO}/p2-${RUN_ID}"
chmod 500 "${OUT_LOCAL}"
SELLO_ESCRITO_AQUI=0
if ( : > "${OUT_LOCAL}/.sonda-17u" ) 2>/dev/null; then
	rm -f -- "${OUT_LOCAL}/.sonda-17u"
	chmod 700 "${OUT_LOCAL}"
	no_aplica 17u "el modo 500 no deniega la escritura en este entorno, probablemente root"
else
	SALIDA_17U="$(seal_artifact 2>&1)"
	chmod 700 "${OUT_LOCAL}"
	roja 17u "no|0|1" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|${SELLO_ESCRITO_AQUI}|$(printf '%s' "${SALIDA_17U}" | grep -c 'could NOT be written')" "un sello que no se pudo escribir no deja bandera puesta ni anuncia que se sello: sin esa comprobacion la redireccion falla en silencio y la corrida cierra diciendo que sello algo que no existe"
fi
rm -rf -- "${OUT_LOCAL}"
RUN_ID="${GUARDA_RUNID2}"
OUT_LOCAL="${GUARDA_OUT}"
SELLO_ESCRITO_AQUI=1

GUARDA_OUT="${OUT_LOCAL}"
OUT_LOCAL="${BANCO}/p2-un-cuarto-nombre"
mkdir -p "${OUT_LOCAL}"
printf 'expected:    P2.build\nverdicts:    P2.build=pass\n' > "${OUT_LOCAL}/SEALED"
roja 17j "1|0" "$(completa_el_sello 2>&1 | grep -c 'is not p2-')|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")" "y bajo un nombre que no es p2-<run id> se niega EN VOZ ALTA y no lo termina, en vez de escribir un closed dentro de un fichero que no sabe de quien es"
OUT_LOCAL="${GUARDA_OUT}"

# ---- 17k and 17l: THE ORDER, measured by its effect and not by its text ------
#
# The rows above call seal_artifact and the sweep separately, so they would
# stay green with the two lines swapped inside
# veredicto_del_sello. These two call the whole function, which is where the order
# lives: sealing first and sweeping afterwards is what makes the sweep include the
# seal the run has just written. With the two lines the other way round, the sweep
# would name the artifact and 17k would come out red.
rm -f -- "${OUT_LOCAL}/SEALED"
SELLO_ESCRITO_AQUI=0
CHECK_FAILED=0
veredicto_del_sello
fila 17k "sellado|verde" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo sellado || echo sin-sello)|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "veredicto_del_sello sella y DESPUES barre: el artefacto sale sellado y la fase no se pone roja por el"

# And the other half: a run that does NOT manage to seal itself. It is set up by taking
# the precondition RUN_STARTED away from seal_artifact, and not by editing the script: the
# object this row measures is the sweep, not the reason why there was no seal.
rm -f -- "${OUT_LOCAL}/SEALED"
SELLO_ESCRITO_AQUI=0
CHECK_FAILED=0
RUN_STARTED=0
veredicto_del_sello
roja 17l "sin-sello|rojo" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo sellado || echo sin-sello)|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "una corrida que no consigue sellarse se pone roja AQUI y AHORA, en la misma invocacion, en vez de que la evidencia se descubra ausente meses despues"
RUN_STARTED=1
CHECK_FAILED=0

# ---- 17m: and the TWO red lines do not say the same thing, so there are two ---
#
# veredicto_del_sello can turn red for two causes and they have different
# remedies: that THIS run did not manage to seal itself, which is a defect of the gate,
# or that under gate/out an artifact of ANOTHER run has been left unsealed, which is
# fixed by sealing it or sweeping it by hand. Without this row the first check
# would be implied by the sweep, because the sweep also names the artifact of
# this run, and a guard that no row can tell apart from another is decoration.
# Here they are told apart: with this run's own sealed and something foreign unsealed,
# the "this run" line does NOT come out, and the sweep's DOES.
#
# THE FOREIGN ARTIFACT IS NOT CREATED under gate/out, and that is the expensive part
# of this row. A p2-<run id> without a seal there would make `make clean` refuse
# forever if this bench died before removing it, and barre_el_banco only knows how to
# delete its own. OUT_DIR is moved to the bench's workshop, which is what the sweep
# reads, so the fake directory is born and dies inside what the trap already sweeps.
SELLO_ESCRITO_AQUI=0
seal_artifact
GUARDA_OUTDIR="${OUT_DIR}"
OUT_DIR="${BANCO}/gate-out-de-mentira"
mkdir -p "${OUT_DIR}/p2-20200101T000000Z-1"
printf 'de otra corrida, y sin sello\n' > "${OUT_DIR}/p2-20200101T000000Z-1/manifest.txt"
# THE OUTPUT IS COLLECTED IN A FILE AND NOT IN A SUBSTITUTION, and the first version
# used `$( )`. That runs in a SUBSHELL, so the `fail` inside did not reach the parent's
# CHECK_FAILED and the line that came after it, setting it back to zero, was a
# no-op that read as if it mattered. A reader measured it. With the file, the color
# of the phase is readable and the row can demand it.
CHECK_FAILED=0
veredicto_del_sello 2> "${BANCO}/17m.err"
OUT_DIR="${GUARDA_OUTDIR}"
roja 17m "0|1|rojo" "$(grep -c 'this run wrote an artifact' "${BANCO}/17m.err")|$(grep -c 'p2-20200101T000000Z-1' "${BANCO}/17m.err")|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "con lo propio sellado y un artefacto AJENO sin sello, la linea de ESTA corrida no sale, el barrido nombra al ajeno y la fase se pone roja: es el barrido quien enrojece aqui, y por eso las dos guardas rojas no son la misma"
CHECK_FAILED=0

# ---- 17s: the guard that NO mutant knocked down ------------------------------
#
# A READER BROUGHT IT BY MEASURING: deleting the line that says "this run wrote an
# artifact and did not seal it" whole, the bench stayed at 0 failing. 17l turns
# red anyway because in its setup the artifact is INSIDE gate/out and the
# sweep names it; 17m only checked that the line does NOT come out. So that guard
# was written, it was the only one that names the run in progress, and nobody watched
# it.
#
# THE ONLY SETUP IN WHICH ONLY IT CAN TURN RED: OUT_DIR in an EMPTY workshop, and
# the run's artifact OUTSIDE that workshop, with content and without a seal. That way
# the sweep has nothing to name and what stays red is that line or nothing.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"
OUT_DIR="${BANCO}/taller-vacio"; mkdir -p "${OUT_DIR}"
OUT_LOCAL="${BANCO}/artefacto-fuera-del-taller"
rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'lo que la corrida escribio\n' > "${OUT_LOCAL}/manifest.txt"
SELLO_ESCRITO_AQUI=0
CHECK_FAILED=0
veredicto_del_sello 2> "${BANCO}/17s.err"
roja 17s "1|0|rojo" "$(grep -c 'this run wrote an artifact' "${BANCO}/17s.err")|$(grep -c 'with no SEALED file' "${BANCO}/17s.err")|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "con el barrido sin nada que nombrar, la corrida que no consiguio sellar SU artefacto se pone roja por su propia linea: es la unica guarda que habla de la corrida en curso y hasta hoy no la miraba ninguna fila"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"
CHECK_FAILED=0

# ---- 17n to 17p: THE THREE NEGATIVES, and why they are needed -----------------
#
# THE ROWS ABOVE ALL TAKE THE HAPPY PATH, and that was measured rather
# than assumed: removing the whole condition that decides whether the rewrite is
# published, those that existed then stayed green. It is the same measurement that
# gate/sello-test.sh had to make on p1.sh, and the conclusion is the same: a bench that
# only walks the good path does not prove the guard, it proves the path. These three
# force a negative by three different routes and all three demand the same thing,
# which is the only thing that makes the negative useful: the seal survives BYTE FOR
# BYTE, no leftover stays beside it, and the function says so out loud.
#
# THE WORKSHOP IS MOVED, and with it OUT_DIR and RUN_ID, because completa_el_sello only
# acts on ${OUT_DIR}/p2-${RUN_ID} and these rows need seals that are deliberately
# broken. Being born inside the bench's workshop, none of them can be left in
# gate/out if this dies halfway.
#
# WHAT THESE THREE DO NOT REACH, declared and not hidden: the half of the guard
# that compares `expected:` byte for byte is NOT reachable from outside the function.
# The loop copies verbatim every line that is neither `verdicts:` nor `closed:`, so
# no valid input can make that line come out different. What measures it is
# gate/sello-test.sh, which EXTRACTS the function from p1.sh and mutates it; its twin here
# is covered by the other half of the same condition, the line count, which
# row 17n does reach. The day that half needs a row of its own, the place is
# an extraction bench and not a mutation from outside.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_RUNID="${RUN_ID}"; GUARDA_OUT="${OUT_LOCAL}"
OUT_DIR="${BANCO}/sellos"
RUN_ID="20260908T100000Z-1"
OUT_LOCAL="${OUT_DIR}/p2-${RUN_ID}"
SELLO_ESCRITO_AQUI=1
VERDICTS=" P2.build=pass P2.hygiene=pass "

# siembra_sello <closed lines it already carries> [sin-verdicts]
siembra_sello() {
	rm -rf -- "${OUT_LOCAL}"
	mkdir -p "${OUT_LOCAL}"
	{
		echo "Phase 2 iron gate artifact, sealed by gate/p2.sh."
		echo
		echo "expected:    P2.build P2.hygiene"
		[ "${2:-}" = sin-verdicts ] || echo "verdicts:    P2.build=pass"
		local i=0
		while [ "${i}" -lt "$1" ]; do
			echo "closed:      2026-09-08T1${i}:00:00Z"
			i=$((i + 1))
		done
		echo "This file is what keeps make clean from taking the directory."
	} > "${OUT_LOCAL}/SEALED"
	huella_del_sello
}
huella_del_sello() { md5 -q "${OUT_LOCAL}/SEALED" 2>/dev/null || md5sum "${OUT_LOCAL}/SEALED" | cut -d' ' -f1; }
restos_al_lado() { ls -1 "${OUT_LOCAL}" 2>/dev/null | grep -c '^SEALED\.a-medias$' ; }

# 17n: TWO closed inside. The rewrite throws both away and puts one, so it comes out
#      with ONE LINE FEWER; the count catches it and nothing is published.
ANTES_17N="$(siembra_sello 2)"
SALIDA_17N="$(completa_el_sello 2>&1)"
roja 17n "${ANTES_17N}|0|1" "$(huella_del_sello)|$(restos_al_lado)|$(printf '%s' "${SALIDA_17N}" | grep -c 'did not match the seal it came from')" "una reescritura que PIERDE lineas con expected intacta la caza el recuento: el sello sale identico byte a byte, sin restos y con su aviso"

# 17o: without a verdicts line there is nothing to rewrite, and saying nothing would
#      leave the seal described as one from a run that did not reach its end.
ANTES_17O="$(siembra_sello 0 sin-verdicts)"
SALIDA_17O="$(completa_el_sello 2>&1)"
roja 17o "${ANTES_17O}|0|1" "$(huella_del_sello)|$(restos_al_lado)|$(printf '%s' "${SALIDA_17O}" | grep -c 'has no verdicts line')" "un sello sin linea de veredictos se deja EXACTAMENTE como esta y se dice, en vez de darse por terminado en silencio"

# 17p: with no write permission beside the seal nothing can be written, not
#      even a note inside the seal itself, and the confession is the only thing
#      left. Mode 500: read and enter yes, create no.
# 17p ASKS FIRST WHETHER MODE 500 REALLY DENIES, and a reader brought that half while
#      thinking about CI. Running as root, and a job with `container:` runs as root, the
#      mode 500 does NOT deny writing: the row would fail with a fingerprint mismatch
#      and no explanation, red for the environment and not for the object. It is probed, and
#      if the probe writes, the row declares itself NOT APPLICABLE out loud instead of
#      running a check that cannot turn red. Today's job runs as `runner`, so
#      today it applies; the day that changes, this line will say so and not a red.
ANTES_17P="$(siembra_sello 0)"
chmod 500 "${OUT_LOCAL}"
if ( : > "${OUT_LOCAL}/.sonda-17p" ) 2>/dev/null; then
	rm -f -- "${OUT_LOCAL}/.sonda-17p"
	chmod 700 "${OUT_LOCAL}"
	no_aplica 17p "el modo 500 no deniega la escritura en este entorno, probablemente root; una fila que no puede fallar no prueba nada y no se cuenta"
else
	SALIDA_17P="$(completa_el_sello 2>&1)"
	chmod 700 "${OUT_LOCAL}"
	roja 17p "${ANTES_17P}|0|1" "$(huella_del_sello)|$(restos_al_lado)|$(printf '%s' "${SALIDA_17P}" | grep -c 'nothing could be written beside it')" "sin permiso de escritura al lado, el sello sale intacto, sin restos, y la funcion confiesa que ese sello va a parecer el de una version que no terminaba sus sellos"
fi

# 17t: THE LAST LINE WITHOUT A NEWLINE. The loop of completa_el_sello carries a
#      `|| [ -n "${linea}" ]` whose absence nobody watched, measured by a
#      reader. Without it, `read` returns false on a last line that does not end in
#      a newline and the loop THROWS IT AWAY; and the `closed:` added compensates
#      exactly the one lost, so the line count gives its approval and the seal is
#      published with one line missing. Today the seals are written by seal_artifact
#      with `echo`, but the Makefile invites writing one by hand and the guard that
#      should stop it is exactly the one that lets itself be fooled.
rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'Phase 2 iron gate artifact, sealed by gate/p2.sh.\nexpected:    P2.build P2.hygiene\nverdicts:    P2.build=pass\nla ultima linea, y va SIN salto' > "${OUT_LOCAL}/SEALED"
completa_el_sello >/dev/null 2>&1
roja 17t "1|1" "$(grep -c 'la ultima linea, y va SIN salto' "${OUT_LOCAL}/SEALED")|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")" "la ultima linea sin salto sobrevive a la reescritura: sin esa mitad de la condicion del bucle se pierde, y el closed que se anade tapa la perdida en el recuento"

# 17q: THE CLAUSE 30 FLAG, on its own, and it is the row that weighs the most of the
#      first seventeen. 17i measures the half that lives in seal_artifact, which REFUSES to
#      write over another run's seal; this one measures the half of completa_el_sello that
#      refuses to FINISH IT. It was needed because the mutant sweep measured it: with
#      that guard taken out whole, NO row fell. It is the only one that separates
#      finishing YOUR seal from putting a closed on another run's, and in gate/p1.sh
#      it is exactly the door through which `p1.sh hygiene <run id>` would have
#      overwritten nineteen verdicts with two.
ANTES_17Q="$(siembra_sello 0)"
SELLO_ESCRITO_AQUI=0
completa_el_sello
roja 17q "${ANTES_17Q}|0" "$(huella_del_sello)|$(restos_al_lado)" "sin la bandera de la ESCRITURA el sello no se toca ni se termina: es lo que impide que una invocacion que se ENCONTRO un sello le ponga encima sus propios veredictos"
SELLO_ESCRITO_AQUI=1

rm -rf -- "${BANCO}/sellos"
OUT_DIR="${GUARDA_OUTDIR}"; RUN_ID="${GUARDA_RUNID}"; OUT_LOCAL="${GUARDA_OUT}"
CHECK_FAILED=0

# ---- 17r: THE IRON HYGIENE PHASE REACHES ITS END UNDER set -e ----------------
#
# THE MOST EXPENSIVE ROW OF THIS BLOCK AND THE ONE THAT WEIGHS THE MOST, brought by a
# reader reading the script and not the bench. `ask_on` has THREE exits, 0 yes, 1 no, 2
# unreadable, and in step 1 of phase_hygiene_fierro the NORMAL answer is 1: the step above
# has just killed those daemons. Written as a bare command followed by `rc_a=$?`, that
# 1 is a failure in the eyes of `set -e`, which is the mode
# gate/p2.sh runs in, and IT KILLED THE PHASE ON THE FIRST PASS OF THE LOOP. Everything
# below was dead code on iron: steps 2, 3 and 4, the seal sweep that this whole block
# exists to test, the PASS line and `end_check` itself. So the sentence
# "the seal is written from the hygiene phase, before the sweep" was FALSE on the path
# of iron, and none of the rows above could see it, because they all
# call the seal functions DIRECTLY.
#
# HOW IT IS MEASURED, and it is the only form that separates the two: the phase is run
# WHOLE with `set -e` in place, against the fake fleet, and it must reach its LAST
# line, which is that of the seal sweep. With the bare command back, the phase does not
# print a single line and this row falls.
#
# WHAT THIS ROW DOES NOT SAY: nothing about whether steps 2 and 3 do their job well
# against real hosts. Only that the phase is walked whole instead of dying in its
# first loop, which is what was broken.
mkdir -p "${ARTEFACTO_REAL}"
# THE OUTPUT GOES TO A FILE AND NOT TO A SUBSTITUTION, and NO `|| true` touches the
# phase. The two previous versions of this line made the same defect that the row
# measures, each in its own way, and both were caught with the mutant in place:
#
#   1. `$( set -e; phase || true )`: a command to the left of `||` runs with
#      errexit SUPPRESSED, the suppression entering the body of the function, so the
#      `set -e` inside was worth nothing and the row came out green with the defect.
#   2. `SALIDA="$( set -e; phase )"` bare, here it does abort, but it kills the BENCH:
#      this file SOURCES gate/p2.sh, whose line 55 sets `set -euo pipefail`,
#      so from that line the bench runs with inherited errexit. A failed substitution
#      took the whole bench down with it and the row was not even printed.
#
# The form below separates the three things: an explicit subshell with its own
# `set -e`, which is not in a condition context and therefore suppresses nothing; the
# output to a file, which survives the death of the subshell; and a `set +e` around it,
# which keeps the death of the subshell from taking the bench with it.
set +e
( set -e; phase_hygiene_fierro ) > "${BANCO}/17r.out" 2>&1
set -e
roja 17r "1" "$(grep -c 'p2 iron artifacts under gate/out' "${BANCO}/17r.out")" "phase_hygiene_fierro se recorre ENTERA bajo set -e y llega a su ultima linea, el barrido de sellos: con un ask_on desnudo el 'no' normal del primer bucle mataba la fase y todo lo de abajo era codigo muerto en fierro"
CHECK_FAILED=0

# ---- 17v to 17z: THE CAP ON THE REHEARSAL ARTIFACTS --------------------------
#
# WHY THESE ROWS ARE HERE AND NOT IN gate/p2-guard-test.sh, with the measurement that
# decides it. That bench is the red arm of the rehearsal and would be the natural place; the
# problem is the price. To test a cap of FIVE there have to be SIX
# artifacts, and there each one comes out of a whole run of the rehearsal, which is a cost
# on the ORDER OF MINUTES per artifact: six of them are a cost counted in TENS of
# minutes, to measure a condition that here is set up with one `mkdir` per artifact. The clock of that
# run, with its three axes, is in ../corridas/naylamp-signing-readiness-20260916T1629Z.txt. One row goes
# there, the end to end one, which asks what this bench cannot: that
# after eighteen real rehearsals the cap held.
#
# AND A FAKE gate/out IS SET UP. The sweep deletes directories, so a row that
# ran it against the real gate/out would take down the artifacts of this machine to
# prove that it knows how to take them. OUT_DIR is moved to the bench's workshop,
# which the trap already sweeps.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"; GUARDA_FIERRO="${ES_FIERRO}"
OUT_DIR="${BANCO}/techo"
ES_FIERRO=0

# siembra_ensayos <how many>: creates artifacts with increasing timestamps and with
# content, and returns the name of the last one, which acts as the run in progress.
siembra_ensayos() {
	local i=1 n="$1" nombre
	rm -rf -- "${BANCO}/techo"; mkdir -p "${OUT_DIR}"
	while [ "${i}" -le "${n}" ]; do
		nombre="p2-local-2026090${i}T000000Z-${i}00"
		mkdir -p "${OUT_DIR}/${nombre}"
		printf 'manifiesto de la corrida %s\n' "${i}" > "${OUT_DIR}/${nombre}/manifest.txt"
		# The order by date is what the sweep uses, and `ls -dt` looks at mtime, so
		# it is fixed by hand instead of trusting the order in which they were created.
		touch -t "20260${i}010000" "${OUT_DIR}/${nombre}"
		i=$((i + 1))
	done
	printf '%s' "${nombre}"
}
cuenta_ensayos() { ls -1d "${OUT_DIR}"/p2-local-[0-9]*Z-[0-9]* 2>/dev/null | wc -l | tr -d ' '; }

# 17v: SEVEN artifacts and the one of the run in progress is one of them. FIVE remain
#      plus its own, and the one that goes is the OLDEST, not just any of them.
ULTIMO="$(siembra_ensayos 7)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
RETIRADOS="$(barre_ensayos_viejos)"
fila 17v "1|6|no|si" "${RETIRADOS}|$(cuenta_ensayos)|$([ -d "${OUT_DIR}/p2-local-20260901T000000Z-100" ] && echo si || echo no)|$([ -d "${OUT_LOCAL}" ] && echo si || echo no)" "con siete artefactos el techo retira UNO, deja cinco mas el de esta corrida, se lleva el MAS VIEJO y no toca el propio"

# 17w: BELOW the cap nothing is touched. A row that only tested the cutoff
#      would pass with a sweep that always deleted.
ULTIMO="$(siembra_ensayos 3)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
RETIRADOS="$(barre_ensayos_viejos)"
fila 17w "0|3" "${RETIRADOS}|$(cuenta_ensayos)" "por debajo del techo no se retira nada: el barrido no borra por costumbre, borra por cuenta"

# 17x: THE IRON ARTIFACT IS NOT TOUCHED, neither sealed nor unsealed, and this is
#      the row that separates the two classes. It is the half that the decision of
#      2026-09-08 makes obligatory: the cap is the rehearsal's and iron
#      stays out.
ULTIMO="$(siembra_ensayos 7)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
mkdir -p "${OUT_DIR}/p2-20260901T000000Z-999" "${OUT_DIR}/p2-20260902T000000Z-998"
printf 'de fierro, sellado\n' > "${OUT_DIR}/p2-20260901T000000Z-999/manifest.txt"
printf 'Phase 2 iron gate artifact\n' > "${OUT_DIR}/p2-20260901T000000Z-999/SEALED"
printf 'de fierro, SIN sello\n' > "${OUT_DIR}/p2-20260902T000000Z-998/manifest.txt"
touch -t 202601010000 "${OUT_DIR}/p2-20260901T000000Z-999" "${OUT_DIR}/p2-20260902T000000Z-998"
barre_ensayos_viejos >/dev/null
roja 17x "si|si" "$([ -d "${OUT_DIR}/p2-20260901T000000Z-999" ] && echo si || echo no)|$([ -d "${OUT_DIR}/p2-20260902T000000Z-998" ] && echo si || echo no)" "los artefactos de FIERRO sobreviven al techo, el sellado y el que no lo esta, aunque sean los mas viejos de todos: el techo es del ensayo y esa es la decision entera"

# 17y: the orphan fleet goes with its artifact and NOT before. A fleet whose
#      artifact is still there is from a live run.
ULTIMO="$(siembra_ensayos 3)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
mkdir -p "${OUT_DIR}/p2-local-fleet-20260901T000000Z-100" "${OUT_DIR}/p2-local-fleet-20260999T000000Z-777"
printf 'x\n' > "${OUT_DIR}/p2-local-fleet-20260901T000000Z-100/node1.log"
printf 'x\n' > "${OUT_DIR}/p2-local-fleet-20260999T000000Z-777/node1.log"
barre_ensayos_viejos >/dev/null
roja 17y "si|no" "$([ -d "${OUT_DIR}/p2-local-fleet-20260901T000000Z-100" ] && echo si || echo no)|$([ -d "${OUT_DIR}/p2-local-fleet-20260999T000000Z-777" ] && echo si || echo no)" "una flota cuyo artefacto SIGUE ahi se queda, y la huerfana se va: es un invariante, una flota nunca sobrevive a su artefacto, y no un segundo techo"

# 17z: ON IRON THE SWEEP DOES NOT RUN. Without this row, the guard of the first line
#      would be a decision nobody looks at.
ULTIMO="$(siembra_ensayos 7)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
ES_FIERRO=1
RETIRADOS="$(barre_ensayos_viejos)"
ES_FIERRO=0
roja 17z "0|7" "${RETIRADOS}|$(cuenta_ensayos)" "en una corrida de FIERRO el barrido devuelve en su primera linea y no retira nada: una corrida que cuesta horas de VM no esta ahi para hacer limpieza"

rm -rf -- "${BANCO}/techo"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"; ES_FIERRO="${GUARDA_FIERRO}"

# ---- 17aa to 17ad: THE MARKER TAKES PRECEDENCE OVER THE CAP ------------------
#
# THESE FOUR ROWS EXIST BECAUSE OF AN INCIDENT THAT HAD ALREADY HAPPENED THREE TIMES, and the
# third one was written by this same house: the rehearsal cap deleted artifacts by
# age without looking at the RUNNING marker, so a LIVE rehearsal that ran
# outside the bench lost its directory halfway. That is what `make clean` did on
# 2026-08-28 and on 2026-09-07, with the lesson already written in the
# Makefile two files away. It was measured before fixing it: with an
# old artifact that carried a LIVE pid inside and six newer ones ahead of it, the
# cap took it away.
#
# THE LIVE PID IS A REAL PROCESS AND NOT AN INVENTED NUMBER. A pid typed
# by hand may be free today and busy tomorrow, so the row measures something else
# without saying so. Here a `sleep` is started, ITS pid is used, and it is killed at the end.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"; GUARDA_FIERRO="${ES_FIERRO}"
OUT_DIR="${BANCO}/marcador"
ES_FIERRO=0
rm -rf -- "${OUT_DIR}"; mkdir -p "${OUT_DIR}"

sleep 300 &
PID_VIVO=$!

# Four old artifacts, one per answer of marcador_de, and six new ones
# ahead to push all four past the cap.
siembra_marcado() {   # <name> <RUNNING contents, or empty to leave it out>
	mkdir -p "${OUT_DIR}/$1"
	printf 'manifiesto\n' > "${OUT_DIR}/$1/manifest.txt"
	[ -n "${2:-}" ] && printf 'pid: %s\nrun: %s\nscript: gate/p2.sh\n' "$2" "$1" > "${OUT_DIR}/$1/RUNNING"
	touch -t 202601010000 "${OUT_DIR}/$1"
}
siembra_marcado p2-local-20260101T000000Z-111 "${PID_VIVO}"
siembra_marcado p2-local-20260101T000000Z-222 999999
siembra_marcado p2-local-20260101T000000Z-333 "no-es-un-numero"
siembra_marcado p2-local-20260101T000000Z-444 ""
for i in 3 4 5 6 7 8; do
	mkdir -p "${OUT_DIR}/p2-local-2026020${i}T000000Z-${i}00"
	printf 'x\n' > "${OUT_DIR}/p2-local-2026020${i}T000000Z-${i}00/manifest.txt"
	touch -t "20260${i}010000" "${OUT_DIR}/p2-local-2026020${i}T000000Z-${i}00"
done
OUT_LOCAL="${OUT_DIR}/p2-local-20260208T000000Z-800"
SALIDA_MARCADOR="$(barre_ensayos_viejos 2>&1 >/dev/null)"

roja 17aa "si|1" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-111" ] && echo si || echo no)|$(printf '%s' "${SALIDA_MARCADOR}" | grep -c 'its run is still alive')" "un artefacto con un pid VIVO dentro sobrevive al techo y lo dice: el techo es una regla sobre lo que ya termino, y sin esta linea el barrido repetia por TERCERA vez el incidente que make clean tuvo dos veces"
fila 17ab "no|1" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-222" ] && echo si || echo no)|$(printf '%s' "${SALIDA_MARCADOR}" | grep -c 'an unfinished run')" "y el de un pid MUERTO si se retira, diciendolo: si un marcador huerfano protegiera, una corrida matada con -9 bloquearia el techo para siempre, que es como una defensa se acaba quitando por estorbar"
roja 17ac "si|1" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-333" ] && echo si || echo no)|$(printf '%s' "${SALIDA_MARCADOR}" | grep -c 'cannot be read')" "un pid que no se puede LEER no es lo mismo que un pid muerto: son TRES respuestas y no dos, y la de en medio se conserva y se dice"
fila 17ad "no" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-444" ] && echo si || echo no)" "y sin marcador ninguno el techo se lo lleva como siempre, que es el control sin el cual las tres de arriba pasarian con un techo que no borrase nunca"

kill "${PID_VIVO}" 2>/dev/null || true
wait "${PID_VIVO}" 2>/dev/null || true
rm -rf -- "${OUT_DIR}"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"; ES_FIERRO="${GUARDA_FIERRO}"

# ---- 17ba to 17bh: THE FIVE IRON BLOCKERS ------------------------------------
#
# AN EXTERNAL READER BROUGHT THEM IN, and the reader was handed the whole design of
# section 10 with a single condition, that the reader could not run anything, and the reader's last
# line was "it would not turn on". The five were re-derived against the script
# before being touched, and the rows here are what stops them from coming back: each one
# fires on both sides, today's form and the one it had.
#
# WHY THEY LIVE HERE. They are predicates of the IRON path, which is what this
# bench exists to test without turning anything on. None of the five can be
# measured in gate/p2-guard-test.sh, which runs the rehearsal.

# ---- B1: the iron artifact does not declare itself a rehearsal ---------------
#
# The banner had NOT ONE branch on ES_FIERRO, measured: zero occurrences inside
# the function. A run over three real machines printed "This is NOT gate
# evidence and it seals nothing", "Three directories on 127.0.0.1 play three
# replicas... there is no fleet" and "Its cut is kill -9", and closed with "all
# rehearsal checks passed". The log IS the artifact and it is not fixed afterwards.
# THE ROW THAT REALLY MEASURES THE DISPATCH, and it was missing: the three below
# call banner_fierro and banner_ensayo DIRECTLY, so they check what each text
# says and not that `banner` picks the right one. The sweep measured it: with
# `banner` losing its iron branch, the three stayed green, because `banner_fierro`
# kept existing and saying its piece, only nobody called it any more. It is class
# 15, inside a row: testing the piece and not the circuit.
GUARDA_FIERRO_B="${ES_FIERRO}"
ES_FIERRO=1; BANNER_DESPACHADO_FIERRO="$(banner 2>/dev/null)"
ES_FIERRO=0; BANNER_DESPACHADO_ENSAYO="$(banner 2>/dev/null)"
ES_FIERRO="${GUARDA_FIERRO_B}"
fila 17b0 "si|no" "$(printf '%s' "${BANNER_DESPACHADO_FIERRO}" | grep -q 'THIS IS GATE EVIDENCE' && echo si || echo no)|$(printf '%s' "${BANNER_DESPACHADO_FIERRO}" | grep -q 'NOT gate evidence' && echo si || echo no)" "con ES_FIERRO=1, banner DESPACHA al de fierro: es el circuito y no la pieza, y sin esta fila quitarle la rama a banner dejaba el banco entero en verde"
roja 17b1 "si|no" "$(printf '%s' "${BANNER_DESPACHADO_ENSAYO}" | grep -q 'NOT gate evidence' && echo si || echo no)|$(printf '%s' "${BANNER_DESPACHADO_ENSAYO}" | grep -q 'THIS IS GATE EVIDENCE' && echo si || echo no)" "y con ES_FIERRO=0 despacha al del ensayo, que es la otra mitad sin la cual un banner que dijera siempre fierro tambien pasaria"

BANNER_FIERRO="$(banner_fierro 2>/dev/null)"
BANNER_ENSAYO="$(banner_ensayo 2>/dev/null)"
fila 17ba "0|0|0|1" "$(printf '%s' "${BANNER_FIERRO}" | grep -c 'NOT gate evidence')|$(printf '%s' "${BANNER_FIERRO}" | grep -c '127\.0\.0\.1')|$(printf '%s' "${BANNER_FIERRO}" | grep -c 'kill -9')|$(printf '%s' "${BANNER_FIERRO}" | grep -c 'THIS IS GATE EVIDENCE')" "el banner de FIERRO no dice que no es evidencia, ni habla de tres directorios en loopback, ni de un corte con kill -9, y si dice lo que es"
roja 17bb "1|1|1|0" "$(printf '%s' "${BANNER_ENSAYO}" | grep -c 'NOT gate evidence')|$(printf '%s' "${BANNER_ENSAYO}" | grep -c '127\.0\.0\.1')|$(printf '%s' "${BANNER_ENSAYO}" | grep -c 'kill -9')|$(printf '%s' "${BANNER_ENSAYO}" | grep -c 'THIS IS GATE EVIDENCE')" "y el del ENSAYO sigue diciendo exactamente lo que decia, palabra por palabra: la rama nueva no se llevo por delante la declaracion que el ensayo tiene que hacer"
# THE QUESTION IS ONE OF PRESENCE, NOT OF COUNT, and the first version counted. It
# asked for ONE occurrence of sysrq-trigger and the banner names it TWICE, in the
# cut and in the reading of 2026-09-07: the row came out red on an expectation of
# mine, not on the object. Counting occurrences of a phrase inside PROSE is a
# figure that moves whenever a paragraph is rewritten, and then the bench turns
# red while nothing is broken. What this row wants to know is whether the phrase IS THERE.
fila 17bc "si|si" "$(printf '%s' "${BANNER_FIERRO}" | grep -q 'sysrq-trigger' && echo si || echo no)|$(printf '%s' "${BANNER_FIERRO}" | grep -q 'caching: ReadWrite' && echo si || echo no)" "y el de fierro lleva su corte de verdad y la frontera del cache del anfitrion, que es la exclusion que el diseno cuelga de este banner"

# ---- B1, the other half: the closing line ------------------------------------
#
# It is the LAST line of the log, the one that gets cited, and it said "all
# rehearsal checks passed" over the only run that cannot be repeated.
GUARDA_FIERRO="${ES_FIERRO}"; GUARDA_EXPECTED="${EXPECTED}"; GUARDA_VERDICTS="${VERDICTS}"
GUARDA_COMPLETED="${COMPLETED}"; GUARDA_STARTED="${RUN_STARTED}"
EXPECTED="P2.build"; VERDICTS=" P2.build=pass "; COMPLETED=1; RUN_STARTED=1
ES_FIERRO=1; CIERRE_FIERRO="$(emit_final_verdict 2>/dev/null)"
ES_FIERRO=0; CIERRE_ENSAYO="$(emit_final_verdict 2>/dev/null)"
fila 17bd "1|0" "$(printf '%s' "${CIERRE_FIERRO}" | grep -c 'all IRON checks passed')|$(printf '%s' "${CIERRE_FIERRO}" | grep -c 'rehearsal')" "la linea de cierre de una corrida de FIERRO no dice rehearsal"
roja 17be "1" "$(printf '%s' "${CIERRE_ENSAYO}" | grep -c 'all rehearsal checks passed')" "y la del ensayo sale EXACTA como estaba, que es lo que casan los bancos por su literal"
ES_FIERRO="${GUARDA_FIERRO}"; EXPECTED="${GUARDA_EXPECTED}"; VERDICTS="${GUARDA_VERDICTS}"
COMPLETED="${GUARDA_COMPLETED}"; RUN_STARTED="${GUARDA_STARTED}"

# ---- B2: the mutant's client runs on the host and not on this laptop ---------
#
# It ran here, with the darwin binary and bound to a private address of the fleet
# that this machine does not have. It is the same defect section 10.16 declares
# closed for client_op, and to client_op it was indeed applied. Without this, the
# forty attempts all failed and the whole red arm never got to measure.
CUERPO_RED_FIERRO="$(awk '/^phase_red_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
fila 17bf "si|no" "$(printf '%s' "${CUERPO_RED_FIERRO}" | grep -q 'run_on 1 "cd naylamp' && echo si || echo no)|$(printf '%s' "${CUERPO_RED_FIERRO}" | grep -q '"\${BIN}" client -listen' && echo si || echo no)" "el cliente del mutante va por run_on al host 1, como client_op, y ya no se invoca el binario local contra una direccion que esta maquina no tiene"
roja 17bg "si" "$(printf '%s' "${CUERPO_RED_FIERRO}" | grep -q '__RC__=0)' && echo si || echo no)" "y lee su estado por la ULTIMA linea entera y no por una subcadena, que es la misma guarda de client_op: un canal de estado que la carga util puede falsificar no es un canal de estado"

# ---- B5b: the canary syncs its file and its directory, not the machine -------
#
# `sync` is GLOBAL and flushed the host's whole dirty page cache, raft log included,
# so at the instant of the cut everything acked was on the platter, barrier or not.
# It is the most expensive finding: the GREEN path that measured nothing.
CUERPO_TESTIGO="$(awk '/^testigo_siembra\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
roja 17bh "no|si|si" "$(printf '%s' "${CUERPO_TESTIGO}" | grep -qE '&& sync$|; sync$' && echo si || echo no)|$(printf '%s' "${CUERPO_TESTIGO}" | grep -q 'os.fsync(f)' && echo si || echo no)|$(printf '%s' "${CUERPO_TESTIGO}" | grep -q 'os.fsync(h)' && echo si || echo no)" "el testigo ya no hace un sync GLOBAL, y sincroniza el fichero Y su directorio: un sync global dentro de un gate de durabilidad es el instrumento anulando lo que mide"

# ---- 17ca to 17cf: B5a, THE IN-FLIGHT WRITES AT THE INSTANT OF THE CUT -------
#
# THE DECISION BELONGS TO WHOEVER COMMISSIONS IT, and it says why: the property is "ack implies
# durable", and without in-flight writes the ack half is never exercised, because
# the mutant only loses something if the cut falls BETWEEN the ack and the barrier.
# The load closed before the cut, so that window did not exist.
#
# AND THESE ROWS FIRE THE REAL FUNCTION, not its text. `escritor_en_vuelo`
# runs against this bench's fake fleet, with a fake naylampd that can be
# made to answer 0 or non-zero at will. It is as close to the object as one can be
# without turning three machines on.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"; GUARDA_FIERRO="${ES_FIERRO}"
GUARDA_MANIFEST="${MANIFEST}"
OUT_LOCAL="${BANCO}/vuelo"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"; : > "${MANIFEST}"
ES_FIERRO=1
# The bound is lowered so the row costs seconds and not minutes: what is measured is
# the SHAPE of what it writes, and that does not depend on how often it does it.
GUARDA_VUELO_MAX="${EN_VUELO_MAX}"; EN_VUELO_MAX=6

# THE FAKE naylampd, which is what lets both sides be fired: it answers 0
# while the signal file exists, and non-zero as soon as it is removed. It is
# the cut, seen from the client: the connection stops giving acks.
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
[ -e "${BANCO_ESTADO}/1.acepta" ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"
: > "${BANCO}/estado/1.acepta"

escritor_en_vuelo
fila 17ca "6|0" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "con la conexion viva, cada ack deja UNA linea confirmed en el manifiesto y ninguna uncertain: su ausencia del log sera un veredicto, que es exactamente la propiedad"
fila 17cb "6|0" "$(grep -c '^ack ' "${OUT_LOCAL}/en-vuelo.txt")|$(grep -c '^sin-ack ' "${OUT_LOCAL}/en-vuelo.txt")" "y cada uno queda fechado en el crudo de la frontera, que es lo que dice en que INSTANTE se cerro el manifiesto"
fila 17cc "1|1" "$(grep -c 'last ack:' "${OUT_LOCAL}/en-vuelo-frontera.txt")|$(grep -c '^acks:' "${OUT_LOCAL}/en-vuelo-frontera.txt")" "y la frontera se escribe en el ARTEFACTO y no solo en la consola, porque es lo que se cita cuando la consola ya no esta"

# THE CUT, seen from the client: the connection stops giving acks halfway.
: > "${MANIFEST}"; rm -f -- "${OUT_LOCAL}/en-vuelo.txt"
EN_VUELO_MAX=6
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
n=$(cat "${BANCO_ESTADO}/1.cuenta" 2>/dev/null || echo 0)
n=$((n + 1)); echo "${n}" > "${BANCO_ESTADO}/1.cuenta"
[ "${n}" -le 2 ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"
rm -f -- "${BANCO}/estado/1.cuenta"
escritor_en_vuelo
roja 17cd "2|3" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "cuando la conexion muere a mitad, lo ackeado queda confirmed y lo que se envio sin respuesta queda UNCERTAIN: sin esa linea, un id comprometido cuyo ack se perdio saldria FANTASMA y pondria roja la fidelidad por hacer justo lo que se le pidio"
roja 17ce "3" "$(grep -c '^sin-ack ' "${OUT_LOCAL}/en-vuelo.txt")" "y el bucle se PARA a los tres fallos seguidos en vez de seguir contra tres maquinas que ya no contestan, que es la cota que la clausula 24 obliga"
roja 17cf "0" "$(sort "${MANIFEST}" | awk '{print $2}' | uniq -d | grep -c .)" "y NINGUN id recibe las dos lineas: el comprobador marca AMBIGUO todo id que toque una operacion sin respuesta, asi que escribir las dos habria costado la comparacion de valor de los que SI volvieron con su ack"

EN_VUELO_MAX="${GUARDA_VUELO_MAX}"
printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/1/naylamp/bin/naylampd"
rm -f -- "${BANCO}/estado/1.acepta" "${BANCO}/estado/1.cuenta"
rm -rf -- "${BANCO}/vuelo"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"; ES_FIERRO="${GUARDA_FIERRO}"; MANIFEST="${GUARDA_MANIFEST}"

# ---- 17da to 17dd: B3 and B4, what the HOT half of the preflight has to do
#
# THESE FOUR ARE READ FROM THE TEXT OF THE FUNCTION AND ARE NOT FIRED, and that is
# said out loud and not disguised. `caliente()` of gate/p2-preflight.sh REQUIRES
# three machines turned on: there is no way to run it here without turning them on, which
# is just what this bench exists not to do. What can be done is to require that the
# steps ARE there, and the sweep's mutants remove them one by one to check that
# these rows fall. It is weaker than firing the function and stronger than looking
# at nothing, and which of the two it is is written here, not left to be assumed.
#
# WHAT THEIR ABSENCE COST, measured against the script: `P2.pre.identity`
# on iron compares the fingerprint of the hosts' binary BYTE BY BYTE with the one
# the run has just cross-compiled, so without a fresh deployment it never matches;
# the TLS material lasts 24 h, so the hosts' is expired and the fleet picks no
# leader; and a single old entry in naylamp/data comes out a GHOST in the THREE cold
# copies and turns P2.recover.faithful red looking like a PROPERTY red, which
# is the red that is never re-run.
CUERPO_CALIENTE="$(awk '/^caliente\(\) \{/,/^\}$/' "${GATE_DIR}/p2-preflight.sh")"
fila 17da "si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q '"${GATE_DIR}/deploy.sh"' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q '"${GATE_DIR}/cluster.sh" start' && echo si || echo no)" "la mitad caliente DESPLIEGA el binario y los certificados y LEVANTA la flota, que es lo que la cabecera de gate/p2.sh llevaba afirmando que hacia sin hacerlo"
roja 17db "si|si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'LITERAL_LIDER=' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'quien=' && echo si || echo no)|$(LIT="$(printf '%s' "${CUERPO_CALIENTE}" | sed -n "s/.*LITERAL_LIDER='\\([^']*\\)'.*/\\1/p" | head -1)"; [ -n "${LIT}" ] && grep -rqF "${LIT}" "${GATE_DIR}/../engine" && echo si || echo no)" "y no se conforma con que los demonios arranquen: exige que ELIJAN LIDER, y la tercera columna CASTEA EL LITERAL CONTRA engine/ en vez de contra el texto del propio gate. Hasta la cuarta vuelta esperaba 'became leader', que no existe en el motor: el demonio escribe role=leader, el case no casaba nunca, y el paso cerraba con mal nombrando material TLS caducado sobre una flota sana. Preguntar si la frase esta en el gate solo comprueba que el gate se cita a si mismo"
fila 17dc "si|si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'rm -rf data logs data-mutante' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'EMPTY on the three, checked' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'naylamp/data-mutante -mindepth 1' && echo si || echo no)" "naylamp/data, naylamp/logs y naylamp/data-mutante se miden, se limpian y se vuelven a MEDIR: es una precondicion y no una tolerancia, y el del mutante estaba fuera hasta que un lector lo trajo, con el mismo razonamiento entero encima: un id 7 viejo ahi dentro hace que el brazo rojo publique que el mutante sin barrera no perdio nada"
roja 17dd "si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'sudo -n test -w /proc/sysrq-trigger' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'os.fsync(os.open' && echo si || echo no)" "y se ejercitan ANTES del corte las dos cosas de las que el corte depende y que corta_en no puede ver, porque tira su estado a proposito: que sudo no pida contrasena, y que python3 pueda hacer fsync de un directorio"

# ---- 17ea to 17ef: WHAT THE EXTERNAL READER'S SECOND PASS FOUND ---------------
#
# ROWS 17ca TO 17cf LET THREE DEFECTS THROUGH, and the reader
# said why with a phrase this very file had just written about the
# banner: **they tested the piece and not the circuit**. They counted `confirmed`
# and `uncertain` lines in the manifest and stopped there. None of them put that
# manifest into the python that builds `live-ids.txt`, which is one of the TWO
# consumers of the manifest and the only one this script controls. Had they done
# so, 17cd, which expects two confirmed and three uncertain, would have exposed
# at once that the three `uncertain` entered the live set and turned the run red.
LIVEIDS="${BANCO}/live-ids.py"
awk '/^\t\/usr\/bin\/python3 - "\$\{MANIFEST\}" > "\$\{OUT_LOCAL\}\/live-ids.txt" <<.PY.$/{f=1;next} f&&/^PY$/{exit} f{print}' "${GATE_DIR}/p2.sh" > "${LIVEIDS}"
fila 17ea "si" "$([ -s "${LIVEIDS}" ] && echo si || echo no)" "el constructor del conjunto vivo se extrae de gate/p2.sh y no se copia aqui: si cambia de forma, esta extraccion sale vacia y el banco lo dice en vez de probar aire"

MAN_PRUEBA="${BANCO}/manifiesto-de-prueba.txt"
printf 'put 1 1,0,0,0,0,0,0,0 confirmed\nput 100 0,0,1,0,0,1,1,0 uncertain\nput 2 0,1,0,0,0,0,0,0\ndel 1\n' > "${MAN_PRUEBA}"
VIVOS="$(/usr/bin/python3 "${LIVEIDS}" "${MAN_PRUEBA}" | tr '\n' ' ')"
roja 17eb "2 " "${VIVOS}" "un id UNCERTAIN no entra en el conjunto vivo, uno sin marcador SI, y un del retira el suyo: sin esta linea, cada envio que no volvio con ack se exigia presente, no podia estarlo porque se mando contra tres maquinas ya muertas, y la corrida salia ROJA diciendo que el motor perdio una escritura ackeada"

# THE IN-FLIGHT RANGE, measured against vec_for and not asserted
roja 17ec "0 0" "$(comprueba_rango_en_vuelo)" "ningun vector del rango en vuelo coincide con uno de la carga ni es el vector cero: vec_for solo depende de id mod 256, asi que el rango de antes daba el vector CERO en el 512 y treinta colisiones con la carga, que es el defecto de la seccion 10.9 reabierto"
GUARDA_DESDE="${ID_EN_VUELO_DESDE}"; GUARDA_MAXV="${EN_VUELO_MAX}"
ID_EN_VUELO_DESDE=500; EN_VUELO_MAX=200
roja 17ed "30 1" "$(comprueba_rango_en_vuelo)" "y con el rango de antes la guarda MUERDE, y dice cuanto: treinta choques, uno por cada id de la carga, y un vector cero. Sin esta mitad, la fila de arriba pasaria con una guarda que dijera siempre cero"
ID_EN_VUELO_DESDE="${GUARDA_DESDE}"; EN_VUELO_MAX="${GUARDA_MAXV}"

# WHAT WAS SENT AND NOT ACKED IS FOLDED IN, even if the writer died
GUARDA_OUT2="${OUT_LOCAL}"; GUARDA_MAN2="${MANIFEST}"
OUT_LOCAL="${BANCO}/pliegue"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"
printf 'put 100 %s confirmed\n' "$(vec_for 100)" > "${MANIFEST}"
printf '100 %s\n101 %s\n102 %s\n' "$(vec_for 100)" "$(vec_for 101)" "$(vec_for 102)" > "${OUT_LOCAL}/en-vuelo-enviados.txt"
pliega_en_vuelo_sin_ack
fila 17ee "1|2" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "todo id que se ENVIO y no dejo su linea vuelve como uncertain: la ventana entre que el cliente contesta y que se anota su linea existe, y una muerte ahi dejaba un id comprometido AUSENTE del manifiesto, que es lo unico que verifylog llama fantasma"
pliega_en_vuelo_sin_ack
roja 17ef "1|2" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "y plegar dos veces no duplica nada, que es lo que permite llamarlo desde el escritor Y desde la trampa de salida sin pensar en cual llego antes"
OUT_LOCAL="${GUARDA_OUT2}"; MANIFEST="${GUARDA_MAN2}"
rm -rf -- "${BANCO}/pliegue"

# NO BARE wait behind a cut, in EITHER of the two phases
CUERPO_CUT_FIERRO="$(awk '/^phase_cut_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
CUERPO_RED_FIERRO2="$(awk '/^phase_red_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
roja 17eg "si|si" "$(printf '%s' "${CUERPO_CUT_FIERRO}" | grep -q 'wait ${pids_corte}' && echo si || echo no)|$(printf '%s' "${CUERPO_RED_FIERRO2}" | grep -q 'wait ${pids_corte_rojo}' && echo si || echo no)" "ninguna de las dos fases que cortan espera con un wait DESNUDO: un wait sin argumentos espera a TODO lo de fondo, y con el escritor en vuelo detras habria tomado el instante del corte treinta segundos tarde, contra una cota de cinco, poniendo los veredictos en none sin decir por que"

# THE VERDICT THAT WAS MISSING, and the iron list names it
roja 17eh "si|si" "$(grep -q 'P2.cut.envuelo' "${GATE_DIR}/p2.sh" && echo si || echo no)|$([ "$(grep -c '^[[:space:]]*EXPECTED=.*P2\.pre\.sysrq.*P2\.cut\.envuelo' "${GATE_DIR}/p2.sh")" -ge 1 ] && echo si || echo no)" "existe un veredicto colgado de que HAYA habido al menos un ack en vuelo, y la lista de fierro lo nombra: sin el, un escritor que no ackeara nada dejaba la propiedad igual de sin medir que antes del arreglo, y nada lo decia"

# AND THE UPPER HALF IS WRITTEN WITHOUT A PIPE AND WITHOUT ESCAPES, which is what
# makes it immune to the TWO classes of environment dependence this pass found. The
# first is the one of the escapes, which is the one that brought it down. The second
# was measured on review and had not come out yet: with `set -o pipefail`,
# a pipe that ends in `grep -q` returns 141 when the upstream one writes more than
# fits in the pipe and the downstream one exits on the first match. Measured here:
# a pipe with 200,000 lines and `grep -q` gives rc=141 with the match inside, so it
# would have printed "no" with the fact right in front of it. The row below has an
# output of two lines and does not reach that window, but the form without a pipe
# takes it out of the two classes at once and not only of the one that already bit.
# THE ROW THAT EXISTS BECAUSE OF THE INCIDENT OF 2026-09-14, and it is the
# only one of this bench that does not look at gate/p2.sh but at the scripts that
# ask. The row above, 17eh, came out GREEN on macOS, RED on the CI runner, with the
# SAME commit, and not by the property: its pattern was '^\t\t\t\tEXPECTED='
# and POSIX does not define \t inside an expression, so BSD grep read a tab and GNU
# grep read the letter t. The fact the row asserts was true in both places; what
# changed was the instrument. A red like that reads as a property red and nobody
# re-runs it, which is the expensive part. THE REPAIR WAS TWO CHANGES AND NOT ONE,
# and neither of the two is the form $'\t': the class '[[:space:]]*', which POSIX
# DOES define, and the collapse of the pipe of three greps into a single `grep -c`
# with a comparison, which takes the row out of the rc=141 class as well. The form
# $'\t' is named by gate/entorno.sh as the portable one and NO pattern of this
# tree uses it: measured on 2026-09-14, ZERO occurrences in the whole
# repository. This row keeps the UNDEFINED form from coming back, which is the one
# that bit, and its red half reinstalls the defect in a copy to prove that the
# census knows how to count it. The first version of this comment said that the
# repair was $'\t', which is a form the tree does not contain: it is corrected here
# because this is where it fell.
MUT_ESC="${BANCO}/p2-iron-test-escape.sh"
python3 - "${GATE_DIR}/p2-iron-test.sh" "${MUT_ESC}" <<'MUTESC'
import sys
# The mutant does NOT undo a concrete form -that would tie the arm to how this file
# is written today-: it INJECTS a line with the forbidden form. Thus the red half
# measures what it says it measures, that the census counts an undefined escape, and
# it still holds on the day no line of the bench uses the portable form any more.
s = open(sys.argv[1], encoding="utf-8").read()
s += "\ngrep '^\\tEXPECTED=' \"${GATE_DIR}/p2.sh\"  # linea inyectada por el brazo rojo de 17ei\n"
open(sys.argv[2], "w", encoding="utf-8").write(s)
MUTESC
# THE SECOND ARM, of 2026-09-15, and it is for the OTHER class the same
# census watches: a metacharacter in a position POSIX does not define, which is the
# family of the escape above and not something else. It is injected, as the first
# one, instead of undoing a concrete form, and it goes on a new file because what
# is measured here is the census and not the bench that houses it.
MUT_ANCLA="${BANCO}/p2-iron-test-ancla.sh"
python3 - "${MUT_ANCLA}" <<'MUTANCLA'
import sys
# THE MUTANT'S grep IS BUILT FROM PIECES, and that is said because it reads oddly and
# the reason is not aesthetic: the census reads THIS file too, and with the whole grep
# on one line it counted itself. Measured: entorno.sh refused to load, an `exit 2`
# at the door of the benches that load this file, and they all died before printing a
# row; the clock of that death, with its three axes, is in ../corridas/naylamp-cifras-20260915T1659Z.txt. What this text WRITES
# is counted by the census, and the row asks for it by name: that is why the word and the pattern
# live in different pieces of this line.
#
# AND THE FORMS ARE FOUR AND NOT ONE, because the first version of the invocation
# pattern took only short flags with no argument and could not read them. THE FIGURES
# OF THAT WIDENING ARE NOT RECITED HERE, for the reason the paragraph above gives; the
# order, with its two counting rules, is in the raw named there. The four forms below
# all carry `-E`, so this row exercises the ANCHOR arm through all four; the FORM arm on
# a BASIC pattern is done by the set of probes above, and that is a different arm.
formas = ["-E -A2", "-A 3 -E", "-E -q --", "--extended-regexp"]
cuerpo = "#!/bin/sh\n# linea inyectada por el brazo rojo de 17ei: un $ en medio de una ERE\n"
for f in formas:
    cuerpo += "grep " + f + " 'a$b' /dev/null\n"
open(sys.argv[1], "w", encoding="utf-8").write(cuerpo)
MUTANCLA
# AND THE SET OF PROBES WITH A DECLARED OUTCOME LIVES HERE, and it lives here because of a
# defect MEASURED and not as a precaution: a set of fourteen probes published by an earlier
# raw could not be re-derived, because the drawer that built it was removed and NOT ONE of
# those names was left in the tree -measured: a grep for them over the whole repository
# returns nothing-. A count that cannot be re-derived is a count that gets recited wrong, and
# that one was one step away from being signed. This set is derived from the classes the
# census above declares: ELEVEN probes that have to be counted, ELEVEN boundaries where the rule
# does not apply, and the ONE blind spot the comment names, an unquoted pattern. Each probe
# declares its outcome BEFORE the run, in the table this python prints, and a probe that stops
# landing on its outcome moves the last two fields of the row and turns it red.
#
# WHAT IT COSTS, and the figures are not recited here for the reason given in the paragraph
# above: the two ways of asking were timed -one census call per probe, and ONE call for all 22
# with a recount per file- and BOTH series, with their three axes, are published in ../corridas/naylamp-cifras-20260915T1659Z.txt,
# which is where a clock figure belongs. What is said here is the shape: this block is a small
# fraction of this bench's clock, and the recount is what turns it red if a probe stops
# landing on its outcome.
#
# AND EVERY BOUNDARY WAS PROVEN TO BITE, one mutation per boundary and one probe watched: the
# rule that boundary claims to test was REMOVED from a copy of the census, and a boundary whose
# count does not move is not a boundary but a control. The first run of that harness caught TWO
# of them: marker.sh expected 0 from a rule that could not fire, because its pattern was BASIC
# and had no mid dollar, and expansion.sh only bit when TWO rules were removed at once, which is
# not the boundary it names. Both were rebuilt -the marker one now carries -qE and a mid dollar,
# and the expansion one sits in single quotes- and a twenty-third probe was added for the
# double-quote rule, which had none. The harness, its mutations and its output are in
# ../corridas/naylamp-cifras-20260915T1659Z.txt.
#
# THE PROBE LINES ARE BUILT FROM PIECES, and the reason is the one this file already paid for
# once: the census reads THIS file too, and a whole `grep ... 'pattern'` on one line would be
# counted by the census as an invocation of this bench. The word and the pattern live in
# different pieces of the same line, so what this text WRITES is counted by the census -the files under
# ${PROBES} are read by the last two fields- and what this text SAYS is not.
PROBES="${BANCO}/probes"
python3 - "${PROBES}" > "${PROBES}.tabla" <<'PROBESET'
import os, sys

D = sys.argv[1]
G = "gr" + "ep"

# (class, name, the line the probe carries, the count it has to land on)
PROBES = [
 ("catch", "escape-t.sh", G + " '^\\tx$' /tmp/f", 1),
 ("catch", "escape-d.sh", G + " -E '\\d' /tmp/f", 1),
 ("catch", "dollar-middle.sh", G + " -E 'a$b' /tmp/f", 1),
 ("catch", "caret-middle.sh", G + " -qE 'a^b' /tmp/f", 1),
 ("catch", "sticky-flag.sh", G + " -m1 '^\\tx$' /tmp/f", 1),
 ("catch", "split-flag.sh", G + " -A 3 '^\\tx$' /tmp/f", 1),
 ("catch", "double-dash.sh", G + " -q -- '^\\tx$' /tmp/f", 1),
 ("catch", "long-option.sh", G + " --extended-regexp 'a$b' /tmp/f", 1),
 ("catch", "numeric-flag.sh", G + " -3 '\\w' /tmp/f", 1),
 ("catch", "ere-split-flag.sh", G + " -E -A 3 'a$b' /tmp/f", 1),
 ("catch", "ere-double-dash.sh", G + " -qE -- 'a$b' /tmp/f", 1),
 ("boundary", "bre-literal.sh", G + " 'a$b' /tmp/f", 0),
 ("boundary", "ere-anchor-end.sh", G + " -E 'a$' /tmp/f", 0),
 ("boundary", "ere-paren.sh", G + " -E '(a$|b)' /tmp/f", 0),
 ("boundary", "ere-open-paren.sh", G + " -E '(^| )x' /tmp/f", 0),
 ("boundary", "bracket.sh", G + " -E '[^ ]x' /tmp/f", 0),
 ("boundary", "expansion.sh", G + " -E 'a${p}b' /tmp/f", 0),
 ("boundary", "expansion-double-quote.sh", G + ' -E "a$x-b" /tmp/f', 0),
 ("boundary", "bash-dollar.sh", G + " $" + "'\\t' /tmp/f", 0),
 ("boundary", "long-option-bre.sh", G + " --extended-regexp --basic-regexp 'a$b' /tmp/f", 0),
 ("boundary", "comment.sh", "# " + G + " -E 'a$b' /tmp/f", 0),
 ("boundary", "marker.sh", "n=$(" + G + " -qE 'a$b' /tmp/f)  # SONDA-DE-ENTORNO", 0),
 ("blind", "no-quotes.sh", G + " -E a$b /tmp/f", 0),
]

for clase, nombre, linea, esperado in PROBES:
    os.makedirs(os.path.join(D, clase), exist_ok=True)
    with open(os.path.join(D, clase, nombre), "w") as destino:
        destino.write(linea + "\n")
    print(os.path.join(D, clase, nombre), esperado)
PROBESET
sondas_ok=0
sondas_tot=0
sondas_salida="$(entorno_escapes_sin_definir "${PROBES}"/*/*.sh)"
while read -r sonda esperado; do
	sondas_tot=$((sondas_tot + 1))
	sonda_cuenta="$(printf '%s\n' "${sondas_salida}" | grep -c "^${sonda}:" || true)"
	if [ "${sonda_cuenta}" = "${esperado}" ]; then
		sondas_ok=$((sondas_ok + 1))
	fi
done < "${PROBES}.tabla"
roja 17ei "0|1|4|23|23" "$(entorno_escapes_sin_definir "${GATE_DIR}"/*.sh | wc -l | tr -d ' ')|$(entorno_escapes_sin_definir "${MUT_ESC}" | wc -l | tr -d ' ')|$(entorno_escapes_sin_definir "${MUT_ANCLA}" | wc -l | tr -d ' ')|${sondas_ok}|${sondas_tot}" "ningun patron de grep de gate/ lleva un escape -\t, \s, \d, \w- ni un metacaracter en una posicion que POSIX no defina, que es lo que hizo que la fila de arriba respondiera distinto en dos maquinas con el mismo arbol y lo que hace que un dolar del medio responda a la implementacion y no al arbol; y el censo cuenta las dos clases cuando se le inyectan en una copia, con las CUATRO formas de invocacion del brazo del ancla -bandera con argumento pegada, separada, doble guion y opcion larga-, o sea que sabe contar lo que dice contar; AND, with the two last fields, the set of probes DERIVED FROM THE CLASSES this census declares -eleven that have to be counted, eleven boundaries where the rule does not apply and the one blind spot it names- lands on its declared outcome in all of them, and that count is PRINTED by the row and not recited in this text"

# THE ROW ABOVE, of the same day and of the same shape: a script that
# SOURCES a file git does not track runs here and dies in a clone, and CI clones
# clean. Today's fix gave it its first outing: `gate/entorno.sh` came in sourced in
# SIX benches, so until it was in the index the blast radius of an oversight
# went from one to six. The count that is required is that of the loads of the
# TREE; the ones the script itself writes in its workshop are exempt and their
# exemption is proved by the variable assignment, and not assumed.
MUT_CARGA="${BANCO}/p2-iron-test-carga.sh"
python3 - "${GATE_DIR}/p2-iron-test.sh" "${MUT_CARGA}" <<'MUTCARGA'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
s += '\n. "${GATE_DIR}/no-esta-en-git.sh"  # linea inyectada por el brazo rojo de 17ej\n'
open(sys.argv[2], "w", encoding="utf-8").write(s)
MUTCARGA
roja 17ej "0|1" "$(entorno_cargas_sin_trackear "${GATE_DIR}"/*.sh | wc -l | tr -d ' ')|$(entorno_cargas_sin_trackear "${MUT_CARGA}" | wc -l | tr -d ' ')" "ningun guion de gate/ sourcea un fichero del arbol que git no trackee, que es lo que corre aqui y muere en un clon; y con una carga inyectada a un fichero que no esta en el indice el censo la cuenta, o sea que sabe contarla"

# THE THIRD ONE, and the predicate is DIFFERENTIAL: the same bench, the same pass,
# under /bin/dash and under bash. dash-red alone is PORTABILITY, and it is this row's;
# both red is a BROKEN bench, which is NOT this row and gets named apart; both green
# pass. The fourth case, green under dash and red under bash, is counted in its own
# bucket because the taxonomy of three does not cover it and this is the only place in
# the tree that measures the pair, and that bucket has had its own red arm since this
# line was written: a copy that only knows how to measure under sh and refuses under
# bash, which is a shape this tree can take for real. Before that arm it was a counter
# with a zero expectation and nothing that could turn it red.
#
# The differential exists for a measured reason: order-guard drives Go and it is most of
# a pass under dash, so a regression OF ITS OWN would turn this row red saying "not
# portable", which is the class of the leader literal: naming the wrong cause.
#
# WHAT IT COSTS, and the figures do NOT live here, for the same reason the probe set above
# gives: this file moves them every time it is touched, and the block that wrote that sentence
# moved them. What stays is the FORM, which does not rot: order-guard drives Go and is the
# LARGEST PART of one pass under dash; the whole row costs about as much as one whole bench of
# this family, both passes and its mutants included; and both passes together are most of what
# this row adds to a push. The clock, with its two series and its three axes, comes from
# `time ./gate/p2-iron-test.sh` and from the row's own instruments, and both are published in
# ../corridas/naylamp-signing-readiness-20260916T1629Z.txt.
#
# AND THIS ROW RUNS FOR THE SECOND TIME FOUR BENCHES THAT CI ALREADY RUNS AS ITS OWN
# STEPS, the ones at ci.yml 230, 304, 323 and 353: under dash that pass is DUPLICATED,
# and the pass under bash is new coverage. It is accepted on purpose, because
# the differential needs both halves and a CI step cannot run its bench under bash as
# well without someone writing it here; and it is declared because whoever adds up CI's
# clock has a right to know that part of those seconds were already being spent.
#
# AND THE NESTING WAS MEASURED, NOT ASSUMED, because no place in this tree looks as much
# like the incident the neighbouring bench guards as this row, which puts four benches
# inside its own: during a run of THIS bench there IS a live artifact with its RUNNING
# under gate/out - the hygiene phase creates it named p2-<stamp>-<pid>, which is exactly
# the shape `make clean` refuses to sweep - and this row still comes out green because
# clean-guard-test.sh builds its fake gate/out in a ${TMPDIR} drawer, copies the REAL
# Makefile there and cds into the drawer. Measured with the bench running: the real
# RUNNING seen in the polls this row takes while the bench runs, and the drawer holding
# Makefile and gate/ and no engine/.
# If clean-guard ever ran make clean against the real tree, this row would be the first
# place it would show, and that last sentence is a prediction and not a result.
#
# THE FAMILY IS DERIVED BY LOAD AND NOT BY MENTION, and that is new here. A `grep -l`
# over the NAME of the file pulls in anything that WRITES that string, a comment
# included; today it gives the same four members by luck, and tomorrow it would run a
# non-member ENTIRELY, twice, inside another bench. The predicate is `sources_entorno`:
# a line that is not a comment, whose first token is a LOAD OPERATOR, and which names
# gate/entorno.sh. And its red half is a trio of drawers: one copy that only MENTIONS the
# file in a comment, which must be zero members, and TWO copies that load it, one per
# operator, which must be one each.
#
# BOTH OPERATORS AND NOT ONLY THE POSIX ONE, and the reason is the reason this whole row
# exists: `source` is NOT POSIX, so a bench that loads with it dies under dash AT THAT
# VERY LINE, exactly like the bench that went red in CI and for the same cause. A guard
# written to catch benches that die under dash would be BLIND to a spelling that dies
# under dash, and that is the defect it would carry inside itself. `source` is a token a
# grep can see, and that is why it is in, and nothing more than that.
#
# AND THE OTHER TWO SHAPES STAY OUT, WITH A DIFFERENT REASON, because they are not the
# same kind of thing. A load written BEHIND ANOTHER COMMAND on the same line, and a load
# BY VARIABLE INDIRECTION, need to know where a command begins and what a variable holds:
# that is an analyzer and not a grep, no matter how wide the expression gets. Measured on
# this tree, no bench loads by either shape, and they stay declared as the hole this
# predicate does not cover: a bench loading that way stays outside the family and is not
# run at all.
classify_bank() {
	local rc_dash=0 rc_bash=0
	/bin/dash "$1" >/dev/null 2>&1 || rc_dash=$?
	bash "$1" >/dev/null 2>&1 || rc_bash=$?
	if [ "${rc_dash}" -ne 0 ] && [ "${rc_bash}" -eq 0 ]; then
		echo portable
	elif [ "${rc_dash}" -ne 0 ]; then
		echo broken
	elif [ "${rc_bash}" -ne 0 ]; then
		echo bash-red
	else
		echo ok
	fi
}
# Does this file EXECUTE a load of gate/entorno.sh? A comment decides no verdict, so a
# commented line does not count; and a bench whose shebang asks for bash may use what
# bash has, so it is not this class. The pattern carries no escape POSIX does not
# define: `[.]` is a literal dot and the blanks go by character class.
sources_entorno() {
	grep -qE '^[[:space:]]*(source|[.])[[:space:]].*entorno[.]sh' "$1"
}
# The sh benches under a directory that LOAD the file, one name per line. The directory
# is an argument so that a row can drive the derivation over a controlled drawer and not
# only over gate/.
sh_benches_loading_entorno() {
	local dir="${1:-${GATE_DIR}}" b
	for b in "${dir}"/*.sh; do
		[ -f "${b}" ] || continue
		case "$(sed -n '1p' "${b}")" in *bash*) continue ;; esac
		sources_entorno "${b}" || continue
		basename "${b}"
	done
}
# How many members the family has and how they classify, over the real gate/ directory.
# The COUNT is the field that moves when the derivation changes, which is what puts the
# derivation itself under test and not only the classifier. Any member that is only
# dash-red, broken, or only bash-red gets named in the dash-*.txt files of the workshop,
# so the failure is read by name and not by count.
sh_benches_classified() {
	local b v portable=0 broken=0 bash_red=0 examined=0
	: > "${BANCO}/dash-portable.txt"; : > "${BANCO}/dash-broken.txt"; : > "${BANCO}/dash-bash-red.txt"
	for b in $(sh_benches_loading_entorno); do
		examined=$((examined + 1))
		v="$(classify_bank "${GATE_DIR}/${b}")"
		case "${v}" in
			portable) portable=$((portable + 1)); echo "${b}" >> "${BANCO}/dash-portable.txt" ;;
			broken)   broken=$((broken + 1));     echo "${b}" >> "${BANCO}/dash-broken.txt" ;;
			bash-red) bash_red=$((bash_red + 1)); echo "${b}" >> "${BANCO}/dash-bash-red.txt" ;;
		esac
	done
	echo "${examined}|${portable}|${broken}|${bash_red}"
}
# THE THREE RED ARMS OF THE CLASSIFIER, and they are not the same mutation. The top one
# injects the OLD FORM as the second line and exits 0 on the third: under dash the
# expansion kills it before it gets there, under bash the load fails, the script goes on
# and exits 0, which is portability. The middle one exits 7 on the second line, which is
# red under BOTH interpreters, a broken bench. The bottom one refuses only under bash,
# which is the fourth bucket: a copy of the same bench that demands to run under sh.
MUT_RESOLUTION="${BANCO}/p2-iron-test-resolution.sh"
MUT_BROKEN="${BANCO}/p2-iron-test-broken.sh"
MUT_BASH_RED="${BANCO}/p2-iron-test-bash-red.sh"
python3 - "${GATE_DIR}/clean-guard-test.sh" "${MUT_RESOLUTION}" "${MUT_BROKEN}" "${MUT_BASH_RED}" <<'MUTANTS'
import sys
base = open(sys.argv[1], encoding="utf-8").read().splitlines(True)
portable = list(base)
portable.insert(1, '. "$(dirname "${BASH_SOURCE[0]}")/entorno.sh"  # old form, injected by the red arm of 17ek\n')
portable.insert(2, 'exit 0  # the copy stops here: what the row measures is the classifier\n')
open(sys.argv[2], "w", encoding="utf-8").writelines(portable)
broken = list(base)
broken.insert(1, 'exit 7  # injected by the broken arm of 17ek\n')
open(sys.argv[3], "w", encoding="utf-8").writelines(broken)
bash_red = list(base)
bash_red.insert(1, '[ -z "${BASH_VERSION:-}" ] || exit 9  # refuses to run under bash\n')
bash_red.insert(2, 'exit 0  # the copy stops here: what the row measures is the classifier\n')
open(sys.argv[4], "w", encoding="utf-8").writelines(bash_red)
MUTANTS
# AND THE DRAWERS OF THE DERIVATION, which is the red half of the family predicate: the
# same shape three times, one that only MENTIONS the file in a comment and two that LOAD
# it, one per operator. None is ever executed, because what the row measures here is the
# DERIVATION, and the field that has to move is the count of members. The workshop path
# is literal at the top of this file, so the removal below is checked before it runs.
DRAWER_MENTION="${BANCO}/family-mention"
DRAWER_LOAD="${BANCO}/family-load"
DRAWER_SOURCE="${BANCO}/family-source"
[ -d "${BANCO}" ] || { echo "p2-iron-test: no workshop to build the family drawers in" >&2; exit 1; }
rm -rf -- "${DRAWER_MENTION}" "${DRAWER_LOAD}" "${DRAWER_SOURCE}"
mkdir -p "${DRAWER_MENTION}" "${DRAWER_LOAD}" "${DRAWER_SOURCE}"
printf '#!/bin/sh\n# this bench mentions entorno.sh and does not load it\n' > "${DRAWER_MENTION}/mention-only.sh"
printf '#!/bin/sh\n. "$(dirname "$0")/entorno.sh"\n' > "${DRAWER_LOAD}/dot-only.sh"
printf '#!/bin/sh\nsource "$(dirname "$0")/entorno.sh"\n' > "${DRAWER_SOURCE}/source-only.sh"
roja 17ek "4|0|0|0|portable|broken|bash-red|0|1|1" "$(sh_benches_classified)|$(classify_bank "${MUT_RESOLUTION}")|$(classify_bank "${MUT_BROKEN}")|$(classify_bank "${MUT_BASH_RED}")|$(sh_benches_loading_entorno "${DRAWER_MENTION}" | wc -l | tr -d ' ')|$(sh_benches_loading_entorno "${DRAWER_LOAD}" | wc -l | tr -d ' ')|$(sh_benches_loading_entorno "${DRAWER_SOURCE}" | wc -l | tr -d ' ')" "no bench under gate/ that asks for sh is dash-red alone, nor broken, nor bash-red alone, and any that is gets named in the dash-portable.txt, dash-broken.txt and dash-bash-red.txt files of the workshop; the classifier tells the three causes apart; and the family is derived by LOAD and not by mention, so a copy that only names the file in a comment is not a member and copies that load it are, with EITHER operator: the POSIX dot and the non-POSIX source, which dies under dash at that very line"

# ---- 17fa to 17fd: THE CIRCUIT AND NOT THE PIECE, FOR THE THIRD TIME ----------
#
# The sweep caught me at the same thing again: 17ec calls `comprueba_rango_en_vuelo`
# DIRECTLY, so it proves that the guard knows how to count and not that the writer
# RUNS it; and the in-flight verdict lived inside a phase that needs three
# machines, so forcing it green by brute force did not take down anything. The two ways out
# are the same one: call the circuit.
GUARDA_OUT3="${OUT_LOCAL}"; GUARDA_MAN3="${MANIFEST}"; GUARDA_FIERRO3="${ES_FIERRO}"
GUARDA_DESDE3="${ID_EN_VUELO_DESDE}"; GUARDA_MAX3="${EN_VUELO_MAX}"
OUT_LOCAL="${BANCO}/circuito"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"; : > "${MANIFEST}"
ES_FIERRO=1
: > "${BANCO}/estado/1.acepta"
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
[ -e "${BANCO_ESTADO}/1.acepta" ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"

# 17fa: with a range that collides, the WRITER refuses and does not write a single line
ID_EN_VUELO_DESDE=500; EN_VUELO_MAX=200
SALIDA_17FA="$(escritor_en_vuelo 2>&1)"
roja 17fa "1|0" "$(printf '%s' "${SALIDA_17FA}" | grep -c 'refusing to write in flight')|$(grep -c . "${MANIFEST}")" "con un rango que colisiona, el ESCRITOR se niega antes de mandar nada y el manifiesto queda vacio: la fila de la guarda sola probaba que sabe contar, no que alguien la mire"

# 17fb: and with the good range it writes
ID_EN_VUELO_DESDE="${GUARDA_DESDE3}"; EN_VUELO_MAX=4
: > "${MANIFEST}"
escritor_en_vuelo >/dev/null 2>&1
fila 17fb "4" "$(grep -c ' confirmed$' "${MANIFEST}")" "y con el rango bueno escribe, que es la mitad sin la cual la de arriba pasaria con un escritor que no escribiera nunca"

# 17fc and 17fd: the in-flight verdict, from both sides
CHECK_FAILED=0; VERDICTS=" "
veredicto_en_vuelo
fila 17fc "pass" "$(verdict_of P2.cut.envuelo)" "con acks en vuelo, P2.cut.envuelo pasa"
printf '' > "${OUT_LOCAL}/en-vuelo.txt"
VERDICTS=" "; CHECK_FAILED=0
veredicto_en_vuelo
roja 17fd "none" "$(verdict_of P2.cut.envuelo)" "y sin un solo ack en vuelo NO se pone rojo, se pone en NONE: cero acks no es un fallo del motor, es que la corrida no llego a hacer la pregunta, y eso se dice con none y no con un rojo que nombraria la causa equivocada"

EN_VUELO_MAX="${GUARDA_MAX3}"; ID_EN_VUELO_DESDE="${GUARDA_DESDE3}"
printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/1/naylamp/bin/naylampd"
rm -f -- "${BANCO}/estado/1.acepta"; rm -rf -- "${BANCO}/circuito"
OUT_LOCAL="${GUARDA_OUT3}"; MANIFEST="${GUARDA_MAN3}"; ES_FIERRO="${GUARDA_FIERRO3}"
CHECK_FAILED=0

# ---- 17ga to 17gf: WHAT THE THIRD ROUND OF THE EXTERNAL READER FOUND ----------
#
# AND THE FIRST OF THEM IS THE FIFTH TIME THIS HOUSE COMMITS THE SAME DEFECT IN
# A SINGLE SESSION: `veredicto_en_vuelo` opened a `begin_check` INSIDE the block
# opened by `P2.cut.fired`, and `begin_check` sets `CHECK_FAILED` to zero. It erased
# all its FAILs: that of the node that did not arm its canary, that of the one that NEVER stopped
# answering ssh -that is, it was NOT cut- and that of the missing boundary, which was
# dead code from the day it was born. And what hid it was, once again, that the
# bench row called the function ALONE, where it works. **Calling the piece is
# exactly what hides the fact that the circuit is broken.**
CUERPO_VEREDICTO="$(awk '/^veredicto_en_vuelo\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
CUERPO_CUT2="$(awk '/^phase_cut_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
POS_END="$(printf '%s\n' "${CUERPO_CUT2}" | grep -n 'end_check P2.cut.fired' | tail -1 | cut -d: -f1)"
POS_VER="$(printf '%s\n' "${CUERPO_CUT2}" | grep -n '^	veredicto_en_vuelo$' | tail -1 | cut -d: -f1)"
roja 17ga "si" "$([ -n "${POS_END}" ] && [ -n "${POS_VER}" ] && [ "${POS_VER}" -gt "${POS_END}" ] && echo si || echo no)" "veredicto_en_vuelo se llama DESPUES del ultimo end_check de P2.cut.fired y no dentro de su bloque: begin_check pone CHECK_FAILED a cero, asi que dentro borraba los FAIL de la fase y P2.cut.fired podia registrar PASS con sus propios FAIL impresos encima"

# THE CIRCUIT AND NOT THE PIECE: the whole phase is set up in miniature, with a FAIL
# accumulated before it, and it is demanded that it survive the call.
GUARDA_CF="${CHECK_FAILED}"; GUARDA_V="${VERDICTS}"; GUARDA_OUT4="${OUT_LOCAL}"
OUT_LOCAL="${BANCO}/veredicto"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'ack 100 2026-09-09T00:00:00Z\n' > "${OUT_LOCAL}/en-vuelo.txt"
# THE SEQUENCE OF THE PHASE IS SET UP AND NOT THE STATE ON ITS OWN, and the first version of
# this row looked at `CHECK_FAILED` AFTER the call, which is an impossible
# expectation: `veredicto_en_vuelo` opens its OWN block, so that counter is no longer
# the caller's. What has to be measured is the VERDICT: that P2.cut.fired
# comes out `fail` with the call behind it. It is the same lesson once more, and this time
# committed while writing the row that watches it.
VERDICTS=" "; begin_check
fail "P2.cut.fired: un FAIL de mentira, para ver si sobrevive" >/dev/null 2>&1
end_check P2.cut.fired
veredicto_en_vuelo >/dev/null 2>&1
roja 17gb "fail|pass" "$(verdict_of P2.cut.fired)|$(verdict_of P2.cut.envuelo)" "en la secuencia de la fase, el veredicto de P2.cut.fired queda en FAIL y el de P2.cut.envuelo en pass: son dos bloques y no uno, y con la llamada dentro el primero salia pass con sus propios FAIL impresos encima"
OUT_LOCAL="${GUARDA_OUT4}"; CHECK_FAILED="${GUARDA_CF}"; VERDICTS="${GUARDA_V}"

# B2: the count of entries, measured for real over EMPTY directories
mkdir -p "${BANCO}/vacios/data" "${BANCO}/vacios/logs" "${BANCO}/vacios/data-mutante"
roja 17gc "3|0" "$(cd "${BANCO}/vacios" && ls -A data logs data-mutante 2>/dev/null | grep -c .)|$(cd "${BANCO}/vacios" && find data logs data-mutante -mindepth 1 2>/dev/null | grep -c .)" "sobre TRES directorios VACIOS, ls -A con varios operandos da TRES por sus cabeceras y find -mindepth 1 da CERO: con el primero, la precondicion del preflight fallaba en un host impecable, siempre, con el mensaje mas caro del diseno"
printf 'x\n' > "${BANCO}/vacios/data/algo"
fila 17gd "1" "$(cd "${BANCO}/vacios" && find data logs data-mutante -mindepth 1 2>/dev/null | grep -c .)" "y con una entrada de verdad dentro cuenta UNA, que es la mitad sin la cual la de arriba pasaria con un contador que dijera siempre cero"
rm -rf -- "${BANCO}/vacios"
roja 17ge "si|no" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'find naylamp/data naylamp/logs naylamp/data-mutante -mindepth 1' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'ls -A naylamp/data naylamp/logs' && echo si || echo no)" "y el preflight cuenta con find y ya no con ls -A"

# B3: the leader is asked of all THREE and with a bound
roja 17gf "si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'for h in "${hosts\[@\]}"' && printf '%s' "${CUERPO_CALIENTE}" | grep -q 'and host .* wrote it with' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'NOT elected a leader in 20 s, asking all THREE' && echo si || echo no)" "el lider se pregunta a los TRES y con cota: solo el nodo que GANA escribe esa linea, asi que preguntar solo al host 1 daba un rojo que nombra la causa equivocada dos de cada tres veces, sobre una flota sana y con las tres encendidas"

# ---- 17ha and 17hb: THE TWO SITES THE NEW GUARD UNCOVERED --------------------
#
# `gate/sitio-test.sh` enters today with the predicate of the class that bit FIVE
# times in one day, and its first run found more than the census by hand
# had seen: `seal_artifact`, `completa_el_sello`, `retira_running`,
# `emit_final_verdict` and `pliega_en_vuelo_sin_ack` have their BARE site inside
# `al_salir`, and **no row ran `al_salir`**. It is exactly where the
# mutant that removes the `kill` of the in-flight writer came out SILENT.
#
# THE ROW RUNS THE WHOLE TRAP, in a subshell because `al_salir` ends in
# `exit`, and looks at what it leaves: the sealed artifact, the seal FINISHED with its
# `closed:`, and the marker removed. With that, a
# change in the ORDER of those six calls -which is the only thing the site decides-
# falls here and not in the first iron run.
GUARDA_OUT5="${OUT_LOCAL}"; GUARDA_MAN5="${MANIFEST}"; GUARDA_FIERRO5="${ES_FIERRO}"
GUARDA_RUN5="${RUN_STARTED}"; GUARDA_EMIT5="${EMITIDO}"; GUARDA_V5="${VERDICTS}"
GUARDA_EXP5="${EXPECTED}"; GUARDA_RID5="${RUN_ID}"; GUARDA_OD5="${OUT_DIR}"
OUT_DIR="${BANCO}/trampa"; RUN_ID="20260909T000000Z-1"
OUT_LOCAL="${OUT_DIR}/p2-${RUN_ID}"
rm -rf -- "${OUT_DIR}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"
printf 'put 1 %s confirmed\n' "$(vec_for 1)" > "${MANIFEST}"
printf 'algo que la corrida escribio\n' > "${OUT_LOCAL}/hygiene.log"
ES_FIERRO=1; RUN_STARTED=1; EMITIDO=1; SELLO_ESCRITO_AQUI=0
EXPECTED="P2.build"; VERDICTS=" P2.build=pass "
SUBCOMANDO=all; ARRANCO_A="2026-09-09T00:00:00Z"
escribe_running
# A FAKE IN-FLIGHT WRITER, so that the trap can be required to KILL it. The
# sweep asked for it: taking the kill away from al_salir, this row stayed green because
# it looked at what the trap LEAVES and not at what the trap STOPS. A process that survives
# the trap keeps writing to the manifest behind the seal.
sleep 120 &
PID_EN_VUELO=$!
SALIDA_TRAMPA="$( al_salir 2>&1 )"
VIVE_TRAS_LA_TRAMPA="$(kill -0 "${PID_EN_VUELO}" 2>/dev/null && echo si || echo no)"
kill "${PID_EN_VUELO}" 2>/dev/null || true
fila 17ha "si|1|no|no" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED" 2>/dev/null || echo 0)|$([ -e "${OUT_LOCAL}/RUNNING" ] && echo si || echo no)|${VIVE_TRAS_LA_TRAMPA}" "la trampa de salida, corrida ENTERA: deja el artefacto SELLADO, el sello TERMINADO con su linea closed, y el marcador RETIRADO. Ninguna fila corria al_salir, que es el sitio de cinco funciones que este banco si prueba una a una"
roja 17hb "0" "$(ls -1 "${OUT_LOCAL}" 2>/dev/null | grep -c '^SEALED\.a-medias$')" "y no deja ningun SEALED.a-medias dentro de un artefacto que el sello protege de make clean: el orden de esas seis llamadas es lo unico que el sitio decide, y sin esta fila un cambio en el orden solo se veria en la primera corrida de fierro"
rm -rf -- "${OUT_DIR}"
OUT_DIR="${GUARDA_OD5}"; RUN_ID="${GUARDA_RID5}"; OUT_LOCAL="${GUARDA_OUT5}"
MANIFEST="${GUARDA_MAN5}"; ES_FIERRO="${GUARDA_FIERRO5}"; RUN_STARTED="${GUARDA_RUN5}"
EMITIDO="${GUARDA_EMIT5}"; VERDICTS="${GUARDA_V5}"; EXPECTED="${GUARDA_EXP5}"
SELLO_ESCRITO_AQUI=1; CHECK_FAILED=0

# ---- 17hc: THE DISPATCH BY ES_FIERRO, which is the site of the three iron phases
#
# `phase_hygiene`, `phase_cut` and `phase_red` do nothing but choose a branch by
# `ES_FIERRO`, and that choice is their only content. The rows that run
# `phase_hygiene_fierro` test the phase; this one tests that it is reached.
GUARDA_FIERRO6="${ES_FIERRO}"
ES_FIERRO=1
DESPACHO="$( set +e; phase_hygiene 2>&1 )"
ES_FIERRO="${GUARDA_FIERRO6}"
# IT ASKS FOR A PHRASE THAT ONLY ONE OF THE TWO BRANCHES PRINTS, and by presence
# and not by count: counting appearances inside the output of a phase is a figure
# that moves every time someone adds a line, and then the bench turns
# red while nothing is broken. It is the third time today that I have corrected it in the same direction.
roja 17hc "si|no" "$(printf '%s' "${DESPACHO}" | grep -q 'sane fleet is at' && echo si || echo no)|$(printf '%s' "${DESPACHO}" | grep -q 'is still running' && echo si || echo no)" "con ES_FIERRO=1, phase_hygiene DESPACHA a su rama de fierro y no corre la del ensayo: es el mismo circuito que el del banner, y las tres fases de fierro cuelgan de el"
CHECK_FAILED=0

# ---- 17ia and 17ib: THE CUT PHASE, RUN WHOLE ---------------------------------
#
# THE GUARD `gate/sitio-test.sh` LEFT THESE THREE EXPOSED and they could not be
# declared: `escritor_en_vuelo`, `pliega_en_vuelo_sin_ack` and `veredicto_en_vuelo`
# have their only BARE site inside `phase_cut_fierro`, and that site decides
# what none of their rows can see: in what ORDER they are called, whether the writer
# starts before the cut, whether the `wait` waits only for the cuts, and whether the verdict
# stays outside the block of `P2.cut.fired`. It is where the mutant that removes the wait
# for the first ack came out SILENT.
#
# THE PHASE IS RUN FOR REAL, with the cut SIMULATED over the fake fleet, and
# that costs SECONDS instead of the cost of letting its two waits run out, which is on
# the ORDER OF MINUTES and is the reason for simulating it. The clock with its three axes is in
# ../corridas/naylamp-cifras-20260915T1659Z.txt. A helper in the background does what the cut would do: it marks the
# three hosts dead, changes their boot id, leaves the canary at its seed, and gives them
# back. None of this powers on anything: the three hosts are directories.
GUARDA_OUT7="${OUT_LOCAL}"; GUARDA_MAN7="${MANIFEST}"; GUARDA_FIERRO7="${ES_FIERRO}"
GUARDA_V7="${VERDICTS}"; GUARDA_CF7="${CHECK_FAILED}"; GUARDA_MAXV7="${EN_VUELO_MAX}"
OUT_LOCAL="${BANCO}/fasecorte"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"; : > "${MANIFEST}"
ES_FIERRO=1; VERDICTS=" "; EN_VUELO_MAX=6
: > "${BANCO}/estado/1.acepta"
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
[ -e "${BANCO_ESTADO}/1.acepta" ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"

# AND NODE 2 CANNOT ARM, on purpose and in this same run. The ssh stub
# denies it the ONLY trip that does a `>>` over the canary, that is, the arming, and
# lets the seeding through. The first version of this line put the canary as
# a DIRECTORY and that was no good: it breaks the SEEDING, which goes earlier and has its own
# early exit, so the phase went away without ever reaching the arming and the three
# columns came out as no for the wrong reason. It is one of the two causes that the
# phase's comment names -an ssh cut off or a full disk- and until now
# no row exercised it: `testigo_arma` was tested ALONE, in rows 22 to 25,
# and the SITE where its failure has to be noted per node was not walked by anybody.
# That hole let a defect in on 2026-09-09, in the very fix
# that parallelised the arming: by taking the call out of the condition of an `if` it lost
# the errexit exemption, and with one arm that failed the gate died whole instead of
# noting the node and going on. With this line in place, that version does not reach the end.
: > "${BANCO_ESTADO}/2.no-arma"

# The helper that plays the cut. The numbers are short on purpose: what this
# row measures is the TRAVERSAL of the phase, not how long a VM takes to come back.
(
	sleep 3
	for n in 1 2 3; do : > "${BANCO_ESTADO}/${n}.muerto"; done
	sleep 2
	for n in 1 2 3; do
		printf 'dddd-eeee-ffff-000%s\n' "${n}" > "${BANCO_CASA}/${n}/proc/sys/kernel/random/boot_id"
		head -c 4096 /dev/zero > "${BANCO_CASA}/${n}/naylamp/testigo-corte.bin" 2>/dev/null || true
		rm -f -- "${BANCO_ESTADO}/${n}.muerto"
	done
) &
AYUDANTE=$!
# AND THE CALL GOES IN THROUGH `phase_cut` AND NOT THROUGH `phase_cut_fierro`, which is ONE
# word and covers a whole site. Until the fourth round this line called the
# iron branch DIRECTLY, and then the DISPATCH BY ES_FIERRO that is in
# `phase_cut` was exercised by nobody: gate/sitio-test.sh had it DECLARED as
# covered "by the dispatch row", and that row, 17hc, is the phase_hygiene one.
# An exemption written with a false reason is worse than none, because it switches the
# guard off at the exact site where it was needed. Going in through the dispatch the row
# walks the same ground and also checks which branch it went to, and the declaration is superfluous.
# AND IT IS NOT CAPTURED WITH `$( )`, which is a SUBSHELL and takes the verdicts with it. The
# phase records in `VERDICTS`, which is a variable, and a command substitution runs
# in a child process: when it closes, everything the phase wrote there is lost. It
# was measured on 2026-09-09 by printing `VERDICTS` right behind the
# capture, and what came out was the space it had been initialised with. What that
# meant is worse than a lost verdict: the second half of 17ib
# asked whether P2.cut.envuelo stayed at `pass` or at `none`, and `verdict_of` over
# an empty variable returns `none` ALWAYS, by its default branch. Which means that
# that column came out green whatever happened, in a row whose own comment
# above explains that an assertion that admits both outcomes watches nothing.
# It is redirected to a file and the phase runs in THIS shell, which is how the bench already
# exercises phase_hygiene_fierro and al_salir.
set +e
phase_cut > "${BANCO}/fasecorte.salida" 2>&1
set -e
SALIDA_CORTE="$(cat "${BANCO}/fasecorte.salida")"
wait "${AYUDANTE}" 2>/dev/null || true
# THE ARMING DENIAL IS REMOVED HERE, and forgetting it turned row 25 red for three
# minutes: that row arms node 2 for real to measure its size, and with the
# flag in place it measured 4096 instead of 69632. A setup that is not undone is not
# a setup, it is an environment change for everything that comes after.
rm -f -- "${BANCO_ESTADO}/2.no-arma"
rm -f -- "${BANCO}/estado/1.acepta"
printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/1/naylamp/bin/naylampd"

# THE FOURTH HALF WAS ASKED FOR BY THE MUTANT SWEEP, not by me: taking away from the phase the
# wait for the first ack, this row stayed green, because it looked at the writer
# STARTING and not at the phase WAITING for it. Starting and waiting are two things, and the
# one that decides whether there is a nearly zero-age in-flight population is the second.
#
# AND THE FIRST VERSION OF THIS HALF STILL DID NOT BITE, because it accepted the TWO branches
# with an alternation: the mutant fell into the other one and passed. An assertion that admits
# the two outcomes of the decision it watches watches nothing. In this setup the
# writer DOES ack -six, measured- so the positive branch is demanded and only that one.
fila 17ia "si|si|si|si|no" "$(printf '%s' "${SALIDA_CORTE}" | grep -q 'starting the in-flight writer' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'has at least one acknowledged write' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'cutting the THREE' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'boot id after' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'cutting nodes 1 and 2 with kill -9' && echo si || echo no)" "phase_cut_fierro se recorre ENTERA contra la flota de mentira, ENTRANDO POR EL DESPACHO: arranca el escritor en vuelo, corta, y llega a leer los boot id de vuelta. Es el SITIO de tres funciones que este banco prueba una a una y que nadie ejercia, y la quinta columna exige que con ES_FIERRO=1 no se haya colado la rama del ensayo, que corta dos nodos con kill -9 en vez de tres con sysrq"
# AND IT DOES NOT CARRY A `case` INSIDE THE SUBSTITUTION, which is clause 31 and the
# second version of this line committed it: a `case` inside `$( )` is a syntax
# error in the bash 3.2 of this machine, because the parser takes the `)` of the
# pattern for the closing of the substitution. And it does not die: the error goes to stderr, the
# substitution returns the loose text from behind the parenthesis, and the row came out
# red showing half an `esac` as if it were a verdict.
#
# 17ib ASKS TWO THINGS THAT CAN GO WRONG, and the first version asked
# one that could not: it compared the verdict against "different from none OR equal to
# none", which is always true. A row that cannot fail is not a row.
roja 17ib "si|pass" "$(printf '%s' "${SALIDA_CORTE}" | grep -q 'in flight:' && echo si || echo no)|$(verdict_of P2.cut.envuelo)" "y en el mismo recorrido lee la frontera del escritor y REGISTRA el veredicto en vuelo: el ORDEN de esas seis llamadas es lo unico que el sitio decide, y sin esta fila un cambio en el orden solo se veria en la primera corrida de fierro. La segunda columna exige PASS y no una alternancia: en este montaje el escritor ackea cuatro veces medidas, asi que none seria un defecto y no una rama legitima"

# ---- 17ic: THE BUDGET OF THE WINDOW, measured by the STRUCTURE ----------------
#
# THE FOURTH PASS OF THE READER FOUND THAT THE WINDOW DID NOT FIT IN ITS BOUND, and the
# defect was not put there by whoever wrote the phase: it was put there by the
# CORRECTIONS of the third pass. The window runs from arming the canary to firing the
# cut and its bound is VENTANA_MAX, five seconds, derived from commit=30. Inside that
# window the third pass put two new costs without touching the bound: the directory fsync
# in the seeding, and up to three seconds waiting for the first ack of the in-flight
# writer. With the three arms IN SERIES against Azure, the budget went over five before
# the cut fired. And it does not fail loudly: `ventana_dentro` gives false and
# P2.cut.bytes comes out NOT RUN, that is, the central reading of the phase -whether
# the cut was dry- is voided on its own over a healthy fleet.
#
# THIS ROW MEASURES STRUCTURE AND NOT PROSE, which is what this week's class
# requires: the LINE NUMBER of the two things is taken inside the body of the
# function and the order is required. A row that asked whether the comment says
# "in parallel" would stay green the day someone put the arms back in series
# and left the paragraph in place. The three columns fall if the correction is undone:
# putting the writer back behind the loop takes the first one down, taking the `&` out of
# the arms takes the second down, and taking the `wait` out takes down the third, which is the
# one that stops the fast and false version: arming in the background without gathering them
# would cut before the seeds were in place.
# AND THE BODY IS READ WITHOUT COMMENTS, which is not tidiness: the first version of
# 17ic came out GREEN for its own prose. The comment that explains the fix
# QUOTES the broken form, `( testigo_arma "$n"; echo $? > ... ) &`, and the grep of the
# second column matched that quote instead of the code. That is, the row written
# to watch the arming would have stayed green the day someone put the arming
# back in the broken form, since the paragraph that describes it would still be there. It
# is the same class this bench has spent a whole day chasing, committed INSIDE
# the row that chases it, and what caught it was the census of mutants: 17ic did not appear
# in the list of rows that some mutant knocks down.
CUERPO_CORTE_F="$(awk '/^phase_cut_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh" | grep -v '^[[:space:]]*#')"
roja 17ic "si|si|si" "$(L_ESC="$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -n 'escritor_en_vuelo &' | head -1 | cut -d: -f1)"; L_ARM="$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -n 'testigo_arma "\$n"' | head -1 | cut -d: -f1)"; [ -n "${L_ESC}" ] && [ -n "${L_ARM}" ] && [ "${L_ESC}" -lt "${L_ARM}" ] && echo si || echo no)|$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -qE '^[[:space:]]*\( if testigo_arma "\$n";.*\) &$' && echo si || echo no)|$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -q 'wait \${pids_arma}' && echo si || echo no)" "el escritor en vuelo arranca ANTES del bucle de armado, las tres armas van al fondo CON su llamada dentro de un if, que es su exencion de errexit, y se las junta con wait antes de cortar: asi la espera del primer ack se solapa con las armas en vez de sumarse detras, y dentro de la ventana queda UN viaje ssh de armar mas el abanico del corte, que ya iba en paralelo"

# ---- 17id: AN ARM THAT FAILS DOES NOT TAKE THE RUN DOWN ----------------------
#
# THIS ROW READS THE SAME CAPTURE AS 17ia and does not cost one second more: node 2
# is denied its arming by the stub higher up, so in that same traversal
# of `phase_cut` there is ONE arm that fails and TWO that arm. The three columns are the
# whole circuit of the degraded case: the node is noted by its number, the phase
# STAYS ALIVE until it fires the cut, and the verdict of the cut is left recorded.
#
# THE SECOND COLUMN IS THE ONE THAT COUNTS AND IT DID NOT EXIST BEFORE. Under `set -e`, a
# call that fails outside a condition kills the subshell that holds it, and if
# that subshell is in the background, the `wait` that collects it returns non-zero and
# takes the gate down. The version of this fix written half an hour earlier did
# exactly that: the iron run died in the arming, with no `fail`, no cut
# and no verdict, that is, the whole session was lost and the artifact did not say
# why. Asking only about the `fail` of node 2 would not have caught it, because in
# that version the `fail` was not written either: what catches it is requiring the phase
# to REACH a later line. It is the difference between looking at the piece and looking at
# whether the current comes out the other side.
roja 17id "si|si|fail" "$(printf '%s' "${SALIDA_CORTE}" | grep -q 'node 2 would not arm its canary' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'cutting the THREE' && echo si || echo no)|$(verdict_of P2.cut.fired)" "con el stub negandole al nodo 2 el unico viaje que hace un >> sobre el testigo, su arma falla de verdad y la siembra pasa: se anota P2.cut.fired contra ESE nodo, la fase sobrevive y dispara el corte, y el veredicto sale FAIL y no none. Sin la exencion de errexit dentro de la subcapa del armado paralelo las tres columnas caen a la vez, porque el gate muere antes de escribir ninguna"

# ---- 17ie: THE PARALLEL ARMING, UNDER REAL errexit ----------------------------
#
# 17id COULD NOT CATCH THIS AND IT WAS MEASURED, not assumed. The fix was undone by hand
# -the `if` was taken out of the subshell- and 17id stayed GREEN. The reason is that the
# capture of the phase runs between `set +e` and `set -e`, so a non-zero return from the
# phase does not take the bench down; with errexit off, the subshell that had to die does
# not die and the defect does not show. A bench that switches off the guard it wants to
# measure measures something else.
#
# SO THE PIECE IS EXTRACTED FROM THE SCRIPT AND RUN IN A CHILD WITH A REAL
# `set -euo pipefail`, with a `testigo_arma` that always fails. The piece is EXTRACTED and
# not copied: it runs from the line that declares `pids_arma` to the `wait` that collects
# it, inside the body of phase_cut_fierro, so the day someone rewrites it this row runs the
# rewritten one. With the `if` in place the child reaches its last line; without it, errexit
# kills the subshell before the `echo`, `wait` returns non-zero and the child dies printing
# nothing, which is exactly what would happen to the iron run in the third minute of a
# session of VMs.
# AN EXTRACTION IS CHECKED BEFORE ANYTHING IS MEASURED WITH IT, which is the form row 17ea
# already uses over its live-ids file, and the reason is that a piece taken out of the phase
# is what both rows below measure with. An `awk` over a RANGE is the fragile half: with the
# OPENING anchor moved the piece comes out EMPTY, and with the CLOSING one moved it comes out
# LONG -it runs to the end of the function- while still carrying the pattern. Both were
# measured on copies with the anchor broken, and so was a rewritten reader line. A row that
# measures with a piece like that does not go quiet: it reddens NAMING THE WRONG CAUSE,
# because the child finds no loop, reads nothing and reports zero, or it dies without
# printing the line the row greps for. The piece has to hold content and not merely exist -a
# piece written with printf '%s\n' is one byte and passes a size test- carry the line the row
# matches on, and END on the anchor that closes the range.
#
# AND THE PIECE IS READ FROM A FILE AND NEVER FROM A PIPE, which is the form row 17eh chose
# two hundred lines above and for the same measured reason: under pipefail a pipeline that
# ends in `grep -q` returns 141 as soon as the writer upstream exceeds what the pipe holds, so
# the predicate answers FALSE on a piece larger than the pipe even when the match is inside
# it, and the row would then redden saying the extraction broke when what broke was the guard.
# Measured on this machine: the pipe takes 65536 bytes, and a piece of 2000013 characters
# carrying the match in its FIRST line returns 141 through a pipe and 0 through a file. This
# bench runs under pipefail, so the pipe form is the one that would have failed.
piece_ok() {	# piece_ok <file> <pattern>
	grep -q '[^[:space:]]' "$1" && grep -q "$2" "$1"
}
range_ok() {	# range_ok <file> <pattern> <closing line>
	piece_ok "$1" "$2" || return 1
	[ "$(tail -n1 "$1" | sed 's/^[[:space:]]*//')" = "$3" ]
}
ARM_PIECE="$(printf '%s\n' "${CUERPO_CORTE_F}" | awk '/pids_arma=""/,/wait \$\{pids_arma\}/')"
mkdir -p "${BANCO}/errexit-arm"
printf '%s\n' "${ARM_PIECE}" > "${BANCO}/errexit-arm.piece"
{
	printf '%s\n' 'set -euo pipefail' 'NODE_IDS=(1 2 3)'
	printf 'OUT_LOCAL=%s\n' "'${BANCO}/errexit-arm'"
	printf '%s\n' 'testigo_arma() { return 1; }' 'fail() { :; }' 'arm_the_three() {'
	printf '%s\n' "${ARM_PIECE}"
	printf '%s\n' '}' 'arm_the_three' 'echo SURVIVED'
} > "${BANCO}/errexit-arm.sh"
roja 17ie "1|3|si" "$(bash "${BANCO}/errexit-arm.sh" 2>/dev/null | grep -c SURVIVED)|$(ls -1 "${BANCO}/errexit-arm" 2>/dev/null | grep -c '^arma-rc-')|$(range_ok "${BANCO}/errexit-arm.piece" 'testigo_arma' 'wait ${pids_arma}' && echo si || echo no)" "the piece of the parallel arming, EXTRACTED from the script and run in a child with set -euo pipefail and a testigo_arma that always fails: it reaches its last line and leaves the THREE rc files written. Without the if inside the subshell, errexit kills it before the echo, wait returns non-zero, and the child prints nothing and writes no rc. The third column is the EXTRACTION GUARD: if the piece comes out empty, or comes out long because the closing anchor moved, or does not carry the call this row matches on, it falls here instead of falling in the first two naming a cause that is not its own"

# ---- 17if: THE ARMING STATUS CHANNEL, WHICH THE PAYLOAD MUST NOT BE ABLE TO DIRTY ----
#
# THE DEFECT THIS ROW WAS WRITTEN FOR IS IN THE PHASE AND NOT IN THE BENCH, and it is
# the class this file has closed twice already, in 17bg and in client_op: a status
# channel that the payload can falsify is not a status channel. In phase_cut_fierro the
# arming writes its status with
#
#   ( if testigo_arma "$n"; then echo 0; else echo 1; fi > "${OUT_LOCAL}/arma-rc-${n}" ) &
#
# where the redirect sits AFTER the `fi`, so by the grammar of bash it covers the WHOLE
# compound and the condition is part of that compound: whatever testigo_arma prints on
# its stdout lands inside the status file. The reader then compares the WHOLE FILE
# against 0, so one line of noise in front of the digit reads as "not armed". The cost
# is the expensive one: the three nodes are noted as unable to arm their canary,
# P2.cut.fired reddens over a healthy fleet and P2.cut.bytes goes NOT RUN, which
# switches off the central reading of the phase in the one run that is never repeated.
#
# TODAY THE PAYLOAD IS SILENT AND THAT WAS MEASURED, NOT ASSUMED: ask_on in
# gate/common.sh captures run_on inside a command substitution and prints nothing, so
# the status file holds the digit and nothing else. The defect is LATENT, and a latent
# defect is what this row exists to make loud: the payload here ARMS WELL and prints one
# line, which is exactly what any future payload that logs its work would do.
#
# THE ROW EXTRACTS BOTH HALVES FROM THE PHASE, the writer and the reader, so the day
# either one is rewritten this row runs what was rewritten. The first column is the
# phase's own reading of its three status files. The second is the channel itself: with
# the redirect on the echo alone each file holds one line, and with the redirect on the
# compound each holds the payload's line plus the digit. Each half is ALSO written to its
# own file, because the guards read files and not pipes.
CHANNEL_PIECE="$(printf '%s\n' "${CUERPO_CORTE_F}" | awk '/pids_arma=""/,/wait \$\{pids_arma\}/')"
READER_PATTERN='rc_arma="$(cat'
printf '%s\n' "${CUERPO_CORTE_F}" > "${BANCO}/phase-cut-fierro.body"
READER_LINE="$(grep -m1 "${READER_PATTERN}" "${BANCO}/phase-cut-fierro.body")"
mkdir -p "${BANCO}/arming-channel"; rm -f -- "${BANCO}"/arming-channel/arma-rc-*
printf '%s\n' "${CHANNEL_PIECE}" > "${BANCO}/arming-channel.piece"
printf '%s\n' "${READER_LINE}" > "${BANCO}/arming-channel.reader"
{
	printf '%s\n' 'set -euo pipefail' 'NODE_IDS=(1 2 3)'
	printf 'OUT_LOCAL=%s\n' "'${BANCO}/arming-channel'"
	printf '%s\n' 'testigo_arma() { echo "arming the canary on node $1"; return 0; }' 'fail() { :; }' 'arm_the_three() {'
	printf '%s\n' "${CHANNEL_PIECE}"
	printf '%s\n' '}' 'arm_the_three' 'armed=0'
	printf '%s\n' 'for n in "${NODE_IDS[@]}"; do'
	printf '%s\n' "${READER_LINE}"
	printf '%s\n' '	if [ "${rc_arma}" = 0 ]; then armed=$((armed + 1)); fi'
	printf '%s\n' 'done'
	printf '%s\n' 'echo "ARMED ${armed}"'
} > "${BANCO}/arming-channel.sh"
roja 17if "1|3|si|si" "$(bash "${BANCO}/arming-channel.sh" 2>/dev/null | grep -c '^ARMED 3$')|$(cat "${BANCO}"/arming-channel/arma-rc-* 2>/dev/null | awk 'END{print NR}')|$(range_ok "${BANCO}/arming-channel.piece" 'testigo_arma' 'wait ${pids_arma}' && echo si || echo no)|$(piece_ok "${BANCO}/arming-channel.reader" "${READER_PATTERN}" && echo si || echo no)" "the parallel arming, with the writer and the reader EXTRACTED from the phase and a testigo_arma that arms well and ALSO prints one line: the three canaries are read as armed and the status channel keeps ONE line per node. With the redirect behind the fi, the testigo's line lands in the status file, the reader compares the WHOLE FILE against 0, the three nodes are noted as unable to arm and the phase reddens over a healthy fleet. The third and fourth columns are the EXTRACTION GUARDS of the two halves this row takes out of the phase: the arming range, which has to end on the anchor that closes it, and the reader's line, which has to keep being the one that reads the status file. Without them either anchor moving would bring the first two columns down for a cause that is not the one being measured"




# THE FAKE FLEET IS PUT BACK TO ITS STATE, and this is a measured correction: the
# helper changes the boot ids so that the cut is noticed, and without putting them back row
# 18, which reads them further down, came out red for a state that another row left behind.
# A row that moves the ground under the ones behind it is worse than one that measures nothing.
for n in 1 2 3; do
	printf 'aaaa-bbbb-cccc-000%s\n' "${n}" > "${BANCO}/casa/${n}/proc/sys/kernel/random/boot_id"
	rm -f -- "${BANCO}/estado/${n}.muerto"
done
rm -f -- "${BANCO}/casa/1/naylamp/testigo-corte.bin" "${BANCO}/casa/2/naylamp/testigo-corte.bin" "${BANCO}/casa/3/naylamp/testigo-corte.bin"
rm -rf -- "${OUT_LOCAL}"
OUT_LOCAL="${GUARDA_OUT7}"; MANIFEST="${GUARDA_MAN7}"; ES_FIERRO="${GUARDA_FIERRO7}"
VERDICTS="${GUARDA_V7}"; CHECK_FAILED="${GUARDA_CF7}"; EN_VUELO_MAX="${GUARDA_MAXV7}"

# ---- 18 to 21: the iron primitives against the stub --------------------------
fila 18 "aaaa-bbbb-cccc-0002" "$(boot_id_de 2)" "boot_id_de lee el boot id por el canal de tres estados"
: > "${BANCO}/estado/2.muerto"
roja 19 "2" "$( boot_id_de 2 >/dev/null 2>&1; echo $? )" "un host que no contesta devuelve 2, y NO una cadena vacia que pase por respuesta"
rm -f -- "${BANCO}/estado/2.muerto"
fila 20 "si" "$(ask_on 1 'true' && echo si || echo no)" "ask_on contesta SI sobre el host vivo"
fila 21 "176" "$(sysrq_de 1)" "sysrq_de trae el valor del host"

# ---- 22 to 25: the third canary, which is what the cut measures ---------------
testigo_siembra 1 >/dev/null 2>&1
fila 22 "${TESTIGO_SEMILLA}" "$(testigo_tamano 1)" "sembrado y sincronizado: ${TESTIGO_SEMILLA} bytes durables por construccion"
testigo_arma 1 >/dev/null 2>&1
fila 23 "$(( TESTIGO_SEMILLA + TESTIGO_COLA ))" "$(testigo_tamano 1)" "armado: la cola sin sincronizar esta encima"
# a DRY cut takes the tail with it: it is simulated by truncating to the seed
head -c "${TESTIGO_SEMILLA}" /dev/zero > "${BANCO}/casa/1/${TESTIGO_REMOTO}"
fila 24 "${TESTIGO_SEMILLA}" "$(testigo_tamano 1)" "tras un corte seco vuelve a la semilla, que es la senal que el gate lee"
roja 25 "$(( TESTIGO_SEMILLA + TESTIGO_COLA ))" "$(testigo_siembra 2 >/dev/null 2>&1; testigo_arma 2 >/dev/null 2>&1; testigo_tamano 2)" "un testigo que vuelve ENTERO significa que ahi no se corto nada, y ese es el caso que no puede leerse como verde"

# ---- 26 to 31: THE DECISIONS, calling the functions OF gate/p2.sh ------------
#
# These rows were arithmetic over literals written here, and a reader measured it
# on 2026-09-07: `cambiados=2; [ "${cambiados}" -ge 2 ]` proves
# that two is at least two, not that this script does anything. With the decision rewound in
# p2.sh, the ten stayed green. Now the decisions are functions named
# IN p2.sh and these rows call those, so rewinding the object puts the row
# red, which is the only thing that makes a bench useful.
fila 26 "2" "$(mayoria_de 3)" "mayoria_de(3) de p2.sh da 2, igual que cluster.Config.Quorum() en engine/cluster/config.go:87"
fila 27 "pasa" "$(faithful_suficiente 2 3 && echo pasa || echo cae)" "faithful_suficiente(2,3): dos copias frias fieles PASAN, la tercera puede no haber persistido"
roja 28 "cae" "$(faithful_suficiente 0 3 && echo pasa || echo cae)" "faithful_suficiente(0,3) CAE, que es donde el mutante sin barrera se queda"
roja 29 "cae" "$(faithful_suficiente 1 3 && echo pasa || echo cae)" "faithful_suficiente(1,3) tambien CAE: la mayoria no se relaja hasta volverse decorativa"

# ---- 30 and 31: the window, calling ventana_dentro of p2.sh -------------------
fila 30 "dentro" "$(ventana_dentro 1.2 && echo dentro || echo fuera)" "ventana_dentro(1.2) con la cota en ${VENTANA_MAX} s"
roja 31 "fuera" "$(ventana_dentro 31.0 && echo dentro || echo fuera)" "ventana_dentro(31.0) queda FUERA: con la raiz en commit=30 el diario pudo volcar la cola"

# ---- 32 to 35: THE MUTANTS. Each decision, rewound to what it was -------------
echo
echo "-- mutantes: cada uno rebobina una decision del 7 de septiembre de 2026 --"

# 32: lineas_listening rewound to the || echo 0
viejo_listening() { grep -c 'listening' "${FLEET}/node$1.log" 2>/dev/null || echo 0; }
roja 32 "2" "$(viejo_listening 1 | wc -l | tr -d ' ')" "MUTANTE: con el || echo 0 la funcion devuelve DOS lineas y la comparacion revienta"

# 33 and 33b: entry_log_bytes rewound to the fail-open form.
#
# THE FIRST VERSION OF THIS ROW MEASURED SOMETHING ELSE, and a reader caught it: it set up
# the unreadable file with a CIRCULAR symlink, for which `[ -e ]` is false, so
# the `continue` was taken and the line of the arithmetic DID NOT RUN. The row
# came out green because of the skip and not because of the empty substitution, which is
# exactly the defect it claims to rewind. It is a case of the error this bench exists to
# catch, inside the bench. Now there are two rows and each one sets up its own case:
#   33  the name exists and does not resolve, which is what the `-L` of p2.sh catches
#   33b the file DOES resolve and `stat` fails all the same, which is the only setup
#       in which the arithmetic gets to run and the empty operand is seen
viejo_bytes() {
	local n="$1" t=0 f
	for f in "${FLEET}/node${n}/data"/raft-*.log; do
		[ -e "${f}" ] || continue
		t=$(( t + $(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}" 2>/dev/null) )) 2>/dev/null
	done
	printf '%d' "${t}"
}
roja 33 "0" "$(viejo_bytes 2 2>/dev/null)" "MUTANTE: la forma vieja devuelve 0 sobre el segmento que no resuelve, o sea 'el log encogio'"

# The stat stub exits 1 ALWAYS, with the file present and readable, which is the
# only way for the substitution to come back empty and the arithmetic to run.
mkdir -p "${BANCO}/bin-stat"
printf '#!/bin/sh\nexit 1\n' > "${BANCO}/bin-stat/stat"
chmod +x "${BANCO}/bin-stat/stat"
mkdir -p "${FLEET}/node3/data"
head -c 77 /dev/zero > "${FLEET}/node3/data/raft-1.log"
salida_33b="$(PATH="${BANCO}/bin-stat:${PATH}" bash -c '
	set -euo pipefail
	t=0
	for f in "'"${FLEET}"'/node3/data"/raft-*.log; do
		[ -e "${f}" ] || continue
		t=$(( t + $(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}" 2>/dev/null) ))
	done
	printf "%d" "${t}"
	echo " y-el-guion-siguio-vivo"' 2>/dev/null)"
roja 33b "0 y-el-guion-siguio-vivo" "${salida_33b}" "MUTANTE: con stat fallando de verdad, la aritmetica revienta en stderr, t conserva su valor y el guion SIGUE con rc 0; eso es el fail-open que set -e no caza"
# The `set +e` is there because p2.sh brings `set -euo pipefail` along when sourced, and
# without it the very function that returns 2, which is what this row wants to see, kills
# the subshell before the `echo $?`. The first version of this row aborted the
# whole bench there, that is, the row written to measure a fail-open died
# because of the strict mode of the object it was measuring.
salida_33c="$(PATH="${BANCO}/bin-stat:${PATH}" bash -c 'source "'"${GATE_DIR}"'/p2.sh" >/dev/null 2>&1; set +e; FLEET="'"${FLEET}"'"; entry_log_bytes 3 >/dev/null 2>&1; echo $?' 2>/dev/null)"
fila 33c "2" "${salida_33c}" "y la forma de hoy, en el MISMO montaje, devuelve 2 en vez de un total corto"

# 34 and 35: the threshold of the cut. The red row rewinds corte_completo to a threshold of
# two, writing it here as it was in the tree; the green row calls the one of p2.sh.
corte_completo_viejo() { [ "$1" -ge 2 ]; }
roja 34 "acepta" "$(corte_completo_viejo 2 3 && echo acepta || echo rechaza)" "MUTANTE: con umbral de DOS, dos boot id cambiados bastan y la superviviente cura a las otras"
fila 35 "rechaza" "$(corte_completo 2 3 && echo acepta || echo rechaza)" "corte_completo(2,3) de p2.sh RECHAZA: la decision del 7 de septiembre de 2026 exige las tres"
fila 36 "acepta" "$(corte_completo 3 3 && echo acepta || echo rechaza)" "y corte_completo(3,3) acepta, para que la fila de arriba no pase por ser siempre negativa"

# 37: faithful rewound to demanding all three, against the one of p2.sh
faithful_viejo() { [ "$1" -eq "$2" ]; }
roja 37 "cae" "$(faithful_viejo 2 3 && echo pasa || echo cae)" "MUTANTE: exigir las TRES pone rojo un hardware sano, porque Raft ackea con dos"

# 38 and 39: identity by path against identity by content, with the one of p2.sh
roja 38 "no-distingue" "$(identidad_confirmada deadbeef deadbeef && echo distingue || echo no-distingue)" "identidad_confirmada con el MISMO sha no distingue: un mutante sobre el nombre sano tiene la misma ruta y el mismo contenido no"
fila 39 "distingue" "$(identidad_confirmada cafe1234 deadbeef && echo distingue || echo no-distingue)" "identidad_confirmada de p2.sh separa contenidos distintos"
roja 39b "no-distingue" "$(identidad_confirmada "" deadbeef && echo distingue || echo no-distingue)" "y una lectura VACIA no cuenta como distinta: un pid muerto no confirma nada"

# 39c to 39g: testigo_veredicto of p2.sh, its five outputs
fila 39c "seco"         "$(testigo_veredicto 4096 4096 65536)"  "testigo_veredicto: la semilla sola es un corte SECO"
fila 39d "entero"       "$(testigo_veredicto 69632 4096 65536)" "el total es ENTERO, o sea que ahi no se corto"
fila 39e "parcial"      "$(testigo_veredicto 30000 4096 65536)" "a medias sigue siendo un corte"
roja 39f "bajo-semilla" "$(testigo_veredicto 100 4096 65536)"   "por DEBAJO de la semilla sincronizada no es un corte seco: es una barrera rota bajo el sistema de ficheros"
roja 39g "ilegible"     "$(testigo_veredicto "" 4096 65536)"    "y una lectura vacia es ILEGIBLE, no cero"

# ---- 42 to 45: the state of the REMOTE client, which on iron travels as text --
#
# On iron the client runs inside host 1 and its exit code comes back as one
# line, because ssh mixes the status of the transport with that of the program. The
# first version looked for __RC__=0 ANYWHERE in the stream, that is, the output
# of the client itself could decide the verdict: a status channel that the payload
# can falsify is not a status channel. The LAST line is read whole.
cliente_estado() {
	local salida="$1" ultima rc
	ultima="$(printf '%s' "${salida}" | tail -1)"
	rc=1
	case "${ultima}" in
		__RC__=0) rc=0 ;;
		__RC__=[0-9]*) rc=1 ;;
		*) rc=2 ;;
	esac
	printf '%s' "${rc}"
}
fila 42 "0" "$(cliente_estado "$(printf 'id=1 score=0.9\n__RC__=0\n')")" "el remoto contesta y sale 0"
roja 43 "1" "$(cliente_estado "$(printf 'error\n__RC__=3\n')")" "sale distinto de cero: no committed"
roja 44 "1" "$(cliente_estado "$(printf 'id=1 texto __RC__=0 pegado\n__RC__=3\n')")" "la SALIDA lleva __RC__=0 dentro y el estado real es 3: no se deja falsificar"
roja 45 "2" "$(cliente_estado "$(printf 'a medias\n')")" "el canal se corto y no hay linea de estado: eso es ILEGIBLE, no un fallo del programa"

# ---- 40: the mutant does NOT land on the path the omnibus measures ------------
fila 40 "0" "$(printf '%s' "${MUT_REMOTO}" | grep -c '^naylamp/bin/naylampd$')" "el mutante NO va a naylamp/bin/naylampd, que es lo que record_binary_digests lee en gate/omnibus.sh:589"
fila 41 "1" "$(printf '%s' "${MUT_REMOTO}" | grep -c 'naylampd-mutante')" "va a su propio nombre"

echo
echo "=============================================================================="
if [ "${OMITIDAS}" -ne 0 ]; then
	echo "${OMITIDAS} fila(s) no aplican en este entorno y no se cuentan como filas; el motivo va impreso arriba"
fi
echo "RESULTADO: ${FILAS} rows, ${ROJAS} of them red, ${FALLAS} failing"
# COMPLETO IS SET HERE, behind the summary and in front of the anti-vacuity check, for the
# reason written in the other benches: exiting with 1 with COMPLETO at zero makes
# the trap print "ABORTADO antes del resumen" right below the summary.
COMPLETO=1
if [ "${FILAS}" -eq 0 ]; then
	echo "p2-iron-test: VACIO. Cero filas, asi que este banco no ha probado nada, y eso NO es un pase" >&2
	exit 1
fi
echo "LO QUE ESTE BANCO NO CUBRE, y va escrito: no enciende una VM, no dispara un"
echo "sysrq-b de verdad y no mide un corte real. Prueba los PREDICADOS del camino de"
echo "fierro y sus mutantes; la primera corrida de fierro es la que los prueba en"
echo "anger, y eso es un limite declarado y no un descuido."
echo "=============================================================================="
[ "${FALLAS}" -eq 0 ] || exit 1
exit 0
