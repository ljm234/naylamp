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
# Las filas VERDES, que son las cinco cosas que la guarda promete:
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
#
# Las filas ROJAS, una por pieza del Makefile, porque las dos se pueden perder
# por separado:
#   6. sin la negativa, el artefacto sin sello se va y `make clean` sale con 0
#   7. sin la condicion de preservacion, el artefacto SELLADO se destruye
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
if [ "$(hay gate/out/p1-sin-sello)" = no ] && [ "$(hay scale_result.txt)" = no ]; then
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
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -eq 0 ]; then
	echo "4 vacio:   OK, un artefacto de fierro vacio y sin sello no para la limpieza"
else
	mal "4 vacio:   FALLA, la negativa salto con rc=${rc} por un directorio vacio"
fi

# ---- 5. p1-local-* no dispara la negativa, y aun asi se lo lleva ----
monta
rm -rf gate/out/p1-sin-sello
rc=0
make clean >/dev/null 2>&1 || rc=$?
if [ "${rc}" -ne 0 ]; then
	mal "5 local:   FALLA, un p1-local-* sin sello disparo la negativa, y la exclusion es deliberada"
elif [ "$(hay gate/out/p1-local-ensayo)" = no ] && [ "$(n_en gate/out/p1-sellada)" -eq 2 ]; then
	echo "5 local:   OK, no para la limpieza y se lo lleva, que es la exclusion que costo un ensayo"
else
	mal "5 local:   FALLA, el p1-local-* sobrevivio o se llevo por delante al sellado"
fi

# ---- las dos mutaciones, y su anti-vacuidad ----
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
awk '
	/^clean:$/           { print; dentro = 1; next }
	dentro && /^\ttest ! -d gate\/out \|\| find gate\/out/ { dentro = 0 }
	dentro               { next }
	                     { print }
' Makefile > Makefile-sin-negativa
grep -v '! -exec test -e {}/SEALED' Makefile > Makefile-sin-preservar

for m in Makefile-sin-negativa Makefile-sin-preservar; do
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

[ "${fallos}" -eq 0 ] || { echo "test: ${fallos} fallo(s)" >&2; exit 1; }
echo "test: la guarda se niega, preserva, barre, respeta sus dos excepciones, y las mitades rojas muerden"
