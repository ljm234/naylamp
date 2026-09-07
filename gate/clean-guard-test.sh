#!/bin/sh
# Prueba de la guarda SEALED de `make clean`, con su BRAZO ROJO dentro.
#
# Por que existe: el censo de brazos rojos de DEFER-077 midio nueve defensores de
# esta casa y este era uno de los dos SIN PRUEBA DE NINGUNA CLASE. Borrado el
# bloque entero del Makefile, nada del arbol cae. Medido el 1 de septiembre de
# 2026 sobre una copia: con las tres piezas fuera, `make clean` se lleva un
# directorio que lleva su fichero SEALED dentro, y sale con rc=0.
#
# Y hay una distincion que el censo no hacia y que decide para que sirve esta
# prueba. `gate/p1.sh` SI comprueba algo de los sellos: su fase P1.hygiene falla
# si hay artefactos de fierro sin SEALED. Eso vigila a quien ESCRIBE el
# artefacto. Nadie vigilaba a quien lo BORRA, que es la guarda del Makefile, y
# son cosas distintas: un artefacto correctamente sellado que `make clean` ya no
# respeta se pierde igual, y el gate lo habria dado por bueno.
#
# Que hace: monta un gate/out de mentira en un cajon propio, con una copia del
# Makefile del arbol, y corre `make clean` contra el. Nunca contra el arbol real.
#
# Las filas VERDES, que son lo que la guarda promete (sin cardinal delante, por
# la clausula 11: la lista esta justo debajo y se cuenta sola):
#   1. se NIEGA y no borra nada si hay un artefacto de fierro sin sello
#   2. con la valvula UNSEALED_OK, el artefacto SELLADO sobrevive entero
#   3. y lo que si tiene que irse, se va (sin esto, un clean que no borrara nada
#      pasaria las dos filas de arriba)
#   3b. las dos excepciones que la receta promete aparte del sello: certs, porque
#      rotarlos deja la flota sin poder elegir lider, y los *.log de primer
#      nivel, porque el registro cita consolas por su nombre
#   4. un directorio de fierro VACIO y sin sello no dispara la negativa
#   5. un p1-local-* sin sello tampoco la dispara, y aun asi lo borra, que es la
#      exclusion deliberada por la que el 28 de agosto de 2026 murio un ensayo
#      (y lo mismo con un p2-local-*, desde el 6 de septiembre de 2026)
#   5b. un p2-<run id> sin sello dispara la negativa EL SOLO, con el de p1 fuera
#      del montaje, que es la unica forma de que la fila mida la generalizacion y
#      no la herede de la fila 1
#   5c. y un p3-<run id>, de una phase que NO EXISTE en este arbol, la dispara
#      igual, que es lo unico que distingue un predicado por FORMA de una lista
#      de prefijos a mano. Sin esta fila, la palabra "forma" seria una promesa
#   9. un directorio con un RUNNING cuyo pid esta VIVO para la limpieza entera y
#      no se borra nada, que es la pieza 5 de DEFER-074 y llega con dos incidentes
#      detras, el del 28 de agosto y el del 7 de septiembre de 2026
#   10. y uno cuyo pid esta MUERTO no la para, se anuncia como resto de una corrida
#      que no termino, y se barre. Sin esta fila la pieza 5 seria una defensa que
#      se desactiva sola el dia que una corrida muera de un kill -9
#   9b. y lo mismo con un p1-local-*, que es la familia del incidente ORIGINAL del
#      28 de agosto de 2026. Va junto a la fila 5, que certifica en verde que un
#      p1-local-* SIN marcador se barre: las dos juntas dibujan la frontera, y una
#      sin la otra la deja a medias
#   12. y la valvula de los sellos, UNSEALED_OK=1, NO se lleva la corrida viva. Esa
#      fila existe porque hasta el 7 de septiembre de 2026 SI se la llevaba, y en
#      silencio: la negativa se saltaba antes de imprimir nada, que es la escena
#      del 28 de agosto palabra por palabra
#
# Las filas ROJAS, una por pieza del Makefile, porque se pueden perder por
# separado:
#   6. sin la negativa, el artefacto sin sello se va y `make clean` sale con 0
#   7. sin la condicion de preservacion, el artefacto SELLADO se destruye
#   8. con el predicado VIEJO, el de p1 solo, un artefacto de fierro de Phase 2 sin
#      sello se va y `make clean` sale con 0. Esa fila no es hipotetica: es el
#      estado en que estuvo el arbol hasta el 6 de septiembre de 2026, y existe
#      para que el arreglo llegue con su perdida medida y no declarada
#   11. sin la negativa del RUNNING, el directorio de una corrida VIVA se va y
#      `make clean` sale con 0, que es lo que paso de verdad dos veces
#
# Uso: ./gate/clean-guard-test.sh    (desde donde sea, rc=0 si todas van)
#
# No toca el repositorio ni el registro: su cajon esta bajo el directorio
# temporal del sistema y lo crea y lo retira el mismo.

