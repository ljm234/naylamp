#!/usr/bin/env bash
# p2-preflight.sh: the list that runs BEFORE the Phase 2 iron session, so that
# nobody reads prose with three VMs billing.
#
# It is PART of section 10.11 of the Phase 2 gate proposal turned into an order,
# and the word is part and not all, because an earlier version of this line said
# all and a reader counted. Of that section's five points this script covers the
# TLS material, the sysrq bit and the eight ports; the mutant binary rides inside
# the rehearsal of step 5 with no check of its own. The proposal lives in the
# workspace and never in this repository; where the two disagree the proposal is
# the one that argues and this one is the one that answers.
#
# AND POINT 5, THE FLEET, IS NOW COVERED IN PART, WHICH THESE LINES DENIED UNTIL
# 2026-09-07. They said it was not covered at all, naming the region and
# deallocate among the things left out, and that same day the script gained a
# written REGION used in every create and a `cierre` subcommand that deallocates
# the three and reads that they came back deallocated. A reader measured the
# contradiction. What is still NOT covered: the SKU, the static addresses, and
# powering on one at a time.
#
# THREE SUBCOMMANDS, AND THE SPLIT IS THE WHOLE POINT. `cold` runs with the fleet
# POWERED OFF; `hot` needs the three machines up and takes the three OS disk
# snapshots the iron session may not run without; `cierre` shuts the three down,
# retires those snapshots and counts that zero remain. Everything that can be
# answered before spending is answered before spending, so a run that was going
# to die on a precondition dies on this laptop instead of on the fleet. `cold`
# refuses to report ready if anything fails, and the session does not power
# anything on until it does.
#
# WHY IT EXISTS AT ALL, measured on 2026-09-06: gate/out/certs had been expired
# since 2026-08-11 and nobody had noticed, because gate/p1.sh does not use TLS and
# never looks. The Phase 2 gate does, and that would have surfaced with the fleet
# already up. That check is item 1 here and it is first for that reason.
#
# WHAT IT DOES AND DOES NOT DO, and the first version of these two lines said "it
# reads", which is false. `cold` RUNS the rehearsal, so it builds binaries, starts
# eight replicas on loopback, writes their data and kills them. What it does not do
# is power on a VM or deploy anything, and `cold` writes nothing to Azure at all;
# `hot` and `cierre` DO write to Azure, creating and deleting snapshots and
# deallocating machines, and that is said here because the two halves used to be
# described as if neither touched anything. And it writes in three places, not one:
# under gate/out, under the system temp directory (the mutant tree the rehearsal's
# red phase copies, and one snapshot file), and in Go's build cache. The temporary
# ones clean themselves up; saying they do not exist would be another matter.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${GATE_DIR}/.." && pwd)"
OUT_DIR="${GATE_DIR}/out"
CERT_DIR="${OUT_DIR}/certs"

NODE_IDS=(1 2 3)
CLIENT_ID=90
# The eight loopback ports the rehearsal binds, four for the sane fleet and four
# for the mutant one. They are the same eight literals as gate/p2.sh:1048 and
# :1064; if this list and that one drift apart, the preflight stops measuring what
# the rehearsal actually binds.
PUERTOS=(19401 19402 19403 19490 19411 19412 19413 19500)

# LA FLOTA, con la region ESCRITA y no heredada. El grupo `naylamp-gate` vive en
# westus2 y todo su contenido en centralus, medido con `az group show` el 7 de
# septiembre de 2026, asi que un `az ... create` que no pase -l hereda la del grupo
# y sale con RequestDisallowedByAzure por politica de la suscripcion. En la prueba
# de una sola VM eso costo el primer intento del snapshot y era gratis; en fierro
# costaria con las tres cobrando. Por eso la region va aqui y en cada create.
GRUPO=NAYLAMP-GATE
REGION=centralus
VMS=(naylamp-1 naylamp-2 naylamp-3)
SNAP_SUFIJO=osdisk-antes-del-gate-p2
# La FAMILIA es mas ancha que el sufijo de esta sesion a proposito: el brazo de una
# sola VM del 7 de septiembre de 2026 dejo `naylamp-1-osdisk-antes-de-sysrq`, con
# otro sufijo, y un rotulo que dice "cero snapshots de gate" tiene que contarlo. La
# version anterior contaba solo `ends_with(SNAP_SUFIJO)` y prometia mas de lo que
# media.
SNAP_FAMILIA=osdisk-antes-de

FALLOS=0
PASOS_MAL=0
declare -a PASOS_NOMBRE=()
declare -a PASOS_FALLA=()

