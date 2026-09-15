#!/usr/bin/env bash
# p2-iron-test.sh: the bench for the iron path of gate/p2.sh.
#
# It fires the predicates the iron cut turns on, from BOTH sides: the shape that
# is in the tree today, and a mutant that rewinds each decision to what it was
# before 2026-09-07. A row that only passes on the good shape proves nothing; the
# pair is what says the decision lives in code and not in prose.
#
# THE DANGEROUS OBJECT HERE IS THE STUB ssh, and it is built so it cannot
# fabricate. It answers only for the documentation-range fleet (RFC 5737) that
# this file sets, only under NAYLAMP_RED_ARM=1, and it runs the remote commands
# for real inside fake home directories. gate/common.sh already refuses a
# documentation address unless NAYLAMP_RED_ARM is set, so a real gate that found
# this stub in front of the real ssh would die at its first probe.
#
# The workspace is gate/out/banco-iron-p2, a literal path, rebuilt from zero every
# run and removed when the rows are green. It is swept by make clean either way,
# and that is true because of the name: see the block beside the definition.
set -uo pipefail

# QUIEN ES ESTE BANCO, dicho en su PRIMERA linea de salida y en una forma que no
# es prosa. Entra el 8 de septiembre de 2026. El barrido que revisa el archivo de
# corridas/ clasificaba cada captura buscando por el CUERPO el texto de alguna de
# sus filas, y eso tiene dos agujeros medidos: el texto de una fila se reescribe,
# y entonces las capturas de ese banco dejan de existir para el barrido sin que
# nadie lo note; y un informe ESCRITO que cita unas filas se cuenta como corrida,
# que es como cuatro analisis del archivo acabaron contados como capturas. Una
# cita vive siempre por el medio de un fichero, nunca en su primera linea, asi que
# esta linea distingue una corrida de una cita a una corrida.
echo "BANCO: p2-iron-test"

. "$(dirname "${BASH_SOURCE[0]}")/entorno.sh"

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# EL TALLER NO SE LLAMA p2-ALGO, y el nombre viejo, gate/out/p2-iron-test, era un
# defecto medido por un lector. La guarda de `make clean` refuse por FORMA,
# `p[0-9]-* ! p[0-9]-local-*`, asi que aquel nombre casaba: mientras el banco
# corria, un `make clean` en otra terminal se negaba, y un banco matado dejaba un
# directorio que la guarda protege y que nada puede sellar. La cabecera de este
# fichero decia "It is swept by make clean either way", que era FALSO con ese
# nombre y es cierto con este. El dia que este banco entra en CI, o sea hoy, eso
# deja de ser una molestia de esta maquina.
BANCO="${GATE_DIR}/out/banco-iron-p2"

FALLAS=0
ROJAS=0
FILAS=0
# LA BANDERA DE TERMINACION, y entra el 8 de septiembre de 2026 con este banco: el
# dia que pasa a correr en CI. Una trampa EXIT se come el estado de salida cuando
# el guion muere a mitad, asi que un banco abortado se lee como un paso verde. Este
# tenia la trampa y no la bandera, o sea justo la mitad que hace falta para que el
# fallo sea silencioso.
#
# LA CUENTA VA RE-DERIVADA Y NO RECITADA, porque la primera version de este
# comentario decia "los otros tres bancos" y "un cuarto sitio", y las dos cifras
# eran falsas; las cazo un lector contando. En gate/ hay OCHO bancos y SIETE ya
# llevaban la bandera: este era el unico sin ella. Y en ci.yml ya corren CUATRO
# pasos de banco, no tres, asi que este es el QUINTO. La orden que lo re-deriva es
# `grep -c "ABORTADO antes del resumen" gate/*-test.sh` fichero a fichero, y
# `grep 'run: ./gate/' .github/workflows/ci.yml` para los pasos.
COMPLETO=0
# UNA FILA PUEDE NO APLICAR EN ESTA MAQUINA, y entonces no se cuenta como fila.
# Es la misma forma que gate/sello-test.sh: contarla como OK seria publicar un pase
# que nadie corrio, y contarla como FALLA pondria roja a CI por la ausencia de algo
# que ese entorno no puede dar. Se declara, se cuenta aparte y se dice el motivo.
OMITIDAS=0
no_aplica() {
	OMITIDAS=$((OMITIDAS + 1))
	printf 'FILA %-4s NO APLICA %s\n' "$1" "$2"
}
fila() {
	local id="$1" quiero="$2" tengo="$3" porque="$4"
	FILAS=$((FILAS + 1))
	if [ "${quiero}" = "${tengo}" ]; then
		printf 'FILA %-4s OK    %s\n' "${id}" "${porque}"
	else
		printf 'FILA %-4s FALLA %s (queria [%s], salio [%s])\n' "${id}" "${porque}" "${quiero}" "${tengo}"
		FALLAS=$((FALLAS + 1))
	fi
}
roja() {
	local id="$1" quiero="$2" tengo="$3" porque="$4"
	ROJAS=$((ROJAS + 1))
	fila "${id}" "${quiero}" "${tengo}" "ROJA ${porque}"
}

# EL NOMBRE DE ESTA FUNCION NO ES CASUAL Y LA TRAMPA SE REGISTRA DESPUES DE
# CARGAR p2.sh. La primera version la llamo al_salir, que es exactamente el
# nombre que gate/p2.sh da a la suya, asi que al cargarlo la definicion de p2.sh
# PISABA la de este banco y la trampa acababa llamando a la de p2.sh: el banco no
# se barria, su directorio quedaba en gate/out, y el artefacto con nombre de
# fierro que las filas 13 a 17 crean quedaba tambien, donde `make clean` se niega
# a tocarlo por no llevar sello. Cuatro de ellos quedaron antes de que la
# limpieza medida del cierre los encontrara. Un banco que ensucia lo que el gate
# protege es peor que uno que falla.
barre_el_banco() {
	local rc=$?
	set +e
	# El artefacto con nombre de fierro que este banco crea se retira SIEMPRE, con
	# su ruta literal y el run id dentro, falle o no: si se quedara, `make clean`
	# se negaria a barrer gate/out entero hasta que alguien lo sellara a mano.
	# LA TRAMPA MIRA ARTEFACTO_REAL Y NO OUT_LOCAL, y esto es una correccion del 8 de
	# septiembre de 2026 que trajo un lector matando el banco a proposito. Las filas
	# del sello MUEVEN OUT_LOCAL, OUT_DIR y RUN_ID a talleres de mentira para montar
	# sus casos, y los devuelven a mano al terminar. Un `exit` dentro de una de esas
	# ventanas dejaba a la trampa comparando la ruta de mentira contra la de verdad:
	# la guarda no casaba, se imprimia "NO retiro" nombrando la ruta EQUIVOCADA, y el
	# artefacto de fierro de verdad se quedaba en gate/out con su SEALED dentro y sin
	# linea `closed:`. O sea un artefacto FABRICADO que se lee como una corrida de
	# fierro matada, y que `make clean` no barre nunca por llevar sello. Medido: el
	# banco muerto a mitad del bloque 17n-17q dejaba
	# gate/out/p2-<run id>/{RUNNING,hygiene.log,SEALED}.
	#
	# ARTEFACTO_REAL se fija UNA vez, justo despues de cargar p2.sh, y ninguna fila
	# lo toca. La guarda de forma se queda, porque lo que justifica un `rm -rf` no es
	# de donde salio la variable sino que la ruta se haya comprobado antes de usarla.
	if [ -n "${ARTEFACTO_REAL:-}" ] && [ "${ARTEFACTO_REAL}" = "${GATE_DIR}/out/$(basename "${ARTEFACTO_REAL}")" ] \
		&& [ "$(basename "${ARTEFACTO_REAL}" | cut -c1-3)" = "p2-" ]; then
		rm -rf -- "${GATE_DIR}/out/$(basename "${ARTEFACTO_REAL}")"
	elif [ -n "${ARTEFACTO_REAL:-}" ]; then
		echo "p2-iron-test: NO retiro ${ARTEFACTO_REAL}: no es la ruta que este banco sabe borrar" >&2
	fi
	# Y LOS TALLERES DE MENTIRA VIVEN DENTRO DEL BANCO, asi que se van con el; pero
	# antes hay que devolver el permiso de escritura, porque la fila 17p pone un
	# directorio en modo 500 y un banco muerto entre el chmod y su vuelta deja un
	# arbol que ni `rm -rf` ni `make clean` pueden retirar. Medido por un lector.
	[ -d "${BANCO}" ] && chmod -R u+w "${BANCO}" 2>/dev/null
	if [ "${COMPLETO}" -ne 1 ]; then
		echo "p2-iron-test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2
		echo "p2-iron-test: el banco queda en gate/out/banco-iron-p2" >&2
		exit 1
	fi
	if [ "${rc}" -eq 0 ] && [ "${FALLAS}" -eq 0 ]; then
		cd "${GATE_DIR}/out" && rm -rf banco-iron-p2
		echo "p2-iron-test: todas las filas verdes; el banco y su artefacto se barren"
	else
		echo "p2-iron-test: ${FALLAS} filas en FALLA o un aborto; el banco queda en gate/out/banco-iron-p2" >&2
	fi
}

[ -d "${BANCO}" ] && { cd "${GATE_DIR}/out" && rm -rf banco-iron-p2; }
mkdir -p "${BANCO}/bin" "${BANCO}/casa" "${BANCO}/estado"
: > "${BANCO}/llave"
chmod 600 "${BANCO}/llave"

# ---- el stub de ssh y scp -----------------------------------------------------
#
# Cada host de mentira tiene su propia casa. El stub traduce la direccion a la
# casa y corre la orden ahi dentro, de verdad. Un host marcado "muerto" no
# contesta y sale con 255, que es lo que hace ssh cuando el transporte cae, y es
# el caso que separa NO de NO-SE-PUDO-LEER.
cat > "${BANCO}/bin/ssh" <<'SSHFIN'
#!/usr/bin/env bash
if [ "${NAYLAMP_RED_ARM:-}" != 1 ]; then
	echo "p2-iron-test stub ssh: refusing to answer without NAYLAMP_RED_ARM=1" >&2
	exit 255
fi
destino=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o|-i) shift 2 ;;
		-q|-r) shift ;;
		*) destino="$1"; shift; break ;;
	esac
done
host="${destino#*@}"
case "${host}" in
	192.0.2.1) n=1 ;;
	192.0.2.2) n=2 ;;
	192.0.2.3) n=3 ;;
	*) echo "stub ssh: unknown host ${host}" >&2; exit 255 ;;
esac
casa="${BANCO_CASA}/${n}"
[ -f "${BANCO_ESTADO}/${n}.muerto" ] && exit 255
cd "${casa}" || exit 255
# Las rutas absolutas del kernel se reescriben a la casa de mentira: es la unica
# forma de que las primitivas se prueben TAL COMO ESTAN ESCRITAS, leyendo
# /proc/sys/kernel/..., en vez de con una version del guion adaptada al banco.
orden="$*"
orden="${orden//\/proc\//${casa}/proc/}"
# UN NODO PUEDE FALLAR SOLO AL ARMAR, y hace falta poder pedirlo. La siembra del
# testigo y su armado son dos viajes distintos y el gate los trata distinto: sin
# siembra la fase se va antes de nada, y sin armado se anota el nodo y se sigue.
# Para ejercer el segundo camino hay que negar el armado DEJANDO pasar la siembra,
# y por eso no vale con romper el fichero: eso rompe la siembra primero. El armado
# es el unico viaje que hace un `>>` sobre el testigo; la siembra usa python con
# O_TRUNC. Se casa esa forma y no una longitud, que cambiaria el dia que alguien
# mueva TESTIGO_COLA.
if [ -f "${BANCO_ESTADO}/${n}.no-arma" ]; then
	case "${orden}" in *">> naylamp/testigo-corte.bin"*) exit 1 ;; esac
fi
bash -c "${orden}"
SSHFIN
chmod +x "${BANCO}/bin/ssh"

cat > "${BANCO}/bin/scp" <<'SCPFIN'
#!/usr/bin/env bash
if [ "${NAYLAMP_RED_ARM:-}" != 1 ]; then
	echo "p2-iron-test stub scp: refusing without NAYLAMP_RED_ARM=1" >&2
	exit 255
fi
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|-i) shift 2 ;;
		-q|-r) shift ;;
		*) args+=("$1"); shift ;;
	esac
done
origen="${args[0]}"; destino="${args[1]}"
traduce() {
	local p="$1" h n
	case "${p}" in
		*@*:*) h="${p#*@}"; h="${h%%:*}"
		       case "${h}" in
		           192.0.2.1) n=1 ;; 192.0.2.2) n=2 ;; 192.0.2.3) n=3 ;;
		           *) echo "" ; return 1 ;;
		       esac
		       printf '%s/%s/%s' "${BANCO_CASA}" "${n}" "${p#*:}" ;;
		*) printf '%s' "${p}" ;;
	esac
}
o="$(traduce "${origen}")" || exit 255
d="$(traduce "${destino}")" || exit 255
mkdir -p "$(dirname "${d}")" 2>/dev/null
cp -R "${o}" "${d}" 2>/dev/null
SCPFIN
chmod +x "${BANCO}/bin/scp"

for n in 1 2 3; do
	mkdir -p "${BANCO}/casa/${n}/naylamp/data" "${BANCO}/casa/${n}/naylamp/logs" "${BANCO}/casa/${n}/naylamp/bin"
	# Las dos lecturas del kernel van por su ruta ABSOLUTA, asi que la casa de
	# mentira las monta bajo su propio prefijo y el stub reescribe /proc dentro.
	mkdir -p "${BANCO}/casa/${n}/proc/sys/kernel/random"
	printf '176\n' > "${BANCO}/casa/${n}/proc/sys/kernel/sysrq"
	printf 'aaaa-bbbb-cccc-000%s\n' "${n}" > "${BANCO}/casa/${n}/proc/sys/kernel/random/boot_id"
	printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/${n}/naylamp/bin/naylampd"
done

export BANCO_CASA="${BANCO}/casa"
export BANCO_ESTADO="${BANCO}/estado"
export PATH="${BANCO}/bin:${PATH}"
export NAYLAMP_RED_ARM=1
export NAYLAMP_GATE_HOSTS=192.0.2.1,192.0.2.2,192.0.2.3
export NAYLAMP_GATE_PRIVATE=198.51.100.1,198.51.100.2,198.51.100.3
export NAYLAMP_GATE_KEY="${BANCO}/llave"
export NAYLAMP_GATE_USER=nadie
export NAYLAMP_P2_SOURCE_ONLY=1

echo "=============================================================================="
echo "BANCO DEL CAMINO DE FIERRO DE gate/p2.sh"
echo "fecha: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "flota de mentira: ${NAYLAMP_GATE_HOSTS} (RFC 5737), stub ssh bajo NAYLAMP_RED_ARM=1"
echo "=============================================================================="
echo

# shellcheck source=p2.sh
source "${GATE_DIR}/p2.sh" >/dev/null 2>&1
# Solo AHORA, con p2.sh ya cargado y sus nombres en su sitio, se arma la trampa.
# El artefacto de fierro de ESTA corrida, capturado antes de que ninguna fila
# pueda mover OUT_LOCAL. Es lo unico que la trampa borra bajo gate/out.
ARTEFACTO_REAL="${OUT_LOCAL}"
trap barre_el_banco EXIT
echo "-- cargado en modo fierro: ES_FIERRO=${ES_FIERRO}, artefacto $(basename "${ARTEFACTO_REAL}") --"
echo

# ---- 1 a 5: la lectura de sysrq, que no es una mascara plana -------------------
fila 1  "si" "$(sysrq_permite_reinicio 176 && echo si || echo no)" "sysrq=176, el valor real de naylamp-1, permite el reinicio"
fila 2  "si" "$(sysrq_permite_reinicio 1   && echo si || echo no)" "sysrq=1 habilita todas las funciones"
roja 3  "no" "$(sysrq_permite_reinicio 0   && echo si || echo no)" "sysrq=0 NO permite: el corte seria un no-op y todo verde de abajo mentiria"
roja 4  "no" "$(sysrq_permite_reinicio 16  && echo si || echo no)" "sysrq=16 es una mascara SIN el bit 128, y leerla como bitmask plano la daria por buena"
roja 5  "no" "$(sysrq_permite_reinicio 'cat: /proc/sys/kernel/sysrq: Permission denied' && echo si || echo no)" "una respuesta que no es un numero NO es un permiso"

