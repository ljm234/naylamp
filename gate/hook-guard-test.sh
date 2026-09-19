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

# QUIEN ES ESTE BANCO, dicho en su PRIMERA linea de salida y en una forma que no
# es prosa. Entra el 8 de septiembre de 2026. El barrido que revisa el archivo de
# corridas/ clasificaba cada captura buscando por el CUERPO el texto de alguna de
# sus filas, y eso tiene dos agujeros medidos: el texto de una fila se reescribe,
# y entonces las capturas de ese banco dejan de existir para el barrido sin que
# nadie lo note; y un informe ESCRITO que cita unas filas se cuenta como corrida,
# que es como cuatro analisis del archivo acabaron contados como capturas. Una
# cita vive siempre por el medio de un fichero, nunca en su primera linea, asi que
# esta linea distingue una corrida de una cita a una corrida.
echo "BANCO: hook-guard-test"

AQUI=$(cd "$(dirname "$0")" && pwd)
RAIZ_REPO=$(cd "${AQUI}/.." && pwd)

# Y SE TRABAJA DESDE LA RAIZ DEL REPOSITORIO, que es lo que la linea de uso
# promete y no cumplia. Un lector lo corrio desde /tmp: el hook hace
# `git rev-parse --show-toplevel` desde el directorio de trabajo, sin raiz sale
# con uno, y la fila `limpio` salia FALLA. Peor que el rojo falso: corrido desde
# OTRO repositorio, las filas de shas juzgarian contra la historia equivocada y
# podrian salir verdes por la razon que no es.
cd "${RAIZ_REPO}" || {
	echo "test: no se pudo entrar en ${RAIZ_REPO}" >&2
	exit 1
}

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
# LA BANDERA DE TERMINACION, y la trae un lector adversarial del 8 de septiembre
# de 2026. Una trampa EXIT se COME el estado de salida cuando el guion muere por
# `set -e` o `set -u`: medido en el `/bin/sh` de esta maquina, que es bash 3.2,
# un abortado pasa de rc 1 a rc 0 en cuanto hay trampa. Y preservar `$?` dentro
# de la trampa NO lo arregla, porque para entonces ya vale 0. Medido sobre este
# banco: con una variable sin definir a mitad, imprimia cuatro filas verdes,
# ningun RESULTADO, y salia con CERO. Los tres guardias de vacuidad que este
# fichero tiene quedaban anulados de golpe.
#
# Lo que si funciona en todos los shells es una bandera: la trampa comprueba si
# el guion llego a su resumen, y si no, lo DICE y sale con uno. Un abortado deja
# de ser indistinguible de un verde.
COMPLETO=0
limpia_y_cierra() {
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2
		rm -rf -- "$CAJON" 2>/dev/null || true
		exit 1
	fi
	rm -rf -- "$CAJON" 2>/dev/null || true
}
trap limpia_y_cierra EXIT

fallos=0
# EL BANCO CUENTA SUS PROPIAS FILAS, y hasta hoy no lo hacia: el total que se
# publicaba de el estaba TECLEADO A MANO en el crudo, que es exactamente el
# defecto que el mensaje de 29b40a7 dice haber arreglado en el otro banco,
# `RESULTADO: $(( 41 ))`. Un banco cuyo total no sale de sus filas puede mentir
# sobre si mismo en cuanto alguien anada una. Cada fila pasa por aqui, verde o
# roja, y el resumen del final se deriva de este fichero.
ROW_LOG="${CAJON}/bench-rows"
: > "${ROW_LOG}"
ok()  { echo "$1"; printf '%s\n' "OK" >> "${ROW_LOG}"; }
mal() { echo "$1" >&2; printf '%s\n' "FAILING" >> "${ROW_LOG}"; fallos=$((fallos + 1)); }

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
	ok "lista:  OK, ${n_pat} patrones leidos del hook, y sus dos alternancias casan"
else
	echo "lista:  ${n_pat} patrones leidos de la primera alternancia; la segunda no casa, ver arriba"
fi

# ---- el PIN ----
# La prueba hereda sus expectativas del objeto, asi que no puede ver que le
# borren un patron: probaria menos y seguiria verde. El pin lo ve.
huella=$(printf '%s' "${ALT}" | shasum -a 256 | cut -c1-16)
if [ "${huella}" = "${PIN_ESPERADO}" ] && [ "${n_pat}" -eq "${PATRONES_ESPERADOS}" ]; then
	ok "pin:    OK, la lista es la anclada, ${n_pat} patrones y huella ${huella}"
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
	ok "patron: OK, los ${n_pat} patrones de la lista se rechazan, uno a uno, y el bucle visito los ${vistos}"
else
	mal "patron: FALLA, ${malos} de ${n_pat} patrones no se rechazan"
fi

# ---- control ----
# Sin esta fila, un hook que rechazara TODO puntuaria igual de bien.
printf 'test(gate): un mensaje ordinario de este arbol\n\nCuerpo normal, sin nada que ocultar.\n' > "${CAJON}/limpio.txt"
if sh "${HOOK}" "${CAJON}/limpio.txt" >/dev/null 2>&1; then
	ok "limpio: OK, un mensaje ordinario pasa, asi que el hook no rechaza por rechazar"
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

# EL REPO DE USAR Y TIRAR RECIBE TAMBIEN LA GUARDA VERSIONADA, y sin esta
# linea esta fila pasaba por la razon equivocada. Desde el 7 de septiembre de
# 2026 el hook llama a gate/msg-shas.sh y se niega si no lo encuentra, asi que
# en un repo sin ese fichero rechaza TODO. Medido antes de escribir esto: un
# mensaje limpio, sin patron y sin sha, salia rechazado ahi con "falta
# .../gate/msg-shas.sh". Un rechazo que ocurre pase lo que pase no distingue
# nada, y esta fila existe para distinguir.
mkdir -p "${R}/gate"
cp "${RAIZ_REPO}/gate/msg-shas.sh" "${R}/gate/msg-shas.sh"
cp "${HOOK}" "${R}/.git/hooks/commit-msg"
chmod +x "${R}/.git/hooks/commit-msg"
printf 'b\n' > "${R}/b.txt"; git -C "${R}" add b.txt
con_hook=0
git -C "${R}" commit -q -F "${R}/sucio.txt" >/dev/null 2>&1 || con_hook=$?
n_con=$(git -C "${R}" rev-list --count HEAD 2>/dev/null || echo 0)

# Y EL CONTROL DE ESTA FILA, que es lo que la vuelve una medida. Con el hook
# puesto y la guarda al lado, un mensaje LIMPIO tiene que entrar. Sin esto, la
# fila daria OK con un hook que rechazara por sistema, que es justo el estado en
# el que la dejo la primera version del hook nuevo.
printf 'un mensaje ordinario del repo de usar y tirar\n' > "${R}/limpio2.txt"
printf 'c\n' > "${R}/c.txt"; git -C "${R}" add c.txt
limpio_rc=0
git -C "${R}" commit -q -F "${R}/limpio2.txt" >/dev/null 2>&1 || limpio_rc=$?
n_limpio=$(git -C "${R}" rev-list --count HEAD 2>/dev/null || echo 0)

