#!/usr/bin/env bash
# p2-guard-test.sh: the red arm of gate/p2.sh's rehearsal.
#
# It fires guards of that script from BOTH sides: a control that must stay green,
# and one mutation per guard that must turn it red. NOT every guard, and the count
# is printed at the end instead of promised here, because "each guard" was written
# in this line while five of the fifteen runnable verdicts had no row at all. A guard nobody has
# ever seen go red is a guard nobody has tested, and this house has already paid
# once for a red arm that certified an empty list.
#
# EVERY ROW ALSO ANSWERS THE FLOW QUESTION, which is clause 20 of the protocol:
# it is not enough that the verdict changes, the row has to say whether the run
# STOPS where it should or CARRIES ON, because a check that fails and lets the
# run continue is a different animal from one that fails and stops it, and the
# verdict alone cannot tell them apart. Where the right answer is CARRY ON, the
# row says so and says why.
#
# HOW IT MUTATES. Never the SOURCE. Each row copies gate/p2.sh into a scratch
# directory, edits the copy, and runs the copy, so gate/p2.sh itself is never
# edited. It does touch the working tree, and the first version of this line said
# it did not: every row runs with NAYLAMP_P2_REPO pointing at the real repository,
# so each one rebuilds gate/out/p2-naylampd and creates an artifact under
# gate/out, and a row landing inside the two hour window before the certificates
# expire would re-mint gate/out/certs through gate/build.sh. Each row removes its
# own artifact when it ends. What it never does is change a tracked file.
#
# THE WORKLOAD IS SHORTENED IN EVERY ROW, THE CONTROL INCLUDED, and that is said
# out loud because it is the anti-vacuity of this test: control and mutants
# differ by the mutation and by nothing else.
#
# AND NOT EVERY ROW LAUNCHES THE SCRIPT, which an earlier version of the line
# above got wrong: of the twenty three rows, seventeen do and rebuild
# gate/out/p2-naylampd, four refuse before creating anything, and two only ask
# what is still running when everything else has finished. The full rehearsal writes 30 puts
# and 3 deletes; here it writes 3 and 1, which is enough for every guard below to
# have something to be wrong about.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P2="${GATE_DIR}/p2.sh"
REPO_DIR="$(cd "${GATE_DIR}/.." && pwd)"
[ -f "${P2}" ] || { echo "guard: no encuentro ${P2}" >&2; exit 2; }

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
case "${RUN_ID}" in
	[0-9]*Z-[0-9]*) ;;
	*) echo "guard: refusing to run: the run id ${RUN_ID} is not the shape this script deletes by" >&2; exit 2 ;;
esac
SCRATCH="${TMPDIR:-/tmp}/naylamp-p2-guard-${RUN_ID}"
mkdir -p "${SCRATCH}"

FILAS=0
ROJAS=0
MAL=0
# Categorias contadas y no recitadas. El epilogo de la version anterior decia
# OCHO filas que siguen cuando eran ONCE, porque tres filas nuevas entraron y el
# cardinal escrito a mano se quedo, y esa cifra mala llego a archivarse en una
# corrida cuyos contadores automaticos salian bien.
NO_EMPIEZAN=0
SIGUEN=0
ABORTAN=0
SUPERVIV=0

# corta_workload shortens the loop in a copy, so a row costs seconds and not a
# minute. It is applied to the control too.
corta_workload() {
	/usr/bin/python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
a = 'for i in $(seq 1 30); do'
b = 'for i in $(seq 1 3); do'
assert s.count(a) == 1, 'el bucle del workload no esta donde este test cree'
s = s.replace(a, b)
a2 = 'for i in 3 11 19; do'
b2 = 'for i in 2; do'
assert s.count(a2) == 1, 'el bucle de borrados no esta donde este test cree'
s = s.replace(a2, b2)
open(p, 'w', encoding='utf-8').write(s)
PY
}

