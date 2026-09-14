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
# Y LAS FUENTES DEL MOTOR, que hasta el 9 de septiembre de 2026 no venian. El
# taller llevaba `gate/` y nada mas, y eso basto mientras el banco solo se miraba a
# si mismo. Dejo de bastar en cuanto entro una fila que CASTEA un literal contra el
# objeto que lo produce: la 17db saca `LITERAL_LIDER` de `caliente()` y lo busca en
# `engine/`, y en un taller sin `engine/` esa columna sale `no` SIEMPRE. El sintoma
# fue inmediato y feo: `17db` aparecia en la lista de filas caidas de TODOS los
# mutantes, incluidos los que no tocan nada suyo, o sea que el barrido estaba
# midiendo un banco corriendo en un arbol roto y llamandolo mordisco. Se copian
# solo los `.go`, que son 144 ficheros y 1.3 MB; no se compila nada aqui.
(cd "${REPO}" && find engine -name '*.go' -print0) | while IFS= read -r -d '' g; do
	mkdir -p "${TALLER}/$(dirname "${g}")"
	cp "${REPO}/${g}" "${TALLER}/${g}"
done

# LOS IDS TIENEN QUE SER UNICOS, Y SE COMPRUEBA ANTES DE GASTAR DIECIOCHO MINUTOS.
# El 9 de septiembre de 2026 se anadieron cuatro mutantes eligiendo `M51`, `M52` y
# `M53`, que ya existian -dos como mutantes y uno como MITAD-. Nada fallo: el
# barrido corrio los ocho y publico su informe con TRES PARES DE LINEAS HOMONIMAS,
# cada par diciendo cosas distintas y sin forma de saber cual era cual. Un informe
# asi no es re-derivable, que es lo unico que este guion produce. La guarda es
# ESTATICA y va antes de copiar nada, porque el fallo se conoce leyendo el fichero
# y hacerlo esperar al final costaria la corrida entera para decir lo mismo.
IDS_REPES="$(grep -oE '^(mutante|mitad) M[0-9a-z]+' "$0" | awk '{print $2}' | sort | uniq -d | tr '\n' ' ')"
if [ -n "${IDS_REPES%% }" ] && [ -n "${IDS_REPES}" ]; then
	echo "sello-mutantes: hay ids de mutante repetidos y el informe no se podria leer: ${IDS_REPES}" >&2
	echo "sello-mutantes: cada mutante o mitad lleva un id propio; el mayor en uso se ve con grep -oE '^(mutante|mitad) M[0-9]+' sobre este fichero" >&2
	exit 2
