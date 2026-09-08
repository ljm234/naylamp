#!/bin/sh
# Prueba del margen del material TLS, con su BRAZO ROJO dentro.
#
# QUE DEFIENDE, y no es el numero sino el ACUERDO. `gate/build.sh` re-acuna solo
# cuando el material falla el margen, y `gate/p2-preflight.sh` se niega a abrir
# una sesion cuando falla el mismo margen. Si los dos numeros se separan, hay una
# VENTANA MUERTA entre ellos: un tramo en el que la lista previa dice que no y el
# remedio documentado, re-construir, devuelve los mismos certificados. Con los
# dos en 7200 no se noto; el 8 de septiembre de 2026, al subir la lista previa a
# seis horas, habria aparecido si el numero hubiera seguido escrito en cada
# guion.
#
# POR QUE ESTA SI PUEDE IR A CI, al reves que gate/hook-guard-test.sh. Aquella
# depende de `.git/hooks/commit-msg`, que no esta versionado, asi que en un
# corredor no habria nada que probar (clausula 16). Esta mira ficheros del arbol
# y acuna certificados de usar y tirar con `openssl`, que es lo unico que
# necesita. No enciende nada, no toca la nube y no escribe fuera de su caja.
#
# Uso: ./gate/cert-margen-test.sh    (desde donde sea, rc=0 si todas van)

set -eu

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

MARGEN_FICH="${AQUI}/cert-margen.sh"
if [ ! -r "${MARGEN_FICH}" ]; then
	echo "test: NO HAY ${MARGEN_FICH}" >&2
	echo "test: sin el, los tres guiones que lo sourcean se niegan a correr" >&2
	echo "test: eso no es un fallo de esta prueba, es su resultado" >&2
	exit 1
fi
. "${MARGEN_FICH}"

CAJON=$(mktemp -d "${TMPDIR:-/tmp}/cert-margen-test.XXXXXX")
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
REGISTRO="${CAJON}/filas"
: > "${REGISTRO}"
ok()  { echo "$1"; printf 'OK\n' >> "${REGISTRO}"; }
mal() { echo "$1" >&2; printf 'FALLA\n' >> "${REGISTRO}"; fallos=$((fallos + 1)); }

# Los guiones que TIENEN que estar de acuerdo. La lista va escrita una vez y las
# dos filas de abajo se derivan de ella, para que anadir un cuarto guion no deje
# una comprobacion mirando a tres.
USUARIOS="build.sh p2-preflight.sh p2.sh"

# ---- el numero se lee, y es un numero ----
case "${CERT_MARGEN_SEG:-}" in
	''|*[!0-9]*)
		mal "valor:  FALLA, CERT_MARGEN_SEG no es un numero de segundos: '${CERT_MARGEN_SEG:-}'"
		;;
	*)
		ok "valor:  OK, CERT_MARGEN_SEG=${CERT_MARGEN_SEG} segundos, $((CERT_MARGEN_SEG / 3600)) horas"
		;;
esac

# ---- NINGUN GUION LLEVA EL NUMERO ESCRITO ----
# Es la fila que impide que el acuerdo se rompa: en cuanto alguien vuelva a
# poner un literal, hay dos numeros y puede haber ventana muerta.
literales=0
sueltos=""
for g in ${USUARIOS}; do
	# EL PATRON SE ENSANCHO, y lo trajo un lector que probo las dos formas mas
	# naturales de volver a meter el numero: `-checkend "7200"`, que es como este
	# arbol entrecomilla todo lo demas, y `-checkend ${CERT_MARGEN_SEG:-7200}`,
	# que es lo que escribiria quien quiera "un valor por si acaso" y es
	# exactamente la ventana muerta. La primera version exigia digito PEGADO al
	# espacio y no veia ninguna de las dos.
	# Y ACOTADO A LA LINEA DEL `checkend`, porque la primera version del patron
	# ensanchado casaba cualquier `${VAR:-0}` del guion: cuatro aciertos
	# legitimos en p2-preflight.sh y p2.sh, y una guarda que enrojece sobre
	# codigo correcto se apaga sola.
	n=$(grep -cE 'checkend[[:space:]]*"?[0-9]|checkend.*:-[0-9]' "${RAIZ_REPO}/gate/${g}" 2>/dev/null || true)
	case "${n}" in ''|*[!0-9]*) n=0 ;; esac
	if [ "${n}" -gt 0 ]; then literales=$((literales + n)); sueltos="${sueltos} ${g}(${n})"; fi
done
if [ "${literales}" -eq 0 ]; then
	ok "literal: OK, ninguno de los guiones lleva el margen escrito a mano; el numero vive en un solo sitio"
else
	mal "literal: FALLA, ${literales} literal(es) de checkend sueltos:${sueltos}; con dos numeros hay ventana muerta"
