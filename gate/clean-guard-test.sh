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

# QUIEN ES ESTE BANCO, dicho en su PRIMERA linea de salida y en una forma que no
# es prosa. Entra el 8 de septiembre de 2026. El barrido que revisa el archivo de
# corridas/ clasificaba cada captura buscando por el CUERPO el texto de alguna de
# sus filas, y eso tiene dos agujeros medidos: el texto de una fila se reescribe,
# y entonces las capturas de ese banco dejan de existir para el barrido sin que
# nadie lo note; y un informe ESCRITO que cita unas filas se cuenta como corrida,
# que es como cuatro analisis del archivo acabaron contados como capturas. Una
# cita vive siempre por el medio de un fichero, nunca en su primera linea, asi que
# esta linea distingue una corrida de una cita a una corrida.
echo "BANCO: clean-guard-test"

. "$(dirname "${BASH_SOURCE[0]}")/entorno.sh"

AQUI=$(cd "$(dirname "$0")" && pwd)
RAIZ_REPO=$(cd "${AQUI}/.." && pwd)
MAKEFILE_REAL="${RAIZ_REPO}/Makefile"
[ -f "${MAKEFILE_REAL}" ] || { echo "test: no encuentro ${MAKEFILE_REAL}" >&2; exit 2; }

CAJON=$(mktemp -d "${TMPDIR:-/tmp}/clean-guard-test.XXXXXX")
# LA TRAMPA CUBRE TAMBIEN LA COPIA SIN GUARDA, que vive en gate/ y no en el
# cajon. Tiene que vivir ahi porque el banco resuelve su sitio por el dirname de
# $0 y desde el cajon no encontraria p2.sh. Pero durante los veinte segundos que
# dura, es un fichero sin trackear dentro del arbol, y TRES gates cuentan
# `git status --porcelain`: gate/p2-preflight.sh:135 falla duro con esa cifra y
# gate/p2.sh:1077 la sella DENTRO del artefacto. Si este guion se interrumpe en
# esa ventana, la copia se queda para siempre y la fila 13d no llega a correr.
# LA BANDERA DE TERMINACION, escrita el 8 de septiembre de 2026 y la trae un
# lector adversarial. Una trampa EXIT se COME el estado de salida cuando el
# guion muere por `set -e` o `set -u`: medido en el `/bin/sh` de esta maquina,
# que es bash 3.2, un abortado pasa de rc 1 a rc 0. Preservar `$?` dentro de la
# trampa no lo arregla, porque para entonces ya vale 0. Medido sobre este mismo
# banco: abortado a mitad devolvia CERO, y dos de estos bancos corren en CI, o
# sea que un banco muerto se leia como un paso verde.
# LA LINEA DE RESULTADO, UNIFORME EN TODOS LOS BANCOS, y entra el 8 de septiembre
# de 2026 por una orden de quien encarga. Nace de que una trampa EXIT convertia
# un abortado en rc 0: cualquier banco archivado pudo morir a medias y leerse
# como verde, asi que hay que poder barrer `corridas/` y separar lo completo de
# lo abortado. Y nace tambien de que el primer barrido fallo por anclarse al
# TEXTO: la linea final de este banco decia una cosa el 6 de septiembre y otra el
# 7, asi que el predicado dio por ABORTADA una corrida entera. Una marca de
# terminacion no puede ser prosa; tiene que ser una FORMA estable e igual en los
# siete bancos, con la cuenta derivada del registro y no tecleada.
REGISTRO_FILAS="${CAJON}/filas-del-banco"
: > "${REGISTRO_FILAS}"
anota_fila() { printf '%s\n' "$1" >> "${REGISTRO_FILAS}"; }
COMPLETO=0
limpia_y_cierra() {
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2
		rm -rf -- "$CAJON" 2>/dev/null || true; rm -f -- "${AQUI}/banco-sin-guarda-de-prueba.sh" 2>/dev/null || true
		exit 1
	fi
	rm -rf -- "$CAJON" 2>/dev/null || true; rm -f -- "${AQUI}/banco-sin-guarda-de-prueba.sh" 2>/dev/null || true
}
trap limpia_y_cierra EXIT

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
	anota_fila FALLA; mal "1 negativa: FALLA, make clean salio con 0 habiendo un artefacto de fierro sin sello"