if [ "${sin_hook}" -eq 0 ] && [ "${n_sin}" -eq 1 ] && [ "${con_hook}" -ne 0 ] && [ "${n_con}" -eq 1 ]; then
	if [ "${limpio_rc}" -eq 0 ] && [ "${n_limpio}" -eq 2 ]; then
		ok "rojo:   OK, MUERDE: sin el hook el mensaje sucio entra en la historia, con el no, y uno limpio si entra"
	else
		mal "rojo:   FALLA, el hook rechaza tambien un mensaje limpio (rc=${limpio_rc}, ${n_limpio} commits); rechaza por sistema y esta fila no mide nada"
	fi
else
	mal "rojo:   FALLA, sin hook rc=${sin_hook} con ${n_sin} commits, con hook rc=${con_hook} con ${n_con}; la prueba no separa el hook de su ausencia"
fi

# ======================================================================
# LA SEGUNDA GUARDA: los shas que un mensaje CITA tienen que estar en la rama.
# ======================================================================
#
# Entra el 7 de septiembre de 2026 y la trae un defecto que ya esta en historia
# compartida: el mensaje de ae8e5f9 cita 9ce3623, que dejo de existir en la rama
# cuando el commit anterior se enmendo antes de empujar.
#
# POR QUE ESTAS FILAS SE PRUEBAN DE OTRA MANERA QUE LAS DE ARRIBA, y es la
# clausula 16 funcionando en vez de citandose. Las de arriba no se automatizan
# porque su objeto, la lista de patrones, no se puede versionar sin meter en el
# arbol lo que existe para mantener fuera. Esta guarda no tiene ese problema: su
# logica no nombra nada prohibido, asi que vive en gate/msg-shas.sh, DENTRO del
# arbol. Por eso no lleva pin: un cambio en ella sale como diff, que es la
# defensa que a la otra le falta. Cambiar que cuenta como evidencia es lo que la
# clausula 16 pide para poder automatizar, y aqui se hizo.
#
# TODAS LAS FILAS CORREN EN REPOSITORIOS DE USAR Y TIRAR y ninguna depende del
# estado del arbol real. Se penso lo contrario primero: 9ce3623 sigue vivo en
# esta copia y una fila podia apuntarle. No se hace, porque ese objeto es
# colgante y desaparece con el primer `git gc`, y una fila que caduca sola es
# peor que ninguna. La medida contra el caso real va aparte, en su crudo.

GUARDA="${RAIZ_REPO}/gate/msg-shas.sh"
if [ ! -r "${GUARDA}" ]; then
	echo "test: NO HAY GUARDA DE SHAS en ${GUARDA}" >&2
	echo "test: el hook la llama, asi que esta copia no puede commitear nada" >&2
	echo "test: eso no es un fallo de esta prueba, es su resultado" >&2
	exit 1
fi

# El banco de pruebas: main con dos commits, y una rama lateral con un tercero
# que NO es ancestro de main. Es la forma exacta del defecto que la trajo.
S="${CAJON}/shas"
git init -q -b main "${S}"
git -C "${S}" config user.email prueba@ejemplo
git -C "${S}" config user.name prueba
git -C "${S}" config commit.gpgsign false
printf 'uno\n' > "${S}/a.txt"; git -C "${S}" add a.txt
git -C "${S}" commit -q -m "primero"
SHA_A=$(git -C "${S}" rev-parse --short=7 HEAD)
printf 'dos\n' > "${S}/b.txt"; git -C "${S}" add b.txt
git -C "${S}" commit -q -m "segundo"
SHA_B=$(git -C "${S}" rev-parse --short=7 HEAD)
git -C "${S}" checkout -q -b lateral
printf 'tres\n' > "${S}/c.txt"; git -C "${S}" add c.txt
git -C "${S}" commit -q -m "lateral"
SHA_C=$(git -C "${S}" rev-parse --short=7 HEAD)
git -C "${S}" checkout -q main

# Anti-vacuidad del propio banco: si los tres shas no salieran distintos, o si
# el lateral resultara ancestro de main, todas las filas de abajo mirarian otra
# cosa y saldrian verdes sin medir nada.
if [ "${SHA_A}" = "${SHA_B}" ] || [ "${SHA_B}" = "${SHA_C}" ] || [ "${SHA_A}" = "${SHA_C}" ]; then
	echo "test: VACIO. El banco de shas no produjo tres commits distintos" >&2
	exit 1
fi
if git -C "${S}" merge-base --is-ancestor "${SHA_C}" HEAD 2>/dev/null; then
	echo "test: VACIO. El commit lateral SI es ancestro de main, asi que no hay caso que probar" >&2
	exit 1
fi

# corre_guarda <fichero de mensaje>: deja el rc en GUARDA_RC y la salida
# completa, las dos corrientes, en GUARDA_OUT. El rc se captura y se decide, que
# es la forma que la clausula 18 fija para este arbol.
GUARDA_OUT="${CAJON}/guarda.out"
corre_guarda() {
	GUARDA_RC=0
	sh "${GUARDA}" "$1" "${S}" > "${GUARDA_OUT}" 2>&1 || GUARDA_RC=$?
}

# ---- control: un mensaje que no cita ningun sha ----
# Sin esta fila, una guarda que rechazara todo puntuaria igual de bien.
printf 'titulo corriente\n\nun cuerpo sin nada hexadecimal dentro.\n' > "${CAJON}/s-limpio.txt"
corre_guarda "${CAJON}/s-limpio.txt"
if [ "${GUARDA_RC}" -eq 0 ]; then
	ok "sha-0:  OK, un mensaje que no cita ningun sha pasa"
else
	mal "sha-0:  FALLA, rc=${GUARDA_RC} sobre un mensaje sin shas"
fi

# ---- el otro lado, y es el que decide si esta guarda es usable ----
# Un mensaje de este proyecto lleva huellas de 16 hex, ids de corrida de CI todo
# digitos y numeros sueltos, y los tres casan [0-9a-f]{7,40}. Juzgarlos como
# shas rechazaria 19 de los 159 mensajes de esta historia, casi todos mal, y una
# guarda con esa tasa se apaga. Por eso solo se juzga lo que el repositorio
# resuelve a un commit.
printf 'titulo\n\nhuella 4117c791b71fa90c y d0efc53004b185c9, corrida 34178238183, y 2000000 vectores.\n' > "${CAJON}/s-huellas.txt"
corre_guarda "${CAJON}/s-huellas.txt"
if [ "${GUARDA_RC}" -eq 0 ]; then
	ok "sha-1:  OK, huellas de 16 hex, un id de corrida y un numero suelto NO se juzgan como shas"
