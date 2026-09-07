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
print("   %-4s %-10s %-4s %-3s %-4s %-5s %s" % ("id","name","virt","on","main","hidpi","mode"))
for d in items:
    print("   %-4s %-10s %-4s %-3s %-4s %-5s %sx%s" % (d["id"],d["name"],int(d["virtual"]),int(d["on"]),int(d["main"]),int(d["hidpi"]),d["width"],d["height"]))
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
$SSH 'pkill -x SimpleDisplay; sleep 1; defaults delete app.simpledisplay 2>/dev/null; rm -f /tmp/simpledisplay-status.json; open -a SimpleDisplay'; sleep 7
snap S0
CONSOLE=$(q "$ST" "[d['id'] for d in items if not d['virtual']][0]")
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
log "ids: TWIN1=$TWIN1 TWIN2=$TWIN2 RET=$RET"

sec "A gemelos: apagar Twin#1, el otro Twin conserva nombre y fila"
url "disable?id=$TWIN1"; sleep 7
snap A1
check "Twin#1 sigue listado (fantasma) y apagado" "$ST" "[d for d in items if d['id']==$TWIN1][0]['on']==False"
check "Twin#1 conserva el nombre 'Twin'" "$ST" "[d for d in items if d['id']==$TWIN1][0]['name']=='Twin'"
check "Twin#2 sigue encendido y con nombre 'Twin'" "$ST" "[d for d in items if d['id']==$TWIN2][0]['on'] and [d for d in items if d['id']==$TWIN2][0]['name']=='Twin'"
check "siguen 4 filas (ninguna desaparecio)" "$ST" "len(items)==4"
ONLINE=$(probe | grep -c "PROBE id=$TWIN1 "); check_str "CG: Twin#1 fuera de la lista online (0=si)" "$ONLINE" "0"
url "enable?id=$TWIN1"; sleep 9
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
RETMODE=$(q "$ST" "'%sx%s hidpi=%s' % tuple([(d['width'],d['height'],d['hidpi']) for d in items if d['name']=='Retina'][0])")
log "   INFO  Retina tras relanzar: $RETMODE (issue preexistente de main: el slot de serial se reasigna y macOS recuerda el modo por identidad; ver informe)"
applog 60s 15
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
MAINPROBE=$(probe | grep -c "PROBE id=$CONSOLE "); check_str "CG: consola fuera de la lista online (0=si)" "$MAINPROBE" "0"
url "enable?id=$CONSOLE"; sleep 9
snap E2
check "consola encendida de nuevo" "$ST" "[d for d in items if d['id']==$CONSOLE][0]['on']"
check "todos encendidos" "$ST" "all(d['on'] for d in items)"
applog 60s 15

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
