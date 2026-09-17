#!/bin/sh
# Brazos rojos de los dos defensores de ORDEN de este arbol, disparados por
# programa: TestPowerCutSweep_EveryReplicaStillBoots, en engine/naylamp, y
# TestCrashInsideCheckpoint_AckedWritesSurvive, en engine/persist.
#
# Por que existe: esos defensores cierran tres averias de ORDEN que ningun otro
# brazo del arbol ve, y hasta el 5 de septiembre de 2026 sus mutaciones se
# aplicaban a mano. Un brazo que depende de que alguien se acuerde es DEFER-077
# en su forma pura, y estos eran sus ejemplares mas recientes.
#
# Que prueba, en una frase: que las tres mutaciones que esos defensores dicen
# cazar los ponen rojos de verdad, y que el arbol sin mutar los deja verdes.
#
# LA FILA ROJA DEL CHECKPOINT TIENE UNA RAZON PROPIA Y NO ES SIMETRIA. Es la 7 y
# el rojo del brazo del
# checkpoint DEPENDE de un segundo defecto sin defensor: Recover lee la marca
# del manifest sin comprobar que el snapshot exista. Arreglado ese, la mutacion
# del orden deja de perder datos y el brazo se queda verde sin que nadie lo
# note; medido el 5 de septiembre de 2026 poniendo las dos cosas a la vez sobre
# una copia, el guion sale con 1 y nombra su fila roja del checkpoint. O sea que
# esta fila no vigila una mutacion: vigila que el rojo siga encendido mientras el
# segundo defecto siga abierto, que es DEFER-095. El dia que se cierre, esta fila
# avisa y hay que decidir que hacer con ella en vez de descubrirlo tarde.
#
# Y por eso esta cabecera es mas larga que la de sus vecinas, medido el 5 de
# septiembre de 2026, contando desde la linea 2 hasta la primera que no es
# comentario ni blanco: 144 de 435 aqui, 40 de 199 en clean-guard-test.sh y 42
# de 217 en hook-guard-test.sh. Esa cifra propia se re-cuenta cada vez que la
# cabecera crece, que es lo que le paso a la version anterior: decia 137 de 429
# con 141 de 432 debajo cuando entro en d3247e3. Vigila dos defensores en tres paquetes en vez de un
# guion en uno, y lleva dentro una decision que se tomo una vez y que sin
# escribir se vuelve a discutir. Si algun dia sobra, lo que sobra es la
# explicacion del overlay, no el limite.
#
# EL LIMITE DEL INSTRUMENTO.
# Este guion NO muta el arbol. Usa `go test -overlay`, que sustituye ficheros en
# la COMPILACION: el compilador ve un fichero distinto y el arbol no se toca ni
# un byte. Eso es mejor que copiar el arbol, porque cuesta segundos, no deja
# residuo y no puede confundirse de directorio; y es distinto de mutar, que hay
# que decirlo: lo que se prueba es el codigo con un fichero sustituido, no un
# arbol mutado. Para lo que este brazo afirma da igual, porque la unidad de
# compilacion es la misma; para lo que afirmaria un brazo sobre el estado del
# arbol, no, y por eso no se afirma.
#
# LA ANTI-VACUIDAD, que es la mitad que un brazo rojo se juega. Un overlay que no
# prende no rompe nada: compila el arbol de siempre y el defensor sale VERDE, y
# sin una guarda eso se leeria como "la mutacion no lo puso rojo", que es lo
# contrario de lo que paso. Aqui se cierra por:
#   - el parche se ancla en TEXTO y exige encontrarlo EXACTAMENTE UNA VEZ; si el
#     fichero objetivo cambio y el ancla no aparece, o aparece dos veces, el
#     guion para y lo dice, en vez de escribir un mutante que no muta;
#   - cada mutante se compara con su original y tiene que DIFERIR;
#   - y va una fila CANARIO por delante de las rojas: un overlay que sustituye
#     el mismo fichero por uno que no compila. Si el canario compila, el overlay
#     no esta entrando y el guion para. Esa fila es la que separa "la mutacion
#     no entro" de "el defensor no la caza", que sin ella dan el mismo verde.
#
# EL SITIO SE LOCALIZA POR TEXTO Y NUNCA POR NUMERO DE LINEA. No es una
# preferencia: el 5 de septiembre de 2026, una edicion de comentario dentro de
# engine/naylamp/persist_order_test.go movio los dos mensajes de ese defensor de
# sitio sin cambiar una coma de lo que dicen. Un brazo anclado en numeros habria
# empezado a mentir ese dia. El movimiento no se puede re-derivar de la historia
# porque ocurrio antes de que el fichero entrara, y el fichero entro con el mismo
# d3247e3 que trae este guion. Las lineas concretas que la primera version de
# esta nota daba ya no describen el fichero: hoy los dos subtests salen por sus
# t.Run y no por donde la nota decia. Se deja el hecho y se retira el numero, que
# es lo que esta seccion predica.
#
# Y EL DIRECTORIO DE TRABAJO IMPORTA, medido y no supuesto. Las claves de un
# overlay se resuelven contra el directorio actual, y `.github/workflows/ci.yml`
# fija `working-directory: engine` por defecto. Con claves relativas a la raiz,
# el mismo fichero de overlay da FAIL desde la raiz y `ok naylamp/engine/naylamp
# 4.123s` desde engine/, o sea que no entra y no avisa. Este guion escribe claves
# ABSOLUTAS y ademas se planta en la raiz del repositorio. Y la razon de llevar
# las dos NO es la que la primera version de esta cabecera daba: decia que con
# una sola el fallo volvia a ser mudo, y esta MEDIDO que es falso por los dos
# lados. Con claves relativas y el cd puesto, las cuatro filas salen OK; con
# claves absolutas y sin cd desde engine/, tambien. Cada mitad basta para que el
# overlay entre. Se llevan las dos porque el cd hace falta de todos modos, ya que
# la ruta del paquete es relativa, y porque una clave absoluta no depende de
# donde lo invoquen. Y cuando faltan las DOS el fallo tampoco es mudo: lo caza el
# canario, que es para lo que esta.
#
# Las filas:
#   1. CONTROL. El arbol sin tocar deja el defensor verde. Sin esto, un rojo no
#      prueba nada: podria estar rojo por cualquier otra cosa.
#   2. CANARIO. El overlay entra de verdad, comprobado con uno que no compila.
#   3. ROJO A. Bajado el bloque de AppendEntries de (*Node).processReady por
#      detras del enmarcado de rd.Msgs y del bucle de rd.Committed, el escenario
#      catching-up se pone rojo y lockstep se queda verde. Ese reparto es parte
#      de la fila: si los dos se pusieran rojos, la mutacion estaria rompiendo
#      algo mas ancho que el orden que dice romper.
#   4. ROJO B. Publicado el hard state antes de que cruce la barrera, o sea el
#      os.Rename por delante del f.Sync() en Storage.SaveHardState, los dos
#      escenarios se ponen rojos.
#   5. CONTROL del brazo del checkpoint. La fila 1 hecha al tercer paquete:
#      TestCrashInsideCheckpoint_AckedWritesSurvive verde sobre el arbol sano.
#   6. CANARIO de engine/persist, que es la fila 2 para ese mismo paquete.
#   7. ROJO C. Movido el paso del snapshot de checkpointWith por detras del
#      manifest y de la truncacion, el brazo del checkpoint se pone rojo.
#
# LO QUE ESTE GUION HACE Y NO DEBERIA GUSTARLE A NADIE, dicho antes de que lo
# encuentre otro. Las filas 3 y 4 cierran con un grep sobre el TEXTO del error
# que el defensor imprime, y anclar en texto es justo lo que esta pasada acaba de
# quitarle al brazo rojo de quorum por la regla de DEFER-077. La diferencia que
# lo hace tolerable, y no lo hace bueno: alli era el UNICO predicado vivo, asi
# que un renombrado producia un falso VERDE; aqui es uno de cuatro conjuntos y
# lo que produce es un falso ROJO, que para a quien mide en vez de dejarlo pasar.
# Un guion de shell no tiene manera de preguntar por la identidad de un error de
# Go, asi que el arreglo de verdad seria que el defensor imprimiera un codigo
# estable y este guion lo buscara. Medido: renombrados los dos literales sin
# tocar comportamiento, las filas 3 y 4 fallan y el guion sale con 1.
#
# DONDE PARA ESTA CADENA, y va escrito para que la proxima sesion no lo vuelva a
# descubrir como duda. Este guion tiene sus guardas disparadas: el ancla muerde
# por los dos lados, cero coincidencias y dos, las dos con estado 3; el canario
# para la corrida si ningun overlay prende; y sus filas rojas fallan con los
# literales renombrados, medido en la seccion anterior. Lo que NO
# tiene es que ninguna de las tres se dispare sola. Borradas dos de las cuatro
# comprobaciones de la fila 3, medido, el guion sale con 0, imprime su linea de
# exito, y esa linea sigue afirmando que lockstep se queda verde cuando ya nadie
# lo mira.
#
# Eso NO se cierra escribiendo un guardian de este guion, y la razon es que la
# cadena no termina: al guardian le haria falta el suyo. Esta casa ya paro en el
# segundo nivel y lo hizo en los dos guiones que preceden a este.
# gate/hook-guard-test.sh no lo corre ni lo vigila nadie: el 5 de septiembre de
# 2026, git grep -n hook-guard-test devuelve dos lineas y las dos son del propio
# fichero. Y gate/clean-guard-test.sh si corre en CI, pero nada comprueba que SUS
# filas sigan mordiendo. Los tres estan en el mismo escalon y por eleccion. Lo
# que lo sostiene no es un tercer guion, es que quien toque este fichero dispare
# la fila roja a mano, y la forma medida de romperlo queda dicha: borrar dos de
# las cuatro comprobaciones de la fila 3.
#
# Uso: ./gate/order-guard-test.sh    (desde donde sea, rc=0 si todas van)
#
# No toca el repositorio: su cajon esta bajo el directorio temporal del sistema
# y lo crea y lo retira el mismo.
#
# COSTE: corre los dos defensores cinco veces, tres el de engine/naylamp y dos el
# de engine/persist, y los canarios no corren nada porque rompen la construccion.
# Las cifras, sus ejes de maquina y de carga y la razon de que ninguna lleve
# identificador de corrida estan en el comentario del paso Order guard de
# ci.yml, que es quien paga el tiempo y donde se decide si el paso se queda.

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
echo "BANCO: order-guard-test"

