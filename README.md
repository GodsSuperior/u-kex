# u-kex

Kali Linux's **Win-KeX** (Kali Desktop EXperience), ported to **Ubuntu on WSL 2**.

Run `kex` in Ubuntu on WSL and you get a full Linux desktop on Windows. There are three ways to view it:

| Mode | Command | How it works |
|---|---|---|
| Window | `kex` | A TigerVNC server runs in WSL, and a TigerVNC viewer runs on Windows |
| Enhanced Session (ESM) | `kex --esm` | xrdp runs in WSL, and Windows' own Remote Desktop client (`mstsc.exe`) connects to it |
| Seamless | `kex --sl` | VcXsrv runs on Windows, and each Linux window appears as its own Windows window |

Add `-s` to any mode for sound. See `kex --help` for every option.

## Install

In Ubuntu (22.04 or newer) on WSL 2:

```bash
git clone https://github.com/GodsSuperior/u-kex.git
cd u-kex
sudo ./install.sh
kex
```

The first time you run `kex`, it asks for a VNC password. VNC only uses the first 8 characters.

Installer options:

- `--full-desktop` also installs xfce4-goodies.
- `--no-desktop` skips XFCE (bring your own desktop).
- `--no-sound` skips the sound module.

To remove u-kex, run `sudo ./uninstall.sh`.

## How it's built

KeX has two halves:

```
 Windows side (Windows .exe files, run from WSL)  Linux side (Ubuntu packages + scripts)
 ───────────────────────────────────────────────  ──────────────────────────────────────
 TigerVNC viewer  ──── VNC :5901 ──────────────►  Xtigervnc + XFCE   (window mode)
 mstsc.exe        ──── RDP :3390 ──────────────►  xrdp + XFCE        (ESM)
 VcXsrv X server  ◄─── X11 :3 ─────────────────   XFCE apps          (seamless)
 pulseaudio.exe   ◄─── pulse tcp ──────────────   Linux apps         (sound, -s)
```

* **The Windows half** (about 124 MB) is the same on every distro. `install.sh` downloads it from the upstream [kali-win-kex](https://gitlab.com/kalilinux/packages/kali-win-kex) repository. It uses a pinned tag and then checks the exact commit hash, so a moved tag can't slip in different binaries. These files are not stored in this repo.
* **The Linux half** is where Kali and Ubuntu differ. This repo holds Kali's scripts with Ubuntu fixes applied.

The git history is set up so you can see each change:

```bash
BASE=$(git log --format=%h --grep='Import upstream kali-win-kex')
git show $BASE --stat           # upstream 3.1.5 scripts, imported verbatim
git diff $BASE -- bin lib etc   # every Ubuntu change since then
```

## What had to change for Ubuntu, and why

Each item below was checked on Ubuntu 24.04. They are not guesses.

| # | Problem on Ubuntu | Cause | Fix |
|---|---|---|---|
| 1 | Window mode asks for the password on every start, and the viewer can't log in | Kali has TigerVNC ≥ 1.14, which keeps the password in `~/.config/tigervnc/passwd`. Ubuntu 22.04 and 24.04 ship 1.12/1.13, which use `~/.vnc/passwd`. Upstream hardcodes the new path. | `vnc-passwd-file()` in `bin/kex` uses whichever file exists. If neither exists, it checks the installed TigerVNC version. |
| 2 | ESM connects and then drops at once (black screen) | Ubuntu's xrdp uses the "snakeoil" TLS key, which only the `ssl-cert` group can read. The `xrdp` user isn't in that group. | `install.sh` adds `xrdp` to `ssl-cert` |
| 3 | `kex --esm --stop` could break the distro | Ubuntu on WSL boots with **systemd**, and Kali on WSL doesn't. Upstream calls `/etc/init.d/*` and also stops the system D-Bus. | `xrdpservice` uses `systemctl` under systemd and never touches D-Bus there. It keeps the SysV path when systemd isn't running. |
| 4 | xrdp grabs port 3389 at boot | Under systemd, apt enables and starts xrdp right away on 3389. Windows' own RDP listener already uses that port. | The installer moves xrdp to 3390 and disables autostart. `kex --esm` starts it on demand, the same as upstream. |
| 5 | No ESM sound package | Ubuntu 24.04+ has no `pulseaudio-module-xrdp`, only `pipewire-module-xrdp` | The installer picks whichever module exists. `kex` only adds the PulseAudio autostart entry when the PulseAudio module is installed, so it can't take audio away from PipeWire. |
| 6 | `apt install xfce4` installs LightDM and Xorg (554 packages) | These come in as *Recommends*. Under systemd, LightDM tries to grab a display at every boot. | The installer uses `--no-install-recommends` and lists the useful packages explicitly (55 packages) |
| 7 | ESM opens GNOME, which then fails | xrdp starts `x-session-manager`. That is GNOME when `ubuntu-desktop` is also installed. | `kex --esm` creates `~/.xsession` with `xfce4-session` if you don't already have one |
| 8 | Every `.exe` fails with "Exec format error" | This is a known Ubuntu + systemd problem: `systemd-binfmt` can replace WSL's interop handler | `kex` detects it and prints the one-line fix (below) |

Two upstream bugs (present on Kali too) are also fixed here:

- `[ -n ${starting_kex} ]` had no quotes. With the variable empty, the test always came out true, so `kex --status` printed a "connection error" even when nothing was being started.
- `print-verbose` built its output with `printf "> $@"`, which mixes the format string and its arguments.

## Troubleshooting

**"Could not get lock /var/lib/dpkg/lock-frontend … (unattended-upgr)"**: right after Ubuntu starts, its automatic updates run in the background and hold the package lock. `install.sh` now waits for them (up to 15 minutes). Don't delete the lock file to get around this. That can corrupt the package database.

**"Cannot run Windows programs from WSL"**: this is fix #8. Run:

```bash
echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /usr/lib/binfmt.d/WSLInterop.conf
sudo systemctl restart systemd-binfmt
```

Then run `wsl --shutdown` in Windows and reopen Ubuntu.

**Use a different desktop in window mode**: put your own startup script in `~/.config/u-kex/xstartup` and make it executable (e.g. `exec startlxqt`). Seamless mode still needs XFCE.

**The window-mode server didn't start**: look at the log in `~/.vnc/` (TigerVNC 1.13) or `~/.config/tigervnc/` (1.14+). Then run `kex --kill` and try again.

## Test status

| What | Status |
|---|---|
| Installer on Ubuntu 24.04: packages, upstream fetch + hash check, file layout, sudoers validation, xrdp config | Tested |
| VNC server + XFCE desktop started by u-kex's `xstartup`, the way `kex` starts it | Tested (desktop renders) |
| `xrdpservice` start/stop/status on a non-systemd system; xrdp listening on 3390 | Tested |
| `vnc-passwd-file` on TigerVNC 1.13 | Tested |
| Windows side: viewer, mstsc, VcXsrv, sound, systemd branch of `xrdpservice` | **Needs a real Windows + WSL 2 machine.** It wasn't available while building this. |

## License

GPL-2.0-or-later, the same as upstream kali-win-kex (© Offensive Security). See `LICENSE`.
This is an unofficial port and is not affiliated with Kali Linux or Offensive Security.