# prepara copies p2.sh, shortens it, and applies the row's mutation, which arrives
# as a python snippet on stdin so a mutation can be an exact string swap and never
# a regex that might match twice.
prepara() {
	local nombre="$1" copia="${SCRATCH}/$1.sh"
	cp "${P2}" "${copia}"
	corta_workload "${copia}"
	if [ -n "${2:-}" ]; then
		if ! /usr/bin/python3 - "${copia}" "$2" "$3" <<'PY'
import sys
p, viejo, nuevo = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
n = s.count(viejo)
assert n == 1, 'la mutacion no muerde donde este test cree: %d apariciones de %r' % (n, viejo[:60])
open(p, 'w', encoding='utf-8').write(s.replace(viejo, nuevo))
PY
		then
			echo "guard: la mutacion de ${nombre} no mordio; se para en vez de puntuar una copia sin mutar" >&2
			exit 3
		fi
	fi
	chmod +x "${copia}"
	printf '%s' "${copia}"
}

# sin_supervivientes asks the question the verdict cannot: after the script has
# ended, is anything it launched still running? It is a separate check because a
# run can close with a correct red verdict and still leave three daemons
# listening, which is exactly what happened before the pid list moved out of the
# directory that hygiene removes.
#
# pgrep exits 1 when it finds nothing, which HERE is the good case, and under
# pipefail that killed this bench. The success branch is written explicitly.
sin_supervivientes() {
	local etiqueta="$1" glosa="$2" n
	FILAS=$((FILAS + 1))
	SUPERVIV=$((SUPERVIV + 1))
	sleep 1
	# Las DOS flotas, la sana y la mutante. La version anterior solo buscaba la
	# sana, asi que tres daemons mutantes vivos le habrian pasado por delante.
	#
	# Y SE MIRA LA LINEA DE ORDEN ANCLADA, no una subcadena. Con `pgrep -f` sobre
	# el patron, cualquier proceso que MENCIONE esas palabras casa, incluido el
	# shell que esta vigilando: el 6 de septiembre de 2026 esta fila salio NO
	# CUADRA con un superviviente que no existia, y lo que casaba era la propia
	# orden de vigilancia. Es la misma leccion que gate/p1.sh dejo escrita cuando
	# conto caffeinate por palabra en vez de por pid.
	n=$(ps -Ao args= 2>/dev/null | grep -cE '^[^ ]*/(p2-naylampd|naylampd-mutante) node -id ' || true)
	[ -z "${n}" ] && n=0
	if [ "${n}" -eq 0 ]; then
		printf '%-26s %s\n' "${etiqueta}-sin-supervivientes" "0 nodos vivos ${glosa}   OK"
	else
		printf '%-26s %s\n' "${etiqueta}-sin-supervivientes" "NO CUADRA: ${n} nodos siguen vivos tras terminar el guion"
		MAL=$((MAL + 1))
	fi
}