set -eu

AQUI=$(cd "$(dirname "$0")" && pwd)
RAIZ_REPO=$(cd "${AQUI}/.." && pwd)
MAKEFILE_REAL="${RAIZ_REPO}/Makefile"
[ -f "${MAKEFILE_REAL}" ] || { echo "test: no encuentro ${MAKEFILE_REAL}" >&2; exit 2; }

CAJON=$(mktemp -d "${TMPDIR:-/tmp}/clean-guard-test.XXXXXX")
trap 'rm -rf -- "$CAJON" 2>/dev/null || true' EXIT

cp "${MAKEFILE_REAL}" "${CAJON}/Makefile"

# ANTES DE CORRER NADA. Esta prueba invoca una receta que BORRA, asi que se
# comprueba que va a correr en el cajon y no en el arbol. La leccion es de
# limpia-scratch-test.sh, y va con su medida exacta y no con una perdida que no
# hubo: el 28 de agosto de 2026 su sed de la raiz no prendio sobre una raiz DE
# MENTIRA y se llevo los tres ficheros de esa raiz, avisando despues de destruir.
# No se perdio nada real, y por eso el aviso sirve: un sed que no casa no falla,
# devuelve el fichero intacto, y la prueba corre contra lo que haya. Aqui no hay
# sed, pero si un cd, y un cd que no prende deja `make clean` apuntando al
# repositorio.
cd "${CAJON}"
if [ "$(pwd -P)" != "$(cd "${CAJON}" && pwd -P)" ] || [ "$(pwd -P)" = "${RAIZ_REPO}" ]; then
	echo "test: ABORTA, el directorio de trabajo no es el cajon" >&2
	exit 1
fi
[ ! -d "${CAJON}/engine" ] || { echo "test: ABORTA, el cajon parece el arbol real" >&2; exit 1; }

monta() {
	rm -rf gate scale_result.txt
	mkdir -p gate/out/certs
	printf 'no rotar esto\n' > gate/out/certs/ca.pem
	printf 'consola de la corrida\n' > gate/out/consola.log
	mkdir -p gate/out/p1-sellada
	printf 'crudo de la corrida sellada\n' > gate/out/p1-sellada/dato.txt
	printf 'lo cita la tabla de recall\n' > gate/out/p1-sellada/SEALED
	mkdir -p gate/out/p1-sin-sello
	printf 'crudo sin sello\n' > gate/out/p1-sin-sello/dato.txt
	mkdir -p gate/out/p1-local-ensayo
	printf 'ensayo en local\n' > gate/out/p1-local-ensayo/dato.txt
	mkdir -p gate/out/p2-sin-sello
	printf 'crudo de fierro de Phase 2 sin sello\n' > gate/out/p2-sin-sello/dato.txt
	mkdir -p gate/out/p2-local-ensayo
	printf 'ensayo en local de Phase 2\n' > gate/out/p2-local-ensayo/dato.txt
	mkdir -p gate/out/p1-vacia
	printf 'basura suelta\n' > gate/out/suelto.log.txt
	printf 'x\n' > scale_result.txt
}
hay()   { [ -e "$1" ] && echo si || echo no; }
n_en()  { ls "$1" 2>/dev/null | wc -l | tr -d ' '; }

fallos=0
mal() { echo "$1" >&2; fallos=$((fallos + 1)); }

# ---- 1. se niega, y no borra NADA ----
monta
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ]; then
	mal "1 negativa: FALLA, make clean salio con 0 habiendo un artefacto de fierro sin sello"