fi

# ---- y los tres lo SOURCEAN ----
faltan=""
for g in ${USUARIOS}; do
	# SE EXIGE LA ORDEN DE SOURCE Y NO LA MENCION, porque la primera version
	# preguntaba si el nombre del fichero aparecia en el guion y eso lo cumple
	# hasta un comentario: rebobinada la linea de source y sustituida por un
	# valor a mano, la fila seguia verde. Ahora se busca la orden.
	grep -qE '^[[:space:]]*(\.|source)[[:space:]]+"\$\{GATE_DIR\}/cert-margen\.sh"' "${RAIZ_REPO}/gate/${g}" \
		|| faltan="${faltan} ${g}"
done
if [ -z "${faltan}" ]; then
	ok "source: OK, los tres guiones que miran el material sourcean el mismo fichero"
else
	mal "source: FALLA, no lo sourcean:${faltan}; ese guion decide con otro margen o con ninguno"
fi

# ---- NI EN PROSA: NINGUN TEXTO CITA LA DURACION A MANO ----
# El predicado de la fila `literal` mira el ARGUMENTO de `checkend` y no ve un
# numero escrito dentro de un `echo`. Un lector encontro asi el undecimo texto,
# `gate/build.sh` diciendo "valid for at least 2 hours" con el margen ya en
# seis, y ademas en la rama de CONSERVAR, que es la que mas se recorre. La
# pasada barrio diez textos y publico "cero literales" bajo un predicado que no
# alcanzaba a la clase que la frase prometia.
prosa=""
for g in ${USUARIOS}; do
	c=$(grep -cEi '(valid for at least|expir(es|ing) within|caduca|quedan menos de)[^"]*[0-9]+[[:space:]]*(hours?|horas|h\b)' "${RAIZ_REPO}/gate/${g}" 2>/dev/null || true)
	case "${c}" in ''|*[!0-9]*) c=0 ;; esac
	[ "${c}" -gt 0 ] && prosa="${prosa} ${g}(${c})"
done
if [ -z "${prosa}" ]; then
	ok "prosa:  OK, ningun texto de los tres guiones cita la duracion a mano; los mensajes se derivan del numero"
else
	mal "prosa:  FALLA, textos con la duracion escrita:${prosa}; un mensaje que miente sobre el margen es peor que ninguno"
fi

# ---- Y NADIE PISA EL VALOR DESPUES DE SOURCEARLO ----
# Sourcear y asignar una linea despues pasaba las seis filas: la de `source`
# mira que exista la ORDEN, la de `literal` mira el `checkend`, y ninguna miraba
# el VALOR con que el guion decide. La ventana muerta que este fichero existe
# para cerrar se podia reabrir sin poner nada rojo. Lo trajo un lector.
pisan=""
for g in ${USUARIOS}; do
	a=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?CERT_MARGEN_SEG=' "${RAIZ_REPO}/gate/${g}" 2>/dev/null || true)
	case "${a}" in ''|*[!0-9]*) a=0 ;; esac
	[ "${a}" -gt 0 ] && pisan="${pisan} ${g}(${a})"
done
if [ -z "${pisan}" ]; then
	ok "pisa:   OK, ningun guion asigna CERT_MARGEN_SEG por su cuenta; el valor con que deciden es el del fichero"
else
	mal "pisa:   FALLA, asignan el margen despues de sourcearlo:${pisan}; sourcear y pisar reabre la ventana muerta"
fi

# ---- ANTI-VACUIDAD de las dos filas de arriba ----
# Sin esto, un cambio en el nombre de un guion dejaria el bucle sin visitar nada
# y las dos filas dirian OK sobre un conjunto vacio.
vistos=0
for g in ${USUARIOS}; do
	[ -f "${RAIZ_REPO}/gate/${g}" ] && vistos=$((vistos + 1))
done
if [ "${vistos}" -eq 3 ]; then
	ok "censo:  OK, los tres guiones existen y se visitaron los tres"
else
	mal "censo:  FALLA, de los tres guiones solo existen ${vistos}; las filas de arriba certifican sobre un conjunto que no recorrieron"
fi

