#!/usr/bin/env bash
# stress.sh <ip> <N> <label> <logfile>
# N ciclos create -> remove via simpledisplayctl (URL scheme) en el guest,
# midiendo .icc en /Library/ColorSync/Profiles/Displays y CPU de colorsyncd/displayservices.
set -u
IP=$1; N=$2; LABEL=$3; LOG=$4
SSH="sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 admin@$IP"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
measure() {
  $SSH 'echo "ICC=$(ls /Library/ColorSync/Profiles/Displays | wc -l | tr -d " ") CPU_colorsync=$(ps -Ao pcpu,comm | grep -iE "colorsyncd|displayservices" | grep -v grep | awk "{s+=\$1} END {print s+0}") RSS_app_MB=$(ps -Ao rss,comm | grep -i "SimpleDisplay.app" | grep -v grep | awk "{s+=\$1} END {print int(s/1024)}")"'
}
log "== $LABEL == N=$N ip=$IP"
log "BASELINE $(measure)"
for i in $(seq 1 "$N"); do
  $SSH "/usr/local/bin/simpledisplayctl create --width 1280 --height 720 --name stress$((i % 3)); sleep 2; /usr/local/bin/simpledisplayctl remove --name stress$((i % 3)); sleep 2"
  if [ $((i % 10)) -eq 0 ] || [ "$i" -eq 1 ]; then log "ciclo $i/$N $(measure)"; fi
done
sleep 3
log "FINAL $(measure)"
log "ICC files: $($SSH 'ls /Library/ColorSync/Profiles/Displays | tr "\n" " "')"
log "CPU sostenida (5 muestras x 2s): $($SSH 'for k in 1 2 3 4 5; do ps -Ao pcpu,comm | grep -iE "colorsyncd|displayservices" | grep -v grep | awk "{s+=\$1} END {print s+0}"; sleep 2; done | tr "\n" " "')"
