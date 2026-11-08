#!/bin/zsh
# Udostępnia instalator agenta dla Windowsa w sieci domowej.
# Na Windowsie (PowerShell jako administrator): irm http://IP_MACA:24851/instaluj.ps1 | iex
set -e
cd "$(dirname "$0")"
IP=$(ipconfig getifaddr en0)
D=$(mktemp -d)
cp windows/agent.ps1 "$D/"
sed "s#__BASE__#http://$IP:24851#" windows/instaluj.ps1 > "$D/instaluj.ps1"
echo "Na Windowsie: irm http://$IP:24851/instaluj.ps1 | iex"
echo "Ctrl+C konczy."
cd "$D" && python3 -I -m http.server 24851 --bind 0.0.0.0
