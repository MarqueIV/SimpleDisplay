#!/usr/bin/env bash
# test.sh <ip> <logfile>
# Ejercita el apagado real (CGSConfigureDisplayEnabled) dentro de una VM Tart.
# La VM tiene un solo display fisico (la consola); los "monitores" a apagar son
# displays virtuales de la propia app. Verdad de terreno: /tmp/cgprobe en el guest.
set -u
IP=$1; LOG=$2
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password"
# rssh: ssh con reintentos. El sshd del guest rechaza el password a rachas cuando la VM
# esta cargada (relanzamiento de la app + colorsyncd); un 255 se reintenta hasta 4 veces.
rssh() {
  local rc
  for attempt in 1 2 3 4; do
    sshpass -p admin ssh $SSHOPTS admin@$IP "$@" 2> >(grep -v -E 'Permission denied|Received disconnect|Too many authentication' >&2)
    rc=$?
    [ $rc -ne 255 ] && return $rc
    sleep 4
  done
  return 255
}
SSH="rssh"
PASS=0; FAIL=0
log()   { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
sec()   { log ""; log "################ $* ################"; }
url()   { log "-> simpledisplay://$1"; $SSH "open 'simpledisplay://$1'"; }
ctl()   { log "-> simpledisplayctl $*"; $SSH "/usr/local/bin/simpledisplayctl $*"; }
probe() { $SSH "/tmp/cgprobe $*" | tee -a "$LOG"; }
applog(){ $SSH "sudo log show --info --predicate 'subsystem == \"app.simpledisplay\"' --last ${1:-40s} --style compact 2>/dev/null | grep -v '^Timestamp' | grep -vE 'Filtering|^\s*$' | tail -${2:-25}" | sed 's/^/   LOG /' | tee -a "$LOG"; }
status() {
  local out
  for attempt in 1 2 3; do
    out=$($SSH "rm -f /tmp/simpledisplay-status.json; open 'simpledisplay://status'; for i in \$(seq 1 20); do [ -s /tmp/simpledisplay-status.json ] && break; sleep 0.5; done; cat /tmp/simpledisplay-status.json 2>/dev/null")
    [ -n "$out" ] && { echo "$out"; return; }
    log "   (status vacio, reintento $attempt)"; sleep 2
  done
  echo '[]'
}
persisted() { # estado persistido (JSON) via defaults export + plistlib
  $SSH 'defaults export app.simpledisplay - 2>/dev/null' | python3 -c '
import plistlib,sys,json
try:
    d=plistlib.loads(sys.stdin.buffer.read()).get("com.simpledisplay.displayState")
    print(json.dumps(json.loads(d.decode())) if d else "[]")
except Exception:
    print("[]")'
}
show() { # show <json>
  python3 -c '
import json,sys
items=json.loads(sys.argv[1])
print("   %-4s %-10s %-4s %-3s %-4s %-5s %-6s %s" % ("id","name","virt","on","main","hidpi","mirror","mode"))
for d in items:
    print("   %-4s %-10s %-4s %-3s %-4s %-5s %-6s %sx%s" % (d["id"],d["name"],int(d["virtual"]),int(d["on"]),int(d["main"]),int(d["hidpi"]),d.get("mirrorOf",0),d["width"],d["height"]))
' "$1" | tee -a "$LOG"
}
q() { # q <json> <python-expr over items>  (ej: q "$S" "[d['id'] for d in items if d['name']=='Twin'][0]")
  python3 -c 'import json,sys; items=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}
check() { # check <desc> <json> <python-bool-expr>
  local r; r=$(q "$2" "$3")
  if [ "$r" = "True" ]; then PASS=$((PASS+1)); log "   PASS  $1"; else FAIL=$((FAIL+1)); log "   FAIL  $1   [expr: $3 -> ${r:-error}]"; fi
}
check_str() { # check_str <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); log "   PASS  $1 ($2)"; else FAIL=$((FAIL+1)); log "   FAIL  $1   [got '$2' expected '$3']"; fi
}
snap() { # snap <label> -> imprime status+probe y deja el json en $ST
  ST=$(status); log "-- status ($1):"; show "$ST"; probe > /dev/null; }

log "== real-disable VM test  ip=$IP  $(date) =="
log "guest: $($SSH 'sw_vers -productVersion; uname -m' | tr '\n' ' ')"

sec "S0 reset + baseline"
log "-> pkill; defaults delete app.simpledisplay; open -a SimpleDisplay"
$SSH 'pkill -x SimpleDisplay; sleep 1; defaults delete app.simpledisplay 2>/dev/null; rm -f /tmp/simpledisplay-status.json; open -a SimpleDisplay'; sleep 9
snap S0
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual']][0]")
# Modo nativo de la consola = el mayor que ofrece (el actual puede venir degradado por
# preferencias del WindowServer de corridas anteriores).
CONSOLE_W_BOOT=$(probe | grep "PROBE id=$CONSOLE " | grep -o 'modes=\[[^]]*\]' | tr ',' '\n' | grep -v '@2x' | sed 's/[^0-9x]//g' | awk -F x 'NF==2{print $1}' | sort -n | tail -1)
log "consola id=$CONSOLE nativo=${CONSOLE_W_BOOT}px actual=$(q "$ST" "items[0]['width']")px"
check "la consola arranca en su modo nativo" "$ST" "items[0]['width']==$CONSOLE_W_BOOT"
check "solo la consola de la VM, encendida y main" "$ST" "len(items)==1 and items[0]['on'] and items[0]['main']"
log "consola id=$CONSOLE"

sec "S1 crear 2 'Twin' identicos + 1 'Retina' HiDPI"
url "create?width=1280&height=720&name=Twin";  sleep 4
url "create?width=1280&height=720&name=Twin";  sleep 4
url "create?width=1600&height=900&name=Retina&hidpi=true"; sleep 5
snap S1
check "4 displays, todos encendidos" "$ST" "len(items)==4 and all(d['on'] for d in items)"
check "dos filas 'Twin'" "$ST" "len([d for d in items if d['name']=='Twin'])==2"
check "Retina es HiDPI 1600x900" "$ST" "[d for d in items if d['name']=='Retina'][0]['hidpi'] and [d for d in items if d['name']=='Retina'][0]['width']==1600"
TWIN1=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][0]")
TWIN2=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][1]")
RET=$(q "$ST" "[d['id'] for d in items if d['name']=='Retina'][0]")
RET_UUID=$(probe | grep "PROBE id=$RET " | sed 's/.*uuid=\([^ ]*\).*/\1/')
log "ids: TWIN1=$TWIN1 TWIN2=$TWIN2 RET=$RET  RET_UUID=$RET_UUID"

