#!/bin/sh
# sello-test.sh: el sello de gate/p1.sh se TERMINA, y una corrida matada entre el
# sello y su veredicto final se distingue de una completa mirando el artefacto.
#
# DE DONDE SALE. El 8 de septiembre de 2026 se pregunto si p1.sh puede morir
# despues de escribir el sello y antes de emitir su veredicto final. La respuesta
# medida es que si, pero solo por SIGKILL o por perdida de maquina: las senales
# atrapables llegan diferidas hasta que cleanup termina. La defensa que se
# propuso entonces fue que el artefacto se delata solo, porque el sello lleva
# `expected:` y `verdicts:` y una corrida a medias tendria menos veredictos que
# esperados.
#
# ESA DEFENSA ERA FALSA, y lo demostro el propio archivo. seal_artifact no
# reescribe: su primera guarda es `[ -e SEALED ] && return 0`. El sello que vale
# lo escribe phase_hygiene mientras la corrida vive, o sea ANTES de que
# P1.hygiene emita su veredicto, asi que las TRES corridas de fierro archivadas
# llevan 19 esperados y 18 veredictos, y el que falta es siempre P1.hygiene. Una
# corrida completa tenia exactamente la misma forma que una matada en la ventana:
# la senal valia lo mismo en los dos casos, que es no valer nada.
#
# QUE PRUEBA ESTE BANCO. Que completa_el_sello deja las dos cuentas iguales en
# una corrida completa, que no toca el sello cuando no fue esta corrida quien lo
# escribio, y que `expected:` sale identica byte a byte, que es la linea que el
# subcomando seals compara para proponer sustituciones.
#
# CORRE LA FUNCION DE VERDAD, no una copia de su logica: la extrae de gate/p1.sh
# por sus llaves y la mete en este shell. Si alguien la renombra o la borra, la
# extraccion sale vacia y el banco lo dice en vez de quedarse verde probando aire.

set -eu

# QUIEN ES ESTE BANCO, dicho en su PRIMERA linea de salida y en una forma que no
# es prosa. Entra el 8 de septiembre de 2026. El barrido que revisa el archivo de
# corridas/ clasificaba cada captura buscando por el CUERPO el texto de alguna de
# sus filas, y eso tiene dos agujeros medidos: el texto de una fila se reescribe,
# y entonces las capturas de ese banco dejan de existir para el barrido sin que
# nadie lo note; y un informe ESCRITO que cita unas filas se cuenta como corrida,
# que es como cuatro analisis del archivo acabaron contados como capturas. Una
# cita vive siempre por el medio de un fichero, nunca en su primera linea, asi que
# esta linea distingue una corrida de una cita a una corrida.
echo "BANCO: sello-test"

. "$(dirname "$0")/entorno.sh"

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
P1="${RAIZ}/gate/p1.sh"
[ -r "${P1}" ] || { echo "test: no se puede leer ${P1}" >&2; exit 2; }

CAJON="${TMPDIR:-/tmp}/naylamp-sello-$$"
mkdir -p "${CAJON}/out"

REGISTRO_FILAS="${CAJON}/filas-del-banco"
: > "${REGISTRO_FILAS}"
anota_fila() { printf '%s\n' "$1" >> "${REGISTRO_FILAS}"; }
fallos=0
mal() { echo "$1" >&2; fallos=$((fallos + 1)); }
# UNA FILA PUEDE NO APLICAR AQUI, y entonces no se cuenta como fila. gate/out/
# esta en .gitignore, asi que la fila que mide el sello de fierro archivado no
# existe en CI: la evidencia no se versiona. Clausula 16. Contarla como OK seria
# publicar un pase que nadie corrio, y contarla como FALLA pondria roja a CI por
# la ausencia de algo que CI no puede tener. Se declara y se cuenta aparte.
omitidas=0
no_aplica() { echo "$1" >&2; omitidas=$((omitidas + 1)); }