# fila runs one row and scores it. espera is pass or fail, and flujo is what the
# run should do after the check: stop or carry.
fila() {
	local nombre="$1" espera="$2" flujo="$3" veredicto="$4" copia="$5" rc_espera="$6" sub="${7:-all}"
	local salida rc v llego_final cierre
	FILAS=$((FILAS + 1))
	set +e
	salida="$(NAYLAMP_P2_LOCAL=1 NAYLAMP_P2_REPO="${REPO_DIR}" "${copia}" "${sub}" 2>&1)"
	rc=$?
	set -e
	printf '%s\n' "${salida}" > "${SCRATCH}/${nombre}.log"

	v="$(printf '%s' "${salida}" | grep -o "verdict ${veredicto} = [a-z]*" | tail -1 | awk '{print $4}')"
	[ -z "${v}" ] && v="(sin veredicto)"
	# THE FLOW, and this is the second version of the question. The first asked
	# whether the verdict block printed, and that stopped separating anything the
	# day p2.sh learned to print the block from its exit trap. What it asks now is
	# whether the run REACHED ITS OWN END or was cut short, which is the
	# distinction clause 20 is about, and the script says so itself.
	if printf '%s' "${salida}" | grep -q 'the run ABORTED before reaching its verdict block'; then
		llego_final=abort
	else
		llego_final=carry
	fi
	# AND THE THING THE EPILOGUE USED TO CLAIM WAS WATCHED AND NOBODY WATCHED: a
	# row whose verdict is red must never close with the success line. That
	# sentence sat in the epilogue of this file for one version with nothing
	# behind it, which is the same defect it exists to catch in p2.sh.
	if printf '%s' "${salida}" | grep -q 'all rehearsal checks passed'; then cierre=verde; else cierre=rojo; fi

	local bien=si
	[ "${v}" = "${espera}" ] || bien=no
	[ "${llego_final}" = "${flujo}" ] || bien=no
	case "${rc_espera}" in
		no-cero) [ "${rc}" -ne 0 ] || bien=no ;;
		*) [ "${rc}" = "${rc_espera}" ] || bien=no ;;
	esac
	[ "${espera}" = fail ] && [ "${cierre}" = verde ] && bien=no
	[ "${bien}" = no ] && MAL=$((MAL + 1))
	[ "${v}" = fail ] && ROJAS=$((ROJAS + 1))
	if [ "${llego_final}" = abort ]; then ABORTAN=$((ABORTAN + 1)); else SIGUEN=$((SIGUEN + 1)); fi

	printf '%-26s %-22s ver %-5s/%-14s flujo %-5s/%-5s rc %s/%-3s cierre %-5s %s\n' \
		"${nombre}" "${veredicto}" "${espera}" "${v}" "${flujo}" "${llego_final}" "${rc_espera}" "${rc}" "${cierre}" \
		"$([ "${bien}" = si ] && echo OK || echo 'NO CUADRA')"

	retira_artefacto "${salida}"
}

# retira_artefacto removes the artifact directory the row just created, so a red
# arm that runs nine rows does not leave nine directories behind in a tree whose
# whole point is not accumulating them. Twenty four of them were counted on
# 2026-09-06 before this existed, and they were this test's doing.
#
# THE ROOT COMES FROM A VARIABLE, so clause 23 applies and its escape hatch is the
# one taken: the root is VALIDATED before the order and the order refuses if it
# does not hold up. Two conditions, and both have to be true: the directory holds
# a go.work, which is what makes it this repository and not somewhere else, and
# the run id has the exact shape this test deletes by. Anything else and nothing
# is removed and the row says so.
retira_artefacto() {
	local rid
	rid="$(printf '%s' "$1" | grep -o 'run id p2-local-[0-9]\{8\}T[0-9]\{6\}Z-[0-9]\{1,\}' | tail -1 | sed 's/^run id p2-local-//')"
	if [ -z "${rid}" ]; then
		return 0   # la fila no llego a imprimir su run id: no hay nada que retirar
	fi
	case "${rid}" in
		[0-9]*Z-[0-9]*) ;;
		*) echo "guard: no retiro ${rid}: no es la forma por la que este banco borra" >&2; return 0 ;;
	esac
	if [ ! -f "${REPO_DIR}/go.work" ] || [ ! -d "${REPO_DIR}/gate/out" ]; then
		echo "guard: no retiro nada: ${REPO_DIR} no parece este repositorio" >&2
		return 0
	fi
	rm -rf -- "${REPO_DIR}/gate/out/p2-local-${rid}"
	rm -rf -- "${REPO_DIR}/gate/out/p2-local-fleet-${rid}"
}

echo "brazo rojo de gate/p2.sh, corrida ${RUN_ID}"
echo "maquina: $(sysctl -n hw.model 2>/dev/null || uname -m), $(uname -sr)"
echo "toolchain: $(go version)"
echo "carga al arrancar: $(uptime | sed 's/.*load averages*: //')"
echo "banco: ${SCRATCH}; el arbol de trabajo no se toca"
echo "el workload va acortado a 3 puts y 1 borrado en TODAS las filas, control incluido"
echo

# ---- filas que no necesitan flota, y por eso van primero ----------------------

echo "--- las que ni siquiera arrancan la flota ---"

