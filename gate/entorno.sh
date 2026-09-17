#!/usr/bin/env bash
# gate/entorno.sh: un banco declara el entorno en el que corre, y lo comprueba.
#
# POR QUE EXISTE, y es un incidente y no una precaucion. El 14 de septiembre de
# 2026 `gate/p2-iron-test.sh` entro en CI y su PRIMERA corrida en el runner lo
# tumbo con una fila en FALLA, la 17eh, mientras la misma fila sobre el MISMO
# commit daba verde en la maquina de trabajo. La causa no estaba en el arbol:
# la fila preguntaba con `grep '^\t...'` y POSIX no define \t dentro de una
# expresion basica ni extendida, asi que BSD grep -macOS- lo leia como TABULADOR
# y GNU grep -el runner- como la letra t. El hecho aseverado era cierto en los
# dos sitios; lo que cambiaba era el instrumento. Un rojo asi se lee como rojo de
# propiedad, y ese es el que nadie vuelve a correr.
#
# QUE HACE, y son las dos mitades que el incidente pide. DECLARA: imprime en una
# linea quien es la maquina, el bash, la implementacion de grep y como lee esa
# implementacion el \t, de modo que una corrida archivada diga donde se tomo sin
# que nadie tenga que acordarse. Y COMPRUEBA: censa el guion que lo llama y se
# NIEGA a abrir si encuentra un patron de grep con un escape que POSIX no define.
# Es la forma con la que `gate/p2-preflight.sh` declara el bit de sysrq antes de
# usarlo: primero se dice en que entorno se esta, y luego se mira si sirve.
#
# COMO SE USA, desde un banco y justo detras de su linea de identidad:
#     . "$(dirname "$0")/entorno.sh"
# Se SOURCEA a proposito: si el censo encuentra algo, el `exit` de aqui dentro
# para el banco entero, que es lo que tiene que pasar.
#
# AND IT CENSUSES ONLY THE SCRIPT THAT LOADS IT, which is measured and not read off: the call
# is `entorno_escapes_sin_definir "$0"`, and the order that finds it is
# `grep -nF 'entorno_escapes_sin_definir "$0"' gate/entorno.sh`, so a bench that carries a bad
# pattern is refused when IT loads, and the family of benches is censused by row 17ei of
# gate/p2-iron-test.sh, which calls this same function over `gate/*.sh` and over the two
# mutants it writes. The difference matters the day a bench is added: nothing here reads it
# until it loads itself.

entorno_lectura_de_tab() {
	local n
	n="$(printf 'x\ty\n' | grep -c '^x\ty$' 2>/dev/null || echo 0)"  # SONDA-DE-ENTORNO
	[ "${n}" = "1" ] && echo tabulador || echo letra-t
}

