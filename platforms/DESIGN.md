# Multi-platform installers — design contract

This document is the contract every installer in `platforms/` and `native/` is built against, written down as it was actually built. Change it deliberately: the installers, their tests and the host scripts that drive `native/install.sh` depend on the names, paths, flags and file formats below. When code and this document disagree, one of them is a bug.

## Goals

- A community-scripts-style one-liner per platform: run one command on the host (or in the platform's shell), answer a short wizard where a terminal exists, and end up with the stack running.
- The stack's security property is the same everywhere: **qBittorrent, Jackett and FlareSolverr can only reach the internet through the VPN.** If the VPN or Gluetun is down, they have no internet at all (fail closed, no leak).
- No telemetry and no runtime sourcing of third-party scripts. Installers are self-contained in this repo (MIT). Ideas and install steps may be adapted from [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) (MIT) with attribution in a header comment.
- No "latest" lookups at install time, and no dependency on `api.github.com` (rate-limited). What is pinned and what follows rolling tags is set out in [Pinning scope](#pinning-scope).
- Secrets never go on a command line (where every local user can read them in the process list) and are never printed into a log file. They come from the wizard, from `TS_<KEY>_FILE` files, or from the platform's own secret store.

## Two install styles

| Style | Platforms | What runs |
|---|---|---|
| **Native system container** | Proxmox VE (LXC), Incus (system container) | One Debian 13 container. Gluetun, qBittorrent, Jackett, FlareSolverr, FileBrowser and the env-editor run as systemd services in that one container, so they share its single network namespace — the native equivalent of `network_mode: service:gluetun`. |
| **Docker Compose** | TrueNAS (custom app), Unraid (Compose Manager Plus), Synology DSM (Container Manager), CasaOS / ZimaOS (dashboard app) | The repository's `compose.yaml` (Unraid, Synology) or a platform rendering of it (TrueNAS, CasaOS), registered through the platform's own app or compose mechanism. |

## Repository layout and ownership

Parallel work must stay inside its own paths. Changes needed outside your paths are **reported, not made**.

| Path | Owner | Notes |
|---|---|---|
| `native/` | native core | In-container installer for Debian 13 system containers, its `lib/`, pins (`versions.env`, `locks/`) and `tests/`. |
| `scripts/env-editor/` | native core | Native (systemd) mode and the seeding CLI. Docker mode must keep working unchanged. |
| `update-qbittorrent.sh` | native core | Only if the native port-forward path needs it; keep Docker behaviour identical. |
| `scripts/setup.sh` | native core | Only to let the native installer reuse its venv build without launching the app. |
| `platforms/proxmox/` | Proxmox | Host-side one-liner (`pct`). |
| `platforms/incus/` | Incus | Host-side one-liner (`incus`). |
| `platforms/truenas/` | TrueNAS | Shell installer plus `truenas_app.py`, using the TrueNAS middleware API. |
| `platforms/unraid/` | Unraid | |
| `platforms/synology/` | Synology DSM | `install.sh` plus `boot.sh` (the boot task's script). |
| `platforms/casaos/` | CasaOS / ZimaOS | |
| `compose.yaml`, `.env.example`, `README.md`, `UPSTREAMS.md`, `platforms/DESIGN.md`, `.github/` | integration (maintainer) | Do not edit in parallel work. |

Each `platforms/<p>/` contains `install.sh` (the one-liner target), `README.md` (prerequisites, one-liner, what it creates, how to update, how to uninstall, limitations, and what was tested vs not, with references) and `tests/` (at least `run-tests.sh`).

## Common to every installer

One-liner form (matches docker-pve). Options go after the quoted command; `install.sh` there is only `$0`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/<p>/install.sh)" install.sh [options]
```

Every installer accepts:

| Variable | Meaning |
|---|---|
| `TS_SOURCE_DIR=/path/to/checkout` | Use a local checkout instead of downloading. This is how every installer is tested. |
| `TS_REF=<branch or tag>` | Default `main`. |
| `TS_REPO_URL=<url>` | A fork instead of this repository. |
| `TS_UNATTENDED=1` | No questions: settings come from `TS_*` variables and defaults. Also the behaviour when there is no terminal. |

A copy from `TS_SOURCE_DIR` leaves out `.git`, `.env` and `.env.*` (except `.env.example`), `configs/` and `downloads/`.

### Command-line options as built

The options differ between installers (see [Known follow-ups](#known-follow-ups)):

| Installer | Update | Uninstall | Dry run | `-y` means | Other |
|---|---|---|---|---|---|
| Proxmox | `--update [CTID]` (finds the container by its `torrent-stack` tag) | none (`pct destroy`) | none | `--unattended` | `--resume CTID`, `--unattended` |
| Incus | `--update [NAME]` | `--uninstall [NAME]` (asks first) | none | `--yes`: answer the uninstall question | `--resume NAME`, `--sync-ports [NAME]`, `--unattended` |
| TrueNAS | `--update` | `--uninstall` | `--dry-run` | (no `-y`) | `--reseed`, `--print-yaml`, `--no-pull`, `--unattended` |
| Unraid | `--update` | `--uninstall [--purge]` | `--dry-run` | `--unattended` (also `--yes`) | `--apply` |
| Synology | `--update` | `--uninstall [--purge]` | `--dry-run` | `--unattended` (also `--yes`) | `--apply`; `boot.sh [--now] [--dry-run] [--tun-only]` |
| CasaOS | `--update` | `--uninstall [--purge]` | `--dry-run` | `--unattended` (also `--yes`) | `--apply`, `--print-yaml`, `--no-register` |

All of them take `-h`/`--help`. The Docker-style installers' `--purge` never deletes downloads; `native/install.sh uninstall --purge` deletes only what is inside `/opt/torrent-stack` (downloads kept there included, a downloads folder mounted from elsewhere never).

## Native system container contract (Proxmox and Incus)

### Guest

- Debian 13 (trixie), amd64 or arm64 (every native component is pinned for both; arm64 is untested). Proxmox VE itself is amd64 only, so the Proxmox script refuses other hosts.
- Unprivileged container with `/dev/net/tun` passed through by the host script (Proxmox: `--dev0 /dev/net/tun` on PVE 8.1+, the classic `lxc.cgroup2.devices.allow`/`lxc.mount.entry` lines on 8.0; Incus: a `unix-char` device).
- Nesting: **Proxmox sets `features: nesting=1`**, because Debian 13's systemd needs it there for the units' mount namespaces (`BindPaths=`, `BindReadOnlyPaths=`; without it they fail with `226/NAMESPACE`). Incus containers allow that without `security.nesting`, which the Incus script leaves off.
- The repo checkout lives at **`/opt/torrent-stack`**; its `.env` (same keys as `.env.example`) is the single source of truth for both styles.
- The apps run as user **`torrent`** with uid/gid `PUID`/`PGID` (default 1000/1000). Gluetun and the env-editor run as root. OpenVPN drops to a separate system user `gluetun`, never `torrent` (the kill switch would block the VPN itself).

### Host script → guest hand-off

The host script creates the container, adds devices, gets the repo into `/opt/torrent-stack` (a `TS_SOURCE_DIR` copy, or `git clone --depth 1 --branch "$TS_REF" "$TS_REPO_URL"`), then runs, as root in the guest from `/opt/torrent-stack`:

```bash
bash native/install.sh install
```

**No host environment reaches the guest.** Every command the host script runs in the guest gets a fixed, known environment:

- Proxmox: `pct exec CTID -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 TERM=dumb DEBIAN_FRONTEND=noninteractive ...`. The `env -i` is required: `pct exec` hands the host's environment to the guest by default.
- Incus: `incus exec --force-noninteractive --env DEBIAN_FRONTEND=noninteractive --env TERM=dumb -- ...`. `incus exec` starts commands with its own small environment (`HOME`, `LANG`, `PATH`, `TERM`, `USER`, `container`, checked on Incus 6.0) and passes nothing from the caller.
- The host's proxy variables are never copied in (a proxy on the host's `127.0.0.1` is unreachable from the guest). `TS_GUEST_PROXY` adds `http_proxy`/`https_proxy`; a proxy URL with a user name or password is refused, because it would be on a command line.
- Host values reach guest snippets as positional arguments (`bash -c "$script" bash "$@"`), never pasted into the script text.

**Initial settings** go into a root-only (0600) file in the guest, `/root/.torrent-stack-proxmox.env` or `/root/.torrent-stack-incus.env`, written with `printf %q`: `TZ`, `PUID`, `PGID`, and with a host downloads folder `DOWNLOADS_PATH`/`INCOMPLETE_DOWNLOADS` (`/mnt/downloads`); the Incus script adds `QBIT_WEBUI_PORT` when a proxy-port offset moves qBittorrent. It holds no secrets. The guest snippet sources it with `set -a` **only for `install`**, so `native/install.sh` sees those keys in its environment; `create_env` copies every `.env.example` key it finds there into the new `.env`, and only while no `.env` exists. VPN credentials are entered afterwards in the env-editor.

### `native/install.sh` subcommands

Run as root in the container. `install`, `update`, `self-update`, `apply`, `reset-login` and `uninstall` take a lock (`/run/torrent-stack/install.lock`).

| Command | Behaviour |
|---|---|
| `install` | Idempotent (repairs, re-runs nothing that is done). Checks Debian 13 + systemd + amd64/arm64 + `/dev/net/tun`; installs Debian packages; creates `.env` from `.env.example` if missing (applying `.env` keys from the environment, see above); creates the `torrent` and `gluetun` users; installs every pinned component; builds the env-editor venv from `native/locks/env-editor.txt` and its first-run login; seeds the Jackett API key and the pinned search plugin (and qBittorrent's login if `.env` has real `QBITTORRENT_*` values); renders configs and units, loads the kill switch, starts what may start (see Startup gating); prints the env-editor URL and the first-run login, and writes the creds file. |
| `self-update [--ref REF] [--no-os-upgrade]` | **The update path.** Gets the new repository version (see [Updates](#updates)), runs `apt-get full-upgrade` (`--force-confold`; `--no-os-upgrade` skips it), then `exec`s the **new** installer's `update`. `--ref` switches to another branch or tag; on a `TS_SOURCE_DIR` copy (no `.git`) the git step is skipped and `--ref` is refused. Refused when run from the env-editor (`TS_MODE=native`). |
| `update` | Compares each pin in `native/versions.env` (and each lock file, and the env-editor's code) with what `/var/lib/torrent-stack/components/` records; downloads or builds a changed component while the old one keeps running, then stops, swaps and starts only that service. With nothing changed: about a second, nothing restarted. Stops before changing anything when Gluetun runs but the VPN is not connected (no internet). |
| `apply [--seed=qbit] [--no-restart] [service...]` | Re-renders every config derived from `.env` and restarts the named services (default: `gluetun qbittorrent jackett flaresolverr filebrowser`; `env-editor` is also accepted). Stops the affected units first, seeds, renders, then starts them, so qBittorrent cannot write an old password back. `--seed=qbit` re-seeds qBittorrent's login; `--no-restart` only renders. Gated units are reported as "left stopped", not restarted. This is what the env-editor runs in native mode. |
| `status` | One line per service (state and installed version), the VPN state, and an `app-dns` line (whether every running app still sees its private `resolv.conf`/`nsswitch.conf`). |
| `reset-login` | A new env-editor password: printed once (never into the journal), written to the creds file, env-editor restarted. Until a real qBittorrent login is set, FileBrowser gets the same new password. Takes no arguments; refused from the env-editor. |
| `uninstall [--purge]` | Stops and removes units, kill switch, installed programs and rendered files; keeps `.env`, `configs/`, downloads and `/etc/torrent-stack/gluetun.local.env`. `--purge` also deletes those, plus the venv and the `torrent` user, but only inside `/opt/torrent-stack`: a downloads folder elsewhere is never deleted. |
| `pins` | Maintainer helper: downloads every pinned file for amd64 and arm64 and prints `KEY=sha256` lines (and the `*_COMMIT` values from `git ls-remote`) for `native/versions.env`. Needs no root and no container. |
| `help` | Usage. |

`native/install.sh` can be sourced without running `main` (the host scripts' tests reuse its `git_update_checkout`).

### Creds file

`native/install.sh` writes **`/root/torrent-stack.creds`** (mode 0600) only when it has just generated a password (first `install`, `reset-login`). The host scripts print every line that does not start with `#` (Proxmox and Incus both strip leading and trailing blanks); when the file is missing or empty, Proxmox falls back to the last four `login`/`user`/`password` lines of the install log, and Incus says the login was shown earlier and names `reset-login`. Format:

```text
# torrent-stack first-run logins, created 2026-11-08T12:00Z.
# Note them somewhere safe, then delete this file.
env-editor:  http://<ip>:9191   user: admin   password: <password>
FileBrowser: http://<ip>:<FILEBROWSER_PORT>   user: admin   password: <password>
  (until you set a real qBittorrent login; then admin uses QBITTORRENT_PASSWORD)
```

`<ip>` is the container's first global IPv4 address that is not `tun0`. The env-editor's own login is stored as a bcrypt hash in `configs/env-editor/credentials.json` (0600).

### Service names

`gluetun`, `qbittorrent`, `jackett`, `flaresolverr`, `filebrowser`, `env-editor` — systemd units `torrent-<name>.service`, plus `torrent-killswitch.service` and `torrent-killswitch-check.timer`. These names match the compose services and `scripts/env-editor/restart_map.py`, so the env-editor maps keys to units 1:1. `watchtower` does not exist in native mode.

### Network and kill switch (security-critical)

- Gluetun runs natively (built from source at a pinned commit, as community-scripts' Gluetun LXC does) and owns the VPN tunnel and its own firewall. Its interface is pinned to `tun0` (`VPN_INTERFACE=tun0`). Its control server is bound to `127.0.0.1:8000` and its health server to `127.0.0.1:9999`.
- **A persistent kill switch independent of Gluetun**: the nftables table `inet torrent_killswitch`, loaded by `torrent-killswitch.service` before `network-pre.target` and before any app. It matches only packets of uid `PUID` and lets them leave via loopback (except to Gluetun's 8000/9999 and the env-editor's 9191), via `tun0`, or as replies to LAN clients (10/8, 172.16/12, 192.168/16, 100.64/10, link-local, fc00::/7, fe80::/10) on the four web UI ports. Everything else from that user is dropped, so it holds while Gluetun is stopped, crashed or reconnecting. The unit has no stop action; every app unit refuses to start without the table; `torrent-killswitch-check.timer` reloads it within a minute if something removed it.
- No DNS leaks: every app unit sees a private `/etc/resolv.conf` (only `127.0.0.1`, Gluetun's DNS) and `/etc/nsswitch.conf` (`hosts: files dns`), with the systemd-resolved, nscd and avahi sockets hidden. The kill switch also drops the user's DNS to other loopback resolvers and any DNS that does not go through `tun0`.
- LAN access to the web UIs on the `.env` ports (`QBIT_WEBUI_PORT`, `JACKETT_PORT`, `FLARESOLVERR_PORT`, `FILEBROWSER_PORT`, all 1024 or higher) and the env-editor (9191) works while the VPN is up **and** while it is down. Natively, `JACKETT_PORT` and `FLARESOLVERR_PORT` are the ports those apps really listen on.
- Port forwarding: Gluetun runs `/bin/sh /opt/torrent-stack/update-qbittorrent.sh` as `VPN_PORT_FORWARDING_UP_COMMAND` with the same environment as in Docker; the status file is set explicitly to `/tmp/gluetun/forwarded_port`, the path the script reads (kept from Debian's `/tmp` clean-up by `/etc/tmpfiles.d/torrent-stack.conf`).
- Root never reads or writes inside the app config folders: rendering and seeding there run as `torrent` (`render.py`'s `as_user()`, the seeding CLI's `--as-user`).

### Startup gating

Gluetun, qBittorrent, Jackett and FlareSolverr must not start with placeholder VPN credentials (values from `.env.example`). Natively their units carry `ConditionPathExists=/etc/torrent-stack/vpn-configured`; `apply` creates that file when the VPN settings are real and removes it (stopping the gated units) when they go back to placeholders, so systemd shows them as "start condition unmet", not failed. Real means a non-empty `VPN_PROVIDER` plus `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES` (WireGuard) or `OPENVPN_USER` and `OPENVPN_PASSWORD` (OpenVPN), none of them empty or equal to the `.env.example` value. The env-editor and FileBrowser start immediately so the user can configure the stack. The apps start once Gluetun has *started* (not once the VPN is healthy), so their web UIs answer while the VPN is down; the kill switch keeps them offline.

### env-editor in native mode

- Same UI. `torrent-env-editor.service` sets `TS_MODE=native`.
- Before saving, it runs `native/lib/render.py --root /opt/torrent-stack info --env <temp file>` on the submitted values and refuses ("Not saved") what cannot work natively (ports below 1024, unsafe paths).
- Apply runs `native/install.sh apply [--seed=qbit] <services>` instead of `docker compose up -d <services>`. Profiled services (`watchtower`) are dropped, and so is the FileBrowser seeder (`apply` renders FileBrowser's login). Two native-only restarts are added: `FILEBROWSER_PORT` also restarts Gluetun (its firewall lets that port in), `FLARESOLVERR_PORT` also restarts Jackett (it stores FlareSolverr's URL). Pressing Apply without changes offers "Apply again".

### Seeding CLI

Used by the native installer and every Docker-style installer that can run Python; the Docker-mode env-editor calls the same functions directly.

```bash
python3 -I scripts/env-editor/seed_configs.py --env /path/to/.env \
    [--config-root DIR] [--only jackett,qbit,filebrowser] [--as-user UID:GID] [--jackett-port PORT]
```

| Flag | Meaning |
|---|---|
| `--env` | Required. The stack's `.env`, read with Docker Compose's literal `.env` rules (`env_io.parse_env_literal`). |
| `--config-root` | The config folder. Default: `CONFIG_PATH` from `.env`, relative to the folder holding `.env`. |
| `--only` | Comma-separated subset of `jackett`, `qbit`, `filebrowser` (default: all). The Jackett API key is always ensured, so `--only ""` does only that. |
| `--as-user UID:GID` | Read `.env` (usually root-only) first, then drop to `UID:GID` for good (`setgroups([])`, `setgid`, `setuid`) before touching any config file. |
| `--jackett-port` | The port qBittorrent's search plugin uses to reach Jackett at `127.0.0.1`. Default: `JACKETT_PORT` from `.env` (right natively). Docker-style installers pass `9117`. |

What it does: ensures a Jackett API key in `ServerConfig.json`; `qbit` writes the PBKDF2 login into `qBittorrent.conf` (into `[WebUI]` once qBittorrent 5.3 has migrated the file), enables search, installs the Jackett search plugin only if it is missing, from the commit pinned in `native/versions.env` and only if its sha256 matches, and writes `jackett.json`; `filebrowser` writes a bcrypt `settings.yaml` that the current FileBrowser image never reads (no installer uses it any more). It never seeds the `.env.example` placeholder login: with it, `qbit` and `filebrowser` are skipped with a warning and the exit code stays 0. Everything that can fail (bcrypt import, plugin pins) is checked before the first write. Any failure prints `seed_configs: ERROR: ...` and exits 1. Only `filebrowser` needs a non-standard-library module (bcrypt).

How each caller runs it:

| Caller | Python | Flags |
|---|---|---|
| `native/install.sh` | the env-editor venv, as root, with `timeout 300` | `--env /opt/torrent-stack/.env --config-root <CONFIG_PATH> --only "" --as-user PUID:PGID`, or `--only qbit` to seed qBittorrent's login (it installs the search plugin itself first, as `torrent`) |
| TrueNAS | TrueNAS's `python3`, under `setpriv` as PUID:PGID in a private mount namespace | `--env <private copy> --config-root <private view> --only jackett,qbit --jackett-port 9117` |
| Unraid | the pinned seeding image | `--env <stack>/.env --config-root <CONFIG_PATH> --only jackett,qbit --as-user PUID:PGID --jackett-port 9117` |
| Synology | DSM's `python3`, else the pinned seeding image | `--env <stack>/.env --only jackett,qbit --as-user PUID:PGID --jackett-port 9117` |
| CasaOS / ZimaOS | the host's `python3` 3.8+, else the pinned seeding image | `--env <stack>/.env --only jackett,qbit --as-user PUID:PGID --jackett-port 9117` |

## Docker-style platforms contract (TrueNAS, Unraid, Synology, CasaOS/ZimaOS)

- Use the repo's `compose.yaml` and `.env` semantics. Unraid and Synology run `compose.yaml` and `.env` as they are. TrueNAS and CasaOS cannot read a `.env` file, so they render `compose.yaml` into their own format with every value written in and every path absolute; their drift tests (`docker compose config` on both sides) allow only the differences their READMEs list. Platform specifics (absolute data paths, default PUID/PGID, how the platform registers a stack) belong in `platforms/<p>/`.
- **Ports:** `compose.yaml` publishes `QBIT_WEBUI_PORT:QBIT_WEBUI_PORT`, `JACKETT_PORT:9117` and `FLARESOLVERR_PORT:8191` on `gluetun`, and `FILEBROWSER_PORT:80` on FileBrowser. Inside Gluetun's network Jackett is always on 9117 and FlareSolverr on 8191, so the search plugin is wired to `127.0.0.1:9117` and Jackett's FlareSolverr URL is `127.0.0.1:8191`. qBittorrent's web UI rejects a `Host` header with another port, so its port is the same on both sides, and every installer refuses `QBIT_WEBUI_PORT` 9117, 8191, 8000 or 9999 (Jackett, FlareSolverr and Gluetun's control and health servers inside that network).
- **FileBrowser** is not seeded. `compose.yaml` sets `FILEBROWSER_DATABASE_PATH=/config/database.sqlite` (the database lives in `CONFIG_PATH/filebrowser`) and `FILEBROWSER_ADMIN_PASSWORD=${QBITTORRENT_PASSWORD}` (user `admin`, reset on every start), and `group_add: ["${PGID}"]`, because the image always runs as uid 1000. Installers make `CONFIG_PATH/filebrowser` writable for FileBrowser (uid 1000, with group PGID added) before the first start: TrueNAS `1000:PGID` mode 2770; Unraid, Synology and CasaOS `PUID:PGID` with group write and setgid (2775), whatever PUID is. Docker would otherwise create it root-owned and FileBrowser would exit with "unable to open database file". FileBrowser needs at least 5 characters, at most 72 bytes (bcrypt), and ignores the value `admin` (on a new database it then makes up a password; an existing one keeps its old password). The installers check the qBittorrent password as follows: Unraid 8 characters to 72 bytes; CasaOS 5 to 72 bytes, not `admin`; Synology at least 8 characters; TrueNAS at least 6 characters, and it generates 24 when none is given. Synology and TrueNAS do not check the 72-byte limit yet.
- Gluetun needs `/dev/net/tun` and `NET_ADMIN`; every installer checks for the device before registering anything and loads `tun` where it can (`modprobe tun` on TrueNAS, Unraid and CasaOS; on Synology `insmod` now and from a root boot task at every boot). The renderers (TrueNAS, CasaOS) keep `devices`, `cap_add` and `network_mode: service:gluetun` from `compose.yaml`; TrueNAS refuses to produce a YAML without them.
- **IPv6 sysctl:** `compose.yaml`'s `net.ipv6.conf.all.disable_ipv6` sysctl cannot be set on a kernel booted with `ipv6.disable=1`; Docker then refuses to start Gluetun. CasaOS leaves the sysctl out on such kernels (`TS_IPV6_SYSCTL=auto|on|off`). The other platforms' kernels have IPv6, so they keep it.
- Keep the stack's Watchtower off (`COMPOSE_PROFILES` empty) unless the platform has no updater the user would rather use; say which in the README. TrueNAS drops the service from its app; CasaOS offers it as "Automatic updates".
- An installer that registers the stack with a platform API must be idempotent (re-running updates, not duplicates) and support a dry run that prints what it would send, with secrets masked.

### Startup gating on Docker platforms

The same placeholder rule as natively (WireGuard key and addresses, or OpenVPN user and password, still empty or the `.env.example` values). What each platform does then:

| Platform | While the VPN settings are placeholders |
|---|---|
| plain `docker compose` | No gating by an installer. Gluetun exits or keeps failing its health check, and qBittorrent, Jackett and FlareSolverr wait for `service_healthy`, so they never start; FileBrowser runs. |
| TrueNAS | The app is created, but `gluetun`, `qbittorrent`, `jackett` and `flaresolverr` get `profiles: [vpn-not-configured]`, so TrueNAS starts only FileBrowser. (A first start that fails would make TrueNAS delete the app.) Filling in the settings with the installer, or deleting those `profiles:` entries in the app's YAML, starts the rest. |
| Unraid | The stack is registered with Compose Manager with autostart off and is not started. `--apply` refuses placeholder keys. |
| Synology | The Container Manager project and the boot task are created, the stack is not started, and the boot task leaves it alone. `--apply` refuses placeholder VPN keys and a placeholder qBittorrent login. |
| CasaOS / ZimaOS | The wizard asks for the keys. Unattended without them, `.env`, folders and seeding are prepared but the app is not registered with CasaOS at all, so nothing appears on the dashboard until `--apply`. Once registered, Compose's health gate keeps the three apps stopped until Gluetun is healthy. |

## Updates

| Install | Repository files | Images / components |
|---|---|---|
| Native (Proxmox, Incus) | `native/install.sh self-update`, which the host scripts' `--update` runs (Proxmox via `pct exec`, then `status`; Incus via `incus exec`, then it re-publishes the proxy ports). **Not `git pull`:** the repository tracks two seed files under `configs/` that the apps rewrite, so `git pull` refuses as soon as a new commit changes one, and `configs/` belongs to the `torrent` user, where root must not write. `self-update` fetches (the checkout's upstream branch, or with `--ref` a shallow fetch of that branch or tag), refuses if a file it would change was edited by hand (and names it), moves the index to the new commit (`read-tree -m`), writes only files **outside** `configs/` (`checkout-index`), deletes removed ones, and moves `HEAD`. A `TS_SOURCE_DIR` install has no git: the host script copies the files in first and the git step is skipped. | `update` (run by `self-update` from the new installer) reinstalls only components whose pin, lock file or recipe changed; Debian packages through `apt-get full-upgrade` in `self-update`. |
| TrueNAS | `--update` refreshes the `source/` copy on the dataset and rebuilds the app's YAML from the new `compose.yaml`, keeping the settings it reads back from the current YAML; it lists the changes first (`--dry-run` stops there). | TrueNAS's image-update check, or `midclt call -j app.pull_images <app> '{"redeploy": true}'`. |
| Unraid | `--update` runs `git pull --ff-only` in the stack folder (the live configs are in `appdata/`, apart from the tracked seeds in `configs/`, so the pull does not trip over them), or downloads a tarball when the install was not a git clone; then Compose Manager's Update Stack. | Compose Manager Plus (Update Stack, its update checks and schedules). |
| Synology | `--update` downloads a fresh copy (git or tarball) and copies it over the project folder, which is deliberately not a git checkout; `.env`, `.env.bak`, `configs/` and `downloads/` are never overwritten. | The same `--update` pulls images and recreates the containers in order (Container Manager has no updater; a scheduled task can run `--update --unattended`). |
| CasaOS / ZimaOS | `--update` downloads the repository again (git or tarball), keeps `.env` and `configs/`, and applies with the **new** installer; `TS_REF`/`TS_REPO_URL` are remembered. | The same `--update` pulls images (cron-able), or the stack's Watchtower if turned on. |
| plain Docker | `git pull` in the checkout (but see [Known follow-ups](#known-follow-ups), item 4). | Dockhand on the docker-pve VM, or the stack's Watchtower profile. |

## Pinning scope

- **Native pins everything it downloads.** `native/versions.env` holds a sha256 (per architecture) or a git commit for Gluetun (and the Go toolchain that builds it, deleted afterwards), qBittorrent-nox, VueTorrent, Jackett, FlareSolverr, FileBrowser and the qBittorrent search plugin. `native/locks/*.txt` pin every Python package with hashes (`pip --require-hashes --no-deps`). A mismatch stops the install. Nothing moves without a commit; `native/install.sh pins` helps compute the new values. Debian packages (chromium, openvpn, nftables, python3, ...) are not pinned: they follow Debian 13 through `self-update`'s `apt-get full-upgrade`. The Debian 13 template or image is the newest the platform offers.
- **The compose stack follows rolling tags** (`:latest`, FileBrowser `:stable`, the VueTorrent docker-mod `:latest`), updated by Dockhand on the docker-pve VM, by the platform's updater, or by the optional Watchtower. Rollback by pinning a tag in `compose.yaml` (see `UPSTREAMS.md`). The Docker-mode env-editor's PyPI packages (`scripts/env-editor/requirements.txt`, `>=` ranges) are not pinned either.
- **Shared pin used by both styles:** the search plugin commit and sha256 in `native/versions.env` (read by `seed_configs.py` for every installer).
- **Docker-style installers only:** the seeding image `python:3.14.9-slim-trixie@sha256:...` (Unraid, Synology, CasaOS; the native install never uses it).
- **Platform versions and APIs** each installer depends on are listed, with how to move them, in [`UPSTREAMS.md`](../UPSTREAMS.md#platform-versions-and-apis).

## Testing (what "tested" means in this repo)

- `bash -n` and `shellcheck -S warning` clean on every shell script.
- Native: end-to-end in a real Incus Debian 13 container (install, units active, env-editor reachable, apply restarts units, update idempotent, kill switch blocks the `torrent` user's internet with Gluetun stopped and while the VPN is not connected, web UIs reachable over the container's LAN address). Real VPN connectivity cannot be tested without credentials; say so.
- `native/tests/check-env-parsing.sh` compares `env_io.parse_env_literal` and the Unraid, Synology and CasaOS `env_get` copies with `docker compose config`, and checks that the seeding CLI only installs the pinned search plugin.
- Platform scripts that call tools unavailable here (`pct`, `midclt`, DSM/Unraid/CasaOS tooling): test against faithful command shims that record calls, and validate any generated payload/compose (`docker compose config -q`, schema checks against official API docs).
- READMEs state plainly what was and was not tested.

## Known follow-ups

1. **A shared helper library.** The same helpers are copied across installers: `msg_info`/`msg_ok`/`msg_warn`/`msg_error`/`die`, `header_info`, `on_exit`/`on_error` (all six, and partly `native/install.sh`); `env_get`, `placeholder`, `env_quote`, `render_env`, `write_env`, `read_secret_file`, `random_password`, `print_env_masked`, `is_secret_key`, `version_ge`, `host_ip`, `prepare_source`/`install_source`, `stop_for_seeding` and `seed_configs` (Unraid, Synology, CasaOS); `guest`/`guest_bash`, the guest hand-off snippet, the creds display and the validators (Proxmox, Incus); `SEED_IMAGE` (three copies). They drift: `check-env-parsing.sh` exists only because `env_get` did. Moving them to one library needs an answer for the one-liner, which runs a single file from `curl`: fetch the library from the same `TS_REF` and check it, or download the repository first and re-exec from it, as several installers already do for `--update`.
2. **One CLI vocabulary.** Today `-y` means "unattended" on Proxmox, Unraid, Synology and CasaOS, "yes to the uninstall question" on Incus, and does not exist on TrueNAS; Proxmox and Incus have no `--dry-run`; Proxmox has no `--uninstall` (see [the table above](#command-line-options-as-built)). Target for every installer: `-y`/`--yes` (no questions: defaults and `TS_*`), `--dry-run` (print what would be sent, change nothing, secrets masked), `--update`, `--uninstall [--purge]`, keeping platform extras such as `--resume`, `--apply` and `--sync-ports`.
3. **A tested answer on Watchtower with `network_mode: service:gluetun`.** Watchtower's documentation says a container on `network_mode: service:<other>` is treated as an implicit link: on an update of the other container it stops the dependents first and starts them after it ([containrrr docs](https://containrrr.dev/watchtower/linked-containers/)); the nicholas-fedor fork's release notes mention Compose `depends_on` support and restart-order fixes. None of that was tested here (the test machine has no Docker bridge networking). The docs therefore prefer Dockhand or the platform updaters, offer Watchtower only for hosts with no other updater, and the Synology README warns that it may update Gluetun alone. Needed: a test on a normal Docker host with the `watchtower` profile on, a local registry serving a newer `gluetun` tag, `--run-once`, then a check that qBittorrent, Jackett and FlareSolverr were recreated into the new Gluetun network and answer on their ports.
4. **The plain Docker layout and `git pull`.** With `CONFIG_PATH=./configs`, the live `qBittorrent.conf` and `ServerConfig.json` are files git tracks, so a `git pull` stops once a commit changes either seed. Native `self-update` and Unraid's `appdata/` layout avoid this; the main README's setup does not yet.
5. **The FileBrowser seeder.** `seed_configs.py`'s `filebrowser` seeder writes a `settings.yaml` the image never reads, and the Docker-mode env-editor still runs it on Apply, where bcrypt 5 would raise an error for a password over 72 bytes. As a side effect it is what creates `configs/filebrowser` with the right owner in the main README's flow, so removing it needs that folder created explicitly.
6. **The port-forward command.** `compose.yaml` runs `/gluetun/update-qbittorrent.sh` directly, so it depends on the file's executable bit; `/bin/sh /gluetun/update-qbittorrent.sh` (as the native install does) would not. Before Gluetun v4, switch the script from `/tmp/gluetun/forwarded_port` to a `{{PORT}}` argument.