set +e
salida="$("${P2}" all 2>&1)"; rc=$?
set -e
FILAS=$((FILAS + 1))
if [ "${rc}" -eq 2 ] && printf '%s' "${salida}" | grep -q 'no iron path yet' && ! printf '%s' "${salida}" | grep -q 'gate: verdict '; then
	echo "F0-fierro-rechazado          sin NAYLAMP_P2_LOCAL             rc=2, ninguna fase corrio, ningun veredicto   OK"
	NO_EMPIEZAN=$((NO_EMPIEZAN + 1))
else
	echo "F0-fierro-rechazado          NO CUADRA: rc=${rc}"; MAL=$((MAL + 1))
fi

set +e
salida="$(NAYLAMP_P2_LOCAL=1 "${P2}" 2>&1)"; rc=$?
set -e
FILAS=$((FILAS + 1))
if [ "${rc}" -eq 2 ] && printf '%s' "${salida}" | grep -q 'usage:' && ! printf '%s' "${salida}" | grep -q 'gate: verdict '; then
	echo "F1-sin-subcomando            invocacion desnuda               rc=2, uso impreso, ningun veredicto           OK"
	NO_EMPIEZAN=$((NO_EMPIEZAN + 1))
else
	echo "F1-sin-subcomando            NO CUADRA: rc=${rc}"; MAL=$((MAL + 1))
fi

# Un subcomando que el uso NO anuncia tiene que salir por el mismo sitio y no
# dejar nada. Es la fila de D6: antes de arreglarlo, cada intento de estos creaba
# un directorio bajo gate/out porque el artefacto se creaba antes de validar.
set +e
salida="$(NAYLAMP_P2_LOCAL=1 "${P2}" hygiene 2>&1)"; rc=$?
set -e
FILAS=$((FILAS + 1))
sobra="$(ls -d "${REPO_DIR}"/gate/out/p2-local-* 2>/dev/null | wc -l | tr -d ' ' || true)"
if [ "${rc}" -eq 2 ] && printf '%s' "${salida}" | grep -q 'usage:' && ! printf '%s' "${salida}" | grep -q 'gate: verdict '; then
	echo "F1b-subcomando-no-cableado   'hygiene', que el uso no anuncia   rc=2 y ningun veredicto                      OK"
	NO_EMPIEZAN=$((NO_EMPIEZAN + 1))
else
	echo "F1b-subcomando-no-cableado   NO CUADRA: rc=${rc}"; MAL=$((MAL + 1))
fi

copia="$(prepara runid-roto \
	'	[0-9]*Z-[0-9]*) ;;' \
	'	nunca-casa-esto) ;;')"
set +e
salida="$(NAYLAMP_P2_LOCAL=1 NAYLAMP_P2_REPO="${REPO_DIR}" "${copia}" all 2>&1)"; rc=$?
set -e
FILAS=$((FILAS + 1))
if [ "${rc}" -eq 2 ] && printf '%s' "${salida}" | grep -q 'not the shape this script deletes by' && ! printf '%s' "${salida}" | grep -q 'gate: verdict '; then
	echo "F2-runid-fuera-de-forma      la guarda del borrado            rc=2, antes de crear nada, ningun veredicto   OK"
	NO_EMPIEZAN=$((NO_EMPIEZAN + 1))
else
	echo "F2-runid-fuera-de-forma      NO CUADRA: rc=${rc}"; MAL=$((MAL + 1))
fi

echo
echo "--- las que corren el ensayo entero, con el workload acortado ---"
printf '%-26s %-30s %s\n' fila veredicto resultado

copia="$(prepara control)"
fila control-sin-mutar pass carry P2.workload.acked "${copia}" 0

# El manifiesto deja de recibir la operacion ackeada: el oraculo se queda vacio y
# todo lo de detras se volveria vacuo. La guarda de anti-vacuidad tiene que verlo.
copia="$(prepara manifiesto-mudo \
	'		echo "put ${id} ${vec}" >> "${MANIFEST}"' \
	'		: # mutacion: la operacion se ackea y no entra en el manifiesto')"
fila manifiesto-mudo fail carry P2.workload.acked "${copia}" 1

# Un id ackeado que no vuelve. Se inyecta en la lista de vivos un id que nadie
# escribio, que es la forma exacta del fallo que esta comprobacion existe para ver.
copia="$(prepara id-que-no-vuelve \
	"	done < \"\${OUT_LOCAL}/live-ids.txt\"" \
	"	done < <(cat \"\${OUT_LOCAL}/live-ids.txt\"; echo 424242)")"