entorno_escapes_sin_definir() {
	python3 - "$@" <<'CENSO'
import re, sys

# Escapes que POSIX NO define ni en una expresion basica ni en una extendida, asi
# que cada implementacion decide y el patron responde a la maquina, no al arbol.
ESC = re.compile(r"\\[tsdwSDW]")
# El dolar delante de la comilla es JUSTO la forma portable, $'\t', porque bash
# convierte el escape ANTES de que grep lo vea: esa no cuenta y se excluye aqui.
#
# AND THE FLAGS ARE READ WHOLE, a correction of 15 September 2026. The earlier version
# took only short flags with no argument, so it did not read `grep -A2`, nor `grep -m1`,
# nor `grep -A 3`, nor `grep -q --`. THE FIGURES OF THAT WIDENING ARE NOT RECITED HERE,
# and the reason is measured rather than stylistic: they move every time this tree moves,
# and the very change that wrote this paragraph moved all three of them. What lives here is
# the ORDER, with its two counting rules -DISTINCT invocations by file, line, flags and
# pattern, or APPEARANCES- and its table of the three patterns, published in
# ../corridas/naylamp-cifras-20260915T1659Z.txt. What does NOT move and is therefore said here: the wide
# pattern recovers everything the old one read as an invocation except the cases that
# crudo names one by one, where the old `[^|;)]*?` reached the quote of the FILE and took
# the file name for the pattern; those were never coverage, and that is why they are not
# recovered. And a figure that has to stay because the text cannot be read without it
# carries its date and the sha of the tree it was measured on: that is the rule this file
# follows from here on.
#
# LO QUE ESTE PATRON NO VE, nombrado porque una guarda que esconde su alcance es
# peor que ninguna: un patron SIN comillas -`grep -c . fichero`-, porque no hay
# forma de saber donde acaba; `grep -f fichero-de-patrones` y `grep -e pat`, que el
# arbol NO usa -medido: cero apariciones de las dos-, y `grep -e` extra cuando hay
# varias. Las opciones largas si se leen, y `--extended-regexp` ademas CAMBIA el
# lenguaje, que es lo que decide si la regla del ancla se le aplica.
GREP = re.compile(r"\b(e?grep)\b((?:[ \t]+(?:--?[^ \t'\"]*|[0-9]+))*)[ \t]*(\$?)(['\"])(.*?)\4")

# LOS METACARACTERES SIN ANCLAR, que entran el 15 de septiembre de 2026 y son la
# MISMA clase que los escapes de arriba: un `$` o un `^` en una posicion que POSIX
# no define la decide la implementacion, y el patron responde a la maquina en vez
# de al arbol. Medido en esta maquina, contra el texto `a$b`: `grep -E 'a$b'` y
# `awk '/a$b/'` NO casan -lo leen como ancla- y `sed -n '/a$b/p'` SI casa -lo lee
# como literal-. Cuatro pares medidos, y el que decide el alcance de esta regla es
# el del LENGUAJE: en una expresion BASICA el `$` del medio es un literal en los
# dos motores, asi que ahi no hay clase; en una EXTENDIDA BSD lo lee como ancla y
# GNU, por su regla documentada, como literal. O sea que la divergencia es de ERE y
# por eso esta regla solo mira las invocaciones EXTENDIDAS: `grep -E`, `grep -qE`,
# `egrep`. The BRE patterns of this tree that carry a mid `$` rely on the literal in both
# engines and they hold today; counting them would be a false-positive machine, and the count
# is NOT recited here, because it moves with the tree. The order that prints it, with its two
# variants -all of them, and only the ones that do not open the pattern-, is in the crudo
# named in the paragraph above.
#
# LO QUE TAMPOCO SE CUENTA, Y VA DICHO EN VEZ DE DISIMULADO, porque una guarda que
# esconde su alcance es peor que ninguna: (1) las posiciones en las que las dos
# implementaciones coinciden en leer un ancla -un `$` justo antes de `)` o de `|`,
# y un `^` justo detras de `(` o de `|`, medido con `(^| )id=7( |$)` y con `a$|b`-;
# (2) lo que va dentro de una EXPRESION DE CORCHETE, donde los dos son literales,
# que sin quitarlo convertia cada `[^ ]` del arbol en un hallazgo; y (3) un `$`
# seguido de `{` o de `(`, que es la FORMA de una expansion del shell: dentro de
# comillas dobles la expande el shell y no llega nunca a grep, y dentro de simples
# es el idioma de empotrar un literal, que en BRE se cumple y en ERE no se usa en
# ningun sitio de este arbol, medido. Esas tres fronteras son el precio de que la
# fila valga cero sobre el arbol sano.
ANCLA = re.compile(r"(?<!\\)[$^]")
# Y un `$` puede ser del SHELL y no del patron. Dentro de comillas SIMPLES el shell
# no expande nada, asi que ahi todo `$` es del patron; dentro de dobles si, y hay
# que separar las expansiones antes de mirar posiciones. Las dos cosas se midieron:
# la primera version neutralizaba expansiones tambien en comillas simples, y una
# copia con `grep -qE 'a$b'` daba CERO, o sea una guarda muda justo en el caso que
# viene a cubrir.
EXPANSION = re.compile(r"\$[({?@*#\-$!0-9A-Za-z_]")
# Y DENTRO DE UNA EXPRESION DE CORCHETE los dos son literales, asi que no cuentan:
# sin quitarlas, cada `[^ ]` del arbol salia contado como un `^` sin anclar.
CORCHETE = re.compile(r"\[\[:[a-z]+:\]\]|\[[^\]]*\]")
# Y UN PUNTO CIEGO DEL PROPIO CENSO, medido al escribirlo y declarado en vez de
# disimulado: la palabra del grep se busca con frontera de palabra delante, asi que
# un `grep` pegado a un caracter de palabra -lo que pasa cuando el texto de una
# linea lleva `\ngrep` dentro de una cadena- NO se ve. El fichero que ese texto
# escribe SI se ve, porque la fila lo censa por su nombre: asi lo hace la 17ei con
# sus dos mutantes. Lo que queda fuera es un grep escrito como DATO y no censado
# por nadie mas, y va dicho aqui.


def sin_expansiones(p):
    return EXPANSION.sub("  ", p)


def ancla_sin_definir(p, comilla, flags):
    # `--extended-regexp` cambia el LENGUAJE y por tanto decide si esta regla aplica;
    # `--basic-regexp` lo devuelve a basico. Sin leerlas, una invocacion extendida por
    # opcion larga se clasificaria como BRE y la regla del ancla se saltaria entera.
    es_ere = "E" in flags or "egrep" in flags or "--extended-regexp" in flags
    if "--basic-regexp" in flags:
        es_ere = False
    if not es_ere:
        return False
    limpio = CORCHETE.sub("  ", p if comilla == "'" else sin_expansiones(p))
    for m in ANCLA.finditer(limpio):
        i = m.start()
        if limpio[i] == "$":
            if i == len(limpio) - 1 or limpio[i + 1:i + 2] in (")", "|", "{", "("):
                continue
        else:
            if i == 0 or (i > 0 and limpio[i - 1] in "(|"):
                continue
        return True
    return False


for f in sys.argv[1:]:
    try:
        texto = open(f, errors="ignore").read()
    except OSError:
        continue
    for numero, linea in enumerate(texto.splitlines(), 1):
        if "SONDA-DE-ENTORNO" in linea:
            continue
        # Un comentario no se ejecuta, asi que no puede decidir ningun veredicto.
        if linea.lstrip().startswith("#"):
            continue
        for m in GREP.finditer(linea):
            if m.group(3) == "$":
                continue
            flags = m.group(2) + (" egrep" if m.group(1) == "egrep" else "")
            if ESC.search(m.group(5)) or ancla_sin_definir(m.group(5), m.group(4), flags):
                print("%s:%d: %s" % (f, numero, linea.strip()[:100]))
CENSO
}

