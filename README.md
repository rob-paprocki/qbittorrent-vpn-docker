# qBittorrent + Gluetun VPN Docker Stack

A Docker Compose stack: Gluetun VPN gateway, qBittorrent (LinuxServer), Jackett, FlareSolverr, FileBrowser, and an optional Watchtower. Pushes the VPN's forwarded port into qBittorrent on every reconnect and reports stack events to Discord.

Designed to drop into the Docker VM provisioned by the companion repo [docker-pve](https://github.com/rob-paprocki/docker-pve) (which pre-installs [Dockhand](https://dockhand.pro) to manage and update the stacks in `/opt/stacks/`, with Dockge as an option), but works on any Docker host. For the platforms below there are one-line installers instead.

## Platform installers

Each installer is one command, run as root on the platform itself (on Incus, a member of the `incus-admin` group will do). It asks a few questions (or reads `TS_*` variables when there is no terminal) and sets the whole stack up the way that platform expects. Read the platform's guide before you run it: it lists what the script creates, how to update and uninstall, and what was and was not tested.

| Platform | Style | Run this | Needs | Guide |
|---|---|---|---|---|
| Proxmox VE | Native: one Debian 13 LXC container, no Docker | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh)"` in the host's **Shell** | Proxmox VE 8.x or 9.x on amd64, updated since September 2025 (`pve-container` 5.3.1 or newer on PVE 8, 6.0.10 or newer on PVE 9, which can create Debian 13.1+ containers; the script checks) | [platforms/proxmox](platforms/proxmox/README.md) |
| Incus | Native: one Debian 13 system container, no Docker | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)"` on the Incus host (or a machine whose `incus` client manages it) | Incus 6.0 LTS or newer (tested on 6.0.0), an amd64 or arm64 server, root or the `incus-admin` group, bash 4.4+ | [platforms/incus](platforms/incus/README.md) |
| TrueNAS | Docker: a TrueNAS custom app built from `compose.yaml` | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)"` in **System > Shell** after `sudo -i` | TrueNAS 25.10 (24.10 and 25.04 run with a warning, untested; older is refused), Apps set up with a pool | [platforms/truenas](platforms/truenas/README.md) |
| Unraid | Docker: a Compose Manager Plus stack | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/unraid/install.sh)"` in the web UI's terminal | Unraid 7.x (6.12 is allowed but untested), array started, Docker on, Compose Manager Plus 2026.09.03 or newer, a downloads share | [platforms/unraid](platforms/unraid/README.md) |
| Synology DSM | Docker: a Container Manager project plus a boot task | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)"` over SSH after `sudo -i` | DSM 7.2 or later, Container Manager (24.0.2-1543 or later is best), SSH on, a downloads shared folder, a DSM user for the apps, an x86_64 or arm64 NAS | [platforms/synology](platforms/synology/README.md) |
| CasaOS / ZimaOS | Docker: one CasaOS dashboard app | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/casaos/install.sh)"` in a root shell | CasaOS 0.4.4 or newer (tested on 0.4.15); ZimaOS is supported but untested; amd64 or arm64 | [platforms/casaos](platforms/casaos/README.md) |

