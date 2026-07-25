#!/bin/bash
# install.sh — install music-mode on an Arch + KDE machine.
#
# Destinations (every write is an idempotent overwrite):
#   ~/.local/bin/music-mode                                0755  user
#   ~/.local/bin/music-mode-tray                           0755  user
#   /usr/local/bin/music-mode-nft                          0755  root:root
#   /etc/sudoers.d/music-mode                              0440  root:root
#   ~/.local/share/applications/music-mode-toggle.desktop  0644  user
#   ~/.config/systemd/user/music-mode-tray.service         0644  user
#
# bin/bitwig-hosts is deliberately NOT installed — it ships in the repo
# and is run manually via sudo when Bitwig's Settings UI freezes.
#
# Usage:
#   ./install.sh                 install
#   DRY_RUN=true ./install.sh    print every destination + mode, write nothing
#
# Security invariants (do not "simplify" these away):
#   * The nft wrapper is installed root-owned into /usr/local/bin. A
#     NOPASSWD rule pointing at a user-writable path is a trivial local
#     root escalation, so the destination must never be $HOME-derived.
#   * The sudoers path is a hardcoded literal shared by bin/music-mode and
#     etc/sudoers.d/music-mode.in; the two are asserted to agree at install
#     time rather than being templated from a variable.
#   * The sudoers grant is rendered to a mktemp file (0600), positively
#     asserted, visudo-validated, and installed LAST — a grant must never
#     exist while its target binary is absent.
#   * visudo -c is a grammar check only. It returns 0 on an empty file, an
#     unknown user, and a wildcard command, so it is paired with, not a
#     substitute for, the assertions in render_sudoers().

set -euo pipefail

# Resolve the payload from this script's own directory, never $PWD:
# `cd /tmp && /path/to/install.sh` must not be able to pick the file that
# becomes the NOPASSWD target.
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

# --- payload (repo-relative, absolute) ---------------------------------

SRC_CLI="$SCRIPT_DIR/bin/music-mode"
SRC_NFT="$SCRIPT_DIR/bin/music-mode-nft"
SRC_TRAY="$SCRIPT_DIR/bin/music-mode-tray"
SRC_SUDOERS="$SCRIPT_DIR/etc/sudoers.d/music-mode.in"
SRC_DESKTOP="$SCRIPT_DIR/share/applications/music-mode-toggle.desktop.in"
SRC_UNIT="$SCRIPT_DIR/systemd/user/music-mode-tray.service"

# --- destinations ------------------------------------------------------

# Hardcoded literal. bin/music-mode and the sudoers template each contain
# this same literal; assert_nft_path_agreement() proves all three agree.
NFT_WRAPPER_DEST="/usr/local/bin/music-mode-nft"
SUDOERS_DEST="/etc/sudoers.d/music-mode"

LOCAL_BIN="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
UNIT_DIR="$HOME/.config/systemd/user"
DESKTOP_DEST="$DESKTOP_DIR/music-mode-toggle.desktop"
UNIT_DEST="$UNIT_DIR/music-mode-tray.service"
# Pre-173cb66 machines installed the wrapper here, where the user can
# rewrite it. Removed on every install.
LEGACY_NFT_WRAPPER="$HOME/.local/bin/music-mode-nft"

INSTALL_USER=""
SUDOERS_RULE=""
TRAY_DEPS_OK="false"
TMP_SUDOERS=""

# Removes the rendered sudoers temp file on every exit path: success,
# assertion failure, visudo rejection, or Ctrl-C.
cleanup() {
    if [[ -n "$TMP_SUDOERS" && -f "$TMP_SUDOERS" ]]; then
        rm -f "$TMP_SUDOERS"
    fi
}
trap cleanup EXIT INT TERM

# --- preconditions -----------------------------------------------------

require_unprivileged() {
    if [[ "$EUID" -eq 0 ]]; then
        log_error "do not run this installer as root / under sudo."
        log_error "  Under sudo, \$USER and \$HOME are root's: the sudoers rule would be"
        log_error "  rendered for 'root' and the CLI, tray and desktop entry would land in"
        log_error "  root's home instead of yours."
        log_error "  Run it as your normal user — it calls sudo itself for the two"
        log_error "  privileged steps ($NFT_WRAPPER_DEST and $SUDOERS_DEST)."
        exit 1
    fi
    if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
        log_error "\$HOME is unset or not a directory — cannot resolve install paths"
        exit 1
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log_error "sudo not found — required to install the root-owned nft wrapper"
        exit 1
    fi
}