else
	mal "sha-1:  FALLA, rc=${GUARDA_RC}; la guarda rechaza tokens que no nombran ningun commit, y con esa tasa se apaga"
fi

# ---- un sha que SI esta en la rama ----
printf 'titulo\n\nel primero entro en %s y el segundo en %s.\n' "${SHA_A}" "${SHA_B}" > "${CAJON}/s-rama.txt"
corre_guarda "${CAJON}/s-rama.txt"
if [ "${GUARDA_RC}" -eq 0 ]; then
	ok "sha-2:  OK, un mensaje que cita dos shas de la rama pasa"
else
	mal "sha-2:  FALLA, rc=${GUARDA_RC} citando shas que SI son ancestros"
fi

# ---- LA FILA QUE LA TRAE: un sha ajeno a la rama, rechazado y NOMBRADO ----
# Las dos mitades importan. Que rechace, y que diga cual, porque un rechazo que
# no nombra el sha deja a quien firma buscandolo a mano en un mensaje largo.
printf 'titulo\n\nesto lo cierra el commit %s, dice el mensaje.\n' "${SHA_C}" > "${CAJON}/s-ajeno.txt"
corre_guarda "${CAJON}/s-ajeno.txt"
if [ "${GUARDA_RC}" -eq 1 ] && grep -q "${SHA_C}" "${GUARDA_OUT}"; then
	ok "sha-3:  OK, un sha ajeno a la rama sale RECHAZADO y con el sha nombrado en la salida"
elif [ "${GUARDA_RC}" -eq 1 ]; then
	mal "sha-3:  FALLA, rechaza pero NO nombra ${SHA_C} en su salida"
else
	mal "sha-3:  FALLA, rc=${GUARDA_RC}; un sha que no esta en la rama pasa"
fi

# ---- y que el rechazo sea por ANCESTRIA y no por existencia ----
# Es la distincion entera de esta guarda. El commit lateral EXISTE en el almacen
# de ese repositorio: cat-file lo da por bueno. Si esta fila no estuviera, una
# guarda escrita con cat-file pasaria todas las de arriba y no pararia nada.
tipo_c=$(git -C "${S}" cat-file -t "${SHA_C}" 2>/dev/null || echo "")
if [ "${tipo_c}" = commit ]; then
	ok "sha-4:  OK, el sha rechazado EXISTE como commit en el almacen, asi que lo que lo rechaza es la ancestria y no la existencia"
else
	mal "sha-4:  FALLA, cat-file dice '${tipo_c}' del sha lateral; esta fila ya no prueba la distincion que existe para probar"
fi

# ---- lo que git va a tirar no se juzga: comentarios y tijeras ----
# Un sha bajo la linea de tijeras de `git commit -v` esta dentro del diff, no del
# mensaje, y las lineas del diff no llevan la marca de comentario delante. Sin
# este corte, un literal hexadecimal de un parche se leeria como cita.
{
	printf 'titulo\n\ncuerpo limpio.\n'
	printf '# un comentario que nombra %s\n' "${SHA_C}"
	printf '# ------------------------ >8 ------------------------\n'
	printf 'diff --git a/x b/x\n+const h = "%s"\n' "${SHA_C}"
} > "${CAJON}/s-tijeras.txt"
corre_guarda "${CAJON}/s-tijeras.txt"
if [ "${GUARDA_RC}" -eq 0 ]; then
	ok "sha-5:  OK, un sha ajeno en un comentario o bajo las tijeras no se juzga, porque git no lo guarda"
else
	mal "sha-5:  FALLA, rc=${GUARDA_RC}; la guarda juzga texto que git va a tirar"
fi

# ---- un repositorio sin commits todavia ----
# Se responde, no se salta. Sin punta ningun sha citado puede estar en la rama.
# EL REPOSITORIO VACIO COMPARTE LOS OBJETOS DEL DE ARRIBA, y sin eso esta fila
# no atravesaba la rama que dice probar: en un repositorio recien creado el sha
# citado no resuelve, asi que se saltaba antes de llegar a mirar la punta. Con
# los objetos prestados, el sha SI resuelve y HEAD sigue sin nacer, que es el
# unico estado en el que esa rama corre.
V="${CAJON}/vacio"
git init -q -b main "${V}"
printf '%s\n' "$(cd "${S}" && pwd)/.git/objects" > "${V}/.git/objects/info/alternates"
printf 'titulo\n\nesto viene de %s.\n' "${SHA_C}" > "${CAJON}/s-vacio.txt"
vacio_rc=0
sh "${GUARDA}" "${CAJON}/s-vacio.txt" "${V}" > "${CAJON}/vacio.out" 2>&1 || vacio_rc=$?
# En un repositorio recien creado el objeto del otro no existe, asi que la
# guarda lo salta y pasa. Es lo correcto y hay que decirlo: la fila mide que NO
# revienta con HEAD sin nacer, que era la unica forma de que este camino matara
# la firma por una excepcion.
if [ "${vacio_rc}" -eq 1 ] && grep -q 'no commits yet' "${CAJON}/vacio.out"; then
	ok "sha-6:  OK, con HEAD sin nacer y el sha resolviendo, la guarda RECHAZA y lo dice, en vez de reventar o de callar"
else
	mal "sha-6:  FALLA, rc=${vacio_rc} con HEAD sin nacer; la salida fue: $(head -1 "${CAJON}/vacio.out")"
fi

# ---- un oid que NO es un commit no es cosa de esta guarda ----
# Sin esta fila el filtro de tipo era codigo que nadie habia visto correr, y sin
# el filtro un blob citado llega a merge-base y sale rechazado por serlo.
BLOB=$(git -C "${S}" rev-parse HEAD:a.txt)
printf 'titulo\n\nel contenido vive en %s.\n' "${BLOB}" > "${CAJON}/s-blob.txt"
corre_guarda "${CAJON}/s-blob.txt"
if [ "${GUARDA_RC}" -eq 0 ]; then
	ok "sha-6b: OK, un oid que es un BLOB y no un commit se salta, que es lo que el filtro de tipo existe para hacer"
else
	mal "sha-6b: FALLA, rc=${GUARDA_RC} citando un blob; sin filtro de tipo un oid que no es commit sale rechazado"
fi

# ---- fail-closed: un mensaje ilegible NO es un pase ----
corre_guarda "${CAJON}/no-existe-este-fichero.txt"
# SE EXIGE LA LINEA Y NO SOLO EL RC, porque `awk` sobre un fichero que no existe
# sale con 2 por su cuenta y bajo `set -eu` ese 2 es el rc del guion: la fila
# certificaba un fail-closed que no estaba midiendo, y seguia verde con el
# bloque explicito borrado.
if [ "${GUARDA_RC}" -eq 2 ] && grep -q 'cannot read the message' "${GUARDA_OUT}"; then
	ok "sha-7:  OK, un mensaje ilegible sale con 2 Y lo dice: no es ni pase ni rechazo sino la guarda diciendo que no pudo correr"
