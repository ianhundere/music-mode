# music-mode

`music-mode` is a single-command focus ritual for music and art work on Arch + KDE. One command severs the distraction surface — chat and browsers killed, notifications silenced, all network except Bitwig blocked at the kernel. One command reverses it.

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
   yet — and aborts if it never appears.
3. **Suppresses KDE notifications** by running `kde-inhibit --notifications` in
   a transient user unit, `music-mode-dnd.service`. It has to be a long-lived
   process: the freedesktop Inhibit call is tied to the caller's D-Bus
   connection, so plasmashell drops the inhibition the moment a one-shot caller
   exits.
4. **Loads an nftables table** (`inet music_mode`) that drops all outbound
   traffic from UID ≥ 1000 **except** loopback and traffic from the Bitwig
   scope's cgroup. Bitwig keeps full internet access; browsers, chat, curl etc.
   are blocked at the kernel. If this step fails, notifications are released
   again and the session is *not* recorded.
5. **Records the session start time** in `~/.cache/music-mode/session`.

Failures are also raised as a critical desktop notification (`notify-send`),
since the tray and the keyboard shortcut have no terminal to print to.

### `music-mode off`

1. Destroys the nftables table — network fully restored.
2. Stops `music-mode-dnd.service` — notifications released.
3. Removes the session file (if present).
4. **Leaves Bitwig running** — you are mid-session, the DAW is not killed.

`off` works even with no active session, as a recovery unblock.

### `music-mode status`

Prints current state and elapsed time. **State is the session file**, not the
live ruleset — if you tear the table down by hand, `status` will still say
"on". To check the actual firewall, use `sudo nft list table inet music_mode`.

## Requirements

| Package | Why |
|---|---|
| `nftables` | the outbound block itself (`nft`) |
| `kde-cli-tools` | `kde-inhibit`, for notification suppression |
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

## Files

- [`bin/music-mode`](bin/music-mode) — the CLI (bash)
- [`bin/music-mode-nft`](bin/music-mode-nft) — root wrapper that loads/unloads the nftables ruleset
- [`bin/music-mode-tray`](bin/music-mode-tray) — KDE system tray icon daemon (python)
- [`bin/bitwig-hosts`](bin/bitwig-hosts) — optional `/etc/hosts` phone-home block, not installed
- [`etc/sudoers.d/music-mode.in`](etc/sudoers.d/music-mode.in) — sudoers template (`__USER__`) for scoped nft access
- [`share/applications/music-mode-toggle.desktop.in`](share/applications/music-mode-toggle.desktop.in) — desktop entry template (`__HOME__`) for the app menu, taskbar pin and Meta+Shift+M shortcut
- [`systemd/user/music-mode-tray.service`](systemd/user/music-mode-tray.service) — user unit for the tray daemon
- [`install.sh`](install.sh), [`uninstall.sh`](uninstall.sh) — installer and its reverse

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
```

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

**`Bitwig scope did not become active within 5s`:**
The scope was requested but never registered. Check that `bitwig-studio` starts
on its own, and look at `systemctl --user list-units --type=scope`.

**`kde-inhibit not found` / notification warning on a non-KDE session:**
Expected without `kde-cli-tools`. `music-mode` warns and continues — firewall,
apps and Bitwig still transition correctly.

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
