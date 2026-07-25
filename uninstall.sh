#!/bin/bash
# uninstall.sh — remove everything install.sh put on this machine.
#
# Reverses the install, with two ordering rules that matter:
#   1. `music-mode off` runs FIRST, while the sudoers grant still exists —
#      otherwise the nftables table survives the uninstall and the machine
#      is left with its network blocked and no tool to unblock it.
#   2. The sudoers grant is removed BEFORE the wrapper it points at, the
#      mirror image of install.sh's order. A NOPASSWD rule must never
#      outlive its target.
#
# Usage:
#   ./uninstall.sh                 remove
#   DRY_RUN=true ./uninstall.sh    print what would be removed, remove nothing

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

DRY_RUN="${DRY_RUN:-false}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_msg()   { echo -e "${1}${*:2}${NC}"; }
log_info()    { print_msg "$BLUE" "$*"; }
log_ok()      { print_msg "$GREEN" "✓ $*"; }
log_warning() { print_msg "$YELLOW" "WARNING: $*"; }
log_error()   { print_msg "$RED" "ERROR: $*" >&2; }
log_dry()     { print_msg "$BLUE" "[DRY RUN] $*"; }

NFT_WRAPPER_DEST="/usr/local/bin/music-mode-nft"
SUDOERS_DEST="/etc/sudoers.d/music-mode"

LOCAL_BIN="$HOME/.local/bin"
CLI_DEST="$LOCAL_BIN/music-mode"
TRAY_DEST="$LOCAL_BIN/music-mode-tray"
LEGACY_NFT_WRAPPER="$LOCAL_BIN/music-mode-nft"
DESKTOP_DEST="$HOME/.local/share/applications/music-mode-toggle.desktop"
UNIT_DEST="$HOME/.config/systemd/user/music-mode-tray.service"
SESSION_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/music-mode"
SESSION_FILE="$SESSION_DIR/session"

TRAY_UNIT="music-mode-tray.service"
DND_UNIT="music-mode-dnd.service"

WAS_ON="false"
OFF_FAILED="false"

require_unprivileged() {
    if [[ "$EUID" -eq 0 ]]; then
        log_error "do not run this uninstaller as root / under sudo."
        log_error "  Under sudo \$HOME is root's, so the user-level files would not be found."
        log_error "  Run it as your normal user — it calls sudo itself for the two"
        log_error "  privileged removals ($SUDOERS_DEST and $NFT_WRAPPER_DEST)."
        exit 1
    fi
    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        log_error "\$HOME is unset or not a directory — cannot resolve install paths"
        exit 1
    fi
}

# Disengage while the sudoers grant is still in place. Prefers the
# installed CLI, falls back to the copy in this repo.
disengage() {
    local cli=""
    [[ -x "$CLI_DEST" ]] && cli="$CLI_DEST"
    [[ -z "$cli" && -x "$SCRIPT_DIR/bin/music-mode" ]] && cli="$SCRIPT_DIR/bin/music-mode"

    if [[ -f "$SESSION_FILE" ]]; then
        WAS_ON="true"
        log_warning "music-mode is currently ON — disengaging before uninstall"
    fi

    if [[ -z "$cli" ]]; then
        log_warning "no music-mode CLI found — skipping 'music-mode off'"
        [[ "$WAS_ON" == "true" ]] && OFF_FAILED="true"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "run '$cli off' (best effort, while the sudoers grant still exists)"
        return 0
    fi

    if "$cli" off; then
        log_ok "music-mode off"
    else
        OFF_FAILED="true"
        log_warning "'music-mode off' returned non-zero — the nftables table may still be loaded"
    fi
}

stop_tray() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "systemctl --user disable --now $TRAY_UNIT"
        log_dry "remove $UNIT_DEST"
        log_dry "systemctl --user daemon-reload"
        return 0
    fi

    systemctl --user disable --now "$TRAY_UNIT" >/dev/null 2>&1 || true
    log_ok "$TRAY_UNIT stopped and disabled"

    rm -f "$UNIT_DEST"
    log_ok "removed $UNIT_DEST"

    systemctl --user daemon-reload >/dev/null 2>&1 || \
        log_warning "'systemctl --user daemon-reload' failed (no user session bus?)"
}

remove_user_bins() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "remove $CLI_DEST"
        log_dry "remove $TRAY_DEST"
        log_dry "remove $LEGACY_NFT_WRAPPER (legacy pre-173cb66 location, if present)"
        return 0
    fi
    rm -f "$CLI_DEST" "$TRAY_DEST" "$LEGACY_NFT_WRAPPER"
    log_ok "removed $CLI_DEST, $TRAY_DEST"
}

# Grant first, then the binary it names. Never leave a NOPASSWD rule
# pointing at a path that no longer exists.
remove_sudoers() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "sudo rm -f $SUDOERS_DEST  [removed BEFORE the wrapper it grants]"
        return 0
    fi
    sudo rm -f "$SUDOERS_DEST"
    log_ok "removed $SUDOERS_DEST"
}

remove_nft_wrapper() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "sudo rm -f $NFT_WRAPPER_DEST"
        return 0
    fi
    sudo rm -f "$NFT_WRAPPER_DEST"
    log_ok "removed $NFT_WRAPPER_DEST"
}

remove_desktop_entry() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "remove $DESKTOP_DEST"
        log_dry "run kbuildsycoca6 to drop the Meta+Shift+M shortcut (if present)"
        return 0
    fi
    rm -f "$DESKTOP_DEST"
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 >/dev/null 2>&1 || true
    fi
    log_ok "removed $DESKTOP_DEST"
}

remove_cache() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "remove -r $SESSION_DIR"
        return 0
    fi
    rm -rf "$SESSION_DIR"
    log_ok "removed $SESSION_DIR"
}

recovery_notice() {
    [[ "$WAS_ON" != "true" && "$OFF_FAILED" != "true" ]] && return 0

    log_warning "music-mode was uninstalled mid-session."
    log_warning "If the network is still restricted or notifications are still muted,"
    log_warning "undo it by hand — the CLI that did it is gone now:"
    print_msg "$YELLOW" "    sudo nft delete table inet music_mode"
    print_msg "$YELLOW" "    systemctl --user stop $DND_UNIT"
    log_warning "Check with: sudo nft list table inet music_mode"
}

main() {
    log_info "==> Uninstalling music-mode"
    require_unprivileged

    disengage
    stop_tray
    remove_user_bins
    remove_sudoers
    remove_nft_wrapper
    remove_desktop_entry
    remove_cache

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run complete — nothing was removed."
        log_info "Note: the Bitwig scope (music-mode-bitwig.scope) is never touched."
        return 0
    fi

    recovery_notice
    log_ok "music-mode uninstalled"
    log_info "Bitwig itself and its scope (music-mode-bitwig.scope) were left alone."
}

main "$@"