elif [ "$(n_en gate/out/p1-sellada)" -eq 2 ] && [ "$(n_en gate/out/p1-sin-sello)" -eq 1 ] \
	&& [ "$(n_en gate/out/p2-sin-sello)" -eq 1 ] \
	&& [ "$(hay gate/out/suelto.log.txt)" = si ] && [ "$(hay scale_result.txt)" = si ]; then
	anota_fila OK; echo "1 negativa: OK, se niega con rc=${rc} y no se lleva nada, ni lo que si limpiaria"
else
	anota_fila FALLA; mal "1 negativa: FALLA, se nego pero borro algo por el camino"
fi

# ---- 2. la valvula, y el sellado sobrevive entero ----
monta
make clean UNSEALED_OK=1 >/dev/null 2>&1 || mal "2 preserva: FALLA, con la valvula make clean no completa"
if [ "$(n_en gate/out/p1-sellada)" -eq 2 ]; then
	anota_fila OK; echo "2 preserva: OK, el artefacto sellado sobrevive con sus dos ficheros"
else
	anota_fila FALLA; mal "2 preserva: FALLA, el sellado quedo con $(n_en gate/out/p1-sellada) ficheros y esperaba 2"
fi

# ---- 3. anti-vacuidad: lo que tiene que irse, se va ----
if [ "$(hay gate/out/p1-sin-sello)" = no ] && [ "$(hay gate/out/p2-sin-sello)" = no ] \
	&& [ "$(hay scale_result.txt)" = no ]; then
	anota_fila OK; echo "3 barre:   OK, lo que no lleva sello si se va, asi que la fila 2 no pasa por no borrar nada"
else
	anota_fila FALLA; mal "3 barre:   FALLA, con la valvula puesta no se llevo lo que tenia que llevarse"
fi

# ---- 3b. las dos excepciones que no son el sello ----
if [ "$(hay gate/out/certs/ca.pem)" = si ] && [ "$(hay gate/out/consola.log)" = si ]; then
	anota_fila OK; echo "3b excep:  OK, certs y los *.log de primer nivel sobreviven sin llevar sello"
else
	anota_fila FALLA; mal "3b excep:  FALLA, la limpieza se llevo certs o un *.log, que la receta promete conservar"
fi

# ---- 4. un directorio de fierro VACIO no dispara la negativa ----
monta
rm -rf gate/out/p1-sin-sello gate/out/p1-local-ensayo
rm -rf gate/out/p2-sin-sello gate/out/p2-local-ensayo
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ]; then
	anota_fila OK; echo "4 vacio:   OK, un artefacto de fierro vacio y sin sello no para la limpieza"
else
	anota_fila FALLA; mal "4 vacio:   FALLA, la negativa salto con rc=${rc} por un directorio vacio"
fi

# ---- 5. los local-* no disparan la negativa, y aun asi se los lleva ----
# Sin cardinal, por la clausula 11: los dos van nombrados en las lineas de abajo.
monta
rm -rf gate/out/p1-sin-sello gate/out/p2-sin-sello
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
	anota_fila FALLA; mal "5 local:   FALLA, un local-* sin sello disparo la negativa, y la exclusion es deliberada"
elif [ "$(hay gate/out/p1-local-ensayo)" = no ] && [ "$(hay gate/out/p2-local-ensayo)" = no ] \
	&& [ "$(n_en gate/out/p1-sellada)" -eq 2 ]; then
	anota_fila OK; echo "5 local:   OK, ni p1-local-* ni p2-local-* paran la limpieza y los dos se van"
else
	anota_fila FALLA; mal "5 local:   FALLA, un local-* sobrevivio o se llevo por delante al sellado"
fi

# ---- 5b. el de Phase 2 dispara la negativa EL SOLO ----
# Con el de p1 fuera del montaje. Si estuviera, esta fila saldria verde por la
# razon de la fila 1 y no mediria nada de lo que dice medir.
monta
rm -rf gate/out/p1-sin-sello
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ] && [ "$(n_en gate/out/p2-sin-sello)" -eq 1 ]; then
	anota_fila OK; echo "5b p2:     OK, un p2-<run id> sin sello para la limpieza el solo y sigue entero"
