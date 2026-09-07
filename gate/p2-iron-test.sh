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
# The workspace is gate/out/p2-iron-test, a literal path, rebuilt from zero every
# run and removed when the rows are green. It is swept by make clean either way.
set -uo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BANCO="${GATE_DIR}/out/p2-iron-test"

FALLAS=0
ROJAS=0
FILAS=0
fila() {
	local id="$1" quiero="$2" tengo="$3" porque="$4"
	FILAS=$((FILAS + 1))
	if [ "${quiero}" = "${tengo}" ]; then
		printf 'FILA %-4s OK    %s\n' "${id}" "${porque}"
	else
		printf 'FILA %-4s FALLA %s (queria [%s], salio [%s])\n' "${id}" "${porque}" "${quiero}" "${tengo}"
		FALLAS=$((FALLAS + 1))
	fi
}
roja() {
	local id="$1" quiero="$2" tengo="$3" porque="$4"
	ROJAS=$((ROJAS + 1))
	fila "${id}" "${quiero}" "${tengo}" "ROJA ${porque}"
}

# EL NOMBRE DE ESTA FUNCION NO ES CASUAL Y LA TRAMPA SE REGISTRA DESPUES DE
# CARGAR p2.sh. La primera version la llamo al_salir, que es exactamente el
# nombre que gate/p2.sh da a la suya, asi que al cargarlo la definicion de p2.sh
# PISABA la de este banco y la trampa acababa llamando a la de p2.sh: el banco no
# se barria, su directorio quedaba en gate/out, y el artefacto con nombre de
# fierro que las filas 13 a 17 crean quedaba tambien, donde `make clean` se niega
# a tocarlo por no llevar sello. Cuatro de ellos quedaron antes de que la
# limpieza medida del cierre los encontrara. Un banco que ensucia lo que el gate
# protege es peor que uno que falla.
barre_el_banco() {
	local rc=$?
	set +e
	# El artefacto con nombre de fierro que este banco crea se retira SIEMPRE, con
	# su ruta literal y el run id dentro, falle o no: si se quedara, `make clean`
	# se negaria a barrer gate/out entero hasta que alguien lo sellara a mano.
	if [ -n "${OUT_LOCAL:-}" ] && [ -n "${RUN_ID:-}" ] && [ "${OUT_LOCAL}" = "${GATE_DIR}/out/p2-${RUN_ID}" ]; then
		rm -rf -- "${GATE_DIR}/out/p2-${RUN_ID}"
	elif [ -n "${OUT_LOCAL:-}" ]; then
		echo "p2-iron-test: NO retiro ${OUT_LOCAL}: no es la ruta que este banco sabe borrar" >&2
	fi
	if [ "${rc}" -eq 0 ] && [ "${FALLAS}" -eq 0 ]; then
		cd "${GATE_DIR}/out" && rm -rf p2-iron-test
		echo "p2-iron-test: todas las filas verdes; el banco y su artefacto se barren"
	else
		echo "p2-iron-test: ${FALLAS} filas en FALLA o un aborto; el banco queda en gate/out/p2-iron-test" >&2
	fi
}

[ -d "${BANCO}" ] && { cd "${GATE_DIR}/out" && rm -rf p2-iron-test; }
mkdir -p "${BANCO}/bin" "${BANCO}/casa" "${BANCO}/estado"
: > "${BANCO}/llave"
chmod 600 "${BANCO}/llave"

# ---- el stub de ssh y scp -----------------------------------------------------
#
# Cada host de mentira tiene su propia casa. El stub traduce la direccion a la
# casa y corre la orden ahi dentro, de verdad. Un host marcado "muerto" no
# contesta y sale con 255, que es lo que hace ssh cuando el transporte cae, y es
# el caso que separa NO de NO-SE-PUDO-LEER.
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
# Las rutas absolutas del kernel se reescriben a la casa de mentira: es la unica
# forma de que las primitivas se prueben TAL COMO ESTAN ESCRITAS, leyendo
# /proc/sys/kernel/..., en vez de con una version del guion adaptada al banco.
orden="$*"
orden="${orden//\/proc\//${casa}/proc/}"
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
	# Las dos lecturas del kernel van por su ruta ABSOLUTA, asi que la casa de
	# mentira las monta bajo su propio prefijo y el stub reescribe /proc dentro.
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
# Solo AHORA, con p2.sh ya cargado y sus nombres en su sitio, se arma la trampa.
trap barre_el_banco EXIT
echo "-- cargado en modo fierro: ES_FIERRO=${ES_FIERRO}, artefacto $(basename "${OUT_LOCAL}") --"
echo

