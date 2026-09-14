#!/usr/bin/env bash
# sitio-test.sh: una fila que llama a una funcion por su NOMBRE no cubre el SITIO
# desde el que esa funcion se llama de verdad.
#
# DE DONDE SALE, y no es un habito: es una clase que mordio CINCO veces el 9 de
# septiembre de 2026, en un solo dia, y las cinco con la misma forma. `banner` no
# despachaba a su rama de fierro y las filas llamaban a `banner_fierro`, asi que
# seguian verdes. `veredicto_en_vuelo` abria un `begin_check` dentro del bloque de
# `P2.cut.fired` y le borraba los FAIL, y la fila la llamaba sola, donde funciona.
# `comprueba_rango_en_vuelo` sabia contar y nadie miraba que el escritor la
# CORRIERA. El manifiesto del escritor nunca se metia en el python que lo consume,
# que es donde estaba el bloqueante. Y `barre_ensayos_viejos` se llama desde la
# trampa de salida, que ninguna fila ejerce.
#
# LAS CINCO SE ARREGLARON UNA A UNA, y esa es justo la senal de que hacia falta
# esto: una clase que se arregla por instancias vuelve. Lo que este guion trae es
# el PREDICADO, que no depende de que nadie se acuerde.
#
# EL PREDICADO, escrito antes de contar nada:
#
#   Una fila NO cubre el SITIO de una funcion si la invoca POR SU NOMBRE y esa
#   funcion tiene al menos un sitio de llamada DESNUDO -una sentencia por si sola,
#   cuyo lugar y cuyo orden importan- dentro de otra funcion del guion que NINGUNA
#   fila del banco llega a ejercer.
#
# Y LO QUE EL PREDICADO DESCARTA A PROPOSITO, porque contarlo seria contar de mas:
# si el sitio consume el VALOR que la funcion devuelve -dentro de un `if`, de una
# sustitucion o de una condicion- entonces llamarla por su nombre mide exactamente
# lo mismo que mide el sitio, y la fila si lo cubre. Medido sobre el banco de hoy:
# el predicado grueso da 43 pares y el afilado 23, o sea que veinte de aquellos
# eran predicados puros leidos por su valor.
#
# COMO SE USA: lo que no este cubierto tiene que estar DECLARADO abajo, con su
# razon escrita. Un par nuevo que no este ni cubierto ni declarado pone rojo este
# guion. No es un techo que se sube: es una lista que se lee.
set -uo pipefail

echo "BANCO: sitio-test"

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUION="${GATE_DIR}/p2.sh"
BANCO="${GATE_DIR}/p2-iron-test.sh"
[ -r "${GUION}" ] || { echo "sitio-test: no encuentro ${GUION}" >&2; exit 2; }
[ -r "${BANCO}" ] || { echo "sitio-test: no encuentro ${BANCO}" >&2; exit 2; }

COMPLETO=0
trap 'if [ "${COMPLETO}" -ne 1 ]; then echo "test: ABORTADO antes del resumen; lo impreso arriba NO es un resultado" >&2; exit 1; fi' EXIT

/usr/bin/python3 - "${GUION}" "${BANCO}" <<'FINDELPYTHON'
import re, sys, collections, io

guion, banco = sys.argv[1], sys.argv[2]

# LO DECLARADO, y cada linea lleva su razon. Un par que este aqui no pone rojo el
# guion; uno que no este ni aqui ni cubierto, si. La lista se lee, no se cuenta:
# quien anada uno tiene que escribir por que, y esa frase es la que un lector
# discute.
DECLARADO = {
    ('escribe_running', 'phase_build'):
        'phase_build cruza-compila y despliega, o sea que ejercerla aqui seria construir binarios dentro de un banco que existe para no encender nada. El sitio es UNA linea sin condicion.',
    ('emit_final_verdict', 'main'):
        'main es el punto de entrada entero: ejercerlo es correr el gate, que es lo que este banco existe para no hacer. Su sitio es la ultima sentencia de main, sin condicion.',
    ('banner', 'main'):
        'mismo caso que el anterior. El DESPACHO de banner, que es lo que mordio, si esta cubierto por las filas que llaman a banner y no a sus mitades.',
    ('phase_hygiene', 'main'):
        'main es el punto de entrada entero, como en los dos casos de arriba: ejercerlo es correr el gate. Lo que el sitio decide, que es el ORDEN de las ocho fases, no lo mira este banco y va dicho aqui en vez de darse por cubierto.',
    ('phase_cut', 'main'):
        'mismo caso, y aparecio al enrutar la 17ia por el despacho: la fase del corte ya se ejerce entera, pero el ORDEN en que main la llama respecto de las otras siete no lo mira nadie, y eso se dice en vez de darse por cubierto.',
}

