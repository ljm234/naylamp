#!/bin/sh
# Prueba del hook que rechaza una firma de asistente, con su BRAZO ROJO dentro.
#
# ESTE GUION NO CORRE SOLO, Y NO PUEDE. Va lo primero porque es lo que decide si
# esta prueba vale algo o es un adorno.
#
# El objeto que prueba, .git/hooks/commit-msg, NO esta versionado: un clon fresco
# nace sin el, y borrarlo no deja diff. Asi que esta prueba no
# puede ir al paso de CI como su hermana clean-guard-test.sh: en un corredor no
# habria nada que probar y saldria roja siempre. Es la CLAUSULA 16 del protocolo
# del final de NAYLAMP_DEFERRED_BACKLOG.md, y este es su segundo ejemplar: un
# defensor que depende de evidencia no versionada no se automatiza sin cambiar
# que cuenta como evidencia.
#
# Y aqui esa eleccion es cara y esta medida. Automatizarlo obliga a versionar la
# lista de cadenas que el hook existe para impedir, y el 1 de septiembre de 2026
# CERO ficheros rastreados de este arbol casan con ninguna de las siete. Y de las
# siete, SEIS no han estado nunca en un fichero rastreado, medido con git log -S
# sobre la historia entera: versionar la lista no repone nada, las introduce. Por
# eso DEFER-070 sigue sin ejecutarse y esta prueba se queda local.

#
# QUIEN LA CORRE, entonces. Nadie automaticamente, y va dicho aqui y no solo en
# el registro, que es la diferencia entre aceptable y adorno. Su sitio es la
# seccion 3 del plan de fierro, la de lo que se comprueba antes de encender nada,
# porque el momento en que el hook importa es justo antes de una sesion que va a
# producir commits. NO se anade al paso de CI. Si algun dia se quiere mecanica de
# verdad, la pieza es la que DEFER-070 propone en su paso 3, una linea en el
# arranque de gate/common.sh, y esa decision no se toma aqui.
#
# LO QUE LA PRUEBA NO ESCRIBE, que es la mitad de por que existe. Ninguna de las
# cadenas que el hook rechaza aparece en este fichero. Se LEEN del hook y se
# generan los mensajes desde ahi, asi que la prueba no puede desincronizarse y
# tampoco mete en el arbol lo que el hook existe para mantener fuera.
#
# El agujero que eso abre y su tapa: una prueba que hereda sus expectativas del
# objeto no ve que le borren un patron, probaria menos y seguiria verde. Por eso
# lleva un PIN, la huella de la alternancia, que es un numero y no nombra a
# nadie. Editar la lista pone esta prueba roja y obliga a re-anclar el pin, que
# es el momento de revision que hace falta.
#
# Uso: ./gate/hook-guard-test.sh    (desde donde sea, rc=0 si todas van)

set -eu

AQUI=$(cd "$(dirname "$0")" && pwd)
RAIZ_REPO=$(cd "${AQUI}/.." && pwd)

# El pin de la alternancia: sha256 de la lista de patrones del hook, 16 primeros.
# Anclado el 1 de septiembre de 2026 sobre los siete patrones de entonces.
# Y un aviso para quien escriba el proximo mensaje, medido y no teorico: el hook
# casa por SUBCADENA, y hay conjugaciones castellanas corrientes de PROPONER y de
# OPONER, las de su tema irregular, que llevan un patron dentro y salen rechazadas. El
# infinitivo, el presente y el sustantivo pasan. Importa aqui y no en abstracto,
# porque DEFER-070 vive de ese campo lexico, y las formas que fallan no se
# escriben en este comentario por la misma razon que no se escribe la lista.
PIN_ESPERADO=198559931375fe48
PATRONES_ESPERADOS=7

