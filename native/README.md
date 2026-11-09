# Native install (no Docker): maintainer notes

`native/install.sh` installs the whole torrent stack straight onto a **Debian 13
system container** (a Proxmox VE LXC or an Incus container) as ordinary systemd
services. The Proxmox and Incus host scripts in `platforms/` create the
container, copy this repo to `/opt/torrent-stack` and then run, inside it:

```bash
bash /opt/torrent-stack/native/install.sh install
```

This page explains what that does, where everything lives, how updates work,
how the kill switch keeps the apps off your real internet connection, and
how to troubleshoot. It ends with what was tested and what was not.

## Commands

Run these as root inside the container.

| Command | What it does |
|---|---|
| `install` | Sets everything up. Safe to run again: it repairs and does nothing that is already done. |
| `self-update [--ref REF]` | **The way to update.** Gets the new version of this repository from git (keeping your live app configs, see [Updating](#updating)), upgrades the container's Debian packages, then runs `update`. `--ref` switches to another branch or tag; `--no-os-upgrade` skips the Debian packages. The Proxmox and Incus host scripts' `--update` runs exactly this. |
| `update` | Installs only the components whose pin in `native/versions.env` changed, and restarts only those (`self-update` runs it for you). |
| `apply [service...]` | Re-renders every config file from `.env` and restarts the named services (all of them if you name none). The env-editor runs this when you press **Apply**. Extra options: `--seed=qbit` re-seeds qBittorrent's login, `--no-restart` only re-renders. |
| `status` | One line per service: running or not, and the installed version. |
| `reset-login` | Lost the env-editor login: makes a new password, prints it once, saves it in `/root/torrent-stack.creds`, and restarts the env-editor so it works right away. |
| `uninstall` | Stops and removes the services, the kill switch and the programs. Keeps `.env`, `configs/`, downloads and your own `/etc/torrent-stack/gluetun.local.env`. |
| `uninstall --purge` | Also deletes `.env`, `configs/`, downloads, the env-editor venv and `gluetun.local.env`. Data is deleted **only inside `/opt/torrent-stack`**: a downloads folder elsewhere (a NAS mount, say) is always left alone. |
| `pins` | For maintainers: downloads every pinned file and prints its sha256 for `versions.env`. |

Service names are the same as in `compose.yaml`: `gluetun`, `qbittorrent`,
`jackett`, `flaresolverr`, `filebrowser`, `env-editor`. The systemd units are
`torrent-<name>.service`.

## What `install` does, step by step

1. Checks it is on Debian 13 with systemd, amd64 or arm64, and that `/dev/net/tun` exists.
2. Installs the Debian packages it needs (`nftables`, `iptables`, `openvpn`, `python3-venv`, `libicu76` for Jackett, `chromium` + `chromium-driver` + `xvfb` for FlareSolverr, and a few basics).
3. Creates `.env` from `.env.example` if there is none. Any `.env` key passed as an environment variable is written in, e.g. `TZ=Europe/Berlin PUID=1000 bash native/install.sh install`. This happens only on the first install.
4. Creates two users: `torrent` with uid/gid `PUID`/`PGID` (runs the apps) and a system user `gluetun` (OpenVPN drops to it; it must not be the `torrent` user, or the kill switch would block the VPN itself).
5. Creates the folders and gives the app config folders to `torrent`.
6. On images that use systemd-resolved (Incus' Debian images do), turns off resolved's stub listener on `127.0.0.53`, because Gluetun's DNS server needs port 53. `/etc/resolv.conf` is pointed at resolved's list of real upstream servers, so the container keeps resolving names. Also disables IPv6, like the `sysctls:` line in `compose.yaml`.
7. Downloads or builds every component pinned in `native/versions.env`, checking each against its sha256 or git commit. Gluetun is built from source with a pinned Go toolchain from go.dev, which is deleted after the build. FlareSolverr's Python packages come from `native/locks/flaresolverr.txt`: every package, dependencies included, with its exact version and sha256 (pip refuses anything else).
8. Builds the env-editor's Python venv from `native/locks/env-editor.txt` (same rules) and creates its first-run password.
9. Seeds the Jackett API key and the pinned qBittorrent Jackett search plugin (and qBittorrent's login, if `.env` already has real `QBITTORRENT_*` values). This runs as the `torrent` user, see "Who may touch what" below.
10. Renders the configs and systemd units from `.env`, loads the kill switch, and starts what may start: the env-editor and FileBrowser always; Gluetun, qBittorrent, Jackett and FlareSolverr only once the VPN settings are filled in.
11. Prints the env-editor URL and its first-run login. The same login is saved in `/root/torrent-stack.creds` (mode 0600). Note it somewhere and delete that file.

### Startup gating

Until `.env` holds real VPN settings (not the `.env.example` placeholders),
Gluetun, qBittorrent, Jackett and FlareSolverr do not start. systemd skips
them through `ConditionPathExists=/etc/torrent-stack/vpn-configured`; they show as
"inactive (dead), start condition unmet", not as failed. `apply` creates that
file when the settings are filled in and removes it if they go back to
placeholders. Which keys count: `WIREGUARD_PRIVATE_KEY` and
`WIREGUARD_ADDRESSES` for WireGuard, `OPENVPN_USER` and `OPENVPN_PASSWORD`
for OpenVPN, plus a non-empty `VPN_PROVIDER`.

The env-editor (port 9191) and FileBrowser start straight away so you can
configure the stack.

## Files and paths

| Path | What |
|---|---|
| `/opt/torrent-stack` | This repo. Its `.env` is the single source of truth, the same file the Docker stack uses. |
| `/opt/torrent-stack/configs/<app>` | App data, as in Docker (`CONFIG_PATH`; a relative path is relative to `/opt/torrent-stack`). |
| `/opt/torrent-stack/downloads` | Downloads (`DOWNLOADS_PATH`, `INCOMPLETE_DOWNLOADS`). |
| `/usr/local/lib/torrent-stack/` | Installed programs: `gluetun/`, `qbittorrent/`, `vuetorrent/`, `jackett/`, `flaresolverr/`, `filebrowser/`. |
| `/etc/torrent-stack/` | Files rendered from `.env`. Do not edit: change `.env` and run `apply`. `gluetun.env` and `filebrowser-admin.pw` hold passwords and are root-only (0600). |
| `/etc/torrent-stack/gluetun.local.env` | Optional, yours: extra Gluetun settings, loaded last. Never written by the installer; kept by `uninstall`, deleted by `uninstall --purge`. |
| `/etc/torrent-stack/killswitch.nft` | The kill switch rules. |
| `/etc/torrent-stack/app-resolve/`, `nsswitch.conf` | What the apps see as `/etc/resolv.conf` (Gluetun's DNS, 127.0.0.1) and `/etc/nsswitch.conf` (see "DNS" below). |
| `/etc/torrent-stack/gluetun-resolve/` | Gluetun's private `resolv.conf`, which Gluetun rewrites. |
| `/etc/tmpfiles.d/torrent-stack.conf` | Keeps Debian's 10-day `/tmp` clean-up away from `/tmp/gluetun`. |
| `/etc/systemd/system/torrent-*.service`, `torrent-killswitch-check.timer` | The units. |
| `/var/lib/torrent-stack/components/` | What version of each component is installed (one file each). |
| `/run/torrent-stack/` | Root-only runtime files: the installer's lock, Gluetun's saved iptables rules. |
| `/gluetun` | Symlink to `configs/gluetun`. Gluetun has this path built in; in Docker it is a volume. |
| `/root/torrent-stack.creds` | First-run logins. Delete after noting them. |
| `native/locks/` | The Python packages, pinned with sha256 hashes (see "How update works"). |

### Services

| Unit | Runs as | Port (from `.env`) | Starts when |
|---|---|---|---|
| `torrent-killswitch` | root (oneshot) | none | first, before the network |
| `torrent-gluetun` | root | control 127.0.0.1:8000, health 127.0.0.1:9999 | VPN settings filled in |
| `torrent-qbittorrent` | torrent | `QBIT_WEBUI_PORT` (VueTorrent UI) | VPN settings filled in |
| `torrent-jackett` | torrent | `JACKETT_PORT` | VPN settings filled in |
| `torrent-flaresolverr` | torrent | `FLARESOLVERR_PORT` | VPN settings filled in |
| `torrent-filebrowser` | torrent | `FILEBROWSER_PORT` | always |
| `torrent-env-editor` | root | 9191 | always |

All of them share the container's one network, the native version of
`network_mode: service:gluetun`. The apps are ordered after Gluetun and pull
it in, but stopping Gluetun does not stop them: their web UIs stay reachable
on your LAN while the kill switch keeps them offline.

## Updating

```bash
bash /opt/torrent-stack/native/install.sh self-update
```

(or the host script's `--update`, which runs the same command). It does three
things, in this order:

1. **The new repository version.** Don't use a plain `git pull` here: the
   repository tracks two starting configs (`configs/qbittorrent/qBittorrent/qBittorrent.conf`
   and `configs/jackett/Jackett/ServerConfig.json`) that the apps rewrite in
   place, and `git pull` refuses to update as soon as a new version changes
   one of them. `self-update` fetches the new commit and updates every file
   **outside** `configs/`; it never writes into `configs/` (those folders
   belong to the `torrent` user, and root must not write where an app could
   have planted a symlink). Your live configs stay exactly as they are; the
   starting configs only matter on a first install. If you changed a
   repository file by hand and the new version changes it too, it stops and
   names the file. A copy installed with the host scripts' `TS_SOURCE_DIR`
   has no git: this step is skipped (the host script copies the new files in
   first). The checkout follows its upstream branch exactly, so don't commit
   in it.
2. **Debian packages**: `apt-get full-upgrade`, keeping config files you changed.
3. **`update`** (below), run from the new version of this script.

While Gluetun runs and the VPN is not connected, the container has no
internet at all (even for root), so `self-update` stops with that message:
`systemctl stop torrent-gluetun`, run it, then `systemctl start torrent-gluetun`.
The kill switch keeps the apps offline meanwhile.

## How `update` works

Versions are pinned in `native/versions.env`, one line per component:

- Gluetun: release tag and the commit it must point at, plus the Go toolchain version and sha256.
- qBittorrent-nox (userdocs static build), VueTorrent, Jackett, FileBrowser Quantum: release tag plus the sha256 of each download, per architecture.
- FlareSolverr: release tag and commit (it runs from source, see below).
- The qBittorrent Jackett search plugin: a commit and its sha256.
- Python packages, in `native/locks/`: `env-editor.txt` (the env-editor),
  `flaresolverr.txt` (FlareSolverr's packages, dependencies included) and
  `build-tools.txt` (setuptools, to build the one FlareSolverr package that
  ships only as source). Each line has an exact version and the sha256 of
  every file pip may use; pip is run with `--require-hashes --no-deps`.

To update a component:

1. Edit its lines in `native/versions.env`. `bash native/install.sh pins` prints
   the sha256 values for the versions you set (it downloads the files; read the
   release notes before trusting a new file).
2. When you bump FlareSolverr, or change `scripts/env-editor/requirements.txt`,
   regenerate the matching lock file on a Debian 13 machine (Python 3.13):

   ```bash
   python3 -m venv /tmp/lock && /tmp/lock/bin/pip install pip-tools==7.5.2
   # FlareSolverr: its requirements.txt from the new release tag
   /tmp/lock/bin/pip-compile --generate-hashes --allow-unsafe --strip-extras \
       --no-header --output-file native/locks/flaresolverr.txt requirements.txt
   # env-editor
   /tmp/lock/bin/pip-compile --generate-hashes --allow-unsafe --strip-extras \
       --no-header --output-file native/locks/env-editor.txt scripts/env-editor/requirements.txt
   ```

   Keep the comment block at the top of each file. `install`/`update` stop
   with a clear message if FlareSolverr's own pins are missing from
   `flaresolverr.txt`, so a forgotten lock file cannot slip through.
3. Commit, then in the container: `bash /opt/torrent-stack/native/install.sh self-update`.

`update` compares each pin (and each lock file) with what is recorded in
`/var/lib/torrent-stack/components/`. A changed component is downloaded or
built first, while the old one keeps running. Then only that service is
stopped, swapped and started again. If a download fails or its checksum does
not match, nothing is replaced; that includes the env-editor's venv, which
is built next to the old one and swapped in only once pip succeeded. With
nothing changed, `update` takes about a second and restarts nothing. It also
notices when the env-editor's own code changed after a `git pull` and
restarts just the env-editor. When something was installed that needs no
restart (VueTorrent's files), it says so. After starting a service,
`install`, `update` and `apply` wait a few seconds and warn (and exit
non-zero) if it did not stay running.

**While Gluetun is running, this container only reaches the internet through
the VPN.** If the VPN is not connected yet, `update` stops with a message
saying so, before it changes anything. Run `systemctl stop torrent-gluetun`
and try again. Starting any app afterwards also starts Gluetun again.

### Debian packages

`update` handles only the pinned components. The Debian packages (chromium,
which FlareSolverr points at arbitrary websites, plus openvpn, nftables,
python3 and the rest) are kept current with apt, as on any Debian system.
Do this regularly, for example monthly, and whenever Debian announces a
chromium security update:

```bash
apt update && apt full-upgrade
```

The same rule applies: with Gluetun running and the VPN not connected, apt
cannot reach Debian's servers. Stop Gluetun first (`systemctl stop
torrent-gluetun`), upgrade, then start it again (`systemctl start
torrent-gluetun`). FlareSolverr picks up a new chromium driver by itself on
its next start; restart it after a chromium upgrade:
`systemctl restart torrent-flaresolverr`.

## The kill switch, in plain words

The point of the stack is that qBittorrent, Jackett and FlareSolverr can only
reach the internet through the VPN. In Docker that falls out of the design:
the apps live inside Gluetun's network namespace, and when Gluetun's container
stops, that namespace goes away with it. Natively the container's network
stays up whether Gluetun runs or not, so Gluetun's own firewall alone is not
enough. A separate, permanent rule set does the job instead.

`torrent-killswitch.service` loads `/etc/torrent-stack/killswitch.nft` early in
boot, before the network comes up and before any app. It adds one nftables
table, `inet torrent_killswitch`, that looks only at packets sent by the
`torrent` user (uid `PUID`). Those packets may leave only:

1. over **loopback**, to reach the other apps and Gluetun's DNS on 127.0.0.1
   (but not Gluetun's control server on port 8000, its health server on 9999
   or the env-editor on 9191: those run as root, and with no auth file
   Gluetun v3.41's control server answers a default list of requests without
   a password, among them the VPN's public IP, the forwarded port, and
   stopping or restarting the VPN);
2. over the **VPN tunnel**, `tun0` (Gluetun's interface; the installer pins
   `VPN_INTERFACE=tun0` so the name never changes);
3. as **replies to LAN devices** that opened a connection to one of the four
   web UI ports (`QBIT_WEBUI_PORT`, `JACKETT_PORT`, `FLARESOLVERR_PORT`,
   `FILEBROWSER_PORT`). "LAN" means the private ranges 10/8, 172.16/12,
   192.168/16, 100.64/10 (Tailscale and other CGNAT setups), link-local, and
   IPv6 fc00::/7 and fe80::/10.

Everything else from that user is dropped. When Gluetun is stopped, crashed or
reconnecting, there is no `tun0`, so the apps simply have no internet. Nothing
falls back to your normal connection.

**DNS.** Every app unit gets its own view of two files (systemd bind mounts,
visible only to that service):

- `/etc/resolv.conf` points only at Gluetun's DNS server on 127.0.0.1, which
  forwards over the tunnel.
- `/etc/nsswitch.conf` has the hosts line `files dns`. That matters: on many
  Debian systems the container's own nsswitch.conf says
  `hosts: files resolve ... dns` (package `libnss-resolve`, which apt pulls in
  with systemd-resolved). Then a name lookup is not sent as a DNS packet at
  all. It is handed over a local socket to systemd-resolved, which asks the
  LAN's DNS server itself, as its own user, outside the VPN. The kill switch
  only sees packets from the `torrent` user, so it could not stop that. The
  same goes for nscd and avahi. With `files dns` the apps never use those
  helpers, and their sockets (`/run/systemd/resolve/io.systemd.Resolve`,
  `/run/nscd`, `/run/avahi-daemon`) are also hidden from the apps.

The kill switch additionally drops any DNS query from the `torrent` user to
another loopback resolver (such as systemd-resolved's 127.0.0.53), and any
DNS to the LAN or the internet that does not go through `tun0`. So even an
app with its own DNS code (Chromium has one) can only ask Gluetun.

Why folders and not single files: when `/etc/resolv.conf` is a symlink into
a folder (Incus' Debian images: `/run/systemd/resolve/`), the units get our
own folder in place of that one. A bind mount of a single file is silently
dropped in the unit's view when the host replaces the file by renaming a new
one over it, which systemd-resolved does whenever the network's DNS settings
change. When `/etc/resolv.conf` is a plain file (Proxmox), the file itself is
mounted, and the check timer (below) restarts any app that lost its view.
`native/install.sh status` shows an `app-dns` line saying whether every
running app still sees both files.

**Other users are not affected.** Root, the env-editor, apt and this installer
use the container's normal network and DNS. While Gluetun runs, its own
firewall limits even them to the VPN and the LAN. When Gluetun stops,
`native/lib/gluetun-iptables.sh` removes Gluetun's leftover firewall so root
can still reach the internet for updates.

**It stays in force.** Stopping `torrent-killswitch` leaves the rules loaded
(the unit has no stop action), and every app unit refuses to start if the table
is missing. `torrent-killswitch-check.timer` runs `native/lib/stack-check.sh`
once a minute. It reloads the table if something removed it (for example
`nft flush ruleset`, or Debian's own `nftables.service`, which flushes all
rules when it starts; leave that service disabled), and restarts an app (at
most once per 10 minutes) whose private `resolv.conf`/`nsswitch.conf` view was
lost. Between a removal and the next check, up to a minute, the apps would not
be protected. Only `native/install.sh uninstall` removes the table on purpose,
after it has stopped every app.

### Who may touch what

The `torrent` user is the one to distrust: it runs qBittorrent, Jackett,
FlareSolverr and FileBrowser, which talk to the internet, and an exploited app
would run as that user. So:

- **Root never reads or writes inside the app config folders**
  (`configs/qbittorrent`, `configs/jackett`, ...), which `torrent` owns.
  Rendering qBittorrent's and Jackett's settings and seeding their logins runs
  in a child process that has switched to `torrent` first (`render.py`'s
  `as_user()`, the seeding CLI's `--as-user`). A symlink planted there (say,
  `qBittorrent.conf` pointing at `.env`) therefore gains nothing: the child
  can only read what `torrent` can read anyway, and symlinks and other
  non-regular files are left alone with a warning.
- **`CONFIG_PATH` and the repo folder must be in folders only root can
  change.** `install`/`apply` refuse a `CONFIG_PATH` inside the downloads
  folder, say. Otherwise the app user could swap a folder on the way for a
  symlink and make root write elsewhere.
- **Downloads folders** are created by `torrent` when they sit in a folder it
  owns (`downloads/incomplete`), and never changed recursively.
- **The apps have their own `/tmp`** (`PrivateTmp=yes`), so they cannot plant
  files where Gluetun, which runs as root, keeps its own (`/tmp/gluetun`).
- **Secrets the apps never see:** `.env` and `gluetun.env` are root-only.
  FileBrowser's admin password is not passed in its environment, which the
  other apps (same user) could read in `/proc`; a root pre-start script feeds
  it on stdin to a short `filebrowser user set` run (see below).
- Within the `torrent` user the apps are not separated from each other (in
  Docker they were separate containers): an exploited qBittorrent could read
  FileBrowser's database or the downloads. That is the price of one container.

Check it yourself, inside the container:

```bash
nft list table inet torrent_killswitch                 # the rules, with packet counters
runuser -u torrent -- curl -m 8 https://github.com     # must fail
curl -m 8 https://github.com                           # root: works while Gluetun is stopped
```

## Gluetun outside Docker: what had to change

Gluetun is built for its Alpine image. Running it natively needed these
changes. Each one comes from reading Gluetun's source at the pinned tag.

- **Its defaults live in its Dockerfile.** Many settings are defaulted by the
  `ENV` block of Gluetun's Dockerfile, not by its Go code. Without them it
  crashes (a nil-pointer panic in the pprof setup). `native/lib/dockerfile_env.py`
  extracts that block from the Dockerfile of the exact version being built into
  `/usr/local/lib/torrent-stack/gluetun/image-defaults.env`, and the unit loads it
  before `/etc/torrent-stack/gluetun.env`. (community-scripts copies a handful of
  these by hand instead.)
- **`/etc/alpine-release`.** Gluetun prints the Alpine version at startup and
  exits if that file is missing. community-scripts creates the file. That makes
  every other tool, community-scripts' own add-ons included, believe the
  container is Alpine. Instead the build changes that one path in
  `internal/alpine/alpine.go` to Gluetun's own file. The change is checked: if
  upstream moves the line, the build stops with a clear message.
- **iptables: the nftables backend works, legacy is not needed.** Gluetun
  tries `iptables`, then `iptables-nft`, then `iptables-legacy`, and uses the
  first that can add a test rule. On Debian 13, `iptables` is iptables-nft;
  Gluetun ran fine with it here (it reported `IPtables version: v1.8.11`, built
  its firewall, and allowed the VPN endpoint). community-scripts switches to
  iptables-legacy. That needs the host's legacy x_tables modules, which an
  unprivileged container cannot load, and it would split the firewall across
  two systems. With nft, Gluetun's tables and the kill switch's table are both
  nftables. A packet must pass every one of them, so neither can weaken the
  other.
- **OpenVPN binary name.** Gluetun runs `openvpn2.6`; the unit's `PATH` has a
  symlink to Debian's `openvpn` (2.6).
- **OpenVPN user.** Gluetun drops OpenVPN to the user whose uid is its `PUID`.
  The installer gives it the `gluetun` system user, never `torrent`.
- **`USER` variable.** systemd sets `USER`, which Gluetun reads as an old
  name for `OPENVPN_USER`; the unit unsets it.
- **resolv.conf.** Gluetun rewrites `/etc/resolv.conf` to point at itself and
  never puts it back. The unit gives it a private copy in
  `/etc/torrent-stack/gluetun-resolve/` (mounted over the folder
  `/etc/resolv.conf` really lives in, or over the file itself when it is a
  plain file; see "DNS" above), so the container's own DNS keeps working when
  Gluetun is stopped.
- **Its DNS server listens on port 53 of every address** (a library default
  Gluetun does not expose). That is why systemd-resolved's stub is turned off.
- **Leftover firewall.** Gluetun leaves its DROP-everything iptables rules in
  place when it exits. `native/lib/gluetun-iptables.sh` saves the iptables
  rules just before Gluetun starts and puts exactly those back after it stops
  (tables Gluetun created are emptied); the kill switch is not touched. Rules
  that something else adds to iptables while Gluetun runs are lost when it
  stops, and Gluetun itself flushes the whole iptables filter table whenever
  its firewall is switched off, so do not rely on other iptables rules in
  this container (use your own nftables table instead).
- **Servers on the LAN.** In Docker, the control server (`:8000`) is private
  to the container. Here it would be on your LAN, so it is bound to
  `127.0.0.1:8000`, and the health server to `127.0.0.1:9999`.
  `FIREWALL_INPUT_PORTS` lists the four web UI ports and 9191: Gluetun's
  firewall drops other inbound LAN connections, the job compose's `ports:`
  did. That includes SSH into the container while Gluetun runs; use
  `pct enter` or `incus exec`, or add the port in `gluetun.local.env`
  (repeat the full list).
- **Port forwarding.** `VPN_PORT_FORWARDING_UP_COMMAND` is
  `/bin/sh /opt/torrent-stack/update-qbittorrent.sh`. It goes through `/bin/sh`,
  so the script's executable bit does not matter. The status file is set
  explicitly to `/tmp/gluetun/forwarded_port`, the path the script reads.
  Debian 13 deletes files in `/tmp` that were unused for 10 days, and Gluetun
  creates `/tmp/gluetun` only once, at start; so the installer adds
  `x /tmp/gluetun` to `/etc/tmpfiles.d/torrent-stack.conf`. Without it, the
  next reconnect after a long quiet spell would leave qBittorrent's port
  unchanged.
  Gluetun runs the command as root with its own environment, which carries
  `QBIT_WEBUI_PORT`, `QBITTORRENT_*` and `SCRIPT_NOTIFY_URL` exactly as in
  compose. Gluetun's wiki says that file will be removed in Gluetun v4.0.
  Before bumping to v4, change the script to take the port as an argument
  (`{{PORT}}`).
- **Version check off.** `VERSION_INFORMATION=off`: versions are pinned here.

The rest of the Gluetun environment is the one in `compose.yaml`, key for key.

## The other components

- **qBittorrent**: the userdocs static `qbittorrent-nox` build, with
  `HOME`/`XDG_*` set to `configs/qbittorrent` like the LinuxServer image. Its
  config therefore lives in the same place as in Docker:
  `configs/qbittorrent/qBittorrent/qBittorrent.conf`. Each `apply` writes the
  real save paths (Docker uses `/downloads`), the web UI port and VueTorrent's
  folder into it. **qBittorrent 5.3 moved its web UI settings** from
  `[Preferences] WebUI\...` to a `[WebUI]` section (settings migration 11).
  The seeding CLI writes the login into `[WebUI]` itself once qBittorrent
  has migrated the file (it always writes the old `[Preferences]` keys too).
  The native renderer also moves any old `[Preferences] WebUI\...` keys
  across, as qBittorrent's migration does. qBittorrent 5.3 also answers a
  good login with
  `204 No Content` instead of `Ok.`; `update-qbittorrent.sh` accepts both.
- **VueTorrent**: the release zip, used as qBittorrent's alternative web UI
  (the compose stack uses the VueTorrent docker-mod for the same thing).
- **Jackett**: the self-contained release binaries, run with `--NoUpdates`,
  `--DataFolder=configs/jackett/Jackett` and the `.env` port. Its FlareSolverr
  URL is kept at `http://127.0.0.1:FLARESOLVERR_PORT`.
- **FlareSolverr**: run from the release's source, with its Python packages
  from `native/locks/flaresolverr.txt` (FlareSolverr's own `requirements.txt`
  pins only its direct dependencies), and Debian's `chromium` and
  `chromium-driver`. That is how
  FlareSolverr's own Docker image does it, and all of it is FOSS (the release
  tarball bundles Google's Chrome for Testing). FlareSolverr patches its
  chromedriver in place and looks for it at `/app/chromedriver`. The install
  changes that path to `/usr/local/lib/torrent-stack/flaresolverr/chromedriver`
  (checked, like the Gluetun change). `native/lib/flaresolverr-prestart.sh`
  refreshes that copy whenever apt updates chromium.
- **FileBrowser Quantum**: the release binary, sharing only the downloads
  folder. The admin user is always `admin`, with password `QBITTORRENT_PASSWORD`
  (or the env-editor's first-run password until that is set; FileBrowser wants
  at least 5 characters, and otherwise keeps the previous password with a
  warning in its journal). On every start,
  `native/lib/filebrowser-prestart.sh` (root) opens the root-only
  `/etc/torrent-stack/filebrowser-admin.pw` and passes it on stdin to
  `filebrowser user set admin --password --admin`, run as `torrent`. The
  password is thus never in the server's environment. A password changed in
  FileBrowser's own UI is reset on the next start. FileBrowser cannot rename
  its admin user from its config, hence the fixed `admin`. The update check is
  off. FileBrowser Quantum also has anonymous usage statistics; they are off
  unless an admin switches them on in its settings, so leave them off.
- **env-editor**: same app as in Docker, started by `torrent-env-editor.service`
  with `TS_MODE=native`. In this mode **Apply** runs
  `native/install.sh apply <services>`. That stops the affected units, seeds,
  re-renders and starts them again, so qBittorrent cannot overwrite a freshly
  seeded password while it shuts down. The restart list is the same as in
  Docker, plus two native extras: `FILEBROWSER_PORT` also restarts Gluetun
  (its firewall lets that port in), and `FLARESOLVERR_PORT` also restarts
  Jackett (it stores FlareSolverr's URL). Before saving, the env-editor asks
  `native/lib/render.py` whether the new values work natively (ports, paths);
  if not, it shows **Not saved** with the reason and changes nothing. If an
  Apply fails half-way, `apply` starts the services it had stopped again,
  and pressing Apply without changes offers **Apply again** (re-render
  everything and restart the stack). The seeding CLI never seeds the
  `.env.example` placeholder login: with those values qBittorrent's and
  FileBrowser's logins are left alone, with a warning.

## Differences from the Docker stack

- The apps start once Gluetun has *started*, not once the VPN is *healthy*
  (compose waits for `service_healthy`). That keeps the web UIs reachable while
  the VPN is down; the kill switch keeps the apps offline in the meantime.
- FileBrowser is behind the kill switch too (it runs as `torrent`). It needs no
  internet.
- `JACKETT_PORT` and `FLARESOLVERR_PORT` are the ports the apps really listen
  on. In Docker those apps always listen on 9117 and 8191 inside the container.
- The four web UI ports must be 1024 or higher: the apps run unprivileged and
  bind their port themselves (in Docker, compose maps a host port such as 80
  for them). Ports 8000 and 9999 are taken by Gluetun on 127.0.0.1.
- `CONFIG_PATH`, `DOWNLOADS_PATH` and `INCOMPLETE_DOWNLOADS` may contain spaces
  but not `%`, `$`, quotes, backslashes or backticks (they are written into
  systemd unit files), and `CONFIG_PATH` must be in a folder only root can
  change.
- Changing `DOWNLOADS_PATH` changes the real folder. Torrents already in
  qBittorrent keep their old location; move the files and use qBittorrent's
  "Set location".
- There is no Watchtower; updates are `native/install.sh self-update`.
- IPv6 is off for the whole container, not only for the VPN side.

## Requirements for the host scripts

- Debian 13 container, unprivileged is fine, with `/dev/net/tun` passed in.
- **Proxmox: enable nesting (`features: nesting=1`).** The Gluetun and app
  units use systemd bind mounts (`BindPaths=`, `BindReadOnlyPaths=`), which need
  a mount namespace. Proxmox staff say Debian's systemd needs nesting for that
  in any case (see References). Without it those units fail with
  `status=226/NAMESPACE`, safely: nothing starts. Incus containers allow it out
  of the box.
- Roughly 2 GB of disk for the container with everything installed (chromium is
  the biggest part), plus room for downloads. The Gluetun build briefly needs
  about 600 MB more in `/var/tmp`.
- About 450 MB of RAM for the services when idle.
- The host scripts can show `/root/torrent-stack.creds` after `install`, or
  pass the install output through.

## Troubleshooting

```bash
bash /opt/torrent-stack/native/install.sh status    # what runs, versions, VPN state
journalctl -u torrent-gluetun -f                    # VPN connection, port forwarding
journalctl -u 'torrent-*' --since -10min            # everything recent
systemctl status torrent-qbittorrent                # why a unit is not running
nft list table inet torrent_killswitch              # kill switch rules and counters
```

- **A unit says "start condition unmet".** The VPN settings in `.env` are still
  placeholders. Fill them in at `http://<container-ip>:9191` and press Apply.
- **`status=226/NAMESPACE`.** On Proxmox: enable nesting for the container and restart it.
- **Gluetun loops on "restarting VPN because it failed to pass the healthcheck".**
  The VPN cannot connect. Check the credentials, the provider and the server
  countries. The apps stay offline meanwhile, by design.
- **`self-update` or `update` says there is no internet.** Gluetun is running but not connected:
  `systemctl stop torrent-gluetun`, run it again, then `systemctl start torrent-gluetun`.
- **qBittorrent's listen port stays the same.** Look for "port forwarding" lines
  in `journalctl -u torrent-gluetun`. Port forwarding needs a provider that
  supports it with Gluetun (see the main README) and `VPN_PORT_FORWARDING=on`.
- **Forgot the env-editor login.** `bash /opt/torrent-stack/native/install.sh reset-login`.
  It prints the new password once (never into the journal), saves it in
  `/root/torrent-stack.creds` and restarts the env-editor. Until you set a real
  qBittorrent login, FileBrowser uses the same new password.
- **"kill switch table was missing, reloading it" in the journal.** Something
  flushed the firewall. Find out what (often `nftables.service`) and disable it.
- **"lost its private resolv.conf/nsswitch.conf" in the journal**
  (`journalctl -u torrent-killswitch-check`). The container's
  `/etc/resolv.conf` was replaced; the app was restarted. If it keeps
  happening, run `bash native/install.sh apply` once.
- **The env-editor says "Not saved".** The values cannot work natively (for
  example a port below 1024); nothing was changed. Fix the value shown.
- **A warning that a service "is not running" after Apply or update.** It
  crashed right after starting: `journalctl -u torrent-<name> -n 30`.

## What was tested, and what was not

Tested on 2026-11-08 in Incus 6.0 Debian 13 (trixie, amd64) system containers
with systemd 257, unprivileged, `/dev/net/tun` passed in. That sandbox's kernel
has no WireGuard module, so Gluetun used its userspace WireGuard, which creates
the same `tun0`. It also has no IPv6. The final round ran on a fresh container
with the final code; the items marked "(earlier round)" were tested before the
latest security fixes and not repeated.

Tested and passed:

- `bash -n` and `shellcheck -S warning` on every shell script here, plus
  `scripts/setup.sh` and `update-qbittorrent.sh`; `py_compile` on the Python
  files.
- Fresh `install` with `PUID=1001 PGID=1001 TZ=Asia/Tokyo` passed in (about
  2 minutes). Units active as expected, Gluetun and the apps behind it gated
  until VPN settings existed, the env-editor answering from the host on the
  container IP with its first-run login (401 without it), and FileBrowser
  accepting the first-run login (no random password generated or logged).
- Fake but well-formed VPN settings (ProtonVPN, WireGuard, random key) and a
  qBittorrent login containing `"`, `$` and `\` entered through the
  env-editor's web form: Gluetun started and kept failing to connect, as
  intended; qBittorrent (204) and FileBrowser (200) accepted that login from
  the host. FileBrowser's process environment holds no password.
- Kill switch, as user `torrent`, while Gluetun ran unconnected, after
  `systemctl stop torrent-gluetun`, and after Gluetun started again: HTTPS by
  IP and by name fails; DNS to the LAN DNS, 1.1.1.1, 8.8.8.8 over TCP and
  resolved's 127.0.0.54 fails; a lookup in qBittorrent's own view of the
  system fails. tcpdump on eth0 saw 0 DNS packets from those lookups; a control
  query by root showed 2. Control: with the kill switch table deleted, the
  probe got through; the check timer put the table back (17 to 57 s). The
  torrent user cannot open Gluetun's control server (8000), its health
  server (9999) or the env-editor (9191) on loopback; root can; the apps still
  reach each other. 44 checks, 0 unexpected.
- DNS with `libnss-resolve` installed (the container's nsswitch.conf then says
  `files resolve [!UNAVAIL=return] dns`): a lookup by the torrent user outside
  the units went through systemd-resolved and out of eth0 (2 packets: the leak
  the review found). Inside an app's view the same lookups failed with 0
  packets on eth0, and with a fake DNS server on 127.0.0.1 they were answered
  by it: the lookup really goes to 127.0.0.1. Installing that package
  rewrote nsswitch.conf by renaming a new file over it, which dropped
  FileBrowser's private copy; the check timer restarted FileBrowser within a
  minute, and even before that the hidden resolved socket kept the lookup on
  127.0.0.1. FlareSolverr's Chromium still works with D-Bus hidden (it fetched
  a page through FlareSolverr's API).
- The apps' private `resolv.conf` survived the host replacing its own
  (`networkctl reconfigure`, `resolvectl dns`: new inode on the host, the
  apps still saw 127.0.0.1, Gluetun its own copy). With `/etc/resolv.conf` as a
  plain file (Proxmox style), a rename over it dropped the apps' copy as
  expected, and the check timer restarted them within about a minute, after
  which they saw 127.0.0.1 again.
- An "exploited app" (the torrent user) planting symlinks: `qBittorrent.conf`,
  `ServerConfig.json` and `jackett.json` pointing at `.env` were left alone by
  `apply` and `render.py` (with a warning), no secret reached a file the
  torrent user can read, and `.env` was unchanged; a seeding attempt failed
  safely (permission denied). `configs/qbittorrent/qBittorrent` and
  `downloads/incomplete` replaced by symlinks to root-owned folders: those
  folders stayed root-owned and empty (the old code chowned such a folder to
  the torrent user). A folder an app creates in `/tmp` is not in the real
  `/tmp`.
- `/tmp/gluetun` survived a `systemd-tmpfiles --clean` run with the age set to
  3 seconds, while another old folder in `/tmp` was deleted.
- iptables: a rule added before Gluetun started (and a nat chain) was still
  there after Gluetun stopped; Gluetun's own rules were gone, policies ACCEPT,
  root had internet.
- The env-editor refused `FILEBROWSER_PORT=80`, `CONFIG_PATH=/srv/100%cfg` and
  a `CONFIG_PATH` inside the downloads folder with "Not saved" and left `.env`
  unchanged. `CONFIG_PATH=/srv/My Configs` (with a space) worked, Jackett
  included. A service that crashed right after Apply (Jackett on a port in
  use) was reported, and Apply exited 1. A failed Apply started again what it
  had stopped. "Apply again" with nothing changed restarted the whole stack
  but not the env-editor.
- env-editor Apply restarted exactly the units its confirm page listed, for
  `SCRIPT_NOTIFY_URL`, `FILEBROWSER_PORT` (and back), `TZ` and `PUID`/`PGID`
  (1001 to 1002; systemd invocation IDs compared). After the PUID change the
  apps ran as uid 1002, every app config file belonged to 1002, the kill
  switch matched uid 1002 and that user had no internet.
- `update` with unchanged pins: no-op in about a second, with Gluetun running
  or stopped. VueTorrent pinned to v2.36.0 and back: installed, "no service
  needed a restart", no unit restarted. Jackett pinned to v0.24.3025 and back:
  only Jackett reinstalled and restarted (Gluetun was started too, because
  starting an app starts it).
- env-editor venv: with the lock file changed while the VPN was down, `update`
  refused before touching anything (15 s) and the env-editor still restarted
  fine. A lock file whose hashes did not match: pip refused, the old venv and
  the running env-editor stayed. A valid change: built next to the old venv
  and swapped in, env-editor restarted once.
- Seeding CLI: with the `.env.example` login it skipped qBittorrent and
  FileBrowser with a warning (exit 0); without bcrypt and with FileBrowser
  requested it stopped before writing anything (exit 1); `--as-user` read a
  root-only `.env` and wrote files owned by that user.
- Docker mode unchanged: the env-editor from git HEAD and the working tree,
  both without `TS_MODE`, a fake `docker` and pinned randomness, through 8
  scenarios: all 59 outputs (pages, docker compose calls, `.env`, seeded
  files) byte-identical.
- Boot order after a reboot: the kill switch loaded before `network-pre.target`
  and before every service; everything came back up, app DNS view ok.
- `uninstall`: units, kill switch, programs, rendered files, tmpfiles and
  sysctl changes removed, `resolv.conf` restored, iptables ACCEPT, root online;
  `.env`, configs, downloads and `gluetun.local.env` kept; reinstall afterwards
  worked and used `gluetun.local.env`. `uninstall --purge` deleted `.env`,
  configs, downloads, the venv, `gluetun.local.env` and the torrent user.
- (earlier round) Gating in reverse: putting the placeholder VPN key back
  stopped the gated units, also across a reboot. `install` re-run on a
  configured system restarted nothing. `update-qbittorrent.sh` run with
  Gluetun's rendered environment set qBittorrent 5.3's listen port.
- The env-editor's Indexers tab listed Jackett's indexers in native mode.

Integration round (final code, real Incus Debian 13 containers, through the
Incus host script with `TS_SOURCE_DIR` and the Proxmox host script with a
local git server; details in those READMEs):

- `self-update` from git after an upstream commit that changed the tracked
  `qBittorrent.conf`: the new commit was checked out, the live file stayed
  byte for byte the same, Debian packages were upgraded, nothing restarted;
  after a commit that changed only the env-editor, only the env-editor was
  reinstalled and restarted. On a copied-in checkout the git step was skipped.
  The git step itself is also tested against a local upstream (hand-edited
  file that upstream changes: refused and named; file removed upstream:
  removed; tag switch; failed fetch: nothing touched) in the Proxmox suite.
- `self-update` (and `update`) with Gluetun running but not connected: stops
  with the "stop Gluetun first" advice. In the container, `apt-get update`
  exited 0 without network and `apt-get update --error-on=any` exited 100.
- `reset-login`: the new password works at once through the env-editor, the
  old one is refused, the password is not in the journal.
- `apply` with placeholder VPN settings lists the gated units as "Left
  stopped until the VPN settings are filled in", not as restarted.
- A `.env` line `QBITTORRENT_PASSWORD=pw # note` seeds `pw`, like Docker
  Compose. `native/tests/check-env-parsing.sh` compares
  `parse_env_literal` and the Unraid, Synology and CasaOS `env_get` with
  `docker compose config` on 30 cases (all equal), and checks that the
  seeding CLI only installs the search plugin from the pinned commit with
  the pinned sha256.
- qBittorrent 5.3 logins through an Incus proxy device whose host port is
  the container port (204), and refused (401) when the Host header names
  another port.

Not tested:

- **A real VPN connection and port forwarding.** No VPN credentials were
  available, so Gluetun never connected. Not exercised: traffic through
  `tun0`, Gluetun's DNS server answering on port 53 (a fake DNS server stood
  in for it), Gluetun itself calling the port-forward command, and the Discord
  notification.
- Kernel WireGuard (the sandbox kernel has none). The kill switch rules ignore
  kernel-generated packets (they carry no user id), so kernel WireGuard's own
  traffic should pass. This was not observed.
- OpenVPN (`VPN_TYPE=openvpn`), including OpenVPN dropping to the `gluetun` user.
- Proxmox VE (no `pct` here) and its AppArmor profile; the nesting requirement
  above comes from Proxmox staff, not from a test here. The plain-file
  `/etc/resolv.conf` case was imitated in Incus, not tested on Proxmox.
- IPv6: the sandbox kernel has no IPv6 at all, so neither the sysctl nor the
  IPv6 kill switch rules were exercised.
- arm64: the arm64 checksums are pinned and the lock files list arm64 wheels,
  but nothing was run on arm64.
- FlareSolverr solving a real Cloudflare challenge (it has no internet without
  the VPN).
- A torrent-user process started outside the stack's units (for example with
  `runuser`) uses the container's normal nsswitch.conf and can resolve names
  through systemd-resolved when `libnss-resolve` is installed. Only the
  services this installer starts get the private view.
- The 10-minute limit on automatic restarts by the check timer was exercised
  only in its first minute (a repeated loss was not provoked).

## References

- apt-get `--error-on=any` (used by `install` and `self-update`; a plain `apt-get update` exits 0 even when nothing could be fetched): <https://manpages.debian.org/trixie/apt/apt-get.8.en.html>
- Docker Compose `.env` file syntax (inline comments, quotes, escapes), which `env_io.parse_env_literal` follows: <https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file-syntax>
- Gluetun source at the pinned tag (Dockerfile `ENV` block, `internal/alpine`,
  `internal/firewall/support.go`, `internal/dns`, `internal/routing`,
  `internal/portforward`): <https://github.com/qdm12/gluetun/tree/v3.41.3>
- Gluetun wiki, firewall options: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/firewall.md>
- Gluetun wiki, VPN port forwarding: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>
- qBittorrent 5.3.0 settings migration (`src/app/upgrade.cpp`): <https://github.com/qbittorrent/qBittorrent/blob/release-5.3.0/src/app/upgrade.cpp>
- qBittorrent static builds: <https://github.com/userdocs/qbittorrent-nox-static/releases>
- FlareSolverr Dockerfile and `src/utils.py`: <https://github.com/FlareSolverr/FlareSolverr/tree/v3.5.2>
- FileBrowser Quantum admin password handling (`backend/pkg/settings/auth.go`): <https://github.com/gtsteffaniak/filebrowser/tree/v2.0.2-stable>
- systemd unit conditions and dependencies: <https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html>
- systemd service settings (`BindReadOnlyPaths=`, `InaccessiblePaths=`, `PrivateTmp=`): <https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html>
- systemd tmpfiles.d (`x` lines): <https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html>
- nss-resolve (talks to systemd-resolved over `/run/systemd/resolve/io.systemd.Resolve`): <https://www.freedesktop.org/software/systemd/man/latest/nss-resolve.html>
- Debian 13 release notes, 5.2.1 (files in `/tmp` deleted after 10 days, `x` exemptions): <https://www.debian.org/releases/trixie/release-notes/issues.en.html>
- mount_namespaces(7), restriction 6 (a mount point renamed over in another namespace is removed): <https://man7.org/linux/man-pages/man7/mount_namespaces.7.html>
- PR_SET_DUMPABLE (a process that switched user is not dumpable, so others cannot ptrace it): <https://man7.org/linux/man-pages/man2/PR_SET_DUMPABLE.2const.html>
- pip hash-checking mode (`--require-hashes`): <https://pip.pypa.io/en/stable/topics/secure-installs/>
- pip-tools (`pip-compile --generate-hashes`): <https://github.com/jazzband/pip-tools>
- Gluetun control server authentication: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md> (the wiki describes the current behaviour, routes private by default; v3.41.3's default "public" role, which the kill switch rule guards against, is in `internal/server/middlewares/auth/settings.go` at the pinned tag)
- FileBrowser Quantum `user set` and admin bootstrap (`backend/cmd/kong.go`, `backend/internal/state/quick_setup.go`): <https://github.com/gtsteffaniak/filebrowser/tree/v2.0.2-stable>
- nftables conntrack matches: <https://wiki.nftables.org/wiki-nftables/index.php/Matching_connection_tracking_stateful_metainformation>
- nftables packet metainformation (`meta skuid`, `oifname`): <https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_metainformation>
- Proxmox staff on Debian containers needing nesting: <https://forum.proxmox.com/posts/837564/>
- Go downloads and checksums: <https://go.dev/dl/?mode=json>
- community-scripts/ProxmoxVE (MIT), whose install steps this adapts: <https://github.com/community-scripts/ProxmoxVE>