else
	mal "sha-7:  FALLA, rc=${GUARDA_RC} sobre un mensaje ilegible; un instrumento que no puede correr no dice que si"
fi

# ---- un prefijo AMBIGUO se rechaza, y esta fila se dispara con un git de mentira ----
# Un prefijo de siete hex que nombre dos objetos no se puede fabricar a mano: la
# paradoja del cumpleanos sobre 16^7 pide del orden de veinte mil commits. Asi
# que el camino se ejerce interponiendo un `git` que contesta dos lineas a esa
# sola pregunta y delega todo lo demas en el de verdad. Sin esta fila, la rama
# de la ambiguedad seria codigo que nadie ha visto correr.
MENTIRA="${CAJON}/bin"
mkdir -p "${MENTIRA}"
GIT_REAL=$(command -v git)
cat > "${MENTIRA}/git" <<GITEOF
#!/bin/sh
for a in "\$@"; do
	case "\$a" in
		--disambiguate=aaaaaaa)
			echo aaaaaaa000000000000000000000000000000001
			echo aaaaaaa000000000000000000000000000000002
			exit 0
			;;
	esac
done
exec "${GIT_REAL}" "\$@"
GITEOF
chmod +x "${MENTIRA}/git"
printf 'titulo\n\nesto lo trae aaaaaaa, dice el mensaje.\n' > "${CAJON}/s-ambiguo.txt"
amb_rc=0
PATH="${MENTIRA}:${PATH}" sh "${GUARDA}" "${CAJON}/s-ambiguo.txt" "${S}" > "${CAJON}/amb.out" 2>&1 || amb_rc=$?
# El control del propio `git` de mentira: sin el, esta fila no distingue "la
# guarda rechaza la ambiguedad" de "el git de mentira rompio la guarda entera".
ctrl_rc=0
PATH="${MENTIRA}:${PATH}" sh "${GUARDA}" "${CAJON}/s-rama.txt" "${S}" > "${CAJON}/amb-ctrl.out" 2>&1 || ctrl_rc=$?
# Y SE EXIGE LA RAZON Y NO SOLO EL RECHAZO, porque la primera version de esta
# fila no distinguia. Rebobinada la rama de la ambiguedad, el token seguia
# saliendo rechazado por OTRO camino, el del tipo ilegible, y la fila daba OK
# sobre un defecto que no habia visto. Ahora se comprueba que la salida diga que
# nombra dos objetos, que es lo unico que solo esa rama escribe.
if [ "${amb_rc}" -eq 1 ] && grep -q 'aaaaaaa' "${CAJON}/amb.out" \
   && grep -q 'names 2 objects' "${CAJON}/amb.out" && [ "${ctrl_rc}" -eq 0 ]; then
	ok "sha-8:  OK, un prefijo que nombra dos objetos se RECHAZA por ambiguo, con esa razon escrita, y con el mismo git de mentira un mensaje bueno sigue pasando"
elif [ "${ctrl_rc}" -ne 0 ]; then
	mal "sha-8:  FALLA, el git interpuesto rompe tambien el caso bueno (rc=${ctrl_rc}); esta fila no mide la ambiguedad"
elif [ "${amb_rc}" -eq 1 ]; then
	mal "sha-8:  FALLA, rechaza el prefijo ambiguo pero por otra razon: $(head -1 "${CAJON}/amb.out")"
else
	mal "sha-8:  FALLA, rc=${amb_rc} sobre un prefijo ambiguo; un sha que no identifica un commit se cuela"
fi

# ---- DE PUNTA A PUNTA: que el HOOK la llame, y no solo que la guarda funcione ----
# Las filas de arriba prueban el guion. Esta prueba el cableado: se commitea de
# verdad, con el hook puesto, un mensaje que cita un sha ajeno.
git -C "${S}" config user.email prueba@ejemplo
mkdir -p "${S}/gate"
cp "${GUARDA}" "${S}/gate/msg-shas.sh"
cp "${HOOK}" "${S}/.git/hooks/commit-msg"
chmod +x "${S}/.git/hooks/commit-msg"
antes=$(git -C "${S}" rev-list --count HEAD)
printf 'd\n' > "${S}/d.txt"; git -C "${S}" add d.txt
e2e_rc=0
git -C "${S}" commit -q -F "${CAJON}/s-ajeno.txt" > "${CAJON}/e2e.out" 2>&1 || e2e_rc=$?
despues=$(git -C "${S}" rev-list --count HEAD)
if [ "${e2e_rc}" -ne 0 ] && [ "${despues}" -eq "${antes}" ] && grep -q "${SHA_C}" "${CAJON}/e2e.out"; then
	ok "sha-9:  OK, DE PUNTA A PUNTA: git commit se para, no entra nada en la historia, y el sha va nombrado en la salida"
else
	mal "sha-9:  FALLA, commit rc=${e2e_rc}, commits ${antes}->${despues}; el hook no esta llamando a la guarda"
fi

# ---- LA PUNTA CITADA, que es el agujero que un lector encontro abierto ----
# Un commit es ancestro de si mismo, asi que citar la punta pasaba siempre. Bajo
# `--amend` la punta se REEMPLAZA y esa cita queda huerfana en el acto: es la
# forma exacta del defecto original, aprobada por la guarda. Medido antes de
# cerrarlo, con el hook puesto: un mensaje que decia "esto reemplaza a 8a4c501"
# entro en su propio amend con OK.
printf 'titulo\n\nesto reemplaza a %s.\n' "${SHA_B}" > "${CAJON}/s-punta.txt"
punta_rc=0
NAYLAMP_MSG_PUNTA=reemplazada sh "${GUARDA}" "${CAJON}/s-punta.txt" "${S}" > "${CAJON}/punta.out" 2>&1 || punta_rc=$?
if [ "${punta_rc}" -eq 1 ] && grep -q "REPLACES the tip" "${CAJON}/punta.out"; then
	ok "sha-10: OK, citar la punta con la punta REEMPLAZADA sale rechazado, y la razon dice que es un amend"
else
	mal "sha-10: FALLA, rc=${punta_rc} citando la punta en un amend; el defecto original vuelve a entrar"
fi

# ---- y el control, sin el cual lo de arriba seria rechazar por rechazar ----
# Un commit NORMAL que cita la punta cita a su propio padre futuro, y eso es
# legitimo: medido sobre esta historia, 2 de los 159 mensajes lo hacen.
punta_ok=0
NAYLAMP_MSG_PUNTA=intacta sh "${GUARDA}" "${CAJON}/s-punta.txt" "${S}" > "${CAJON}/punta2.out" 2>&1 || punta_ok=$?
punta_des=0
NAYLAMP_MSG_PUNTA=desconocida sh "${GUARDA}" "${CAJON}/s-punta.txt" "${S}" > "${CAJON}/punta3.out" 2>&1 || punta_des=$?
if [ "${punta_ok}" -eq 0 ] && [ "${punta_des}" -eq 1 ]; then
	ok "sha-11: OK, con la punta INTACTA la misma cita pasa, y con DESCONOCIDA se rechaza: un ilegible no es un pase"