fila id-que-no-vuelve fail carry P2.recover.acked "${copia}" 1

# Un fantasma en el manifiesto: una operacion que el manifiesto declara ackeada y
# que la corrida nunca emitio. verify-log tiene que negarse a llamarlo fiel.
copia="$(prepara fantasma-en-el-manifiesto \
	'	local t0 t1 i n_ok=0 n_try=0' \
	'	local t0 t1 i n_ok=0 n_try=0
	trap "echo \"put 777777 1,0,0,0,0,0,0,0\" >> \"${MANIFEST}\"" RETURN')"
fila fantasma-en-el-manifiesto fail carry P2.recover.faithful "${copia}" 1

# La higiene deja de matar, y la mutacion tiene que quitarle LAS DOS pasadas. La
# primera version de esta fila quitaba solo el kill amable y salio VERDE, porque
# el kill -9 de detras remataba igual: una mutacion que no llega al sitio no
# prueba nada de la guarda, y esta fila la cazo a si misma.
copia="$(prepara higiene-que-no-mata \
	'	for n in "${NODE_IDS[@]}"; do
		if node_alive "$n"; then
			kill "$(node_pid "$n")" 2>/dev/null || true
		fi
	done
	sleep 1
	for n in "${NODE_IDS[@]}"; do
		if node_alive "$n"; then
			kill -9 "$(node_pid "$n")" 2>/dev/null || true
		fi
	done' \
	'	: # mutacion: la higiene no mata a nadie, ni con senal ni con -9')"
fila higiene-que-no-mata fail carry P2.hygiene "${copia}" 1

# La identidad de binario. Una replica ejecutando otra cosa tiene que verse, y la
# primera version de esa comprobacion no podia verlo porque comparaba una
# variable consigo misma: se lanzo el nodo 3 con otro binario y salio PASS igual.
# La mutacion pone a un nodo a ejecutar una copia con otro nombre.
copia="$(prepara identidad-cambiada \
	'	local n="$1" dir="${FLEET}/node${n}"' \
	'	local n="$1" dir="${FLEET}/node${n}"
	if [ "${n}" = 3 ]; then cp "${BIN}" "${OUT_LOCAL}/otro-naylampd"; local BIN="${OUT_LOCAL}/otro-naylampd"; fi')"
fila identidad-cambiada fail carry P2.pre.identity "${copia}" 1

# La procedencia. Su primera version llamaba a pass sin condicion, asi que no
# podia ponerse roja por nada. La mutacion le quita el arbol de debajo.
copia="$(prepara procedencia-sin-arbol \
	'	head="$(cd "${REPO_DIR}" && git rev-parse HEAD 2>/dev/null || true)"' \
	'	head=""')"
fila procedencia-sin-arbol fail carry P2.provenance "${copia}" 1

# Y LA UNICA QUE PARA, que es la que faltaba: hasta esta fila ninguna esperaba
# `stop`, o sea que la pregunta del flujo se contestaba con una constante y no
# probaba nada. La mutacion aborta a mitad de fase llamando a una orden que no
# existe. Lo que se exige es que el guion DIGA que aborto, imprima su bloque de
# veredictos igualmente y no salga cero: antes de arreglarlo dejaba ocho lineas
# PASS, cero lineas de veredicto y ninguna de NOT A SUCCESS.
copia="$(prepara aborto-a-media-fase \
	'	t0="$(ahora)"
	for i in $(seq 1 3); do' \
	'	t0="$(no-existe-esta-orden)"
	for i in $(seq 1 3); do')"
fila aborto-a-media-fase none abort P2.workload.acked "${copia}" no-cero