# LA CONTABILIDAD DEL GATE VA APARTE, y con su razon: begin_check, end_check,
# fail, pass, note, record_verdict y not_run no son piezas de nada. Son el andamio
# con el que una fila CONSTRUYE una secuencia para probar el sitio de otra cosa, y
# marcarlas como "probadas por su nombre" seria contar como defecto justo el gesto
# que lo arregla. Su sitio esta en cada fase, y el UNICO sitio suyo que ha decidido
# algo -el `begin_check` que veredicto_en_vuelo abria dentro del bloque de
# P2.cut.fired y le borraba los FAIL- tiene su propia fila, que monta esa secuencia
# exacta y mira el VEREDICTO. Excluirlas sin decirlo seria la trampa; decirlo es la
# lista.
CONTABILIDAD = {'begin_check', 'end_check', 'fail', 'pass', 'note',
                'record_verdict', 'not_run', 'verdict_of', 'stop'}

src = io.open(guion, encoding='utf-8').read().split('\n')
defs, orden = {}, []
i = 0
while i < len(src):
    m = re.match(r'^([a-z_][a-z0-9_]*)\(\) \{$', src[i])
    if m:
        j = i + 1
        while j < len(src) and src[j] != '}':
            j += 1
        defs[m.group(1)] = (i, j)
        orden.append(m.group(1))
    i += 1

if len(defs) < 20:
    print('test: VACIO. Solo %d funciones extraidas de %s, o sea que la extraccion' % (len(defs), guion))
    print('test: se rompio y este guion no ha comprobado nada, que NO es un pase', file=sys.stderr)
    raise SystemExit(1)

def dentro_de(k):
    for n, (a, b) in defs.items():
        if a < k <= b:
            return n
    return None

def es_com(l):
    return l.lstrip().startswith('#')

def solo_codigo(l):
    # EL RECORRIDO SABE DE COMILLAS, y la primera version no. Contaba parentesis a
    # secas, asi que un `grep -q 'os.fsync(os.open'` le desbalanceaba la cuenta: el
    # tramo de la sustitucion se comia el resto de la linea, la prosa del final
    # sobrevivia dentro de el, y la guarda daba un falso positivo. Una guarda que
    # senala lo que esta bien se apaga tan rapido como una que calla lo que esta
    # mal. Aqui se recorre caracter a caracter llevando el estado de las comillas,
    # y un parentesis dentro de comillas no cuenta.
    #
    # Y SE APLICA POR DENTRO DE LAS SUSTITUCIONES, que es la otra mitad y la que
    # mentia en la direccion PELIGROSA. Una fila que LEE el texto de una fase, con
    # un `$(awk '/^phase_cut_fierro/,/^}/' p2.sh)`, contaba como si la EJERCIERA, y
    # entonces todo lo que tenga su sitio ahi dentro salia cubierto sin estarlo.
    # Cinco pares reales desaparecian por esa via. Recorrer tambien por dentro deja
    # el patron del awk donde le toca, que es en la prosa.
    fuera, i, n = [], 0, len(l)
    while i < n:
        c = l[i]
        if c == "'":
            j = l.find("'", i + 1)
            i = n if j < 0 else j + 1
            fuera.append(' ')
            continue
        if c == '"':
            # una cadena entre comillas dobles PUEDE llevar sustituciones dentro, y
            # esas si son codigo. Se recorre por dentro y solo se conservan ellas.
            i += 1
            while i < n and l[i] != '"':
                if l[i] == '$' and i + 1 < n and l[i + 1] == '(':
                    trozo, i = _sustitucion(l, i, n)
                    fuera.append(solo_codigo(trozo[2:-1]) if trozo.endswith(')') else trozo)
                else:
                    i += 1
            i += 1
            fuera.append(' ')
            continue
        if c == '$' and i + 1 < n and l[i + 1] == '(':
            trozo, i = _sustitucion(l, i, n)
            fuera.append(solo_codigo(trozo[2:-1]) if trozo.endswith(')') else trozo)
            continue
        fuera.append(c)
        i += 1
    return ''.join(fuera)

