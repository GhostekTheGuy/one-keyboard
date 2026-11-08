#!/bin/zsh
# Udostępnia instalator agenta dla Windowsa w sieci domowej.
# Na Windowsie (PowerShell jako administrator): irm http://IP_MACA:24851/instaluj.ps1 | iex
set -e
cd "$(dirname "$0")"
IP=$(ipconfig getifaddr en0)
# adresy, pod którymi agent szuka Maca: IP w sieci domowej, nazwa .local i (jeśli jest) Tailscale
HOSTS="$IP,$(scutil --get LocalHostName).local"
TS=$( (command -v tailscale >/dev/null && tailscale ip -4 || /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4) 2>/dev/null | head -1)
[ -n "$TS" ] && HOSTS="$HOSTS,$TS"
D=$(mktemp -d)
cp windows/agent.ps1 "$D/"
sed -e "s#__BASE__#http://$IP:24851#" -e "s#__HOSTS__#$HOSTS#" windows/instaluj.ps1 > "$D/instaluj.ps1"
echo "Adresy Maca dla agenta: $HOSTS"
echo "Na Windowsie: irm http://$IP:24851/instaluj.ps1 | iex"
echo "Ctrl+C konczy."
cd "$D" && python3 -I -m http.server 24851 --bind 0.0.0.0