. "$(dirname "$0")/entorno.sh"

GO=${GO:-go}
command -v "${GO}" >/dev/null 2>&1 || { echo "test: no encuentro el binario de Go (${GO})" >&2; exit 2; }

AQUI=$(cd "$(dirname "$0")" && pwd)
RAIZ=$(cd "${AQUI}/.." && pwd)
NODE_GO="${RAIZ}/engine/naylamp/node.go"
STORAGE_GO="${RAIZ}/engine/raft/storage.go"
CHECKPOINT_GO="${RAIZ}/engine/persist/checkpoint.go"
for f in "${NODE_GO}" "${STORAGE_GO}" "${CHECKPOINT_GO}"; do
	[ -f "${f}" ] || { echo "test: no encuentro ${f}" >&2; exit 2; }
done

CAJON=$(mktemp -d "${TMPDIR:-/tmp}/order-guard-test.XXXXXX")
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
# `RESULTADO: <n> filas, <n> en FALLA`. **Y NO ES IGUAL EN LOS SIETE, que es lo
# que decia esta linea y no describia el arbol:** son SEIS con esa forma y uno,
# `gate/p2-iron-test.sh`, con un superconjunto de tres numeros,
# `RESULTADO: <n> filas, <n> de ellas rojas, <n> en FALLA`. El predicado del
# barrido acepta las dos a proposito, con un grupo opcional; la afirmacion de que
# eran siete iguales se escribio cuatro veces en el arbol y era falsa en todas.
# Desde el 8 de septiembre son OCHO bancos, con gate/sello-test.sh. Y con la
# cuenta derivada del registro y no tecleada.
REGISTRO_FILAS="${CAJON}/filas-del-banco"
: > "${REGISTRO_FILAS}"
anota_fila() { printf '%s\n' "$1" >> "${REGISTRO_FILAS}"; }
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