RUTA_HOOKS=$(git -C "${RAIZ_REPO}" config --get core.hooksPath 2>/dev/null || true)
[ -n "${RUTA_HOOKS}" ] || RUTA_HOOKS="${RAIZ_REPO}/.git/hooks"
case "${RUTA_HOOKS}" in /*) ;; *) RUTA_HOOKS="${RAIZ_REPO}/${RUTA_HOOKS}" ;; esac
HOOK="${RUTA_HOOKS}/commit-msg"

# La ausencia del hook NO es un salto, es el resultado. Si no esta, esta copia del
# repositorio no tiene defensa ninguna contra una firma de asistente, y eso es
# exactamente lo que esta prueba existe para decir en voz alta.
if [ ! -x "${HOOK}" ]; then
	echo "test: NO HAY HOOK en ${HOOK}" >&2
	echo "test: esta copia del repositorio no tiene nada entre una firma de asistente y su historia" >&2
	echo "test: eso no es un fallo de esta prueba, es su resultado" >&2
	exit 1
fi

CAJON=$(mktemp -d "${TMPDIR:-/tmp}/hook-guard-test.XXXXXX")
trap 'rm -rf -- "$CAJON" 2>/dev/null || true' EXIT

fallos=0
mal() { echo "$1" >&2; fallos=$((fallos + 1)); }

# ---- la lista, leida del objeto ----
# El hook nombra su alternancia dos veces, una para decidir y otra para imprimir.
# Se exige que las dos sean identicas: si divergen, el hook rechaza por una lista
# y explica por otra, y esta prueba no sabria cual esta probando.
# Se cuentan las alternancias y ademas cuantas formas DISTINTAS hay. Las dos
# cuentas hacen falta: la primera version solo miraba las distintas, y un hook al
# que se le borrara la segunda alternancia entera daba una sola forma, pasaba la
# comprobacion, y la fila seguia diciendo "sus dos alternancias casan" habiendo
# una. Afirmar sobre dos cosas exige contar que sean dos.
cuantas=$(sed -n "s/.*-[qn]iE '\([^']*\)'.*/\1/p" "${HOOK}" | wc -l | tr -d ' ')
formas=$(sed -n "s/.*-[qn]iE '\([^']*\)'.*/\1/p" "${HOOK}" | sort -u | wc -l | tr -d ' ')
casan=si
if [ "${cuantas}" -ne 2 ]; then
	casan=no
	mal "lista:  FALLA, el hook nombra su alternancia ${cuantas} veces y deberia nombrarla dos, una para decidir y otra para imprimir"
elif [ "${formas}" -ne 1 ]; then
	casan=no
	mal "lista:  FALLA, el hook usa ${formas} alternancias distintas y deberia usar una"
fi
ALT=$(sed -n "s/.*-qiE '\([^']*\)'.*/\1/p" "${HOOK}" | head -n1)

# ---- anti-vacuidad de la extraccion ----
# Sin esto, un cambio en la forma del hook que rompiera el sed dejaria la lista
# vacia, el bucle de abajo no correria ni una vez, y la prueba saldria verde
# habiendo probado nada. Es la clase que esta casa llama instrumento muerto.
# El `|| true` esta por un motivo medido: `grep -c .` sobre una entrada vacia
# sale con estado 1, y bajo `set -eu` eso mata la asignacion ANTES de que el
# bloque de abajo pueda decir que la lista salio vacia. Medido al disparar el
# brazo: el guion moria imprimiendo una sola linea y sin nombrar la vacuidad, que
# es la clausula 15 cometida dentro de la prueba escrita para aplicarla.
n_pat=$(printf '%s' "${ALT}" | tr '|' '\n' | grep -c . || true)
if [ -z "${ALT}" ] || [ "${n_pat}" -lt 2 ]; then
	echo "test: VACIO. La extraccion devolvio ${n_pat} patrones del hook" >&2
	echo "test: alguien cambio la forma del hook y esta prueba dejo de probar" >&2
	exit 1
fi
if [ "${casan}" = si ]; then
	echo "lista:  OK, ${n_pat} patrones leidos del hook, y sus dos alternancias casan"
else
	echo "lista:  ${n_pat} patrones leidos de la primera alternancia; la segunda no casa, ver arriba"
fi

# ---- el PIN ----
# La prueba hereda sus expectativas del objeto, asi que no puede ver que le
# borren un patron: probaria menos y seguiria verde. El pin lo ve.
huella=$(printf '%s' "${ALT}" | shasum -a 256 | cut -c1-16)
if [ "${huella}" = "${PIN_ESPERADO}" ] && [ "${n_pat}" -eq "${PATRONES_ESPERADOS}" ]; then
	echo "pin:    OK, la lista es la anclada, ${n_pat} patrones y huella ${huella}"
else
	mal "pin:    FALLA, la lista dice ${n_pat} patrones y huella ${huella}, y el pin espera ${PATRONES_ESPERADOS} y ${PIN_ESPERADO}"
	mal "pin:    si el cambio es a proposito, re-ancla PIN_ESPERADO y PATRONES_ESPERADOS en este guion"
fi