elif [ "$(n_en gate/out/p1-sellada)" -eq 2 ] && [ "$(n_en gate/out/p1-sin-sello)" -eq 1 ] \
	&& [ "$(n_en gate/out/p2-sin-sello)" -eq 1 ] \
	&& [ "$(hay gate/out/suelto.log.txt)" = si ] && [ "$(hay scale_result.txt)" = si ]; then
	echo "1 negativa: OK, se niega con rc=${rc} y no se lleva nada, ni lo que si limpiaria"
else
	mal "1 negativa: FALLA, se nego pero borro algo por el camino"
fi

# ---- 2. la valvula, y el sellado sobrevive entero ----
monta
make clean UNSEALED_OK=1 >/dev/null 2>&1 || mal "2 preserva: FALLA, con la valvula make clean no completa"
if [ "$(n_en gate/out/p1-sellada)" -eq 2 ]; then
	echo "2 preserva: OK, el artefacto sellado sobrevive con sus dos ficheros"
else
	mal "2 preserva: FALLA, el sellado quedo con $(n_en gate/out/p1-sellada) ficheros y esperaba 2"
fi

# ---- 3. anti-vacuidad: lo que tiene que irse, se va ----
if [ "$(hay gate/out/p1-sin-sello)" = no ] && [ "$(hay gate/out/p2-sin-sello)" = no ] \
	&& [ "$(hay scale_result.txt)" = no ]; then
	echo "3 barre:   OK, lo que no lleva sello si se va, asi que la fila 2 no pasa por no borrar nada"
else
	mal "3 barre:   FALLA, con la valvula puesta no se llevo lo que tenia que llevarse"
fi

# ---- 3b. las dos excepciones que no son el sello ----
if [ "$(hay gate/out/certs/ca.pem)" = si ] && [ "$(hay gate/out/consola.log)" = si ]; then
	echo "3b excep:  OK, certs y los *.log de primer nivel sobreviven sin llevar sello"
else
	mal "3b excep:  FALLA, la limpieza se llevo certs o un *.log, que la receta promete conservar"
fi

# ---- 4. un directorio de fierro VACIO no dispara la negativa ----
monta
rm -rf gate/out/p1-sin-sello gate/out/p1-local-ensayo
rm -rf gate/out/p2-sin-sello gate/out/p2-local-ensayo
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ]; then
	echo "4 vacio:   OK, un artefacto de fierro vacio y sin sello no para la limpieza"
else
	mal "4 vacio:   FALLA, la negativa salto con rc=${rc} por un directorio vacio"
fi

# ---- 5. los local-* no disparan la negativa, y aun asi se los lleva ----
# Sin cardinal, por la clausula 11: los dos van nombrados en las lineas de abajo.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
	mal "5 local:   FALLA, un local-* sin sello disparo la negativa, y la exclusion es deliberada"
elif [ "$(hay gate/out/p1-local-ensayo)" = no ] && [ "$(hay gate/out/p2-local-ensayo)" = no ] \
	&& [ "$(n_en gate/out/p1-sellada)" -eq 2 ]; then
	echo "5 local:   OK, ni p1-local-* ni p2-local-* paran la limpieza y los dos se van"
else
	mal "5 local:   FALLA, un local-* sobrevivio o se llevo por delante al sellado"
fi

# ---- 5b. el de Phase 2 dispara la negativa EL SOLO ----
# Con el de p1 fuera del montaje. Si estuviera, esta fila saldria verde por la
# razon de la fila 1 y no mediria nada de lo que dice medir.
monta
rm -rf gate/out/p1-sin-sello
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ] && [ "$(n_en gate/out/p2-sin-sello)" -eq 1 ]; then
	echo "5b p2:     OK, un p2-<run id> sin sello para la limpieza el solo y sigue entero"
else
	mal "5b p2:     FALLA, con rc=${rc} el artefacto de fierro de Phase 2 sin sello no paro la limpieza"
fi

