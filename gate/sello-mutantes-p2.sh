#!/usr/bin/env bash
# Barrido de mutantes sobre el sello de gate/p2.sh (DEFER-098).
#
# QUE MIDE. Cada mutante rebobina UNA decision del sello y se corre el banco
# gate/p2-iron-test.sh contra el arbol mutado. Lo que se publica es que filas
# CAEN: un mutante que no tumba ninguna fila es una decision que el banco no
# vigila, y esa es toda la pregunta.
#
# EL ARBOL MUTADO ES UNA COPIA Y NO EL DE TRABAJO. Se copia gate/ SIN gate/out,
# que son 183 MiB de artefactos, y el banco crea el suyo dentro de la copia.
#
# VIVE EN EL ARBOL Y NO EN EL WORKSPACE, y la primera version estaba al reves.
# El argumento para dejarlo fuera era que esto no es una guarda sino el
# instrumento que MIDE una guarda, y eso sigue siendo cierto; lo que no se sostuvo
# es la conclusion. Un fichero nuevo en el workspace pone en rojo la regla dura de
# DEFER-079, que pide una copia anterior de todo lo que se toca y no sabe separar
# un fichero nuevo de uno viejo que nadie copio; su propio comentario lo dice. Y
# el argumento de fondo es mejor que el de forma: la frase "los mutantes muerden" no vale nada si quien la lee no puede volver a derivarla. Aqui puede,
# contra el mismo arbol, con una orden.
#
# NO ES UN PASO DE CI, y esto se decide midiendo y no por costumbre. LO QUE CUESTA
# LO IMPRIME EL PROPIO BARRIDO en su ultima linea, y por eso no hay ninguna cifra
# escrita aqui: un numero de reloj guardado en un comentario envejece en cuanto se
# anade un mutante o le crece una fila al banco, y a este le han pasado las dos
# cosas en un dia. Cabria en un flujo de sobra. Lo que no cabe es su FORMA: cada
# mutante casa una CADENA EXACTA de gate/p2.sh y se para si no la encuentra UNA
# sola vez, que es lo que lo hace honesto a mano y venenoso en un flujo. Cualquier
# edicion legitima de esas lineas volveria roja la rama con un mensaje sobre el
# barrido y no sobre el cambio, y un CI que se pone rojo por trabajar se apaga. Se
# corre a mano cuando se toca el sello, que es justo cuando su respuesta importa.
#
# Uso:
#   bash gate/sello-mutantes-p2.sh <ruta del repositorio> <directorio padre>
set -uo pipefail

# EL BORRADO NO TOMA SU RUTA DE UN ARGUMENTO, y la primera version de este guion si:
# hacia `rm -rf -- "$2"` sobre lo que le pasaran. Eso es la clausula 23 rota en el
# sitio mas caro, porque la salida de esa clausula es que una ruta que puede hacer
# dano se escriba literal o se VALIDE antes de la orden. Aqui se hace lo segundo y
# ademas se le quita el filo: el segundo argumento es un directorio PADRE que tiene
# que existir ya, y el taller es un hijo suyo con un nombre que este guion elige y
# que lleva su pid dentro. Lo que se borra es siempre esa ruta construida por el
# guion, nunca la que le den, y se comprueba que lo es antes de borrarla.
#
# Y SE NIEGA EN VOZ ALTA SIN ARGUMENTOS en vez de morir con un `$1: unbound
# variable`, que es lo que hacia. Un guion que se rompe con el error crudo del shell
# no dice que hacer, y su estado de salida se confunde con el de una medida.
if [ "$#" -lt 2 ]; then
	cat >&2 <<'USO'
uso: bash gate/sello-mutantes-p2.sh <ruta del repositorio> <directorio padre para el taller>

  El taller se crea DENTRO del padre, con un nombre propio y el pid dentro, y es
  lo unico que este guion borra. El padre tiene que existir ya y no se toca.

  Sale 0 si el control queda en cero y ningun mutante sale mudo, 1 si no, y 2 si
  la comprobacion no se pudo hacer, que no es ni pase ni fallo.
USO
	exit 2
