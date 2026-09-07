#!/usr/bin/env bash
# deploy.sh <ip> <app-bundle-dir> <cli-binary>  — instala SimpleDisplay en el guest y lo abre
set -eu
IP=$1; APP=$2; CLI=$3
# PubkeyAuthentication=no: the host offers every key in the agent first and the guest's sshd
# hits MaxAuthTries before the password is tried ("Too many authentication failures").
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password"
SSH="sshpass -p admin ssh $SSHOPTS admin@$IP"
$SSH 'pkill -x SimpleDisplay || true; sleep 1; sudo rm -rf /Applications/SimpleDisplay.app; sudo mkdir -p /usr/local/bin'
sshpass -p admin scp $SSHOPTS -r "$APP" admin@$IP:/tmp/SimpleDisplay.app
sshpass -p admin scp $SSHOPTS "$CLI" admin@$IP:/tmp/simpledisplayctl
$SSH 'sudo mv /tmp/SimpleDisplay.app /Applications/SimpleDisplay.app && sudo mv /tmp/simpledisplayctl /usr/local/bin/simpledisplayctl && sudo chmod 755 /usr/local/bin/simpledisplayctl && sudo xattr -cr /Applications/SimpleDisplay.app; /usr/bin/lsregister -f /Applications/SimpleDisplay.app 2>/dev/null || /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SimpleDisplay.app; open -a SimpleDisplay; sleep 4; pgrep -x SimpleDisplay && echo APP-RUNNING; /usr/local/bin/simpledisplayctl status'