# El overlay se resuelve contra el directorio actual, asi que este guion corre
# desde la raiz del repositorio Y escribe claves absolutas. Con una sola de las
# dos el overlay entra igual, medido por los dos lados; se llevan las dos por lo
# que la cabecera explica.
cd "${RAIZ}"

# sustituye <fichero> <fichero-con-el-texto-viejo> <fichero-con-el-nuevo> <salida>
#
# Empareja una SECUENCIA DE LINEAS, no un numero de linea, y exige que aparezca
# exactamente una vez. Cero coincidencias significa que el fichero objetivo
# cambio y el parche ya no describe el sitio; dos significa que el ancla dejo de
# ser unica y el parche podria prender donde no toca. Las dos paran el guion.
sustituye() {
	awk -v viejo="$2" -v nuevo="$3" '
		BEGIN {
			nv = 0
			while ((getline linea < viejo) > 0) { nv++; V[nv] = linea }
			close(viejo)
			nn = 0
			while ((getline linea < nuevo) > 0) { nn++; N[nn] = linea }
			close(nuevo)
			if (nv == 0) { print "test: el texto a buscar esta vacio" > "/dev/stderr"; exit 2 }
		}
		{ nl++; L[nl] = $0 }
		END {
			casos = 0
			for (i = 1; i <= nl - nv + 1; i++) {
				ok = 1
				for (j = 1; j <= nv; j++) if (L[i + j - 1] != V[j]) { ok = 0; break }
				if (ok) { casos++; donde = i }
			}
			if (casos != 1) {
				printf "test: el ancla aparece %d veces y tiene que aparecer 1\n", casos > "/dev/stderr"
				exit 3
			}
			for (i = 1; i < donde; i++) print L[i]
			for (j = 1; j <= nn; j++) print N[j]
			for (i = donde + nv; i <= nl; i++) print L[i]
		}
	' "$1" > "$4"
}

