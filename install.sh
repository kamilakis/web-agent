#!/usr/bin/env bash
# Copy web-agent into place and (re)start the services.
#
#   ./install.sh                 install and restart, so the new code runs
#   NO_RESTART=1 ./install.sh    install only; restart yourself later
#
# A restart interrupts a reply in flight (Siri/Matrix callers are told so) and
# the conversation continues: the daemon resumes the active transcript.
set -euo pipefail
REPO=$(cd "$(dirname "$0")" && pwd)
cd "$REPO"                       # the paths below are relative to the checkout
PREFIX=${PREFIX:-$HOME}
BIN="$PREFIX/.local/bin"
STATE="$PREFIX/.local/share/agent-session"
UNITS="$PREFIX/.config/systemd/user"

mkdir -p "$BIN" "$STATE/web" "$UNITS" "$STATE/attachments/site"
install -m 755 bin/agent-session-daemon bin/agent-task \
               bin/agent-matrix-listener bin/matrix-notify bin/agent-update "$BIN/"
install -m 644 web/index.html "$STATE/web/index.html"
# the dashboard's icons are referenced as /media/site/*, which the daemon serves
# out of the attachments tree -- so they have to be installed, not just shipped
install -m 644 web/site/* "$STATE/attachments/site/"
install -m 644 systemd/*.service "$UNITS/"

# What is deployed, as the dashboard's build badge shows it (GET /version). The
# commit comes from the checkout this ran in; a tarball install just says so.
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)
if [ -n "$COMMIT" ] && [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    COMMIT="$COMMIT-dirty"       # uncommitted changes: the hash alone would lie
fi
# `repo` is where the dashboard's Update button (agent-update) pulls from.
REPO_JSON=""
[ -d "$REPO/.git" ] && REPO_JSON=$REPO
printf '{"commit":"%s","built":"%s","repo":"%s"}\n' \
       "${COMMIT:-unknown}" "$(date -Is)" "$REPO_JSON" > "$STATE/build.json"

systemctl --user daemon-reload
systemctl --user enable agent-session.service agent-matrix-listener.service
if [ "${NO_RESTART:-0}" = "1" ]; then
    # `enable --now` would not restart an already-running daemon, which then
    # kept the old code while build.json advertised the new commit.
    echo "Installed, NOT restarted (NO_RESTART=1). The running daemon is still the"
    echo "old build until: systemctl --user restart agent-session agent-matrix-listener"
else
    systemctl --user restart agent-session.service agent-matrix-listener.service
    echo "Installed and restarted."
fi

echo
echo "Check it (see README, \"Always on\"):"
echo "  curl -s http://<host>:8383/version   # daemon version + commit $COMMIT"
echo "  curl -s http://<host>:8383/state     # 200 = pi is answering"
echo
echo "First install? Next steps:"
echo "  1. Matrix bridge (optional): create ~/.config/web-agent/matrix with"
echo "     token / homeserver_url / room_id files, and set AGENT_MATRIX_CONFIG in a"
echo "     drop-in for both units, then restart agent-matrix-listener"
echo "  2. Dashboard: set AGENT_WEB_HOST to your VPN IP in a drop-in"
echo "     (~/.config/systemd/user/agent-session.service.d/local.conf)"
echo "  3. Siri shortcut: ssh <host> agent-task \"...\" (full path required)"