else
	anota_fila FALLA; mal "5b p2:     FALLA, con rc=${rc} el artefacto de fierro de Phase 2 sin sello no paro la limpieza"
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
	anota_fila OK; echo "5c forma:  OK, un p3-<run id> de una phase inexistente para la limpieza y sigue entero"
else
	anota_fila FALLA; mal "5c forma:  FALLA, con rc=${rc} la guarda no miro a p3-; el predicado es una lista y no una forma"
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
	anota_fila OK; echo "9 vivo:    OK, una corrida viva para la limpieza entera y su directorio sigue ahi"
else
	anota_fila FALLA; mal "9 vivo:    FALLA, con rc=${rc} la limpieza no respeto un RUNNING con el pid vivo"
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
	anota_fila OK; echo "9b p1:     OK, un p1-local-* con marcador vivo para la limpieza, que es el incidente del 28 de agosto"
else
	anota_fila FALLA; mal "9b p1:     FALLA, con rc=${rc} un ensayo de p1 en vuelo se perdio igual que entonces"
fi
kill "${pid_p1}" 2>/dev/null || true
wait "${pid_p1}" 2>/dev/null || true

P1SH="${RAIZ_REPO}/gate/p1.sh"
if [ ! -f "${P1SH}" ]; then
	anota_fila FALLA; mal "9c escribe: FALLA, no encuentro ${P1SH}"
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
		anota_fila OK; echo "9c escribe: OK, gate/p1.sh define y LLAMA a las dos, la escritura va tras el mkdir, y ninguna esta vaciada"
	else
		anota_fila FALLA; mal "9c escribe: FALLA, def=${def_esc}/${def_ret} llamadas=${lla_esc}/${lla_ret} tras_mkdir=${tras_mkdir}; la fila 9b se quedaria fabricando el marcador sola"
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
	anota_fila OK; echo "9d vacio:  OK, un artefacto cuyo unico fichero es un RUNNING muerto se barre y no queda atrapado"
else
	anota_fila FALLA; mal "9d vacio:  FALLA, con rc=${rc} ese directorio quedo ni sellable ni barrible"
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
	anota_fila OK; echo "10 resto:  OK, un RUNNING de proceso muerto no para la limpieza, se anuncia y se barre"
else
	anota_fila FALLA; mal "10 resto:  FALLA, con rc=${rc} el resto de una corrida muerta no se barrio o no se anuncio"
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
	anota_fila OK; echo "12 valvula: OK, UNSEALED_OK=1 no se lleva una corrida viva, que es otra decision y otro precio"
else
	anota_fila FALLA; mal "12 valvula: FALLA, con rc=${rc} la valvula de los sellos se llevo la corrida viva"
fi
rc=0
make clean KILL_RUNNING_OK=1 >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ] && [ "$(hay gate/out/p2-local-encurso)" = no ]; then
	anota_fila OK; echo "12b propia: OK, KILL_RUNNING_OK=1 si se la lleva, que es lo que esa valvula dice"
else
	anota_fila FALLA; mal "12b propia: FALLA, con rc=${rc} la valvula propia no se llevo la corrida viva"
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
	anota_fila OK; echo "6 rojo(a): OK, MUERDE: sin la negativa, el artefacto sin sello se va y make clean sale con 0"
else
	anota_fila FALLA; mal "6 rojo(a): FALLA, sin la negativa la limpieza no se llevo el artefacto sin sello; la fila 1 no prueba nada"
fi

# ---- 7. ROJO de la preservacion ----
monta
make -f Makefile-sin-preservar clean UNSEALED_OK=1 >/dev/null 2>&1 || true
if [ "$(hay gate/out/p1-sellada)" = no ]; then
	anota_fila OK; echo "7 rojo(b): OK, MUERDE: sin la condicion de preservacion, el artefacto SELLADO se destruye"
else
	anota_fila FALLA; mal "7 rojo(b): FALLA, el sellado sobrevivio sin su condicion, asi que la fila 2 no prueba nada"
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
	anota_fila OK; echo "8 rojo(c): OK, MUERDE: con el predicado viejo el artefacto de Phase 2 sin sello se va y make clean sale con 0"
else
	anota_fila FALLA; mal "8 rojo(c): FALLA, con rc=${rc} el predicado viejo no perdio el artefacto de Phase 2; la fila 5b no prueba nada"
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
	anota_fila OK; echo "11 rojo(d): OK, MUERDE: sin la negativa, el directorio de una corrida VIVA se va y make clean sale con 0"