COMPLETO=0
limpia_y_cierra() {
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2
		rm -rf -- "${TMPDIR:-/tmp}/naylamp-sello-$$" 2>/dev/null || true
		exit 1
	fi
	rm -rf -- "${TMPDIR:-/tmp}/naylamp-sello-$$" 2>/dev/null || true
}
trap limpia_y_cierra EXIT

# ---- la extraccion, y su propia anti-vacuidad -------------------------------
FUENTE="${CAJON}/completa_el_sello.sh"
awk '/^completa_el_sello\(\) \{$/,/^\}$/' "${P1}" > "${FUENTE}"
n_ext=$(grep -c '' "${FUENTE}" || true)
if [ "${n_ext}" -lt 20 ]; then
	echo "test: la extraccion de completa_el_sello dio ${n_ext} lineas; o cambio de nombre o cambio de forma" >&2
	echo "test: sin funcion que probar este banco no prueba nada, y eso NO es un pase" >&2
	exit 1
fi
if ! grep -q 'SELLO_ESCRITO_AQUI' "${FUENTE}"; then
	echo "test: la funcion extraida no menciona SELLO_ESCRITO_AQUI; la guarda que este banco vigila ya no esta" >&2
	exit 1
fi
echo "extraidas ${n_ext} lineas de completa_el_sello desde gate/p1.sh"

# ---- un sello de mentira con la forma exacta del de verdad -------------------
ESPERADOS="P1.pre P1.provenance P1.exact P1.ledger P1.reach P1.recall.500 P1.recall.5k P1.recall.50k P1.point.ledger P1.point.exact P1.point.reach P1.point.shape P1.point.floor P1.red.reach P1.red.ledger P1.red.ghost P1.red.floor P1.red.shape P1.hygiene"

siembra() {
	# $1 = run id, $2 = veredictos que YA estan en el sello
	rm -rf -- "${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-$1"
	mkdir -p "${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-$1"
	{
		echo "Phase 1 iron gate artifact, sealed by gate/p1.sh."
		echo
		echo "run id:      $1"
		echo "subcommand:  all"
		echo "started:     2026-09-08T10:00:00Z"
		echo "sealed:      2026-09-08T11:30:00Z"
		echo "HEAD:        0000000000000000000000000000000000000000"
		echo "uncommitted: 0"
		echo "hosts:       10.0.0.1,10.0.0.2,10.0.0.3"
		echo "red arm on:  node 1"
		echo "binaries:    aa bb"
		echo "expected:    ${ESPERADOS}"
		echo "verdicts:    $2"
		echo
		echo "This file is what keeps make clean from taking the directory."
	} > "${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-$1/SEALED"
}

cuenta() { grep -m1 "^$2:" "$1" | sed "s/^$2: *//" | tr ' ' '\n' | grep -c . || true; }

# El juego de veredictos completo y el que escribe phase_hygiene (uno menos).
VER_COMPLETO=""
for e in ${ESPERADOS}; do VER_COMPLETO="${VER_COMPLETO}${e}=pass "; done
VER_PARCIAL=""
for e in ${ESPERADOS}; do
	[ "${e}" = P1.hygiene ] && continue
	VER_PARCIAL="${VER_PARCIAL}${e}=pass "
done

# corre <run id> <bandera> <out_local> ; deja la salida de error en ${CAJON}/err
corre() {
	(
		# `set +e` REPRODUCE EL CONTEXTO REAL Y NO LO RELAJA, y sin el este banco
		# probaba una situacion que no ocurre. `cleanup` de gate/p1.sh hace `set +e`
		# en su segunda linea y llama a la funcion despues, asi que una redireccion
		# que falla NO aborta alli. Heredando el `set -e` de este banco, el caso del
		# directorio sin permiso de escritura moria antes de llegar al `if` que
		# decide, y la fila salia roja por el arnes y no por el objeto.
		set +e
		. "${FUENTE}"
		OUT_DIR="${TMPDIR:-/tmp}/naylamp-sello-$$/out"
		RUN_ID="$1"
		SELLO_ESCRITO_AQUI="$2"
		OUT_LOCAL="$3"
		VERDICTS=" ${VER_COMPLETO}"
		completa_el_sello
	) 2> "${CAJON}/err" || true
}