# LA SEGUNDA COMPROBACION, y es del mismo dia y un piso por encima de la primera.
# Un guion que SOURCEA un fichero que git no trackea funciona aqui y muere en un
# clon, y CI clona en limpio. Es la misma forma que el rojo de los escapes: el
# guion no cambia, cambia lo que la otra maquina tiene delante. El predicado se
# escribe antes de contar y separa DOS clases: una carga cuyo fichero vive en el
# ARBOL tiene que estar trackeada; una carga cuyo fichero lo ESCRIBE el propio
# guion en su taller -mktemp, ${TMPDIR}, el directorio del banco- no se trackea y
# no es un defecto, es una fixture. La cuenta que se publica es la de la primera.
entorno_cargas_sin_trackear() {
	python3 - "$@" <<'CARGAS'
import os, re, subprocess, sys

CARGA = re.compile(r"^\s*(?:\.|source)\s+(.+?)\s*$")

RAIZ = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True,
                      cwd=os.path.dirname(os.path.abspath(sys.argv[1])) if len(sys.argv) > 1 else ".").stdout.strip()
if not RAIZ:
    print("censo: no se pudo localizar la raiz del repositorio, y sin raiz no hay contra que juzgar una ruta")
    sys.exit(0)
REDIR = re.compile(r"\s*(?:[0-9]?>>?|[0-9]?<|2>&1|>&2)\s*\S+.*$")

