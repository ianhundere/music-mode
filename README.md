# music-mode

`music-mode` is a single-command focus ritual for music and art work on Arch + KDE. One command severs the distraction surface — chat and browsers killed, notifications silenced, all network except Bitwig blocked at the kernel — and keeps the machine out of the audio's way: background sync paused, idle sleep held off. One command reverses it.

It runs as the same user you normally use — no second Linux account to manage.

> Extracted from [github.com/ianhundere/sys-restore-t14s-arch](https://github.com/ianhundere/sys-restore-t14s-arch), where it lived as `focus/` plus a `setup_music_mode()` function inside the restore scripts. Same destinations, same security properties — now installable on its own.

## Table of Contents

- [What It Does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Files](#files)
- [Removal](#removal)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## What It Does

### `music-mode on`

Two preflight checks run **before anything is killed**, so a doomed engage never
closes your browsers and chat for nothing:

1. **Bitwig is reachable.** If Bitwig is already running *outside* the
   music-mode scope, it aborts and tells you to `killall bitwig-studio` and
   re-run — its traffic could not be allowlisted otherwise. If `bitwig-studio`
   is not in `PATH`, it aborts too.
2. **The kernel isn't stale.** See [Troubleshooting](#troubleshooting) — nft is
   guaranteed to fail in that state, so it aborts with nothing changed.

Then:

1. **Kills distraction apps:** Signal, Discord, Thunderbird, Firefox, Chromium,
   Chrome, VS Code. No-op if not running. Covers both native and flatpak
   installs — a graceful `SIGTERM` first (flatpak sandboxes get theirs via
   `flatpak ps` so Thunderbird's mail store closes cleanly), a one-second settle
   pause, then `SIGKILL` / `flatpak kill` for survivors like Discord that trap
   `SIGTERM`.
2. **Launches Bitwig Studio** inside a dedicated systemd user scope
   (`music-mode-bitwig.scope`) so its traffic can be allowlisted at the kernel
   level. On Wayland it is started with `GDK_BACKEND=x11`. It then waits up to
   5s for the scope to register — nft cannot match a cgroup that does not exist
   yet — and aborts if it never appears. Before launching, it stops any Wine
   prefix still running from an earlier Bitwig (`wineserver -k`, for
   `$WINEPREFIX` or `~/.wine`) and any leftover scope, so the prefix boots again
   inside the new scope. Wine plugins' background services, such as iLok's PACE
   `LDSvc.exe`, then share Bitwig's network access instead of being blocked.
3. **Suppresses KDE notifications and holds off idle sleep** by running
   `kde-inhibit --notifications --power` in a transient user unit,
   `music-mode-dnd.service`. It has to be a long-lived process: a freedesktop
   Inhibit call is tied to the caller's D-Bus connection, so plasmashell and
   PowerDevil drop the inhibition the moment a one-shot caller exits. `--power`
   stops PowerDevil's idle timer from suspending the machine in the middle of a
   take, when your hands are on an instrument and not on the keyboard.
   While the inhibit is held, Plasma would show its crossed-out bell in the
   tray next to music-mode's own icon, so music-mode hides that tray entry
   (adds `org.kde.plasma.notifications` to the tray's `hiddenItems` through
   plasmashell's scripting API) and notes that in
   `~/.cache/music-mode/tray-bell-hidden`. A bell you had hidden yourself is
   left alone.
4. **Loads an nftables table** (`inet music_mode`) that drops all outbound
   traffic from UID ≥ 1000 **except** loopback and traffic from the Bitwig
   scope's cgroup. Bitwig keeps full internet access; browsers, chat, curl etc.
   are blocked at the kernel. If this step fails, notifications and idle sleep
   are released again and the session is *not* recorded.
5. **Pauses background sync.** Each unit in `PAUSE_UNITS` (Syncthing, by
   default) that is running is stopped with `systemctl --user stop` and noted in
   `~/.cache/music-mode/paused-units`. Syncthing rescans and hashes every file
   Bitwig writes, and its network is blocked for the session anyway. A unit that
   is not installed or not running is left alone. A unit that will not stop is a
   warning, not a failed engage.
6. **Records the session start time** in `~/.cache/music-mode/session`.

Failures are also raised as a critical desktop notification (`notify-send`),
since the tray and the keyboard shortcut have no terminal to print to.

### `music-mode off`

1. Destroys the nftables table — network fully restored.
2. Stops `music-mode-dnd.service` — notifications and idle sleep released —
   and shows the tray bell again if `on` hid it. If plasmashell is not running,
   the note stays and the next `off` tries again.
3. Starts the units `on` paused, and only those: a service you had stopped
   yourself before the session stays stopped.
4. Removes the session file (if present).
5. **Leaves Bitwig running** — you are mid-session, the DAW is not killed.

`off` works even with no active session, as a recovery unblock.

### `music-mode status`

Prints current state and elapsed time. **State is the session file**, not the
live ruleset — if you tear the table down by hand, `status` will still say
"on". To check the actual firewall, use `sudo nft list table inet music_mode`.

### Making other jobs wait

music-mode stops what it can stop itself. A scheduled job it cannot stop, such
as a backup, can check for a session and skip its own run.

A job running **as you** can test for the session file. The file survives a
reboot and the firewall table does not, so treat a session file older than the
last boot as stale:

```bash
session="${XDG_CACHE_HOME:-$HOME/.cache}/music-mode/session"
boot=$(awk '/^btime/ { print $2 }' /proc/stat)
if [ -f "$session" ] && [ "$(stat -c %Y "$session")" -ge "$boot" ]; then
    exit 0   # music-mode is on
fi
```

A job running **as root** can test for the firewall table, which exists only
while the block is live:

```bash
nft list table inet music_mode >/dev/null 2>&1 && exit 0
```

## Requirements

| Package | Why |
|---|---|
| `nftables` | the outbound block itself (`nft`) |
| `kde-cli-tools` | `kde-inhibit`, for notification suppression and the idle-sleep hold |
| `python-dbus` | tray icon (StatusNotifierItem over D-Bus) |
| `python-gobject` | tray icon (GLib main loop) |
| `flatpak` | *optional* — only needed if any distraction app is a flatpak |
| `libnotify` | *optional* — `notify-send` failure notifications |
| Bitwig Studio | `bitwig-studio` must be on `PATH` |

```bash
sudo pacman -S nftables kde-cli-tools python-dbus python-gobject
```

Without `python-dbus`/`python-gobject` the CLI still works — `install.sh` warns
and skips enabling the tray rather than leaving it to crash-loop.

## Installation

```bash
./install.sh
```

Dry run — prints every destination path and mode, writes nothing:

```bash
DRY_RUN=true ./install.sh
```

Re-running is an idempotent overwrite, so `./install.sh` is also the repair
step. It installs:

| Destination | Mode | Owner |
|---|---|---|
| `~/.local/bin/music-mode` | 0755 | you |
| `~/.local/bin/music-mode-tray` | 0755 | you |
| `/usr/local/bin/music-mode-nft` | 0755 | `root:root` |
| `/etc/sudoers.d/music-mode` | 0440 | `root:root` |
| `~/.local/share/applications/music-mode-toggle.desktop` | 0644 | you |
| `~/.config/systemd/user/music-mode-tray.service` | 0644 | you |

Do **not** run `install.sh` under `sudo` — it refuses, because `$USER` and
`$HOME` would be root's. It calls `sudo` itself for exactly the two privileged
steps.

### Why the nft wrapper is root-owned

The sudoers drop-in authorizes exactly two commands —
`/usr/local/bin/music-mode-nft on` and `/usr/local/bin/music-mode-nft off`, no
wildcards — so `music-mode` can toggle the firewall without a password prompt
(it uses `sudo -n`). That path has to be root-owned: a `NOPASSWD` rule on a
script you can rewrite is a trivial local root escalation, which is why the
wrapper goes to `/usr/local/bin` and not `~/.local/bin`.

`install.sh` renders the drop-in to a `mktemp` file, checks that it is
non-empty, that the username is real and well-formed, that it contains exactly
the one intended rule, and only then runs `visudo -c` — `visudo` is a grammar
check that happily accepts empty files, unknown users and wildcards, so it is a
backstop, not the check. The grant is installed **last**, after the wrapper it
points at exists and has been verified root-owned.

Verify afterwards:

```bash
sudo -l                                    # exactly two music-mode-nft entries
sudo visudo -c -f /etc/sudoers.d/music-mode
```

## Usage

```bash
music-mode on       # enter focus
music-mode off      # exit focus
music-mode toggle   # on if off, off if on
music-mode status   # check state
music-mode          # same as status
music-mode --help   # usage
```

Or press **Meta+Shift+M** to toggle, click the system tray icon (left- or
middle-click), or launch **"Music Mode"** from the application menu — you can
pin it to your KDE taskbar or panel. All three run `music-mode toggle`.

The tray icon is `media-record` when on and `folder-music` when off; it polls
the session file every 2 seconds, so the CLI and the tray stay in sync whichever
one you use.

### Bitwig phone-home block (not installed)

`bin/bitwig-hosts` ships in this repo but is **not** installed by `install.sh`.
It adds/removes `/etc/hosts` entries for `services.bitwig.com` and
`dash.bitwig.com`, which stops the Bitwig Settings UI freezing on synchronous
network calls. Run it manually:

```bash
sudo ./bin/bitwig-hosts on
sudo ./bin/bitwig-hosts off
```

To have it on `PATH` without copying it — a copy silently drifts from the repo
the first time either side changes — symlink it instead:

```bash
ln -s "$PWD/bin/bitwig-hosts" ~/bin/bitwig-hosts
```

## Files

- [`bin/music-mode`](bin/music-mode) — the CLI (bash)
- [`bin/music-mode-nft`](bin/music-mode-nft) — root wrapper that loads/unloads the nftables ruleset
- [`bin/music-mode-tray`](bin/music-mode-tray) — KDE system tray icon daemon (python)
- [`bin/bitwig-hosts`](bin/bitwig-hosts) — optional `/etc/hosts` phone-home block, not installed
- [`etc/sudoers.d/music-mode.in`](etc/sudoers.d/music-mode.in) — sudoers template (`__USER__`) for scoped nft access
- [`share/applications/music-mode-toggle.desktop.in`](share/applications/music-mode-toggle.desktop.in) — desktop entry template (`__HOME__`) for the app menu, taskbar pin and Meta+Shift+M shortcut
- [`systemd/user/music-mode-tray.service`](systemd/user/music-mode-tray.service) — user unit for the tray daemon
- [`install.sh`](install.sh), [`uninstall.sh`](uninstall.sh) — installer and its reverse
- [`tests/test-pause-units`](tests/test-pause-units) — tests for pausing and resuming background units, run against a fake `systemctl`

Files ending in `.in` are templates; `install.sh` renders them. Rendering never
happens inside the repo — the sudoers grant is rendered to a `mktemp` file and
the desktop entry straight into `~/.local/share/applications` — so a real
username or `$HOME` never appears in the working tree to begin with.

## Removal

```bash
./uninstall.sh
```

Dry run:

```bash
DRY_RUN=true ./uninstall.sh
```

It runs `music-mode off` first — while the sudoers grant still exists, so the
firewall can actually be torn down — then stops and disables the tray unit and
removes all six installed files plus `~/.cache/music-mode`. The sudoers grant is
removed *before* the wrapper it points at. Bitwig and its scope are left alone.

If you removed things by hand mid-session instead, undo the leftovers with:

```bash
sudo nft delete table inet music_mode
systemctl --user stop music-mode-dnd.service
systemctl --user start syncthing.service   # if `on` had paused it
```

If the notifications bell is still missing from the tray, set it back under
System Tray Settings → Entries → Notifications → *Shown when relevant*.

## Troubleshooting

**`kernel upgraded since boot` / `reboot so kernel modules can load`:**
A kernel upgrade deleted the running kernel's `/lib/modules` tree, so nft can't
autoload `nft_socket` (needed by the ruleset's cgroupv2 match) until the next
boot. `music-mode` only blames the kernel when the modules tree is missing
**and** `nft_socket` is not already loaded — if the module is loaded, an nft
failure has some other cause. Not a music-mode problem — reboot. `music-mode on`
detects this before killing any apps and aborts with nothing changed. Verify
with:

```bash
uname -r
ls /lib/modules/            # running kernel's version absent = stale
ls -d /sys/module/nft_socket   # present = module already loaded
```

**`nft rule load failed`:**
The sudoers drop-in is missing or invalid, or the Bitwig scope is not active.
Re-run `./install.sh`. Verify with:

```bash
sudo visudo -c -f /etc/sudoers.d/music-mode
systemctl --user is-active music-mode-bitwig.scope
```

**`cgroupv2 path fails: No such file or directory`:**
The Bitwig scope must exist before the nft rules load. The script handles this
automatically — if you see this, Bitwig either failed to launch or ended too
quickly. Check `pgrep bitwig-studio` and `systemctl --user list-units --type=scope`.

**`Bitwig is running outside the music-mode scope`:**
Bitwig was started normally, so its traffic is not in the cgroup the ruleset
allowlists. Quit it (`killall bitwig-studio`) and run `music-mode on` again so
it is launched inside the scope. Nothing was changed.

**iLok / PACE errors under Wine (e.g. a PSP plugin) while music-mode is on:**
iLok's license service (`LDSvc.exe`) phones home over the network. It belongs
to the Wine prefix, not to Bitwig. A Bitwig launcher that keeps the prefix
alive with `wineserver -p` leaves it running in whichever cgroup first started
it, which may be outside the scope. `music-mode on` restarts the prefix inside
the scope whenever Bitwig is not already running. If Bitwig was already
running in the scope, it warns `iLok's license service (LDSvc) runs outside the
Bitwig scope`: quit Bitwig and run `music-mode on` again.

**iLok *Error 2000* ("an iLok background component ... is not running") right
after `music-mode on`:**
Restarting the prefix means it boots cold, and a PSP or other iLok plugin that
loads before `LDSvc.exe` is up fails. music-mode launches `bitwig-studio` by
name from the session's `PATH`, so a warm-up wrapper only helps if it is on that
`PATH`. Use `~/.local/bin`, not a directory only your shell rc adds such as
`~/bin`. The tray and desktop launchers don't read shell rc files. Check with
`systemctl --user status music-mode-bitwig.scope`: the description should name
your wrapper, not `/usr/bin/bitwig-studio`.

**`Bitwig scope did not become active within 5s`:**
The scope was requested but never registered. Check that `bitwig-studio` starts
on its own, and look at `systemctl --user list-units --type=scope`.

**`kde-inhibit not found` / notification warning on a non-KDE session:**
Expected without `kde-cli-tools`. `music-mode` warns and continues — firewall,
apps and Bitwig still transition correctly. Notifications are not suppressed and
idle sleep is not held off.

**Syncthing (or another paused unit) is still stopped after `off`:**
`off` starts whatever is listed in `~/.cache/music-mode/paused-units`. A unit
that will not start stays on the list and raises a desktop notification, so
running `music-mode off` again retries it. systemd refuses a unit started too
many times in a minute, which rapid on/off toggling can reach. If the list was
deleted by hand mid-session, start the unit yourself:
`systemctl --user start syncthing.service`.

**Bitwig is not launched:**
Check `command -v bitwig-studio`. If not in `PATH`, install Bitwig or ensure
`/opt/bitwig-studio/bin` is on your `PATH`.

**Tray icon missing:**
Check `systemctl --user status music-mode-tray.service`. If it never started,
the python dependencies are probably missing — install `python-dbus` and
`python-gobject`, then
`systemctl --user enable --now music-mode-tray.service`.

**Network stays blocked after `off`:**
Run `sudo nft delete table inet music_mode` manually.

**Not sure if it's on:**

```bash
music-mode status              # reads ~/.cache/music-mode/session
sudo nft list table inet music_mode   # the actual live ruleset
```

## License

[MIT](LICENSE) — do what you like with it.