# ---- 1 completa -------------------------------------------------------------
siembra 20260908T100000Z-111 "${VER_PARCIAL}"
S="${CAJON}/out/p1-20260908T100000Z-111/SEALED"
antes_v=$(cuenta "${S}" verdicts)
corre 20260908T100000Z-111 1 "${CAJON}/out/p1-20260908T100000Z-111"
despues_v=$(cuenta "${S}" verdicts)
despues_e=$(cuenta "${S}" expected)
if [ "${antes_v}" -eq 18 ] && [ "${despues_v}" -eq 19 ] && [ "${despues_e}" -eq 19 ]; then
	anota_fila OK; echo "1 completa: OK, el sello entraba con ${antes_v} veredictos contra ${despues_e} esperados y sale con ${despues_v}"
else
	anota_fila FALLA; mal "1 completa: FALLA, antes ${antes_v}, despues ${despues_v}, esperados ${despues_e}"
fi

# ---- 2 esperada intacta -----------------------------------------------------
# La linea que seals compara entre dos sellos. Si esta reescritura la tocara,
# seals empezaria a proponer sustituciones al azar.
if [ "$(grep -m1 '^expected:' "${S}")" = "expected:    ${ESPERADOS}" ]; then
	anota_fila OK; echo "2 intacta: OK, la linea expected sale identica byte a byte"
else
	anota_fila FALLA; mal "2 intacta: FALLA, la linea expected cambio: $(grep -m1 '^expected:' "${S}" | cut -c1-70)"
fi

# ---- 3 cierre ---------------------------------------------------------------
if grep -qE '^closed:      [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "${S}"; then
	anota_fila OK; echo "3 cierre: OK, el sello dice a que hora se termino, que no es la hora en que se escribio"
else
	anota_fila FALLA; mal "3 cierre: FALLA, no hay linea closed: con forma de instante UTC"
fi

# ---- 4 bandera --------------------------------------------------------------
# LA FILA QUE MAS PESA. `p1.sh hygiene <run id>` adopta el id de otra corrida y
# apunta OUT_LOCAL a un artefacto ya terminado. Si la guarda mirase
# SEALED_THIS_RUN, que tambien vale 1 cuando el sello simplemente se ENCUENTRA,
# una higiene suelta le machacaria diecinueve veredictos y le pondria dos.
siembra 20260908T100000Z-222 "${VER_PARCIAL}"
S2="${CAJON}/out/p1-20260908T100000Z-222/SEALED"
md5_antes=$(md5 -q "${S2}" 2>/dev/null || md5sum "${S2}" | cut -d' ' -f1)
corre 20260908T100000Z-222 0 "${CAJON}/out/p1-20260908T100000Z-222"
md5_despues=$(md5 -q "${S2}" 2>/dev/null || md5sum "${S2}" | cut -d' ' -f1)
if [ "${md5_antes}" = "${md5_despues}" ]; then
	anota_fila OK; echo "4 bandera: OK, sin la bandera de ESCRITURA el sello no se toca, que es lo que salva a una higiene suelta"
else
	anota_fila FALLA; mal "4 bandera: FALLA, el sello cambio con SELLO_ESCRITO_AQUI=0"
fi