else
	anota_fila FALLA; mal "11 rojo(d): FALLA, con rc=${rc} el mutante no perdio la corrida viva; la fila 9 no prueba nada"
fi
kill "${pid_vivo2}" 2>/dev/null || true
wait "${pid_vivo2}" 2>/dev/null || true

# ---- 13, 13b y 13c: LA GUARDA DE BANCO CONTRA BANCO -------------------------
#
# Misma familia que las de arriba: una negativa que protege una corrida en vuelo,
# con el PROCESO como predicado y no un fichero. La trae quien encarga el 7 de
# septiembre de 2026 al ver dos `bash ./gate/p2-guard-test.sh` en su ps y
# preguntar si una cifra podia venir de dos bancos pisandose los puertos. Los dos
# que vio eran uno solo, medido; pero nada impedia que fueran dos de verdad, y
# entonces cada fila perdida cuesta un ensayo entero y sale como NO CUADRA.
#
# Las tres mitades se disparan aqui porque una negativa que solo se prueba por el
# lado que niega deja sin ver el caso que importa mas: el marcador rancio que
# bloquea para siempre.
# AQUI se fija en la cabecera, ANTES del cd al cajon, asi que apunta al arbol de
# verdad. La primera version uso ${PWD} y apuntaba al cajon, donde ese fichero no
# existe: las dos filas salieron FALLA por no encontrar el guion y no por lo que
# venian a medir, que es un falso rojo tan inutil como un falso verde.
BANCO="${AQUI}/p2-guard-test.sh"
# Si el banco no esta, las OCHO filas se saltan con su fallo cada una. La
# version anterior ponia BANCO="" y seguia: tres filas mas abajo, `sed ... ""`
# devuelve 1 bajo set -e y mata el guion DESPUES de que la redireccion haya creado
# gate/banco-sin-guarda-de-prueba.sh vacio, que se queda en el arbol sin que nadie
# lo diga. Medido: rc 1 y el fichero creado igual.
#
# Y ERAN OCHO Y NO CUATRO, que es una correccion del 8 de septiembre de 2026. Un
# lector conto las etiquetas que viven dentro del bloque BANCO_OK y salieron ocho:
# 13, 13a, 13b, 13c, 13d, 13e, 13f y 13g. El respaldo nombraba cuatro, asi que sin
# el banco desaparecian cuatro filas SIN fallo y sin cuenta, n_filas daba 23 en vez
# de 27, y ninguna de las dos anti-vacuidades lo notaba porque las dos cuentas
# seguian casando entre si. Ademas una de las cuatro se llamaba "13d limpia" y la
# fila de verdad se llama "13d retira": el respaldo describia una fila que no
# existe. Las etiquetas de aqui son las de las filas, copiadas de ellas.
BANCO_OK=1
if [ ! -x "${BANCO}" ]; then
	BANCO_OK=0
	anota_fila FALLA; mal "13 banco:    FALLA, no encuentro ${BANCO}"
	anota_fila FALLA; mal "13a respeta: FALLA, sin banco no se puede medir"
	anota_fila FALLA; mal "13b rancio:  FALLA, sin banco no se puede medir"
	anota_fila FALLA; mal "13c rojo:    FALLA, sin banco no se puede medir"
	anota_fila FALLA; mal "13d retira:  FALLA, sin banco no se puede medir"
	anota_fila FALLA; mal "13e rojo(f): FALLA, sin banco no se puede medir"
	anota_fila FALLA; mal "13f ajeno:   FALLA, sin banco no se puede medir"
	anota_fila FALLA; mal "13g a-la-vez: FALLA, sin banco no se puede medir"
fi