def _sustitucion(l, i, n):
    # devuelve el texto de la sustitucion que empieza en i, y donde acaba. Cuenta
    # parentesis SALTANDOSE los que van dentro de comillas.
    j, hondo = i + 2, 1
    while j < n and hondo:
        c = l[j]
        if c == "'":
            k = l.find("'", j + 1)
            j = n if k < 0 else k + 1
            continue
        if c == '"':
            k = j + 1
            while k < n and l[k] != '"':
                k += 1
            j = k + 1
            continue
        if c == '(':
            hondo += 1
        elif c == ')':
            hondo -= 1
        j += 1
    return l[i:j], j

sitios = collections.defaultdict(list)
for n in defs:
    pat = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(n) + r'(?![A-Za-z0-9_])')
    a, b = defs[n]
    for k, l in enumerate(src):
        if a <= k <= b or es_com(l):
            continue
        # EL LADO DEL GUION SE MIRA CON LAS MISMAS GAFAS QUE EL DEL BANCO, y hasta
        # la cuarta vuelta no. Aqui se casaba la linea CRUDA, asi que un nombre de
        # funcion dentro de un `note "...seal_artifact..."` entraba en sitios[] como
        # si fuera una llamada. El ancla de `desnuda` tapaba casi todo el dano -una
        # cita dentro de comillas no empieza la linea- pero la asimetria es el
        # defecto: dos lados de la misma comparacion leidos con dos reglas. Una
        # guarda cuya cuenta depende de que nadie escriba el nombre en un mensaje se
        # apaga el dia que alguien mejore un mensaje.
        l = solo_codigo(l)
        if not pat.search(l):
            continue
        s = l.strip()
        desnuda = bool(re.match(r'^' + re.escape(n) + r'(\s|$)', s))
        sitios[n].append((k + 1, dentro_de(k), 'DESNUDO' if desnuda else 'VALOR'))

b = io.open(banco, encoding='utf-8').read().split('\n')
filas, ini = [], 0
for k, l in enumerate(b):
    m = re.match(r'^\s*(fila|roja|no_aplica)\s+(\S+)', l)
    if m:
        # LA DEFINICION DE `roja` NO ES UNA FILA. `roja` esta escrita en terminos de
        # `fila`, con un `fila "${id}" ...` dentro de su cuerpo, y ese renglon casa
        # este patron como cualquier otro. Un id que no es un literal es el ayudante
        # y no una fila del banco, y contarlo inflaba la cifra que esta casa archiva.
        if not re.match(r'^[0-9A-Za-z]+$', m.group(2)):
            continue
        filas.append({'id': m.group(2), 'cuerpo': b[ini:k + 1]})
        ini = k + 1

if len(filas) < 50:
    print('test: VACIO. Solo %d filas extraidas de %s' % (len(filas), banco), file=sys.stderr)
    raise SystemExit(1)