# ---- 6 a 8: lineas_listening devuelve UNA linea, siempre ----------------------
FLEET="${BANCO}/flota"; mkdir -p "${FLEET}"
printf 'arranca\nnada aqui\n' > "${FLEET}/node1.log"
printf 'arranca\nlistening on x\n' > "${FLEET}/node2.log"
# El predicado es "el valor NO lleva un salto de linea dentro". Contar con wc -l
# sobre una salida sin salto final da 0 y no 1, y la primera version de estas
# filas lo escribio asi: un predicado que no mide lo que su texto dice, dentro
# del banco escrito para cazar justo eso.
saltos_en() { printf '%s' "$1" | tr -cd '\n' | wc -c | tr -d ' '; }
fila 6 "0" "$(saltos_en "$(lineas_listening 1)")" "log que existe SIN la linea: CERO saltos dentro del valor (el defecto metia uno)"
fila 7 "0" "$(lineas_listening 1)" "y su valor es 0"
fila 8 "1" "$(lineas_listening 2)" "log con la linea: 1"
fila 9 "0" "$(lineas_listening 9)" "log que no existe: 0"
fila 10 "1" "$( set +e; [ "$(lineas_listening 1)" -gt 0 ] >/dev/null 2>&1; echo $? )" "la comparacion devuelve 1, que es FALSO; antes devolvia 2, que es un error de sintaxis disfrazado de falso"

# ---- 11 y 12: entry_log_bytes tiene un tercer resultado, ILEGIBLE -------------
mkdir -p "${FLEET}/node1/data"
head -c 100 /dev/zero > "${FLEET}/node1/data/raft-1.log"
head -c 50  /dev/zero > "${FLEET}/node1/data/raft-2.log"
fila 11 "150" "$(entry_log_bytes 1)" "suma los segmentos legibles"
# El fichero ilegible se monta con un enlace simbolico CIRCULAR y no con chmod
# 000: la primera version usaba chmod y las filas 12 y 33 salian verdes por la
# razon equivocada, porque stat lee METADATOS y no contenido, asi que un fichero
# sin permisos de lectura sigue dando su tamano. Un bucle de enlaces hace fallar
# a stat de verdad, que es lo que estas filas quieren.
mkdir -p "${FLEET}/node2/data"
ln -sf "raft-1.log" "${FLEET}/node2/data/raft-1.log"
roja 12 "2" "$( entry_log_bytes 2 >/dev/null 2>&1; echo $? )" "un segmento que stat no puede leer devuelve 2, y no un total corto en silencio"

# ---- 13 y 14: el artefacto de fierro se llama p2-, que es lo que make clean protege
fila 13 "p2" "$(basename "${OUT_LOCAL}" | cut -d- -f1)" "en fierro el artefacto es p2-<run id>, o sea el que la guarda del Makefile exige sellado"
fila 14 "1" "$(printf '%s' "$(basename "${OUT_LOCAL}")" | grep -c '^p2-[0-9]')" "y NO p2-local-, que es el que make clean barre sin preguntar"

# ---- 15 a 17: el marcador RUNNING conoce el nombre de fierro ------------------
mkdir -p "${OUT_LOCAL}"
escribe_running
fila 15 "1" "$(grep -c "^run: $(basename "${OUT_LOCAL}")\$" "${OUT_LOCAL}/RUNNING")" "el marcador lleva dentro el nombre de fierro"
retira_running
fila 16 "0" "$( [ -f "${OUT_LOCAL}/RUNNING" ] && echo 1 || echo 0 )" "y la retirada lo encuentra por su literal de fierro"
escribe_running
GUARDA_OUT="${OUT_LOCAL}"
OUT_LOCAL="${GATE_DIR}/out/p2-un-tercer-nombre"
roja 17 "1" "$(retira_running 2>&1 | grep -c 'NOT removed')" "y con un tercer nombre se niega EN VOZ ALTA en vez de callarse"
OUT_LOCAL="${GUARDA_OUT}"
rm -f -- "${OUT_LOCAL}/RUNNING"

# ---- 17a a 17u: EL SELLO DEL ARTEFACTO DE FIERRO, DEFER-098 -------------------
#
# POR QUE ESTAS FILAS VIVEN AQUI Y NO EN gate/p2-guard-test.sh. Aquel banco corre
# el ENSAYO, y el ensayo no sella nunca: seal_artifact devuelve en su primera
# linea con ES_FIERRO distinto de 1, que es deliberado, porque un p2-local- lo
# barre un make clean cualquiera y un sello dentro seria la marca de evidencia
# puesta sobre lo que no lo es. Un banco que no puede ver el objeto no lo prueba,
# y este fichero ya lleva escrita esa leccion mas arriba. Aqui p2.sh esta cargado
# en modo fierro, asi que el objeto existe: OUT_LOCAL es un p2-<run id> de verdad.
#
# Y SE DISPARAN POR LOS DOS LADOS, que es lo que este banco dice de si mismo en su
# primera linea. Cada decision del sello se mide en su forma de hoy y en la forma
# que tendria sin ella, porque una fila que solo pasa sobre la forma buena no
# separa "la decision esta en el codigo" de "la decision esta en la prosa".
RUN_STARTED=1
SUBCOMANDO=all
ARRANCO_A="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
EXPECTED="P2.build P2.hygiene"
VERDICTS=" P2.build=pass "

# El barrido devuelve la cuenta de los que visito pegada a la lista de los que no
# llevan sello, asi que la pregunta "me nombra a MI" se hace por el nombre y no
# por la cuenta: otro p2-<run id> en gate/out moveria la cuenta y no dice nada
# sobre este artefacto.
esta_en_el_barrido() {
	case " $(artefactos_de_fierro_sin_sello) " in
		*" $(basename "${OUT_LOCAL}") "*) printf 'si' ;;
		*) printf 'no' ;;
	esac
}
# Cuenta las palabras de una linea del sello. grep -c sale con 1 cuando cuenta
# cero, que aqui es un valor y no un error, y por eso se lee el texto y nunca el
# estado de salida.
palabras_de() { sed -n "s/^$1:  *//p" "${OUT_LOCAL}/SEALED" | tr ' ' '\n' | grep -c . ; }

# EL ESTADO DE LA 17a SE MONTA AQUI Y NO SE HEREDA, y un lector midio lo que
# costaba: la fila exige que el artefacto tenga SOLO el marcador dentro, y ese
# estado lo dejaban las filas 15 a 17, no ella. Un fichero de mas en cualquier fila
# anterior y la 17a se invierte sin que nadie lo note. Ahora lo rehace desde cero.
rm -rf -- "${OUT_LOCAL}"
mkdir -p "${OUT_LOCAL}"
escribe_running
seal_artifact
roja 17a "no|no" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(esta_en_el_barrido)" "con solo el marcador dentro NO se sella y el barrido NO lo nombra: es la excepcion del vacio, y seal_artifact, el barrido y la guarda del Makefile la preguntan igual"

printf 'lo que esta corrida escribio\n' > "${OUT_LOCAL}/hygiene.log"
roja 17b "no|si" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(esta_en_el_barrido)" "con contenido y sin sello el barrido LO NOMBRA, y esa es la linea que pone roja a P2.hygiene y la que make clean convierte en una negativa"

seal_artifact
ESPERADA_ANTES="$(grep -m1 '^expected:' "${OUT_LOCAL}/SEALED")"
fila 17c "si|no" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(esta_en_el_barrido)" "y en cuanto el sello esta escrito, el barrido deja de nombrarlo: es la linea del barrido que salta un artefacto sellado. El ORDEN de las dos operaciones no lo mide esta fila, lo mide la 17k, y decir aqui que si era describirse de mas"

roja 17d "0|1|2" "$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")|$(palabras_de verdicts)|$(palabras_de expected)" "el sello a medias no lleva closed y trae MENOS veredictos que esperados, que es la forma que una corrida matada y una completa compartian en gate/p1.sh hasta el 8 de septiembre de 2026"

# La corrida llega a su final: la higiene emite el veredicto que faltaba y la
# trampa termina el sello. Es la secuencia de al_salir, sin la trampa.
record_verdict P2.hygiene pass
completa_el_sello
fila 17e "1|2|2" "$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")|$(palabras_de verdicts)|$(palabras_de expected)" "terminado, lleva UNA linea closed y tantos veredictos como esperados: una corrida completa y una matada dejan de tener la misma forma"
fila 17f "${ESPERADA_ANTES}" "$(grep -m1 '^expected:' "${OUT_LOCAL}/SEALED")" "la linea expected sale identica byte a byte, que es por la que dos sellos se comparan. Lo que esta fila mide es el brazo VERBATIM del bucle, no la guarda que compara: quitando esa guarda entera el banco sigue verde, medido, y por que no se puede alcanzar desde fuera va escrito en el bloque de la 17n"

completa_el_sello
fila 17g "1|1" "$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")|$(grep -c '^verdicts:' "${OUT_LOCAL}/SEALED")" "dos pasadas dejan UNA sola closed y UNA sola verdicts: terminar un sello ya terminado no lo duplica"
fila 17h "0" "$(ls -1 "${OUT_LOCAL}" | grep -c '^SEALED\.a-medias$')" "y no sobrevive ningun SEALED.a-medias dentro de un artefacto que el sello protege de make clean"

# LA 17i TIENE DOS MITADES Y LA PRIMERA VERSION SOLO TENIA UNA, que es un hallazgo
# de lector: medida solo por el eco, un p2.sh al que se le quitara la linea de la
# bandera y se le dejara el eco gritaria "THIS run did not write it" en CADA segunda
# llamada normal de la corrida, que es el caso corriente, y la fila seguia verde. La
# mitad que faltaba es esa: con la bandera puesta, la segunda llamada es SILENCIOSA.
roja 17i "0|1|1" "$(seal_artifact 2>&1 | grep -c 'did not write it')|$( SELLO_ESCRITO_AQUI=0; seal_artifact 2>&1 | grep -c 'did not write it')|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")" "con la bandera puesta la segunda llamada de la corrida NO dice nada, y sin ella un sello que esta corrida no escribio se dice en voz alta y no se toca: la bandera de la clausula 30, y aqui basta una porque ningun subcomando de este guion adopta el id de otra corrida"

# 17u: UN SELLO QUE NO SE PUDO ESCRIBIR NO SE ANUNCIA COMO ESCRITO, y esta fila
#      entra con la guarda que la hace posible. Medido en el bash 3.2 de esta
#      maquina: un grupo `{ ...; } > fichero` cuyo destino no se puede crear imprime
#      su error, devuelve 1 y NO dispara `set -e`, asi que la bandera se ponia a 1 y
#      la consola decia "sealed the artifact" sin que existiera fichero. La fila
#      exige las tres cosas: no hay sello, la bandera sigue en cero, y se dice.
GUARDA_OUT="${OUT_LOCAL}"
OUT_LOCAL="${BANCO}/artefacto-sin-permiso"
rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'contenido\n' > "${OUT_LOCAL}/manifest.txt"
GUARDA_RUNID2="${RUN_ID}"; RUN_ID="$(basename "${GUARDA_OUT}" | sed 's/^p2-//')"
mv -- "${OUT_LOCAL}" "${BANCO}/p2-${RUN_ID}"; OUT_LOCAL="${BANCO}/p2-${RUN_ID}"
chmod 500 "${OUT_LOCAL}"
SELLO_ESCRITO_AQUI=0
if ( : > "${OUT_LOCAL}/.sonda-17u" ) 2>/dev/null; then
	rm -f -- "${OUT_LOCAL}/.sonda-17u"
	chmod 700 "${OUT_LOCAL}"
	no_aplica 17u "el modo 500 no deniega la escritura en este entorno, probablemente root"
else
	SALIDA_17U="$(seal_artifact 2>&1)"
	chmod 700 "${OUT_LOCAL}"
	roja 17u "no|0|1" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|${SELLO_ESCRITO_AQUI}|$(printf '%s' "${SALIDA_17U}" | grep -c 'could NOT be written')" "un sello que no se pudo escribir no deja bandera puesta ni anuncia que se sello: sin esa comprobacion la redireccion falla en silencio y la corrida cierra diciendo que sello algo que no existe"
fi
rm -rf -- "${OUT_LOCAL}"
RUN_ID="${GUARDA_RUNID2}"
OUT_LOCAL="${GUARDA_OUT}"
SELLO_ESCRITO_AQUI=1

GUARDA_OUT="${OUT_LOCAL}"
OUT_LOCAL="${BANCO}/p2-un-cuarto-nombre"
mkdir -p "${OUT_LOCAL}"
printf 'expected:    P2.build\nverdicts:    P2.build=pass\n' > "${OUT_LOCAL}/SEALED"
roja 17j "1|0" "$(completa_el_sello 2>&1 | grep -c 'is not p2-')|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")" "y bajo un nombre que no es p2-<run id> se niega EN VOZ ALTA y no lo termina, en vez de escribir un closed dentro de un fichero que no sabe de quien es"
OUT_LOCAL="${GUARDA_OUT}"

# ---- 17k y 17l: EL ORDEN, medido por su efecto y no por su texto -------------
#
# Las filas de arriba llaman a seal_artifact y al barrido por separado, asi que
# seguirian verdes con las dos lineas cambiadas de sitio dentro de
# veredicto_del_sello. Estas dos llaman a la funcion entera, que es donde el orden
# vive: sellar primero y barrer despues es lo que hace que el barrido incluya el
# sello que la corrida acaba de escribir. Con las dos lineas al reves, el barrido
# nombraria el artefacto y la 17k saldria roja.
rm -f -- "${OUT_LOCAL}/SEALED"
SELLO_ESCRITO_AQUI=0
CHECK_FAILED=0
veredicto_del_sello
fila 17k "sellado|verde" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo sellado || echo sin-sello)|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "veredicto_del_sello sella y DESPUES barre: el artefacto sale sellado y la fase no se pone roja por el"

# Y la otra mitad: una corrida que NO consigue sellarse. Se monta quitandole a
# seal_artifact su precondicion, RUN_STARTED, y no editando el guion: el objeto
# que esta fila mide es el barrido, no la razon por la que no hubo sello.
rm -f -- "${OUT_LOCAL}/SEALED"
SELLO_ESCRITO_AQUI=0
CHECK_FAILED=0
RUN_STARTED=0
veredicto_del_sello
roja 17l "sin-sello|rojo" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo sellado || echo sin-sello)|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "una corrida que no consigue sellarse se pone roja AQUI y AHORA, en la misma invocacion, en vez de que la evidencia se descubra ausente meses despues"
RUN_STARTED=1
CHECK_FAILED=0

# ---- 17m: y las DOS lineas rojas no dicen lo mismo, que es por lo que son dos -
#
# veredicto_del_sello puede ponerse roja por dos causas y tienen remedios
# distintos: que ESTA corrida no consiguiera sellarse, que es un defecto del gate,
# o que en gate/out haya quedado un artefacto de OTRA corrida sin sellar, que se
# arregla sellandolo o barriendolo a mano. Sin esta fila la primera comprobacion
# quedaria implicada por el barrido, porque el barrido tambien nombra el artefacto
# de esta corrida, y una guarda que ninguna fila puede distinguir de otra es
# decoracion. Aqui se separan: con lo propio sellado y algo ajeno sin sello, la
# linea de "this run" NO sale y la del barrido SI.
#
# EL ARTEFACTO AJENO NO SE CREA EN gate/out, y esa es la parte cara de esta fila.
# Un p2-<run id> sin sello ahi arriba haria que `make clean` se negara para siempre
# si este banco muriera antes de retirarlo, y barre_el_banco solo sabe borrar el
# suyo. Se mueve OUT_DIR al taller del banco, que es lo que el barrido lee, asi
# que el directorio de mentira nace y muere dentro de lo que la trampa ya barre.
SELLO_ESCRITO_AQUI=0
seal_artifact
GUARDA_OUTDIR="${OUT_DIR}"
OUT_DIR="${BANCO}/gate-out-de-mentira"
mkdir -p "${OUT_DIR}/p2-20200101T000000Z-1"
printf 'de otra corrida, y sin sello\n' > "${OUT_DIR}/p2-20200101T000000Z-1/manifest.txt"
# LA SALIDA SE RECOGE EN UN FICHERO Y NO EN UNA SUSTITUCION, y la primera version
# usaba `$( )`. Eso corre en un SUBSHELL, asi que el `fail` de dentro no llegaba a
# CHECK_FAILED del padre y la linea que venia detras poniendolo a cero era un
# no-op que se leia como si importara. Un lector lo midio. Con el fichero, el color
# de la fase es legible y la fila puede exigirlo.
CHECK_FAILED=0
veredicto_del_sello 2> "${BANCO}/17m.err"
OUT_DIR="${GUARDA_OUTDIR}"
roja 17m "0|1|rojo" "$(grep -c 'this run wrote an artifact' "${BANCO}/17m.err")|$(grep -c 'p2-20200101T000000Z-1' "${BANCO}/17m.err")|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "con lo propio sellado y un artefacto AJENO sin sello, la linea de ESTA corrida no sale, el barrido nombra al ajeno y la fase se pone roja: es el barrido quien enrojece aqui, y por eso las dos guardas rojas no son la misma"
CHECK_FAILED=0