# ---- 1 a 5: la lectura de sysrq, que no es una mascara plana -------------------
fila 1  "si" "$(sysrq_permite_reinicio 176 && echo si || echo no)" "sysrq=176, el valor real de naylamp-1, permite el reinicio"
fila 2  "si" "$(sysrq_permite_reinicio 1   && echo si || echo no)" "sysrq=1 habilita todas las funciones"
roja 3  "no" "$(sysrq_permite_reinicio 0   && echo si || echo no)" "sysrq=0 NO permite: el corte seria un no-op y todo verde de abajo mentiria"
roja 4  "no" "$(sysrq_permite_reinicio 16  && echo si || echo no)" "sysrq=16 es una mascara SIN el bit 128, y leerla como bitmask plano la daria por buena"
roja 5  "no" "$(sysrq_permite_reinicio 'cat: /proc/sys/kernel/sysrq: Permission denied' && echo si || echo no)" "una respuesta que no es un numero NO es un permiso"

# ---- 6 a 8: lineas_listening devuelve UNA linea, siempre ----------------------
FLEET="${BANCO}/flota"; mkdir -p "${FLEET}"
printf 'arranca\nnada aqui\n' > "${FLEET}/node1.log"
printf 'arranca\nlistening on x\n' > "${FLEET}/node2.log"
# El predicado es "el valor NO lleva un salto de linea dentro". Contar con wc -l
# sobre una salida sin salto final da 0 y no 1, y la primera version de estas
# filas lo escribio asi: un predicado que no mide lo que su texto dice, dentro
# del banco escrito para cazar justo eso.
saltos_en() { printf '%s' "$1" | tr -cd '\n' | wc -c | tr -d ' '; }
fila 6 "0" "$(saltos_en "$(lineas_listening 1)")" "log que existe SIN la linea: CERO saltos dentro del valor (el defecto metia uno)"
fila 7 "0" "$(lineas_listening 1)" "y su valor es 0"
fila 8 "1" "$(lineas_listening 2)" "log con la linea: 1"
fila 9 "0" "$(lineas_listening 9)" "log que no existe: 0"
fila 10 "1" "$( set +e; [ "$(lineas_listening 1)" -gt 0 ] >/dev/null 2>&1; echo $? )" "la comparacion devuelve 1, que es FALSO; antes devolvia 2, que es un error de sintaxis disfrazado de falso"

# ---- 11 y 12: entry_log_bytes tiene un tercer resultado, ILEGIBLE -------------
mkdir -p "${FLEET}/node1/data"
head -c 100 /dev/zero > "${FLEET}/node1/data/raft-1.log"
head -c 50  /dev/zero > "${FLEET}/node1/data/raft-2.log"
fila 11 "150" "$(entry_log_bytes 1)" "suma los segmentos legibles"
# El fichero ilegible se monta con un enlace simbolico CIRCULAR y no con chmod
# 000: la primera version usaba chmod y las filas 12 y 33 salian verdes por la
# razon equivocada, porque stat lee METADATOS y no contenido, asi que un fichero
# sin permisos de lectura sigue dando su tamano. Un bucle de enlaces hace fallar
# a stat de verdad, que es lo que estas filas quieren.
mkdir -p "${FLEET}/node2/data"
ln -sf "raft-1.log" "${FLEET}/node2/data/raft-1.log"
roja 12 "2" "$( entry_log_bytes 2 >/dev/null 2>&1; echo $? )" "un segmento que stat no puede leer devuelve 2, y no un total corto en silencio"