# EL CORTE QUE FALLA EN UNA REPLICA, que es el caso que dejaba un daemon huerfano.
# phase_recover relanza la replica cortada y launch_node sobrescribia su pid, asi
# que si el corte no habia matado a la primera, ese pid se perdia y nada detras
# lo alcanzaba. La mutacion corta solo el nodo 2 y deja el 1 vivo.
# EL BRAZO ROJO DEL BRAZO ROJO, que es lo que faltaba hasta el 6 de septiembre de
# 2026: las tres partes de phase_red se disparan aqui, y sin estas filas serian
# tres verdes mas que nadie ha visto ponerse rojos. Van con el subcomando `red`,
# que corre la fase sola y cuesta unos veinte segundos en vez de dos minutos.

# La mutacion deja de compilar: la fase tiene que decirlo y no seguir como si nada.
# LOS CINCO QUE NO TENIAN FILA, escritos el 6 de septiembre de 2026 porque un
# lector adversarial conto cuantos veredictos tienen mutacion y cuantos no: eran
# diez de quince. La frase "one mutation per guard" llevaba escrita desde el
# primer dia y era falsa, y la salida honesta no era suavizarla sino escribirlas.

# P2.build: el binario no queda donde la fase lo busca.
copia="$(prepara build-sin-binario \
	'[ -x "${BIN}" ] || fail "P2.build:' \
	'[ -x "${BIN}.no-existe" ] || fail "P2.build:')"
fila build-sin-binario fail carry P2.build "${copia}" 1 build

# P2.pre.fleet: una replica no puede escuchar, porque la direccion no es suya.
copia="$(prepara flota-que-no-escucha \
	'-listen "${HOSTADDR}:${NODE_PORTS[$n]}"' \
	'-listen "203.0.113.9:${NODE_PORTS[$n]}"')"
fila flota-que-no-escucha fail carry P2.pre.fleet "${copia}" 1 pre

# P2.recover.boots: las replicas cortadas no se relanzan.
copia="$(prepara recover-que-no-arranca \
	'	for n in 1 2; do
		launch_node "${n}"
	done' \
	'	for n in 1 2; do
		: # mutacion: la replica cortada no se relanza
	done')"
fila recover-que-no-arranca fail carry P2.recover.boots "${copia}" 1

# P2.recover.elects: la consulta que prueba que hay lider se vuelve invalida.
copia="$(prepara eleccion-que-no-sirve \
	'client_op -op search -vec "$(vec_for 1)" -k 3' \
	'client_op -op search -vec "$(vec_for 1)" -k 0')"
fila eleccion-que-no-sirve fail carry P2.recover.elects "${copia}" 1

# P2.recover.idem: la segunda lectura se hace sobre otra replica, asi que los dos
# digests no tienen por que coincidir.
copia="$(prepara idem-sobre-otro-directorio \
	'h2="$("${BIN}" state-hash -id 1 -peers "$(peers_of 1)" -dir "${copia}"' \
	'h2="$("${BIN}" state-hash -id 2 -peers "$(peers_of 2)" -dir "${OUT_LOCAL}/cold-node2"')"
fila idem-sobre-otro-directorio fail carry P2.recover.idem "${copia}" 1

copia="$(prepara mutante-que-no-construye \
	'b = """	// red arm mutation: the AppendEntries barrier removed.' \
	'b = """	esto no es go y no debe compilar')"
fila mutante-que-no-construye fail carry P2.red.mutation "${copia}" 1 red