# ---- 5c. una phase que no existe, para separar la forma de la lista ----
# gate/out/p3-... no lo escribe nada en este arbol y ese es justo el punto: el dia
# que exista, la guarda ya lo mira. Con una lista de prefijos a mano esta fila
# saldria roja y nadie se enteraria hasta perder el artefacto.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
mkdir -p gate/out/p3-20260906T0000Z-1
printf 'crudo de una phase que aun no existe\n' > gate/out/p3-20260906T0000Z-1/dato.txt
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ] && [ "$(n_en gate/out/p3-20260906T0000Z-1)" -eq 1 ]; then
	echo "5c forma:  OK, un p3-<run id> de una phase inexistente para la limpieza y sigue entero"
else
	mal "5c forma:  FALLA, con rc=${rc} la guarda no miro a p3-; el predicado es una lista y no una forma"
fi

# ---- 9. una corrida VIVA para la limpieza ----
# El pid tiene que ser de un proceso de verdad, porque el predicado del Makefile
# pregunta al sistema operativo con `kill -0` y no al fichero. Se arranca un `sleep`
# en el cajon, se usa SU pid, y se mata al terminar la fila.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
mkdir -p gate/out/p2-local-encurso
printf 'crudo a medio escribir\n' > gate/out/p2-local-encurso/dato.txt
sleep 120 &
pid_vivo=$!
printf 'pid: %s\nrun: p2-local-encurso\nstarted: prueba\n' "${pid_vivo}" > gate/out/p2-local-encurso/RUNNING
rc=0
salida=$(make clean 2>&1) || rc=$?
if [ "${rc}" -ne 0 ] && [ "$(hay gate/out/p2-local-encurso/dato.txt)" = si ] \
	&& printf '%s' "${salida}" | grep -q 'still writing'; then
	echo "9 vivo:    OK, una corrida viva para la limpieza entera y su directorio sigue ahi"
else
	mal "9 vivo:    FALLA, con rc=${rc} la limpieza no respeto un RUNNING con el pid vivo"
fi
kill "${pid_vivo}" 2>/dev/null || true
wait "${pid_vivo}" 2>/dev/null || true

# ---- 9b. y la familia del incidente ORIGINAL, p1-local-* ----
# La fila 5 certifica en verde que un p1-local-* sin marcador se barre. Esta dice
# que CON marcador vivo no, y las dos juntas son la frontera.
#
# Y VA CON SU MITAD QUE SI MIRA A gate/p1.sh, porque sin ella esta fila fabrica el
# marcador con un printf y habria pasado identica el 6 de septiembre, cuando p1.sh
# no escribia ninguno. Lo trajo el lector de la ronda. La mitad de abajo pregunta al
# guion de verdad: que llame a escribe_running despues de crear el artefacto y que
# su cleanup llame a retira_running. Borra cualquiera de las dos del guion y esta
# fila cae; con el printf solo, no caia.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
sleep 120 &
pid_p1=$!
printf 'pid: %s\nrun: p1-local-ensayo\nstarted: prueba\n' "${pid_p1}" > gate/out/p1-local-ensayo/RUNNING
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ] && [ "$(hay gate/out/p1-local-ensayo/dato.txt)" = si ]; then
	echo "9b p1:     OK, un p1-local-* con marcador vivo para la limpieza, que es el incidente del 28 de agosto"
else
	mal "9b p1:     FALLA, con rc=${rc} un ensayo de p1 en vuelo se perdio igual que entonces"
fi
kill "${pid_p1}" 2>/dev/null || true
wait "${pid_p1}" 2>/dev/null || true

P1SH="${RAIZ_REPO}/gate/p1.sh"
if [ ! -f "${P1SH}" ]; then
	mal "9c escribe: FALLA, no encuentro ${P1SH}"
