#!/bin/sh
# Prueba de la guarda finished_cleanly de gate/p1.sh, con su BRAZO ROJO.
#
# Por que existe: hasta el 29 de agosto de 2026, red_row concluia que una
# mutacion habia SOBREVIVIDO por la AUSENCIA del patron rojo esperado, y solo
# descartaba dos formas de no haber corrido: un host que se niega y un test que
# muere en su techo de reloj. No descartaba una corrida CORTADA, asi que una
# salida truncada caia en la rama de supervivencia y el gate escribia "The
# mutation ran and the check ... did not go red", cuyas dos mitades son falsas
# cuando la corrida no termino. Paso de verdad: el portatil que lanzo la corrida
# de fierro de ese dia se durmio, las sesiones ssh viven en el portatil, y
# red-relleno.txt se quedo en "upserted 30000 / 60009".
#
# Que prueba, y sobre QUE. No sobre una copia de la funcion, que se pudre en
# cuanto alguien toca el guion, sino sobre la que vive dentro de gate/p1.sh,
# extraida de el en cada corrida. Y no sobre ficheros inventados, sino sobre los
# crudos archivados de las DOS corridas de fierro, que son evidencia real y ya
# estan selladas:
#   gate/out/p1-20260826T214025Z-63564  las nueve del 26, todas enteras
#   gate/out/p1-20260829T051448Z-46398  las nueve del 29, ocho enteras y una cortada
#
# Las tres mitades:
#   VERDE     cada crudo entero tiene que dar TERMINO.
#   ROJO      el crudo cortado real, red-relleno.txt del 29, tiene que dar NO
#             CORRIDA; y un crudo entero truncado a mano, tambien.
#   VACUIDAD  si el entero y su truncado dan lo MISMO, la prueba se declara
#             vacia y falla, porque entonces no estaria separando nada.
#   SITIO     la llamada tiene que vivir dentro de red_row y delante de las DOS
#             conclusiones. El defecto del 29 no fue el predicado, fue el sitio,
#             y sin esta mitad se puede reintroducir dejando la prueba verde.
#
# Uso: ./gate/redrow-guard-test.sh   (desde la raiz del repositorio, rc=0 si va)
#
# No toca la red, no enciende ninguna VM, no escribe en gate/out y no modifica
# ningun artefacto sellado: solo lee los crudos y trabaja en un directorio
# temporal propio que retira al salir.

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
echo "BANCO: redrow-guard-test"

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
GUION="${RAIZ}/gate/p1.sh"
A26="${RAIZ}/gate/out/p1-20260826T214025Z-63564"
A29="${RAIZ}/gate/out/p1-20260829T051448Z-46398"
CORTADO="${A29}/red-relleno.txt"

[ -r "${GUION}" ] || { echo "test: no encuentro ${GUION}" >&2; exit 2; }

CAJON=$(mktemp -d "${TMPDIR:-/tmp}/redrow-guard-test.XXXXXX")
# LA BANDERA DE TERMINACION, escrita el 8 de septiembre de 2026 y la trae un
# lector adversarial. Una trampa EXIT se COME el estado de salida cuando el
# guion muere por `set -e` o `set -u`: medido en el `/bin/sh` de esta maquina,
# que es bash 3.2, un abortado pasa de rc 1 a rc 0. Preservar `$?` dentro de la
# trampa no lo arregla, porque para entonces ya vale 0. Medido sobre este mismo
# banco: abortado a mitad devolvia CERO, y dos de estos bancos corren en CI, o
# sea que un banco muerto se leia como un paso verde.
# LA LINEA DE RESULTADO, UNIFORME EN TODOS LOS BANCOS DE ESTA CASA, y entra el
# 8 de septiembre de 2026 por una orden de quien encarga. Nace de que una trampa
# EXIT convertia un abortado en rc 0: cualquier banco archivado pudo morir a
# medias y leerse como verde, asi que hay que poder barrer `corridas/` y separar
# lo completo de lo abortado.
#
# Y NACE TAMBIEN DE QUE EL PRIMER BARRIDO FALLO POR ANCLARSE AL TEXTO. La linea
# final de OTRO banco, el de limpieza, decia una cosa el 6 de septiembre y otra
# el 7. La de ESTE no ha cambiado nunca, comprobado con git show sobre la
# historia, y la primera version de este comentario decia "este banco" porque
# se clono del suyo sin releer el deictico: la misma clase que el bloque
# denuncia, cometida dentro del bloque. Un predicado anclado a la redaccion
# daba por ABORTADA una corrida entera, asi que un
# predicado anclado a su redaccion daba por ABORTADA una corrida entera. Una
# marca de terminacion no puede ser prosa: tiene que ser una FORMA estable,
# `RESULTADO: <n> rows, <n> failing`. **Y NO ES IGUAL EN LOS SIETE, que es lo
# que decia esta linea y no describia el arbol:** son SEIS con esa forma y uno,
# `gate/p2-iron-test.sh`, con un superconjunto de tres numeros,
# `RESULTADO: <n> filas, <n> de ellas rojas, <n> en FALLA`. El predicado del
# barrido acepta las dos a proposito, con un grupo opcional; la afirmacion de que
# eran siete iguales se escribio cuatro veces en el arbol y era falsa en todas.
# Desde el 8 de septiembre son OCHO bancos, con gate/sello-test.sh. Y con la
# cuenta derivada del registro y no tecleada.
ROW_LOG="${CAJON}/bench-rows"
: > "${ROW_LOG}"
anota_fila() { printf '%s\n' "$1" >> "${ROW_LOG}"; }
COMPLETO=0
limpia_y_cierra() {
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2
		find "$CAJON" -mindepth 1 -delete 2>/dev/null || true; rmdir "$CAJON" 2>/dev/null || true
		exit 1
	fi
	find "$CAJON" -mindepth 1 -delete 2>/dev/null || true; rmdir "$CAJON" 2>/dev/null || true
}
trap limpia_y_cierra EXIT

