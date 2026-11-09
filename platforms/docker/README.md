# Docker Compose on any Linux host

This guide sets the stack up with plain Docker Compose. You clone this repository, and a small web form, the env-editor, writes `.env`, seeds the apps' first logins and starts the containers. It is the way to go on the Docker VM that the companion repo [docker-pve](https://github.com/rob-paprocki/docker-pve) creates, which also installs [Dockhand](https://dockhand.pro) to manage and update the stacks in `/opt/stacks/` (with Dockge as an option). It works on any other Linux host with Docker too.

On Proxmox VE, Incus, TrueNAS, Unraid, Synology DSM and CasaOS/ZimaOS, a one-line installer does all of this for you: see [Choose your platform](../../README.md#choose-your-platform) in the main README.

## Before you start

* A Linux host, amd64 or arm64. 32-bit ARM cannot run all the images.
* Docker Engine 20.10+ with the Docker Compose plugin.
* `git`, to clone the repository and to update it later.
* A root shell (`sudo -i` if you log in as another user). The commands below create `/opt/stacks` and change folder owners, and the env-editor runs `docker compose` when you press **Apply**, which needs root or the `docker` group.
* `/dev/net/tun` available on the host (loaded automatically on most Linux kernels).
* `NET_ADMIN` capability (granted via `cap_add` in the compose file).
* For the setup editor: Python 3.9+ with the `venv` module. On Debian/Ubuntu that means `python3` plus `python3-venv`; Debian 13 cloud images, including VMs from older docker-pve versions, ship without `python3-venv` (`sudo apt-get install -y python3-venv`).
* A VPN provider that supports port forwarding through Gluetun. The port-update flow depends on it; see [Prerequisites](../../README.md#prerequisites) in the main README for the providers that work.

## Setup

As root:

```bash
# Pick a stacks dir (the paired docker-pve VM
# uses /opt/stacks/).
mkdir -p /opt/stacks && cd /opt/stacks

# Clone into a folder named after the compose
# project (`name: torrent-stack`) and move in.
# Dockge needs the names to match; see
# "If you also run Dockge".
git clone https://github.com/rob-paprocki/qbittorrent-vpn-docker.git torrent-stack
cd torrent-stack

# Prep host-side state dirs so the containers
# can write them as PUID/PGID (1000 by default).
# configs/filebrowser must exist before the
# first start: Docker would create it as root,
# and FileBrowser could not write its database.
mkdir -p configs/filebrowser downloads/incomplete
chown -R 1000:1000 configs downloads

# Launch the setup editor. The first run creates
# a Python venv (~10 MB), generates an admin
# password and prints it once, then serves the
# form on :9191.
./scripts/setup.sh
```

The editor keeps only a bcrypt hash of its password, in `configs/env-editor/credentials.json`, so note the password when it is printed. If you lose it, see [Lost the env-editor login](#lost-the-env-editor-login).

Open `http://<host>:9191` in a browser (`<host>` is the machine's address) and log in as `admin` with the printed password. Fill in the VPN details, a qBittorrent username and password, and the ports, then press **Preview changes** and **Apply**. The editor writes `.env`, stops qBittorrent and seeds `qBittorrent.conf` (PBKDF2 password, and the Jackett search plugin pointed at `127.0.0.1:9117`, where Jackett listens inside the stack), generates a Jackett API key, creates `<CONFIG_PATH>/filebrowser` if it is missing (mode 2775, group `PGID`, and owner `PUID` when the editor runs as root, so a `CONFIG_PATH` other than `./configs` works too), and brings the stack up.

FileBrowser needs no seeding: `compose.yaml` hands it `QBITTORRENT_PASSWORD`, so its login is user **`admin`** with the qBittorrent password (see [FileBrowser](#filebrowser) below). That is why the editor checks the qBittorrent login on **Preview changes** and again on **Apply**, before it saves anything: it refuses an empty user or password, the `.env.example` placeholders (anyone can look them up), a password FileBrowser cannot use (it must be 5 to 72 bytes and not `admin`), and a password with `$` (see below). When it refuses one, it shows **Not saved** with the reason above the form, which still holds what you entered, and changes nothing.

The editor runs in the foreground: it stops when you press Ctrl+C or close the terminal or SSH session. To change `.env` later, start it again with `./scripts/setup.sh`; the URL and login stay the same. When you save, it works out what changed and recycles only the services that depend on those variables.

> [!WARNING]
> The env-editor serves plain HTTP on every interface (`0.0.0.0:9191`), behind a basic-auth login, and the form holds your VPN key and passwords. Stop it when you're done, or keep it on the host itself with `ENV_EDITOR_BIND=127.0.0.1:9191 ./scripts/setup.sh` and reach it through an SSH tunnel (`ssh -L 9191:127.0.0.1:9191 <user>@<host>`, then open `http://localhost:9191`). The web UIs of qBittorrent, Jackett, FlareSolverr and FileBrowser are published on every interface too: if the host is reachable from networks you don't trust, firewall those ports or put a reverse proxy in front.

Keep `$` out of `.env` while you use the editor. Each **Apply** writes every value in `.env` again, the ones you did not touch included, and puts a value with `$` in double quotes, where Docker Compose reads `$name` as a variable. So the editor refuses a qBittorrent password with `$`, even one that is already in `.env` (the Unraid and Synology installers write such a password in single quotes, which Compose takes literally): the containers would get a shorter password than the one qBittorrent has. Other values with `$`, such as an OpenVPN password, are not refused, and after the next **Apply** the containers get them cut short. Quotes and backslashes are fine.

### Lost the env-editor login

Delete `configs/env-editor/credentials.json` (in the repository folder, whatever `CONFIG_PATH` is) and start the editor again with `./scripts/setup.sh`. It makes a new password and prints it once. `ENV_EDITOR_USER=<name>` on that run picks a user name other than `admin`.

### Add indexers

With the stack up, the editor's **Indexers** tab lists everything in Jackett's catalog. Click **configure** on an indexer, fill in the credentials Jackett asks for, and save. Public trackers need none; private trackers ask for a passkey, a cookie or similar. Jackett's own UI at `http://<host>:${JACKETT_PORT}` still works if you prefer it.

### Deploy on the paired docker-pve VM (Dockhand)

If the host is the Docker VM produced by [docker-pve](https://github.com/rob-paprocki/docker-pve), clone into `/opt/stacks/torrent-stack` as above, then in Dockhand (`http://<host>:3000`) open **Stacks → Adopt** and select `torrent-stack`. Dockhand edits `compose.yaml` and `.env` where they are, so it and the env-editor always work on the same files.

* **`.env` changes:** use the env-editor. It handles the config seeding and only recycles the services a change affects. Deploying from Dockhand runs the same `docker compose` with a compatible Compose version, so it leaves unchanged containers alone.
* **Image updates:** Dockhand's nightly update covers this stack, so leave this stack's own Watchtower off (see **Image updates** under [Operational notes](#operational-notes)). When Dockhand updates `gluetun`, it recreates qBittorrent, Jackett and FlareSolverr onto the new network namespace itself. The next env-editor or `docker compose up` run recreates those dependents once more to settle Compose's view of them; `gluetun` and the VPN connection are not touched.

#### If you also run Dockge

Dockge (at `http://<host>:5001`, when installed) lists the stack as `torrent-stack` if you cloned into `/opt/stacks/torrent-stack` as above. The folder name matters: Dockge names stacks after their folder, while Docker names the project from `name: torrent-stack` in `compose.yaml`. Cloned into the default `qbittorrent-vpn-docker/` folder, the stack shows up twice in Dockge: an inactive `qbittorrent-vpn-docker` entry you can edit, and an active `torrent-stack` entry marked "This stack is not managed by Dockge".

Use Dockge for log tailing and for reading or editing files. Use the env-editor (or `docker compose` on the host) for `.env` changes and restarts. Avoid Dockge's **Start**, **Update** and **Deploy** buttons for this stack. Dockge 1.5.0 runs its own bundled Docker Compose (v2.34.0), which computes different config hashes from the host's newer Compose plugin, so each of those buttons recreates every container (which here means a VPN reconnect and a qBittorrent restart), and the host's Compose recreates them again the next time it touches them.

### Moving an existing clone to the `torrent-stack` folder

If you cloned into the default `qbittorrent-vpn-docker/` folder, stop the env-editor (Ctrl+C) and move the checkout. Relative paths (`./configs`, `./downloads`) move with it.

```bash
cd /opt/stacks/qbittorrent-vpn-docker
docker compose down
cd /opt/stacks
mv qbittorrent-vpn-docker torrent-stack
cd torrent-stack
docker compose up -d
# restart the env-editor from the new folder
./scripts/setup.sh
```

## Updating

Images and the repository update separately. For the images, see **Image updates** under [Operational notes](#operational-notes). To update them by hand, with neither Dockhand nor Watchtower running, run `docker compose pull` and then `docker compose up -d` in the stack folder. To update the repository (`compose.yaml`, the scripts and the env-editor):

1. Stop the env-editor (Ctrl+C) and run `git pull` in the stack folder. If it stops, see the notes below.
2. Read the new entries in [CHANGELOG.md](../../CHANGELOG.md). An entry marked **BREAKING:** says what to change before you go on. For example, an install from before 2.0.0 must take the old Compose project down under its old name first, and one from before 3.0.0 must decide whether to keep its Watchtower: its container keeps running after the update, because `docker compose up` (even with `--remove-orphans`) leaves a profile-disabled service's container alone.
3. Run `docker compose up -d`. It recreates the containers whose settings changed.
4. Start the editor again with `./scripts/setup.sh`.

> [!IMPORTANT]
> With the default `CONFIG_PATH=./configs`, two of the apps' live settings files are files git tracks: `configs/qbittorrent/qBittorrent/qBittorrent.conf` and `configs/jackett/Jackett/ServerConfig.json`. If an update changes either one in the repository, `git pull` stops with "Your local changes to the following files would be overwritten by merge". Copy the file it names somewhere safe, run `git checkout -- <file>` and `git pull`, then copy your file back ([Known follow-ups, item 4](../DESIGN.md#known-follow-ups)).

The update that made FileBrowser's login `admin` with `QBITTORRENT_PASSWORD`, and gave Jackett and FlareSolverr fixed ports inside the stack, has **BREAKING** entries in the changelog. What they don't spell out:

* Before you run `docker compose up -d`, check `QBITTORRENT_USER` and `QBITTORRENT_PASSWORD` in `.env`. If either is still the `.env.example` placeholder (`your_qbit_username`, `your_qbit_password`; the editor used to save those without a word), or the password is `admin`, under 5 or over 72 bytes, or has a `$`, choose a new login first: in the editor (`./scripts/setup.sh`, then **Preview changes** and **Apply**), or by hand in `.env` and in qBittorrent's **Tools → Options → Web UI**.
* On its first start after the update, FileBrowser creates `configs/filebrowser/database.sqlite` with one user, `admin`, whose password is `QBITTORRENT_PASSWORD`; its log says `Using admin password from FILEBROWSER_ADMIN_PASSWORD environment variable`.
* If you had made a non-default `JACKETT_PORT` work by changing Jackett's own `"Port"` in `configs/jackett/Jackett/ServerConfig.json`, set that back to 9117.
* `update-qbittorrent.sh` and `scripts/setup.sh` became executable in git. If you made either file executable yourself (`chmod +x`, which both needed until then), git counts that as a local change, and the pull stops with "Your local changes to the following files would be overwritten by merge". Undo it first, then pull:

  ```bash
  git checkout -- update-qbittorrent.sh scripts/setup.sh
  git pull
  ```

  A copy made without git needs `chmod 755 update-qbittorrent.sh scripts/setup.sh`.

## Uninstalling

Stop the env-editor (Ctrl+C), then remove the containers, including Watchtower's if it ran:

```bash
cd /opt/stacks/torrent-stack
docker compose --profile watchtower down
```

Then delete the stack folder. It holds `.env`, `configs/` and, with the default paths, your downloads, so move those out first if you want to keep them.

## Doing it manually (without the editor)

You can skip the editor and set everything up by hand. The stack doesn't need the editor to run; the editor only saves you these steps.

* **`.env`**: `cp .env.example .env`, edit in `$EDITOR`. Set `QBITTORRENT_PASSWORD` to the password you will give qBittorrent **before the first `docker compose up`**: FileBrowser takes it as its admin password at every start, and `your_qbit_password` from `.env.example` is public. Nothing checks it on this path, so keep to FileBrowser's rules yourself: 5 to 72 bytes, not `admin` (see [FileBrowser](#filebrowser)).
* **Folders**: `mkdir -p configs/filebrowser downloads/incomplete` (with another `CONFIG_PATH` or `DOWNLOADS_PATH`, the same folders there) and give them to PUID/PGID, as in [Setup](#setup).
* **FileBrowser**: user `admin`, password `QBITTORRENT_PASSWORD` from `.env`. Nothing to look up in a log (see [FileBrowser](#filebrowser)).
* **qBittorrent**: the LinuxServer image prints a temporary admin password on first start (`docker compose logs qbittorrent | grep -i -A1 'temporary.*password'`). Log in with it (user `admin`), and in **Tools → Options → Web UI** set the user name and password to `QBITTORRENT_USER` and `QBITTORRENT_PASSWORD` from `.env`. The port-update script logs in with those. If you change the password in `.env` later, run `docker compose up -d gluetun qbittorrent jackett flaresolverr filebrowser` so Gluetun and FileBrowser get it.
* **Jackett search plugin**: enable **Tools → Options → Search → "Enable search engine"** in qBittorrent, install the plugin via **Search → Search Plugins → Install new** with `https://raw.githubusercontent.com/qbittorrent/search-plugins/<commit>/nova3/engines/jackett.py`, where `<commit>` is `QBIT_SEARCH_PLUGINS_COMMIT` from [`native/versions.env`](../../native/versions.env) (the version the installers use and check). Then edit `./configs/qbittorrent/qBittorrent/nova3/engines/jackett.json`: paste your Jackett API key into `api_key` and leave `url` at `http://127.0.0.1:9117`. qBittorrent reaches Jackett inside the stack, so that is always port 9117, whatever `JACKETT_PORT` is.
* **Jackett indexers**: add them in Jackett's own UI at `http://<host>:${JACKETT_PORT}`.

The `FILEBROWSER_PORT` compose binding is `0.0.0.0:${FILEBROWSER_PORT}` by default. If the host is reachable from untrusted networks, firewall it off, use a reverse proxy, or set it to a loopback-only bind.

## Operational notes

* **Image tags.** Every image in `compose.yaml` is on a rolling tag (`:latest`, or `:stable` for FileBrowser), pulled nightly by Dockhand on the docker-pve VM or by this stack's optional Watchtower (the platform installers say which updater they use; the native install pins every version instead). Pin a specific version in `compose.yaml` if reproducibility matters more than auto-update; [UPSTREAMS.md](../../UPSTREAMS.md) has the per-image rollback recipe. The Gluetun image is the one worth watching: provider env-variable renames have shipped as minor bumps there.
* **Image updates.** On the docker-pve VM, Dockhand's nightly update covers this stack: it blocks an update whose image has more known vulnerabilities than the running one, and reconnects the containers that share gluetun's network. On a host with no other updater, turn on this stack's own Watchtower: env-editor **Watchtower → Run Watchtower: on**, or `COMPOSE_PROFILES=watchtower` in `.env`. It runs `ghcr.io/nicholas-fedor/watchtower:latest`, the active community fork of `containrrr/watchtower` (archived 2025-12-17 at `v1.7.1`), and only touches this stack's containers (`scope=torrent-stack`).
* **Restart gluetun with its dependents, never alone.** qBittorrent, Jackett and FlareSolverr share gluetun's network namespace. Restarting only the `gluetun` container (a per-container Restart button in a Docker UI, or `docker restart`) leaves them with no network until they are recreated too. The env-editor already recycles them together; from the CLI, `docker compose up -d --force-recreate gluetun qbittorrent jackett flaresolverr`.
* **IPv6.** Disabled via a Docker sysctl on the gluetun service (`net.ipv6.conf.all.disable_ipv6=1`), which propagates to every container on `network_mode: service:gluetun`. The host's IPv6 is untouched. On a host booted with `ipv6.disable=1` that sysctl cannot be set; see [Hosts booted with ipv6.disable=1](#hosts-booted-with-ipv6disable1).
* **`update-qbittorrent.sh` must stay executable.** Gluetun runs it as `/gluetun/update-qbittorrent.sh` with no shell in between, and the read-only mount keeps the file's mode from the host. Without the executable bit Gluetun cannot run it, and qBittorrent's listen port is never updated. git keeps the bit (the file is mode 755 in the repository). A copy made another way, for example through an SMB share or from Windows, can lose it: `chmod 755 update-qbittorrent.sh`, then `docker compose up -d --force-recreate gluetun qbittorrent jackett flaresolverr`. The native install runs it through `/bin/sh`, so there the bit does not matter.

### Ports inside and outside the stack

qBittorrent, Jackett and FlareSolverr share Gluetun's network, so their ports are published on the `gluetun` service. Each `.env` key below is the port on the host, then what `compose.yaml` publishes:

* **`QBIT_WEBUI_PORT`**, published as `QBIT_WEBUI_PORT:QBIT_WEBUI_PORT`. qBittorrent listens on `QBIT_WEBUI_PORT` itself. Its web UI rejects a request whose `Host` header names another port, so both sides must be the same number.
* **`JACKETT_PORT`**, published as `JACKETT_PORT:9117`. Jackett always listens on 9117.
* **`FLARESOLVERR_PORT`**, published as `FLARESOLVERR_PORT:8191`. FlareSolverr always listens on 8191.
* **`FILEBROWSER_PORT`**, published as `FILEBROWSER_PORT:80` on FileBrowser's own container, which has its own network.

So `JACKETT_PORT` and `FLARESOLVERR_PORT` only choose the port on the host, for your browser and other machines. Inside the stack the apps always talk to `127.0.0.1:9117` (qBittorrent's search plugin) and `127.0.0.1:8191` (Jackett's FlareSolverr URL). `QBIT_WEBUI_PORT` must not be 9117, 8191, 8000 or 9999, which Jackett, FlareSolverr and Gluetun's control and health servers already use inside that shared network. In native mode the apps listen on the `.env` ports themselves (see [native/README.md](../../native/README.md)).

### FileBrowser

* **Login:** user **`admin`**, password `QBITTORRENT_PASSWORD` from `.env`. `compose.yaml` passes it as `FILEBROWSER_ADMIN_PASSWORD`, and FileBrowser sets the `admin` user's password from it **every time it starts**. A password you change for `admin` inside FileBrowser lasts only until the next restart; change `QBITTORRENT_PASSWORD` instead (the env-editor recreates FileBrowser for you). The user name is always `admin`, whatever `QBITTORRENT_USER` is.
* **Password rules:** 5 to 72 bytes, and not `admin`. Bytes, not letters: A-Z, digits and ASCII punctuation take 1 byte each, other characters 2 to 4. The env-editor refuses anything else before it saves, and also a `$` (see [Setup](#setup)); a password you put into `.env` by hand is not checked. What FileBrowser does with one it cannot use: `admin` (or an empty value) is ignored, so a new database gets a random password that FileBrowser prints once in its log (`docker compose logs filebrowser`), and an existing one keeps its old password. Fewer than 5 bytes are refused when FileBrowser sets the password on a later start, and it keeps the old one. More than 72 bytes do not fit its bcrypt hash: on a new database FileBrowser does not start, on an existing one it keeps the old password.
* **What it keeps:** its database, `configs/filebrowser/database.sqlite` (`FILEBROWSER_DATABASE_PATH=/config/database.sqlite`), holds its users, shares and settings. It survives restarts, image updates and recreated containers, and goes into your backup with the rest of `configs/`.
* **Its user:** the image always runs as uid 1000, whatever `PUID` is. `compose.yaml` adds it to the `PGID` group (`group_add`). With PUID/PGID 1000 nothing else is needed. With other IDs, FileBrowser gets in through the group: `configs/filebrowser` must be group-writable (`chmod 2775`), and it can only change downloads in folders its group may write to.
* **If FileBrowser keeps restarting and its log says `unable to open database file`,** `configs/filebrowser` is not writable for it: FileBrowser always runs as uid 1000, and a folder Docker created belongs to root. Fix it with `sudo chown 1000:1000 configs/filebrowser` when PUID/PGID are 1000; with other IDs, `sudo chown PUID:PGID configs/filebrowser && sudo chmod 2775 configs/filebrowser`. Then `docker compose up -d filebrowser`.
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