# ---- 5 ajeno ----------------------------------------------------------------
# EL SELLO TIENE QUE EXISTIR EN EL SITIO AJENO, y la primera version de esta fila
# no lo sembraba: apuntaba OUT_LOCAL a un p1-local que no existia, asi que la
# funcion devolvia en la guarda del `-f` sin llegar nunca al case, y la fila salia
# roja diciendo que el rechazo no se pronunciaba. La fila probaba la guarda
# equivocada. Aqui el artefacto ajeno existe y esta sellado, que es el unico caso
# en que la comprobacion del nombre significa algo.
mkdir -p "${CAJON}/out/p1-local-20260908T100000Z-333"
siembra 20260908T100000Z-333 "${VER_PARCIAL}"
cp "${CAJON}/out/p1-20260908T100000Z-333/SEALED" "${CAJON}/out/p1-local-20260908T100000Z-333/SEALED"
S3="${CAJON}/out/p1-local-20260908T100000Z-333/SEALED"
md5_antes=$(md5 -q "${S3}" 2>/dev/null || md5sum "${S3}" | cut -d' ' -f1)
corre 20260908T100000Z-333 1 "${CAJON}/out/p1-local-20260908T100000Z-333"
md5_despues=$(md5 -q "${S3}" 2>/dev/null || md5sum "${S3}" | cut -d' ' -f1)
if [ "${md5_antes}" = "${md5_despues}" ] && grep -q 'NOT completed' "${CAJON}/err"; then
	anota_fila OK; echo "5 ajeno: OK, un OUT_LOCAL que no es p1-<run id> se rechaza en voz alta y no toca nada"
else
	anota_fila FALLA; mal "5 ajeno: FALLA, md5 $([ "${md5_antes}" = "${md5_despues}" ] && echo igual || echo distinto), stderr [$(head -c 80 "${CAJON}/err")]"
fi

# ---- 6 repite ---------------------------------------------------------------
corre 20260908T100000Z-111 1 "${CAJON}/out/p1-20260908T100000Z-111"
n_closed=$(grep -c '^closed:' "${S}" || true)
n_ver=$(grep -c '^verdicts:' "${S}" || true)
if [ "${n_closed}" -eq 1 ] && [ "${n_ver}" -eq 1 ]; then
	anota_fila OK; echo "6 repite: OK, dos pasadas dejan una sola linea closed y una sola verdicts"
else
	anota_fila FALLA; mal "6 repite: FALLA, ${n_closed} lineas closed y ${n_ver} verdicts tras la segunda pasada"
fi

# ---- 7 basura ---------------------------------------------------------------
restos=$(find "${CAJON}/out" -name 'SEALED.a-medias' | wc -l | tr -d ' ')
if [ "${restos}" -eq 0 ]; then
	anota_fila OK; echo "7 basura: OK, no sobrevive ningun SEALED.a-medias"
else
	anota_fila FALLA; mal "7 basura: FALLA, quedan ${restos} ficheros SEALED.a-medias"
fi

# ---- 8 archivo --------------------------------------------------------------
# Sobre una COPIA de un sello de fierro de verdad, el del 4 de septiembre, que es
# el que descubrio todo esto. No se toca el original.
REAL="${RAIZ}/gate/out/p1-20260904T204300Z-48669/SEALED"
if [ -r "${REAL}" ]; then
	mkdir -p "${CAJON}/out/p1-20260904T204300Z-48669"
	cp "${REAL}" "${CAJON}/out/p1-20260904T204300Z-48669/SEALED"
	S4="${CAJON}/out/p1-20260904T204300Z-48669/SEALED"
	a_e=$(cuenta "${S4}" expected); a_v=$(cuenta "${S4}" verdicts)
	corre 20260904T204300Z-48669 1 "${CAJON}/out/p1-20260904T204300Z-48669"
	d_e=$(cuenta "${S4}" expected); d_v=$(cuenta "${S4}" verdicts)
	if [ "${a_e}" -eq 19 ] && [ "${a_v}" -eq 18 ] && [ "${d_e}" -eq 19 ] && [ "${d_v}" -eq 19 ]; then
		anota_fila OK; echo "8 archivo: OK, el sello de fierro del 4 de septiembre entra ${a_e}/${a_v} y sale ${d_e}/${d_v}"
	else
		anota_fila FALLA; mal "8 archivo: FALLA, entra ${a_e}/${a_v} y sale ${d_e}/${d_v}"
	fi
else
	no_aplica "8 archivo: NO APLICA aqui, ${REAL} no existe porque gate/out/ esta en .gitignore"