# ---- 17s: la guarda que NINGUN mutante tumbaba -------------------------------
#
# LA TRAJO UN LECTOR MIDIENDO: borrando entera la linea que dice "this run wrote an
# artifact and did not seal it", el banco seguia con 0 en FALLA. La 17l se pone
# roja igual porque en su montaje el artefacto esta DENTRO de gate/out y lo nombra
# el barrido; la 17m solo comprobaba que la linea NO sale. O sea que esa guarda
# estaba escrita, era la unica que nombra a la corrida en curso, y no la vigilaba
# nadie.
#
# EL UNICO MONTAJE EN QUE SOLO ELLA PUEDE ENROJECER: OUT_DIR en un taller VACIO, y
# el artefacto de la corrida FUERA de ese taller, con contenido y sin sello. Asi el
# barrido no tiene nada que nombrar y lo que quede rojo es esa linea o nada.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"
OUT_DIR="${BANCO}/taller-vacio"; mkdir -p "${OUT_DIR}"
OUT_LOCAL="${BANCO}/artefacto-fuera-del-taller"
rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'lo que la corrida escribio\n' > "${OUT_LOCAL}/manifest.txt"
SELLO_ESCRITO_AQUI=0
CHECK_FAILED=0
veredicto_del_sello 2> "${BANCO}/17s.err"
roja 17s "1|0|rojo" "$(grep -c 'this run wrote an artifact' "${BANCO}/17s.err")|$(grep -c 'with no SEALED file' "${BANCO}/17s.err")|$([ "${CHECK_FAILED}" -eq 0 ] && echo verde || echo rojo)" "con el barrido sin nada que nombrar, la corrida que no consiguio sellar SU artefacto se pone roja por su propia linea: es la unica guarda que habla de la corrida en curso y hasta hoy no la miraba ninguna fila"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"
CHECK_FAILED=0

# ---- 17n a 17p: LAS TRES NEGATIVAS, y por que hacen falta ---------------------
#
# LAS DOCE FILAS DE ARRIBA PASAN TODAS POR EL CAMINO FELIZ, y eso se midio en vez
# de suponerse: quitando entera la condicion que decide si la reescritura se
# publica, las doce seguian verdes. Es la misma medida que gate/sello-test.sh
# tuvo que hacerse sobre p1.sh, y la conclusion es la misma: un banco que solo
# recorre el camino bueno no prueba la guarda, prueba el camino. Estas tres
# fuerzan una negativa por tres rutas distintas y las tres exigen lo mismo, que es
# lo unico que hace util a la negativa: el sello sobrevive BYTE A BYTE, no queda
# ningun resto al lado, y la funcion lo dice en voz alta.
#
# EL TALLER SE MUEVE, y con el OUT_DIR y RUN_ID, porque completa_el_sello solo
# actua sobre ${OUT_DIR}/p2-${RUN_ID} y estas filas necesitan sellos deliberadamente
# rotos. Naciendo dentro del taller del banco, ninguno de ellos puede quedarse en
# gate/out si esto muere a mitad.
#
# LO QUE ESTAS TRES NO ALCANZAN, declarado y no escondido: la mitad de la guarda
# que compara `expected:` byte a byte NO es alcanzable desde fuera de la funcion.
# El bucle copia verbatim toda linea que no sea verdicts: ni closed:, asi que
# ninguna entrada valida puede hacer que esa linea salga distinta. Quien la mide es
# gate/sello-test.sh, que EXTRAE la funcion de p1.sh y la muta; su gemela de aqui
# esta cubierta por la otra mitad de la misma condicion, el recuento de lineas, que
# la fila 17n si alcanza. El dia que esa mitad necesite su propia fila, el sitio es
# un banco de extraccion y no una mutacion desde fuera.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_RUNID="${RUN_ID}"; GUARDA_OUT="${OUT_LOCAL}"
OUT_DIR="${BANCO}/sellos"
RUN_ID="20260908T100000Z-1"
OUT_LOCAL="${OUT_DIR}/p2-${RUN_ID}"
SELLO_ESCRITO_AQUI=1
VERDICTS=" P2.build=pass P2.hygiene=pass "

# siembra_sello <lineas closed que ya trae> [sin-verdicts]
siembra_sello() {
	rm -rf -- "${OUT_LOCAL}"
	mkdir -p "${OUT_LOCAL}"
	{
		echo "Phase 2 iron gate artifact, sealed by gate/p2.sh."
		echo
		echo "expected:    P2.build P2.hygiene"
		[ "${2:-}" = sin-verdicts ] || echo "verdicts:    P2.build=pass"
		local i=0
		while [ "${i}" -lt "$1" ]; do
			echo "closed:      2026-09-08T1${i}:00:00Z"
			i=$((i + 1))
		done
		echo "This file is what keeps make clean from taking the directory."
	} > "${OUT_LOCAL}/SEALED"
	huella_del_sello
}
huella_del_sello() { md5 -q "${OUT_LOCAL}/SEALED" 2>/dev/null || md5sum "${OUT_LOCAL}/SEALED" | cut -d' ' -f1; }
restos_al_lado() { ls -1 "${OUT_LOCAL}" 2>/dev/null | grep -c '^SEALED\.a-medias$' ; }

# 17n: DOS closed dentro. La reescritura tira las dos y pone una, o sea que sale
#      con UNA LINEA MENOS; el recuento la caza y no se publica nada.
ANTES_17N="$(siembra_sello 2)"
SALIDA_17N="$(completa_el_sello 2>&1)"
roja 17n "${ANTES_17N}|0|1" "$(huella_del_sello)|$(restos_al_lado)|$(printf '%s' "${SALIDA_17N}" | grep -c 'did not match the seal it came from')" "una reescritura que PIERDE lineas con expected intacta la caza el recuento: el sello sale identico byte a byte, sin restos y con su aviso"

# 17o: sin linea verdicts no hay nada que reescribir, y callarse dejaria el sello
#      descrito como el de una corrida que no llego a su final.
ANTES_17O="$(siembra_sello 0 sin-verdicts)"
SALIDA_17O="$(completa_el_sello 2>&1)"
roja 17o "${ANTES_17O}|0|1" "$(huella_del_sello)|$(restos_al_lado)|$(printf '%s' "${SALIDA_17O}" | grep -c 'has no verdicts line')" "un sello sin linea de veredictos se deja EXACTAMENTE como esta y se dice, en vez de darse por terminado en silencio"

# 17p: sin permiso de escritura al lado del sello no se puede escribir nada, ni
#      siquiera una nota dentro del propio sello, y la confesion es lo unico que
#      queda. Modo 500: leer y entrar si, crear no.
# 17p PREGUNTA PRIMERO SI EL MODO 500 DENIEGA DE VERDAD, y esa mitad la trajo un
# lector pensando en CI. Como root, y un job con `container:` corre como root, el
# modo 500 NO deniega la escritura: la fila fallaria con una discrepancia de huella
# y ninguna explicacion, o sea roja por el entorno y no por el objeto. Se sondea, y
# si el sondeo escribe, la fila se declara NO APLICA en voz alta en vez de correr
# una comprobacion que no puede fallar. El job de hoy corre como `runner`, asi que
# hoy si aplica; el dia que eso cambie, se sabra por esta linea y no por un rojo.
ANTES_17P="$(siembra_sello 0)"
chmod 500 "${OUT_LOCAL}"
if ( : > "${OUT_LOCAL}/.sonda-17p" ) 2>/dev/null; then
	rm -f -- "${OUT_LOCAL}/.sonda-17p"
	chmod 700 "${OUT_LOCAL}"
	no_aplica 17p "el modo 500 no deniega la escritura en este entorno, probablemente root; una fila que no puede fallar no prueba nada y no se cuenta"
else
	SALIDA_17P="$(completa_el_sello 2>&1)"
	chmod 700 "${OUT_LOCAL}"
	roja 17p "${ANTES_17P}|0|1" "$(huella_del_sello)|$(restos_al_lado)|$(printf '%s' "${SALIDA_17P}" | grep -c 'nothing could be written beside it')" "sin permiso de escritura al lado, el sello sale intacto, sin restos, y la funcion confiesa que ese sello va a parecer el de una version que no terminaba sus sellos"
fi

# 17t: LA ULTIMA LINEA SIN SALTO. El bucle de completa_el_sello lleva un
#      `|| [ -n "${linea}" ]` cuya ausencia no la vigilaba nadie, medido por un
#      lector. Sin el, `read` devuelve falso en una ultima linea que no termina en
#      salto y el bucle la TIRA; y el `closed:` que se anade compensa exactamente el
#      uno que se pierde, asi que el recuento de lineas da el visto bueno y el sello
#      se publica con una linea de menos. Hoy los sellos los escribe seal_artifact
#      con `echo`, pero el Makefile invita a escribir uno a mano y la guarda que
#      tendria que frenarlo es justo la que se deja enganar.
rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'Phase 2 iron gate artifact, sealed by gate/p2.sh.\nexpected:    P2.build P2.hygiene\nverdicts:    P2.build=pass\nla ultima linea, y va SIN salto' > "${OUT_LOCAL}/SEALED"
completa_el_sello >/dev/null 2>&1
roja 17t "1|1" "$(grep -c 'la ultima linea, y va SIN salto' "${OUT_LOCAL}/SEALED")|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED")" "la ultima linea sin salto sobrevive a la reescritura: sin esa mitad de la condicion del bucle se pierde, y el closed que se anade tapa la perdida en el recuento"

# 17q: LA BANDERA DE LA CLAUSULA 30, sola, y es la fila que mas pesa de las
#      diecisiete. La 17i mide la mitad que vive en seal_artifact, que se NIEGA a
#      escribir sobre un sello ajeno; esta mide la de completa_el_sello, que se
#      niega a TERMINARLO. Hizo falta porque el barrido de mutantes lo midio: con
#      esa guarda quitada entera, NINGUNA fila caia. Es la unica que separa
#      terminar TU sello de ponerle un closed al de otra corrida, y en gate/p1.sh
#      es exactamente la puerta por la que `p1.sh hygiene <run id>` habria
#      machacado diecinueve veredictos con dos.
ANTES_17Q="$(siembra_sello 0)"
SELLO_ESCRITO_AQUI=0
completa_el_sello
roja 17q "${ANTES_17Q}|0" "$(huella_del_sello)|$(restos_al_lado)" "sin la bandera de la ESCRITURA el sello no se toca ni se termina: es lo que impide que una invocacion que se ENCONTRO un sello le ponga encima sus propios veredictos"
SELLO_ESCRITO_AQUI=1

rm -rf -- "${BANCO}/sellos"
OUT_DIR="${GUARDA_OUTDIR}"; RUN_ID="${GUARDA_RUNID}"; OUT_LOCAL="${GUARDA_OUT}"
CHECK_FAILED=0

# ---- 17r: LA FASE DE HIGIENE DE FIERRO LLEGA A SU FINAL BAJO set -e ----------
#
# LA FILA MAS CARA DE ESTE BLOQUE Y LA QUE MAS PESA, y la trajo un lector leyendo
# el guion y no el banco. `ask_on` tiene TRES salidas, 0 si, 1 no, 2 ilegible, y en
# el paso 1 de phase_hygiene_fierro la respuesta NORMAL es 1: el paso de arriba
# acaba de matar esos daemons. Escrita como orden desnuda seguida de `rc_a=$?`, ese
# 1 es un fallo a los ojos de `set -e`, que es el modo en que corre gate/p2.sh, y
# MATABA LA FASE EN LA PRIMERA VUELTA DEL BUCLE. Todo lo que hay debajo era codigo
# muerto en fierro: los pasos 2, 3 y 4, el barrido del sello que este bloque entero
# existe para probar, la linea de PASS y el propio `end_check`. O sea que la frase
# "el sello se escribe desde la higiene y antes del barrido" era FALSA en el camino
# de fierro, y ninguna de las diecisiete filas de arriba podia verlo, porque todas
# llaman a las funciones del sello DIRECTAMENTE.
#
# COMO SE MIDE, y es la unica forma que separa las dos: se corre la fase ENTERA con
# `set -e` puesto, contra la flota de mentira, y se exige que llegue a su ULTIMA
# linea, que es la del barrido de sellos. Con la orden desnuda de vuelta, la fase no
# imprime ni una linea y esta fila cae.
#
# LO QUE ESTA FILA NO DICE: nada sobre si los pasos 2 y 3 hacen bien su trabajo
# contra hosts de verdad. Solo que la fase se recorre entera en vez de morirse en su
# primer bucle, que es lo que estaba roto.
mkdir -p "${ARTEFACTO_REAL}"
# LA SALIDA VA A UN FICHERO Y NO A UNA SUSTITUCION, y NINGUN `|| true` toca a la
# fase. Las dos versiones anteriores de esta linea cometieron el mismo defecto que
# la fila mide, cada una por su lado, y las dos se cazaron con el mutante puesto:
#
#   1. `$( set -e; fase || true )`: una orden a la izquierda de `||` corre con
#      errexit SUPRIMIDO, y la supresion entra en el cuerpo de la funcion, asi que
#      el `set -e` de dentro no valia nada y la fila salia verde con el defecto.
#   2. `SALIDA="$( set -e; fase )"` a secas, aqui si aborta, pero mata al BANCO:
#      este fichero SOURCEA gate/p2.sh, que en su linea 55 pone `set -euo pipefail`,
#      asi que desde esa linea el banco corre con errexit heredado. La sustitucion
#      fallida se llevaba el banco entero por delante y la fila ni se imprimia.
#
# La forma de abajo separa las tres cosas: un subshell explicito con su propio
# `set -e`, que no esta en contexto de condicion y por tanto no suprime nada; la
# salida a fichero, que sobrevive a la muerte del subshell; y un `set +e` alrededor,
# que impide que la muerte del subshell se lleve al banco.
set +e
( set -e; phase_hygiene_fierro ) > "${BANCO}/17r.out" 2>&1
set -e
roja 17r "1" "$(grep -c 'p2 iron artifacts under gate/out' "${BANCO}/17r.out")" "phase_hygiene_fierro se recorre ENTERA bajo set -e y llega a su ultima linea, el barrido de sellos: con un ask_on desnudo el 'no' normal del primer bucle mataba la fase y todo lo de abajo era codigo muerto en fierro"
CHECK_FAILED=0

# ---- 17v a 17z: EL TECHO DE LOS ARTEFACTOS DE ENSAYO -------------------------
#
# POR QUE ESTAS FILAS ESTAN AQUI Y NO EN gate/p2-guard-test.sh, con la medida que
# lo decide. Aquel banco es el brazo rojo del ensayo y seria el sitio natural; el
# problema es el precio. Para probar un techo de CINCO hay que tener SEIS
# artefactos, y alli cada uno sale de una corrida entera del ensayo, que cuesta de
# 120.66 a 128.37 segundos medidos sobre sus propios timings.txt: seis son trece
# minutos para medir una condicion que aqui se monta con seis `mkdir`. Alli entra
# UNA fila, la de punta a punta, que pregunta lo que este banco no puede: que
# despues de dieciocho ensayos de verdad el techo se cumplio.
#
# Y SE MONTA UN gate/out DE MENTIRA. El barrido borra directorios, asi que una fila
# que lo corriera contra el gate/out de verdad se llevaria por delante los
# artefactos de esta maquina para probar que sabe llevarselos. OUT_DIR se mueve al
# taller del banco, que la trampa ya barre.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"; GUARDA_FIERRO="${ES_FIERRO}"
OUT_DIR="${BANCO}/techo"
ES_FIERRO=0

# siembra_ensayos <cuantos>: crea artefactos con marcas de tiempo crecientes y con
# contenido, y devuelve el nombre del ultimo, que hace de corrida en curso.
siembra_ensayos() {
	local i=1 n="$1" nombre
	rm -rf -- "${BANCO}/techo"; mkdir -p "${OUT_DIR}"
	while [ "${i}" -le "${n}" ]; do
		nombre="p2-local-2026090${i}T000000Z-${i}00"
		mkdir -p "${OUT_DIR}/${nombre}"
		printf 'manifiesto de la corrida %s\n' "${i}" > "${OUT_DIR}/${nombre}/manifest.txt"
		# El orden por fecha es lo que el barrido usa, y `ls -dt` mira mtime, asi que
		# se fija a mano en vez de confiar en el orden en que se crearon.
		touch -t "20260${i}010000" "${OUT_DIR}/${nombre}"
		i=$((i + 1))
	done
	printf '%s' "${nombre}"
}
cuenta_ensayos() { ls -1d "${OUT_DIR}"/p2-local-[0-9]*Z-[0-9]* 2>/dev/null | wc -l | tr -d ' '; }

# 17v: SEIS artefactos y el de la corrida en curso es uno de ellos. Quedan CINCO
#      mas el propio, y el que se va es el mas VIEJO, no uno cualquiera.
ULTIMO="$(siembra_ensayos 7)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
RETIRADOS="$(barre_ensayos_viejos)"
fila 17v "1|6|no|si" "${RETIRADOS}|$(cuenta_ensayos)|$([ -d "${OUT_DIR}/p2-local-20260901T000000Z-100" ] && echo si || echo no)|$([ -d "${OUT_LOCAL}" ] && echo si || echo no)" "con siete artefactos el techo retira UNO, deja cinco mas el de esta corrida, se lleva el MAS VIEJO y no toca el propio"