check_payload() {
    local f missing=0
    for f in "$SRC_CLI" "$SRC_NFT" "$SRC_TRAY" "$SRC_SUDOERS" "$SRC_DESKTOP" "$SRC_UNIT"; do
        if [[ ! -f "$f" ]]; then
            log_error "payload file missing: $f"
            missing=1
        fi
    done
    if [[ "$missing" -ne 0 ]]; then
        log_error "incomplete repo at $SCRIPT_DIR — aborting"
        exit 1
    fi
}

# The username is baked into a root-owned sudoers file, so it is validated
# rather than trusted. id -un is used instead of $USER: $USER is a plain
# environment variable and can be stale or attacker-set.
resolve_user() {
    INSTALL_USER="$(id -un)"

    if [[ ! "$INSTALL_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "refusing to write a sudoers rule for username '$INSTALL_USER'"
        log_error "  (does not match ^[a-z_][a-z0-9_-]*\$)"
        exit 1
    fi
    if ! getent passwd "$INSTALL_USER" >/dev/null 2>&1; then
        log_error "user '$INSTALL_USER' is not in getent passwd — aborting"
        log_error "  (visudo -c accepts rules for users that do not exist)"
        exit 1
    fi
    if [[ -n "${USER:-}" && "$USER" != "$INSTALL_USER" ]]; then
        log_warning "\$USER is '$USER' but the real user is '$INSTALL_USER' — using '$INSTALL_USER'"
    fi

    SUDOERS_RULE="$INSTALL_USER ALL=(root) NOPASSWD: $NFT_WRAPPER_DEST on, $NFT_WRAPPER_DEST off"
}

# The CLI, the sudoers template and this installer must all name the same
# absolute wrapper path. If they drift, either the CLI calls something the
# grant does not cover (password prompt from a tray click, no terminal) or
# the grant covers something the CLI never runs.
assert_nft_path_agreement() {
    if ! grep -qF "sudo -n $NFT_WRAPPER_DEST on" "$SRC_CLI"; then
        log_error "bin/music-mode does not invoke '$NFT_WRAPPER_DEST on'"
        log_error "  the CLI and the sudoers grant must name the same absolute path"
        exit 1
    fi
    if ! grep -qF "$NFT_WRAPPER_DEST off" "$SRC_CLI"; then
        log_error "bin/music-mode does not invoke '$NFT_WRAPPER_DEST off'"
        exit 1
    fi
    if ! grep -qF "$NFT_WRAPPER_DEST on, $NFT_WRAPPER_DEST off" "$SRC_SUDOERS"; then
        log_error "$SRC_SUDOERS does not grant exactly '$NFT_WRAPPER_DEST on, $NFT_WRAPPER_DEST off'"
        exit 1
    fi
}

check_tray_deps() {
    TRAY_DEPS_OK="false"
    if ! command -v python3 >/dev/null 2>&1; then
        log_warning "python3 not found — the tray icon cannot run (pacman -S python)"
        return 0
    fi
    if python3 -c 'import dbus, dbus.mainloop.glib, dbus.service
from gi.repository import GLib' >/dev/null 2>&1; then
        TRAY_DEPS_OK="true"
    else
        log_warning "python3 cannot import dbus and/or gi — tray dependencies missing"
        log_warning "  install with: sudo pacman -S python-dbus python-gobject"
    fi
}

preflight() {
    if ! command -v nft >/dev/null 2>&1 && [[ ! -x /usr/sbin/nft && ! -x /usr/bin/nft ]]; then
        log_warning "nft not found — install nftables: sudo pacman -S nftables"
        log_warning "  without it 'music-mode on' cannot block non-Bitwig traffic"
    fi
    if ! command -v kde-inhibit >/dev/null 2>&1; then
        log_warning "kde-inhibit not found — notifications will not be suppressed"
        log_warning "  install with: sudo pacman -S kde-cli-tools"
    fi
    check_tray_deps
    if ! echo ":$PATH:" | grep -q ":$LOCAL_BIN:"; then
        log_warning "$LOCAL_BIN is not on \$PATH — add it to your shell init"
    fi
}

# --- dry run -----------------------------------------------------------

dry_run_report() {
    log_dry "install $SRC_CLI -> $LOCAL_BIN/music-mode (0755)"
    log_dry "install $SRC_TRAY -> $LOCAL_BIN/music-mode-tray (0755)"
    log_dry "sudo install $SRC_NFT -> $NFT_WRAPPER_DEST (0755 root:root)"
    log_dry "remove legacy user-writable wrapper $LEGACY_NFT_WRAPPER (if present)"
    log_dry "verify $NFT_WRAPPER_DEST is root-owned and not group/other writable"
    log_dry "render $SRC_DESKTOP (__HOME__ -> $HOME) -> $DESKTOP_DEST (0644)"
    log_dry "run kbuildsycoca6 to pick up the Meta+Shift+M shortcut (if present)"
    log_dry "install $SRC_UNIT -> $UNIT_DEST (0644)"
    log_dry "systemctl --user daemon-reload"
    if [[ "$TRAY_DEPS_OK" == "true" ]]; then
        log_dry "systemctl --user enable --now music-mode-tray.service"
    else
        log_dry "SKIP 'enable --now music-mode-tray.service' — python dbus/gi missing"
    fi
    log_dry "render $SRC_SUDOERS (__USER__ -> $INSTALL_USER) to a mktemp file (0600)"
    log_dry "validate it with 'sudo visudo -c -f <tmp>' plus non-empty/single-rule assertions"
    log_dry "sudo install <tmp> -> $SUDOERS_DEST (0440 root:root)  [installed LAST]"
    log_dry "  rule: $SUDOERS_RULE"
    log_dry "NOT installed: $SCRIPT_DIR/bin/bitwig-hosts (ships in-repo, run manually via sudo)"
    log_info "Dry run complete — nothing was written."
}

# --- install steps -----------------------------------------------------

install_local_bins() {
    mkdir -p "$LOCAL_BIN"
    install -m 0755 "$SRC_CLI" "$LOCAL_BIN/music-mode"
    install -m 0755 "$SRC_TRAY" "$LOCAL_BIN/music-mode-tray"
    log_ok "music-mode, music-mode-tray -> $LOCAL_BIN/ (0755)"
}

install_nft_wrapper() {
    sudo install -m 0755 -o root -g root "$SRC_NFT" "$NFT_WRAPPER_DEST"
    # Pre-173cb66 machines kept the wrapper in a user-writable directory
    # that also shadows the root-owned copy on $PATH.
    rm -f "$LEGACY_NFT_WRAPPER"
    log_ok "music-mode-nft -> $NFT_WRAPPER_DEST (0755 root:root)"
}

# Last gate before the NOPASSWD grant goes in: the target and the directory
# holding it must both be root-owned and not group/other writable.
assert_root_owned() {
    local path="$1" owner mode
    if [[ ! -e "$path" ]]; then
        log_error "$path does not exist after install — refusing to grant sudo on it"
        exit 1
    fi
    owner="$(stat -c '%U' "$path")"
    mode="$(stat -c '%a' "$path")"
    if [[ "$owner" != "root" ]]; then
        log_error "$path is owned by '$owner', not root — refusing to grant NOPASSWD on it"
        exit 1
    fi
    if (( (0"$mode" & 022) != 0 )); then
        log_error "$path is group/other writable (mode $mode) — refusing to grant NOPASSWD on it"
        exit 1
    fi
}

verify_wrapper_target() {
    assert_root_owned "$(dirname "$NFT_WRAPPER_DEST")"
    assert_root_owned "$NFT_WRAPPER_DEST"
    log_ok "$NFT_WRAPPER_DEST verified root-owned and not user-writable"
}

install_desktop_entry() {
    mkdir -p "$DESKTOP_DIR"
    # Pipe delimiter: $HOME contains slashes and would break s/../../.
    if ! sed "s|__HOME__|$HOME|g" "$SRC_DESKTOP" > "$DESKTOP_DEST"; then
        log_error "failed rendering $SRC_DESKTOP -> $DESKTOP_DEST"
        exit 1
    fi
    if [[ ! -s "$DESKTOP_DEST" ]] || grep -q '__HOME__' "$DESKTOP_DEST"; then
        log_error "$DESKTOP_DEST is empty or still contains __HOME__ — render failed"
        exit 1
    fi
    chmod 0644 "$DESKTOP_DEST"
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 >/dev/null 2>&1 || true
    fi
    log_ok "music-mode-toggle.desktop -> $DESKTOP_DEST (0644, Meta+Shift+M)"
}

install_tray_unit() {
    mkdir -p "$UNIT_DIR"
    install -m 0644 "$SRC_UNIT" "$UNIT_DEST"
    log_ok "music-mode-tray.service -> $UNIT_DEST (0644)"

    if ! systemctl --user daemon-reload >/dev/null 2>&1; then
        log_warning "'systemctl --user daemon-reload' failed (no user session bus?)"
        log_warning "  enable the tray later with: systemctl --user enable --now music-mode-tray.service"
        return 0
    fi

    # The unit is Restart=on-failure / RestartSec=5. Enabling it without
    # python-dbus + python-gobject is a silent crash-loop every 5s, so the
    # missing dependency is reported instead of started.
    if [[ "$TRAY_DEPS_OK" != "true" ]]; then
        log_warning "not enabling music-mode-tray.service — python dbus/gi missing"
        log_warning "  the unit restarts on failure every 5s; it would crash-loop silently"
        log_warning "  after installing python-dbus and python-gobject, run:"
        log_warning "    systemctl --user enable --now music-mode-tray.service"
        return 0
    fi

    if systemctl --user enable --now music-mode-tray.service >/dev/null 2>&1; then
        log_ok "music-mode-tray.service enabled and started"
    else
        log_warning "could not enable music-mode-tray.service — check: systemctl --user status music-mode-tray.service"
    fi
}

# Renders the grant and proves it is exactly what is intended. Runs before
# anything privileged is installed so a bad render aborts with the system
# untouched; the resulting temp file is installed last.
# Proves the rendered file is exactly the intended grant and nothing else.
# Factored out because it must run twice — see install_sudoers().
assert_sudoers_content() {
    local directives
    if [[ ! -s "$TMP_SUDOERS" ]]; then
        log_error "rendered sudoers file is empty — aborting (visudo -c accepts empty files)"
        exit 1
    fi
    if grep -q '__USER__' "$TMP_SUDOERS"; then
        log_error "rendered sudoers still contains __USER__ — substitution failed"
        exit 1
    fi

    # Exactly one directive line, byte-identical to the intended rule.
    # This is what rejects wildcards, an argument-less command form, SETENV,
    # and system-wide Defaults lines — visudo -c accepts all of those.
    directives="$(grep -cvE '^[[:space:]]*(#.*)?$' "$TMP_SUDOERS" || true)"
    if [[ "$directives" -ne 1 ]]; then
        log_error "rendered sudoers has $directives directive lines, expected exactly 1"
        exit 1
    fi
    if ! grep -qxF "$SUDOERS_RULE" "$TMP_SUDOERS"; then
        log_error "rendered sudoers does not match the expected grant — aborting"
        log_error "  expected: $SUDOERS_RULE"
        exit 1
    fi
}

render_sudoers() {
    TMP_SUDOERS="$(mktemp)"
    chmod 0600 "$TMP_SUDOERS"

    if ! sed "s/__USER__/$INSTALL_USER/g" "$SRC_SUDOERS" > "$TMP_SUDOERS"; then
        log_error "sed failed rendering $SRC_SUDOERS — aborting before touching $SUDOERS_DEST"
        exit 1
    fi

    assert_sudoers_content

    # Grammar check last, as a backstop to the assertions above.
    if ! sudo visudo -c -f "$TMP_SUDOERS" >/dev/null; then
        log_error "rendered sudoers failed 'visudo -c' validation — aborting"
        exit 1
    fi
    log_ok "sudoers grant rendered and validated (user: $INSTALL_USER)"
}

install_sudoers() {
    # Re-assert immediately before the privileged copy. render_sudoers()
    # deliberately runs early so a bad render aborts with the system
    # untouched, which leaves the validated temp file sitting through the
    # binary/desktop/unit installs — and install_tray_unit() can block for
    # seconds on `systemctl --user enable --now`. The file is 0600 and
    # user-owned, so only same-user code could rewrite it in that window,
    # but user-code-to-root is exactly the escalation this file exists to
    # prevent. Re-checking here costs nothing and closes the window.
    assert_sudoers_content

    sudo install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_DEST"
    rm -f "$TMP_SUDOERS"
    TMP_SUDOERS=""
    log_ok "sudoers drop-in -> $SUDOERS_DEST (0440 root:root, user: $INSTALL_USER)"
}

# --- main --------------------------------------------------------------

main() {
    log_info "==> Installing music-mode (from $SCRIPT_DIR)"

    require_unprivileged
    check_payload
    resolve_user
    assert_nft_path_agreement
    preflight

    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run_report
        return 0
    fi

    # Validate the grant before anything is written, install it after
    # everything else: a NOPASSWD rule must never outlive or precede its
    # target binary.
    render_sudoers

    install_local_bins
    install_nft_wrapper
    verify_wrapper_target
    install_desktop_entry
    install_tray_unit
    install_sudoers

    log_ok "music-mode install complete"
    log_info "Usage: music-mode [on|off|toggle|status]  —  or Meta+Shift+M to toggle"
    log_info "Verify the grant with: sudo -l"
}

main "$@"