fi

# ---- 9 corta ----------------------------------------------------------------
# LA PRIMERA VERSION DE ESTA FILA NO LLAMABA A LA FUNCION, y lo trajo un lector:
# sembraba un sello parcial y comparaba sus dos cuentas, que es una tautologia
# sobre `siembra` y salia verde con la funcion vaciada del todo. Lo que separa de
# verdad a un sello viejo de uno de una corrida cortada NO son las dos cuentas,
# que en los dos casos no cuadran: es la linea `closed:`. Un sello que esta funcion
# no ha cerrado no la lleva; uno cortado por un Ctrl-C SI la lleva, y sigue corto.
# Eso es lo que el subcomando seals usa para describir en vez de acusar, asi que es
# lo que hay que probar.
siembra 20260908T100000Z-444 "${VER_PARCIAL}"
S5="${CAJON}/out/p1-20260908T100000Z-444/SEALED"
sin_cerrar=$(grep -c '^closed:' "${S5}" || true)
c_e=$(cuenta "${S5}" expected); c_v=$(cuenta "${S5}" verdicts)
# y ahora la MISMA corrida, cortada: se llama con veredictos parciales, que es lo
# que deja un INT o un TERM, porque EXPECTED se fija de golpe al arrancar y
# VERDICTS crece por fases.
siembra 20260908T100000Z-445 "${VER_PARCIAL}"
S5b="${CAJON}/out/p1-20260908T100000Z-445/SEALED"
(
	. "${FUENTE}"
	OUT_DIR="${TMPDIR:-/tmp}/naylamp-sello-$$/out"
	RUN_ID=20260908T100000Z-445
	SELLO_ESCRITO_AQUI=1
	OUT_LOCAL="${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-20260908T100000Z-445"
	VERDICTS=" P1.pre=pass P1.provenance=pass"
	completa_el_sello
) 2>/dev/null || true
con_cierre=$(grep -c '^closed:' "${S5b}" || true)
d_e=$(cuenta "${S5b}" expected); d_v=$(cuenta "${S5b}" verdicts)
if [ "${sin_cerrar}" -eq 0 ] && [ "${c_e}" -ne "${c_v}" ] \
	&& [ "${con_cierre}" -eq 1 ] && [ "${d_e}" -ne "${d_v}" ]; then
	anota_fila OK; echo "9 corta: OK, sin cerrar no hay closed y las cuentas no cuadran (${c_v}/${c_e}); cortada SI hay closed y siguen sin cuadrar (${d_v}/${d_e})"
else
	anota_fila FALLA; mal "9 corta: FALLA, closed sin cerrar=${sin_cerrar} cortada=${con_cierre}; cuentas ${c_v}/${c_e} y ${d_v}/${d_e}"
fi

# ---- 10 mutante -------------------------------------------------------------
# La fila 4 es la que sostiene todo el argumento, asi que se comprueba que MUERDE:
# con la guarda cambiada a la bandera equivocada, el sello de una higiene suelta
# se machaca, y la fila 4 tendria que ponerse roja.
sed 's/SELLO_ESCRITO_AQUI/SEALED_THIS_RUN/g' "${FUENTE}" > "${CAJON}/mutante.sh"
if cmp -s "${FUENTE}" "${CAJON}/mutante.sh"; then
	anota_fila FALLA; mal "10 mutante: FALLA, la mutacion no cambio nada, asi que no prueba nada"
