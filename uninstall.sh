#!/usr/bin/env bash
#
# Removes the files install.sh put in place. Packages installed by apt
# (tigervnc, xrdp, xfce4, ...) are left alone: other things may use them.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

# Stop anything still running (ignore errors: it may not be running)
if [ -x /usr/bin/kex ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "${SUDO_USER}" /usr/bin/kex --kill >/dev/null 2>&1 || true
fi

rm -f  /usr/bin/kex /etc/sudoers.d/u-kex /etc/profile.d/win-kex.sh
rm -rf /usr/lib/win-kex

cat <<'EOF'
u-kex files removed.

Left in place (remove by hand if you want):
  ~/.vnc/ or ~/.config/tigervnc/   VNC password and logs
  ~/.win-kex.rdp, ~/.xsession       ESM client profile / session choice
  /etc/xrdp/xrdp.ini                port changed from 3389 to 3390
  Packages:  sudo apt remove tigervnc-standalone-server tigervnc-tools xrdp xfce4
EOF