else
	# LAS TRES CONDICIONES MIRAN SITIOS DE LLAMADA Y NO DEFINICIONES, y la primera
	# version miraba definiciones: `grep -q escribe_running` casa con la linea que
	# ABRE la funcion, asi que dos de sus tres condiciones se cumplian solas mientras
	# el fichero contuviera las funciones. Medido por el lector con cinco mutantes:
	# vaciar retira_running a `return 0`, borrar su llamada, o vaciar escribe_running
	# dejaban la fila VERDE, y una linea en blanco tras el mkdir la ponia roja. Estaba
	# al reves: ciega ante lo que importa y fragil ante lo que no.
	#
	# Ahora se cuenta cada nombre por separado, definicion y llamadas, y se exige que
	# haya MAS de una aparicion de cada uno, que es lo que distingue una funcion viva
	# de una funcion que solo existe. Y ademas se comprueba que ninguna de las dos
	# este vaciada a un `return 0` como primera linea de cuerpo.
	# Las cinco cuentas llevan `|| true`: `grep -c` sale con 1 cuando no hay aciertos,
	# y este fichero corre con `set -eu`. Sin la guarda, el mutante que borra la
	# llamada mataba el banco entero DENTRO de la fila que iba a cazarlo, sin imprimir
	# ni la fila ni el fallo. Es la clase que el barrido de errexit de esta misma
	# jornada persiguio en veinte guiones, cometida al escribir esta fila.
	def_esc=$(grep -cE '^escribe_running\(\) \{' "${P1SH}" || true)
	def_ret=$(grep -cE '^retira_running\(\) \{' "${P1SH}" || true)
	lla_esc=$(grep -cE '^[[:space:]]*escribe_running[[:space:]]*$' "${P1SH}" || true)
	lla_ret=$(grep -cE '^[[:space:]]+retira_running[[:space:]]*$' "${P1SH}" || true)
	tras_mkdir=$(grep -A2 'mkdir -p "${OUT_LOCAL}"' "${P1SH}" | grep -cE '^[[:space:]]*escribe_running[[:space:]]*$' || true)
	# Y que ninguna este vaciada a un `return 0` como primera linea de cuerpo, que es
	# la forma de desactivarla sin borrar ni la definicion ni la llamada.
	cuerpo_esc=$(awk '/^escribe_running\(\) \{/{f=1;next} f&&NF{print;exit}' "${P1SH}" || true)
	cuerpo_ret=$(awk '/^retira_running\(\) \{/{f=1;next} f&&NF{print;exit}' "${P1SH}" || true)
	if [ "${def_esc}" -eq 1 ] && [ "${def_ret}" -eq 1 ] \
		&& [ "${lla_esc}" -ge 1 ] && [ "${lla_ret}" -ge 1 ] && [ "${tras_mkdir}" -ge 1 ] \
		&& ! printf '%s' "${cuerpo_esc}" | grep -qE '^[[:space:]]*return 0[[:space:]]*$' \
		&& ! printf '%s' "${cuerpo_ret}" | grep -qE '^[[:space:]]*return 0[[:space:]]*$'; then
		echo "9c escribe: OK, gate/p1.sh define y LLAMA a las dos, la escritura va tras el mkdir, y ninguna esta vaciada"
	else
		mal "9c escribe: FALLA, def=${def_esc}/${def_ret} llamadas=${lla_esc}/${lla_ret} tras_mkdir=${tras_mkdir}; la fila 9b se quedaria fabricando el marcador sola"
	fi
fi

# ---- 9d. la trampa del recuento de vacio, por el lado del Makefile ----
# Un directorio cuyo UNICO fichero es RUNNING y cuyo proceso murio tiene que
# BARRERSE. Si el sitio que pregunta por vacio deja de descontar el marcador, ese
# directorio queda ni sellable ni barrible, que es lo que la excepcion de los vacios
# existe para evitar. Lo cazo el lector el 7 de septiembre de 2026.
#
# Y VA DICHO LO QUE ESTA FILA ALCANZA: dispara sobre el predicado del Makefile, que
# es el unico que `make clean` lee. Los otros tres, los de gate/p1.sh, no los toca
# ninguna fila de este banco, porque para verlos haria falta correr el gate entero
# con un artefacto de fierro. La cabecera de la primera version decia "los tres" y
# media uno; ahora dice cual mide.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
sleep 0 &
pid_ido=$!
wait "${pid_ido}" 2>/dev/null || true
mkdir -p gate/out/p1-20260907T0000Z-1
printf 'pid: %s\n' "${pid_ido}" > gate/out/p1-20260907T0000Z-1/RUNNING
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p1-20260907T0000Z-1)" = no ]; then
	echo "9d vacio:  OK, un artefacto cuyo unico fichero es un RUNNING muerto se barre y no queda atrapado"
else
	mal "9d vacio:  FALLA, con rc=${rc} ese directorio quedo ni sellable ni barrible"
fi

