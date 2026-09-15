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
#     . "$(dirname "${BASH_SOURCE[0]}")/entorno.sh"
# Se SOURCEA a proposito: si el censo encuentra algo, el `exit` de aqui dentro
# para el banco entero, que es lo que tiene que pasar.

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
GREP = re.compile(r"\be?grep\b[^|;)]*?(\$?)(['\"])(.*?)\2")

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
            if m.group(1) == "$":
                continue
            if ESC.search(m.group(3)):
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
	"$(uname -s -r -m)" "${BASH_VERSION}" \
	"$(grep --version 2>/dev/null | head -1)" "$(entorno_lectura_de_tab)"

ENTORNO_SOSPECHOSOS="$(entorno_escapes_sin_definir "$0")"
if [ -n "${ENTORNO_SOSPECHOSOS}" ]; then
	echo "ENTORNO: este banco pregunta con un escape que POSIX no define, asi que su" >&2
	echo "ENTORNO: respuesta depende de la implementacion de grep y no del arbol:" >&2
	echo "${ENTORNO_SOSPECHOSOS}" >&2
	echo "ENTORNO: la forma portable es \$'\\t', que bash expande antes de llamar a grep" >&2
	exit 2
fi