paso() {
	PASOS_NOMBRE+=("$*")
	PASOS_FALLA+=(0)
	printf '\n[%d] %s\n' "${#PASOS_NOMBRE[@]}" "$*"
}
ok()   { printf '    OK    %s\n' "$*"; }
mal()  {
	FALLOS=$((FALLOS + 1))
	local i=$(( ${#PASOS_NOMBRE[@]} - 1 ))
	if [ "${i}" -ge 0 ] && [ "${PASOS_FALLA[$i]}" -eq 0 ]; then
		PASOS_FALLA[$i]=1
		PASOS_MAL=$((PASOS_MAL + 1))
	fi
	printf '    FALLA %s\n' "$*"
}
dato() { printf '          %s\n' "$*"; }

# `az` no esta en el PATH de todas las sesiones de esta maquina y la sesion puede
# haber caducado. Las dos cosas se distinguen de "no hay snapshots", igual que el
# paso de `lsof` distingue "no escucha nadie" de "no se pudo preguntar".
# TODA lectura de `az` va con `|| true` y se juzga por su CONTENIDO, nunca por su
# codigo de salida directo. Con `set -euo pipefail`, una asignacion por sustitucion
# de orden hereda el rc de `az`, y un token caducado a mitad, un 429 de throttling o
# un `ResourceNotFound` transitorio matan el guion entero SIN imprimir nada. En
# `cierre` esa muerte cae DESPUES del `deallocate` y ANTES de retirar los snapshots,
# o sea que deja tres snapshots facturando y ni una linea que lo diga. Medido el 7 de
# septiembre de 2026: `az vm show` sobre una VM inexistente sale con rc=3 y la linea
# siguiente no llega a ejecutarse. Las lecturas por `ssh` de este mismo guion ya lo
# llevaban; las de `az` no, y eso era un descuido y no una decision.
az_lee() { "${AZ}" "$@" 2>/dev/null || true; }

AZ=""
hay_az() {
	if [ -n "${AZ}" ]; then return 0; fi
	if command -v az >/dev/null 2>&1; then AZ="$(command -v az)"
	elif [ -x /opt/homebrew/bin/az ]; then AZ=/opt/homebrew/bin/az
	else return 1; fi
	"${AZ}" account show >/dev/null 2>&1 || { AZ=""; return 1; }
	return 0
}
nombre_snap() { printf '%s-%s' "$1" "${SNAP_SUFIJO}"; }

# ---- la mitad FRIA: la flota apagada, coste cero ------------------------------

frio() {
	echo "PREFLIGHT DE LA SESION DE FIERRO DE PHASE 2, mitad FRIA"
	echo "fecha: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "maquina: $(sysctl -n hw.model 2>/dev/null || uname -m), $(uname -sr)"
	echo "arbol: ${REPO_DIR}"
	echo "Nada de lo que sigue enciende una VM ni cuesta un centimo."

	paso "El arbol: limpio, firmado y con su CI verde"
	local sucio head firma
	sucio="$(cd "${REPO_DIR}" && git status --porcelain | wc -l | tr -d ' ')"
	head="$(cd "${REPO_DIR}" && git rev-parse HEAD)"
	firma="$(cd "${REPO_DIR}" && git log -1 --format='%G?')"
	dato "HEAD ${head}"
	if [ "${sucio}" -eq 0 ]; then
		ok "arbol limpio"
	else
		local plural=s; [ "${sucio}" -eq 1 ] && plural=""
		mal "el arbol lleva ${sucio} entrada${plural} sin commitear; la corrida se anclaria a un arbol que no existe en ningun sitio"
		( cd "${REPO_DIR}" && git status --porcelain | sed 's/^/          /' )
		dato "se firman o se retiran antes de encender; este guion no lo hace"
	fi
	[ "${firma}" = G ] && ok "la firma de HEAD verifica" || mal "git log -1 --format='%G?' devuelve [${firma}] y no G"
	# El verde de CI se pregunta si gh esta y hay red; si no, se dice que no se
	# comprobo, en vez de callarlo. Un paso que no puede correr no es un paso verde.
	if command -v gh >/dev/null 2>&1 || [ -x /opt/homebrew/bin/gh ]; then
		local GH concl
		GH="$(command -v gh || echo /opt/homebrew/bin/gh)"
		concl="$("${GH}" run list --limit 20 --json headSha,conclusion 2>/dev/null \
			| /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print(next((r['conclusion'] for r in d if r['headSha']=='${head}'),'sin corrida'))" 2>/dev/null || echo 'no se pudo preguntar')"
		[ "${concl}" = success ] && ok "CI verde para este HEAD" || mal "CI para este HEAD dice [${concl}]"
	else
		dato "gh no esta en esta maquina: el verde de CI NO se comprobo, y eso no es un verde"
	fi

	paso "El material TLS, que es el punto que nadie mira hasta tener la flota arriba"
	dato "dura 24 h desde que se acuna, engine/cluster/tlstest/tlstest.go:55 y :90"
	local id falta=0
	for id in "${NODE_IDS[@]}" "${CLIENT_ID}"; do
		[ -f "${CERT_DIR}/node-${id}.pem" ] || { mal "no hay certificado para el id ${id}"; falta=1; continue; }
		[ -f "${CERT_DIR}/node-${id}-key.pem" ] || { mal "no hay clave privada para el id ${id}"; falta=1; continue; }
		if ! openssl x509 -in "${CERT_DIR}/node-${id}.pem" -noout -checkend 7200 >/dev/null 2>&1; then
			mal "el certificado del id ${id} esta caducado o le quedan menos de dos horas"; falta=1
		fi
	done
	if [ -f "${CERT_DIR}/ca.pem" ]; then
		dato "CA hasta $(openssl x509 -in "${CERT_DIR}/ca.pem" -noout -enddate | cut -d= -f2)"
		openssl x509 -in "${CERT_DIR}/ca.pem" -noout -checkend 7200 >/dev/null 2>&1 \
			|| { mal "el CA esta caducado o le quedan menos de dos horas"; falta=1; }
	else
		mal "no hay CA"; falta=1
	fi
	if [ "${falta}" -eq 1 ]; then
		dato "se arregla con:  cd ${REPO_DIR} && ./gate/build.sh"
		dato "y se re-corre este paso; build.sh re-acuna el conjunto entero"
	else
		ok "material TLS completo y no caduca en las proximas dos horas"
	fi

	paso "Los OCHO puertos de loopback que el ensayo enlaza"
	# SE DISTINGUE "no escucha nadie" DE "no se pudo preguntar", y la primera
	# version no lo hacia: `lsof` devuelve 1 con el puerto libre y tambien falla
	# con 127 si no esta instalado, y el `if` era falso en los dos casos, o sea que
	# sin `lsof` esta comprobacion decia "los ocho libres" sin haber mirado. Es la
	# misma distincion que el paso del CI si hace tres pasos mas arriba.
	if ! command -v lsof >/dev/null 2>&1; then
		mal "lsof no esta en esta maquina, asi que los puertos NO se comprobaron, y eso no es un verde"
	else
		local p ocupados=0 quien
		for p in "${PUERTOS[@]}"; do
			quien="$(lsof -nP -iTCP:"${p}" -sTCP:LISTEN -Fcp 2>/dev/null | tr '\n' ' ' || true)"
			if [ -n "${quien}" ]; then
				mal "el puerto ${p} ya esta escuchando: ${quien}"; ocupados=1
			fi
		done
		[ "${ocupados}" -eq 0 ] && ok "los ocho libres"
	fi

	paso "Nada del ensayo vivo de una corrida anterior"
	# La instantanea se toma a un fichero con una orden que NO lleva el patron
	# dentro, y se filtra despues; y el filtro va anclado a la ruta del binario.
	# Es la clausula 24, y el motivo es que un predicado por subcadena se encuentra
	# a si mismo. Lo que esta forma NO ve es un daemon lanzado por nombre desnudo,
	# y eso va dicho porque el falso negativo es aqui el fallo grave.
	# La instantanea lleva el pid, y se lee ANTES de borrarla: la primera version
	# contaba las replicas y tiraba la prueba antes de imprimir el mensaje, asi que
	# decia cuantas habia sin decir cuales.
	local instantanea vivos quienes
	instantanea="$(mktemp -t naylamp-p2-pre)"
	ps -Ao pid,args > "${instantanea}"
	vivos="$(grep -cE '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${instantanea}" || true)"
	quienes="$(grep -E '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${instantanea}" | awk '{print $1}' | tr '\n' ' ' || true)"
	rm -f -- "${instantanea}"
	if [ "${vivos}" -eq 0 ]; then
		ok "cero replicas del ensayo corriendo"
	else
		mal "${vivos} replicas del ensayo siguen vivas, pids: ${quienes}"
		dato "se matan una a una por pid literal antes de seguir"
	fi

	paso "Ningun snapshot de una sesion anterior sin retirar"
	# La sesion de fierro crea TRES y los retira al apagar. Uno que sobreviva es una
	# sesion que no cerro, y ademas se esta cobrando su almacenamiento. Se mira en
	# FRIO porque aqui no cuesta nada mirarlo.
	# EL FALLO ES DURO Y NO UN AVISO, y la version anterior lo dejaba en `dato`, que no
	# toca el contador: `cold` imprimia LISTO PARA ENCENDER en la misma corrida en la
	# que acababa de escribir "eso no es un verde". Y la misma precondicion es dura en
	# `hot`, con las tres cobrando, o sea que el guion negaba su propia cabecera: lo
	# que se puede contestar antes de gastar se contesta antes de gastar.
	if ! hay_az; then
		mal "az no esta o su sesion caduco, asi que ni los snapshots ni el cierre podran correr, y eso no es un verde"
		dato "se arregla con: az login"
	else
		local sobran
		sobran="$(az_lee snapshot list -g "${GRUPO}" --query "[?contains(name,'${SNAP_FAMILIA}')].name" -o tsv | tr '\n' ' ')"
		if [ -z "${sobran}" ]; then
			ok "cero snapshots de gate sin retirar"
		else
			mal "quedan snapshots de una sesion anterior: ${sobran}"
			dato "se retiran con: ./gate/p2-preflight.sh cierre"
		fi
	fi

	paso "El ensayo en localhost, VERDE sobre el arbol que se va a gatear"
	dato "corriendo NAYLAMP_P2_LOCAL=1 ./gate/p2.sh all, unos dos minutos"
	# La extension es .txt y no .log a proposito, y la razon es de limpieza: la
	# regla `clean` del Makefile barre lo que hay en gate/out salvo `certs` y salvo
	# los `*.log`, asi que un log de preflight se acumularia para siempre. Esto es
	# diagnostico y no evidencia, de modo que se nombra para que el barrido que ya
	# existe se lo lleve, en vez de escribir un barrido nuevo.
	local log rc
	log="${OUT_DIR}/preflight-$(date -u '+%Y%m%dT%H%M%SZ').txt"
	mkdir -p "${OUT_DIR}"
	set +e
	( cd "${REPO_DIR}" && NAYLAMP_P2_LOCAL=1 ./gate/p2.sh all ) > "${log}" 2>&1
	rc=$?
	set -e
	dato "salida en $(basename "${log}")"
	if [ "${rc}" -eq 0 ] && grep -q 'all rehearsal checks passed' "${log}"; then
		ok "el ensayo cierra verde: $(grep -c 'gate: verdict .* = pass' "${log}") veredictos en pass y $(grep -c 'gate: NOT RUN' "${log}") declarados NOT RUN"
	else
		# El fallo NOMBRA el veredicto rojo, que esta a un grep de distancia, en vez
		# de mandar a mirar un fichero.
		local rojos
		rojos="$(grep -oE 'gate: verdict [A-Za-z0-9.]+ = (fail|none)' "${log}" | awk '{print $3}' | tr '\n' ' ' || true)"
		mal "el ensayo NO cerro verde, rc=${rc}; sin pass: ${rojos:-ninguno registrado}"
		dato "el detalle esta en $(basename "${log}")"
	fi

	# D4: EL ENSAYO LEVANTA OCHO REPLICAS Y LAS MATA, asi que la comprobacion de
	# fugas del paso anterior queda vieja en cuanto este paso corre. Se vuelve a
	# mirar, porque este guion vigila una fuga que el mismo puede producir.
	paso "Y nada vivo DESPUES del ensayo, que es lo que este guion puede haber dejado"
	local ins2 v2 q2
	ins2="$(mktemp -t naylamp-p2-pre)"
	ps -Ao pid,args > "${ins2}"
	v2="$(grep -cE '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${ins2}" || true)"
	q2="$(grep -E '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${ins2}" | awk '{print $1}' | tr '\n' ' ' || true)"
	rm -f -- "${ins2}"
	[ "${v2}" -eq 0 ] && ok "el ensayo no dejo ninguna replica viva" || mal "${v2} replicas vivas tras el ensayo, pids: ${q2}"

	# EL RESUMEN NO DIVIDE DOS CLASES, y la primera version si lo hacia: contaba
	# FALLOS, que son llamadas a mal(), sobre PASOS, que son llamadas a paso(). Las
	# dos cifras no comparten denominador porque un solo paso puede anotar varios
	# motivos: el paso de los puertos llama a mal() dentro de un bucle y con los ocho
	# ocupados anota ocho motivos el solo.
	#
	# Y AQUI YA NO VA NINGUN CARDINAL, que es la correccion de la novena pasada del 7
	# de septiembre de 2026 y la tercera que necesita esta frase. Las dos anteriores
	# declaraban cuantos sitios llaman a mal() en este fichero: la primera dijo
	# "catorce dentro de bucles", que no daba catorce por ninguna de sus dos mitades,
	# y la segunda dijo 19 y 13, que era el recuento del 6 de septiembre dejado sin
	# re-contar mientras el fichero crecia; al arreglarla ese mismo dia salieron 31 y
	# 14, y al terminar la pasada ya eran 34 y 16, porque las propias correcciones
	# anaden llamadas. Una cifra del fichero escrita DENTRO del fichero caduca cada
	# vez que alguien lo toca, y quien la quiera la cuenta:
	#   grep -oE '(^|[^A-Za-z_])mal "' gate/p2-preflight.sh | wc -l
	# Es la clausula 11 del protocolo, el cardinal pegado a su propia lista.
	echo
	echo "RESUMEN DE LA MITAD FRIA"
	echo "    comprobaciones: ${#PASOS_NOMBRE[@]}, con fallo: ${PASOS_MAL}, motivos anotados: ${FALLOS}"
	if [ "${FALLOS}" -eq 0 ]; then
		echo "    LISTO PARA ENCENDER."
		echo "    Lo siguiente NO lo hace este guion: az vm start una a una, y despues"
		echo "    ./gate/p2-preflight.sh hot, que lee sysrq en los tres, TOMA LOS TRES"
		echo "    SNAPSHOTS y vuelve a mirar el material TLS."
	else
		echo "    NO SE ENCIENDE NADA. Lo que falla:"
		local k
		for k in "${!PASOS_NOMBRE[@]}"; do
			[ "${PASOS_FALLA[$k]:-0}" -eq 1 ] && echo "      - ${PASOS_NOMBRE[$k]}"
		done
	fi
	return "$(( FALLOS > 0 ? 1 : 0 ))"
}