def resuelve(a, fichero):
    a = REDIR.sub("", a.strip())
    if a.startswith('"') and a.endswith('"'):
        a = a[1:-1]
    for viejo, nuevo in (
        ('$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)', "gate"),
        ('$(dirname "${BASH_SOURCE[0]}")', "gate"),
        ('$(cd "$(dirname "$0")" && pwd)', "gate"),
        ('$(dirname "$0")', "gate"),
        ("${GATE_DIR}", "gate"), ("$GATE_DIR", "gate"),
        ("${AQUI}", "gate"), ("$AQUI", "gate"),
        ("${REPO_DIR}/gate", "gate"), ("${RAIZ}/gate", "gate"),
    ):
        a = a.replace(viejo, nuevo)
    return a

for f in sys.argv[1:]:
    try:
        lineas = open(f, errors="ignore").read().splitlines()
    except OSError:
        continue
    # Las variables que el propio guion apunta a un taller quedan exentas, y la
    # exencion se demuestra con su asignacion, no se supone.
    taller = set()
    asignaciones = {}
    for l in lineas:
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", l)
        if not m:
            continue
        valor = m.group(2).strip().strip('"')
        asignaciones.setdefault(m.group(1), valor)
        if re.search(r"mktemp|\$\{TMPDIR|/tmp|\$\{BANCO\}|\$\{CAJON\}|out/", m.group(2)):
            taller.add(m.group(1))
    for numero, l in enumerate(lineas, 1):
        if l.lstrip().startswith("#"):
            continue
        m = CARGA.match(l)
        if not m:
            continue
        ruta = resuelve(m.group(1), f)
        # Una vuelta de sustitucion por asignacion del propio fichero: si la
        # variable se define ahi y su valor resuelve a una ruta del arbol, la
        # carga es del arbol y hay que juzgarla, no dejarla en "sin resolver".
        if "$" in ruta:
            v = re.search(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", ruta)
            if v and v.group(1) in asignaciones:
                cand = resuelve(ruta.replace("${%s}" % v.group(1), asignaciones[v.group(1)])
                                    .replace("$%s" % v.group(1), asignaciones[v.group(1)]), f)
                if "$" not in cand:
                    ruta = cand
        if "$" in ruta:
            v = re.search(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", ruta)
            if v and v.group(1) in taller:
                continue
            print("%s:%d: carga con variable sin resolver: %s" % (f, numero, ruta))
            continue
        # git -C LA RAIZ, y no `git ls-files` a secas: las rutas que este censo
        # resuelve son relativas a la raiz del repositorio, y el banco se mueve de
        # directorio mientras corre. Sin el -C, el censo contestaba al DIRECTORIO
        # ACTUAL en vez de al arbol y daba 23 donde hay 0, que es la misma clase de
        # defecto que este fichero existe para cazar. Medido el 14 de septiembre.
        r = subprocess.run(["git", "-C", RAIZ, "ls-files", "--error-unmatch", ruta],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("%s:%d: %s no esta trackeado, asi que en un clon no existe" % (f, numero, ruta))
CARGAS
}

# LA TERCERA COMPROBACION, y esta costo un rojo de CI. El 15 de septiembre de 2026 la
# corrida 34929631648 tumbo el PRIMERO de los bancos que cargan este fichero con `Bad substitution` en su
# linea de carga, y por el radio los otros cinco no llegaron a correr: un fallo de
# entorno que antes tumbaba UN banco paso a tumbar SEIS. La causa es la clase que las
# dos comprobaciones de arriba vigilan por otros lados, un instrumento que responde
# distinto segun donde corre: `BASH_SOURCE` es una expansion de bash, el shebang de ese
# banco promete sh, y en el runner sh es dash, que no la entiende; el dirname sale vacio
# y la carga resuelve a /entorno.sh. Aqui se vigilan los guiones que PROMETEN sh; uno que
# pide bash por shebang puede usar lo que bash tiene. La forma portable para resolver el
# sitio de un guion que se ejecuta es `$0`, y es la que estos bancos ya usaban para lo
# mismo dos lineas mas abajo.
#
# ESTO ES UN LINT BARATO Y NO CIERRA LA CLASE, y va dicho aqui para que nadie lo lea de
# mas: caza la INSTANCIA que tumbo CI -una expansion de bash en un guion que promete sh-
# y habria dado VERDE con el segundo bashismo dentro, porque `${BASH_VERSION}` sin guarda
# no es BASH_SOURCE y mata el banco igual bajo dash. La clase la cierra la fila 17ek de
# gate/p2-iron-test.sh, que corre cada banco de la familia bajo /bin/dash y exige rc=0,
# que es exactamente lo que el runner hace con ellos.
entorno_resolucion_no_portable() {
	python3 - "$@" <<'PORTABLE'
import re, sys

for f in sys.argv[1:]:
	try:
		lineas = open(f, errors="ignore").read().splitlines()
	except OSError:
		continue
	if not lineas:
		continue
	# Un guion que pide bash puede usar sintaxis de bash: no es esta clase.
	if "bash" in lineas[0]:
		continue
	for numero, l in enumerate(lineas, 1):
		# Un comentario no se ejecuta, asi que no puede decidir ningun veredicto.
		if l.lstrip().startswith("#"):
			continue
		if "BASH_SOURCE" in l:
			print("%s:%d: %s" % (f, numero, l.strip()[:100]))
PORTABLE
}

# Y ANTES DE NADA, EL TERCERO DEL QUE ESTE FICHERO DEPENDE. Las dos comprobaciones
# de aqui abajo las hace `python3`, que no es de este arbol: es un acoplamiento con
# un tercero, de la clase que DEFER-103 nombra. Si falta, sus censos no fallan:
# devuelven VACIO, y una fila que cuenta lineas leeria cero y se pondria VERDE por
# ausencia de la herramienta. Eso es una fila muda fabricada por el entorno, que es
# justo lo que esta pasada vino a cazar. Asi que se comprueba y se muere, con la
# ausencia como resultado y no como pase.
if ! command -v python3 >/dev/null 2>&1; then
	echo "ENTORNO: no hay python3 en esta maquina, y los dos censos de este fichero lo usan" >&2
	echo "ENTORNO: sin el devolverian vacio y sus filas pasarian VERDES por ausencia" >&2
	echo "ENTORNO: la ausencia es el resultado, no un salto" >&2
	exit 2
fi

printf 'ENTORNO: %s | bash %s | %s | grep lee \\t como %s\n' \
	"$(uname -s -r -m)" "${BASH_VERSION:-no-bash}" \
	"$(grep --version 2>/dev/null | head -1)" "$(entorno_lectura_de_tab)"

ENTORNO_SOSPECHOSOS="$(entorno_escapes_sin_definir "$0")"
if [ -n "${ENTORNO_SOSPECHOSOS}" ]; then
	echo "ENTORNO: este banco pregunta con un escape que POSIX no define, asi que su" >&2
	echo "ENTORNO: respuesta depende de la implementacion de grep y no del arbol:" >&2
	echo "${ENTORNO_SOSPECHOSOS}" >&2
	echo "ENTORNO: la forma portable es \$'\\t', que bash expande antes de llamar a grep" >&2
	exit 2
fi