# ---- 10. una corrida MUERTA no para la limpieza, y se anuncia ----
# El pid tiene que estar muerto de verdad: se arranca y se recoge antes de usarlo.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
sleep 0 &
pid_muerto=$!
wait "${pid_muerto}" 2>/dev/null || true
mkdir -p gate/out/p2-local-resto
printf 'crudo de una corrida que murio\n' > gate/out/p2-local-resto/dato.txt
printf 'pid: %s\nrun: p2-local-resto\nstarted: prueba\n' "${pid_muerto}" > gate/out/p2-local-resto/RUNNING
rc=0
salida=$(make clean 2>&1) || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p2-local-resto)" = no ] \
	&& printf '%s' "${salida}" | grep -q 'did not finish'; then
	echo "10 resto:  OK, un RUNNING de proceso muerto no para la limpieza, se anuncia y se barre"
else
	mal "10 resto:  FALLA, con rc=${rc} el resto de una corrida muerta no se barrio o no se anuncio"
fi

# ---- 12. la valvula de los sellos no mata una corrida viva ----
# Las dos valvulas dicen cosas de precio distinto: UNSEALED_OK=1 es "si, borra este
# artefacto TERMINADO sin sello"; matar una corrida que se esta pagando tiene que
# escribirse a proposito y con otro nombre.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
mkdir -p gate/out/p2-local-encurso
printf 'crudo a medio escribir\n' > gate/out/p2-local-encurso/dato.txt
sleep 120 &
pid_valvula=$!
printf 'pid: %s\nrun: p2-local-encurso\nstarted: prueba\n' "${pid_valvula}" > gate/out/p2-local-encurso/RUNNING
rc=0
make clean UNSEALED_OK=1 >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ] && [ "$(hay gate/out/p2-local-encurso/dato.txt)" = si ]; then
	echo "12 valvula: OK, UNSEALED_OK=1 no se lleva una corrida viva, que es otra decision y otro precio"
else
	mal "12 valvula: FALLA, con rc=${rc} la valvula de los sellos se llevo la corrida viva"
fi
rc=0
make clean KILL_RUNNING_OK=1 >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p2-local-encurso)" = no ]; then
	echo "12b propia: OK, KILL_RUNNING_OK=1 si se la lleva, que es lo que esa valvula dice"
else
	mal "12b propia: FALLA, con rc=${rc} la valvula propia no se llevo la corrida viva"
fi
kill "${pid_valvula}" 2>/dev/null || true
wait "${pid_valvula}" 2>/dev/null || true

# ---- las mutaciones, y su anti-vacuidad ----
# Sin cardinal delante, por la clausula 11: el bucle de abajo las enumera y una
# cifra aqui solo podia coincidir o discrepar. Discrepaba: decia dos y son tres
# desde el 6 de septiembre de 2026, y lo trajo el lector de esa misma pasada.
# Si un patron deja de casar, la copia sale identica a la original y la fila roja
# certificaria la guarda buena: por eso se comparan antes de correr, que es lo que
# hace limpia-scratch-test.sh.
#
# El primer mutante retira solo la negativa. El SEGUNDO no es minimo y va dicho:
# el grep se lleva las DOS lineas que llevan esa condicion, la del barrido y la
# de dentro de la negativa. Su fila corre con UNSEALED_OK=1, o sea con la
# negativa ya desactivada por la valvula, asi que lo que mide sigue siendo la
# condicion del barrido; pero el mutante toca dos sitios y quien lo lea tiene
# que saberlo.
#
# EL TERCERO NO QUITA UNA PIEZA, LA REBOBINA: deja el predicado como estuvo hasta
# el 6 de septiembre de 2026, mirando p1-* y nada mas. No es un mutante inventado
# para tener fila: es el Makefile que este arbol tuvo, y su fila mide lo que se
# habria perdido, que es un artefacto de fierro de Phase 2 sin sello. El vivo
# pregunta por FORMA, p[0-9]-, asi que esta fila tambien cubre lo que pasaria si
# alguien volviera a escribir el predicado como una lista de phases a mano.
awk '
	/^clean:$/           { print; dentro = 1; next }
	dentro && /^\ttest ! -d gate\/out \|\| find gate\/out/ { dentro = 0 }
	dentro               { next }
	                     { print }