elif [ "${punta_ok}" -ne 0 ]; then
	mal "sha-11: FALLA, rc=${punta_ok} con la punta intacta; rechaza una cita legitima al padre"
else
	mal "sha-11: FALLA, rc=${punta_des} con la punta desconocida; un ilegible esta pasando por bueno"
fi

# ---- un sha en MAYUSCULAS ----
# git resuelve C108109 igual que c108109. El filtro solo miraba minusculas, asi
# que un mensaje que citaba en mayusculas entraba con "cites no sha".
MAY=$(printf '%s' "${SHA_C}" | tr 'a-f' 'A-F')
printf 'titulo\n\nviene de %s.\n' "${MAY}" > "${CAJON}/s-may.txt"
corre_guarda "${CAJON}/s-may.txt"
if [ "${GUARDA_RC}" -eq 1 ] && grep -q "${MAY}" "${GUARDA_OUT}"; then
	ok "sha-12: OK, un sha ajeno escrito en MAYUSCULAS tambien se caza y se nombra"
else
	mal "sha-12: FALLA, rc=${GUARDA_RC} sobre un sha ajeno en mayusculas; el filtro sigue siendo de minusculas"
fi

# ---- un git que FALLA no es un git que dice que no hay nada ----
# Era el unico fail-open del guion: el estado de la tuberia era el de `tr`, asi
# que un git roto convertia un RECHAZO en un OK.
ROTO="${CAJON}/bin-roto"
mkdir -p "${ROTO}"
cat > "${ROTO}/git" <<GITEOF
#!/bin/sh
for a in "\$@"; do
	case "\$a" in --disambiguate=*) exit 3 ;; esac
done
exec "${GIT_REAL}" "\$@"
GITEOF
chmod +x "${ROTO}/git"
roto_rc=0
PATH="${ROTO}:${PATH}" sh "${GUARDA}" "${CAJON}/s-ajeno.txt" "${S}" > "${CAJON}/roto.out" 2>&1 || roto_rc=$?
if [ "${roto_rc}" -eq 1 ] && grep -q 'git failed' "${CAJON}/roto.out"; then
	ok "sha-13: OK, un git que falla al resolver sale RECHAZADO con su rc, no saltado como si el token no fuera un sha"
else
	mal "sha-13: FALLA, rc=${roto_rc} con un git roto; un fallo del instrumento se esta leyendo como pase"
fi

# ======================================================================
# EL PASO CERO: el mensaje esta donde la convencion lo pone.
# ======================================================================
#
# Entra el 8 de septiembre de 2026 y lo trae una firma que no ocurrio. El
# mensaje se escribio en `<repo>/mensajes/01`; la convencion es
# `<workspace>/mensajes/NN-nombre-commit-msg.txt`, FUERA del repositorio. El
# glob de la firma no caso nada, el `-F` salio vacio y `git commit` fallo con
# HEAD quieto y los ficheros en el indice.
#
# TODAS LAS FILAS CORREN EN UN ARBOL DE MENTIRA, con la forma
# <caja>/ws/repo/gate y <caja>/ws/mensajes, porque el guion deriva el directorio
# de la convencion de su propia ruta y una fila que dependiera del workspace de
# verdad mediria el estado de la maquina y no el codigo.

SITIO="${RAIZ_REPO}/gate/msg-sitio.sh"
if [ ! -r "${SITIO}" ]; then
	echo "test: NO HAY GUARDA DEL SITIO en ${SITIO}" >&2
	echo "test: la lista de firma la nombra, asi que ese paso no se puede dar" >&2
	exit 1
fi

WS="${CAJON}/ws"
mkdir -p "${WS}/repo/gate" "${WS}/mensajes"
cp "${SITIO}" "${WS}/repo/gate/msg-sitio.sh"
SIT="${WS}/repo/gate/msg-sitio.sh"
SIT_OUT="${CAJON}/sitio.out"
SIT_ERR="${CAJON}/sitio.err"
corre_sitio() {
	SIT_RC=0
	sh "${SIT}" "$1" > "${SIT_OUT}" 2> "${SIT_ERR}" || SIT_RC=$?
}

# ---- LA FILA QUE LO TRAE: un glob que no casa nada ----
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'matches no file' "${SIT_ERR}" && [ ! -s "${SIT_OUT}" ]; then
	ok "sit-0:  OK, un glob que no casa nada sale RECHAZADO, lo dice, y NO imprime nada por salida"
else
	mal "sit-0:  FALLA, rc=${SIT_RC} sobre un glob vacio; es lo que dejo el -F sin argumento y la firma sin ocurrir"
fi

# ---- el control: exactamente uno, y lo imprime ----
printf 'titulo\n\ncuerpo\n' > "${WS}/mensajes/01-prueba-commit-msg.txt"
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
if [ "${SIT_RC}" -eq 0 ] && [ "$(grep -c . "${SIT_OUT}")" -eq 1 ]; then
	ok "sit-1:  OK, con un solo fichero en el sitio pasa y devuelve esa unica ruta, que es lo que la firma consume"
else
	mal "sit-1:  FALLA, rc=${SIT_RC} con el fichero en su sitio; rechaza por rechazar"
fi

# ---- dos ficheros: la firma toma uno ----
printf 'otro\n' > "${WS}/mensajes/02-otro-commit-msg.txt"
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'matches 2 files' "${SIT_ERR}"; then
	ok "sit-2:  OK, dos ficheros en el sitio se rechazan nombrando los dos, en vez de firmar uno al azar"
else
	mal "sit-2:  FALLA, rc=${SIT_RC} con dos ficheros; la firma tomaria uno sin decir cual"
fi
rm -f "${WS}/mensajes/02-otro-commit-msg.txt"

# ---- LA TRAMPA: un mensajes/ dentro del repositorio ----
# Muerde aunque el fichero de fuera este bien, porque la trampa no es de firma:
# un git add -A commitea ese directorio como contenido del arbol.
mkdir -p "${WS}/repo/mensajes"
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'INSIDE the repository' "${SIT_ERR}"; then
	ok "sit-3:  OK, un mensajes/ dentro del repositorio se rechaza AUNQUE el de fuera este bien: ignorado no es ausente"
else
	mal "sit-3:  FALLA, rc=${SIT_RC} con la trampa puesta; se firma con un directorio que un git add -A commitearia"
fi
rmdir "${WS}/repo/mensajes"