# LA PROSA DE UNA FILA NO CUENTA COMO INVOCACION, y la primera version de este
# guion la contaba. Se midio quitandole a una fila la llamada que da su cobertura:
# la guarda siguio verde, porque el NOMBRE de la funcion seguia apareciendo dentro
# del texto que la fila imprime. Una guarda que confunde nombrar con llamar dice
# que todo esta cubierto en cuanto alguien escriba la palabra, que es la forma mas
# barata de un verde falso.
#
# LO QUE SI CUENTA: el codigo. Se conservan las sustituciones $(...), que es donde
# una fila llama de verdad, y se tira todo lo que quede entre comillas, que es
# donde una fila HABLA. El orden importa: primero se apartan las sustituciones,
# luego se borra la prosa, y solo entonces se busca.
# Y EL PATRON SIN COMILLAS TAMPOCO ES UNA LLAMADA. `solo_codigo` ya deja fuera
# `grep -q 'phase_cut_fierro'`, porque el patron va entrecomillado; un
# `grep -c phase_cut_fierro gate/p2.sh` a pelo se colaba y contaba como si la fila
# EJERCIERA la fase. Ninguna fila del banco lo hacia el 9 de septiembre de 2026
# -se midio antes de escribir esto, y salieron cero- asi que esto no arregla nada
# que estuviera roto: cierra la puerta antes de que alguien la use, que es cuando
# sale barato. La direccion del fallo es la peligrosa, la de dar por cubierto.
_BUSCADORES = re.compile(r'\b(?:grep|egrep|fgrep|sed|awk)\b((?:\s+-{1,2}[A-Za-z0-9-]+)*)\s+(\S+)')

def sin_patron(l):
    return _BUSCADORES.sub(lambda m: 'grep' + m.group(1) + ' ', l)

for f in filas:
    txt = [sin_patron(solo_codigo(l)) for l in f['cuerpo'] if not es_com(l)]
    inv = set()
    for n in defs:
        p = re.compile(r'(?<![A-Za-z0-9_$"])' + re.escape(n) + r'(?![A-Za-z0-9_])')
        if any(p.search(l) for l in txt):
            inv.add(n)
    f['invoca'] = inv

ejercidas = set()
for f in filas:
    ejercidas |= f['invoca']

# LA COBERTURA SE PROPAGA POR EL GRAFO, y no hacerlo era el mismo defecto que este
# guion existe para cazar, cometido por el guion. `ejercidas` era el conjunto de
# nombres que alguna fila escribe LITERALMENTE. Con eso, una fila que corre
# `phase_cut` con ES_FIERRO=1 -y que por tanto recorre `phase_cut_fierro` entera,
# que es justo la forma buena- dejaba a `phase_cut_fierro` FUERA de las ejercidas,
# y los sitios que viven dentro de ella salian descubiertos. La guarda premiaba
# llamar a la pieza por su nombre y castigaba entrar por el circuito. Se midio el
# 9 de septiembre de 2026 al enrutar la 17ia por el despacho: tres pares aparecieron
# de golpe sobre un banco que acababa de mejorar.
#
# LO QUE SE PROPAGA Y LO QUE NO: si una fila ejerce f, se dan por alcanzadas las
# funciones cuyo sitio de llamada vive DENTRO del cuerpo de f, y asi hacia abajo.
# Es una sobre-aproximacion consciente: una llamada en una rama no tomada cuenta
# igual. La misma sobre-aproximacion que ya se hacia para las llamadas directas,
# porque ejercer una funcion tampoco garantiza recorrer todas sus lineas. Lo que
# NO se propaga es `main`, que no lo ejerce ninguna fila y por eso no arrastra el
# guion entero; el dia que alguna lo ejerza, esta guarda se apaga sola y la linea
# de abajo tiene que volverse a pensar.
llama = collections.defaultdict(set)
for n in sitios:
    for (_, c, _t) in sitios[n]:
        if c:
            llama[c].add(n)
alcanzadas, frontera = set(ejercidas), list(ejercidas)
while frontera:
    f = frontera.pop()
    for g in llama.get(f, ()):
        if g not in alcanzadas:
            alcanzadas.add(g)
            frontera.append(g)

sin_cubrir = []
for f in filas:
    for n in sorted(f['invoca']):
        if n in CONTABILIDAD:
            continue
        for (_, c, t) in sitios[n]:
            if t != 'DESNUDO' or not c or c in alcanzadas:
                continue
            sin_cubrir.append((f['id'], n, c))