# 17w: por DEBAJO del techo no se toca nada. Una fila que solo probara el corte
#      pasaria con un barrido que borrase siempre.
ULTIMO="$(siembra_ensayos 3)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
RETIRADOS="$(barre_ensayos_viejos)"
fila 17w "0|3" "${RETIRADOS}|$(cuenta_ensayos)" "por debajo del techo no se retira nada: el barrido no borra por costumbre, borra por cuenta"

# 17x: EL ARTEFACTO DE FIERRO NO SE TOCA, ni sellado ni sin sellar, y esta es la
#      fila que separa las dos clases. Es la mitad que la decision del 8 de
#      septiembre de 2026 hace obligatoria: el techo es del ensayo y el fierro
#      queda fuera.
ULTIMO="$(siembra_ensayos 7)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
mkdir -p "${OUT_DIR}/p2-20260901T000000Z-999" "${OUT_DIR}/p2-20260902T000000Z-998"
printf 'de fierro, sellado\n' > "${OUT_DIR}/p2-20260901T000000Z-999/manifest.txt"
printf 'Phase 2 iron gate artifact\n' > "${OUT_DIR}/p2-20260901T000000Z-999/SEALED"
printf 'de fierro, SIN sello\n' > "${OUT_DIR}/p2-20260902T000000Z-998/manifest.txt"
touch -t 202601010000 "${OUT_DIR}/p2-20260901T000000Z-999" "${OUT_DIR}/p2-20260902T000000Z-998"
barre_ensayos_viejos >/dev/null
roja 17x "si|si" "$([ -d "${OUT_DIR}/p2-20260901T000000Z-999" ] && echo si || echo no)|$([ -d "${OUT_DIR}/p2-20260902T000000Z-998" ] && echo si || echo no)" "los artefactos de FIERRO sobreviven al techo, el sellado y el que no lo esta, aunque sean los mas viejos de todos: el techo es del ensayo y esa es la decision entera"

# 17y: la flota huerfana se va con su artefacto y NO antes. Una flota cuyo
#      artefacto sigue ahi es de una corrida viva.
ULTIMO="$(siembra_ensayos 3)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
mkdir -p "${OUT_DIR}/p2-local-fleet-20260901T000000Z-100" "${OUT_DIR}/p2-local-fleet-20260999T000000Z-777"
printf 'x\n' > "${OUT_DIR}/p2-local-fleet-20260901T000000Z-100/node1.log"
printf 'x\n' > "${OUT_DIR}/p2-local-fleet-20260999T000000Z-777/node1.log"
barre_ensayos_viejos >/dev/null
roja 17y "si|no" "$([ -d "${OUT_DIR}/p2-local-fleet-20260901T000000Z-100" ] && echo si || echo no)|$([ -d "${OUT_DIR}/p2-local-fleet-20260999T000000Z-777" ] && echo si || echo no)" "una flota cuyo artefacto SIGUE ahi se queda, y la huerfana se va: es un invariante, una flota nunca sobrevive a su artefacto, y no un segundo techo"

# 17z: EN FIERRO EL BARRIDO NO CORRE. Sin esta fila, la guarda de la primera linea
#      seria una decision que nadie mira.
ULTIMO="$(siembra_ensayos 7)"
OUT_LOCAL="${OUT_DIR}/${ULTIMO}"
ES_FIERRO=1
RETIRADOS="$(barre_ensayos_viejos)"
ES_FIERRO=0
roja 17z "0|7" "${RETIRADOS}|$(cuenta_ensayos)" "en una corrida de FIERRO el barrido devuelve en su primera linea y no retira nada: una corrida que cuesta horas de VM no esta ahi para hacer limpieza"

rm -rf -- "${BANCO}/techo"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"; ES_FIERRO="${GUARDA_FIERRO}"

# ---- 17aa a 17ad: EL MARCADOR MANDA SOBRE EL TECHO ---------------------------
#
# ESTAS CUATRO FILAS EXISTEN POR UN INCIDENTE QUE YA IBA POR LA TERCERA VEZ, y la
# tercera la escribio esta misma casa: el techo de los ensayos borraba por
# antiguedad sin mirar el marcador RUNNING, o sea que un ensayo VIVO que corriera
# fuera del banco perdia su directorio a mitad. Es lo que un `make clean` hizo el
# 28 de agosto y el 7 de septiembre de 2026, con la leccion ya escrita en el
# Makefile a dos ficheros de distancia. Se midio antes de arreglarlo: con un
# artefacto viejo que llevaba un pid VIVO dentro y seis mas nuevos por delante, el
# techo se lo llevo.
#
# EL PID VIVO ES UN PROCESO DE VERDAD Y NO UN NUMERO INVENTADO. Un pid escrito a
# mano puede estar libre hoy y ocupado manana, y entonces la fila mide otra cosa
# sin decirlo. Aqui se lanza un `sleep`, se usa SU pid, y se mata al terminar.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"; GUARDA_FIERRO="${ES_FIERRO}"
OUT_DIR="${BANCO}/marcador"
ES_FIERRO=0
rm -rf -- "${OUT_DIR}"; mkdir -p "${OUT_DIR}"

sleep 300 &
PID_VIVO=$!

# Cuatro artefactos viejos, uno por cada respuesta de marcador_de, y seis nuevos
# por delante para empujarlos a todos por debajo del techo.
siembra_marcado() {   # <nombre> <contenido del RUNNING, o vacio para no ponerlo>
	mkdir -p "${OUT_DIR}/$1"
	printf 'manifiesto\n' > "${OUT_DIR}/$1/manifest.txt"
	[ -n "${2:-}" ] && printf 'pid: %s\nrun: %s\nscript: gate/p2.sh\n' "$2" "$1" > "${OUT_DIR}/$1/RUNNING"
	touch -t 202601010000 "${OUT_DIR}/$1"
}
siembra_marcado p2-local-20260101T000000Z-111 "${PID_VIVO}"
siembra_marcado p2-local-20260101T000000Z-222 999999
siembra_marcado p2-local-20260101T000000Z-333 "no-es-un-numero"
siembra_marcado p2-local-20260101T000000Z-444 ""
for i in 3 4 5 6 7 8; do
	mkdir -p "${OUT_DIR}/p2-local-2026020${i}T000000Z-${i}00"
	printf 'x\n' > "${OUT_DIR}/p2-local-2026020${i}T000000Z-${i}00/manifest.txt"
	touch -t "20260${i}010000" "${OUT_DIR}/p2-local-2026020${i}T000000Z-${i}00"
done
OUT_LOCAL="${OUT_DIR}/p2-local-20260208T000000Z-800"
SALIDA_MARCADOR="$(barre_ensayos_viejos 2>&1 >/dev/null)"

roja 17aa "si|1" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-111" ] && echo si || echo no)|$(printf '%s' "${SALIDA_MARCADOR}" | grep -c 'su corrida sigue viva')" "un artefacto con un pid VIVO dentro sobrevive al techo y lo dice: el techo es una regla sobre lo que ya termino, y sin esta linea el barrido repetia por TERCERA vez el incidente que make clean tuvo dos veces"
fila 17ab "no|1" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-222" ] && echo si || echo no)|$(printf '%s' "${SALIDA_MARCADOR}" | grep -c 'una corrida que no termino')" "y el de un pid MUERTO si se retira, diciendolo: si un marcador huerfano protegiera, una corrida matada con -9 bloquearia el techo para siempre, que es como una defensa se acaba quitando por estorbar"
roja 17ac "si|1" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-333" ] && echo si || echo no)|$(printf '%s' "${SALIDA_MARCADOR}" | grep -c 'no se puede leer')" "un pid que no se puede LEER no es lo mismo que un pid muerto: son TRES respuestas y no dos, y la de en medio se conserva y se dice"
fila 17ad "no" "$([ -d "${OUT_DIR}/p2-local-20260101T000000Z-444" ] && echo si || echo no)" "y sin marcador ninguno el techo se lo lleva como siempre, que es el control sin el cual las tres de arriba pasarian con un techo que no borrase nunca"

kill "${PID_VIVO}" 2>/dev/null || true
wait "${PID_VIVO}" 2>/dev/null || true
rm -rf -- "${OUT_DIR}"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"; ES_FIERRO="${GUARDA_FIERRO}"

# ---- 17ba a 17bh: LOS CINCO BLOQUEANTES DEL FIERRO ---------------------------
#
# LAS TRAJO UN LECTOR EXTERNO al que se le paso el diseno de la seccion 10 entera
# con una sola condicion, que no pudiera correr nada, y su ultima linea era "no
# encenderia". Los cinco se re-derivaron contra el guion antes de tocarlos. Las
# filas de aqui son lo que impide que vuelvan, y cada una se dispara por los dos
# lados: la forma de hoy y la que tenia.
#
# POR QUE VIVEN AQUI. Son predicados del camino de FIERRO, que es lo que este banco
# existe para probar sin encender nada. Ninguna de las cinco se puede medir en
# gate/p2-guard-test.sh, que corre el ensayo.

# ---- B1: el artefacto de fierro no se declara un ensayo ----------------------
#
# El banner no tenia NI UNA rama por ES_FIERRO, medido: cero apariciones dentro de
# la funcion. Una corrida sobre tres maquinas de verdad imprimia "This is NOT gate
# evidence and it seals nothing", "Three directories on 127.0.0.1 play three
# replicas... there is no fleet" y "Its cut is kill -9", y cerraba con "all
# rehearsal checks passed". El log ES el artefacto y no se arregla despues.
# LA FILA QUE DE VERDAD MIDE EL DESPACHO, y faltaba: las tres de abajo llaman a
# banner_fierro y banner_ensayo DIRECTAMENTE, asi que comprueban lo que cada texto
# dice y no que `banner` elija el correcto. El barrido lo midio: quitandole a
# `banner` su rama de fierro, las tres seguian verdes, porque `banner_fierro`
# seguia existiendo y diciendo lo suyo, solo que ya no lo llamaba nadie. Es la clase
# 15 en una fila: probar la pieza y no el circuito.
GUARDA_FIERRO_B="${ES_FIERRO}"
ES_FIERRO=1; BANNER_DESPACHADO_FIERRO="$(banner 2>/dev/null)"
ES_FIERRO=0; BANNER_DESPACHADO_ENSAYO="$(banner 2>/dev/null)"
ES_FIERRO="${GUARDA_FIERRO_B}"
fila 17b0 "si|no" "$(printf '%s' "${BANNER_DESPACHADO_FIERRO}" | grep -q 'THIS IS GATE EVIDENCE' && echo si || echo no)|$(printf '%s' "${BANNER_DESPACHADO_FIERRO}" | grep -q 'NOT gate evidence' && echo si || echo no)" "con ES_FIERRO=1, banner DESPACHA al de fierro: es el circuito y no la pieza, y sin esta fila quitarle la rama a banner dejaba el banco entero en verde"
roja 17b1 "si|no" "$(printf '%s' "${BANNER_DESPACHADO_ENSAYO}" | grep -q 'NOT gate evidence' && echo si || echo no)|$(printf '%s' "${BANNER_DESPACHADO_ENSAYO}" | grep -q 'THIS IS GATE EVIDENCE' && echo si || echo no)" "y con ES_FIERRO=0 despacha al del ensayo, que es la otra mitad sin la cual un banner que dijera siempre fierro tambien pasaria"

BANNER_FIERRO="$(banner_fierro 2>/dev/null)"
BANNER_ENSAYO="$(banner_ensayo 2>/dev/null)"
fila 17ba "0|0|0|1" "$(printf '%s' "${BANNER_FIERRO}" | grep -c 'NOT gate evidence')|$(printf '%s' "${BANNER_FIERRO}" | grep -c '127\.0\.0\.1')|$(printf '%s' "${BANNER_FIERRO}" | grep -c 'kill -9')|$(printf '%s' "${BANNER_FIERRO}" | grep -c 'THIS IS GATE EVIDENCE')" "el banner de FIERRO no dice que no es evidencia, ni habla de tres directorios en loopback, ni de un corte con kill -9, y si dice lo que es"
roja 17bb "1|1|1|0" "$(printf '%s' "${BANNER_ENSAYO}" | grep -c 'NOT gate evidence')|$(printf '%s' "${BANNER_ENSAYO}" | grep -c '127\.0\.0\.1')|$(printf '%s' "${BANNER_ENSAYO}" | grep -c 'kill -9')|$(printf '%s' "${BANNER_ENSAYO}" | grep -c 'THIS IS GATE EVIDENCE')" "y el del ENSAYO sigue diciendo exactamente lo que decia, palabra por palabra: la rama nueva no se llevo por delante la declaracion que el ensayo tiene que hacer"
# LA PREGUNTA ES POR PRESENCIA Y NO POR CUENTA, y la primera version contaba. Pedia
# UNA aparicion de sysrq-trigger y el banner lo nombra DOS, en el corte y en la
# lectura del 7 de septiembre: la fila salia roja por una expectativa mia y no por
# el objeto. Contar apariciones de una frase dentro de PROSA es una cifra que se
# mueve cada vez que alguien reescribe un parrafo, y entonces el banco se pone rojo
# por trabajar. Lo que esta fila quiere saber es si la frase ESTA.
fila 17bc "si|si" "$(printf '%s' "${BANNER_FIERRO}" | grep -q 'sysrq-trigger' && echo si || echo no)|$(printf '%s' "${BANNER_FIERRO}" | grep -q 'caching: ReadWrite' && echo si || echo no)" "y el de fierro lleva su corte de verdad y la frontera del cache del anfitrion, que es la exclusion que el diseno cuelga de este banner"

# ---- B1, la otra mitad: la linea de cierre -----------------------------------
#
# Es la ULTIMA linea del log, que es la que se cita, y decia "all rehearsal checks
# passed" sobre la unica corrida que no se puede repetir.
GUARDA_FIERRO="${ES_FIERRO}"; GUARDA_EXPECTED="${EXPECTED}"; GUARDA_VERDICTS="${VERDICTS}"
GUARDA_COMPLETED="${COMPLETED}"; GUARDA_STARTED="${RUN_STARTED}"
EXPECTED="P2.build"; VERDICTS=" P2.build=pass "; COMPLETED=1; RUN_STARTED=1
ES_FIERRO=1; CIERRE_FIERRO="$(emit_final_verdict 2>/dev/null)"
ES_FIERRO=0; CIERRE_ENSAYO="$(emit_final_verdict 2>/dev/null)"
fila 17bd "1|0" "$(printf '%s' "${CIERRE_FIERRO}" | grep -c 'all IRON checks passed')|$(printf '%s' "${CIERRE_FIERRO}" | grep -c 'rehearsal')" "la linea de cierre de una corrida de FIERRO no dice rehearsal"
roja 17be "1" "$(printf '%s' "${CIERRE_ENSAYO}" | grep -c 'all rehearsal checks passed')" "y la del ensayo sale EXACTA como estaba, que es lo que casan los bancos por su literal"
ES_FIERRO="${GUARDA_FIERRO}"; EXPECTED="${GUARDA_EXPECTED}"; VERDICTS="${GUARDA_VERDICTS}"
COMPLETED="${GUARDA_COMPLETED}"; RUN_STARTED="${GUARDA_STARTED}"

# ---- B2: el cliente del mutante corre en el host y no en este portatil -------
#
# Corria aqui, con el binario darwin y atado a una direccion privada de la flota
# que esta maquina no tiene. Es el mismo defecto que la seccion 10.16 declara
# cerrado para client_op, y a client_op si se le aplico. Sin esto, los cuarenta
# intentos fallaban los cuarenta y el brazo rojo entero no llegaba a medir.
CUERPO_RED_FIERRO="$(awk '/^phase_red_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
fila 17bf "si|no" "$(printf '%s' "${CUERPO_RED_FIERRO}" | grep -q 'run_on 1 "cd naylamp' && echo si || echo no)|$(printf '%s' "${CUERPO_RED_FIERRO}" | grep -q '"\${BIN}" client -listen' && echo si || echo no)" "el cliente del mutante va por run_on al host 1, como client_op, y ya no se invoca el binario local contra una direccion que esta maquina no tiene"
roja 17bg "si" "$(printf '%s' "${CUERPO_RED_FIERRO}" | grep -q '__RC__=0)' && echo si || echo no)" "y lee su estado por la ULTIMA linea entera y no por una subcadena, que es la misma guarda de client_op: un canal de estado que la carga util puede falsificar no es un canal de estado"

# ---- B5b: el testigo sincroniza su fichero y su directorio, no la maquina ----
#
# `sync` es GLOBAL y vaciaba la pagina sucia entera del host, log de raft incluido,
# asi que en el instante del corte todo lo ackeado estaba en el plato hubiera
# barrera o no. Es el hallazgo mas caro: el camino VERDE que no media nada.
CUERPO_TESTIGO="$(awk '/^testigo_siembra\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
roja 17bh "no|si|si" "$(printf '%s' "${CUERPO_TESTIGO}" | grep -qE '&& sync$|; sync$' && echo si || echo no)|$(printf '%s' "${CUERPO_TESTIGO}" | grep -q 'os.fsync(f)' && echo si || echo no)|$(printf '%s' "${CUERPO_TESTIGO}" | grep -q 'os.fsync(h)' && echo si || echo no)" "el testigo ya no hace un sync GLOBAL, y sincroniza el fichero Y su directorio: un sync global dentro de un gate de durabilidad es el instrumento anulando lo que mide"