# ---- EL PREDICADO, DISPARADO POR LOS DOS LADOS ----
# LA PRIMERA VERSION DE ESTA FILA HABRIA SIDO ROJA EN CI, y lo trajo un lector
# que la corrio dentro de ubuntu:24.04. Acunaba el certificado corto con
# `openssl req -x509 -not_after`, que existe en el OpenSSL 3.6 de esta maquina y
# NO en el 3.0.13 de ese corredor ni en LibreSSL 3.3.6, que es el /usr/bin/openssl
# de este mismo Mac. El banco se moria despues de la fila `censo`, sin resumen y
# sin una palabra, y el paso de CI habria salido rojo desde el primer empujon.
#
# LA FORMA PORTATIL usa solo `-days`, que lleva OpenSSL desde siempre: un
# certificado de UN DIA, mirado con dos margenes distintos. Con el margen de la
# casa pasa, y con el margen mas un dia no pasa. Eso es lo que la fila tiene que
# demostrar, que el predicado DISCRIMINA y no dice que si a todo.
#
# LO QUE ESTA FORMA NO EJERCE, y va declarado en vez de disimulado: no acuna un
# certificado mas corto que el margen, porque hacerlo portatil no se puede con
# `-days`, cuya unidad es el dia. La aritmetica es la misma y la conclusion
# tambien; lo que se pierde es la fixture literal.
MARGEN_LARGO=$(( CERT_MARGEN_SEG + 86400 ))
openssl req -x509 -newkey rsa:2048 -keyout "${CAJON}/k.pem" -out "${CAJON}/un-dia.pem" \
	-nodes -subj "/CN=margen" -days 1 >/dev/null 2>&1 || true
if [ ! -s "${CAJON}/un-dia.pem" ]; then
	echo "test: VACIO. No se pudo acunar el certificado de prueba con openssl req -x509 -days 1" >&2
	echo "test: sin fixture, la fila del limite no mediria nada y saldria verde por vacuidad" >&2
	exit 1
fi
corto_rc=0; openssl x509 -in "${CAJON}/un-dia.pem" -noout -checkend "${MARGEN_LARGO}" >/dev/null 2>&1 || corto_rc=$?
largo_rc=0; openssl x509 -in "${CAJON}/un-dia.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1 || largo_rc=$?
if [ "${corto_rc}" -ne 0 ] && [ "${largo_rc}" -eq 0 ]; then
	ok "limite: OK, un certificado de un dia PASA el margen de ${CERT_MARGEN_SEG}s y NO pasa el de ${MARGEN_LARGO}s: el predicado discrimina"
else
	mal "limite: FALLA, con margen ${MARGEN_LARGO}s rc=${corto_rc} y con ${CERT_MARGEN_SEG}s rc=${largo_rc}; el margen no separa los dos lados"
fi

# ---- SIN EL FICHERO, LOS TRES SE NIEGAN ----
# LA PRIMERA VERSION PROBABA UNO Y SU TITULO DECIA TRES, y ademas lo invocaba con
# `sh`, cuando los tres guiones son de bash y llevan `set -o pipefail`: en un
# corredor de Linux, donde `sh` es dash, eso muere en la linea 7 con "Illegal
# option -o pipefail" y devuelve 2 por casualidad, que es justo el codigo que la
# fila esperaba. Verde por el motivo equivocado, y rojo en cuanto se mirase el
# texto. Ahora se recorre la lista y se invoca cada guion por su propio shebang.
faltan_cerrados=""
for g in ${USUARIOS}; do
	COPIA="${CAJON}/repo-${g}"
	mkdir -p "${COPIA}/gate"
	cp "${RAIZ_REPO}/gate/${g}" "${COPIA}/gate/${g}"
	chmod +x "${COPIA}/gate/${g}"
	sin_rc=0
	"${COPIA}/gate/${g}" > "${CAJON}/sin-${g}.out" 2>&1 || sin_rc=$?
	if [ "${sin_rc}" -ne 2 ] || ! grep -q 'cert-margen.sh' "${CAJON}/sin-${g}.out"; then
		faltan_cerrados="${faltan_cerrados} ${g}(rc=${sin_rc})"
	fi
done
if [ -z "${faltan_cerrados}" ]; then
	ok "ausente: OK, sin el fichero del margen los TRES guiones salen con 2 nombrandolo, en vez de seguir con un valor supuesto"
else
	mal "ausente: FALLA, no se niegan bien:${faltan_cerrados}; sin margen no hay comprobacion y suponer uno seria inventarlo"
fi

n_filas=$(grep -c . "${REGISTRO}" || true)
n_falla=$(grep -c '^FALLA$' "${REGISTRO}" || true)
COMPLETO=1
echo "RESULTADO: ${n_filas} filas, ${n_falla} en FALLA"
if [ "${n_filas}" -eq 0 ]; then
	echo "test: VACIO. El registro de filas salio a cero, asi que este banco no ha probado nada" >&2
	exit 1
fi
if [ "${n_falla}" -ne "${fallos}" ]; then
	echo "test: el registro cuenta ${n_falla} fallas y el acumulador ${fallos}; las dos cuentas tienen que casar" >&2
	exit 1
fi
[ "${fallos}" -eq 0 ] || { echo "test: ${fallos} fallo(s)" >&2; exit 1; }
echo "test: el margen vive en un solo sitio, los tres guiones que lo miran lo sourcean, discrimina por los dos lados, y sin el fichero se niegan en vez de suponerlo"