sec "A gemelos: apagar Twin#1, el otro Twin conserva nombre y fila"
ctl disable --id $TWIN1; sleep 7
snap A1
check "Twin#1 sigue listado (fantasma) y apagado" "$ST" "[d for d in items if d['id']==$TWIN1][0]['on']==False"
check "Twin#1 conserva el nombre 'Twin'" "$ST" "[d for d in items if d['id']==$TWIN1][0]['name']=='Twin'"
check "Twin#2 sigue encendido y con nombre 'Twin'" "$ST" "[d for d in items if d['id']==$TWIN2][0]['on'] and [d for d in items if d['id']==$TWIN2][0]['name']=='Twin'"
check "siguen 4 filas (ninguna desaparecio)" "$ST" "len(items)==4"
ONLINE=$(probe | grep -c "PROBE id=$TWIN1 "); check_str "CG: Twin#1 fuera de la lista online (0=si)" "$ONLINE" "0"
ctl enable --id $TWIN1; sleep 9
snap A2
check "Twin#1 encendido de nuevo" "$ST" "[d for d in items if d['id']==$TWIN1][0]['on']"
check "los 4 encendidos" "$ST" "len(items)==4 and all(d['on'] for d in items)"
ONLINE=$(probe | grep -c "PROBE id=$TWIN1 active=1"); check_str "CG: Twin#1 online y activo" "$ONLINE" "1"
applog 60s 12