# ---- 17ca a 17cf: B5a, LAS ESCRITURAS EN VUELO EN EL INSTANTE DEL CORTE ------
#
# LA DECISION ES DE QUIEN ENCARGA y dice por que: la propiedad es "ack implica
# durable", y sin escrituras en vuelo la mitad del ack no se ejercita nunca, porque
# el mutante solo pierde algo si el corte cae ENTRE el ack y la barrera. La carga
# cerraba antes del corte, asi que esa ventana no existia.
#
# Y ESTAS FILAS DISPARAN LA FUNCION DE VERDAD, no su texto. `escritor_en_vuelo`
# corre contra la flota de mentira de este banco, con un naylampd falso que se
# puede hacer contestar 0 o distinto de 0 a voluntad. Es lo mas cerca del objeto
# que se puede estar sin encender tres maquinas.
GUARDA_OUTDIR="${OUT_DIR}"; GUARDA_OUT="${OUT_LOCAL}"; GUARDA_FIERRO="${ES_FIERRO}"
GUARDA_MANIFEST="${MANIFEST}"
OUT_LOCAL="${BANCO}/vuelo"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"; : > "${MANIFEST}"
ES_FIERRO=1
# La cota se baja para que la fila cueste segundos y no minutos: lo que se mide es
# la FORMA de lo que escribe, y esa no depende de cuantas veces lo haga.
GUARDA_VUELO_MAX="${EN_VUELO_MAX}"; EN_VUELO_MAX=6