# ---- la mitad CALIENTE: exige las tres arriba ---------------------------------

caliente() {
	echo "PREFLIGHT DE LA SESION DE FIERRO DE PHASE 2, mitad CALIENTE"
	echo "fecha: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "Esto EXIGE las tres VMs arriba, o sea que ya se esta pagando."
	: "${NAYLAMP_GATE_HOSTS:?la mitad caliente necesita NAYLAMP_GATE_HOSTS}"
	: "${NAYLAMP_GATE_KEY:?la mitad caliente necesita NAYLAMP_GATE_KEY}"
	: "${NAYLAMP_GATE_USER:=ubuntu}"

	local hosts h i=0
	IFS=',' read -r -a hosts <<< "${NAYLAMP_GATE_HOSTS}"

	# EL NUMERO DE HOSTS SE CUENTA, y no se daba por supuesto: con una sola entrada
	# en la variable, la version anterior imprimia "host 1 contesta" y cerraba con
	# las precondiciones cumplidas, con la flota facturando.
	paso "La variable trae TRES hosts"
	if [ "${#hosts[@]}" -eq 3 ]; then
		ok "tres hosts: ${hosts[*]}"
	else
		mal "NAYLAMP_GATE_HOSTS trae ${#hosts[@]} y no 3; la corrida de quorum necesita tres"
	fi

	paso "Los tres hosts contestan"
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		# ConnectTimeout acota la CONEXION y no la ejecucion: un host que acepta TCP
		# y se cuelga en el shell dejaria esto bloqueado con la flota pagando. Las
		# dos guardas de servidor vivo ponen la cota que faltaba, que es lo que la
		# clausula 24 del protocolo obliga: una espera lleva cota.
		if ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" true 2>/dev/null; then
			ok "host ${i} (${h}) contesta"
		else
			mal "host ${i} (${h}) no contesta por ssh"
		fi
	done

	paso "El bit de reinicio de sysrq en los tres, que es lo que hace que el corte corte"
	dato "Ubuntu documenta 176 por defecto, y eso es cita y no medida de estas maquinas"
	# EL VALOR NO ES UNA MASCARA PURA, y la primera version de esta guarda lo trato
	# como si lo fuera. /proc/sys/kernel/sysrq vale 0 para DESACTIVADO, 1 para TODAS
	# las funciones habilitadas, y solo por encima de 1 es mascara de bits. Con
	# sysrq=1 el reinicio esta permitido y 1 & 128 da 0, asi que el predicado viejo
	# habria dicho "SIN el bit de reinicio" sobre un host que si corta, y con las
	# tres cobrando. Se comprueba el 1 aparte y antes.
	i=0
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		local v
		v="$(ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'cat /proc/sys/kernel/sysrq 2>/dev/null' 2>/dev/null || true)"
		case "${v}" in
			''|*[!0-9]*)
				mal "host ${i}: /proc/sys/kernel/sysrq no se pudo leer o no devolvio un numero, dio [${v}]" ;;
			0)
				mal "host ${i}: sysrq=0, sysrq esta DESACTIVADO entero; el corte no cortaria y el gate seria un verde vacio" ;;
			1)
				ok "host ${i}: sysrq=1, que es TODAS las funciones habilitadas, asi que el reinicio esta permitido" ;;
			*)
				if [ $(( v & 128 )) -ne 0 ]; then
					ok "host ${i}: sysrq=${v}, el bit de reinicio esta"
				else
					mal "host ${i}: sysrq=${v}, SIN el bit de reinicio; el corte no cortaria y el gate seria un verde vacio"
				fi ;;
		esac
	done

	# LOS TRES SNAPSHOTS, Y NO SON OPCIONALES. La decision es del 7 de septiembre de
	# 2026 y sale de una medida que NO es de este guion, y por eso va con su sitio: la
	# corrida de la prueba de una sola VM leyo `Total Regional vCPUs: 6 de 6` y esta
	# archivada en corridas/naylamp-sysrq-1vm-20260907T0013Z.txt. Este guion no lee
	# cuota en ningun sitio, y la version anterior de este comentario se atribuia esa
	# lectura. Lo que la cifra dice es que una VM de rescate no cabia ese dia. El gate corta las TRES a la vez, asi que no
	# queda ninguna sana desde la que mirar ni sitio para levantar una. El snapshot
	# es lo unico que devuelve la flota bajo la que se sellaron los artefactos de
	# Phase 1. La prueba de una sola VM tenia margen que esta sesion no tiene.
	#
	# Y VAN CON SU REGION ESCRITA, por lo que dice el bloque de constantes.
	#
	# LO QUE ESTOS SNAPSHOTS SON Y LO QUE NO: se toman con las tres ENCENDIDAS, asi
	# que son consistentes ante caida y no ante aplicacion, que es exactamente lo que
	# se querria restaurar tras un corte. El de la prueba del 7 de septiembre se tomo
	# con la maquina apagada y era limpio; este no lo es, y va dicho aqui en vez de
	# descubrirse el dia que haya que restaurar.
	paso "Los TRES snapshots de disco de sistema, antes de gatear nada"
	if ! hay_az; then
		mal "az no esta o su sesion caduco, asi que los snapshots NO se tomaron, y sin ellos no se gatea"
	else
		local v disco snap hechos=0
		for v in "${VMS[@]}"; do
			snap="$(nombre_snap "${v}")"
			# "YA EXISTE" NO ES "ES BUENO", y la version anterior lo daba por bueno con
			# `--query name`, que triunfa con cualquier snapshot que exista, sea de hace
			# diez minutos o de hace una semana y este `Succeeded` o `Failed`. Con la
			# guarda de `cold` esquivada, esa via llegaba a `hechos=3` sin haber tomado
			# ni uno, y el gate corta las tres fiandose de discos viejos. Se leen el
			# estado y la fecha, y solo cuenta el que esta bueno y es de hoy.
			local estado_snap fecha_snap
			estado_snap="$(az_lee snapshot show -g "${GRUPO}" -n "${snap}" --query provisioningState -o tsv)"
			fecha_snap="$(az_lee snapshot show -g "${GRUPO}" -n "${snap}" --query timeCreated -o tsv)"
			if [ -n "${estado_snap}" ]; then
				if [ "${estado_snap}" = Succeeded ] && [ "${fecha_snap%%T*}" = "$(date -u '+%Y-%m-%d')" ]; then
					ok "${snap} ya existe, ${estado_snap}, del ${fecha_snap%%T*}"
					hechos=$((hechos + 1))
				else
					mal "${snap} existe pero esta [${estado_snap}] y es del [${fecha_snap%%T*}]; se retira con cierre y se vuelve a tomar"
				fi
				continue
			fi
			disco="$(az_lee vm show -g "${GRUPO}" -n "${v}" --query "storageProfile.osDisk.managedDisk.id" -o tsv)"
			if [ -z "${disco}" ]; then
				mal "no se pudo leer el disco de sistema de ${v}"; continue
			fi
			if "${AZ}" snapshot create -g "${GRUPO}" -n "${snap}" -l "${REGION}" \
				--source "${disco}" --sku Standard_LRS --incremental true \
				--query provisioningState -o tsv 2>/dev/null | grep -q '^Succeeded$'; then
				ok "${snap} creado en ${REGION}"
				hechos=$((hechos + 1))
			else
				mal "no se pudo crear ${snap}; sin los tres no se gatea"
			fi
		done
		[ "${hechos}" -eq 3 ] || mal "hay ${hechos} snapshots de 3, y la decision es que van los TRES"
	fi

	# EL HUECO QUE 10.11 NOMBRA Y QUE NADIE CUBRIA: entre correr build.sh y arrancar
	# la corrida pasa tiempo, y el material dura 24 h desde que se acuna. Aqui se
	# vuelve a mirar con la flota ya arriba, que es el ultimo momento util.
	paso "El material TLS, RE-LEIDO ahora que la flota esta arriba"
	local id2 caduca=0
	for id2 in "${NODE_IDS[@]}" "${CLIENT_ID}"; do
		openssl x509 -in "${CERT_DIR}/node-${id2}.pem" -noout -checkend 7200 >/dev/null 2>&1 \
			|| { mal "el certificado del id ${id2} caduca dentro de dos horas o ya caduco"; caduca=1; }
	done
	openssl x509 -in "${CERT_DIR}/ca.pem" -noout -checkend 7200 >/dev/null 2>&1 \
		|| { mal "el CA caduca dentro de dos horas o ya caduco"; caduca=1; }
	if [ "${caduca}" -eq 0 ]; then
		ok "el material sigue vigente: CA hasta $(openssl x509 -in "${CERT_DIR}/ca.pem" -noout -enddate | cut -d= -f2)"
		dato "esa fecha tiene que ser POSTERIOR al final previsto de la corrida, y una de Phase 2 no la ha cronometrado nadie"
	fi

	echo
	echo "RESUMEN DE LA MITAD CALIENTE"
	echo "    comprobaciones: ${#PASOS_NOMBRE[@]}, con fallo: ${PASOS_MAL}, motivos anotados: ${FALLOS}"
	if [ "${FALLOS}" -eq 0 ]; then
		echo "    LO QUE ESTA MITAD MIRA SE CUMPLE, y son cinco cosas y no la lista entera:"
		echo "    tres hosts en la variable, los tres contestan, el bit de reinicio en los tres,"
		echo "    los TRES snapshots tomados, y el material TLS todavia vigente. Lo que NO mira,"
		echo "    y sigue siendo de quien opera: el SKU y la region de las VMs, que las IPs sean"
		echo "    las de siempre, y que se encendieran una a una. El apagado ya no esta en esta"
		echo "    lista porque lo hace 'cierre', y los snapshots se retiran ahi."
	else
		echo "    Hay fallos. Con la flota encendida, la decision de seguir o apagar es de quien"
		echo "    encarga, y este guion no la toma. Lo que falla:"
		local k
		for k in "${!PASOS_NOMBRE[@]}"; do
			[ "${PASOS_FALLA[$k]:-0}" -eq 1 ] && echo "      - ${PASOS_NOMBRE[$k]}"
		done
	fi
	return "$(( FALLOS > 0 ? 1 : 0 ))"
}