else
	siembra 20260908T100000Z-555 "${VER_PARCIAL}"
	S6="${CAJON}/out/p1-20260908T100000Z-555/SEALED"
	m_antes=$(md5 -q "${S6}" 2>/dev/null || md5sum "${S6}" | cut -d' ' -f1)
	(
		. "${CAJON}/mutante.sh"
		OUT_DIR="${TMPDIR:-/tmp}/naylamp-sello-$$/out"
		RUN_ID=20260908T100000Z-555
		SEALED_THIS_RUN=1
		OUT_LOCAL="${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-20260908T100000Z-555"
		VERDICTS=" P1.pre=pass P1.hygiene=pass"
		completa_el_sello
	) 2>/dev/null || true
	m_despues=$(md5 -q "${S6}" 2>/dev/null || md5sum "${S6}" | cut -d' ' -f1)
	m_v=$(cuenta "${S6}" verdicts)
	if [ "${m_antes}" != "${m_despues}" ] && [ "${m_v}" -eq 2 ]; then
		anota_fila OK; echo "10 mutante: OK, MUERDE: con la bandera equivocada la higiene suelta deja ${m_v} veredictos donde habia 18"
	else
		anota_fila FALLA; mal "10 mutante: FALLA, la bandera equivocada no destruyo el sello, asi que la fila 4 no prueba nada"
	fi
fi

# ---- 11 y 12: LA RAMA DE FALLO, que no cubria NINGUNA fila ------------------
#
# Un lector lo midio y es el agujero mas grave que tenia este banco. Las diez filas
# de arriba corren TODAS por el camino feliz, asi que con la rama del `else`
# cambiada para que BORRE EL SELLO en vez de borrar el fichero de al lado, el banco
# salia 10 filas y 0 en FALLA. Lo mismo con cualquiera de las tres condiciones del
# `if` quitada. Cinco mutaciones sin una sola fila roja.
#
# Las dos de aqui fuerzan el rechazo por dos caminos distintos, uno mutando y otro
# REAL, y las dos exigen lo mismo: el sello sigue ahi byte a byte, no queda ningun
# `.a-medias`, y se dice en voz alta. Con eso, una rama de fallo que borre el sello
# pone rojas las dos.
comprueba_rechazo() {
	# $1 etiqueta, $2 runid, $3 glosa
	local eti="$1" runid="$2" glosa="$3" m_despues restos
	m_despues=$(md5 -q "${CAJON}/out/p1-${runid}/SEALED" 2>/dev/null || md5sum "${CAJON}/out/p1-${runid}/SEALED" | cut -d' ' -f1)
	restos=$(find "${CAJON}/out/p1-${runid}" -name 'SEALED.a-medias' 2>/dev/null | wc -l | tr -d ' ')
	if [ "${m_despues}" = "${MD5_ANTES}" ] && [ "${restos}" -eq 0 ] \
		&& grep -q 'could not be completed' "${CAJON}/err"; then
		anota_fila OK; echo "${eti}: OK, ${glosa}, y el sello sale intacto, sin restos y con su aviso"
	else
		anota_fila FALLA
		mal "${eti}: FALLA, sello $([ "${m_despues}" = "${MD5_ANTES}" ] && echo intacto || echo CAMBIADO), ${restos} resto(s), aviso [$(head -c 60 "${CAJON}/err")]"
	fi
}

# 11: la reescritura sale corrupta, asi que la guarda de `expected:` la caza.
siembra 20260908T100011Z-777 "${VER_PARCIAL}"
S11="${CAJON}/out/p1-20260908T100011Z-777/SEALED"
MD5_ANTES=$(md5 -q "${S11}" 2>/dev/null || md5sum "${S11}" | cut -d' ' -f1)
sed 's|{linea}" ;;|{linea}XX" ;;|' "${FUENTE}" > "${CAJON}/rota-11.sh"
if cmp -s "${FUENTE}" "${CAJON}/rota-11.sh"; then
	anota_fila FALLA; mal "11 rechaza: FALLA, la mutacion no cambio nada, asi que esta fila no prueba nada"
else
	(
		set +e
		. "${CAJON}/rota-11.sh"
		OUT_DIR="${TMPDIR:-/tmp}/naylamp-sello-$$/out"
		RUN_ID=20260908T100011Z-777
		SELLO_ESCRITO_AQUI=1
		OUT_LOCAL="${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-20260908T100011Z-777"
		VERDICTS=" ${VER_COMPLETO}"
		completa_el_sello
	) 2> "${CAJON}/err" || true
	comprueba_rechazo "11 rechaza" 20260908T100011Z-777 "con la reescritura corrompida la guarda de expected la caza"
