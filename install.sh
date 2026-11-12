#!/usr/bin/env bash
#
# u-kex installer: Kali's Win-KeX on Ubuntu (WSL 2).
#
# What it does, in order:
#   1. Sanity checks (root, Ubuntu, WSL 2, CPU architecture)
#   2. apt-installs the Linux side (TigerVNC server, xrdp, XFCE, sound module)
#   3. Fetches the Windows side (TigerVNC viewer, VcXsrv, PulseAudio for
#      Windows) from upstream kali-win-kex at a pinned, verified commit
#   4. Installs the Ubuntu-adapted scripts from this repository
#   5. Configures xrdp for Ubuntu (TLS key access, port 3390, start on demand)
#
# Usage: sudo ./install.sh [--no-desktop] [--full-desktop] [--no-sound] [--force]
#
# DESTDIR=/some/dir ./install.sh --force   stages files only (no apt, no system
# changes). Used for testing and packaging.

set -euo pipefail

UPSTREAM_URL="https://gitlab.com/kalilinux/packages/kali-win-kex.git"
UPSTREAM_TAG="kali/3.1.5"
UPSTREAM_COMMIT="1e32772d8108461061c0a9cce6d38287a1ab3e3c"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTDIR="${DESTDIR:-}"
LIBDIR="${DESTDIR}/usr/lib/win-kex"

WANT_DESKTOP=1
FULL_DESKTOP=0
WANT_SOUND=1
FORCE=0

red='\033[1;31m'; green='\033[1;32m'; yellow='\033[1;33m'; reset='\033[0m'
info() { printf "${green}[u-kex]${reset} %s\n" "$*"; }
warn() { printf "${yellow}[u-kex] WARNING:${reset} %s\n" "$*" >&2; }
die()  { printf "${red}[u-kex] ERROR:${reset} %s\n" "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF
Options:
  --no-desktop     Do not install XFCE (bring your own; seamless mode needs XFCE)
  --full-desktop   Also install xfce4-goodies (panel plugins, extra apps)
  --no-sound       Do not install the xrdp sound module
  --force          Skip the Ubuntu / WSL 2 checks
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-desktop)   WANT_DESKTOP=0 ;;
        --full-desktop) FULL_DESKTOP=1 ;;
        --no-sound)     WANT_SOUND=0 ;;
        --force)        FORCE=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage; die "Unknown option: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------- 1. checks --
[ -n "${DESTDIR}" ] || [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"

. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] && [[ " ${ID_LIKE:-} " != *" ubuntu "* ]]; then
    [ "${FORCE}" = 1 ] || die "This is ${PRETTY_NAME:-unknown}, not Ubuntu. Use --force to try anyway."
    warn "Not Ubuntu (${PRETTY_NAME:-unknown}); continuing because of --force"
fi

# WSL 2 check. WSL 1 has no real Linux kernel and cannot run an X/VNC server.
# WSL_INTEROP and /run/WSL only exist on WSL 2.
if ! grep -qi microsoft /proc/version 2>/dev/null; then
    [ "${FORCE}" = 1 ] || die "Not running under WSL. u-kex is for Ubuntu on WSL 2 (Windows)."
    warn "Not WSL; continuing because of --force (Windows-side features will not work)"
elif [ -z "${WSL_INTEROP:-}" ] && [ ! -d /run/WSL ]; then
    [ "${FORCE}" = 1 ] || die "This looks like WSL 1. In Windows run: wsl --set-version ${WSL_DISTRO_NAME:-Ubuntu} 2"
fi

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
    amd64) ;;
    arm64) warn "arm64: as upstream, only Enhanced Session Mode (--esm) is supported" ;;
    *)     die "Unsupported architecture: ${ARCH} (upstream supports amd64 and arm64)" ;;
esac