' Makefile > Makefile-sin-negativa
grep -v '! -exec test -e {}/SEALED' Makefile > Makefile-sin-preservar

cat > sin-running.awk <<'AWK'
/if \[ -n "\$\$alive" \]/ { sub(/\$\$alive/, "") }
{ print }
AWK
awk -f sin-running.awk Makefile > Makefile-sin-running

cat > rebobina-a-p1.awk <<'AWK'
/-name .p\[0-9\]-local-/ { print "\t\t\t-name \"p1-*\" ! -name \"p1-local-*\" \\"; next }
{ print }
AWK
awk -f rebobina-a-p1.awk Makefile > Makefile-solo-p1

for m in Makefile-sin-negativa Makefile-sin-preservar Makefile-solo-p1 Makefile-sin-running; do
	if cmp -s Makefile "${m}"; then
		echo "test: VACIO. ${m} salio identico al Makefile, asi que su fila roja no muta nada" >&2
		echo "test: alguien cambio la forma de la receta clean y este brazo dejo de probar" >&2
		exit 1
	fi
done

# ---- 6. ROJO de la negativa ----
monta
rc=0
make -f Makefile-sin-negativa clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p1-sin-sello)" = no ]; then
	echo "6 rojo(a): OK, MUERDE: sin la negativa, el artefacto sin sello se va y make clean sale con 0"
else
	mal "6 rojo(a): FALLA, sin la negativa la limpieza no se llevo el artefacto sin sello; la fila 1 no prueba nada"
fi

# ---- 7. ROJO de la preservacion ----
monta
make -f Makefile-sin-preservar clean UNSEALED_OK=1 >/dev/null 2>&1 || true
if [ "$(hay gate/out/p1-sellada)" = no ]; then
	echo "7 rojo(b): OK, MUERDE: sin la condicion de preservacion, el artefacto SELLADO se destruye"
else
	mal "7 rojo(b): FALLA, el sellado sobrevivio sin su condicion, asi que la fila 2 no prueba nada"
fi

# ---- 8. ROJO del predicado viejo, el de p1 solo ----
# Sin el de p1 en el montaje, para que la negativa no salte por otra razon. Con el
# predicado rebobinado, el artefacto de fierro de Phase 2 no lo mira nadie, y el
# barrido de abajo, que no pregunta por el prefijo, se lo lleva.
monta
rm -rf gate/out/p1-sin-sello
rc=0
make -f Makefile-solo-p1 clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p2-sin-sello)" = no ]; then
	echo "8 rojo(c): OK, MUERDE: con el predicado viejo el artefacto de Phase 2 sin sello se va y make clean sale con 0"
else
	mal "8 rojo(c): FALLA, con rc=${rc} el predicado viejo no perdio el artefacto de Phase 2; la fila 5b no prueba nada"
fi

# ---- 11. ROJO de la negativa del RUNNING ----
# Sin ella, el directorio de una corrida VIVA se va y make clean sale con 0. No es
# una hipotesis: es lo que paso el 28 de agosto y el 7 de septiembre de 2026.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
mkdir -p gate/out/p2-local-encurso
printf 'crudo a medio escribir\n' > gate/out/p2-local-encurso/dato.txt
sleep 120 &
pid_vivo2=$!
printf 'pid: %s\nrun: p2-local-encurso\nstarted: prueba\n' "${pid_vivo2}" > gate/out/p2-local-encurso/RUNNING
rc=0
make -f Makefile-sin-running clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p2-local-encurso)" = no ]; then
	echo "11 rojo(d): OK, MUERDE: sin la negativa, el directorio de una corrida VIVA se va y make clean sale con 0"
else
	mal "11 rojo(d): FALLA, con rc=${rc} el mutante no perdio la corrida viva; la fila 9 no prueba nada"
fi
kill "${pid_vivo2}" 2>/dev/null || true
wait "${pid_vivo2}" 2>/dev/null || true

[ "${fallos}" -eq 0 ] || { echo "test: ${fallos} fallo(s)" >&2; exit 1; }
echo "test: la guarda se niega por forma y no por lista, respeta una corrida viva, barre el resto de una muerta, preserva, y las mitades rojas muerden"