fi

# 12: el caso REAL y sin mutar nada, el que el comentario de la funcion describe:
# no se puede escribir al lado del sello. Es la unica via por la que la rama del
# else se recorre en produccion.
siembra 20260908T100012Z-777 "${VER_PARCIAL}"
S12="${CAJON}/out/p1-20260908T100012Z-777/SEALED"
MD5_ANTES=$(md5 -q "${S12}" 2>/dev/null || md5sum "${S12}" | cut -d' ' -f1)
chmod 500 "${CAJON}/out/p1-20260908T100012Z-777"
corre 20260908T100012Z-777 1 "${CAJON}/out/p1-20260908T100012Z-777"
chmod 700 "${CAJON}/out/p1-20260908T100012Z-777"
comprueba_rechazo "12 sin-permiso" 20260908T100012Z-777 "sin permiso de escritura al lado del sello"

# ---- 13 sin-verdicts --------------------------------------------------------
# Un sello sin linea `verdicts:` se daba por terminado EN SILENCIO: la reescritura
# salia identica, pasaba las tres condiciones, se movia encima y no se anadia
# `closed:`. El artefacto quedaba entonces descrito como escrito por una version
# que no terminaba sus sellos, que es la confusion que la rama de fallo se molesta
# en confesar. Ahora lo confiesa aqui tambien.
mkdir -p "${CAJON}/out/p1-20260908T100014Z-777"
printf 'run id:      20260908T100014Z-777\nexpected:    A B C\nfin\n' > "${CAJON}/out/p1-20260908T100014Z-777/SEALED"
SV="${CAJON}/out/p1-20260908T100014Z-777/SEALED"
sv_antes=$(md5 -q "${SV}" 2>/dev/null || md5sum "${SV}" | cut -d' ' -f1)
corre 20260908T100014Z-777 1 "${CAJON}/out/p1-20260908T100014Z-777"
sv_despues=$(md5 -q "${SV}" 2>/dev/null || md5sum "${SV}" | cut -d' ' -f1)
if [ "${sv_antes}" = "${sv_despues}" ] && grep -q 'no verdicts line' "${CAJON}/err"; then
	anota_fila OK; echo "13 sin-verdicts: OK, un sello sin linea de veredictos se deja como esta y se dice"
else
	anota_fila FALLA; mal "13 sin-verdicts: FALLA, md5 $([ "${sv_antes}" = "${sv_despues}" ] && echo igual || echo distinto), stderr [$(head -c 60 "${CAJON}/err")]"
fi

# ---- 14 sin-salto -----------------------------------------------------------
# Un sello cuya ultima linea no termina en salto perdia esa linea, porque `read`
# devuelve falso al llegar a ella. Y la perdida quedaba tapada: el `closed:` que se
# anade compensa exactamente el uno que falta, asi que el recuento de lineas daba
# el visto bueno. Medido por un lector: 403 bytes entraban y salian 393.
mkdir -p "${CAJON}/out/p1-20260908T100015Z-777"
printf 'run id:      20260908T100015Z-777\nexpected:    A B C\nverdicts:    A=pass\nULTIMA SIN SALTO' > "${CAJON}/out/p1-20260908T100015Z-777/SEALED"
corre 20260908T100015Z-777 1 "${CAJON}/out/p1-20260908T100015Z-777"
if grep -q '^ULTIMA SIN SALTO$' "${CAJON}/out/p1-20260908T100015Z-777/SEALED"; then
	anota_fila OK; echo "14 sin-salto: OK, la ultima linea sin salto de linea sobrevive a la reescritura"
else
	anota_fila FALLA; mal "14 sin-salto: FALLA, la ultima linea sin salto se perdio en la reescritura"
fi