fi
REPO="$1"
PADRE="$2"
[ -d "${REPO}/gate" ] && [ -f "${REPO}/go.work" ] || {
	echo "sello-mutantes: ${REPO} no parece la raiz de este repositorio" >&2; exit 2; }
[ -d "${PADRE}" ] || {
	echo "sello-mutantes: ${PADRE} no existe, y este guion no crea el directorio padre" >&2; exit 2; }
TALLER="${PADRE}/naylamp-sello-mutantes-$$"
case "${TALLER}" in
	"${PADRE}/naylamp-sello-mutantes-"[0-9]*) ;;
	*) echo "sello-mutantes: el taller ${TALLER} no tiene la forma por la que este guion borra" >&2; exit 2 ;;
esac
rm -rf -- "${PADRE}/naylamp-sello-mutantes-$$"; mkdir -p "${TALLER}/gate/out"
for f in "${REPO}"/gate/*.sh "${REPO}"/gate/*.txt; do cp "${f}" "${TALLER}/gate/"; done
cp "${REPO}/go.work" "${TALLER}/" 2>/dev/null || true

T_INICIO="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || echo 0)"
echo "BARRIDO DE MUTANTES: el sello de gate/p2.sh contra gate/p2-iron-test.sh"
echo "fecha: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "maquina: $(sysctl -n hw.model 2>/dev/null || uname -m), $(uname -sr)"
echo "arbol: $(cd "${REPO}" && git rev-parse --short HEAD), $(cd "${REPO}" && git status --porcelain | wc -l | tr -d ' ') entradas sin commitear"
echo "taller: ${TALLER}"
echo

CONTROL=0; MUTANTES=0; MUDOS=0; MITADES=0; MITADES_MAL=0
corre() {
	# NINGUNA RUTA DE ESTA MAQUINA AQUI, y la primera version llevaba una: el
	# directorio del toolchain de quien lo escribio, pegado al PATH. Un guion
	# versionado con la ruta de una maquina dentro es un guion que solo corre en esa
	# maquina y no lo dice. Medido: gate/p2-iron-test.sh no invoca go ni una vez, asi
	# que el PATH heredado basta; y si algun dia lo invocara, fallar diciendo "go: no
	# such file" es mejor que correr con el toolchain equivocado en silencio.
	bash "${TALLER}/gate/p2-iron-test.sh" 2>/dev/null
}
control() {
	cp "${REPO}/gate/p2.sh" "${TALLER}/gate/p2.sh"
	local n salida
	salida="$(corre)"
	n="$(printf '%s' "${salida}" | grep -cE '^FILA .* FALLA ' || true)"
	CONTROL="${n}"
	if ! printf '%s' "${salida}" | grep -q '^RESULTADO: '; then
		echo "CONTROL   sin mutar: el banco ABORTA. Sin control verde este barrido no dice nada" >&2
		CONTROL=-1
		return
	fi
	printf 'CONTROL   sin mutar: %s filas en FALLA, y el banco llega a su resumen\n' "${n}"
	echo
}
# LA MUTACION SE APLICA EN UN SOLO SITIO, y antes vivia copiada dentro de `mutante`.
# Al entrar `mitad` habria hecho falta una segunda copia del mismo heredoc, y dos
# copias de un predicado son dos sitios donde corregirlo: la clase que este registro
# persigue con nombre propio. Se saca a funcion y las dos la llaman.
aplica_mutacion() {
	/usr/bin/python3 - "$1" "$2" "$3" <<'FINDELPYTHON'
import sys
p, viejo, nuevo = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
if s.count(viejo) != 1:
    sys.stderr.write('la mutacion no muerde donde este barrido cree: %d apariciones\n' % s.count(viejo))
    raise SystemExit(3)
open(p, 'w', encoding='utf-8').write(s.replace(viejo, nuevo))
FINDELPYTHON
}

# UN TERCER DESENLACE, y entra el 8 de septiembre de 2026 porque los dos que habia
# no bastaban para decir la verdad. Una propiedad puede estar defendida por DOS
# guardas independientes, y entonces un mutante que quita SOLO UNA sale mudo sin que
# eso signifique que nadie la vigila: significa que la otra la para. Contarlo como
# FALLA es la clausula 15 otra vez, un instrumento que contesta lo contrario de lo
# que pasa. `mitad` declara ese caso: se ESPERA mudo, y lo que si es un hallazgo es
# que MUERDA, porque entonces la defensa no era doble y la prosa que lo dice esta
# mal. La mitad que rompe la propiedad de verdad, quitando las dos, va aparte y como
# mutante ordinario.
mitad() {
	local etiqueta="$1" viejo="$2" nuevo="$3" glosa="$4" salida caidas
	MUTANTES=$((MUTANTES + 1))
	MITADES=$((MITADES + 1))
	cp "${REPO}/gate/p2.sh" "${TALLER}/gate/p2.sh"
	if ! aplica_mutacion "${TALLER}/gate/p2.sh" "${viejo}" "${nuevo}"; then
		printf '%-5s FALLO DE MONTAJE: la mutacion no se pudo aplicar   %s\n' "${etiqueta}" "${glosa}"
		MITADES_MAL=$((MITADES_MAL + 1))
		return
	fi
	salida="$(corre)"
	caidas="$(printf '%s' "${salida}" | grep -E '^FILA .* FALLA ' | awk '{print $2}' | tr '\n' ' ')"
	if ! printf '%s' "${salida}" | grep -q '^RESULTADO: '; then
		printf '%-5s INESPERADO  el banco ABORTA con media guarda quitada   %s\n' "${etiqueta}" "${glosa}"
		MITADES_MAL=$((MITADES_MAL + 1))
	elif [ -z "${caidas}" ]; then
		printf '%-5s MITAD  mudo COMO SE ESPERA: la otra guarda sola lo para   %s\n' "${etiqueta}" "${glosa}"
	else
		printf '%-5s INESPERADO  MUERDE, caen: %-14s la defensa NO era doble   %s\n' "${etiqueta}" "${caidas}" "${glosa}"
		MITADES_MAL=$((MITADES_MAL + 1))
	fi
}

mutante() {
	local etiqueta="$1" viejo="$2" nuevo="$3" caidas
	MUTANTES=$((MUTANTES + 1))
	cp "${REPO}/gate/p2.sh" "${TALLER}/gate/p2.sh"
	if ! aplica_mutacion "${TALLER}/gate/p2.sh" "${viejo}" "${nuevo}"; then
		printf '%-5s FALLO DE MONTAJE: la mutacion no se pudo aplicar   %s\n' "${etiqueta}" "$4"
		MUDOS=$((MUDOS + 1))
		return
	fi
	local salida
	salida="$(corre)"
	caidas="$(printf '%s' "${salida}" | grep -E '^FILA .* FALLA ' | awk '{print $2}' | tr '\n' ' ')"
	if ! printf '%s' "${salida}" | grep -q '^RESULTADO: '; then
		printf '%-5s MUERDE  el banco ABORTA y no llega a su resumen   %s\n' "${etiqueta}" "$4"
	elif [ -z "${caidas}" ]; then
		printf '%-5s MUDO  NINGUNA FILA CAE   <-- la decision no la vigila nadie   %s\n' "${etiqueta}" "$4"
		MUDOS=$((MUDOS + 1))
	else
		printf '%-5s MUERDE  caen: %-18s %s\n' "${etiqueta}" "${caidas}" "$4"
	fi
}

control

mutante M1 '
	seal_artifact
	# LA CONDICION PREGUNTA SI HABIA ALGO QUE SELLAR.' '
	# MUTANTE M1: sellar DESPUES de barrer
	# LA CONDICION PREGUNTA SI HABIA ALGO QUE SELLAR.' 'sellar DESPUES de barrer, no antes'

mutante M2 '			[ -n "$(ls -A "${d}" 2>/dev/null | grep -vx RUNNING)" ] || continue' \
'			[ -n "$(ls -A "${d}" 2>/dev/null)" ] || continue' 'el barrido cuenta el marcador RUNNING como contenido'

mutante M3 "					printf 'closed:      %s\n' \"\${marca}\" ;;" '					;;' 'el sello se termina SIN linea closed'

mutante M4 "					printf 'verdicts:    %s\n' \"\${VERDICTS# }\"" "					printf '%s\n' \"\${linea}\"" 'el sello se termina sin reescribir los veredictos'

mutante M5 '	[ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ] || return 0
	if [ -e "${OUT_LOCAL}/SEALED" ]; then' '	if [ -e "${OUT_LOCAL}/SEALED" ]; then' 'seal_artifact sella tambien un artefacto vacio'

mutante M6 '	elif [ "$(grep -m1 '"'"'^expected:'"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" = "${esperada}" ] \
		&& [ "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" -ge "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED" 2>/dev/null)" ]; then' \
'	elif true; then' 'se quita ENTERA la condicion que decide si la reescritura se publica'

mutante M6b '		&& [ "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" -ge "$(grep -c '"'"''"'"' "${OUT_DIR}/p2-${RUN_ID}/SEALED" 2>/dev/null)" ]; then' \
'		; then' 'solo la mitad del RECUENTO de lineas de esa condicion'

mutante M7 '		[ "${SELLO_ESCRITO_AQUI}" -eq 1 ] && return 0
		echo "gate: ${OUT_LOCAL}/SEALED exists and THIS run did not write it, so nothing here is touched and no seal is completed" >&2
		return 0' '		return 0' 'se quita la rama que confiesa un sello que esta corrida no escribio'

mutante M8 '	case "${OUT_LOCAL}" in
		"${OUT_DIR}/p2-${RUN_ID}") ;;
		*)
			echo "gate: the seal was written but NOT completed: ${OUT_LOCAL} is not p2-${RUN_ID}" >&2
			return 0 ;;
	esac' '	:' 'completa_el_sello acepta cualquier nombre de artefacto'

mutante M9 '		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: the rewrite did not match the seal it came from, so nothing was moved on top of it" >&2' \
'		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: the rewrite did not match the seal it came from, so nothing was moved on top of it" >&2' \
'la rama del rechazo BORRA el sello en vez del fichero de al lado'

mutante M10 '	elif [ "${vistas}" -eq 0 ]; then
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal has no verdicts line, so it was left exactly as it was and carries no closed line" >&2' \
'	elif false; then
		:' 'se quita la anti-vacuidad del sello sin linea verdicts'

mutante M11 '	[ "${SELLO_ESCRITO_AQUI}" -eq 1 ] || return 0
	[ -f "${OUT_LOCAL}/SEALED" ] || return 0' '	[ -f "${OUT_LOCAL}/SEALED" ] || return 0' \
'completa_el_sello sin la bandera de la clausula 30'

# M12 ENTRA POR UN LECTOR, y su hallazgo era este: de las tres filas de rechazo,
# la 17p no la respaldaba ningun mutante, asi que estaba escrita por prevision y
# la prosa decia lo contrario. Este mutante la respalda: quita la rama que
# distingue "no se pudo escribir al lado" de las demas negativas, con lo que un
# directorio sin permiso cae en la rama de abajo y la funcion confiesa la causa
# equivocada.
mutante M12 '	if [ ! -s "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" ]; then
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: nothing could be written beside it, so that seal now looks like one from a run that did not reach its end, and there is no way to say otherwise from inside a directory that cannot be written" >&2
	elif [ "${vistas}" -eq 0 ]; then' '	if [ "${vistas}" -eq 0 ]; then' \
'se quita la rama que separa "no se pudo escribir al lado" de las demas negativas'

# M18 REBOBINA EL DEFECTO MAS GRAVE QUE ESTA PASADA ENCONTRO, y no lo encontro un
# banco: lo encontro un lector leyendo el guion. El `ask_on` desnudo seguido de
# `rc_a=$?` mataba phase_hygiene_fierro en la primera vuelta bajo `set -e`, con lo
# que el barrido del sello nunca corria en fierro. Solo la fila 17r puede verlo,
# porque es la unica que corre la fase entera en vez de llamar a las funciones del
# sello una a una.
mutante M18 '		rc_a="$(ask_on "$n" '"'"'pid=$(cat naylamp/naylampd-mutante.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'"'"'; echo $?)"' \
'		ask_on "$n" '"'"'pid=$(cat naylamp/naylampd-mutante.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'"'"'
		rc_a=$?' \
'el ask_on del primer bucle de la higiene de fierro vuelve a ser una orden desnuda'

# M13 Y M14 CIERRAN LAS DOS ULTIMAS FILAS QUE NINGUN MUTANTE TOCABA de las que si
# son alcanzables. Las que quedan sin mutante detras van dichas en la cabecera del
# banco y son, todas, la mitad DESCRIPTIVA de un par: 17c y 17d son el "despues" y
# el "antes" de 17b y 17e, 17h afirma la ausencia de restos en el camino feliz,
# donde no hay resto que dejar, y 17f mide la identidad byte a byte de `expected:`,
# que no es alcanzable desde fuera de la funcion y se declara por escrito.
mutante M13 '		fail "P2.hygiene: p2 iron artifacts under gate/out with no SEALED file, which make clean will refuse to sweep:${sin}"' \
'		note "P2.hygiene: p2 iron artifacts under gate/out with no SEALED file:${sin}"' \
'el barrido NOMBRA los artefactos sin sello pero deja de poner roja la fase'

mutante M14 '	if [ "${ES_FIERRO}" -eq 1 ] && [ ! -e "${OUT_LOCAL}/SEALED" ] \
		&& [ -d "${OUT_LOCAL}" ] && [ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ]; then' \
'	if [ "${ES_FIERRO}" -eq 1 ]; then' \
'la linea de "esta corrida no sello" salta sin preguntar si hay sello ni si habia algo que sellar'

# M15 A M17 ENTRAN POR EL MISMO LECTOR QUE MIDIO LAS DECISIONES MUDAS: tres guardas
# escritas que ninguna fila tumbaba. Cada una tiene ahora su fila y su mutante.
mutante M15 '	if [ "${ES_FIERRO}" -eq 1 ] && [ ! -e "${OUT_LOCAL}/SEALED" ] \
		&& [ -d "${OUT_LOCAL}" ] && [ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ]; then
		fail "P2.hygiene: this run wrote an artifact and did not seal it, so make clean will refuse to sweep gate/out until somebody seals it by hand"
	fi' '	:' \
'se quita ENTERA la unica guarda que habla de la corrida en curso'

mutante M16 '		while IFS= read -r linea || [ -n "${linea}" ]; do' '		while IFS= read -r linea; do' \
'la reescritura pierde la ultima linea cuando no termina en salto'

mutante M17 '	if [ ! -s "${OUT_LOCAL}/SEALED" ]; then
		rm -f -- "${OUT_LOCAL}/SEALED"
		echo "gate: the seal could NOT be written at ${OUT_LOCAL}/SEALED, so this run'"'"'s artifact is unsealed and make clean will refuse to sweep gate/out" >&2
		return 0
	fi' '	:' \
'seal_artifact anuncia el sello sin comprobar que llego a escribirse'

# M19 A M23: EL TECHO DE LOS ARTEFACTOS DE ENSAYO, que entra el 8 de septiembre de
# 2026 con la decision de quien encarga. Cada uno rebobina una mitad distinta y la
# fila que lo caza va escrita al lado.
mutante M19 '		[ "${nombre}" = "${propio}" ] && continue' '		:' \
'el techo puede llevarse el artefacto de la corrida EN CURSO'

mutante M20 '		[ "${n}" -le "${CONSERVA_ENSAYOS}" ] && continue' '		[ "${n}" -le 0 ] && continue' \
'el techo baja a cero y se lleva todo lo que no sea de esta corrida'

mutante M21 '	[ "${ES_FIERRO}" -eq 1 ] && { printf '"'"'0'"'"'; return 0; }' '	:' \
'el barrido del ensayo tambien corre en una corrida de fierro'

# M22 TIENE QUE QUITAR LAS DOS GUARDAS A LA VEZ, y las dos versiones anteriores
# quitaban una cada una y salieron MUDAS las dos. Eso no era un agujero: la
# propiedad "el techo nunca toca un artefacto de fierro" la defienden DOS guardas
# INDEPENDIENTES, el patron del `ls` que decide que se mira y el `case` que decide
# que se borra, y con cualquiera de las dos en pie el fierro sobrevive. Ensanchar el
# patron sola deja el `case` refusando con su aviso; quitar el `case` sola deja el
# patron sin traer un solo nombre de fierro al bucle. **Que un mutante salga mudo
# porque OTRA guarda lo para no es lo mismo que salir mudo porque nadie mira**, y la
# unica forma de separar las dos cosas es un mutante que las quite juntas. Este las
# quita, y la fila 17x cae. Las dos versiones mudas van nombradas aqui en vez de
# borradas, porque la conclusion util es que esa propiedad tiene defensa doble y eso
# solo se sabe habiendolo medido.
mitad M22 '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-local-[0-9]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue' '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-[0-9a-z]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue' \
'PRIMERA MITAD: el patron del techo se ensancha y trae los artefactos de FIERRO al bucle'

mitad M22b '		case "${nombre}" in
			p2-local-[0-9]*Z-[0-9]*)
				rm -rf -- "${OUT_DIR}/${nombre}"
				retirados=$((retirados + 1)) ;;
			*)
				echo "gate: NO retiro ${d}: no es un artefacto de ensayo de este gate" >&2 ;;
		esac' '		rm -rf -- "${OUT_DIR}/${nombre}"
		retirados=$((retirados + 1))' \
'SEGUNDA MITAD: se quita el case que refusa lo que no es un nombre de ensayo'

mutante M22c '	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-local-[0-9]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue
		# EL DE ESTA CORRIDA NUNCA, y se excluye POR NOMBRE y no por confiar en que
		# sea el mas reciente. El banco se apoya en que el suyo es el mas nuevo; eso
		# es cierto hasta el dia que dos corridas se solapan, y entonces una borra el
		# artefacto vivo de la otra. Una exclusion explicita no tiene ese dia.
		[ "${nombre}" = "${propio}" ] && continue
		n=$((n + 1))
		[ "${n}" -le "${CONSERVA_ENSAYOS}" ] && continue
		# Clausula 23: la ruta se compone de OUT_DIR mas un nombre que se acaba de
		# comprobar contra la forma exacta por la que este guion borra, y lo que no
		# sea esa forma se dice en voz alta en vez de borrarse.
		case "${nombre}" in
			p2-local-[0-9]*Z-[0-9]*)
				rm -rf -- "${OUT_DIR}/${nombre}"
				retirados=$((retirados + 1)) ;;
			*)
				echo "gate: NO retiro ${d}: no es un artefacto de ensayo de este gate" >&2 ;;
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
'LAS DOS A LA VEZ: el techo mira todo lo que empiece por p2- y borra sin comprobar la forma'

mutante M23 '		[ -d "${OUT_DIR}/p2-local-${id}" ] && continue' '		:' \
'la flota se retira aunque su artefacto siga ahi'

echo
# LA LINEA DE RESULTADO EN LA FORMA DE LA CASA, `RESULTADO: <n> filas, <n> en
# FALLA`, y no en una propia. Una fila de este barrido es UN MUTANTE, y una FALLA
# es un mutante MUDO: una decision que ninguna fila del banco vigila. Se escribe
# asi porque las cifras de un mensaje de commit se re-derivan del crudo con
# gate/msg-cifras.sh, y ese paso lee el total por esta forma exacta; una linea de
# resumen con forma propia le daba un total de cero y el paso rechazaba el
# mensaje por una cifra que el crudo si tiene y decia de otra manera.
echo "y el CONTROL sin mutar dio ${CONTROL} filas en FALLA sobre el banco entero"
if [ "${MITADES}" -ne 0 ]; then
	echo "${MITADES} de esos son MITADES de una defensa doble: se esperan mudos, y ${MITADES_MAL} salieron de otra forma"
fi
T_FIN="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || echo 0)"
/usr/bin/python3 -c "print('reloj: %.1f s de punta a punta, %s corridas del banco, la del control incluida' % (${T_FIN} - ${T_INICIO}, ${MUTANTES} + 1))" 2>/dev/null || true
echo "RESULTADO: ${MUTANTES} filas, $((MUDOS + MITADES_MAL)) en FALLA"
rm -rf -- "${PADRE}/naylamp-sello-mutantes-$$"
[ "${MUDOS}" -eq 0 ] && [ "${MITADES_MAL}" -eq 0 ] && [ "${CONTROL}" -eq 0 ] || exit 1
exit 0