# -------------------------------------------------------------- 2. packages --
pkg_available() { [ -n "$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]; }

if [ -z "${DESTDIR}" ]; then
    info "Installing packages (this can take a while)"
    apt-get update -qq

    PKGS=(tigervnc-standalone-server tigervnc-tools xrdp ssl-cert dbus-x11
          xauth x11-xserver-utils git ca-certificates)

    if [ "${WANT_DESKTOP}" = 1 ]; then
        # --no-install-recommends matters: xfce4 *recommends* LightDM and a full
        # Xorg server. Under systemd on WSL, LightDM would try to take over a
        # display at every boot. We list the useful recommends explicitly.
        PKGS+=(xfce4 xfce4-terminal xfce4-notifyd tango-icon-theme
               adwaita-icon-theme at-spi2-core fonts-dejavu-core)
        [ "${FULL_DESKTOP}" = 1 ] && PKGS+=(xfce4-goodies)
    fi

    if [ "${WANT_SOUND}" = 1 ]; then
        # Kali uses pulseaudio-module-xrdp; Ubuntu 24.04+ only has the PipeWire one.
        if pkg_available pipewire-module-xrdp; then
            PKGS+=(pipewire-module-xrdp pipewire-pulse wireplumber)
        elif pkg_available pulseaudio-module-xrdp; then
            PKGS+=(pulseaudio pulseaudio-module-xrdp)
        else
            warn "No xrdp sound module in your apt sources; ESM will have no sound"
        fi
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"
fi

# --------------------------------------------- 3. Windows side from upstream --
command -v git >/dev/null || die "git is required"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

info "Fetching Windows components from ${UPSTREAM_URL} (${UPSTREAM_TAG})"
# Sparse + blobless clone: only downloads the files under usr/lib/win-kex.
git -c advice.detachedHead=false clone -q --depth 1 --branch "${UPSTREAM_TAG}" \
    --filter=blob:none --sparse "${UPSTREAM_URL}" "${WORK}/upstream"
git -C "${WORK}/upstream" sparse-checkout set usr/lib/win-kex

# A tag can be moved; a commit hash cannot. Refuse anything but the reviewed one.
GOT="$(git -C "${WORK}/upstream" rev-parse HEAD)"
[ "${GOT}" = "${UPSTREAM_COMMIT}" ] || die "Upstream commit mismatch: expected ${UPSTREAM_COMMIT}, got ${GOT}"
info "Verified upstream commit ${GOT}"

UP="${WORK}/upstream/usr/lib/win-kex"

# ------------------------------------------------------------- 4. install --
info "Installing to ${DESTDIR:-/}"
install -d "${DESTDIR}/usr/bin" "${LIBDIR}/xrdp" "${LIBDIR}/wslg-sock" \
           "${DESTDIR}/etc/profile.d" "${DESTDIR}/etc/sudoers.d"

# Windows binaries, unchanged from upstream (cp -a keeps the exec bits WSL needs
# to launch .exe files from the Linux filesystem)
for d in TigerVNC VcXsrv pulse; do
    rm -rf "${LIBDIR:?}/${d}"
    cp -a "${UP}/${d}" "${LIBDIR}/${d}"
done
install -m 0644 "${UP}/xrdp/win-kex.rdp" "${LIBDIR}/xrdp/win-kex.rdp"   # UTF-16 RDP profile

# Ubuntu-adapted scripts from this repo
install -m 0755 "${SRC_DIR}/bin/kex"                        "${DESTDIR}/usr/bin/kex"
install -m 0755 "${SRC_DIR}/lib/win-kex/xstartup"           "${LIBDIR}/xstartup"
install -m 0755 "${SRC_DIR}/lib/win-kex/xrdp/xrdpservice"   "${LIBDIR}/xrdp/xrdpservice"
install -m 0644 "${SRC_DIR}/lib/win-kex/xrdp/pulseaudio.desktop" "${LIBDIR}/xrdp/pulseaudio.desktop"
install -m 0755 "${SRC_DIR}/lib/win-kex/wslg-sock/wslg-sock" "${LIBDIR}/wslg-sock/wslg-sock"
install -m 0644 "${SRC_DIR}/etc/profile.d/win-kex.sh"       "${DESTDIR}/etc/profile.d/win-kex.sh"

# A syntax error in a sudoers.d file can lock you out of sudo entirely,
# so validate before putting it in place.
if command -v visudo >/dev/null; then
    visudo -cqf "${SRC_DIR}/etc/sudoers.d/u-kex" || die "sudoers file failed validation"
fi
install -m 0440 "${SRC_DIR}/etc/sudoers.d/u-kex" "${DESTDIR}/etc/sudoers.d/u-kex"

# ------------------------------------------------------- 5. configure xrdp --
if [ -z "${DESTDIR}" ]; then
    # Ubuntu's xrdp uses the snakeoil TLS key, readable only by group ssl-cert.
    # Without this, RDP (--esm) connects and immediately drops.
    if ! id -nG xrdp | grep -qw ssl-cert; then
        info "Adding user xrdp to group ssl-cert"
        usermod -aG ssl-cert xrdp
    fi
    # Windows' own RDP listener owns 3389 on localhost.
    sed -i 's/^port=3389$/port=3390/' /etc/xrdp/xrdp.ini
    # Under systemd, apt just enabled+started xrdp. Upstream KeX starts it on
    # demand (kex --esm), so keep it off at boot.
    if [ -d /run/systemd/system ]; then
        systemctl disable --now xrdp xrdp-sesman >/dev/null 2>&1 || true
    fi
fi

info "Done."
cat <<EOF

  Start the desktop:   kex                (window mode, VNC)
                       kex --esm          (Enhanced Session Mode, Windows RDP client)
                       kex --sl           (seamless mode, needs amd64)
  Add sound:           kex -s   /   kex --esm -s
  Help:                kex --help

  The first 'kex' asks you for a VNC password (6-8 chars is what VNC uses).
  You may need to log out and back in (or 'wsl --shutdown') for the
  XAUTHORITY setting in /etc/profile.d/win-kex.sh to apply.

EOF