# EL naylampd DE MENTIRA, que es lo que deja disparar los dos lados: contesta 0
# mientras exista el fichero de la senal, y distinto de 0 en cuanto se retire. Es
# el corte, visto desde el cliente: la conexion deja de dar acks.
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
[ -e "${BANCO_ESTADO}/1.acepta" ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"
: > "${BANCO}/estado/1.acepta"

escritor_en_vuelo
fila 17ca "6|0" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "con la conexion viva, cada ack deja UNA linea confirmed en el manifiesto y ninguna uncertain: su ausencia del log sera un veredicto, que es exactamente la propiedad"
fila 17cb "6|0" "$(grep -c '^ack ' "${OUT_LOCAL}/en-vuelo.txt")|$(grep -c '^sin-ack ' "${OUT_LOCAL}/en-vuelo.txt")" "y cada uno queda fechado en el crudo de la frontera, que es lo que dice en que INSTANTE se cerro el manifiesto"
fila 17cc "1|1" "$(grep -c 'ultimo ack:' "${OUT_LOCAL}/en-vuelo-frontera.txt")|$(grep -c 'acks:' "${OUT_LOCAL}/en-vuelo-frontera.txt")" "y la frontera se escribe en el ARTEFACTO y no solo en la consola, porque es lo que se cita cuando la consola ya no esta"

# EL CORTE, visto desde el cliente: la conexion deja de dar acks a mitad.
: > "${MANIFEST}"; rm -f -- "${OUT_LOCAL}/en-vuelo.txt"
EN_VUELO_MAX=6
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
n=$(cat "${BANCO_ESTADO}/1.cuenta" 2>/dev/null || echo 0)
n=$((n + 1)); echo "${n}" > "${BANCO_ESTADO}/1.cuenta"
[ "${n}" -le 2 ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"
rm -f -- "${BANCO}/estado/1.cuenta"
escritor_en_vuelo
roja 17cd "2|3" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "cuando la conexion muere a mitad, lo ackeado queda confirmed y lo que se envio sin respuesta queda UNCERTAIN: sin esa linea, un id comprometido cuyo ack se perdio saldria FANTASMA y pondria roja la fidelidad por hacer justo lo que se le pidio"
roja 17ce "3" "$(grep -c '^sin-ack ' "${OUT_LOCAL}/en-vuelo.txt")" "y el bucle se PARA a los tres fallos seguidos en vez de seguir contra tres maquinas que ya no contestan, que es la cota que la clausula 24 obliga"
roja 17cf "0" "$(sort "${MANIFEST}" | awk '{print $2}' | uniq -d | grep -c .)" "y NINGUN id recibe las dos lineas: el comprobador marca AMBIGUO todo id que toque una operacion sin respuesta, asi que escribir las dos habria costado la comparacion de valor de los que SI volvieron con su ack"

EN_VUELO_MAX="${GUARDA_VUELO_MAX}"
printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/1/naylamp/bin/naylampd"
rm -f -- "${BANCO}/estado/1.acepta" "${BANCO}/estado/1.cuenta"
rm -rf -- "${BANCO}/vuelo"
OUT_DIR="${GUARDA_OUTDIR}"; OUT_LOCAL="${GUARDA_OUT}"; ES_FIERRO="${GUARDA_FIERRO}"; MANIFEST="${GUARDA_MANIFEST}"

# ---- 17da a 17dd: B3 y B4, lo que la mitad CALIENTE del preflight tiene que hacer
#
# ESTAS CUATRO SE LEEN DEL TEXTO DE LA FUNCION Y NO SE DISPARAN, y eso va dicho en
# vez de disfrazado. `caliente()` de gate/p2-preflight.sh EXIGE tres maquinas
# encendidas: no hay forma de correrla aqui sin encender, que es justo lo que este
# banco existe para no hacer. Lo que si se puede es exigir que los pasos ESTEN, y
# los mutantes del barrido los quitan uno a uno para comprobar que estas filas
# caen. Es mas debil que disparar la funcion y mas fuerte que no mirar nada, y
# cual de las dos cosas es va escrito aqui y no se deja suponer.
#
# LO QUE COSTABA QUE NO ESTUVIERAN, medido contra el guion: `P2.pre.identity` en
# fierro compara la huella del binario de los hosts BYTE A BYTE con el que la
# corrida acaba de cruza-compilar, asi que sin despliegue fresco no casa nunca; el
# material TLS dura 24 h, asi que el de los hosts esta caducado y la flota no elige
# lider; y una sola entrada vieja en naylamp/data sale FANTASMA en las TRES copias
# frias y pone P2.recover.faithful roja con cara de rojo de PROPIEDAD, que es el
# rojo que no se re-corre nunca.
CUERPO_CALIENTE="$(awk '/^caliente\(\) \{/,/^\}$/' "${GATE_DIR}/p2-preflight.sh")"
fila 17da "si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q '"${GATE_DIR}/deploy.sh"' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q '"${GATE_DIR}/cluster.sh" start' && echo si || echo no)" "la mitad caliente DESPLIEGA el binario y los certificados y LEVANTA la flota, que es lo que la cabecera de gate/p2.sh llevaba afirmando que hacia sin hacerlo"
roja 17db "si|si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'LITERAL_LIDER=' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'quien=' && echo si || echo no)|$(LIT="$(printf '%s' "${CUERPO_CALIENTE}" | sed -n "s/.*LITERAL_LIDER='\\([^']*\\)'.*/\\1/p" | head -1)"; [ -n "${LIT}" ] && grep -rqF "${LIT}" "${GATE_DIR}/../engine" && echo si || echo no)" "y no se conforma con que los demonios arranquen: exige que ELIJAN LIDER, y la tercera columna CASTEA EL LITERAL CONTRA engine/ en vez de contra el texto del propio gate. Hasta la cuarta vuelta esperaba 'became leader', que no existe en el motor: el demonio escribe role=leader, el case no casaba nunca, y el paso cerraba con mal nombrando material TLS caducado sobre una flota sana. Preguntar si la frase esta en el gate solo comprueba que el gate se cita a si mismo"
fila 17dc "si|si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'rm -rf data logs data-mutante' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'VACIOS en los tres, verificado' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'naylamp/data-mutante -mindepth 1' && echo si || echo no)" "naylamp/data, naylamp/logs y naylamp/data-mutante se miden, se limpian y se vuelven a MEDIR: es una precondicion y no una tolerancia, y el del mutante estaba fuera hasta que un lector lo trajo, con el mismo razonamiento entero encima: un id 7 viejo ahi dentro hace que el brazo rojo publique que el mutante sin barrera no perdio nada"
roja 17dd "si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'sudo -n test -w /proc/sysrq-trigger' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'os.fsync(os.open' && echo si || echo no)" "y se ejercitan ANTES del corte las dos cosas de las que el corte depende y que corta_en no puede ver, porque tira su estado a proposito: que sudo no pida contrasena, y que python3 pueda hacer fsync de un directorio"

# ---- 17ea a 17ef: LO QUE LA SEGUNDA VUELTA DEL LECTOR EXTERNO ENCONTRO --------
#
# LAS CINCO FILAS DE ARRIBA, 17ca a 17cf, DEJARON PASAR TRES DEFECTOS, y el lector
# dijo por que con una frase que este mismo fichero acababa de escribir sobre el
# banner: **probaban la pieza y no el circuito**. Contaban lineas `confirmed` y
# `uncertain` en el manifiesto y ahi paraban. Ninguna metia ese manifiesto en el
# python que construye `live-ids.txt`, que es uno de los DOS consumidores del
# manifiesto y el unico que este guion controla. Si lo hubieran hecho, la 17cd,
# que espera dos confirmed y tres uncertain, habria destapado en el acto que las
# tres `uncertain` entraban en el conjunto vivo y ponian la corrida roja.
LIVEIDS="${BANCO}/live-ids.py"
awk '/^\t\/usr\/bin\/python3 - "\$\{MANIFEST\}" > "\$\{OUT_LOCAL\}\/live-ids.txt" <<.PY.$/{f=1;next} f&&/^PY$/{exit} f{print}' "${GATE_DIR}/p2.sh" > "${LIVEIDS}"
fila 17ea "si" "$([ -s "${LIVEIDS}" ] && echo si || echo no)" "el constructor del conjunto vivo se extrae de gate/p2.sh y no se copia aqui: si cambia de forma, esta extraccion sale vacia y el banco lo dice en vez de probar aire"

MAN_PRUEBA="${BANCO}/manifiesto-de-prueba.txt"
printf 'put 1 1,0,0,0,0,0,0,0 confirmed\nput 100 0,0,1,0,0,1,1,0 uncertain\nput 2 0,1,0,0,0,0,0,0\ndel 1\n' > "${MAN_PRUEBA}"
VIVOS="$(/usr/bin/python3 "${LIVEIDS}" "${MAN_PRUEBA}" | tr '\n' ' ')"
roja 17eb "2 " "${VIVOS}" "un id UNCERTAIN no entra en el conjunto vivo, uno sin marcador SI, y un del retira el suyo: sin esta linea, cada envio que no volvio con ack se exigia presente, no podia estarlo porque se mando contra tres maquinas ya muertas, y la corrida salia ROJA diciendo que el motor perdio una escritura ackeada"

# EL RANGO EN VUELO, medido contra vec_for y no afirmado
roja 17ec "0 0" "$(comprueba_rango_en_vuelo)" "ningun vector del rango en vuelo coincide con uno de la carga ni es el vector cero: vec_for solo depende de id mod 256, asi que el rango de antes daba el vector CERO en el 512 y treinta colisiones con la carga, que es el defecto de la seccion 10.9 reabierto"
GUARDA_DESDE="${ID_EN_VUELO_DESDE}"; GUARDA_MAXV="${EN_VUELO_MAX}"
ID_EN_VUELO_DESDE=500; EN_VUELO_MAX=200
roja 17ed "30 1" "$(comprueba_rango_en_vuelo)" "y con el rango de antes la guarda MUERDE, y dice cuanto: treinta choques, uno por cada id de la carga, y un vector cero. Sin esta mitad, la fila de arriba pasaria con una guarda que dijera siempre cero"
ID_EN_VUELO_DESDE="${GUARDA_DESDE}"; EN_VUELO_MAX="${GUARDA_MAXV}"

# LO ENVIADO Y NO ACKEADO SE PLIEGA, tambien si el escritor murio
GUARDA_OUT2="${OUT_LOCAL}"; GUARDA_MAN2="${MANIFEST}"
OUT_LOCAL="${BANCO}/pliegue"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"
printf 'put 100 %s confirmed\n' "$(vec_for 100)" > "${MANIFEST}"
printf '100 %s\n101 %s\n102 %s\n' "$(vec_for 100)" "$(vec_for 101)" "$(vec_for 102)" > "${OUT_LOCAL}/en-vuelo-enviados.txt"
pliega_en_vuelo_sin_ack
fila 17ee "1|2" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "todo id que se ENVIO y no dejo su linea vuelve como uncertain: la ventana entre que el cliente contesta y que se anota su linea existe, y una muerte ahi dejaba un id comprometido AUSENTE del manifiesto, que es lo unico que verifylog llama fantasma"
pliega_en_vuelo_sin_ack
roja 17ef "1|2" "$(grep -c ' confirmed$' "${MANIFEST}")|$(grep -c ' uncertain$' "${MANIFEST}")" "y plegar dos veces no duplica nada, que es lo que permite llamarlo desde el escritor Y desde la trampa de salida sin pensar en cual llego antes"
OUT_LOCAL="${GUARDA_OUT2}"; MANIFEST="${GUARDA_MAN2}"
rm -rf -- "${BANCO}/pliegue"

# NINGUN wait DESNUDO detras de un corte, en NINGUNA de las dos fases
CUERPO_CUT_FIERRO="$(awk '/^phase_cut_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
CUERPO_RED_FIERRO2="$(awk '/^phase_red_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
roja 17eg "si|si" "$(printf '%s' "${CUERPO_CUT_FIERRO}" | grep -q 'wait ${pids_corte}' && echo si || echo no)|$(printf '%s' "${CUERPO_RED_FIERRO2}" | grep -q 'wait ${pids_corte_rojo}' && echo si || echo no)" "ninguna de las dos fases que cortan espera con un wait DESNUDO: un wait sin argumentos espera a TODO lo de fondo, y con el escritor en vuelo detras habria tomado el instante del corte treinta segundos tarde, contra una cota de cinco, poniendo los veredictos en none sin decir por que"

# EL VEREDICTO QUE FALTABA, y que la lista de fierro lo nombre
roja 17eh "si|si" "$(grep -q 'P2.cut.envuelo' "${GATE_DIR}/p2.sh" && echo si || echo no)|$([ "$(grep -c '^[[:space:]]*EXPECTED=.*P2\.pre\.sysrq.*P2\.cut\.envuelo' "${GATE_DIR}/p2.sh")" -ge 1 ] && echo si || echo no)" "existe un veredicto colgado de que HAYA habido al menos un ack en vuelo, y la lista de fierro lo nombra: sin el, un escritor que no ackeara nada dejaba la propiedad igual de sin medir que antes del arreglo, y nada lo decia"

# Y LA MITAD DE ARRIBA SE ESCRIBE SIN TUBERIA Y SIN ESCAPES, que es lo que la
# hace inmune a las DOS clases de dependencia de entorno que esta pasada encontro.
# La primera es la de los escapes, que es la que la tumbo. La segunda se midio al
# revisarla y no habia salido todavia: con `set -o pipefail`, una tuberia que
# acaba en `grep -q` devuelve 141 cuando el de aguas arriba escribe mas de lo que
# cabe en el tubo y el de abajo sale al primer acierto. Medido aqui: una tuberia
# con 200.000 lineas y `grep -q` da rc=141 con el acierto dentro, o sea que habria
# impreso "no" teniendo el hecho delante. La fila de aqui abajo tiene una salida
# de dos lineas y no llega a esa ventana, pero la forma sin tuberia la saca de las
# dos clases a la vez y no solo de la que ya mordio.
# LA FILA QUE EXISTE POR EL INCIDENTE DEL 14 DE SEPTIEMBRE DE 2026, y es la unica
# de este banco que no mira a gate/p2.sh sino a los guiones que preguntan. La
# fila de arriba, la 17eh, dio VERDE en macOS y ROJA en el runner de CI con el
# MISMO commit, y no por la propiedad: su patron era '^\t\t\t\tEXPECTED=' y POSIX
# no define \t dentro de una expresion, asi que BSD grep leia tabulador y GNU
# grep leia la letra t. El hecho que la fila asevera era cierto en los dos sitios;
# lo que cambiaba era el instrumento. Un rojo asi se lee como rojo de propiedad y
# nadie lo re-corre, que es lo caro. LA REPARACION FUERON DOS CAMBIOS Y NO UNO, y
# ninguno de los dos es la forma $'\t': la clase '[[:space:]]*', que POSIX SI
# define, y el colapso de la tuberia de tres greps en un solo `grep -c` con
# comparacion, que saca a la fila tambien de la clase del rc=141. La forma $'\t'
# la nombra gate/entorno.sh como la portable y NO la usa ningun patron de este
# arbol: medido el 14 de septiembre de 2026, CERO apariciones en todo el
# repositorio. Esta fila impide que vuelva la forma SIN DEFINIR, que es la que
# mordio, y su mitad roja reinstala el defecto en una copia para probar que el
# censo sabe contarlo. La primera version de este comentario decia que la
# reparacion fue $'\t', que es una forma que el arbol no contiene: se corrige aqui
# porque es el sitio donde cayo.
MUT_ESC="${BANCO}/p2-iron-test-escape.sh"
python3 - "${GATE_DIR}/p2-iron-test.sh" "${MUT_ESC}" <<'MUTESC'
import sys
# El mutante NO deshace una forma concreta -eso ataba el brazo a como este fichero
# este escrito hoy-: INYECTA una linea con la forma prohibida. Asi la mitad roja
# mide lo que dice medir, que el censo cuenta un escape sin definir, y sigue
# valiendo el dia que ninguna linea del banco use ya la forma portable.
s = open(sys.argv[1], encoding="utf-8").read()
s += "\ngrep '^\\tEXPECTED=' \"${GATE_DIR}/p2.sh\"  # linea inyectada por el brazo rojo de 17ei\n"
open(sys.argv[2], "w", encoding="utf-8").write(s)
MUTESC
roja 17ei "0|1" "$(entorno_escapes_sin_definir "${GATE_DIR}"/*.sh | wc -l | tr -d ' ')|$(entorno_escapes_sin_definir "${MUT_ESC}" | wc -l | tr -d ' ')" "ningun patron de grep de gate/ lleva un escape que POSIX no define -\\t, \\s, \\d, \\w-, que es lo que hizo que la fila de arriba respondiera distinto en dos maquinas con el mismo arbol; y con la forma vieja restituida en una copia el censo la cuenta, o sea que sabe contar"

# LA FILA DE UN PISO POR ENCIMA, del mismo dia y de la misma forma: un guion que
# SOURCEA un fichero que git no trackea corre aqui y muere en un clon, y CI clona
# en limpio. El arreglo de hoy lo estreno: `gate/entorno.sh` entro sourceado en
# SEIS bancos, asi que hasta que no estuviera en el indice el radio de daño de un
# olvido pasaba de uno a seis. La cuenta que se exige es la de las cargas del
# ARBOL; las que el propio guion escribe en su taller quedan exentas y su exencion
# se demuestra con la asignacion de la variable, no se supone.
MUT_CARGA="${BANCO}/p2-iron-test-carga.sh"
python3 - "${GATE_DIR}/p2-iron-test.sh" "${MUT_CARGA}" <<'MUTCARGA'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
s += '\n. "${GATE_DIR}/no-esta-en-git.sh"  # linea inyectada por el brazo rojo de 17ej\n'
open(sys.argv[2], "w", encoding="utf-8").write(s)
MUTCARGA
roja 17ej "0|1" "$(entorno_cargas_sin_trackear "${GATE_DIR}"/*.sh | wc -l | tr -d ' ')|$(entorno_cargas_sin_trackear "${MUT_CARGA}" | wc -l | tr -d ' ')" "ningun guion de gate/ sourcea un fichero del arbol que git no trackee, que es lo que corre aqui y muere en un clon; y con una carga inyectada a un fichero que no esta en el indice el censo la cuenta, o sea que sabe contarla"

# ---- 17fa a 17fd: EL CIRCUITO Y NO LA PIEZA, POR TERCERA VEZ ------------------
#
# El barrido volvio a cazarme lo mismo: la 17ec llama a `comprueba_rango_en_vuelo`
# DIRECTAMENTE, asi que prueba que la guarda sabe contar y no que el escritor la
# CORRA; y el veredicto en vuelo vivia dentro de una fase que necesita tres
# maquinas, asi que ponerlo a verde por las bravas no tumbaba nada. Las dos salidas
# son la misma: llamar al circuito.
GUARDA_OUT3="${OUT_LOCAL}"; GUARDA_MAN3="${MANIFEST}"; GUARDA_FIERRO3="${ES_FIERRO}"
GUARDA_DESDE3="${ID_EN_VUELO_DESDE}"; GUARDA_MAX3="${EN_VUELO_MAX}"
OUT_LOCAL="${BANCO}/circuito"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"; : > "${MANIFEST}"
ES_FIERRO=1
: > "${BANCO}/estado/1.acepta"
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
[ -e "${BANCO_ESTADO}/1.acepta" ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"

# 17fa: con un rango que colisiona, el ESCRITOR se niega y no escribe una sola linea
ID_EN_VUELO_DESDE=500; EN_VUELO_MAX=200
SALIDA_17FA="$(escritor_en_vuelo 2>&1)"
roja 17fa "1|0" "$(printf '%s' "${SALIDA_17FA}" | grep -c 'refusing to write in flight')|$(grep -c . "${MANIFEST}")" "con un rango que colisiona, el ESCRITOR se niega antes de mandar nada y el manifiesto queda vacio: la fila de la guarda sola probaba que sabe contar, no que alguien la mire"

# 17fb: y con el rango bueno escribe
ID_EN_VUELO_DESDE="${GUARDA_DESDE3}"; EN_VUELO_MAX=4
: > "${MANIFEST}"
escritor_en_vuelo >/dev/null 2>&1
fila 17fb "4" "$(grep -c ' confirmed$' "${MANIFEST}")" "y con el rango bueno escribe, que es la mitad sin la cual la de arriba pasaria con un escritor que no escribiera nunca"

# 17fc y 17fd: el veredicto en vuelo, por los dos lados
CHECK_FAILED=0; VERDICTS=" "
veredicto_en_vuelo
fila 17fc "pass" "$(verdict_of P2.cut.envuelo)" "con acks en vuelo, P2.cut.envuelo pasa"
printf '' > "${OUT_LOCAL}/en-vuelo.txt"
VERDICTS=" "; CHECK_FAILED=0
veredicto_en_vuelo
roja 17fd "none" "$(verdict_of P2.cut.envuelo)" "y sin un solo ack en vuelo NO se pone rojo, se pone en NONE: cero acks no es un fallo del motor, es que la corrida no llego a hacer la pregunta, y eso se dice con none y no con un rojo que nombraria la causa equivocada"

EN_VUELO_MAX="${GUARDA_MAX3}"; ID_EN_VUELO_DESDE="${GUARDA_DESDE3}"
printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/1/naylamp/bin/naylampd"
rm -f -- "${BANCO}/estado/1.acepta"; rm -rf -- "${BANCO}/circuito"
OUT_LOCAL="${GUARDA_OUT3}"; MANIFEST="${GUARDA_MAN3}"; ES_FIERRO="${GUARDA_FIERRO3}"
CHECK_FAILED=0

# ---- 17ga a 17gf: LO QUE LA TERCERA VUELTA DEL LECTOR EXTERNO ENCONTRO --------
#
# Y LA PRIMERA DE ELLAS ES LA QUINTA VEZ QUE ESTA CASA COMETE EL MISMO DEFECTO EN
# UNA SOLA SESION: `veredicto_en_vuelo` abria un `begin_check` DENTRO del bloque
# abierto de `P2.cut.fired`, y `begin_check` pone `CHECK_FAILED` a cero. Borraba
# todos sus FAIL: el del nodo que no armo su testigo, el del que NUNCA dejo de
# contestar al ssh -o sea que no se corto- y el de la frontera ausente, que era
# codigo muerto desde el dia que nacio. Y lo que lo escondia fue, otra vez, que la
# fila del banco llamaba a la funcion SOLA, donde funciona. **Llamar a la pieza es
# justo lo que tapa que el circuito esta roto.**
CUERPO_VEREDICTO="$(awk '/^veredicto_en_vuelo\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
CUERPO_CUT2="$(awk '/^phase_cut_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh")"
POS_END="$(printf '%s\n' "${CUERPO_CUT2}" | grep -n 'end_check P2.cut.fired' | tail -1 | cut -d: -f1)"
POS_VER="$(printf '%s\n' "${CUERPO_CUT2}" | grep -n '^	veredicto_en_vuelo$' | tail -1 | cut -d: -f1)"
roja 17ga "si" "$([ -n "${POS_END}" ] && [ -n "${POS_VER}" ] && [ "${POS_VER}" -gt "${POS_END}" ] && echo si || echo no)" "veredicto_en_vuelo se llama DESPUES del ultimo end_check de P2.cut.fired y no dentro de su bloque: begin_check pone CHECK_FAILED a cero, asi que dentro borraba los FAIL de la fase y P2.cut.fired podia registrar PASS con sus propios FAIL impresos encima"

# EL CIRCUITO Y NO LA PIEZA: se monta la fase entera en pequeno, con un FAIL
# acumulado antes, y se exige que sobreviva a la llamada.
GUARDA_CF="${CHECK_FAILED}"; GUARDA_V="${VERDICTS}"; GUARDA_OUT4="${OUT_LOCAL}"
OUT_LOCAL="${BANCO}/veredicto"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
printf 'ack 100 2026-09-09T00:00:00Z\n' > "${OUT_LOCAL}/en-vuelo.txt"
# SE MONTA LA SECUENCIA DE LA FASE Y NO EL ESTADO SUELTO, y la primera version de
# esta fila miraba `CHECK_FAILED` DESPUES de la llamada, que es una expectativa
# imposible: `veredicto_en_vuelo` abre su PROPIO bloque, asi que ese contador ya no
# es el de quien llama. Lo que hay que medir es el VEREDICTO: que P2.cut.fired
# quede en `fail` con la llamada detras. Es la misma leccion una vez mas, y esta vez
# cometida al escribir la fila que la vigila.
VERDICTS=" "; begin_check
fail "P2.cut.fired: un FAIL de mentira, para ver si sobrevive" >/dev/null 2>&1
end_check P2.cut.fired
veredicto_en_vuelo >/dev/null 2>&1
roja 17gb "fail|pass" "$(verdict_of P2.cut.fired)|$(verdict_of P2.cut.envuelo)" "en la secuencia de la fase, el veredicto de P2.cut.fired queda en FAIL y el de P2.cut.envuelo en pass: son dos bloques y no uno, y con la llamada dentro el primero salia pass con sus propios FAIL impresos encima"
OUT_LOCAL="${GUARDA_OUT4}"; CHECK_FAILED="${GUARDA_CF}"; VERDICTS="${GUARDA_V}"

# B2: el conteo de entradas, medido de verdad sobre directorios VACIOS
mkdir -p "${BANCO}/vacios/data" "${BANCO}/vacios/logs" "${BANCO}/vacios/data-mutante"
roja 17gc "3|0" "$(cd "${BANCO}/vacios" && ls -A data logs data-mutante 2>/dev/null | grep -c .)|$(cd "${BANCO}/vacios" && find data logs data-mutante -mindepth 1 2>/dev/null | grep -c .)" "sobre TRES directorios VACIOS, ls -A con varios operandos da TRES por sus cabeceras y find -mindepth 1 da CERO: con el primero, la precondicion del preflight fallaba en un host impecable, siempre, con el mensaje mas caro del diseno"
printf 'x\n' > "${BANCO}/vacios/data/algo"
fila 17gd "1" "$(cd "${BANCO}/vacios" && find data logs data-mutante -mindepth 1 2>/dev/null | grep -c .)" "y con una entrada de verdad dentro cuenta UNA, que es la mitad sin la cual la de arriba pasaria con un contador que dijera siempre cero"
rm -rf -- "${BANCO}/vacios"
roja 17ge "si|no" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'find naylamp/data naylamp/logs naylamp/data-mutante -mindepth 1' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'ls -A naylamp/data naylamp/logs' && echo si || echo no)" "y el preflight cuenta con find y ya no con ls -A"

# B3: el lider se pregunta a los TRES y con cota
roja 17gf "si|si" "$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'for h in "${hosts\[@\]}"' && printf '%s' "${CUERPO_CALIENTE}" | grep -q 'lo escribio el host' && echo si || echo no)|$(printf '%s' "${CUERPO_CALIENTE}" | grep -q 'NO ha elegido lider en 20 s, preguntando a los TRES' && echo si || echo no)" "el lider se pregunta a los TRES y con cota: solo el nodo que GANA escribe esa linea, asi que preguntar solo al host 1 daba un rojo que nombra la causa equivocada dos de cada tres veces, sobre una flota sana y con las tres encendidas"

# ---- 17ha y 17hb: LOS DOS SITIOS QUE LA GUARDA NUEVA DESTAPO -----------------
#
# `gate/sitio-test.sh` entra hoy con el predicado de la clase que mordio CINCO
# veces en un dia, y su primera corrida encontro mas de lo que el censo a mano
# habia visto: `seal_artifact`, `completa_el_sello`, `retira_running`,
# `emit_final_verdict` y `pliega_en_vuelo_sin_ack` tienen su sitio DESNUDO dentro
# de `al_salir`, y **ninguna fila corria `al_salir`**. Es exactamente donde el
# mutante que quita el `kill` del escritor en vuelo salio MUDO.
#
# LA FILA CORRE LA TRAMPA ENTERA, en un subshell porque `al_salir` termina en
# `exit`, y mira lo que deja: el artefacto sellado, el sello TERMINADO con su
# `closed:`, el marcador retirado y el bloque de veredictos impreso. Con eso, un
# cambio en el ORDEN de esas seis llamadas -que es lo unico que el sitio decide-
# cae aqui y no en la primera corrida de fierro.
GUARDA_OUT5="${OUT_LOCAL}"; GUARDA_MAN5="${MANIFEST}"; GUARDA_FIERRO5="${ES_FIERRO}"
GUARDA_RUN5="${RUN_STARTED}"; GUARDA_EMIT5="${EMITIDO}"; GUARDA_V5="${VERDICTS}"
GUARDA_EXP5="${EXPECTED}"; GUARDA_RID5="${RUN_ID}"; GUARDA_OD5="${OUT_DIR}"
OUT_DIR="${BANCO}/trampa"; RUN_ID="20260909T000000Z-1"
OUT_LOCAL="${OUT_DIR}/p2-${RUN_ID}"
rm -rf -- "${OUT_DIR}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"
printf 'put 1 %s confirmed\n' "$(vec_for 1)" > "${MANIFEST}"
printf 'algo que la corrida escribio\n' > "${OUT_LOCAL}/hygiene.log"
ES_FIERRO=1; RUN_STARTED=1; EMITIDO=1; SELLO_ESCRITO_AQUI=0
EXPECTED="P2.build"; VERDICTS=" P2.build=pass "
SUBCOMANDO=all; ARRANCO_A="2026-09-09T00:00:00Z"
escribe_running
# UN ESCRITOR EN VUELO DE MENTIRA, para poder exigir que la trampa lo MATE. El
# barrido lo pidio: quitandole a al_salir el kill, esta fila seguia verde porque
# miraba lo que la trampa DEJA y no lo que la trampa PARA. Un proceso que sobrevive
# a la trampa sigue escribiendo en el manifiesto detras del sello.
sleep 120 &
PID_EN_VUELO=$!
SALIDA_TRAMPA="$( al_salir 2>&1 )"
VIVE_TRAS_LA_TRAMPA="$(kill -0 "${PID_EN_VUELO}" 2>/dev/null && echo si || echo no)"
kill "${PID_EN_VUELO}" 2>/dev/null || true
fila 17ha "si|1|no|no" "$([ -e "${OUT_LOCAL}/SEALED" ] && echo si || echo no)|$(grep -c '^closed:' "${OUT_LOCAL}/SEALED" 2>/dev/null || echo 0)|$([ -e "${OUT_LOCAL}/RUNNING" ] && echo si || echo no)|${VIVE_TRAS_LA_TRAMPA}" "la trampa de salida, corrida ENTERA: deja el artefacto SELLADO, el sello TERMINADO con su linea closed, y el marcador RETIRADO. Ninguna fila corria al_salir, que es el sitio de cinco funciones que este banco si prueba una a una"
roja 17hb "0" "$(ls -1 "${OUT_LOCAL}" 2>/dev/null | grep -c '^SEALED\.a-medias$')" "y no deja ningun SEALED.a-medias dentro de un artefacto que el sello protege de make clean: el orden de esas seis llamadas es lo unico que el sitio decide, y sin esta fila un cambio en el orden solo se veria en la primera corrida de fierro"
rm -rf -- "${OUT_DIR}"
OUT_DIR="${GUARDA_OD5}"; RUN_ID="${GUARDA_RID5}"; OUT_LOCAL="${GUARDA_OUT5}"
MANIFEST="${GUARDA_MAN5}"; ES_FIERRO="${GUARDA_FIERRO5}"; RUN_STARTED="${GUARDA_RUN5}"
EMITIDO="${GUARDA_EMIT5}"; VERDICTS="${GUARDA_V5}"; EXPECTED="${GUARDA_EXP5}"
SELLO_ESCRITO_AQUI=1; CHECK_FAILED=0

# ---- 17hc: EL DESPACHO POR ES_FIERRO, que es el sitio de las tres fases de fierro
#
# `phase_hygiene`, `phase_cut` y `phase_red` no hacen mas que elegir rama por
# `ES_FIERRO`, y esa eleccion es su unico contenido. Las filas que corren
# `phase_hygiene_fierro` prueban la fase; esta prueba que se llegue a ella.
GUARDA_FIERRO6="${ES_FIERRO}"
ES_FIERRO=1
DESPACHO="$( set +e; phase_hygiene 2>&1 )"
ES_FIERRO="${GUARDA_FIERRO6}"
# SE PREGUNTA POR UNA FRASE QUE SOLO IMPRIME UNA DE LAS DOS RAMAS, y por presencia
# y no por cuenta: contar apariciones dentro de la salida de una fase es una cifra
# que se mueve cada vez que alguien anade una linea, y entonces el banco se pone
# rojo por trabajar. Es la tercera vez hoy que lo corrijo en la misma direccion.
roja 17hc "si|no" "$(printf '%s' "${DESPACHO}" | grep -q 'sane fleet is at' && echo si || echo no)|$(printf '%s' "${DESPACHO}" | grep -q 'is still running' && echo si || echo no)" "con ES_FIERRO=1, phase_hygiene DESPACHA a su rama de fierro y no corre la del ensayo: es el mismo circuito que el del banner, y las tres fases de fierro cuelgan de el"
CHECK_FAILED=0

# ---- 17ia y 17ib: LA FASE DEL CORTE, CORRIDA ENTERA --------------------------
#
# LA GUARDA `gate/sitio-test.sh` DEJO ESTAS TRES AL DESCUBIERTO y no se pudieron
# declarar: `escritor_en_vuelo`, `pliega_en_vuelo_sin_ack` y `veredicto_en_vuelo`
# tienen su unico sitio DESNUDO dentro de `phase_cut_fierro`, y ese sitio decide
# lo que ninguna de sus filas puede ver: en que ORDEN se llaman, si el escritor
# arranca antes del corte, si el `wait` espera solo a los cortes, y si el veredicto
# queda fuera del bloque de `P2.cut.fired`. Es donde el mutante que quita la espera
# del primer ack salio MUDO.
#
# SE CORRE LA FASE DE VERDAD, con el corte SIMULADO sobre la flota de mentira, y
# eso cuesta unos segundos en vez de los 360 que costaria dejar que sus dos esperas
# se agoten. Un ayudante en segundo plano hace lo que haria el corte: marca los
# tres hosts muertos, les cambia el boot id, deja el testigo en su semilla, y los
# devuelve. Nada de esto enciende nada: los tres hosts son directorios.
GUARDA_OUT7="${OUT_LOCAL}"; GUARDA_MAN7="${MANIFEST}"; GUARDA_FIERRO7="${ES_FIERRO}"
GUARDA_V7="${VERDICTS}"; GUARDA_CF7="${CHECK_FAILED}"; GUARDA_MAXV7="${EN_VUELO_MAX}"
OUT_LOCAL="${BANCO}/fasecorte"; rm -rf -- "${OUT_LOCAL}"; mkdir -p "${OUT_LOCAL}"
MANIFEST="${OUT_LOCAL}/manifest.txt"; : > "${MANIFEST}"
ES_FIERRO=1; VERDICTS=" "; EN_VUELO_MAX=6
: > "${BANCO}/estado/1.acepta"
cat > "${BANCO}/casa/1/naylamp/bin/naylampd" <<'FALSO'
#!/bin/sh
[ -e "${BANCO_ESTADO}/1.acepta" ] || exit 7
exit 0
FALSO
chmod +x "${BANCO}/casa/1/naylamp/bin/naylampd"

# Y EL NODO 2 NO PUEDE ARMAR, a proposito y en esta misma corrida. El stub de ssh
# le niega el UNICO viaje que hace un `>>` sobre el testigo, o sea el armado, y le
# deja pasar la siembra. La primera version de esta linea puso el testigo como
# DIRECTORIO y no valia: eso rompe la SIEMBRA, que va antes y tiene su propia
# salida temprana, asi que la fase se iba sin llegar nunca al armado y las tres
# columnas salian en no por la razon equivocada. Es una de las dos causas que el
# comentario de la fase nombra -un ssh cortado o un disco lleno- y hasta ahora
# ninguna fila la ejercia: `testigo_arma` se probaba SOLO, en las filas 22 a 25,
# y el SITIO donde su fallo tiene que recordarse por nodo no lo recorria nadie.
# Ese hueco dejo entrar un defecto el 9 de septiembre de 2026, en el arreglo mismo
# que paralelizo el armado: al sacar la llamada de la condicion de un `if` perdio
# la exencion de errexit, y con un arma que fallaba el gate moria entero en vez de
# anotar el nodo y seguir. Con esta linea puesta, esa version no llega al final.
: > "${BANCO_ESTADO}/2.no-arma"

# El ayudante que hace de corte. Los numeros son cortos a proposito: lo que esta
# fila mide es el RECORRIDO de la fase, no cuanto tarda una VM en volver.
(
	sleep 3
	for n in 1 2 3; do : > "${BANCO_ESTADO}/${n}.muerto"; done
	sleep 2
	for n in 1 2 3; do
		printf 'dddd-eeee-ffff-000%s\n' "${n}" > "${BANCO_CASA}/${n}/proc/sys/kernel/random/boot_id"
		head -c 4096 /dev/zero > "${BANCO_CASA}/${n}/naylamp/testigo-corte.bin" 2>/dev/null || true
		rm -f -- "${BANCO_ESTADO}/${n}.muerto"
	done
) &
AYUDANTE=$!
# Y LA LLAMADA ENTRA POR `phase_cut` Y NO POR `phase_cut_fierro`, que es UNA
# palabra y cubre un sitio entero. Hasta la cuarta vuelta esta linea llamaba a la
# rama de fierro DIRECTAMENTE, y entonces el DESPACHO por ES_FIERRO que hay en
# `phase_cut` no lo ejercia nadie: gate/sitio-test.sh lo tenia DECLARADO como
# cubierto "por la fila del despacho", y esa fila, la 17hc, es la de phase_hygiene.
# Una exencion escrita con una razon falsa es peor que ninguna, porque apaga la
# guarda en el sitio exacto donde hacia falta. Entrando por el despacho la fila
# recorre lo mismo y ademas comprueba a que rama fue, y la declaracion sobra.
# Y NO SE CAPTURA CON `$( )`, que es una SUBCAPA y se lleva los veredictos. La
# fase registra en `VERDICTS`, que es una variable, y una sustitucion de orden corre
# en un proceso hijo: al cerrarse, todo lo que la fase escribio ahi se pierde. Se
# midio el 9 de septiembre de 2026 imprimiendo `VERDICTS` justo detras de la
# captura y saliendo el espacio con el que se habia inicializado. Lo que eso
# significaba es peor que un veredicto perdido: la segunda mitad de la 17ib
# preguntaba si P2.cut.envuelo quedaba en `pass` o en `none`, y `verdict_of` sobre
# una variable vacia devuelve `none` SIEMPRE, por su rama por defecto. O sea que
# esa columna salia verde pasara lo que pasara, en una fila cuyo propio comentario
# de arriba explica que una asercion que admite los dos desenlaces no vigila nada.
# Se redirige a fichero y la fase corre en ESTA capa, que es como el banco ya
# ejerce phase_hygiene_fierro y al_salir.
set +e
phase_cut > "${BANCO}/fasecorte.salida" 2>&1
set -e
SALIDA_CORTE="$(cat "${BANCO}/fasecorte.salida")"
wait "${AYUDANTE}" 2>/dev/null || true
# LA NEGACION DEL ARMADO SE RETIRA AQUI, y olvidarla puso roja la fila 25 tres
# minutos: esa fila arma el nodo 2 de verdad para medir su tamano, y con la
# bandera puesta media 4096 en vez de 69632. Un montaje que no se deshace no es
# un montaje, es un cambio de entorno para todo lo que venga detras.
rm -f -- "${BANCO_ESTADO}/2.no-arma"
rm -f -- "${BANCO}/estado/1.acepta"
printf 'binario sano, igual en las tres\n' > "${BANCO}/casa/1/naylamp/bin/naylampd"

# LA CUARTA MITAD LA PIDIO EL BARRIDO DE MUTANTES, no yo: quitandole a la fase la
# espera del primer ack, esta fila seguia verde, porque miraba que el escritor
# ARRANCARA y no que la fase le ESPERARA. Arrancar y esperar son dos cosas, y la
# que decide si hay poblacion en vuelo con edad casi cero es la segunda.
#
# Y LA PRIMERA VERSION DE ESTA MITAD SEGUIA SIN MORDER, porque acepto las DOS ramas
# con una alternancia: el mutante caia en la otra y pasaba. Una asercion que admite
# los dos desenlaces de la decision que vigila no vigila nada. En este montaje el
# escritor SI ackea -seis, medido- asi que se exige la rama positiva y solo esa.
fila 17ia "si|si|si|si|no" "$(printf '%s' "${SALIDA_CORTE}" | grep -q 'starting the in-flight writer' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'has at least one acknowledged write' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'cutting the THREE' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'boot id after' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'cutting nodes 1 and 2 with kill -9' && echo si || echo no)" "phase_cut_fierro se recorre ENTERA contra la flota de mentira, ENTRANDO POR EL DESPACHO: arranca el escritor en vuelo, corta, y llega a leer los boot id de vuelta. Es el SITIO de tres funciones que este banco prueba una a una y que nadie ejercia, y la quinta columna exige que con ES_FIERRO=1 no se haya colado la rama del ensayo, que corta dos nodos con kill -9 en vez de tres con sysrq"
# Y NO LLEVA UN `case` DENTRO DE LA SUSTITUCION, que es la clausula 31 y la
# segunda version de esta linea la cometio: un `case` dentro de `$( )` es un error
# de sintaxis en el bash 3.2 de esta maquina, porque el parser toma el `)` del
# patron por el cierre de la sustitucion. Y no muere: el error va a stderr, la
# sustitucion devuelve el texto suelto de detras del parentesis, y la fila salio
# roja mostrando medio `esac` como si fuera un veredicto.
#
# LA 17ib PREGUNTA DOS COSAS QUE PUEDEN SALIR MAL, y la primera version pregunto
# una que no podia: comparaba el veredicto contra "distinto de none O igual a
# none", que es verdad siempre. Una fila que no puede fallar no es una fila.
roja 17ib "si|pass" "$(printf '%s' "${SALIDA_CORTE}" | grep -q 'en vuelo:' && echo si || echo no)|$(verdict_of P2.cut.envuelo)" "y en el mismo recorrido lee la frontera del escritor y REGISTRA el veredicto en vuelo: el ORDEN de esas seis llamadas es lo unico que el sitio decide, y sin esta fila un cambio en el orden solo se veria en la primera corrida de fierro. La segunda columna exige PASS y no una alternancia: en este montaje el escritor ackea cuatro veces medidas, asi que none seria un defecto y no una rama legitima"

# ---- 17ic: EL PRESUPUESTO DE LA VENTANA, medido por la ESTRUCTURA -------------
#
# LA CUARTA VUELTA DEL LECTOR ENCONTRO QUE LA VENTANA NO CABIA EN SU COTA, y el
# defecto no lo metio quien escribio la fase: lo metieron las CORRECCIONES de la
# tercera vuelta. La ventana va de armar el testigo a disparar el corte y su cota
# es VENTANA_MAX, cinco segundos, derivada de commit=30. Dentro de esa ventana la
# tercera vuelta metio dos gastos nuevos sin tocar la cota: el fsync de directorio
# en la siembra, y hasta tres segundos esperando el primer ack del escritor en
# vuelo. Con las tres armas EN SERIE contra Azure, el presupuesto se pasaba de
# cinco antes de que el corte saliera. Y no falla ruidosamente: `ventana_dentro`
# da falso y P2.cut.bytes sale NOT RUN, o sea que la lectura central de la fase
# -si el corte fue seco- se anula sola sobre una flota sana.
#
# ESTA FILA MIDE ESTRUCTURA Y NO PROSA, que es lo que la clase de esta semana
# obliga: se saca el NUMERO DE LINEA de las dos cosas dentro del cuerpo de la
# funcion y se exige el orden. Una fila que preguntara si el comentario dice
# "en paralelo" seguiria verde el dia que alguien devolviera las armas a la serie
# y dejara el parrafo puesto. Las tres columnas caen si se deshace la correccion:
# volver a poner el escritor detras del bucle tumba la primera, quitar el `&` de
# las armas tumba la segunda, y quitar el `wait` tumba la tercera, que es la que
# impide la version veloz y falsa: armar al fondo sin juntar cortaria antes de
# que las semillas estuvieran puestas.
# Y EL CUERPO SE LEE SIN COMENTARIOS, que no es limpieza: la primera version de
# la 17ic salia VERDE por su propia prosa. El comentario que explica el arreglo
# CITA la forma rota, `( testigo_arma "$n"; echo $? > ... ) &`, y el grep de la
# segunda columna casaba esa cita en vez del codigo. O sea que la fila escrita
# para vigilar el armado se habria quedado verde el dia que alguien devolviera el
# armado a la forma rota, porque el parrafo que la describe seguiria puesto. Es
# la misma clase que este banco lleva un dia entero persiguiendo, cometida DENTRO
# de la fila que la persigue, y la caza fue el censo de mutantes: 17ic no aparecia
# en la lista de filas que algun mutante hace caer.
CUERPO_CORTE_F="$(awk '/^phase_cut_fierro\(\) \{/,/^\}$/' "${GATE_DIR}/p2.sh" | grep -v '^[[:space:]]*#')"
roja 17ic "si|si|si" "$(L_ESC="$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -n 'escritor_en_vuelo &' | head -1 | cut -d: -f1)"; L_ARM="$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -n 'testigo_arma "\$n"' | head -1 | cut -d: -f1)"; [ -n "${L_ESC}" ] && [ -n "${L_ARM}" ] && [ "${L_ESC}" -lt "${L_ARM}" ] && echo si || echo no)|$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -qE '^[[:space:]]*\( if testigo_arma "\$n";.*\) &$' && echo si || echo no)|$(printf '%s\n' "${CUERPO_CORTE_F}" | grep -q 'wait \${pids_arma}' && echo si || echo no)" "el escritor en vuelo arranca ANTES del bucle de armado, las tres armas van al fondo CON su llamada dentro de un if, que es su exencion de errexit, y se las junta con wait antes de cortar: asi la espera del primer ack se solapa con las armas en vez de sumarse detras, y dentro de la ventana queda UN viaje ssh de armar mas el abanico del corte, que ya iba en paralelo"