# El bloque que la mutacion A mueve, y las dos anclas, escritos como texto.
cat > "${CAJON}/a-bloque.txt" <<'FIN'
	if len(rd.Entries) > 0 {
		if err := n.storage.AppendEntries(rd.Entries); err != nil {
			return nil, err
		}
	}

FIN
: > "${CAJON}/vacio.txt"
cat > "${CAJON}/a-ancla.txt" <<'FIN'
	for _, rs := range rd.ReadStates {
FIN
cat > "${CAJON}/a-ancla-con-bloque.txt" <<'FIN'
	if len(rd.Entries) > 0 {
		if err := n.storage.AppendEntries(rd.Entries); err != nil {
			return nil, err
		}
	}

	for _, rs := range rd.ReadStates {
FIN

# La mutacion B es un cambio de orden dentro de SaveHardState. Se escribe el
# bloque entero porque sus cadenas de error lo hacen unico, y porque la linea
# `if err := f.Sync(); err != nil {` aparece DOS veces en ese fichero y no sirve
# de ancla por si sola.
cat > "${CAJON}/b-viejo.txt" <<'FIN'
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: fsync hard state: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("raft: close hard state temp: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, hardStateFile)); err != nil {
		return fmt.Errorf("raft: replace hard state: %w", err)
	}
	return fsyncDir(s.dir)
FIN
cat > "${CAJON}/b-nuevo.txt" <<'FIN'
	if err := os.Rename(tmp, filepath.Join(s.dir, hardStateFile)); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: replace hard state: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: fsync hard state: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("raft: close hard state temp: %w", err)
	}
	return fsyncDir(s.dir)
FIN

# La mutacion C mueve el paso 1 de checkpointWith por detras de los pasos 2 y 3.
# Se escribe el bloque de los tres pasos entero porque cada uno lleva su cadena
# de error y eso lo hace unico en el fichero.
cat > "${CAJON}/c-viejo.txt" <<'FIN'
	// Step 1: snapshot to disk, atomically.
	if err := writeSnapshotWith(dir, snap, open); err != nil {
		return fmt.Errorf("persist: checkpoint snapshot: %w", err)
	}

	// Step 2: point the manifest at the snapshot's watermark, atomically.
	if err := writeManifestWith(dir, Manifest{SnapshotLSN: snapshotLSN}, open); err != nil {
		return fmt.Errorf("persist: checkpoint manifest: %w", err)
	}

	// Step 3: reclaim space by deleting fully-covered WAL segments.
	if err := truncateWALSegments(dir, snapshotLSN); err != nil {
		return fmt.Errorf("persist: checkpoint wal truncation: %w", err)
	}
FIN
cat > "${CAJON}/c-nuevo.txt" <<'FIN'
	// Step 2: point the manifest at the snapshot's watermark, atomically.
	if err := writeManifestWith(dir, Manifest{SnapshotLSN: snapshotLSN}, open); err != nil {
		return fmt.Errorf("persist: checkpoint manifest: %w", err)
	}

	// Step 3: reclaim space by deleting fully-covered WAL segments.
	if err := truncateWALSegments(dir, snapshotLSN); err != nil {
		return fmt.Errorf("persist: checkpoint wal truncation: %w", err)
	}

	// Step 1: snapshot to disk, atomically.
	if err := writeSnapshotWith(dir, snap, open); err != nil {
		return fmt.Errorf("persist: checkpoint snapshot: %w", err)
	}
FIN

# Mutante A, en dos pasos: se quita el bloque de donde esta y se pone delante de
# la otra ancla. Si cualquiera de los dos no prende, sustituye() para el guion.
sustituye "${NODE_GO}" "${CAJON}/a-bloque.txt" "${CAJON}/vacio.txt" "${CAJON}/paso1.go"
sustituye "${CAJON}/paso1.go" "${CAJON}/a-ancla.txt" "${CAJON}/a-ancla-con-bloque.txt" "${CAJON}/node_a.go"

# Mutante B, en uno.
sustituye "${STORAGE_GO}" "${CAJON}/b-viejo.txt" "${CAJON}/b-nuevo.txt" "${CAJON}/storage_b.go"

# Mutante C, en uno.
sustituye "${CHECKPOINT_GO}" "${CAJON}/c-viejo.txt" "${CAJON}/c-nuevo.txt" "${CAJON}/checkpoint_c.go"

# Un canario por paquete mutado. Si uno compila, el overlay no esta entrando para
# ese fichero. Van uno por paquete porque el overlay se declara por fichero, asi
# que comprobar solo uno dejaria los demas sin comprobar, que es la mitad del
# argumento.
printf 'package naylamp\n\nesto no es go y no compila\n' > "${CAJON}/node_canario.go"
printf 'package raft\n\nesto no es go y no compila\n' > "${CAJON}/storage_canario.go"
printf 'package persist\n\nesto no es go y no compila\n' > "${CAJON}/checkpoint_canario.go"

# Cada mutante tiene que DIFERIR de su original. Un parche que prendiera y no
# cambiara nada dejaria las filas rojas certificando un arbol sano.
cmp -s "${NODE_GO}" "${CAJON}/node_a.go" && { echo "test: VACIO, el mutante A salio identico a node.go" >&2; exit 1; }
cmp -s "${STORAGE_GO}" "${CAJON}/storage_b.go" && { echo "test: VACIO, el mutante B salio identico a storage.go" >&2; exit 1; }
cmp -s "${CHECKPOINT_GO}" "${CAJON}/checkpoint_c.go" && { echo "test: VACIO, el mutante C salio identico a checkpoint.go" >&2; exit 1; }

overlay() { printf '{"Replace":{"%s":"%s"}}\n' "$1" "$2" > "$3"; }
overlay "${NODE_GO}"       "${CAJON}/node_a.go"             "${CAJON}/ov_a.json"
overlay "${STORAGE_GO}"    "${CAJON}/storage_b.go"          "${CAJON}/ov_b.json"
overlay "${CHECKPOINT_GO}" "${CAJON}/checkpoint_c.go"       "${CAJON}/ov_c.json"
overlay "${NODE_GO}"       "${CAJON}/node_canario.go"       "${CAJON}/ov_canario_a.json"
overlay "${STORAGE_GO}"    "${CAJON}/storage_canario.go"    "${CAJON}/ov_canario_b.json"
overlay "${CHECKPOINT_GO}" "${CAJON}/checkpoint_canario.go" "${CAJON}/ov_canario_c.json"

PAQUETE=./engine/naylamp/
SELECTOR=TestPowerCutSweep_EveryReplicaStillBoots
PAQUETE_CP=./engine/persist/
SELECTOR_CP=TestCrashInsideCheckpoint_AckedWritesSurvive
PLAZO=900s

# corre_en <overlay-o-vacio> <salida> <paquete> <selector> -> imprime el rc
corre_en() {
	rc=0
	if [ -n "$1" ]; then
		"${GO}" test -overlay "$1" "$3" -run "$4" -count=1 -timeout "${PLAZO}" -v > "$2" 2>&1 || rc=$?
	else
		"${GO}" test "$3" -run "$4" -count=1 -timeout "${PLAZO}" -v > "$2" 2>&1 || rc=$?
	fi
	echo "${rc}"
}

# corre <fichero-de-overlay-o-vacio> <fichero-de-salida> -> imprime el rc
corre() { corre_en "$1" "$2" "${PAQUETE}" "${SELECTOR}"; }
# El nombre del subtest va seguido de su reloj entre parentesis, asi que el
# patron ancla en el nombre y en el espacio que lo cierra, no en el fin de linea.
paso()  { grep -q "^ *--- PASS: ${SELECTOR}/$1 " "$2"; }
falla() { grep -q "^ *--- FAIL: ${SELECTOR}/$1 " "$2"; }

fallos=0
mal() { echo "$1" >&2; fallos=$((fallos + 1)); }

# ---- 1. CONTROL: el arbol sin tocar deja el defensor verde ----
rc=$(corre "" "${CAJON}/control.txt")
if [ "${rc}" -eq 0 ] && paso lockstep "${CAJON}/control.txt" && paso catching-up "${CAJON}/control.txt"; then
	anota_fila OK; echo "1 control: OK, el arbol sin mutar deja los dos escenarios verdes"
else
	anota_fila FALLA; mal "1 control: FALLA, el defensor no esta verde sobre el arbol sano, asi que ningun rojo de abajo prueba nada"
	echo "test: sin control no se sigue" >&2
	exit 1
fi

# ---- 2. CANARIO: el overlay entra de verdad, en los DOS paquetes ----
for lado in a b; do
	rc=$(corre "${CAJON}/ov_canario_${lado}.json" "${CAJON}/canario_${lado}.txt")
	if [ "${rc}" -ne 0 ] && ! grep -q "^ok " "${CAJON}/canario_${lado}.txt"; then
		anota_fila OK; echo "2 canario(${lado}): OK, el overlay entra: el fichero que no compila rompe la construccion"
	else
		anota_fila FALLA; mal "2 canario(${lado}): FALLA, el overlay NO esta entrando en ese paquete, asi que un verde de su fila roja no diria nada"
		echo "test: sin canario no se sigue, porque las filas rojas serian ilegibles" >&2
		exit 1
	fi
done

# ---- 3. ROJO A: el orden dentro de processReady ----
rc=$(corre "${CAJON}/ov_a.json" "${CAJON}/rojo_a.txt")
if [ "${rc}" -ne 0 ] && falla catching-up "${CAJON}/rojo_a.txt" && paso lockstep "${CAJON}/rojo_a.txt" \
	&& grep -q "restored commit exceeds restored log" "${CAJON}/rojo_a.txt"; then
	anota_fila OK; echo "3 rojo(A): OK, MUERDE: bajado AppendEntries por detras del ack, catching-up cae y lockstep se queda verde"
else
	anota_fila FALLA; mal "3 rojo(A): FALLA, la mutacion del orden de processReady no dio el reparto que este brazo afirma"
fi

# ---- 4. ROJO B: el hard state publicado antes de cruzar la barrera ----
rc=$(corre "${CAJON}/ov_b.json" "${CAJON}/rojo_b.txt")
if [ "${rc}" -ne 0 ] && falla lockstep "${CAJON}/rojo_b.txt" && falla catching-up "${CAJON}/rojo_b.txt" \
	&& grep -q "corrupt hard state file" "${CAJON}/rojo_b.txt"; then
	anota_fila OK; echo "4 rojo(B): OK, MUERDE: publicado el hard state antes de la barrera, los dos escenarios caen"
else
	anota_fila FALLA; mal "4 rojo(B): FALLA, la mutacion del orden de SaveHardState no puso rojos los dos escenarios"
fi

# ---- 5. CONTROL del brazo del checkpoint, y 6. su CANARIO ----
#
# Van juntos porque son la misma pregunta hecha al tercer paquete: el brazo esta
# verde sobre el arbol sano, y el overlay entra en engine/persist.
rc=$(corre_en "" "${CAJON}/control_cp.txt" "${PAQUETE_CP}" "${SELECTOR_CP}")
if [ "${rc}" -eq 0 ] && grep -q "^--- PASS: ${SELECTOR_CP} " "${CAJON}/control_cp.txt"; then
	anota_fila OK; echo "5 control(cp): OK, el brazo del checkpoint esta verde sobre el arbol sin mutar"
else
	anota_fila FALLA; mal "5 control(cp): FALLA, el brazo del checkpoint no esta verde sobre el arbol sano, asi que su rojo no probaria nada"
	echo "test: sin control no se sigue" >&2
	exit 1
fi

rc=$(corre_en "${CAJON}/ov_canario_c.json" "${CAJON}/canario_c.txt" "${PAQUETE_CP}" "${SELECTOR_CP}")
if [ "${rc}" -ne 0 ] && ! grep -q "^ok " "${CAJON}/canario_c.txt"; then
	anota_fila OK; echo "6 canario(c): OK, el overlay entra en engine/persist"
else
	anota_fila FALLA; mal "6 canario(c): FALLA, el overlay NO esta entrando en engine/persist"
	echo "test: sin canario no se sigue, porque la fila roja seria ilegible" >&2
	exit 1
fi

# ---- 7. ROJO C: el orden de los tres pasos de checkpointWith ----
#
# Esta fila existe por una razon que la cabecera desarrolla y que conviene tener
# delante al leer un fallo: el rojo del brazo del checkpoint DEPENDE de que
# Recover lea la marca del manifest sin comprobar que el snapshot exista, y esa
# lectura no la defiende nadie. Arreglada esa segunda, la mutacion del orden
# deja de perder datos y el brazo se queda verde sin que nadie lo note. Esta
# fila es quien lo nota.
rc=$(corre_en "${CAJON}/ov_c.json" "${CAJON}/rojo_c.txt" "${PAQUETE_CP}" "${SELECTOR_CP}")
if [ "${rc}" -ne 0 ] && grep -q "^--- FAIL: ${SELECTOR_CP} " "${CAJON}/rojo_c.txt" \
	&& grep -q "acknowledged writes came back intact after recovery" "${CAJON}/rojo_c.txt"; then
	anota_fila OK; echo "7 rojo(C): OK, MUERDE: publicado el manifest antes que su snapshot, el brazo del checkpoint cae"
else
	anota_fila FALLA; mal "7 rojo(C): FALLA, la mutacion del orden de checkpointWith no puso rojo al brazo que existe para cazarla"
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
echo "test: los dos defensores estan verdes sobre el arbol sano, el overlay entra en los tres paquetes, y las tres mutaciones muerden"