# ---- 15 rechaza-corta -------------------------------------------------------
# LA TERCERA CONDICION, el recuento de lineas, que se quedaba sin vigilar. Un
# lector midio que quitarla no ponia roja ninguna fila, y con las filas 11 y 12
# dentro seguia sin ponerla, porque las dos rompen ademas la linea `expected:` y
# la caza la condicion de antes.
#
# Lo que esta condicion protege es una reescritura que PIERDA lineas dejando
# `expected:` intacta. La mutacion las tira: se le anade el patron de linea vacia
# al brazo que ya descarta `closed:`, con lo que el sello de prueba pierde sus dos
# lineas en blanco y gana la de `closed:`, o sea una menos en neto.
#
# Y NO SIRVE PARA EL CASO DE LA LINEA SIN SALTO, que es lo que hay que decir aqui
# para no venderla de mas: alli se pierde UNA linea y el `closed:` que se anade la
# compensa exactamente, asi que este recuento da el visto bueno. De ese caso se
# ocupa la fila 14, mirando la linea por su texto.
siembra 20260908T100015Z-777 "${VER_PARCIAL}"
S15="${CAJON}/out/p1-20260908T100015Z-777/SEALED"
MD5_ANTES=$(md5 -q "${S15}" 2>/dev/null || md5sum "${S15}" | cut -d' ' -f1)
sed 's|closed:\*) ;;|closed:*\|"") ;;|' "${FUENTE}" > "${CAJON}/rota-15.sh"
if cmp -s "${FUENTE}" "${CAJON}/rota-15.sh"; then
	anota_fila FALLA; mal "15 rechaza-corta: FALLA, la mutacion no cambio nada, asi que esta fila no prueba nada"
else
	(
		set +e
		. "${CAJON}/rota-15.sh"
		OUT_DIR="${TMPDIR:-/tmp}/naylamp-sello-$$/out"
		RUN_ID=20260908T100015Z-777
		SELLO_ESCRITO_AQUI=1
		OUT_LOCAL="${TMPDIR:-/tmp}/naylamp-sello-$$/out/p1-20260908T100015Z-777"
		VERDICTS=" ${VER_COMPLETO}"
		completa_el_sello
	) 2> "${CAJON}/err" || true
	comprueba_rechazo "15 rechaza-corta" 20260908T100015Z-777 "con la reescritura perdiendo lineas y expected intacta, el recuento la caza"
fi

# ---- el resumen -------------------------------------------------------------
n_filas=$(grep -c . "${REGISTRO_FILAS}" || true)
n_falla=$(grep -c '^FALLA$' "${REGISTRO_FILAS}" || true)
if [ "${omitidas}" -ne 0 ]; then
	echo "${omitidas} fila(s) no aplican en esta maquina y no se cuentan como filas; el motivo va impreso arriba"
fi
echo "RESULTADO: ${n_filas} filas, ${n_falla} en FALLA"
# COMPLETO SE PONE AQUI Y NO CUATRO LINEAS MAS ABAJO, y es una correccion del 8 de
# septiembre. En los otros bancos las dos anti-vacuidades salen por exit 1 ANTES
# de COMPLETO=1, asi que la trampa imprime "ABORTADO antes del resumen" habiendo
# impreso el resumen justo encima. El resumen es esta linea: llegar aqui es haber
# terminado, y lo que venga despues es un rojo ordinario, no un aborto.
COMPLETO=1
if [ "${n_filas}" -eq 0 ]; then
	echo "test: VACIO. El registro de filas salio a cero, asi que este banco no ha probado nada" >&2
	exit 1
fi
if [ "${n_falla}" -ne "${fallos}" ]; then
	echo "test: el registro cuenta ${n_falla} fallas y el acumulador ${fallos}; las dos cuentas tienen que casar" >&2
	exit 1
fi
[ "${fallos}" -eq 0 ] || { echo "test: ${fallos} fallo(s)" >&2; exit 1; }
echo "test: el sello se termina, la linea expected no se toca, y una corrida a medias ya no tiene la forma de una completa"
