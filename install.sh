#!/usr/bin/env bash
# Copy web-agent into place and start the services.
set -euo pipefail
PREFIX=${PREFIX:-$HOME}
BIN="$PREFIX/.local/bin"
STATE="$PREFIX/.local/share/agent-session"
UNITS="$PREFIX/.config/systemd/user"

mkdir -p "$BIN" "$STATE/web" "$UNITS"
install -m 755 bin/agent-session-daemon bin/agent-task \
               bin/agent-matrix-listener bin/matrix-notify "$BIN/"
install -m 644 web/index.html "$STATE/web/index.html"
install -m 644 systemd/*.service "$UNITS/"
systemctl --user daemon-reload
systemctl --user enable --now agent-session.service agent-matrix-listener.service

echo
echo "Installed. Next steps:"
echo "  1. Matrix bridge (optional): create ~/.config/web-agent/matrix with"
echo "     token / homeserver_url / room_id files, set AGENT_MATRIX_CONFIG in"
echo "     both unit files, then: systemctl --user restart agent-matrix-listener"
echo "  2. Dashboard: set AGENT_WEB_HOST to your VPN IP in agent-session.service"
echo "     and open http://<that-ip>:8383"
echo "  3. Siri shortcut: ssh <host> agent-task \"...\" (full path required)"