# ---- 13 y 14: el artefacto de fierro se llama p2-, que es lo que make clean protege
fila 13 "p2" "$(basename "${OUT_LOCAL}" | cut -d- -f1)" "en fierro el artefacto es p2-<run id>, o sea el que la guarda del Makefile exige sellado"
fila 14 "1" "$(printf '%s' "$(basename "${OUT_LOCAL}")" | grep -c '^p2-[0-9]')" "y NO p2-local-, que es el que make clean barre sin preguntar"

# ---- 15 a 17: el marcador RUNNING conoce el nombre de fierro ------------------
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

# ---- 18 a 21: las primitivas de fierro contra el stub ------------------------
fila 18 "aaaa-bbbb-cccc-0002" "$(boot_id_de 2)" "boot_id_de lee el boot id por el canal de tres estados"
: > "${BANCO}/estado/2.muerto"
roja 19 "2" "$( boot_id_de 2 >/dev/null 2>&1; echo $? )" "un host que no contesta devuelve 2, y NO una cadena vacia que pase por respuesta"
rm -f -- "${BANCO}/estado/2.muerto"
fila 20 "si" "$(ask_on 1 'true' && echo si || echo no)" "ask_on contesta SI sobre el host vivo"
fila 21 "176" "$(sysrq_de 1)" "sysrq_de trae el valor del host"

# ---- 22 a 25: el tercer testigo, que es lo que mide el corte ------------------
testigo_siembra 1 >/dev/null 2>&1
fila 22 "${TESTIGO_SEMILLA}" "$(testigo_tamano 1)" "sembrado y sincronizado: ${TESTIGO_SEMILLA} bytes durables por construccion"
testigo_arma 1 >/dev/null 2>&1
fila 23 "$(( TESTIGO_SEMILLA + TESTIGO_COLA ))" "$(testigo_tamano 1)" "armado: la cola sin sincronizar esta encima"
# un corte SECO se lleva la cola: se simula truncando a la semilla
head -c "${TESTIGO_SEMILLA}" /dev/zero > "${BANCO}/casa/1/${TESTIGO_REMOTO}"
fila 24 "${TESTIGO_SEMILLA}" "$(testigo_tamano 1)" "tras un corte seco vuelve a la semilla, que es la senal que el gate lee"
roja 25 "$(( TESTIGO_SEMILLA + TESTIGO_COLA ))" "$(testigo_siembra 2 >/dev/null 2>&1; testigo_arma 2 >/dev/null 2>&1; testigo_tamano 2)" "un testigo que vuelve ENTERO significa que ahi no se corto nada, y ese es el caso que no puede leerse como verde"

# ---- 26 a 31: LAS DECISIONES, llamando a las funciones DE gate/p2.sh ---------
#
# Estas filas eran aritmetica sobre literales escritos aqui, y un lector lo midio
# el 7 de septiembre de 2026: `cambiados=2; [ "${cambiados}" -ge 2 ]` demuestra
# que dos es al menos dos, no que este guion haga nada. Rebobinada la decision en
# p2.sh, las diez seguian verdes. Ahora las decisiones son funciones nombradas
# EN p2.sh y estas filas llaman a esas, asi que rebobinar el objeto pone la fila
# roja, que es lo unico que hace util a un banco.
fila 26 "2" "$(mayoria_de 3)" "mayoria_de(3) de p2.sh da 2, igual que cluster.Config.Quorum() en engine/cluster/config.go:87"
fila 27 "pasa" "$(faithful_suficiente 2 3 && echo pasa || echo cae)" "faithful_suficiente(2,3): dos copias frias fieles PASAN, la tercera puede no haber persistido"
roja 28 "cae" "$(faithful_suficiente 0 3 && echo pasa || echo cae)" "faithful_suficiente(0,3) CAE, que es donde el mutante sin barrera se queda"
roja 29 "cae" "$(faithful_suficiente 1 3 && echo pasa || echo cae)" "faithful_suficiente(1,3) tambien CAE: la mayoria no se relaja hasta volverse decorativa"