sec "B HiDPI: apagar y encender Retina, debe volver en HiDPI"
url "disable?id=$RET"; sleep 7
snap B1
check "Retina apagada" "$ST" "[d for d in items if d['id']==$RET][0]['on']==False"
url "enable?id=$RET"; sleep 10
snap B2
check "Retina encendida" "$ST" "[d for d in items if d['id']==$RET][0]['on']"
check "Retina sigue HiDPI 1600x900" "$ST" "[d for d in items if d['id']==$RET][0]['hidpi'] and [d for d in items if d['id']==$RET][0]['width']==1600"
applog 40s 12

sec "Z modo elegido (zoom): via URL y CLI, persiste, sobrevive a cambios de topologia y al relanzar"
ctl mode --name Retina --width 800 --height 600 --hidpi; sleep 7
snap Z1
check "Retina cambio a 800x600 HiDPI (zoom elegido)" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==800 and [d for d in items if d['name']=='Retina'][0]['hidpi']"
url "disable?id=$TWIN1"; sleep 8
snap Z2
check "tras apagar otro display, Retina conserva el modo elegido 800x600 HiDPI" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==800 and [d for d in items if d['name']=='Retina'][0]['hidpi']"
url "enable?id=$TWIN1"; sleep 9
snap Z3
check "tras encenderlo, Retina sigue en 800x600 HiDPI" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==800"
log "-> relanzar: el modo elegido se reaplica"
$SSH 'pkill -x SimpleDisplay; sleep 2; open -a SimpleDisplay'; sleep 14
snap Z4
check "tras relanzar, Retina vuelve en 800x600 HiDPI" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==800 and [d for d in items if d['name']=='Retina'][0]['hidpi']"
url "mode?name=Retina&width=1600&height=900&hidpi=true"; sleep 7
snap Z5
check "de vuelta al modo del panel 1600x900 HiDPI" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==1600 and [d for d in items if d['name']=='Retina'][0]['hidpi']"
P=$(persisted); log "   (mode persistido se limpia al volver al panel: comprobado via status tras relanzar en C)"
url "mode?name=Retina&width=4000&height=3000"; sleep 5
snap Z6
check "un modo que el display no ofrece se rechaza sin cambiar nada" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==1600"
TWIN1=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][0]")
TWIN2=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][1]")
RET=$(q "$ST" "[d['id'] for d in items if d['name']=='Retina'][0]")
applog 90s 12

sec "C reinicio de la app con Retina apagada; reactivar desde la fila fantasma"
url "disable?id=$RET"; sleep 7
snap C1
check "Retina apagada antes de reiniciar" "$ST" "[d for d in items if d['name']=='Retina'][0]['on']==False"
log "-> pkill SimpleDisplay; open -a SimpleDisplay"
$SSH 'pkill -x SimpleDisplay; sleep 2; open -a SimpleDisplay'; sleep 14
snap C2
check "app relanzada: 4 filas" "$ST" "len(items)==4"
check "Retina sigue apagada tras relanzar (estado persistido)" "$ST" "[d for d in items if d['name']=='Retina'][0]['on']==False"
check "los dos Twin encendidos" "$ST" "all(d['on'] for d in items if d['name']=='Twin')"
RET_ONLINE=$(probe | grep -c "px=3200x1800"); check_str "CG: Retina (3200x1800 px) no esta online (0=si)" "$RET_ONLINE" "0"
url "enable?name=Retina"; sleep 10
snap C3
check "Retina reactivada desde el fantasma" "$ST" "[d for d in items if d['name']=='Retina'][0]['on']"
check "Retina volvio en HiDPI" "$ST" "[d for d in items if d['name']=='Retina'][0]['hidpi']"
applog 90s 25
# ids pueden haber cambiado al recrear los virtuales
TWIN1=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][0]")
TWIN2=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][1]")
RET=$(q "$ST" "[d['id'] for d in items if d['name']=='Retina'][0]")
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual']][0]")
log "ids tras reinicio: TWIN1=$TWIN1 TWIN2=$TWIN2 RET=$RET CONSOLE=$CONSOLE"