# La funcion se saca del guion y no se copia aqui. Si alguien la renombra o la
# borra, la extraccion sale vacia y la prueba se declara VACIA en vez de pasar.
sed -n '/^finished_cleanly() {/,/^}/p' "${GUION}" > "${CAJON}/fn.sh"
if ! grep -q '^finished_cleanly() {' "${CAJON}/fn.sh"; then
	echo "test: no pude extraer finished_cleanly de gate/p1.sh" >&2
	echo "test: VACIO. Alguien la renombro o la retiro, y esta prueba dejo de probar" >&2
	exit 1
fi
. "${CAJON}/fn.sh"

fallos=0
di() { printf '%s\n' "$1"; }
verdicto() { finished_cleanly "$1" && echo TERMINO || echo "NO CORRIDA"; }

# ---- VERDE: todo crudo entero de las dos corridas tiene que decir TERMINO ----
enteros=0
malos=0
for f in "${A26}"/red-*.txt "${A29}"/red-*.txt; do
	[ -r "${f}" ] || continue
	[ "${f}" = "${CORTADO}" ] && continue
	enteros=$((enteros + 1))
	if [ "$(verdicto "${f}")" != "TERMINO" ]; then
		di "verde: FALLA, $(basename "$(dirname "${f}")")/$(basename "${f}") deberia decir TERMINO" >&2
		# EL BUCLE NO TOCA EL ACUMULADOR, y esto es del 8 de septiembre. Contando
		# aqui, diecisiete crudos malos daban diecisiete fallos para UNA sola fila,
		# y la cuenta de filas rojas del registro no podia casar nunca con la del
		# acumulador. Quien cuenta es la conclusion de la fila, una vez.
		malos=$((malos + 1))
	fi
done
# Sin un suelo, un directorio vacio o renombrado daria cero crudos y la mitad
# verde saldria bien sin haber mirado nada. Es el instrumento muerto que esta
# casa ya pago una vez.
if [ "${enteros}" -lt 17 ]; then
	anota_fila FAILING
	di "verde: VACIO. Solo encontre ${enteros} crudos enteros y hacen falta al menos 17" >&2
	di "verde: los artefactos sellados de las dos corridas de fierro no estan donde se esperan" >&2
	fallos=$((fallos + 1))
elif [ "${malos}" -eq 0 ]; then
	anota_fila OK; di "verde: OK, los ${enteros} crudos enteros de las dos corridas dicen TERMINO"
else
	anota_fila FAILING
	di "verde: FALLA, ${malos} de los ${enteros} crudos enteros no dijeron TERMINO" >&2
	fallos=$((fallos + 1))
fi

# ---- ROJO 1: el corte REAL, que es el que destapo el defecto ----
if [ ! -r "${CORTADO}" ]; then
	anota_fila FAILING
	di "rojo:  VACIO. Falta el crudo cortado real ${CORTADO}" >&2
	fallos=$((fallos + 1))
elif ! grep -q 'upserted 30000 / 60009' "${CORTADO}" \
	|| ! grep -q 'client_loop: send disconnect: Broken pipe' "${CORTADO}"; then
	# Sin esto, ROJO 1 solo exigia que el crudo NO dijera TERMINO, y eso lo cumple
	# cualquier cosa: un fichero vacio, uno de basura, uno que perdio su contenido.
	# La fila pasaria sin pinchar en nada del corte real. Se ancla por TEXTO y no
	# por numero de linea, como el tripwire de gate/common_red_pins.txt.
	anota_fila FAILING
	di "rojo:  VACIO. ${CORTADO} ya no trae las dos lineas del corte real" >&2
	di "       hacen falta 'upserted 30000 / 60009' y 'client_loop: send disconnect: Broken pipe'" >&2
	fallos=$((fallos + 1))
elif [ "$(verdicto "${CORTADO}")" = "NO CORRIDA" ]; then
	anota_fila OK; di "rojo:  OK, MUERDE sobre el corte real, con sus dos lineas ancladas dentro"
	di "       su ultima linea es: $(tail -n1 "${CORTADO}")"
else
	anota_fila FAILING
	di "rojo:  FALLA, el corte real dice TERMINO y el defecto sigue abierto" >&2
	fallos=$((fallos + 1))
fi