# Y LA QUE MAS IMPORTA: una mutacion que NO muerde. Deja la barrera donde estaba y
# solo anade un comentario, asi que el binario cambia y los defensores del arbol
# siguen verdes. Si `P2.red.bites` no lo viera, la fase estaria certificando que
# la mutacion llega al sitio sin haberlo comprobado, que es el defecto exacto que
# el censo de DEFER-077 midio en los brazos rojos de esta casa.
copia="$(prepara mutacion-que-no-muerde \
	'b = """	// red arm mutation: the AppendEntries barrier removed.
	s.lastIndex = entries[len(entries)-1].Index"""' \
	'b = """	// red arm mutation: this one deliberately does not remove anything.
	if err := s.active.Sync(); err != nil {
		return fmt.Errorf("raft: fsync entries: %w", err)
	}
	s.lastIndex = entries[len(entries)-1].Index"""')"
fila mutacion-que-no-muerde fail carry P2.red.bites "${copia}" 1 red

# Y el mutante que no levanta cluster, que en fierro es lo que se lleva la sesion
# por delante con las tres VMs encendidas. La mutacion le da un directorio de
# datos donde no se puede escribir, asi que los nodos mueren al arrancar.
copia="$(prepara mutante-que-no-arranca \
	'-dir "${MUT_ROOT}/flota/node${n}/data" -dim' \
	'-dir "/dev/null/no-se-puede-escribir-aqui" -dim')"
fila mutante-que-no-arranca fail carry P2.red.daemon "${copia}" 1 red

copia="$(prepara corte-que-falla-en-una \
	'	for n in 1 2; do
		kill -9 "${PID_BEFORE[$n]}" 2>/dev/null || true
	done' \
	'	for n in 2; do
		kill -9 "${PID_BEFORE[$n]}" 2>/dev/null || true
	done')"
fila corte-que-falla-en-una fail carry P2.cut.fired "${copia}" 1
sin_supervivientes F9 "tras un corte que dejo una replica viva"

# Y la fila de arriba tiene una SEGUNDA mitad, que es la que de verdad importa y
# la que este banco encontro. Una higiene que no mata deja tres daemons vivos, y
# lo unico que puede recogerlos es la limpieza de salida. La primera version de
# p2.sh la tenia y NO servia: escribia los pid dentro del directorio de flota, que
# phase_hygiene borra antes de salir, asi que la limpieza buscaba un fichero que
# ya no estaba y no mataba a nadie. Medido ese dia: los nodos 1, 2 y 3 quedaron
# escuchando en loopback despues de que el guion hubiera terminado. Los pid viven
# ahora fuera de ese directorio, y esta comprobacion es la que lo sostiene.
sin_supervivientes F8 "al cerrar el banco, tras las filas de higiene y de corte parcial"

echo
echo "filas: ${FILAS}, veredictos rojos obtenidos: ${ROJAS}, filas que no cuadran: ${MAL}"
echo
printf 'LA PREGUNTA DEL FLUJO, contestada fila a fila y contada, no recitada:\n'
printf '  %d filas NO EMPIEZAN, y deben: rechazan antes de crear un directorio, encender un\n' "${NO_EMPIEZAN}"
printf '  nodo o registrar un veredicto. Las cuatro se comprueban por rc=2 y por la ausencia\n'
printf '  de una sola linea "gate: verdict".\n'
printf '  %d filas SIGUEN hasta su propio final, y deben. Este gate registra un veredicto por\n' "${SIGUEN}"
printf '  clausula y su valor es el de la clausula, no el del guion: parar en el primer rojo\n'
printf '  se llevaria por delante los veredictos de las fases de detras. Es la misma\n'
printf '  respuesta que DEFER-083 midio para phase_digest y por la misma razon.\n'
printf '  %d fila PARA, y es la que hacia falta: hasta que existio, todas esperaban lo mismo\n' "${ABORTAN}"
printf '  y la pregunta se contestaba con una constante.\n'
printf '  %d filas no miran veredicto sino lo que queda vivo despues, porque un rojo correcto\n' "${SUPERVIV}"
printf '  y tres daemons huerfanos caben en la misma corrida.\n'
printf '  suma: %d, y FILAS dice %d\n' "$((NO_EMPIEZAN + SIGUEN + ABORTAN + SUPERVIV))" "${FILAS}"
if [ "$((NO_EMPIEZAN + SIGUEN + ABORTAN + SUPERVIV))" -ne "${FILAS}" ]; then
	echo "guard: el reparto por categorias no suma las filas corridas" >&2
	MAL=$((MAL + 1))
fi
echo
echo "LO QUE ESTE BANCO COMPRUEBA DE CADA FILA, y no solo el veredicto: el codigo de"
echo "salida, si la corrida llego a su final o aborto, y que una fila roja NO cierre con"
echo "'all rehearsal checks passed'."
echo
echo "el banco queda en ${SCRATCH} para que se puedan leer los logs de cada fila"

[ "${MAL}" -eq 0 ] || exit 1
exit 0