# ---- el APAGADO, que era prosa y ahora se corre ---------------------------------

cierre() {
	echo "CIERRE DE LA SESION DE FIERRO DE PHASE 2"
	echo "fecha: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "Apaga las tres, retira los tres snapshots y comprueba que quedan CERO."

	# El aviso va DENTRO de un paso, y no antes de que exista ninguno: la version
	# anterior salia con "comprobaciones: 0, con fallo: 0, motivos anotados: 1", o sea
	# que la corrida que mas necesita gritar que no se apago nada era la que peor lo
	# decia.
	paso "az disponible, que es lo que hace falta para apagar y para retirar"
	if ! hay_az; then
		mal "az no esta o su sesion caduco: NO se apago nada y NO se retiro nada, y las tres siguen cobrando"
		dato "se arregla con: az login, y se vuelve a correr este mismo subcomando"
		echo
		echo "RESUMEN DEL CIERRE"
		echo "    comprobaciones: ${#PASOS_NOMBRE[@]}, con fallo: ${PASOS_MAL}, motivos anotados: ${FALLOS}"
		echo "    EL CIERRE NO CORRIO. Lo que falla:"
		echo "      - ${PASOS_NOMBRE[0]}"
		return 1
	fi
	ok "az responde y la sesion vale"

	paso "Apagar las tres con deallocate, que es lo que deja de cobrar"
	local v estado
	for v in "${VMS[@]}"; do
		if "${AZ}" vm deallocate -g "${GRUPO}" -n "${v}" >/dev/null 2>&1; then
			ok "${v} desasignada"
		else
			mal "no se pudo desasignar ${v}, y parada se sigue cobrando el computo"
		fi
	done

	# SE LEE, no se supone. El 26 de agosto de 2026 el apagado se dio por hecho y
	# hubo que ir a comprobarlo despues.
	paso "Y se LEE que las tres quedaron desasignadas"
	for v in "${VMS[@]}"; do
		estado="$(az_lee vm show -d -g "${GRUPO}" -n "${v}" --query powerState -o tsv)"
		[ "${estado}" = "VM deallocated" ] && ok "${v}: ${estado}" \
			|| mal "${v} dice [${estado}] y no [VM deallocated]"
	done

	# SE RETIRA LO QUE EL RECUENTO CUENTA, y no una lista de tres nombres. La version
	# anterior recorria `VMS` y contaba con un patron mas ancho, de modo que un
	# snapshot de la familia con otro nombre lo detectaba `cold`, lo volvia a ver el
	# paso 4 de aqui, y NADIE lo borraba: el remedio que el guion nombra no retiraba lo
	# que el guion detecta. Ahora se pregunta a `az` cuales hay y se borran esos.
	paso "Retirar los snapshots de la familia del gate"
	local snap listado
	listado="$(az_lee snapshot list -g "${GRUPO}" --query "[?contains(name,'${SNAP_FAMILIA}')].name" -o tsv)"
	if [ -z "${listado}" ]; then
		ok "no habia ninguno que retirar"
	else
		while IFS= read -r snap; do
			[ -n "${snap}" ] || continue
			# El nombre viene de `az` y no de aqui, asi que se valida su forma antes de
			# borrar por el. Ninguna orden de borrado corre contra una cadena libre.
			case "${snap}" in
				*"${SNAP_FAMILIA}"*) ;;
				*) mal "el nombre [${snap}] no es de la familia por la que este guion borra"; continue ;;
			esac
			if "${AZ}" snapshot delete -g "${GRUPO}" -n "${snap}" >/dev/null 2>&1; then
				ok "${snap} retirado"
			else
				mal "no se pudo retirar ${snap}, y se sigue cobrando su almacenamiento"
			fi
		done <<< "${listado}"
	fi

	paso "Y quedan CERO, contado y no supuesto"
	local quedan
	quedan="$(az_lee snapshot list -g "${GRUPO}" --query "[?contains(name,'${SNAP_FAMILIA}')].name" -o tsv | tr '\n' ' ')"
	[ -z "${quedan}" ] && ok "cero snapshots de gate en ${GRUPO}" \
		|| mal "todavia quedan: ${quedan}"

	echo
	echo "RESUMEN DEL CIERRE"
	echo "    comprobaciones: ${#PASOS_NOMBRE[@]}, con fallo: ${PASOS_MAL}, motivos anotados: ${FALLOS}"
	if [ "${FALLOS}" -eq 0 ]; then
		echo "    LA SESION QUEDA CERRADA: tres desasignadas leidas una a una y cero snapshots."
	else
		echo "    EL CIERRE NO ESTA LIMPIO, y lo que queda encendido o guardado se cobra. Lo que falla:"
		local k
		for k in "${!PASOS_NOMBRE[@]}"; do
			[ "${PASOS_FALLA[$k]:-0}" -eq 1 ] && echo "      - ${PASOS_NOMBRE[$k]}"
		done
	fi
	return "$(( FALLOS > 0 ? 1 : 0 ))"
}

case "${1:-}" in
	cold)   frio ;;
	hot)    caliente ;;
	cierre) cierre ;;
	*)
		cat >&2 <<'USAGE'
usage: p2-preflight.sh <cold|hot|cierre>

  cold    con la flota APAGADA y coste cero: arbol limpio, firmado y con CI verde;
          material TLS que no caduca en dos horas; los ocho puertos libres; nada
          del ensayo vivo; ningun snapshot de gate sin retirar; y el ensayo en
          localhost verde sobre este arbol.
  hot     con las tres VMs ARRIBA: que contestan por ssh, el bit de reinicio de
          sysrq en las tres, los TRES snapshots de disco de sistema tomados, y el
          material TLS re-leido.
  cierre  al terminar: desasigna las tres, LEE que quedaron desasignadas, retira
          los tres snapshots y comprueba que quedan cero.

No se enciende nada hasta que `cold` sale con 0. Encender sigue siendo un paso a
mano, con az vm start una a una, y no lo hace este guion. Apagar SI lo hace, con
`cierre`, porque el 26 de agosto de 2026 se dio por hecho y hubo que ir a mirarlo.
USAGE
		exit 2
		;;
esac
