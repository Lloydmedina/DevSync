#!/bin/bash
#
# install.sh — installs devsync from this cloned repo into your WSL user PATH
#
# Meant to be run from inside WSL, in the same folder as devsync.sh
# (i.e. after `git clone` into your WSL filesystem, NOT a Windows path
# like /mnt/c/...).
#
# What it does:
#   - Confirms you're running inside WSL (warns, doesn't block, if not)
#   - Symlinks ./devsync.sh -> ~/.local/bin/devsync (so `git pull` later
#     updates the tool automatically, no reinstall needed)
#   - Adds ~/.local/bin to PATH in your shell rc file, only if it isn't
#     already there
#   - Safe to re-run any time (idempotent)
#
# Usage:
#   ./install.sh            # install
#   ./install.sh uninstall  # remove the symlink (leaves PATH edits alone)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
err()   { echo -e "${RED}$*${NC}"; }
note()  { echo -e "${BLUE}$*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/devsync.sh"
INSTALL_DIR="$HOME/.local/bin"
LINK_PATH="$INSTALL_DIR/devsync"

# ---------- WSL check ----------
check_wsl() {
    if grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
        return 0
    fi
    return 1
}

# ---------- shell rc file detection ----------
detect_rc_file() {
    local shell_name
    shell_name="$(basename "${SHELL:-bash}")"
    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *)    echo "$HOME/.bashrc" ;;  # sane default
    esac
}

# ---------- uninstall ----------
do_uninstall() {
    if [ -L "$LINK_PATH" ] || [ -f "$LINK_PATH" ]; then
        rm -f "$LINK_PATH"
        info "Removed $LINK_PATH"
    else
        warn "Nothing installed at $LINK_PATH — already clean."
    fi
    note "PATH entries in your shell rc file were left in place (harmless if unused)."
    exit 0
}

if [ "${1:-}" = "uninstall" ]; then
    do_uninstall
fi

# ---------- pre-flight checks ----------
note "=== devsync installer ==="
echo ""

if [ "$(id -u)" = "0" ]; then
    err "This installer should NOT be run as root or with sudo."
    err "It installs per-user (into \$HOME/.local/bin). Running as root"
    err "would install into /root instead of your user home."
    err ""
    err "Run it without sudo:  ./install.sh"
    exit 1
fi

if ! check_wsl; then
    warn "This doesn't look like a WSL environment."
    warn "devsync is built for WSL — if you're on native Linux this may still"
    warn "work, but if you're in a Windows shell (PowerShell/CMD), stop and"
    warn "run this from inside your WSL distro instead."
    echo ""
fi

if [ ! -f "$SOURCE_SCRIPT" ]; then
    err "Could not find devsync.sh next to this installer (looked in: $SCRIPT_DIR)."
    err "Make sure you're running install.sh from inside the cloned repo folder."
    exit 1
fi

case "$SCRIPT_DIR" in
    /mnt/c/*|/mnt/[a-zA-Z]/*)
        warn "This repo looks like it's on a Windows-mounted path ($SCRIPT_DIR)."
        warn "That will work, but file I/O across the /mnt/ boundary is much"
        warn "slower in WSL. Cloning directly into your Linux home folder"
        warn "(e.g. ~/devsync) is recommended instead."
        echo ""
        ;;
esac

# ---------- install ----------
chmod +x "$SOURCE_SCRIPT"
mkdir -p "$INSTALL_DIR"

if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
    err "$LINK_PATH already exists and isn't a symlink devsync manages."
    err "Remove or rename it manually, then re-run this installer."
    exit 1
fi

ln -sf "$SOURCE_SCRIPT" "$LINK_PATH"
info "Linked $LINK_PATH -> $SOURCE_SCRIPT"

# ---------- PATH setup ----------
if command -v devsync >/dev/null 2>&1 && [ "$(command -v devsync)" = "$LINK_PATH" ]; then
    info "$INSTALL_DIR is already on your PATH."
else
    RC_FILE="$(detect_rc_file)"
    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

    if [ -f "$RC_FILE" ] && grep -qF "$PATH_LINE" "$RC_FILE"; then
        note "$RC_FILE already has the PATH entry, but it's not active in this shell yet."
    else
        echo "" >> "$RC_FILE"
        echo "# Added by devsync installer" >> "$RC_FILE"
        echo "$PATH_LINE" >> "$RC_FILE"
        info "Added $INSTALL_DIR to PATH in $RC_FILE"
    fi

    warn "Run this to use devsync in your current terminal:"
    echo "  source $RC_FILE"
    warn "New terminals will pick it up automatically."
fi

echo ""
info "=== Install complete ==="
note "Try: devsync help"
note "To update later: just 'git pull' in this folder — the symlink stays current."
note "To uninstall: ./install.sh uninstall"