sec "D quitar un display virtual apagado: no debe dejar fila muerta ni fantasma en el WindowServer"
TWIN2_UUID=$(probe | grep "PROBE id=$TWIN2 " | sed 's/.*uuid=\([^ ]*\).*/\1/'); log "Twin#2 uuid=$TWIN2_UUID"
url "disable?id=$TWIN2"; sleep 7
snap D1
check "Twin#2 apagado" "$ST" "[d for d in items if d['id']==$TWIN2][0]['on']==False"
url "remove?id=$TWIN2"; sleep 9
snap D2
check "la fila de Twin#2 desaparecio al quitarlo (sin fantasma muerto)" "$ST" "len([d for d in items if d['id']==$TWIN2])==0"
check "quedan 3 filas, todas encendidas" "$ST" "len(items)==3 and all(d['on'] for d in items)"
P=$(persisted); log "   persistido: $P"
check_str "persistencia olvido el uuid de Twin#2" "$(python3 -c 'import sys,json; print(any(d["uuid"]==sys.argv[2] for d in json.loads(sys.argv[1])))' "$P" "$TWIN2_UUID")" "False"
log "-> relanzar la app: quien herede el slot de serial de Twin#2 no debe heredar su modo"
$SSH 'pkill -x SimpleDisplay; sleep 2; open -a SimpleDisplay'; sleep 14
snap D3
check "tras relanzar: 3 filas encendidas" "$ST" "len(items)==3 and all(d['on'] for d in items)"
check "Retina sigue 1600x900 HiDPI tras relanzar (serial persistente: no hereda el slot de Twin#2)" "$ST" "[d for d in items if d['name']=='Retina'][0]['hidpi'] and [d for d in items if d['name']=='Retina'][0]['width']==1600"
RET_UUID_NOW=$(probe | grep "px=3200x1800" | sed 's/.*uuid=\([^ ]*\).*/\1/'); check_str "Retina conserva su UUID (identidad) tras relanzar" "$RET_UUID_NOW" "$RET_UUID"
applog 60s 15
# El slot 2 (el de Twin#2) queda libre y el WindowServer recuerda 1280x720 para esa
# identidad: un virtual nuevo con otra config debe salir igual en SU modo configurado.
url "create?width=1600&height=900&name=Retina2&hidpi=true"; sleep 8
snap D4
check "Retina2 (hereda el slot de Twin#2) arranca en 1600x900 HiDPI, no en el 1280x720 recordado" "$ST" "[d for d in items if d['name']=='Retina2'][0]['hidpi'] and [d for d in items if d['name']=='Retina2'][0]['width']==1600"
R2=$(probe | grep -c "px=3200x1800"); check_str "CG: dos displays a 3200x1800 px (Retina y Retina2)" "$R2" "2"
url "remove?name=Retina2"; sleep 6
snap D5
check "Retina2 quitado: quedan 3 filas encendidas" "$ST" "len(items)==3 and all(d['on'] for d in items)"
applog 60s 10
TWIN1=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][0]")
RET=$(q "$ST" "[d['id'] for d in items if d['name']=='Retina'][0]")
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual']][0]")
log "ids: TWIN1=$TWIN1 RET=$RET CONSOLE=$CONSOLE"