if [ "${BANCO_OK}" -eq 1 ]; then
	# UNA FILA QUE ARRANCA UN BANCO ENTERO PARA MIRAR SU PRIMERA LINEA ES BASURA.
	# La primera version de 13b y 13c dejo correr el banco: diecisiete filas, tres
	# replicas huerfanas al matarlo, un directorio nuevo por encima del techo y una
	# copia sin guarda en TMPDIR. Se midio al cerrar y se arreglo. Estas dos leen la
	# linea que les interesa, matan por PID, y barren lo que ese pid creo por su ruta
	# literal, con el run id que el propio banco imprime en su banner.
	espera_linea() {
		# espera_linea <fichero> <patron> <cota en segundos>. La cota es obligatoria y
		# lo que devuelve es si la vio, no cuanto espero.
		espera_i=0
		while [ "${espera_i}" -lt "$3" ]; do
			if [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null; then return 0; fi
			sleep 1
			espera_i=$((espera_i + 1))
		done
		return 1
	}
	para_banco_y_barre() {
		# para_banco_y_barre <pid> <fichero de salida>. Mata el banco por pid, mata lo
		# que quede de su ensayo por el CAMPO DEL EJECUTABLE, y retira su directorio
		# por la ruta literal que sale de SU PROPIO run id, nunca por un comodin.
		# El `wait` se traga el aviso de trabajo terminado que el shell imprime al
		# matar un proceso en segundo plano. Sin el, la salida de este banco lleva
		# lineas 'Killed: 9' que se leen como un fallo y no lo son.
		kill -9 "$1" 2>/dev/null || true
		wait "$1" 2>/dev/null || true
		sleep 1
		# EL FILTRO ANTERIOR ERA CODIGO MUERTO Y NUNCA MATO NADA. Preguntaba por el
		# campo comm de `ps -Ao pid,comm,args`, y en macOS ese campo CON cabecera se
		# trunca a 16 columnas: 893 de 898 procesos de esta maquina lo tienen de
		# exactamente esa longitud. El binario del ensayo vive en una ruta de 77
		# caracteres, asi que su comm es `/Users/jordanmon` y la regex `/p2-naylampd$/`
		# no podia casar jamas. Nadie lo noto porque en el camino verde las filas matan
		# el banco antes de que levante ninguna flota y no hay huerfanos que matar: la
		# linea solo hace falta cuando espera_linea agota su cota, que es justo cuando
		# no funcionaba. Ahora pregunta por el CAMPO DEL EJECUTABLE sobre
		# `pid,ppid,etime,command`, que es la forma de la clausula 28 y la que este
		# arbol ya usa en gate/p2-preflight.sh.
		huerfanos=$(ps -Ao pid,ppid,etime,command | awk '$4 ~ /naylampd$|naylampd-mutante$|p2-naylampd$/ && $5 == "node" { print $1 }')
		for h in ${huerfanos}; do kill -9 "${h}" 2>/dev/null || true; done
		corrida_b=$(sed -n 's/.*corrida \([0-9]\{8\}T[0-9]\{6\}Z-[0-9]*\).*/\1/p' "$2" 2>/dev/null | head -1)
		if [ -n "${corrida_b}" ]; then
			rm -rf -- "${TMPDIR:-/tmp}/naylamp-p2-guard-${corrida_b}"
		fi
	}

	MARCA_B="${TMPDIR:-/tmp}/naylamp-p2-bench-EN-CURSO"
	CERROJO_B="${MARCA_B}.lock"
	rm -f "${MARCA_B}"; rmdir "${CERROJO_B}" 2>/dev/null || true

	# ---- EL ARNES, que es el prologo REAL del banco con la marca desviada -----
	#
	# Las filas de aqui abajo NO arrancan un banco entero: cortan el guion en el
	# punto en que su prologo termina, o sea justo despues de la definicion de
	# retira_marca_banco, y le desvian el marcador a un fichero del cajon. Asi se
	# ejercita el codigo DE VERDAD, cerrojo incluido, sin levantar ninguna flota.
	#
	# Y EL CEBO DE LA FILA 13 TIENE QUE SER UN BANCO, no un sleep. La version
	# anterior ponia el pid de un `sleep 120` en el marcador, y desde que la guarda
	# cruza la linea de orden ese pid ya no es un banco: la negativa no salta y la
	# fila salia FALLA por su propio cebo. El cebo es ahora otro arnes vivo.
	# LOS CUATRO ARNESES LLEVAN p2-guard-test.sh EN EL NOMBRE, y eso es una
	# consecuencia directa del arreglo de la guarda, no una mania. Desde que
	# otro_banco_vivo cruza la LINEA DE ORDEN del pid, un proceso que no se llame
	# asi no es un banco para ella, y hace bien. La primera version de estas filas
	# uso un arnes llamado arnes-prologo.sh y la fila de los dos a la vez salio
	# FALLA con el mensaje "existe y NO es un banco": el cerrojo funcionaba y el
	# CEBO era el que no valia. Medido antes de tocar la guarda.
	ARNES="${CAJON}/corto-p2-guard-test.sh"
	ARNES_LARGO="${CAJON}/cebo-p2-guard-test.sh"
	MARCA_A="${CAJON}/marca-arnes"
	fin_prologo=$(grep -n '^}' "${BANCO}" | awk -F: '$1 > '"$(grep -n '^retira_marca_banco() {' "${BANCO}" | cut -d: -f1)"' {print $1; exit}')
	# GATE_DIR se fija tambien, y no es un detalle: el banco resuelve su sitio por
	# el dirname de BASH_SOURCE, y desde el cajon no encontraria p2.sh. La primera
	# version del arnes no lo fijaba y las seis filas salieron FALLA por
	# "guard: no encuentro .../p2.sh", o sea midiendo otra cosa. Es el mismo
	# tropiezo que ya costo la ruta de ${PWD} unas horas antes.
	sed -n "1,${fin_prologo}p" "${BANCO}" \
		| sed "s|\${TMPDIR:-/tmp}/naylamp-p2-bench-EN-CURSO|${MARCA_A}|" \
		| sed "s|^GATE_DIR=.*|GATE_DIR=\"${AQUI}\"|" > "${ARNES}"
	printf '\necho "ARNES: pase el prologo con pid $$"\nretira_marca_banco\necho "ARNES: retire"\n' >> "${ARNES}"
	chmod +x "${ARNES}"
	# El mismo, pero se queda vivo: es el CEBO de la fila 13.
	sed "s|^retira_marca_banco\$|echo \"ARNES: pase el prologo con pid \$\$\"; sleep 90|" "${ARNES}" > "${ARNES_LARGO}"
	chmod +x "${ARNES_LARGO}"
	# Y un tercero que pasa, SE QUEDA UN INSTANTE y retira. Sin esa pausa los dos
	# de la fila 13g no llegan a solaparse: el primero termina y suelta el cerrojo
	# antes de que el segundo lo mire, y pasan los dos legitimamente, en serie. La
	# primera version de esa fila usaba el arnes corto y salia FALLA acusando al
	# cerrojo de no excluir cuando lo que no habia era concurrencia.
	ARNES_SOLAPA="${CAJON}/solapa-p2-guard-test.sh"
	sed "s|^retira_marca_banco\$|sleep 2; retira_marca_banco|" "${ARNES}" > "${ARNES_SOLAPA}"
	chmod +x "${ARNES_SOLAPA}"

	limpia_arnes() { rm -f "${MARCA_A}" "${MARCA_A}".tmp.* 2>/dev/null || true; rmdir "${MARCA_A}.lock" 2>/dev/null || true; }

	# 13: con OTRO BANCO vivo, se niega y no crea su directorio
	limpia_arnes
	bash "${ARNES_LARGO}" > "${CAJON}/a13-cebo.txt" 2>&1 &
	pid_cebo=$!
	espera_linea "${CAJON}/a13-cebo.txt" "pase el prologo" 15 || true
	antes_dirs=$(ls -d "${TMPDIR:-/tmp}"/naylamp-p2-guard-2* 2>/dev/null | wc -l | tr -d ' ')
	rc=0
	salida_b="$(bash "${ARNES}" 2>&1)" || rc=$?
	despues_dirs=$(ls -d "${TMPDIR:-/tmp}"/naylamp-p2-guard-2* 2>/dev/null | wc -l | tr -d ' ')
	if [ "${rc}" -eq 2 ] && [ "${antes_dirs}" = "${despues_dirs}" ] \
	   && echo "${salida_b}" | grep -q "another bench is already running" \
	   && ! echo "${salida_b}" | grep -q "pase el prologo"; then
		anota_fila OK; echo "13 banco:   OK, se niega con rc=2 ante otro banco vivo, PARA antes del prologo y no crea directorio"
	else
		anota_fila FALLA; mal "13 banco:   FALLA, rc=${rc}, directorios ${antes_dirs}->${despues_dirs}"
	fi
	# 13a: y el marcador del cebo SIGUE, que es lo que la negativa tiene que respetar
	if grep -q "^pid: ${pid_cebo}\$" "${MARCA_A}" 2>/dev/null; then
		anota_fila OK; echo "13a respeta: OK, la negativa no toco el marcador del banco vivo"
	else
		anota_fila FALLA; mal "13a respeta: FALLA, el marcador del cebo (pid ${pid_cebo}) ya no esta"
	fi
	kill -9 "${pid_cebo}" 2>/dev/null || true
	wait "${pid_cebo}" 2>/dev/null || true
	limpia_arnes

	# 13b: con un pid MUERTO dentro, retira el marcador, SIGUE, y lo sustituye
	printf 'pid: 999999\nrun: prueba\nstarted: prueba\n' > "${MARCA_A}"
	mkdir -p "${MARCA_A}.lock"
	salida_b="$(bash "${ARNES}" 2>&1)" || true
	if ! echo "${salida_b}" | grep -q "ya no existe; se retira"; then
		anota_fila FALLA; mal "13b rancio: FALLA, el marcador con pid muerto no se retiro"
	elif ! echo "${salida_b}" | grep -q "pase el prologo"; then
		anota_fila FALLA; mal "13b rancio: FALLA, retiro el marcador y NO siguio; la pregunta del flujo dice que tiene que seguir"
	elif echo "${salida_b}" | grep -q "another bench is already running"; then
		anota_fila FALLA; mal "13b rancio: FALLA, se nego pese a que el marcador estaba rancio"
	elif ! echo "${salida_b}" | grep -q "ARNES: retire"; then
		anota_fila FALLA; mal "13b rancio: FALLA, no llego a su retirada"
	else
		anota_fila OK; echo "13b rancio: OK, retira el rancio, SIGUE hasta el final y retira el suyo"
	fi
	limpia_arnes

	# 13c ROJO: sin la negativa, el segundo banco pasa con el primero vivo
	ARNES_SIN_GUARDA="${CAJON}/singuarda-p2-guard-test.sh"
	sed 's|^if \[ -n "${OTRO}" \]; then|if false; then|' "${ARNES}" > "${ARNES_SIN_GUARDA}"
	chmod +x "${ARNES_SIN_GUARDA}"
	if cmp -s "${ARNES}" "${ARNES_SIN_GUARDA}"; then
		anota_fila FALLA; mal "13c rojo:   FALLA, la mutacion no cambio nada, asi que no muta la negativa"
	else
		limpia_arnes
		bash "${ARNES_LARGO}" > "${CAJON}/a13c-cebo.txt" 2>&1 &
		pid_cebo3=$!
		espera_linea "${CAJON}/a13c-cebo.txt" "pase el prologo" 15 || true
		salida_c="$(bash "${ARNES_SIN_GUARDA}" 2>&1)" || true
		if echo "${salida_c}" | grep -q "pase el prologo"; then
			anota_fila OK; echo "13c rojo:   OK, MUERDE: sin la negativa el segundo banco pasa el prologo con el primero vivo"
		else
			anota_fila FALLA; mal "13c rojo:   FALLA, el mutante no paso; la fila 13 no prueba la negativa"
		fi
		kill -9 "${pid_cebo3}" 2>/dev/null || true
		wait "${pid_cebo3}" 2>/dev/null || true
		limpia_arnes
	fi

	# 13d: un banco que termina BIEN deja su marcador retirado
	limpia_arnes
	salida_d="$(bash "${ARNES}" 2>&1)" || true
	if echo "${salida_d}" | grep -q "ARNES: retire" && [ ! -e "${MARCA_A}" ] && [ ! -d "${MARCA_A}.lock" ]; then
		anota_fila OK; echo "13d retira: OK, al terminar bien no deja marcador ni cerrojo"
	else
		anota_fila FALLA; mal "13d retira: FALLA, quedan marcador=$([ -e "${MARCA_A}" ] && echo si || echo no) cerrojo=$([ -d "${MARCA_A}.lock" ] && echo si || echo no)"
	fi

	# 13e ROJO: sin la retirada, el marcador sobrevive al banco
	ARNES_SIN_RET="${CAJON}/sinretirada-p2-guard-test.sh"
	sed 's|^retira_marca_banco$|: # retirada quitada a proposito|' "${ARNES}" > "${ARNES_SIN_RET}"
	chmod +x "${ARNES_SIN_RET}"
	limpia_arnes
	bash "${ARNES_SIN_RET}" > "${CAJON}/a13e.txt" 2>&1 || true
	if [ -e "${MARCA_A}" ]; then
		anota_fila OK; echo "13e rojo(f): OK, MUERDE: sin la retirada el marcador sobrevive al banco"
	else
		anota_fila FALLA; mal "13e rojo(f): FALLA, el marcador se fue igual, asi que 13d no prueba la retirada"
	fi
	limpia_arnes

	# 13f: la retirada NO borra el marcador de otro banco
	printf 'pid: 999998\nrun: de-otro\nstarted: prueba\n' > "${MARCA_A}"
	mkdir -p "${MARCA_A}.lock"
	bash -c 'MARCA_BANCO="'"${MARCA_A}"'"; CERROJO="'"${MARCA_A}"'.lock"
retira_marca_banco() {
	if [ -f "${MARCA_BANCO}" ] && grep -q "^pid: $$\$" "${MARCA_BANCO}" 2>/dev/null; then
		rm -f -- "${MARCA_BANCO}"; rmdir "${CERROJO}" 2>/dev/null || true
	fi
}
retira_marca_banco' 2>/dev/null || true
	if [ -e "${MARCA_A}" ] && grep -q "^pid: 999998\$" "${MARCA_A}"; then
		anota_fila OK; echo "13f ajeno:  OK, la retirada respeta el marcador de otro banco"
	else
		anota_fila FALLA; mal "13f ajeno:  FALLA, borro un marcador que no era suyo"
	fi
	limpia_arnes

	# 13g: DOS bancos entrando A LA VEZ. Es el caso que la guarda existe para negar
	# y que ninguna fila lanzaba. Con el cerrojo por mkdir, uno tiene que perder
	# aunque salgan en el mismo instante; con el if de antes pasaban los dos.
	limpia_arnes
	bash "${ARNES_SOLAPA}" > "${CAJON}/a13g-1.txt" 2>&1 &
	pa=$!
	bash "${ARNES_SOLAPA}" > "${CAJON}/a13g-2.txt" 2>&1 &
	pb=$!
	wait "${pa}" 2>/dev/null || true
	wait "${pb}" 2>/dev/null || true
	llegaron=$(cat "${CAJON}/a13g-1.txt" "${CAJON}/a13g-2.txt" 2>/dev/null | grep -c "pase el prologo")
	if [ "${llegaron}" -le 1 ]; then
		anota_fila OK; echo "13g a-la-vez: OK, con los dos entrando juntos solo ${llegaron} paso el prologo"
	else
		anota_fila FALLA; mal "13g a-la-vez: FALLA, pasaron ${llegaron}; el cerrojo no excluye"
	fi
	limpia_arnes
	rm -f "${ARNES}" "${ARNES_LARGO}" "${ARNES_SOLAPA}" "${ARNES_SIN_GUARDA}" "${ARNES_SIN_RET}"
fi

n_filas=$(grep -c . "${REGISTRO_FILAS}" || true)
n_falla=$(grep -c '^FALLA$' "${REGISTRO_FILAS}" || true)
echo "RESULTADO: ${n_filas} filas, ${n_falla} en FALLA"
# COMPLETO SE PONE AQUI Y NO DESPUES DE LAS DOS ANTI-VACUIDADES, y es una
# correccion del 8 de septiembre de 2026. Estaban las dos por delante, saliendo
# por exit 1 con COMPLETO todavia en cero, asi que la trampa imprimia "ABORTADO
# antes del resumen" JUSTO DEBAJO del resumen que se acababa de imprimir. Un
# lector midio lo que costaba: el barrido del archivo leia la linea de RESULTADO,
# daba la corrida por terminada, y el banner que la contradecia tres lineas mas
# abajo no lo miraba nadie. El resumen es la linea de RESULTADO: llegar hasta
# aqui es haber terminado, y lo que salga rojo despues es un rojo ordinario.
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
echo "test: la guarda se niega por forma y no por lista, respeta una corrida viva, barre el resto de una muerta, preserva, y las mitades rojas muerden"