# ---- un fichero legible pero fuera de la convencion ----
# LA FIXTURE ESTA FUERA DEL REPOSITORIO A PROPOSITO, y la primera version no lo
# estaba: un fichero dentro del arbol de trabajo lo rechaza la OTRA comprobacion,
# la de la trampa, asi que la fila daba verde con la comprobacion del sitio
# borrada. Medido rebobinandola. Este vive al lado de la convencion, no dentro,
# asi que solo la comprobacion del sitio lo puede parar.
printf 'titulo\n' > "${WS}/suelto-commit-msg.txt"
corre_sitio "${WS}/suelto-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'is not in' "${SIT_ERR}"; then
	ok "sit-4:  OK, un mensaje fuera de la convencion y fuera del repo se rechaza igual: lo que decide es el SITIO"
else
	mal "sit-4:  FALLA, rc=${SIT_RC} sobre un mensaje fuera del sitio; la convencion no se esta comprobando"
fi

# ---- LA TRAMPA A CUALQUIER PROFUNDIDAD ----
# sit-3 solo pone el directorio en la RAIZ. Un lector midio que `gate/mensajes/`
# era invisible para la guarda Y commiteable por `git add -A`, o sea las dos
# tapas fallando a la vez a un nivel de profundidad.
mkdir -p "${WS}/repo/gate/mensajes"
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'INSIDE the repository' "${SIT_ERR}"; then
	ok "sit-4b: OK, un mensajes/ ANIDADO tambien se caza, no solo el de la raiz"
else
	mal "sit-4b: FALLA, rc=${SIT_RC} con gate/mensajes/ puesto; la trampa a un nivel de profundidad pasa"
fi
rmdir "${WS}/repo/gate/mensajes"

# ---- UN ENLACE SIMBOLICO NO ES EL FICHERO ----
# `-f` sigue el enlace, asi que un enlace en el sitio correcto apuntando a
# cualquier parte pasaba: las comprobaciones juzgaban la ruta del ENLACE y la
# firma habria leido el contenido del DESTINO. Medido por un lector con un
# enlace hacia dentro del arbol de trabajo.
printf 'contenido ajeno\n' > "${WS}/repo/ajeno.txt"
ln -sf "${WS}/repo/ajeno.txt" "${WS}/mensajes/09-enlace-commit-msg.txt"
corre_sitio "${WS}/mensajes/09-enlace-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'symbolic link' "${SIT_ERR}"; then
	ok "sit-6:  OK, un enlace simbolico se rechaza nombrando su destino, en vez de juzgar la ruta del enlace"
else
	mal "sit-6:  FALLA, rc=${SIT_RC} sobre un enlace; se firmaria con el contenido del destino"
fi
rm -f "${WS}/mensajes/09-enlace-commit-msg.txt"

# ---- EXISTIR NO ES PODER LEERSE ----
printf 'titulo\n' > "${WS}/mensajes/08-sinleer-commit-msg.txt"
chmod 000 "${WS}/mensajes/08-sinleer-commit-msg.txt"
corre_sitio "${WS}/mensajes/08-sinleer-commit-msg.txt"
sit_leer="${SIT_RC}"
chmod 644 "${WS}/mensajes/08-sinleer-commit-msg.txt"
rm -f "${WS}/mensajes/08-sinleer-commit-msg.txt"
if [ "${sit_leer}" -eq 1 ]; then
	ok "sit-7:  OK, un fichero que existe y no se puede LEER se rechaza; la firma tiene que consumirlo, no solo encontrarlo"
else
	mal "sit-7:  FALLA, rc=${sit_leer} sobre un fichero sin permiso de lectura; se entrega un argumento que no se puede consumir"
fi

# ---- UN ESPACIO EN EL NOMBRE NO PARTE LA CUENTA ----
# Con el IFS por defecto, `for c in ${PATRON}` parte por espacios antes de que el
# glob se expanda: un unico fichero con un espacio se contaba como DOS, y la
# misma ruta escrita literal salia rechazada mientras por glob pasaba.
printf 'titulo\n' > "${WS}/mensajes/07-con espacio-commit-msg.txt"
rm -f "${WS}/mensajes/01-prueba-commit-msg.txt"
corre_sitio "${WS}/mensajes/07-con espacio-commit-msg.txt"
sit_esp_lit="${SIT_RC}"
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
sit_esp_glob="${SIT_RC}"
rm -f "${WS}/mensajes/07-con espacio-commit-msg.txt"
printf 'titulo\n\ncuerpo\n' > "${WS}/mensajes/01-prueba-commit-msg.txt"
if [ "${sit_esp_lit}" -eq 0 ] && [ "${sit_esp_glob}" -eq 0 ]; then
	ok "sit-8:  OK, un nombre con un espacio cuenta UNO, tanto por ruta literal como por glob"
else
	mal "sit-8:  FALLA, literal rc=${sit_esp_lit} y glob rc=${sit_esp_glob}; la cuenta se parte por el espacio"
fi

# ---- EL PATRON SIN COMILLAS, QUE EL SHELL YA EXPANDIO ----
# No es un error de uso: es la respuesta. Devolver 2 ahi mezclaba "no pude
# correr" con "casa varios", que son las dos cosas que este guion existe para
# separar.
printf 'titulo\n' > "${WS}/mensajes/06-otro-commit-msg.txt"
sinq_rc=0
sh "${SIT}" "${WS}/mensajes/01-prueba-commit-msg.txt" "${WS}/mensajes/06-otro-commit-msg.txt" > "${SIT_OUT}" 2> "${SIT_ERR}" || sinq_rc=$?
rm -f "${WS}/mensajes/06-otro-commit-msg.txt"
if [ "${sinq_rc}" -eq 1 ] && grep -q 'expanded by the caller' "${SIT_ERR}"; then
	ok "sit-9:  OK, un patron que el shell ya expandio en varios sale con 1 y lo dice, no con 2 de 'no pude correr'"
else
	mal "sit-9:  FALLA, rc=${sinq_rc} con el patron sin comillas; se confunde no poder correr con casar varios"
fi

# ---- y el directorio de la convencion ausente ----
mv "${WS}/mensajes" "${WS}/mensajes-guardado"
corre_sitio "${WS}/mensajes/*-commit-msg.txt"
if [ "${SIT_RC}" -eq 1 ] && grep -q 'convention directory' "${SIT_ERR}"; then
	ok "sit-5:  OK, sin el directorio de la convencion se rechaza nombrandolo, en vez de leerlo como un glob vacio mas"
else
	mal "sit-5:  FALLA, rc=${SIT_RC} sin el directorio; no distingue 'no hay mensaje' de 'no hay sitio'"
fi
mv "${WS}/mensajes-guardado" "${WS}/mensajes"

# ======================================================================
# EL TERCER PASO: las cifras de un mensaje contra el crudo que las sostiene.
# ======================================================================
#
# gate/msg-cifras.sh NO es un hook y no puede serlo: el hook no sabe que crudo
# respalda un mensaje, y quien firma si. Es un paso de la lista de firma, y sus
# filas viven aqui porque este banco es el de lo que se interpone entre un
# mensaje y la historia.
#
# Lo que decide es una sola cosa: si nombras un crudo como sosten del mensaje,
# el TOTAL de ese crudo tiene que estar en el mensaje. No al reves. Un mensaje
# menciona legitimamente cifras parciales y etapas anteriores; lo que no puede
# es no llevar el total del fichero que dice tener detras.