# ---- una fila por patron ----
# Los mensajes se generan desde la lista leida. Cuando uno falla se nombra por su
# INDICE y no por su texto, para que ni la salida de esta prueba escriba lo que
# el hook mantiene fuera.
# El printf lleva \n al final, y esa es la diferencia entre probar la lista y
# probar todos menos el ultimo. Sin el, `read` recibe una ultima linea sin
# terminar, devuelve estado distinto de cero y el cuerpo del bucle NO corre para
# ella: la fila decia "los 7 se rechazan, uno a uno" habiendo probado seis, y
# siempre los mismos seis, porque el pin fija tambien el orden. Se demostro con
# un hook ciego SOLO al ultimo patron, con su lista y su pin intactos: las cinco
# filas salian verdes. Un brazo que certifica lo que no ha probado es peor que no
# tenerlo, asi que debajo va ademas la cuenta de visitas.
: > "${CAJON}/malos"
: > "${CAJON}/vistos"
printf '%s\n' "${ALT}" | tr '|' '\n' | while IFS= read -r pat; do
	[ -n "${pat}" ] || continue
	echo x >> "${CAJON}/vistos"
	printf 'titulo de prueba\n\ncuerpo con %s dentro\n' "${pat}" > "${CAJON}/m.txt"
	if sh "${HOOK}" "${CAJON}/m.txt" >/dev/null 2>&1; then
		echo x >> "${CAJON}/malos"
	fi
done
malos=$(grep -c . "${CAJON}/malos" || true)
vistos=$(grep -c . "${CAJON}/vistos" || true)
# La cuenta de visitas contra la de la lista es la anti-vacuidad de ESTA fila, y
# existe por el defecto de arriba: sin ella, un bucle que se salte patrones
# informa de un exito sobre un conjunto que nunca recorrio.
if [ "${vistos}" -ne "${n_pat}" ]; then
	mal "patron: FALLA, la lista tiene ${n_pat} patrones y el bucle visito ${vistos}"
elif [ "${malos}" -eq 0 ]; then
	echo "patron: OK, los ${n_pat} patrones de la lista se rechazan, uno a uno, y el bucle visito los ${vistos}"
else
	mal "patron: FALLA, ${malos} de ${n_pat} patrones no se rechazan"
fi

# ---- control ----
# Sin esta fila, un hook que rechazara TODO puntuaria igual de bien.
printf 'test(gate): un mensaje ordinario de este arbol\n\nCuerpo normal, sin nada que ocultar.\n' > "${CAJON}/limpio.txt"
if sh "${HOOK}" "${CAJON}/limpio.txt" >/dev/null 2>&1; then
	echo "limpio: OK, un mensaje ordinario pasa, asi que el hook no rechaza por rechazar"
else
	mal "limpio: FALLA, el hook rechaza un mensaje ordinario"
fi

# ---- ROJO DEL ROJO: el hook desenchufado ----
# Es la fila que dice que lo de arriba mide el hook y no otra cosa. Se monta un
# repositorio de usar y tirar y se commitea el mismo mensaje sucio con el hook y
# sin el.
#
# La configuracion global se desvia a la nada por algo que paso: en la maquina
# donde esto se escribio, la global trae firma GPG y el primer intento de esta
# fila se quedo colgado dos minutos esperando una clave. Un guion de prueba que
# hereda la configuracion de quien lo corre no prueba lo mismo en dos maquinas.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
R="${CAJON}/repo"
git init -q "${R}"
git -C "${R}" config user.email prueba@ejemplo
git -C "${R}" config user.name prueba
git -C "${R}" config commit.gpgsign false
primero=$(printf '%s' "${ALT}" | cut -d'|' -f1)
printf 'titulo de prueba\n\ncuerpo con %s dentro\n' "${primero}" > "${R}/sucio.txt"

printf 'a\n' > "${R}/a.txt"; git -C "${R}" add a.txt
sin_hook=0
git -C "${R}" commit -q -F "${R}/sucio.txt" >/dev/null 2>&1 || sin_hook=$?
n_sin=$(git -C "${R}" rev-list --count HEAD 2>/dev/null || echo 0)

cp "${HOOK}" "${R}/.git/hooks/commit-msg"
chmod +x "${R}/.git/hooks/commit-msg"
printf 'b\n' > "${R}/b.txt"; git -C "${R}" add b.txt
con_hook=0
git -C "${R}" commit -q -F "${R}/sucio.txt" >/dev/null 2>&1 || con_hook=$?
n_con=$(git -C "${R}" rev-list --count HEAD 2>/dev/null || echo 0)

if [ "${sin_hook}" -eq 0 ] && [ "${n_sin}" -eq 1 ] && [ "${con_hook}" -ne 0 ] && [ "${n_con}" -eq 1 ]; then
	echo "rojo:   OK, MUERDE: sin el hook el mensaje sucio entra en la historia, y con el no"
else
	mal "rojo:   FALLA, sin hook rc=${sin_hook} con ${n_sin} commits, con hook rc=${con_hook} con ${n_con}; la prueba no separa el hook de su ausencia"
fi

[ "${fallos}" -eq 0 ] || { echo "test: ${fallos} fallo(s)" >&2; exit 1; }
echo "test: el hook esta, su lista es la anclada, rechaza cada patron, deja pasar lo limpio, y sin el no hay defensa"