Every platform also needs a VPN provider with port forwarding (see [Prerequisites](#prerequisites)). Every installer accepts `TS_REF=<branch or tag>` (default `main`) and `TS_SOURCE_DIR=/path/to/checkout` (use a local copy instead of downloading). Options go after the quoted command, for example `bash -c "$(curl ...)" install.sh --help`: the word `install.sh` there is only the name bash gives the script. How the installers are built, and what they promise, is in [platforms/DESIGN.md](platforms/DESIGN.md).

### Native mode (Proxmox VE and Incus)

The Proxmox VE and Incus installers run no Docker at all. They create one unprivileged Debian 13 container and run [`native/install.sh`](native/README.md) in it, which installs Gluetun, qBittorrent-nox with VueTorrent, Jackett, FlareSolverr, FileBrowser and the env-editor as ordinary systemd services (`torrent-<name>.service`). They share the container's one network, the native version of `network_mode: service:gluetun`. That network stays up when Gluetun stops, so an nftables kill switch makes sure the apps' user can reach the internet only through the VPN tunnel, whether Gluetun runs or not. It uses the same `.env` keys and the same env-editor (on port 9191) as the Docker stack. Every component is pinned by checksum or git commit in `native/versions.env`, there is no Watchtower, and you update from inside the container with `bash /opt/torrent-stack/native/install.sh self-update` (or the host script's `--update`, which runs that). A lost env-editor login is replaced with `bash /opt/torrent-stack/native/install.sh reset-login`. [native/README.md](native/README.md) explains the kill switch, where everything lives, and how native mode differs from Docker.

## Prerequisites

* Docker Engine 20.10+ with the Docker Compose plugin
* `/dev/net/tun` available on the host (loaded automatically on most Linux kernels)
* `NET_ADMIN` capability (granted via `cap_add` in the compose file)
* For the setup editor: Python 3.9+ with the `venv` module. On Debian/Ubuntu that means `python3` plus `python3-venv`; Debian 13 cloud images, including VMs from older docker-pve versions, ship without `python3-venv` (`sudo apt-get install -y python3-venv`).
* A VPN provider that supports port forwarding through Gluetun; the port-update flow depends on it. Gluetun currently covers ProtonVPN, Private Internet Access, Perfect Privacy, and PrivateVPN. NordVPN, Mullvad, and AirVPN are not supported on this path: the stack will connect, but qBittorrent's listen port will stay at 0 and nothing will seed.

See the current list in Gluetun's wiki: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>

## Setup

```bash
# Pick a stacks dir (the paired docker-pve VM uses /opt/stacks/).
mkdir -p /opt/stacks && cd /opt/stacks

# Clone into a folder named after the compose project (`name: torrent-stack`)
# and move in. Dockge needs the names to match; see "If you also run Dockge".
git clone https://github.com/rob-paprocki/qbittorrent-vpn-docker.git torrent-stack
cd torrent-stack

# Prep host-side state dirs so the containers can write them as PUID/PGID.
# configs/filebrowser must exist before the first start: Docker would
# create it as root, and FileBrowser could not write its database there.
mkdir -p configs/filebrowser downloads/incomplete
sudo chown -R 1000:1000 configs downloads  # match PUID/PGID

# Launch the setup editor. First run creates a Python venv (~10 MB),
# auto-generates an admin password (printed to stdout, saved to
# configs/env-editor/credentials.json), then serves the form on :9191.
./scripts/setup.sh
```

Open `http://<host>:9191` in a browser, log in with the printed credentials, fill in VPN details, a qBittorrent username and password, and the ports, hit **Preview changes** then **Apply**. The editor writes `.env`, stops qBittorrent and seeds `qBittorrent.conf` (PBKDF2 password, and the Jackett search plugin pointed at `127.0.0.1:9117`, where Jackett listens inside the stack), generates a Jackett API key, creates `<CONFIG_PATH>/filebrowser` if it is missing (mode 2775, group `PGID`, and owner `PUID` when the editor runs as root, so a `CONFIG_PATH` other than `./configs` works too), and brings the stack up. No temp-password log-grep dance, no plugin-install UI clicking, no API-key copy/paste.

FileBrowser needs no seeding: `compose.yaml` hands it `QBITTORRENT_PASSWORD`, so its login is user **`admin`** with the qBittorrent password (see [FileBrowser](#filebrowser) below). That is why the editor checks the qBittorrent login on **Preview changes** and again on **Apply**, before it saves anything: it refuses an empty user or password, the `.env.example` placeholders (anyone can look them up), a password FileBrowser cannot use (it must be 5 to 72 bytes and not `admin`), and a password with `$` (see below). It then shows **Not saved** with the reason above the form, which still holds what you entered, and changes nothing.

The editor stays running — same URL, same login — for any future `.env` edit. It computes a diff of what's changing on save and only recycles the services that depend on the changed variables.

Keep `$` out of `.env` while you use the editor. Each **Apply** writes every value in `.env` again, the ones you did not touch included, and puts a value with `$` in double quotes, where Docker Compose reads `$name` as a variable. So the editor refuses a qBittorrent password with `$`, also one that is already in `.env` (the Unraid and Synology installers write such a password in single quotes, which Compose takes literally): the containers would get a shorter password than qBittorrent. Other values with `$`, such as an OpenVPN password, are not refused and reach the containers shorter after the next **Apply**. Quotes and backslashes are fine.

### Add indexers

With the stack up, the editor's **Indexers** tab lists everything in Jackett's catalog. Click **configure** on an indexer, fill in whatever credentials Jackett asks for (public trackers need none; private trackers prompt for passkey/cookie/etc.), save. Jackett's own UI at `http://<host>:${JACKETT_PORT}` still works if you prefer it.

### Deploy on the paired docker-pve VM (Dockhand)

If the host is the Docker VM produced by [docker-pve](https://github.com/rob-paprocki/docker-pve), clone into `/opt/stacks/torrent-stack` as above, then in Dockhand (`http://<host>:3000`) open **Stacks → Adopt** and select `torrent-stack`. Dockhand edits `compose.yaml` and `.env` where they are, so it and the env-editor always work on the same files.

* **`.env` changes:** use the env-editor. It handles the config seeding and only recycles the services a change affects. Deploying from Dockhand runs the same `docker compose` with a compatible Compose version, so it leaves unchanged containers alone.
* **Image updates:** Dockhand's nightly update covers this stack, so leave this stack's own Watchtower off (see **Image updates** below). When Dockhand updates `gluetun`, it recreates qBittorrent, Jackett and FlareSolverr onto the new network namespace itself. The next env-editor or `docker compose up` run recreates those dependents once more to settle Compose's view of them; `gluetun` and the VPN connection are not touched.

#### If you also run Dockge

Dockge (at `http://<host>:5001`, when installed) lists the stack as `torrent-stack` if you cloned into `/opt/stacks/torrent-stack` as above. The folder name matters: Dockge names stacks after their folder, while Docker names the project from `name: torrent-stack` in `compose.yaml`. Cloned into the default `qbittorrent-vpn-docker/` folder, the stack shows up twice in Dockge: an inactive `qbittorrent-vpn-docker` entry you can edit, and an active `torrent-stack` entry marked "This stack is not managed by Dockge".

Use Dockge for log tailing and for reading or editing files. Use the env-editor (or `docker compose` on the host) for `.env` changes and restarts: it handles the config seeding and only recycles the services a change affects. Avoid Dockge's **Start**, **Update** and **Deploy** buttons for this stack. Dockge 1.5.0 runs its own bundled Docker Compose (v2.34.0), which computes different config hashes from the host's newer Compose plugin, so each of those buttons recreates every container (here, a VPN reconnect and a qBittorrent restart), and the host's Compose recreates them again the next time it touches them.

### Upgrading from a pre-`name: torrent-stack` deployment

The compose file now declares `name: torrent-stack`. Earlier versions let Docker Compose derive the project name from the parent directory (`qbittorrent-vpn-docker` or `docker-vpn-qbittorrent`). If you are upgrading in place, bring the old project down under its old name first, then up under the new one so Docker doesn't leave orphaned containers:

```bash
docker compose -p qbittorrent-vpn-docker down   # or -p docker-vpn-qbittorrent, whichever you had
docker compose up -d
```

### Upgrading to the optional-Watchtower version

Watchtower now only runs with the `watchtower` Compose profile, which is off by default. An existing Watchtower container keeps running after you update, because `docker compose up` (even with `--remove-orphans`) leaves a profile-disabled service's container alone. Either remove it:

```bash
docker compose rm -s -f watchtower
```

or keep it by setting `COMPOSE_PROFILES=watchtower` in `.env` (env-editor: **Watchtower → Run Watchtower: on**).

### Upgrading to the FileBrowser-database and port-mapping version

To update:

1. Stop the env-editor (Ctrl+C) and run `git pull` in the stack folder (see the last point below if it stops).
2. Before you run `docker compose up -d` (step 3), check `QBITTORRENT_USER` and `QBITTORRENT_PASSWORD` in `.env`: from this version on, the password is also FileBrowser's login (user `admin`), on every interface. If either is still the `.env.example` placeholder (`your_qbit_username`, `your_qbit_password`; the editor used to save those without a word), or the password is `admin`, under 5 or over 72 bytes, or has a `$`, choose a new login now: in the editor (`./scripts/setup.sh`, then **Preview changes** and **Apply**), or by hand in `.env` and in qBittorrent's **Tools → Options → Web UI**.
3. Run `docker compose up -d`. It recreates the containers whose settings changed (FileBrowser at least). Start the editor again with `./scripts/setup.sh` if it is not running.

This version changes these things for an existing Docker install:

* **FileBrowser keeps its database, and its login is user `admin` with `QBITTORRENT_PASSWORD`.** Before, its database lived inside the container and was lost whenever the container was recreated, and the `configs/filebrowser/settings.yaml` the editor wrote (with a bcrypt hash of the qBittorrent password) was never read, so `admin` had whatever password FileBrowser itself had set up. On its first start after the update FileBrowser creates `configs/filebrowser/database.sqlite` with one user, `admin`, whose password is `QBITTORRENT_PASSWORD`; its log says `Using admin password from FILEBROWSER_ADMIN_PASSWORD environment variable`. Users, shares and settings you made in FileBrowser before the update are gone; from now on they are kept. `settings.yaml` is no longer written or read, so you can delete it.
  * If FileBrowser keeps restarting and its log says `unable to open database file`, `configs/filebrowser` is not writable for it: FileBrowser always runs as uid 1000, and a folder Docker created belongs to root. Fix it with `sudo chown 1000:1000 configs/filebrowser` when PUID/PGID are 1000; with other IDs, `sudo chown PUID:PGID configs/filebrowser && sudo chmod 2775 configs/filebrowser`. Then `docker compose up -d filebrowser`.
  * If `QBITTORRENT_PASSWORD` is one FileBrowser cannot use, the login is not what you expect: with `admin` (or an empty value) FileBrowser makes up a random password and prints it once in its log (`docker compose logs filebrowser`), with more than 72 bytes it does not start, and the `.env.example` placeholder `your_qbit_password` would be FileBrowser's password for anyone who has read `.env.example`. The editor now refuses to save such a login (and a password under 5 bytes or with `$`): until you choose another password in its form, every **Preview changes** ends in **Not saved**.
* **Jackett and FlareSolverr keep their own ports inside the stack** (see [Ports](#ports-inside-and-outside-the-stack)): `compose.yaml` now publishes `JACKETT_PORT:9117` and `FLARESOLVERR_PORT:8191`. With the default ports nothing changes. Before, a `JACKETT_PORT` or `FLARESOLVERR_PORT` other than the default was published to that same port inside the stack, where nothing listens, so the web UI could not be reached on it; now it can. A `JACKETT_PORT` set in the editor also pointed qBittorrent's search plugin at that port. Edit `configs/qbittorrent/qBittorrent/nova3/engines/jackett.json` and set `"url": "http://127.0.0.1:9117"`. qBittorrent starts the plugin afresh for every search, so the next search uses it. (If you had made another port work by changing Jackett's own `"Port"` in `configs/jackett/Jackett/ServerConfig.json`, set that back to 9117.)
* **`update-qbittorrent.sh` and `scripts/setup.sh` are executable in git now.** Older checkouts had both as plain files: Gluetun cannot run the port-update script that way (see [Operational notes](#operational-notes)), and `./scripts/setup.sh` stopped with "Permission denied". `git pull` fixes both modes. If you made either file executable yourself (`chmod +x`, which both needed until now), git counts that as a local change, and the pull stops with "Your local changes to the following files would be overwritten by merge". Undo it first with `git checkout -- update-qbittorrent.sh scripts/setup.sh`, then run `git pull`. (This update leaves the tracked qBittorrent and Jackett config files alone, so they do not stop the pull; a later update may, see [Known follow-ups, item 4](platforms/DESIGN.md#known-follow-ups).) A copy made without git needs `chmod 755 update-qbittorrent.sh scripts/setup.sh`.

### Moving an existing clone to the `torrent-stack` folder

If you cloned into the default `qbittorrent-vpn-docker/` folder, stop the env-editor (Ctrl+C) and move the checkout. Relative paths (`./configs`, `./downloads`) move with it.

```bash
cd /opt/stacks/qbittorrent-vpn-docker
docker compose down
cd /opt/stacks
mv qbittorrent-vpn-docker torrent-stack
cd torrent-stack
docker compose up -d
./scripts/setup.sh   # restart the env-editor from the new folder
```

## Doing it manually (without the editor)

If you'd rather skip the editor and provision by hand — the stack still works end-to-end that way; the editor is a convenience, not a dependency.

* **`.env`** — `cp .env.example .env`, edit in `$EDITOR`. Set `QBITTORRENT_PASSWORD` to the password you will give qBittorrent **before the first `docker compose up`**: FileBrowser takes it as its admin password at every start, and `your_qbit_password` from `.env.example` is public. Nothing checks it on this path, so keep to FileBrowser's rules yourself: 5 to 72 bytes, not `admin` (see [FileBrowser](#filebrowser)).
* **Folders** — `mkdir -p configs/filebrowser downloads/incomplete` (with another `CONFIG_PATH` or `DOWNLOADS_PATH`, the same folders there) and give them to PUID/PGID, as in [Setup](#setup).
* **FileBrowser** — user `admin`, password `QBITTORRENT_PASSWORD` from `.env`. Nothing to look up in a log (see [FileBrowser](#filebrowser)).
* **qBittorrent** — the LinuxServer image prints a temporary admin password on first start (`docker compose logs qbittorrent | grep -i -A1 'temporary.*password'`). Log in with it (user `admin`), and in **Tools → Options → Web UI** set the user name and password to `QBITTORRENT_USER` and `QBITTORRENT_PASSWORD` from `.env`. The port-update script logs in with those. If you change the password in `.env` later, run `docker compose up -d gluetun qbittorrent jackett flaresolverr filebrowser` so Gluetun and FileBrowser get it.
* **Jackett search plugin** — enable **Tools → Options → Search → "Enable search engine"** in qBittorrent, install the plugin via **Search → Search Plugins → Install new** with `https://raw.githubusercontent.com/qbittorrent/search-plugins/<commit>/nova3/engines/jackett.py`, where `<commit>` is `QBIT_SEARCH_PLUGINS_COMMIT` from [`native/versions.env`](native/versions.env) (the version the installers use and check). Then edit `./configs/qbittorrent/qBittorrent/nova3/engines/jackett.json`: paste your Jackett API key into `api_key` and leave `url` at `http://127.0.0.1:9117`. qBittorrent reaches Jackett inside the stack, so that is always port 9117, whatever `JACKETT_PORT` is.
* **Jackett indexers** — add them in Jackett's own UI at `http://<host>:${JACKETT_PORT}`.

The `FILEBROWSER_PORT` compose binding is `0.0.0.0:${FILEBROWSER_PORT}` by default; firewall it off, use a reverse proxy, or set it to a loopback-only bind if the host is reachable from untrusted networks.

## Operational notes

* **Image tags.** Every image in `compose.yaml` is on a rolling tag (`:latest`, or `:stable` for FileBrowser), pulled nightly by Dockhand on the docker-pve VM or by this stack's optional Watchtower (the platform installers say which updater they use; the native install pins every version instead). Pin a specific version in `compose.yaml` if reproducibility matters more than auto-update — see `UPSTREAMS.md` for the per-image rollback recipe. The Gluetun image is the one worth watching: provider env-variable renames have shipped as minor bumps there.
* **Image updates.** On the docker-pve VM, Dockhand's nightly update covers this stack: it blocks an update whose image has more known vulnerabilities than the running one, and reconnects the containers that share gluetun's network. On a host with no other updater, turn on this stack's own Watchtower: env-editor **Watchtower → Run Watchtower: on**, or `COMPOSE_PROFILES=watchtower` in `.env`. It runs `ghcr.io/nicholas-fedor/watchtower:latest`, the active community fork of `containrrr/watchtower` (archived 2025-12-17 at `v1.7.1`), and only touches this stack's containers (`scope=torrent-stack`).
* **Restart gluetun with its dependents, never alone.** qBittorrent, Jackett and FlareSolverr share gluetun's network namespace. Restarting only the `gluetun` container (a per-container Restart button in a Docker UI, or `docker restart`) leaves them with no network until they are recreated too. The env-editor already recycles them together; from the CLI, `docker compose up -d --force-recreate gluetun qbittorrent jackett flaresolverr`.
* **IPv6.** Disabled via a Docker sysctl on the gluetun service (`net.ipv6.conf.all.disable_ipv6=1`), which propagates to every container on `network_mode: service:gluetun`. The host's IPv6 is untouched. On a host booted with `ipv6.disable=1` that sysctl cannot be set; see [Hosts booted with ipv6.disable=1](#hosts-booted-with-ipv6disable1).
* **`update-qbittorrent.sh` must stay executable.** Gluetun runs it as `/gluetun/update-qbittorrent.sh` with no shell in between, and the read-only mount keeps the file's mode from the host. Without the executable bit Gluetun cannot run it, and qBittorrent's listen port is never updated. git keeps the bit (the file is mode 755 in the repository). A copy made another way, for example through an SMB share or from Windows, can lose it: `chmod 755 update-qbittorrent.sh`, then `docker compose up -d --force-recreate gluetun qbittorrent jackett flaresolverr`. The native install runs it through `/bin/sh`, so there the bit does not matter.

### Ports inside and outside the stack

qBittorrent, Jackett and FlareSolverr share Gluetun's network, so their ports are published on the `gluetun` service:

| `.env` key | Published as | Inside the stack |
|---|---|---|
| `QBIT_WEBUI_PORT` | `QBIT_WEBUI_PORT:QBIT_WEBUI_PORT` | qBittorrent listens on `QBIT_WEBUI_PORT` itself. Its web UI rejects a request whose `Host` header names another port, so both sides must be the same number. |
| `JACKETT_PORT` | `JACKETT_PORT:9117` | Jackett always listens on 9117. |
| `FLARESOLVERR_PORT` | `FLARESOLVERR_PORT:8191` | FlareSolverr always listens on 8191. |
| `FILEBROWSER_PORT` | `FILEBROWSER_PORT:80` | FileBrowser has its own network. |

So `JACKETT_PORT` and `FLARESOLVERR_PORT` only choose the port on the host, for your browser and other machines. Inside the stack the apps always talk to `127.0.0.1:9117` (qBittorrent's search plugin) and `127.0.0.1:8191` (Jackett's FlareSolverr URL). `QBIT_WEBUI_PORT` must not be 9117, 8191, 8000 or 9999, which Jackett, FlareSolverr and Gluetun's control and health servers already use inside that shared network. In native mode the apps listen on the `.env` ports themselves (see [native/README.md](native/README.md)).

### FileBrowser

* **Login:** user **`admin`**, password `QBITTORRENT_PASSWORD` from `.env`. `compose.yaml` passes it as `FILEBROWSER_ADMIN_PASSWORD`, and FileBrowser sets the `admin` user's password from it **every time it starts**. A password you change for `admin` inside FileBrowser lasts only until the next restart; change `QBITTORRENT_PASSWORD` instead (the env-editor recreates FileBrowser for you). The user name is always `admin`, whatever `QBITTORRENT_USER` is.
* **Password rules:** 5 to 72 bytes, and not `admin`. Bytes, not letters: A-Z, digits and ASCII punctuation take 1 byte each, other characters 2 to 4. The env-editor refuses anything else before it saves, and also a `$` (see [Setup](#setup)); a password you put into `.env` by hand is not checked. What FileBrowser does with one it cannot use: `admin` (or an empty value) is ignored, so a new database gets a random password that FileBrowser prints once in its log, and an existing one keeps its old password. Fewer than 5 bytes are refused when FileBrowser sets the password on a later start, and it keeps the old one. More than 72 bytes do not fit its bcrypt hash: on a new database FileBrowser does not start, on an existing one it keeps the old password.
* **What it keeps:** its database, `configs/filebrowser/database.sqlite` (`FILEBROWSER_DATABASE_PATH=/config/database.sqlite`), holds its users, shares and settings. It survives restarts, image updates and recreated containers, and goes into your backup with the rest of `configs/`.
* **Its user:** the image always runs as uid 1000, whatever `PUID` is. `compose.yaml` adds it to the `PGID` group (`group_add`). With PUID/PGID 1000 nothing else is needed. With other IDs, FileBrowser gets in through the group: `configs/filebrowser` must be group-writable (`chmod 2775`), and it can only change downloads in folders its group may write to.
* **FileBrowser cannot rename or delete inside a download (PUID other than 1000).** qBittorrent creates its files and folders without group write (the LinuxServer image's default umask is 022). FileBrowser, which gets in through the group, can then rename what sits directly in a group-writable downloads folder and delete the files there, but cannot change or delete anything inside a folder qBittorrent created, so it cannot delete such a folder either. To make new downloads group-writable, add `UMASK: "002"` (the LinuxServer images' documented variable) to the `qbittorrent` service's `environment:` in `compose.yaml` and run `docker compose up -d qbittorrent`. Files that are already there need `sudo chmod -R g+w downloads` (your `DOWNLOADS_PATH`). git counts the edited `compose.yaml` as a local change: run `git stash` before a `git pull` and `git stash pop` after it.
* It shows only `DOWNLOADS_PATH` (as `/srv/downloads`), never `configs/` or `.env`, which hold secrets.

### Hosts booted with `ipv6.disable=1`

Some hosts switch IPv6 off on the kernel command line (`ipv6.disable=1` in `/proc/cmdline`). Then the kernel has no IPv6 settings at all, and Docker refuses to start Gluetun:

```text
error during container init: open sysctl net.ipv6.conf.all.disable_ipv6 file: ... no such file or directory
```

qBittorrent, Jackett and FlareSolverr wait for a healthy Gluetun, so they never start either; nothing leaks, but nothing works. Two ways out:

* **Turn IPv6 off with a sysctl instead of the boot option** (recommended). Remove `ipv6.disable=1` from the boot options, put `net.ipv6.conf.all.disable_ipv6 = 1` and `net.ipv6.conf.default.disable_ipv6 = 1` in `/etc/sysctl.d/90-no-ipv6.conf`, and reboot. The host still has no IPv6, and the stack starts unchanged.
* **Leave the sysctl out** when you can't change the boot options. A kernel booted with `ipv6.disable=1` cannot open IPv6 sockets at all, so nothing can leak over IPv6 anyway. Create `compose.override.yaml` next to `compose.yaml`:

  ```yaml
  services:
    gluetun:
      sysctls: !reset {}
  ```

  Docker Compose reads that file only when it is started without `-f`, as a plain `docker compose up -d` in the stack folder is. The env-editor runs `docker compose -f compose.yaml`, which ignores the override, so with this workaround start and restart the stack from the command line instead.

  The `!reset` tag needs a recent Docker Compose. Checked here: 2.20.1 and 5.6.1 honour it; 2.9.0 ignores it without any error, so the sysctl stays and Gluetun still fails. Check yours in the stack folder with `docker compose config | grep disable_ipv6`: it must print nothing.

The CasaOS installer checks for this itself and leaves the sysctl out on such kernels. The native install needs neither: it only sets the IPv6 sysctl when the kernel has IPv6.

(Checked on a Docker 29.9 / Compose 5.6 host booted with `ipv6.disable=1`, with a small stand-in for Gluetun and one app on its network: the error above, the override letting both start, and `-f compose.yaml` ignoring the override. The real Gluetun image and the boot-option change could not be tried there.)

## License

Released under the [MIT License](LICENSE). Copyright © 2025 Rob Paprocki.