CIFRAS="${RAIZ_REPO}/gate/msg-cifras.sh"
if [ ! -r "${CIFRAS}" ]; then
	echo "test: NO HAY PASO DE CIFRAS en ${CIFRAS}" >&2
	echo "test: la lista de firma lo nombra, asi que ese paso no se puede dar" >&2
	exit 1
fi

C="${CAJON}/cifras"
mkdir -p "${C}"
CIF_OUT="${C}/salida"
corre_cifras() {
	CIF_RC=0
	sh "${CIFRAS}" "$@" > "${CIF_OUT}" 2>&1 || CIF_RC=$?
}

# El crudo de mentira, con la forma que imprimen los bancos de este arbol.
printf 'BANCO DE PRUEBA\nFILA 1  OK\nRESULTADO: 53 filas, 22 de ellas rojas, 0 en FALLA\n' > "${C}/crudo.txt"
# Y otro con la otra forma, la del nombre delante y los dos puntos.
printf 'BANCO DE PRUEBA\n  filas:  25\n' > "${C}/crudo2.txt"

# ---- control: un mensaje sin ninguna cifra contada ----
printf 'titulo\n\nun cuerpo que no cuenta nada.\n' > "${C}/m-sin.txt"
corre_cifras "${C}/m-sin.txt"
if [ "${CIF_RC}" -eq 0 ]; then
	ok "cif-0:  OK, un mensaje sin cifras contadas no tiene nada que re-derivar"
else
	mal "cif-0:  FALLA, rc=${CIF_RC} sobre un mensaje sin cifras"
fi

# ---- LA FILA QUE LO TRAE: el total del crudo no esta en el mensaje ----
# Es el defecto de 29b40a7 reproducido: el mensaje publica un total viejo.
printf 'titulo\n\nForty-one rows, fifteen of them red, zero failing.\n' > "${C}/m-viejo.txt"
corre_cifras "${C}/m-viejo.txt" "${C}/crudo.txt"
# SE EXIGEN LOS DOS TOTALES Y NO UNO, porque con uno solo la fila no veia dos
# defectos: la ventana de tres reducida a uno, y los nombres `rojas` y `falla`
# borrados de la tabla. En los dos casos seguia saliendo rc 1 por `filas`, y la
# fila daba OK sobre un lector medio ciego.
if [ "${CIF_RC}" -eq 1 ] && grep -q 'filas=53' "${CIF_OUT}" && grep -q 'rojas=22' "${CIF_OUT}" && grep -q '41' "${CIF_OUT}"; then
	ok "cif-1:  OK, los DOS totales del crudo que el mensaje no dice salen rechazados, con los del crudo y los del mensaje impresos"
elif [ "${CIF_RC}" -eq 1 ]; then
	mal "cif-1:  FALLA, rechaza pero no imprime las dos cifras: $(head -1 "${CIF_OUT}")"
else
	mal "cif-1:  FALLA, rc=${CIF_RC}; un mensaje con el total equivocado pasa"
fi

# ---- el otro lado: el mismo mensaje con el total bueno ----
# Sin esta fila, un paso que rechazara siempre puntuaria igual de bien.
printf 'titulo\n\nFifty-three rows, twenty-two of them red, zero failing.\n' > "${C}/m-bueno.txt"
corre_cifras "${C}/m-bueno.txt" "${C}/crudo.txt"
if [ "${CIF_RC}" -eq 0 ]; then
	ok "cif-2:  OK, el mismo mensaje con el total del crudo pasa, asi que no rechaza por rechazar"
else
	mal "cif-2:  FALLA, rc=${CIF_RC} con el total correcto: $(head -1 "${CIF_OUT}")"
fi

# ---- las cifras en PALABRAS, que es la forma en que el defecto real ocurrio ----
# La fila anterior ya escribe el total en palabras, y esta lo dice en voz alta
# porque es lo que tumbo el primer diseno: un barrido de DIGITOS sobre el
# mensaje de 29b40a7 devuelve 26 lineas, ninguna de ellas los dos defectos.
# Y la afirmacion se hace sobre el objeto: el mensaje bueno NO lleva un solo
# digito, asi que si el paso lo acepta contra un crudo cuyo total es 53 y 22, es
# porque leyo las palabras. Un barrido de digitos habria visto cero cifras ahi.
digitos_en_bueno=$(tr -cd '0-9' < "${C}/m-bueno.txt" | wc -c | tr -d ' ')
corre_cifras "${C}/m-viejo.txt" "${C}/crudo.txt"
rc_palabras_malas="${CIF_RC}"
corre_cifras "${C}/m-bueno.txt" "${C}/crudo.txt"
if [ "${digitos_en_bueno}" -eq 0 ] && [ "${CIF_RC}" -eq 0 ] && [ "${rc_palabras_malas}" -eq 1 ]; then
	ok "cif-3:  OK, con CERO digitos en el mensaje el paso separa el total bueno del viejo, asi que lee palabras; un barrido de digitos no habria visto el caso real"
elif [ "${digitos_en_bueno}" -ne 0 ]; then
	mal "cif-3:  FALLA, el mensaje de prueba lleva ${digitos_en_bueno} digito(s), asi que esta fila no prueba que se lean palabras"
else
	mal "cif-3:  FALLA, bueno rc=${CIF_RC} y viejo rc=${rc_palabras_malas}; las palabras no se estan leyendo como cifras"
fi

# ---- el paso no se puede saltar en silencio ----
corre_cifras "${C}/m-viejo.txt"
if [ "${CIF_RC}" -eq 2 ]; then
	ok "cif-4:  OK, un mensaje con cifras y sin crudo nombrado sale con 2: el paso no se dio"
else
	mal "cif-4:  FALLA, rc=${CIF_RC} sin nombrar crudo; el paso se puede saltar callando"
fi

# ---- la otra forma de total, nombre delante y dos puntos ----
printf 'titulo\n\nthe bench goes to 23 rows and then to 25 rows, zero failing.\n' > "${C}/m-dos.txt"
corre_cifras "${C}/m-dos.txt" "${C}/crudo2.txt"
if [ "${CIF_RC}" -eq 0 ]; then
	ok "cif-5:  OK, un total escrito 'filas: 25' se lee, y una cifra de una etapa anterior no estorba"
else
	mal "cif-5:  FALLA, rc=${CIF_RC} sobre la forma 'filas: 25': $(head -1 "${CIF_OUT}")"
fi