# ---- 17id: UN ARMA QUE FALLA NO SE LLEVA LA CORRIDA --------------------------
#
# ESTA FILA LEE LA MISMA CAPTURA QUE LA 17ia y no cuesta un segundo mas: el nodo 2
# tiene su testigo puesto como directorio arriba, asi que en ese mismo recorrido
# de `phase_cut` hay UN arma que falla y DOS que arman. Las tres columnas son el
# circuito entero del caso degradado: se anota el nodo por su numero, la fase
# SIGUE VIVA hasta disparar el corte, y el veredicto del corte queda registrado.
#
# LA SEGUNDA COLUMNA ES LA QUE VALE Y ES LA QUE NO EXISTIA. Bajo `set -e`, una
# llamada que falla fuera de una condicion mata la subcapa que la contiene, y si
# esa subcapa esta al fondo, el `wait` que la recoge devuelve distinto de cero y
# se lleva el gate. La version de este arreglo escrita media hora antes hacia
# exactamente eso: la corrida de fierro moria en el armado, sin `fail`, sin corte
# y sin veredicto, o sea que la sesion se perdia entera y el artefacto no decia
# por que. Preguntar solo por el `fail` del nodo 2 no lo habria cazado, porque en
# esa version el `fail` tampoco se escribia: lo que lo caza es exigir que la fase
# LLEGUE a una linea posterior. Es la diferencia entre mirar la pieza y mirar que
# la corriente sale por el otro lado.
roja 17id "si|si|fail" "$(printf '%s' "${SALIDA_CORTE}" | grep -q 'node 2 would not arm its canary' && echo si || echo no)|$(printf '%s' "${SALIDA_CORTE}" | grep -q 'cutting the THREE' && echo si || echo no)|$(verdict_of P2.cut.fired)" "con el stub negandole al nodo 2 el unico viaje que hace un >> sobre el testigo, su arma falla de verdad y la siembra pasa: se anota P2.cut.fired contra ESE nodo, la fase sobrevive y dispara el corte, y el veredicto sale FAIL y no none. Sin la exencion de errexit dentro de la subcapa del armado paralelo las tres columnas caen a la vez, porque el gate muere antes de escribir ninguna"