sec "H fantasmas sembrados desde una sesion previa: colision de ID y display inexistente"
log "-> pkill; defaults write con 'Phantom' (lastKnownID=$CONSOLE, id vivo de otro display) y 'Orphan' (lastKnownID=9999)"
$SSH 'pkill -x SimpleDisplay; sleep 2'
CUR=$(persisted); log "   persistido antes: $CUR"
NEWHEX=$(python3 -c '
import json,sys
items=json.loads(sys.argv[1]); console=int(sys.argv[2])
items=[d for d in items if d.get("uuid") not in ("FAKE-PHANTOM","FAKE-ORPHAN")]
items.append({"uuid":"FAKE-PHANTOM","isDisabled":True,"isMain":False,"lastKnownID":console,"name":"Phantom"})
items.append({"uuid":"FAKE-ORPHAN","isDisabled":True,"isMain":False,"lastKnownID":9999,"name":"Orphan"})
print(json.dumps(items).encode().hex())' "$CUR" "$CONSOLE")
$SSH "defaults write app.simpledisplay com.simpledisplay.displayState -data $NEWHEX" || log "   FAIL  defaults write fallo"
log "   sembrado: $(persisted)"
$SSH 'open -a SimpleDisplay'; sleep 14
snap H1
check "'Phantom' (ID en colision con la consola) NO se muestra" "$ST" "len([d for d in items if d['name']=='Phantom'])==0"
check "la consola sigue encendida (no se toco el display equivocado)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
check "'Orphan' (ID libre) se muestra como fila apagada placeholder" "$ST" "len([d for d in items if d['name']=='Orphan'])==1 and [d for d in items if d['name']=='Orphan'][0]['on']==False"
url "enable?name=Orphan"; sleep 8
snap H2
check "al intentar encender 'Orphan' inexistente, se olvida la fila" "$ST" "len([d for d in items if d['name']=='Orphan'])==0"
applog 90s 25
PERSIST=$(persisted)
log "   persistido ahora: $PERSIST"
check_str "Orphan quedo con isDisabled=false en persistencia" "$(echo "$PERSIST" | python3 -c 'import sys,json; d=[x for x in json.load(sys.stdin) if x["uuid"]=="FAKE-ORPHAN"]; print(d[0]["isDisabled"] if d else "missing")')" "False"
check_str "Phantom conserva isDisabled=true en persistencia" "$(echo "$PERSIST" | python3 -c 'import sys,json; d=[x for x in json.load(sys.stdin) if x["uuid"]=="FAKE-PHANTOM"]; print(d[0]["isDisabled"] if d else "missing")')" "True"

sec "E apagar el display MAIN (la consola): main debe transferirse antes"
snap E0
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual'] and d['width']>0][0]"); log "consola id=$CONSOLE"
url "disable?id=$CONSOLE"; sleep 9
snap E1
check "consola apagada (fantasma)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']==False"
check "otro display es main ahora" "$ST" "len([d for d in items if d['main'] and d['id']!=$CONSOLE])==1"
check "con el fisico apagado, Retina conserva 1600x900 HiDPI (conjunto de displays distinto)" "$ST" "[d for d in items if d['name']=='Retina'][0]['width']==1600 and [d for d in items if d['name']=='Retina'][0]['hidpi']"
MAINPROBE=$(probe | grep -c "PROBE id=$CONSOLE "); check_str "CG: consola fuera de la lista online (0=si)" "$MAINPROBE" "0"
url "enable?id=$CONSOLE"; sleep 9
snap E2
check "consola encendida de nuevo" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
check "todos encendidos" "$ST" "all(d['on'] for d in items)"
applog 60s 15

sec "G ultimo display visible: cuenta atras, confirmacion headless y recuperacion al arrancar"
hl() { python3 -c 'import sys,json; d=[x for x in json.loads(sys.argv[1]) if x.get("uuid")==sys.argv[2]]; print(d[0].get(sys.argv[3]) if d else "missing")' "$1" "$2" "$3"; }
snap G0
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual'] and d['width']>0][0]")
CONSOLE_UUID=$(probe | grep "PROBE id=$CONSOLE " | sed 's/.*uuid=\([^ ]*\).*/\1/'); log "consola id=$CONSOLE uuid=$CONSOLE_UUID"
url "disable?id=$CONSOLE"; sleep 6
snap G1
check "consola apagada (cuenta atras corriendo)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']==False"
P=$(persisted); check_str "persistido como apagado NO confirmado (headless ausente)" "$(hl "$P" "$CONSOLE_UUID" headless)" "None"
log "   esperando 14 s a que venza la cuenta atras"; sleep 14
snap G2
check "la consola volvio sola al vencer la cuenta atras" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
P=$(persisted); check_str "persistencia: consola isDisabled=false tras revertir" "$(hl "$P" "$CONSOLE_UUID" isDisabled)" "False"
ctl disable --id $CONSOLE --headless; sleep 6
snap G3
check "con headless=true la consola queda apagada" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']==False"
P=$(persisted); check_str "persistido headless=true" "$(hl "$P" "$CONSOLE_UUID" headless)" "True"
log "   esperando 17 s: con headless confirmado no debe revertirse"; sleep 17
snap G4
check "sigue apagada tras 17 s (sin cuenta atras)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']==False"
log "-> relanzar la app: un headless confirmado se reaplica"
$SSH 'pkill -x SimpleDisplay; sleep 2; open -a SimpleDisplay'; sleep 14
snap G5
check "tras relanzar la consola sigue apagada (headless confirmado)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']==False"
url "enable?id=$CONSOLE"; sleep 9
snap G6
check "consola encendida de nuevo" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
check "reencendida desde la fila reconstruida, la consola recupera su modo de arranque (${CONSOLE_W_BOOT}px; modo persistido al apagarla)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['width']==$CONSOLE_W_BOOT"
url "disable?id=$CONSOLE"; sleep 4
log "-> pkill DURANTE la cuenta atras (simula crash); relanzar"
$SSH 'pkill -x SimpleDisplay; sleep 2; open -a SimpleDisplay'; sleep 16
snap G7
check "al arrancar sin pantalla visible y sin headless confirmado, la consola se recupera sola" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
check "y vuelve en su modo de arranque (${CONSOLE_W_BOOT}px)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['width']==$CONSOLE_W_BOOT"
P=$(persisted); check_str "persistencia limpia tras la recuperacion (isDisabled=false)" "$(hl "$P" "$CONSOLE_UUID" isDisabled)" "False"
applog 120s 20

sec "M espejo: solo un display FISICO puede espejar; un virtual como esclavo crashea el WindowServer"
WS0=$($SSH 'pgrep -x WindowServer'); log "WindowServer pid=$WS0"
wscheck() { local ws; ws=$($SSH 'pgrep -x WindowServer'); check_str "$1: el WindowServer sigue siendo el mismo proceso" "$ws" "$WS0"; }
snap M0
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual'] and d['width']>0][0]")
TWIN1=$(q "$ST" "[d['id'] for d in items if d['name']=='Twin'][0]")
MAIN0=$(q "$ST" "[d['id'] for d in items if d['main']][0]"); CONSOLE_W0=$(q "$ST" "[d for d in items if d['id']==$CONSOLE][0]['width']"); log "consola=$CONSOLE (${CONSOLE_W0}px de ancho) twin=$TWIN1 main=$MAIN0"
url "mirror?id=$TWIN1"; sleep 6
snap M1
check "espejar un VIRTUAL se rechaza: Twin sigue sin espejo" "$ST" "[d for d in items if d['id']==$TWIN1][0]['mirrorOf']==0"
wscheck "tras rechazar el espejo del virtual"
ctl mirror --id $CONSOLE; sleep 10
snap M2
wscheck "tras espejar la consola"
check "la consola espeja al display main (un virtual)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['mirrorOf']!=0 and [d for d in items if d['id']==$CONSOLE][0]['mirrorOf']==[d for d in items if d['main']][0]['id']"
check "la consola sigue encendida (espejar no es apagar)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
TARGET=$(q "$ST" "[d for d in items if d['id']==$CONSOLE][0]['mirrorOf']")
MIR=$(probe | grep -c "PROBE id=$CONSOLE .*mirrorOf=$TARGET "); check_str "CG: CGDisplayMirrorsDisplay(consola) == $TARGET" "$MIR" "1"
P=$(persisted); check_str "persistido mirrorOf de la consola apunta a un UUID" "$(python3 -c 'import sys,json; d=[x for x in json.loads(sys.argv[1]) if x.get("uuid")==sys.argv[2]]; print(bool(d and d[0].get("mirrorOf")))' "$P" "$CONSOLE_UUID")" "True"
log "-> relanzar: el espejo persistido se reaplica"
$SSH 'pkill -x SimpleDisplay; sleep 2; open -a SimpleDisplay'; sleep 16
snap M3
wscheck "tras relanzar con espejo persistido"
check "tras relanzar, la consola vuelve espejada a un display encendido" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['mirrorOf'] in [d['id'] for d in items if d['on'] and d['id']!=$CONSOLE]"
ctl unmirror --id $CONSOLE; sleep 8
snap M4
check "sin espejos" "$ST" "all(d['mirrorOf']==0 for d in items)"
check "la consola volvio a su modo previo al espejo (${CONSOLE_W0}px; restaurado por la app)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['width']==$CONSOLE_W0"
P=$(persisted); check_str "persistencia sin mirrorOf" "$(python3 -c 'import sys,json; d=[x for x in json.loads(sys.argv[1]) if x.get("mirrorOf")]; print(len(d))' "$P")" "0"
url "mirror?id=$CONSOLE"; sleep 10
snap M5
TARGET=$(q "$ST" "[d for d in items if d['id']==$CONSOLE][0]['mirrorOf']"); log "la consola espeja a $TARGET; ahora apago ese destino"
url "disable?id=$TARGET"; sleep 10
snap M6
wscheck "tras apagar el destino de un espejo"
check "apagar el destino disuelve el espejo primero: la consola queda sin espejo y encendida" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['mirrorOf']==0 and [d for d in items if d['id']==$CONSOLE][0]['on']"
check "y recupera su modo previo al espejo (${CONSOLE_W0}px)" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['width']==$CONSOLE_W0"
check "el destino quedo apagado" "$ST" "[d for d in items if d['id']==$TARGET][0]['on']==False"
url "enable?id=$TARGET"; sleep 9
snap M7
check "todos encendidos y sin espejos" "$ST" "all(d['on'] for d in items) and all(d['mirrorOf']==0 for d in items)"
applog 120s 20

sec "F sleep/wake (puede no estar soportado en VM)"
log "pmset: $($SSH 'pmset -g 2>/dev/null | grep -iE "^ (sleep|hibernatemode|standby)" | tr -s " " | tr "\n" ";"')"
url "disable?id=$RET"; sleep 7
snap F0
if $SSH 'sudo pmset sleepnow' 2>&1 | tee -a "$LOG" | grep -qi 'sleeping'; then
  log "   sleepnow aceptado; espero 20s y compruebo si el guest sigue accesible"; sleep 20
  if $SSH 'echo alive' 2>/dev/null | grep -q alive; then
    snap F1; applog 60s 15
    check "Retina sigue apagada tras el intento de sleep/wake" "$ST" "[d for d in items if d['id']==$RET][0]['on']==False"
  else
    log "   INFO  el guest no responde tras sleepnow: la VM quedo suspendida (sleep real no soportado en Virtualization.framework)"
  fi
else
  log "   INFO  sleepnow no aceptado en la VM"
fi
url "enable?id=$RET"; sleep 8
snap F2

sec "RESUMEN"
log "PASS=$PASS FAIL=$FAIL"