pares = sorted({(n, c) for (_, n, c) in sin_cubrir})
declarados = [p for p in pares if p in DECLARADO]
huerfanos = [p for p in pares if p not in DECLARADO]

print('guion: %s, %d funciones' % (guion.split('/')[-1], len(defs)))
# Y LA CIFRA SE DICE CON SU PREDICADO. Estos son los BLOQUES en que se parte el
# banco, uno por cada `fila`, `roja` o `no_aplica` con id literal. No coincide con
# las filas que el banco EJECUTA y no tiene por que: las dos `no_aplica` son
# alternativas de filas que tambien estan escritas, y hay filas dentro de un `if`
# que solo corren en su rama. Decir "N filas" a secas era declarar una poblacion
# que no era la suya, en un fichero cuyas cifras se archivan y se re-derivan.
print('banco: %s, %d bloques de fila, %d ids distintos'
      % (banco.split('/')[-1], len(filas), len({f['id'] for f in filas})))
print()
print('DECLARADOS, con su razon leida y no contada:')
for (n, c) in declarados:
    print('  %-24s en %-22s %s' % (n, c, DECLARADO[(n, c)]))
print()
if huerfanos:
    print('SIN CUBRIR Y SIN DECLARAR, que es lo que este guion existe para parar:')
    for (n, c) in huerfanos:
        quien = sorted({f for (f, nn, cc) in sin_cubrir if (nn, cc) == (n, c)})
        print('  %-24s su sitio DESNUDO esta en %-20s y lo invocan por su nombre: %s'
              % (n, c, ', '.join(quien)))
print()

# LA GUARDA SE VIGILA A SI MISMA, y la cuarta vuelta del lector la pidio con la
# cuenta puesta: de trece exenciones escritas, el guion solo alcanzaba CINCO. Las
# otras ocho eran cadaveres. Y no eran inocentes: estaban muertas porque el banco
# habia CUBIERTO sus sitios de verdad -las filas del recorrido de al_salir y la
# del despacho por ES_FIERRO- asi que seguian ahi como exenciones vivas para el
# dia en que esa cobertura se perdiera. Una regresion que descubriera el sitio de
# seal_artifact en al_salir habria entrado en silencio, absorbida por una linea
# escrita meses antes para un mundo distinto.
#
# UNA EXENCION QUE YA NO HACE FALTA SE BORRA, no se deja dormida. Un cadaver aqui
# es rojo por la misma razon por la que lo es un par sin declarar: los dos son el
# guion diciendo que algo esta cubierto sin que nadie lo haya vuelto a comprobar.
cadaveres = sorted(p for p in DECLARADO if p not in pares)
if cadaveres:
    print('DECLARACIONES MUERTAS, que exoneran un sitio que ya nadie descubre:')
    for (n, c) in cadaveres:
        print('  %-24s en %-22s ya no aparece como par: o el sitio esta cubierto y '
              'la linea sobra, o la funcion se renombro y la linea miente' % (n, c))
    print()
# LA ETIQUETA DICE PARES Y NO FILAS, que es lo que esta linea cuenta. Decia
# `filas` y publicaba 5 sobre un banco de 129, o sea que la cifra que la casa
# archiva y re-deriva nombraba una poblacion que no era la suya. La cuenta de
# filas del banco va aparte y arriba.
print('RESULTADO: %d pares, %d en FALLA' % (len(pares), len(huerfanos) + len(cadaveres)))
if huerfanos:
    print('test: %d par(es) prueban la PIEZA y no el SITIO, y no estan declarados.' % len(huerfanos), file=sys.stderr)
if cadaveres:
    print('test: %d declaracion(es) muertas: exoneran un sitio que el guion ya no descubre.' % len(cadaveres), file=sys.stderr)
    print('test: o una fila corre la funcion que los llama, o se declaran aqui con su razon.', file=sys.stderr)
    raise SystemExit(1)
print('test: toda funcion con sitio DESNUDO sin ejercer esta declarada con su razon, y ninguna se cuela')
FINDELPYTHON
rc=$?
COMPLETO=1
exit "${rc}"