# ---- ROJO 2: un entero truncado a mano, y su ANTI-VACUIDAD ----
PATRON="${A29}/red-fuga.txt"
if [ ! -r "${PATRON}" ]; then
	anota_fila FAILING
	di "rojo:  VACIO. Falta el crudo entero que sirve de patron" >&2
	fallos=$((fallos + 1))
else
	head -n 3 "${PATRON}" > "${CAJON}/truncado.txt"
	cp "${PATRON}" "${CAJON}/entero.txt"
	v_ent=$(verdicto "${CAJON}/entero.txt")
	v_tru=$(verdicto "${CAJON}/truncado.txt")
	if [ "${v_ent}" = "${v_tru}" ]; then
		anota_fila FAILING
		di "test:  VACIO. El entero y su truncado dan lo mismo (${v_ent}), asi que esta prueba no separa nada" >&2
		fallos=$((fallos + 1))
	elif [ "${v_ent}" = "TERMINO" ] && [ "${v_tru}" = "NO CORRIDA" ]; then
		anota_fila OK; di "rojo:  OK, MUERDE sobre un entero truncado a mano, y el entero sigue diciendo TERMINO"
	else
		anota_fila FAILING
		di "rojo:  FALLA, entero=${v_ent} truncado=${v_tru}, que no es lo que se pide" >&2
		fallos=$((fallos + 1))
	fi
fi

# ---- SITIO: donde estuvo el defecto, y lo unico que las mitades de arriba no ven ----
# Las tres anteriores prueban el PREDICADO, y el predicado no fue lo que fallo el
# 29 de agosto de 2026. Fallo el SITIO: una corrida cortada caia en la rama de
# supervivencia. Sin esta mitad, borrar la llamada de red_row o moverla detras
# del branch de SURVIVED deja la funcion intacta, reintroduce el defecto palabra
# por palabra, y esta prueba sale verde. Medido antes de escribirla: las dos
# variantes daban rc=0.
sed -n '/^red_row() {/,/^}/p' "${GUION}" > "${CAJON}/red_row.sh"
n_llam=$(grep -c 'finished_cleanly "${out}"' "${CAJON}/red_row.sh" || true)
l_llam=$(grep -n 'if ! finished_cleanly "${out}"; then' "${CAJON}/red_row.sh" | head -n1 | cut -d: -f1)
l_surv=$(grep -n 'SURVIVED\.' "${CAJON}/red_row.sh" | head -n1 | cut -d: -f1)
l_pass=$(grep -n 'pass "${id}: red as written' "${CAJON}/red_row.sh" | head -n1 | cut -d: -f1)
if [ ! -s "${CAJON}/red_row.sh" ] || [ -z "${l_surv}" ] || [ -z "${l_pass}" ]; then
	anota_fila FAILING
	di "sitio: VACIO. No pude leer red_row ni sus dos conclusiones en gate/p1.sh" >&2
	di "sitio: alguien la renombro o cambio el texto de una conclusion, y esta mitad dejo de probar" >&2
	fallos=$((fallos + 1))
elif [ "${n_llam}" != 1 ] || [ -z "${l_llam}" ]; then
	anota_fila FAILING
	# EL MENSAJE NOMBRA LAS DOS MITADES DE LA CONDICION, y la primera version solo
	# nombraba una. La rama salta si la llamada no aparece exactamente una vez O si
	# la linea del `if` no se localiza, y con solo la cuenta impresa salia el
	# absurdo "llama 1 vez y tiene que llamarla exactamente una", que manda a quien
	# lee a buscar donde no es. Medido al mutar un espacio dentro del `if`.
	di "sitio: FALLA. red_row llama a finished_cleanly ${n_llam} vez(veces), y hace falta exactamente una" >&2
	if [ -z "${l_llam}" ]; then
		di "sitio: y la que falla aqui es la otra mitad: no se localiza la linea 'if ! finished_cleanly \"\${out}\"; then'" >&2
		di "sitio: la llamada existe pero ya no tiene esa forma, asi que no se puede decir si va antes de las conclusiones" >&2
	fi
	fallos=$((fallos + 1))
elif [ "${l_llam}" -lt "${l_surv}" ] && [ "${l_llam}" -lt "${l_pass}" ]; then
	anota_fila OK; di "sitio: OK, la llamada vive dentro de red_row y va antes de las DOS conclusiones"
else
	anota_fila FAILING
	di "sitio: FALLA. La llamada va DESPUES de una conclusion (llamada=${l_llam} SURVIVED=${l_surv} pass=${l_pass})" >&2
	di "sitio: que es el defecto del 29 de agosto otra vez" >&2
	fallos=$((fallos + 1))
fi

n_filas=$(grep -c . "${ROW_LOG}" || true)
n_falla=$(grep -c '^FAILING$' "${ROW_LOG}" || true)
echo "RESULTADO: ${n_filas} rows, ${n_falla} failing"
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
[ "${fallos}" -eq 0 ] || { di "test: ${fallos} fallo(s)" >&2; exit 1; }
di "test: la guarda separa lo cortado de lo entero, las mitades muerden, y la llamada sigue en su sitio"