# ---- 17ie: EL ARMADO PARALELO, BAJO errexit DE VERDAD -------------------------
#
# LA 17id NO PODIA CAZAR ESTO Y SE MIDIO, no se supuso. Se deshizo el arreglo a
# mano -se le quito el `if` a la subcapa- y la 17id siguio VERDE. La razon es que
# la captura de la fase va entre `set +e` y `set -e`, para que un retorno distinto
# de cero de la fase no se lleve el banco; con errexit apagado, la subcapa que
# tenia que morir no muere y el defecto no se manifiesta. Un banco que apaga la
# guarda que quiere medir mide otra cosa.
#
# ASI QUE EL TROZO SE SACA DEL GUION Y SE CORRE EN UN HIJO CON `set -euo pipefail`
# de verdad, con un `testigo_arma` que siempre falla. El trozo se EXTRAE, no se
# copia: va de la linea que declara `pids_arma` al `wait` que la recoge, dentro del
# cuerpo de phase_cut_fierro, asi que el dia que alguien lo reescriba esta fila
# corre lo reescrito. Con el `if` puesto, el hijo llega a su ultima linea; sin el,
# errexit mata la subcapa antes del `echo`, el `wait` devuelve distinto de cero y
# el hijo muere sin imprimir nada, que es exactamente lo que le pasaria a la
# corrida de fierro en el minuto tres de una sesion de VMs.
TROZO_ARMA="$(printf '%s\n' "${CUERPO_CORTE_F}" | awk '/pids_arma=""/,/wait \$\{pids_arma\}/')"
mkdir -p "${BANCO}/errexit-arma"
{
	printf '%s\n' 'set -euo pipefail' 'NODE_IDS=(1 2 3)'
	printf 'OUT_LOCAL=%s\n' "'${BANCO}/errexit-arma'"
	printf '%s\n' 'testigo_arma() { return 1; }' 'fail() { :; }' 'armar() {'
	printf '%s\n' "${TROZO_ARMA}"
	printf '%s\n' '}' 'armar' 'echo SOBREVIVE'
} > "${BANCO}/errexit-arma.sh"
roja 17ie "1|3" "$(bash "${BANCO}/errexit-arma.sh" 2>/dev/null | grep -c SOBREVIVE)|$(ls -1 "${BANCO}/errexit-arma" 2>/dev/null | grep -c '^arma-rc-')" "el trozo del armado paralelo, EXTRAIDO del guion y corrido en un hijo con set -euo pipefail y un testigo_arma que siempre falla: llega a su ultima linea y deja los TRES rc escritos. Sin el if dentro de la subcapa, errexit la mata antes del echo, el wait devuelve distinto de cero, y el hijo no imprime nada ni escribe ningun rc"




# LA FLOTA DE MENTIRA SE DEVUELVE A SU ESTADO, y esto es una correccion medida: el
# ayudante cambia los boot id para que el corte se note, y sin devolverlos la fila
# 18, que los lee mas abajo, salia roja por un estado que le dejo puesto otra fila.
# Una fila que le mueve el suelo a las de detras es peor que una que no mide nada.
for n in 1 2 3; do
	printf 'aaaa-bbbb-cccc-000%s\n' "${n}" > "${BANCO}/casa/${n}/proc/sys/kernel/random/boot_id"
	rm -f -- "${BANCO}/estado/${n}.muerto"
done
rm -f -- "${BANCO}/casa/1/naylamp/testigo-corte.bin" "${BANCO}/casa/2/naylamp/testigo-corte.bin" "${BANCO}/casa/3/naylamp/testigo-corte.bin"
rm -rf -- "${OUT_LOCAL}"
OUT_LOCAL="${GUARDA_OUT7}"; MANIFEST="${GUARDA_MAN7}"; ES_FIERRO="${GUARDA_FIERRO7}"
VERDICTS="${GUARDA_V7}"; CHECK_FAILED="${GUARDA_CF7}"; EN_VUELO_MAX="${GUARDA_MAXV7}"

# ---- 18 a 21: las primitivas de fierro contra el stub ------------------------
fila 18 "aaaa-bbbb-cccc-0002" "$(boot_id_de 2)" "boot_id_de lee el boot id por el canal de tres estados"
: > "${BANCO}/estado/2.muerto"
roja 19 "2" "$( boot_id_de 2 >/dev/null 2>&1; echo $? )" "un host que no contesta devuelve 2, y NO una cadena vacia que pase por respuesta"
rm -f -- "${BANCO}/estado/2.muerto"
fila 20 "si" "$(ask_on 1 'true' && echo si || echo no)" "ask_on contesta SI sobre el host vivo"
fila 21 "176" "$(sysrq_de 1)" "sysrq_de trae el valor del host"

# ---- 22 a 25: el tercer testigo, que es lo que mide el corte ------------------
testigo_siembra 1 >/dev/null 2>&1
fila 22 "${TESTIGO_SEMILLA}" "$(testigo_tamano 1)" "sembrado y sincronizado: ${TESTIGO_SEMILLA} bytes durables por construccion"
testigo_arma 1 >/dev/null 2>&1
fila 23 "$(( TESTIGO_SEMILLA + TESTIGO_COLA ))" "$(testigo_tamano 1)" "armado: la cola sin sincronizar esta encima"
# un corte SECO se lleva la cola: se simula truncando a la semilla
head -c "${TESTIGO_SEMILLA}" /dev/zero > "${BANCO}/casa/1/${TESTIGO_REMOTO}"
fila 24 "${TESTIGO_SEMILLA}" "$(testigo_tamano 1)" "tras un corte seco vuelve a la semilla, que es la senal que el gate lee"
roja 25 "$(( TESTIGO_SEMILLA + TESTIGO_COLA ))" "$(testigo_siembra 2 >/dev/null 2>&1; testigo_arma 2 >/dev/null 2>&1; testigo_tamano 2)" "un testigo que vuelve ENTERO significa que ahi no se corto nada, y ese es el caso que no puede leerse como verde"

# ---- 26 a 31: LAS DECISIONES, llamando a las funciones DE gate/p2.sh ---------
#
# Estas filas eran aritmetica sobre literales escritos aqui, y un lector lo midio
# el 7 de septiembre de 2026: `cambiados=2; [ "${cambiados}" -ge 2 ]` demuestra
# que dos es al menos dos, no que este guion haga nada. Rebobinada la decision en
# p2.sh, las diez seguian verdes. Ahora las decisiones son funciones nombradas
# EN p2.sh y estas filas llaman a esas, asi que rebobinar el objeto pone la fila
# roja, que es lo unico que hace util a un banco.
fila 26 "2" "$(mayoria_de 3)" "mayoria_de(3) de p2.sh da 2, igual que cluster.Config.Quorum() en engine/cluster/config.go:87"
fila 27 "pasa" "$(faithful_suficiente 2 3 && echo pasa || echo cae)" "faithful_suficiente(2,3): dos copias frias fieles PASAN, la tercera puede no haber persistido"
roja 28 "cae" "$(faithful_suficiente 0 3 && echo pasa || echo cae)" "faithful_suficiente(0,3) CAE, que es donde el mutante sin barrera se queda"
roja 29 "cae" "$(faithful_suficiente 1 3 && echo pasa || echo cae)" "faithful_suficiente(1,3) tambien CAE: la mayoria no se relaja hasta volverse decorativa"

# ---- 30 y 31: la ventana, llamando a ventana_dentro de p2.sh ------------------
fila 30 "dentro" "$(ventana_dentro 1.2 && echo dentro || echo fuera)" "ventana_dentro(1.2) con la cota en ${VENTANA_MAX} s"
roja 31 "fuera" "$(ventana_dentro 31.0 && echo dentro || echo fuera)" "ventana_dentro(31.0) queda FUERA: con la raiz en commit=30 el diario pudo volcar la cola"

# ---- 32 a 35: LOS MUTANTES. Cada decision, rebobinada a lo que era ------------
echo
echo "-- mutantes: cada uno rebobina una decision del 7 de septiembre de 2026 --"

# 32: lineas_listening rebobinada al || echo 0
viejo_listening() { grep -c 'listening' "${FLEET}/node$1.log" 2>/dev/null || echo 0; }
roja 32 "2" "$(viejo_listening 1 | wc -l | tr -d ' ')" "MUTANTE: con el || echo 0 la funcion devuelve DOS lineas y la comparacion revienta"

# 33 y 33b: entry_log_bytes rebobinada a la forma fail-open.
#
# LA PRIMERA VERSION DE ESTA FILA MEDIA OTRA COSA, y lo cazo un lector: montaba
# el fichero ilegible con un enlace CIRCULAR, para el que `[ -e ]` es falso, asi
# que el `continue` saltaba y la linea de la aritmetica NO SE EJECUTABA. La fila
# salia verde por el salto y no por la sustitucion vacia, que es justo el defecto
# que dice rebobinar. Es un caso del error que este banco existe para cazar,
# dentro del banco. Ahora hay dos filas y cada una monta su caso:
#   33  el nombre existe y no resuelve, que es lo que el `-L` de p2.sh caza
#   33b el fichero SI resuelve y `stat` falla igualmente, que es el unico montaje
#       en el que la aritmetica llega a correr y se ve el operando vacio
viejo_bytes() {
	local n="$1" t=0 f
	for f in "${FLEET}/node${n}/data"/raft-*.log; do
		[ -e "${f}" ] || continue
		t=$(( t + $(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}" 2>/dev/null) )) 2>/dev/null
	done
	printf '%d' "${t}"
}
roja 33 "0" "$(viejo_bytes 2 2>/dev/null)" "MUTANTE: la forma vieja devuelve 0 sobre el segmento que no resuelve, o sea 'el log encogio'"

# El stub de stat sale 1 SIEMPRE, con el fichero presente y legible, que es la
# unica forma de que la sustitucion vuelva vacia y la aritmetica se ejecute.
mkdir -p "${BANCO}/bin-stat"
printf '#!/bin/sh\nexit 1\n' > "${BANCO}/bin-stat/stat"
chmod +x "${BANCO}/bin-stat/stat"
mkdir -p "${FLEET}/node3/data"
head -c 77 /dev/zero > "${FLEET}/node3/data/raft-1.log"
salida_33b="$(PATH="${BANCO}/bin-stat:${PATH}" bash -c '
	set -euo pipefail
	t=0
	for f in "'"${FLEET}"'/node3/data"/raft-*.log; do
		[ -e "${f}" ] || continue
		t=$(( t + $(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}" 2>/dev/null) ))
	done
	printf "%d" "${t}"
	echo " y-el-guion-siguio-vivo"' 2>/dev/null)"
roja 33b "0 y-el-guion-siguio-vivo" "${salida_33b}" "MUTANTE: con stat fallando de verdad, la aritmetica revienta en stderr, t conserva su valor y el guion SIGUE con rc 0; eso es el fail-open que set -e no caza"
# El `set +e` va porque p2.sh trae `set -euo pipefail` consigo al cargarse, y sin
# el la propia funcion que devuelve 2, que es lo que esta fila quiere ver, mata
# la subshell antes del `echo $?`. La primera version de esta fila abortaba el
# banco entero ahi, o sea que la fila escrita para medir un fail-open se moria
# por el modo estricto del objeto que estaba midiendo.
salida_33c="$(PATH="${BANCO}/bin-stat:${PATH}" bash -c 'source "'"${GATE_DIR}"'/p2.sh" >/dev/null 2>&1; set +e; FLEET="'"${FLEET}"'"; entry_log_bytes 3 >/dev/null 2>&1; echo $?' 2>/dev/null)"
fila 33c "2" "${salida_33c}" "y la forma de hoy, en el MISMO montaje, devuelve 2 en vez de un total corto"

# 34 y 35: el umbral del corte. La roja rebobina corte_completo a un umbral de
# dos, escribiendola aqui como estaba en el arbol; la verde llama a la DE p2.sh.
corte_completo_viejo() { [ "$1" -ge 2 ]; }
roja 34 "acepta" "$(corte_completo_viejo 2 3 && echo acepta || echo rechaza)" "MUTANTE: con umbral de DOS, dos boot id cambiados bastan y la superviviente cura a las otras"
fila 35 "rechaza" "$(corte_completo 2 3 && echo acepta || echo rechaza)" "corte_completo(2,3) de p2.sh RECHAZA: la decision del 7 de septiembre de 2026 exige las tres"
fila 36 "acepta" "$(corte_completo 3 3 && echo acepta || echo rechaza)" "y corte_completo(3,3) acepta, para que la fila de arriba no pase por ser siempre negativa"

# 37: faithful rebobinada a exigir las tres, contra la de p2.sh
faithful_viejo() { [ "$1" -eq "$2" ]; }
roja 37 "cae" "$(faithful_viejo 2 3 && echo pasa || echo cae)" "MUTANTE: exigir las TRES pone rojo un hardware sano, porque Raft ackea con dos"

# 38 y 39: la identidad por ruta contra la identidad por contenido, con la de p2.sh
roja 38 "no-distingue" "$(identidad_confirmada deadbeef deadbeef && echo distingue || echo no-distingue)" "identidad_confirmada con el MISMO sha no distingue: un mutante sobre el nombre sano tiene la misma ruta y el mismo contenido no"
fila 39 "distingue" "$(identidad_confirmada cafe1234 deadbeef && echo distingue || echo no-distingue)" "identidad_confirmada de p2.sh separa contenidos distintos"
roja 39b "no-distingue" "$(identidad_confirmada "" deadbeef && echo distingue || echo no-distingue)" "y una lectura VACIA no cuenta como distinta: un pid muerto no confirma nada"

# 39c a 39f: testigo_veredicto de p2.sh, sus cuatro salidas
fila 39c "seco"         "$(testigo_veredicto 4096 4096 65536)"  "testigo_veredicto: la semilla sola es un corte SECO"
fila 39d "entero"       "$(testigo_veredicto 69632 4096 65536)" "el total es ENTERO, o sea que ahi no se corto"
fila 39e "parcial"      "$(testigo_veredicto 30000 4096 65536)" "a medias sigue siendo un corte"
roja 39f "bajo-semilla" "$(testigo_veredicto 100 4096 65536)"   "por DEBAJO de la semilla sincronizada no es un corte seco: es una barrera rota bajo el sistema de ficheros"
roja 39g "ilegible"     "$(testigo_veredicto "" 4096 65536)"    "y una lectura vacia es ILEGIBLE, no cero"

# ---- 42 a 45: el estado del cliente REMOTO, que en fierro viene por el texto --
#
# En fierro el cliente corre dentro del host 1 y su codigo de salida vuelve como
# una linea, porque ssh mezcla el estado del transporte con el del programa. La
# primera version buscaba __RC__=0 EN CUALQUIER PARTE del flujo, o sea que la
# salida del propio cliente podia decidir el veredicto: un canal de estado que la
# carga puede falsificar no es un canal de estado. Se lee la ULTIMA linea entera.
cliente_estado() {
	local salida="$1" ultima rc
	ultima="$(printf '%s' "${salida}" | tail -1)"
	rc=1
	case "${ultima}" in
		__RC__=0) rc=0 ;;
		__RC__=[0-9]*) rc=1 ;;
		*) rc=2 ;;
	esac
	printf '%s' "${rc}"
}
fila 42 "0" "$(cliente_estado "$(printf 'id=1 score=0.9\n__RC__=0\n')")" "el remoto contesta y sale 0"
roja 43 "1" "$(cliente_estado "$(printf 'error\n__RC__=3\n')")" "sale distinto de cero: no committed"
roja 44 "1" "$(cliente_estado "$(printf 'id=1 texto __RC__=0 pegado\n__RC__=3\n')")" "la SALIDA lleva __RC__=0 dentro y el estado real es 3: no se deja falsificar"
roja 45 "2" "$(cliente_estado "$(printf 'a medias\n')")" "el canal se corto y no hay linea de estado: eso es ILEGIBLE, no un fallo del programa"

# ---- 40: el mutante NO aterriza en el path que mide el omnibus ----------------
fila 40 "0" "$(printf '%s' "${MUT_REMOTO}" | grep -c '^naylamp/bin/naylampd$')" "el mutante NO va a naylamp/bin/naylampd, que es lo que record_binary_digests lee en gate/omnibus.sh:589"
fila 41 "1" "$(printf '%s' "${MUT_REMOTO}" | grep -c 'naylampd-mutante')" "va a su propio nombre"

echo
echo "=============================================================================="
if [ "${OMITIDAS}" -ne 0 ]; then
	echo "${OMITIDAS} fila(s) no aplican en este entorno y no se cuentan como filas; el motivo va impreso arriba"
fi
echo "RESULTADO: ${FILAS} filas, ${ROJAS} de ellas rojas, ${FALLAS} en FALLA"
# COMPLETO SE PONE AQUI, detras del resumen y delante de la anti-vacuidad, por la
# razon escrita en los otros bancos: salir por exit 1 con COMPLETO en cero hace que
# la trampa imprima "ABORTADO antes del resumen" justo debajo del resumen.
COMPLETO=1
if [ "${FILAS}" -eq 0 ]; then
	echo "p2-iron-test: VACIO. Cero filas, asi que este banco no ha probado nada, y eso NO es un pase" >&2
	exit 1
fi
echo "LO QUE ESTE BANCO NO CUBRE, y va escrito: no enciende una VM, no dispara un"
echo "sysrq-b de verdad y no mide un corte real. Prueba los PREDICADOS del camino de"
echo "fierro y sus mutantes; la primera corrida de fierro es la que los prueba en"
echo "anger, y eso es un limite declarado y no un descuido."
echo "=============================================================================="
[ "${FALLAS}" -eq 0 ] || exit 1
exit 0