# ---- un identificador no es un nombre contado ----
# Lo trajo una medida y no un razonamiento: `phase_red launches three mutant
# daemons` daba rojas=3, y con eso el mensaje de 243d2f5, que no afirma ningun
# recuento, exigia un crudo.
# Y la fixture lleva las DOS direcciones a proposito. La que ocurrio de verdad
# es la del nombre delante, `phase_red launches three`, y esa la para la
# restriccion de los dos puntos. La simetrica, `three phase_red daemons`, solo
# la para que el punto y el guion bajo NO separen: sin ella el cambio del
# tokenizador seria codigo que ninguna fila mira, y medido lo era.
printf 'titulo\n\nP2.red.barrier and phase_red launch three mutant daemons.\nAnd three phase_red daemons more, plus 7 P2.red.barrier probes.\n' > "${C}/m-ident.txt"
corre_cifras "${C}/m-ident.txt"
if [ "${CIF_RC}" -eq 0 ]; then
	ok "cif-6:  OK, phase_red y P2.red.barrier no producen ningun recuento; un identificador no es un nombre contado"
else
	mal "cif-6:  FALLA, rc=${CIF_RC}; un identificador se esta leyendo como cifra y eso pide crudo donde no hay afirmacion"
fi

# ---- un crudo sin linea de total se RECHAZA, no se ignora ----
printf 'un fichero cualquiera sin totales\n' > "${C}/crudo-mudo.txt"
corre_cifras "${C}/m-viejo.txt" "${C}/crudo-mudo.txt"
if [ "${CIF_RC}" -eq 1 ] && grep -q 'no total line' "${CIF_OUT}"; then
	ok "cif-7:  OK, un crudo sin linea de total se RECHAZA nombrandolo, en vez de aportar cero callando"
else
	mal "cif-7:  FALLA, rc=${CIF_RC} sobre un crudo mudo; un crudo que no aporta nada no puede pasar por sostener algo"
fi

# ---- una linea de total con VARIOS CAMPOS no inventa recuentos ----
# La forma que imprime gate/p2-guard-test.sh. La ventana de tres saltaba la coma
# y sacaba `veredictos=24` de `24, veredictos` y `filas=15` de `15, filas`: dos
# de los tres totales eran invencion, y nombrar ese crudo hacia rechazar un
# mensaje correcto.
printf 'BANCO\nfilas: 24, veredictos rojos obtenidos: 15, filas que no cuadran: 0\n' > "${C}/crudo-multi.txt"
printf 'titulo\n\n24 rows, zero failing.\n' > "${C}/m-multi.txt"
corre_cifras "${C}/m-multi.txt" "${C}/crudo-multi.txt"
if [ "${CIF_RC}" -eq 0 ]; then
	ok "cif-9:  OK, una linea de total con varios campos separados por comas no fabrica recuentos que el crudo no dice"
else
	mal "cif-9:  FALLA, rc=${CIF_RC}; el lector cruza las comas y se inventa totales: $(head -1 "${CIF_OUT}")"
fi

# ---- un crudo RETIRADO no es evidencia ----
# Es el agujero mas caro que encontro el lector: el defecto que este paso existe
# para cazar salio de corridas retiradas, y la primera version daba rc 0 al
# mensaje culpable si se le apuntaba justo al fichero del que salio.
printf 'BANCO\nRESULTADO: 41 filas, 15 de ellas rojas, 0 en FALLA\n' > "${C}/crudo-RETIRADA-de-prueba.txt"
corre_cifras "${C}/m-viejo.txt" "${C}/crudo-RETIRADA-de-prueba.txt"
if [ "${CIF_RC}" -eq 1 ] && grep -q 'RETIRED run' "${CIF_OUT}"; then
	ok "cif-10: OK, un crudo con RETIRADA en el nombre se rechaza por serlo, aunque sus cifras casen con el mensaje"
else
	mal "cif-10: FALLA, rc=${CIF_RC} sobre un crudo retirado; el paso avala la clase de evidencia que causo el defecto"
fi

# ---- decenas compuestas, en los dos idiomas ----
# `Twenty two rows` daba 2 y 20, y `Cincuenta y tres filas` daba 3. Los dos son
# prosa correcta y los dos salian rechazados.
printf 'BANCO\nfilas: 22\n' > "${C}/crudo-22.txt"
printf 'titulo\n\nTwenty two rows, zero failing.\n' > "${C}/m-en22.txt"
printf 'titulo\n\nCincuenta y tres filas, veintidos de ellas rojas, cero en FALLA.\n' > "${C}/m-es53.txt"
corre_cifras "${C}/m-en22.txt" "${C}/crudo-22.txt"; rc_en="${CIF_RC}"
corre_cifras "${C}/m-es53.txt" "${C}/crudo.txt"; rc_es="${CIF_RC}"
corre_cifras "${C}/m-en22.txt" "${C}/crudo.txt"; rc_no="${CIF_RC}"
if [ "${rc_en}" -eq 0 ] && [ "${rc_es}" -eq 0 ] && [ "${rc_no}" -eq 1 ]; then
	ok "cif-11: OK, 'Twenty two' y 'Cincuenta y tres' se leen, y la misma frase contra el crudo que no la sostiene sigue cayendo"
else
	mal "cif-11: FALLA, ingles=${rc_en} castellano=${rc_es} control=${rc_no}; las decenas compuestas no se leen o no discriminan"
fi

# ---- fail-closed ----
corre_cifras "${C}/no-existe.txt" "${C}/crudo.txt"
if [ "${CIF_RC}" -eq 2 ] && grep -q 'cannot read the message' "${CIF_OUT}"; then
	ok "cif-8:  OK, un mensaje ilegible sale con 2 Y lo dice, que es el paso diciendo que no pudo correr"
else
	mal "cif-8:  FALLA, rc=${CIF_RC} sobre un mensaje ilegible"
fi

# EL RESUMEN, CONTADO SOBRE EL REGISTRO Y NO TECLEADO. Va en la forma que
# gate/msg-cifras.sh sabe leer, para que quien firme pueda apuntarle a este
# crudo y el total que compare salga del banco y no de una mano.
n_filas=$(grep -c . "${ROW_LOG}" || true)
n_falla=$(grep -c '^FAILING$' "${ROW_LOG}" || true)
COMPLETO=1
echo "RESULTADO: ${n_filas} rows, ${n_falla} failing"
if [ "${n_filas}" -eq 0 ]; then
	echo "test: VACIO. El registro de filas salio a cero, asi que este banco no ha probado nada" >&2
	exit 1
fi
if [ "${n_falla}" -ne "${fallos}" ]; then
	echo "test: el registro cuenta ${n_falla} fallas y el acumulador ${fallos}; las dos cuentas tienen que casar" >&2
	exit 1
fi

[ "${fallos}" -eq 0 ] || { echo "test: ${fallos} fallo(s)" >&2; exit 1; }
echo "test: el hook esta, su lista es la anclada, rechaza cada patron, deja pasar lo limpio, sin el no hay defensa; los shas que un mensaje cita se comprueban contra la rama por ancestria y no por existencia; y el total del crudo que un mensaje dice tener detras tiene que estar en el mensaje"