fi

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
	# EL CONTROL RESTAURA TODOS LOS GUIONES y no solo p2.sh, desde que el barrido
	# puede mutar mas de uno: si no, el ultimo mutante del preflight se quedaria
	# puesto y el control mediria un arbol que no es el del repositorio.
	for f in "${REPO}"/gate/*.sh; do cp "${f}" "${TALLER}/gate/"; done
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
	local objeto="${5:-p2.sh}"
	MUTANTES=$((MUTANTES + 1))
	MITADES=$((MITADES + 1))
	for f in "${REPO}"/gate/*.sh; do cp "${f}" "${TALLER}/gate/"; done
	cp "${REPO}/gate/${objeto}" "${TALLER}/gate/${objeto}"
	if ! aplica_mutacion "${TALLER}/gate/${objeto}" "${viejo}" "${nuevo}"; then
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
	# EL QUINTO ARGUMENTO ES EL FICHERO, y por defecto es gate/p2.sh, que es donde
	# vive casi todo lo que este barrido mide. Entra el 9 de septiembre de 2026 con
	# los cinco bloqueantes del fierro: dos de ellos, el despliegue y el estado de
	# partida de los hosts, viven en gate/p2-preflight.sh, y un barrido que solo sabe
	# mutar un fichero no puede decir nada de sus filas. Se RESTAURA el fichero
	# mutado al terminar cada mutante, para que uno no se lleve al siguiente por
	# delante.
	local objeto="${5:-p2.sh}"
	MUTANTES=$((MUTANTES + 1))
	for f in "${REPO}"/gate/*.sh; do cp "${f}" "${TALLER}/gate/"; done
	cp "${REPO}/gate/${objeto}" "${TALLER}/gate/${objeto}"
	if ! aplica_mutacion "${TALLER}/gate/${objeto}" "${viejo}" "${nuevo}"; then
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
		# EL MARCADOR MANDA SOBRE EL TECHO, y esta es la linea que faltaba. Un
		# artefacto cuya corrida sigue VIVA no se retira por viejo: el techo es una
		# regla sobre lo que ya termino. Y el que lleva un marcador cuyo proceso murio
		# se retira, pero diciendolo, porque sus restos son informacion. La cuenta del
		# techo NO se le devuelve al vivo: ocupa su sitio en la ventana igual que
		# cualquier otro, y lo unico que cambia es que no se borra.
		case "$(marcador_de "${d}")" in
			vivo)
				echo "gate: NO retiro ${d}: su corrida sigue viva, con marcador y pid vivo dentro" >&2
				continue ;;
			ilegible)
				echo "gate: NO retiro ${d}: lleva un marcador con un pid que no se puede leer, y eso no es lo mismo que estar muerto" >&2
				continue ;;
			muerto)
				echo "gate: retiro ${d} por el techo: lleva el marcador de una corrida que no termino" >&2 ;;
		esac
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
'LAS DOS A LA VEZ: el techo mira todo lo que empiece por p2- y borra sin comprobar la forma ni el marcador'

mutante M23 '		[ -d "${OUT_DIR}/p2-local-${id}" ] && continue' '		:' \
'la flota se retira aunque su artefacto siga ahi'

# M24 A M27: EL MARCADOR SOBRE EL TECHO, que entra el 9 de septiembre de 2026
# despues de medir que el techo se llevaba una corrida viva. Cada uno rebobina una
# de las cuatro decisiones y la fila que lo caza va al lado.
mutante M24 '		case "$(marcador_de "${d}")" in
			vivo)
				echo "gate: NO retiro ${d}: su corrida sigue viva, con marcador y pid vivo dentro" >&2
				continue ;;
			ilegible)
				echo "gate: NO retiro ${d}: lleva un marcador con un pid que no se puede leer, y eso no es lo mismo que estar muerto" >&2
				continue ;;
			muerto)
				echo "gate: retiro ${d} por el techo: lleva el marcador de una corrida que no termino" >&2 ;;
		esac' '		:' \
'el techo vuelve a borrar por antiguedad sin mirar el marcador: el incidente por TERCERA vez'

mutante M25 '			ilegible)
				echo "gate: NO retiro ${d}: lleva un marcador con un pid que no se puede leer, y eso no es lo mismo que estar muerto" >&2
				continue ;;' '			ilegible) ;;' \
'un pid ilegible se trata como muerto: dos respuestas donde hay tres'

mutante M26 '	if kill -0 "${pid}" 2>/dev/null || ps -p "${pid}" >/dev/null 2>&1; then
		printf '"'"'vivo'"'"'
	else
		printf '"'"'muerto'"'"'
	fi' '	printf '"'"'muerto'"'"'' \
'marcador_de dice MUERTO siempre, o sea que ningun marcador protege'

mutante M27 '	[ -f "${d}/RUNNING" ] || { printf '"'"'sin-marcador'"'"'; return 0; }' '	[ -f "${d}/RUNNING" ] && { printf '"'"'vivo'"'"'; return 0; }' \
'el predicado pasa a ser el FICHERO y no el proceso: un marcador huerfano bloquea el techo para siempre'

# M28 A M37: LOS CINCO BLOQUEANTES DEL FIERRO, cada uno rebobinado a la forma que
# tenia cuando un lector externo los encontro. Dos de ellos viven en
# gate/p2-preflight.sh, que es por lo que este barrido aprendio a mutar mas de un
# fichero.
mutante M28 '	if [ "${ES_FIERRO}" -eq 1 ]; then
		banner_fierro
	else
		banner_ensayo
	fi' '	banner_ensayo' \
'el banner pierde su rama de fierro: el artefacto vuelve a declararse un ensayo de loopback'

mutante M29 '		if [ "${ES_FIERRO}" -eq 1 ]; then
			echo "gate: all IRON checks passed (${EXPECTED})"
		else
			echo "gate: all rehearsal checks passed (${EXPECTED})"
		fi' '		echo "gate: all rehearsal checks passed (${EXPECTED})"' \
'la ULTIMA linea del log vuelve a decir rehearsal en una corrida de fierro'

mutante M30 '		out="$(run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO} -group '"'"'${mgroup}'"'"' -dim ${DIM} -op put -id 7 -vec '"'"'$(vec_for 7)'"'"' ; echo __RC__=\$?" 2>&1)"' \
'		out="$("${BIN}" client -listen "${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO}" -group "${mgroup}" -dim "${DIM}" -op put -id 7 -vec "$(vec_for 7)" </dev/null 2>&1)"' \
'el cliente del mutante vuelve a correr en este portatil, contra una direccion que esta maquina no tiene'

# M31 REBOBINA EL DEFECTO Y NO ROMPE EL FICHERO, que es lo que hacia la primera
# version: cortaba el heredoc de python por la mitad y dejaba las comillas sin
# casar, asi que el banco moria de sintaxis. Eso cuenta como deteccion en este
# barrido, y esta bien que cuente, pero no es lo que se queria medir: un mutante
# tiene que dejar un guion que CORRE y hace lo de antes, no uno que no arranca.
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
'el testigo vuelve al sync GLOBAL: el instrumento anulando lo que mide'

mutante M32 '		if committed "${out}"; then
			echo "put ${id} ${vec} confirmed" >> "${MANIFEST}"' '		echo "put ${id} ${vec} uncertain" >> "${MANIFEST}"
		if committed "${out}"; then
			echo "put ${id} ${vec} confirmed" >> "${MANIFEST}"' \
'el escritor en vuelo anota uncertain ANTES de enviar: todos los ids quedan ambiguos, tambien los que volvieron con su ack'

mutante M33 '			seguidos=$(( seguidos + 1 ))
			[ "${seguidos}" -ge "${EN_VUELO_FALLOS_SEGUIDOS}" ] && break' '			seguidos=$(( seguidos + 1 ))' \
'el escritor en vuelo pierde su cota de fallos seguidos y sigue contra tres maquinas que ya no contestan'

mutante M34 '	if "${GATE_DIR}/deploy.sh" >/dev/null 2>&1; then' '	if true; then' \
'la mitad caliente deja de desplegar el binario y los certificados' p2-preflight.sh

mutante M35 '	if "${GATE_DIR}/cluster.sh" start >/dev/null 2>&1; then' '	if true; then' \
'la mitad caliente deja de levantar la flota' p2-preflight.sh

mutante M36 '	paso "naylamp/data, naylamp/logs y naylamp/data-mutante VACIOS en los tres, verificado y no supuesto"' \
'	paso "naylamp/data sin mirar"' \
'la mitad caliente deja de exigir el estado de partida de los hosts' p2-preflight.sh

mutante M37 '			'"'"'sudo -n test -w /proc/sysrq-trigger'"'"' >/dev/null 2>&1; then' \
'			'"'"'true'"'"' >/dev/null 2>&1; then' \
'el sudo del corte deja de ejercitarse antes del corte' p2-preflight.sh

# M38 A M44: LO QUE LA SEGUNDA VUELTA DEL LECTOR EXTERNO DESTAPO. Dos de estos
# rebobinan defectos que introdujo el arreglo anterior, o sea que este barrido
# vigila ahora tambien lo que la casa se rompio a si misma al arreglar.
mutante M38 '    if estado == INCIERTO:
        continue' '    pass' \
'el conjunto vivo vuelve a no mirar el estado: las lineas uncertain se exigen presentes y la corrida sale roja diciendo que el motor perdio una escritura ackeada'

mutante M39 'ID_EN_VUELO_DESDE=100' 'ID_EN_VUELO_DESDE=500' \
'el rango en vuelo vuelve al 500: el id 512 da el vector CERO y treinta ids colisionan con los de la carga'

mutante M40 '	choques="$(comprueba_rango_en_vuelo)"
	if [ "${choques}" != "0 0" ]; then' '	choques="0 0"
	if false; then' \
'la guarda del rango deja de correrse antes de escribir'

mutante M41 '		printf '"'"'%s %s\n'"'"' "${id}" "${vec}" >> "${OUT_LOCAL}/en-vuelo-enviados.txt"' '		:' \
'lo enviado deja de anotarse antes de enviarlo: una muerte entre el ack y su linea deja un id comprometido fuera del manifiesto'

mutante M42 '		grep -q "^put ${id} ${vec} confirmed\$" "${MANIFEST}" 2>/dev/null && continue
		grep -q "^put ${id} ${vec} uncertain\$" "${MANIFEST}" 2>/dev/null && continue' '		grep -q "^put ${id} ${vec} confirmed\$" "${MANIFEST}" 2>/dev/null && continue' \
'el pliegue deja de ser idempotente y duplica lineas al llamarse dos veces'

mutante M43 '	if [ "${acks_en_vuelo}" -gt 0 ]; then' '	if true; then' \
'P2.cut.envuelo pasa a verde sin que haya habido un solo ack en vuelo'

mutante M44 '	# shellcheck disable=SC2086
	wait ${pids_corte_rojo}' '	wait' \
'phase_red_fierro vuelve a esperar con un wait desnudo detras de su corte'

# M45 A M49: LA TERCERA VUELTA DEL LECTOR EXTERNO. La primera de estas rebobina un
# defecto que introdujo el arreglo de la SEGUNDA vuelta, o sea que este barrido
# vigila ya tres capas de arreglos sobre arreglos.
mutante M45 '	end_check P2.cut.fired

	# EL VEREDICTO EN VUELO VA DETRAS DEL end_check DE ESTA FASE, nunca dentro: abre
	# su propio bloque con su propio begin_check, y compartirlo era borrar los FAIL
	# de P2.cut.fired.
	veredicto_en_vuelo' '	veredicto_en_vuelo
	end_check P2.cut.fired' \
'veredicto_en_vuelo vuelve DENTRO del bloque de P2.cut.fired y su begin_check borra los FAIL de la fase'

mutante M46 '			'"'"'find naylamp/data naylamp/logs naylamp/data-mutante -mindepth 1 2>/dev/null | grep -c . ; echo __FIN__'"'"' 2>/dev/null || true)"
		case "${antes}" in' \
'			'"'"'ls -A naylamp/data naylamp/logs naylamp/data-mutante 2>/dev/null | grep -c . ; echo __FIN__'"'"' 2>/dev/null || true)"
		case "${antes}" in' \
'la precondicion vuelve a contar con ls -A, que da tres sobre tres directorios vacios' p2-preflight.sh

mutante M47 '		ok "la flota eligio lider, y lo escribio el host ${quien} con ${LITERAL_LIDER}; se pregunto a los tres porque solo el que GANA deja esa linea"' \
'		ok "la flota eligio lider, leido del host 1"' \
'el mensaje del lider deja de decir a cual de los tres se le leyo' p2-preflight.sh

# M50 A M53: LA CUARTA CAPA. Los tres primeros rebobinan lo que la tercera vuelta
# del lector encontro; el ultimo rebobina la guarda de la clase.
mutante M50 '	veredicto_en_vuelo' '	# el veredicto se va de aqui' \
'la fase deja de llamar al veredicto en vuelo: P2.cut.envuelo no se registra y la lista de fierro lo echa en falta'

mutante M51 '	if grep -q '"'"'^ack '"'"' "${OUT_LOCAL}/en-vuelo.txt" 2>/dev/null; then
		note "the in-flight writer has at least one acknowledged write; cutting now, so its age at the cut is as close to zero as this gate can put it"' \
'	if false; then
		note "the in-flight writer has at least one acknowledged write; cutting now, so its age at the cut is as close to zero as this gate can put it"' \
'el corte deja de esperar al primer ack del escritor en vuelo'

mutante M52 '	if [ -n "${PID_EN_VUELO:-}" ]; then
		kill "${PID_EN_VUELO}" 2>/dev/null || true
		wait "${PID_EN_VUELO}" 2>/dev/null || true
	fi' '	:' \
'la trampa deja de matar al escritor en vuelo, que sobrevive al aborto escribiendo detras del sello'

# M53 SE ESPERA MUDO Y SU RAZON VIVE EN OTRO FICHERO, que es lo que ata los dos
# instrumentos. Su sitio, `escribe_running` dentro de `phase_build`, esta DECLARADO
# en gate/sitio-test.sh con esta razon escrita: ejercer phase_build seria
# cruza-compilar y desplegar binarios dentro de un banco que existe para no
# encender nada. O sea que no es que nadie mire: es que mirar ahi cuesta mas de lo
# que ese banco puede gastar, y esta dicho donde se lee.
mitad M53 '	escribe_running
	if [ "${ES_FIERRO}" -eq 1 ]; then' '	if [ "${ES_FIERRO}" -eq 1 ]; then' \
'phase_build deja de escribir el marcador RUNNING: su sitio esta DECLARADO exento en gate/sitio-test.sh'

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
# ---- LOS CUATRO QUE LA CUARTA VUELTA DEJO SIN RESPALDO ------------------------
#
# EL CENSO LOS ENCONTRO Y NO YO. Tras cerrar la cuarta vuelta se cruzo la lista de
# filas que algun mutante hace caer contra las filas nuevas, y CUATRO no aparecian:
# 17db, 17ic, 17ib y 17ie. Y los IDS SE ELIGIERON MAL la primera vez: M51, M52 y
# M53 ya existian, dos como mutantes y uno como MITAD, asi que el informe salio
# con tres pares de lineas homonimas y sin forma de saber cual era cual. Van como
# M54, M55 y M56, detras del mayor que habia. Una fila sin mutante detras es una fila que nadie ha
# visto ponerse roja, o sea una afirmacion sin comprobar. Y el cruce cobro en el
# acto: la 17ic salia verde por su PROPIA PROSA, porque el comentario que explica
# el arreglo CITA la forma rota y el grep casaba la cita en vez del codigo.

mutante M47b "	local LITERAL_LIDER='role=leader'" \
"	local LITERAL_LIDER='became leader'" \
'el literal del lider vuelve a la frase que el motor NO escribe' p2-preflight.sh

mutante M54 '		( if testigo_arma "$n"; then echo 0; else echo 1; fi > "${OUT_LOCAL}/arma-rc-${n}" ) &' \
'		( testigo_arma "$n"; echo $? > "${OUT_LOCAL}/arma-rc-${n}" ) &' \
'el armado paralelo pierde la exencion de errexit: con un arma que falla, la subcapa muere antes de escribir su rc'

mutante M55 '	wait ${pids_arma}' \
'	:' \
'las armas se lanzan al fondo y NO se las junta: se corta antes de que las semillas esten puestas'

mutante M56 '	if [ "${acks_en_vuelo}" -gt 0 ]; then' \
'	if [ "${acks_en_vuelo}" -gt 999 ]; then' \
'el veredicto en vuelo no llega nunca a pass, aunque haya acks'

T_FIN="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())' 2>/dev/null || echo 0)"
/usr/bin/python3 -c "print('reloj: %.1f s de punta a punta, %s corridas del banco, la del control incluida' % (${T_FIN} - ${T_INICIO}, ${MUTANTES} + 1))" 2>/dev/null || true
echo "RESULTADO: ${MUTANTES} filas, $((MUDOS + MITADES_MAL)) en FALLA"
rm -rf -- "${PADRE}/naylamp-sello-mutantes-$$"
[ "${MUDOS}" -eq 0 ] && [ "${MITADES_MAL}" -eq 0 ] && [ "${CONTROL}" -eq 0 ] || exit 1
exit 0