# ---- 30 y 31: la ventana, llamando a ventana_dentro de p2.sh ------------------
fila 30 "dentro" "$(ventana_dentro 1.2 && echo dentro || echo fuera)" "ventana_dentro(1.2) con la cota en ${VENTANA_MAX} s"
roja 31 "fuera" "$(ventana_dentro 31.0 && echo dentro || echo fuera)" "ventana_dentro(31.0) queda FUERA: con la raiz en commit=30 el diario pudo volcar la cola"

# ---- 32 a 35: LOS MUTANTES. Cada decision, rebobinada a lo que era ------------
echo
echo "-- mutantes: cada uno rebobina una decision del 7 de septiembre de 2026 --"

# 32: lineas_listening rebobinada al || echo 0
viejo_listening() { grep -c 'listening' "${FLEET}/node$1.log" 2>/dev/null || echo 0; }
roja 32 "2" "$(viejo_listening 1 | wc -l | tr -d ' ')" "MUTANTE: con el || echo 0 la funcion devuelve DOS lineas y la comparacion revienta"

# 33 y 33b: entry_log_bytes rebobinada a la forma fail-open.
#
# LA PRIMERA VERSION DE ESTA FILA MEDIA OTRA COSA, y lo cazo un lector: montaba
# el fichero ilegible con un enlace CIRCULAR, para el que `[ -e ]` es falso, asi
# que el `continue` saltaba y la linea de la aritmetica NO SE EJECUTABA. La fila
# salia verde por el salto y no por la sustitucion vacia, que es justo el defecto
# que dice rebobinar. Es un caso del error que este banco existe para cazar,
# dentro del banco. Ahora hay dos filas y cada una monta su caso:
#   33  el nombre existe y no resuelve, que es lo que el `-L` de p2.sh caza
#   33b el fichero SI resuelve y `stat` falla igualmente, que es el unico montaje
#       en el que la aritmetica llega a correr y se ve el operando vacio
viejo_bytes() {
	local n="$1" t=0 f
	for f in "${FLEET}/node${n}/data"/raft-*.log; do
		[ -e "${f}" ] || continue
		t=$(( t + $(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}" 2>/dev/null) )) 2>/dev/null
	done
	printf '%d' "${t}"
}
roja 33 "0" "$(viejo_bytes 2 2>/dev/null)" "MUTANTE: la forma vieja devuelve 0 sobre el segmento que no resuelve, o sea 'el log encogio'"

# El stub de stat sale 1 SIEMPRE, con el fichero presente y legible, que es la
# unica forma de que la sustitucion vuelva vacia y la aritmetica se ejecute.
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
# El `set +e` va porque p2.sh trae `set -euo pipefail` consigo al cargarse, y sin
# el la propia funcion que devuelve 2, que es lo que esta fila quiere ver, mata
# la subshell antes del `echo $?`. La primera version de esta fila abortaba el
# banco entero ahi, o sea que la fila escrita para medir un fail-open se moria
# por el modo estricto del objeto que estaba midiendo.
salida_33c="$(PATH="${BANCO}/bin-stat:${PATH}" bash -c 'source "'"${GATE_DIR}"'/p2.sh" >/dev/null 2>&1; set +e; FLEET="'"${FLEET}"'"; entry_log_bytes 3 >/dev/null 2>&1; echo $?' 2>/dev/null)"
fila 33c "2" "${salida_33c}" "y la forma de hoy, en el MISMO montaje, devuelve 2 en vez de un total corto"

# 34 y 35: el umbral del corte. La roja rebobina corte_completo a un umbral de
# dos, escribiendola aqui como estaba en el arbol; la verde llama a la DE p2.sh.
corte_completo_viejo() { [ "$1" -ge 2 ]; }
roja 34 "acepta" "$(corte_completo_viejo 2 3 && echo acepta || echo rechaza)" "MUTANTE: con umbral de DOS, dos boot id cambiados bastan y la superviviente cura a las otras"
fila 35 "rechaza" "$(corte_completo 2 3 && echo acepta || echo rechaza)" "corte_completo(2,3) de p2.sh RECHAZA: la decision del 7 de septiembre de 2026 exige las tres"
fila 36 "acepta" "$(corte_completo 3 3 && echo acepta || echo rechaza)" "y corte_completo(3,3) acepta, para que la fila de arriba no pase por ser siempre negativa"

# 37: faithful rebobinada a exigir las tres, contra la de p2.sh
faithful_viejo() { [ "$1" -eq "$2" ]; }
roja 37 "cae" "$(faithful_viejo 2 3 && echo pasa || echo cae)" "MUTANTE: exigir las TRES pone rojo un hardware sano, porque Raft ackea con dos"

# 38 y 39: la identidad por ruta contra la identidad por contenido, con la de p2.sh
roja 38 "no-distingue" "$(identidad_confirmada deadbeef deadbeef && echo distingue || echo no-distingue)" "identidad_confirmada con el MISMO sha no distingue: un mutante sobre el nombre sano tiene la misma ruta y el mismo contenido no"
fila 39 "distingue" "$(identidad_confirmada cafe1234 deadbeef && echo distingue || echo no-distingue)" "identidad_confirmada de p2.sh separa contenidos distintos"
roja 39b "no-distingue" "$(identidad_confirmada "" deadbeef && echo distingue || echo no-distingue)" "y una lectura VACIA no cuenta como distinta: un pid muerto no confirma nada"

# 39c a 39f: testigo_veredicto de p2.sh, sus cuatro salidas
fila 39c "seco"         "$(testigo_veredicto 4096 4096 65536)"  "testigo_veredicto: la semilla sola es un corte SECO"
fila 39d "entero"       "$(testigo_veredicto 69632 4096 65536)" "el total es ENTERO, o sea que ahi no se corto"
fila 39e "parcial"      "$(testigo_veredicto 30000 4096 65536)" "a medias sigue siendo un corte"
roja 39f "bajo-semilla" "$(testigo_veredicto 100 4096 65536)"   "por DEBAJO de la semilla sincronizada no es un corte seco: es una barrera rota bajo el sistema de ficheros"
roja 39g "ilegible"     "$(testigo_veredicto "" 4096 65536)"    "y una lectura vacia es ILEGIBLE, no cero"

# ---- 42 a 45: el estado del cliente REMOTO, que en fierro viene por el texto --
#
# En fierro el cliente corre dentro del host 1 y su codigo de salida vuelve como
# una linea, porque ssh mezcla el estado del transporte con el del programa. La
# primera version buscaba __RC__=0 EN CUALQUIER PARTE del flujo, o sea que la
# salida del propio cliente podia decidir el veredicto: un canal de estado que la
# carga puede falsificar no es un canal de estado. Se lee la ULTIMA linea entera.
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

# ---- 40: el mutante NO aterriza en el path que mide el omnibus ----------------
fila 40 "0" "$(printf '%s' "${MUT_REMOTO}" | grep -c '^naylamp/bin/naylampd$')" "el mutante NO va a naylamp/bin/naylampd, que es lo que record_binary_digests lee en gate/omnibus.sh:589"
fila 41 "1" "$(printf '%s' "${MUT_REMOTO}" | grep -c 'naylampd-mutante')" "va a su propio nombre"

echo
echo "=============================================================================="
echo "RESULTADO: ${FILAS} filas, ${ROJAS} de ellas rojas, ${FALLAS} en FALLA"
echo "LO QUE ESTE BANCO NO CUBRE, y va escrito: no enciende una VM, no dispara un"
echo "sysrq-b de verdad y no mide un corte real. Prueba los PREDICADOS del camino de"
echo "fierro y sus mutantes; la primera corrida de fierro es la que los prueba en"
echo "anger, y eso es un limite declarado y no un descuido."
echo "=============================================================================="
[ "${FALLAS}" -eq 0 ] || exit 1
exit 0
