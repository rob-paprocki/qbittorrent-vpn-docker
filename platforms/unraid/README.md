# Unraid installer

Installs this repository's Docker Compose stack (Gluetun VPN, qBittorrent, Jackett, FlareSolverr, FileBrowser) on an Unraid server, as a stack managed by the **Compose Manager Plus** plugin. You answer a few questions in the Unraid terminal. The stack then appears under **Docker > Compose**, where you can start, stop, update, read logs, edit `.env` and set autostart, like any other Compose Manager stack.

As everywhere in this repo: qBittorrent, Jackett and FlareSolverr have no network of their own. They share Gluetun's network namespace (`network_mode: service:gluetun` in `compose.yaml`), so they can reach the internet only through the VPN. If Gluetun stops, they have no network at all.

## Before you start

1. **Unraid 7.x.** Tested against a fake Unraid 7.2 (see [What was tested](#what-was-tested)). Unraid 6.12 should also work (Compose Manager Plus installs on 6.12.0 and later, though its author has tested it on 7.2.3 and later) but is untested here. Older versions are refused.
2. **The array is started**, and **Docker is enabled** (*Settings > Docker > Enable Docker: Yes*).
3. **Compose Manager Plus** is installed (*Apps* tab, search "Compose Manager Plus", *Install*). It also installs `docker compose`. No *Apps* tab? Install [Community Applications](https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/community-applications/) first.
   * Have the **original "Docker Compose Manager"** (by dcflachs)? It is deprecated. Install Compose Manager Plus over it from the *Apps* tab; it replaces the old plugin and keeps your existing stacks. The installer checks this and tells you. The reason: the old plugin would run this stack as `torrent_stack` instead of `torrent-stack`, which splits it from the files in this repo.
   * Compose Manager Plus must be **2026.09.03 or newer** (the release that pins each stack's project name). Update it on the *Plugins* tab if the installer says it is too old.
4. **A share for downloads**, for example `downloads`, created on the *Shares* tab. The installer does not create shares: making a folder directly under `/mnt/user` would create a share with default settings behind your back. The downloads folder must be outside the stack folder (`<appdata>/torrent-stack`), because FileBrowser shows everything in it.
5. **Compose Manager's Projects Folder** (*Settings > Compose*) is not your appdata share. The default (`/boot/config/plugins/compose.manager/projects`) is fine. If it were `/mnt/user/appdata`, Compose Manager's entry for this stack would be the stack folder itself, and *Delete Stack* would delete your `.env` and settings. The installer checks this and stops.
6. **A VPN account with port forwarding**: ProtonVPN, Private Internet Access, Perfect Privacy or PrivateVPN (see the main README). You can also add the keys later.

## Install

Open the terminal (the `>_` icon at the top right of the Unraid web UI) and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/unraid/install.sh)"
```

It asks, with a default you can accept with Enter:

| Question | Default | Notes |
|---|---|---|
| Appdata share | `/mnt/user/appdata` | The stack goes in `<appdata>/torrent-stack`. |
| Downloads folder | `/mnt/user/downloads` | `incomplete/` is created inside it. |
| Time zone | from *Settings > Date and Time* | |
| VPN provider, protocol | `protonvpn`, `wireguard` | Gluetun's provider names. |
| WireGuard private key and address, or OpenVPN user and password | empty | Typed keys are not shown. Leave them empty to add them later; the stack will not start until they are set. |
| VPN exit countries | `United States` | |
| qBittorrent username and password | `admin`, generated | The password is also FileBrowser's (its user is always `admin`, see [Day to day](#day-to-day)). 8 characters or more, and at most 72 bytes, the most FileBrowser can store. A generated password is printed once and is in `.env`. |

The ports are not asked. They are the `.env.example` defaults (qBittorrent 8090, Jackett 9117, FlareSolverr 8191, FileBrowser 8081); set `TS_QBIT_WEBUI_PORT`, `TS_JACKETT_PORT`, `TS_FLARESOLVERR_PORT` or `TS_FILEBROWSER_PORT` for others, or change them later in `.env`.

Then it shows a summary and asks before changing anything. Re-running it is safe: your current values become the defaults, and nothing is duplicated.

Want to see first what it would do? Add `--dry-run`. It changes nothing and prints every file and command, with secrets hidden:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/unraid/install.sh)" install.sh --dry-run
```

(`install.sh` there is only the name bash gives the script; the options follow it.)

## What it creates

| Where | What |
|---|---|
| `/mnt/user/appdata/torrent-stack/` | A copy of this repository: `compose.yaml`, `update-qbittorrent.sh`, `scripts/` and so on. A git clone when Unraid has git (6.12 and 7.x do), otherwise a download from GitHub. |
| `.../torrent-stack/.env` | Your settings (mode 600, root only): absolute paths, `PUID=99` / `PGID=100` (Unraid's `nobody:users`), your time zone, VPN, qBittorrent login. `COMPOSE_PROFILES` is empty, so the stack's own Watchtower stays off. |
| `.../torrent-stack/appdata/` | The apps' settings (`CONFIG_PATH`): `gluetun/`, `qbittorrent/`, `jackett/`, `flaresolverr/`, `filebrowser/`, owned by 99:100 (Gluetun's stays root's). `filebrowser/` holds FileBrowser's database (`database.sqlite`); it is also writable for group 100 and has the setgid bit (mode 2775), because FileBrowser runs as uid 1000 and gets in through group 100. This is what you back up. |
| `.../torrent-stack/configs/` | Only in a git clone: part of the repository, the starting templates for qBittorrent and Jackett that the first install copies into `appdata/`. The apps never use this folder. It is kept apart from `appdata/` so that `git pull` (in `--update`) never trips over files the apps rewrite. |
| `<downloads>/` and `<downloads>/incomplete/` | Created if missing. Only these two folders are changed, never their contents: owner 99:100, plus group write and setgid (`chmod ug+rwx` and `chmod g+s`, which only add permissions, so a share that is open to everyone stays open), so that FileBrowser can work in them. |
| `/boot/config/plugins/compose.manager/projects/torrent-stack/` | The Compose Manager entry. It holds only metadata (`name`, `project_name`, `indirect`, `indirect_mode`, `description`, `webui_url`, `autostart`), the same files Compose Manager Plus writes when you add an *indirect* stack in its UI. |

Before the first start, the installer **seeds** the app configs with the repo's seeding CLI (`scripts/env-editor/seed_configs.py`): the qBittorrent password hash and the Jackett search plugin, and a Jackett API key. The search plugin is pointed at `127.0.0.1:9117`: qBittorrent and Jackett share Gluetun's network, and Jackett always listens on 9117 there, whatever `JACKETT_PORT` is. Unraid has no Python, so this runs in a throwaway `python:3.14.9-slim-trixie` container, pinned by digest. Nothing is installed in it; it needs internet access once, to download the Jackett search plugin from GitHub. The stack folder is mounted read-only and only `appdata/` is writable; the CLI reads `.env`, then switches to 99:100 before it writes anything. Your secrets stay in `.env`; nothing is passed on a command line.

FileBrowser is **not** seeded and needs nothing from the installer except folders it can write to: `compose.yaml` gives its `admin` user the qBittorrent password and keeps its database in `appdata/filebrowser` (see [Day to day](#day-to-day)).

Then it **starts the stack exactly as Compose Manager does**. It asks the plugin's own `compose_args.php` for the stack's arguments and runs the plugin's `compose.sh` wrapper, so the Compose page shows the same state as for a stack you started there. Autostart is switched on, so the stack comes up whenever the array starts.

### Why the files are in appdata and not on the flash drive

Compose Manager can keep a stack's compose file and `.env` in its projects folder on the flash drive. This installer keeps them in appdata instead and points the plugin there (an "indirect" stack). The reasons:

* The flash drive is FAT32: files there [cannot be executable](https://docs.unraid.net/unraid-os/system-administration/secure-your-server/secure-your-flash-drive/), and Gluetun runs `update-qbittorrent.sh` directly.
* FAT32 has no file permissions, so `.env` (VPN keys, passwords) would be readable by anything that can read the flash drive.
* A repository checkout in appdata can be updated with `git pull`, and the optional env-editor works there.

Compose Manager's **Edit Stack > ENV** tab still edits that same `.env`.

## Day to day

* **Start, stop, logs, autostart:** *Docker > Compose > torrent-stack*. Use **Compose Up/Down** on the whole stack rather than restarting single containers. qBittorrent, Jackett and FlareSolverr share Gluetun's network: restarting Gluetun alone leaves them offline until they are recreated with it.
* **Web UIs:** qBittorrent `http://<unraid-ip>:8090`, Jackett `:9117`, FileBrowser `:8081` (or the ports in `.env`).
  * qBittorrent: the username and password from `.env` (`QBITTORRENT_USER`, `QBITTORRENT_PASSWORD`).
  * FileBrowser: user **`admin`** (always, whatever `QBITTORRENT_USER` is) with the **qBittorrent password**. `compose.yaml` passes that password to FileBrowser (`FILEBROWSER_ADMIN_PASSWORD`), and FileBrowser sets it on the `admin` user **every time it starts**. So change it in `.env` (*Edit Stack > ENV*, then `--apply`), not in FileBrowser: a password changed in FileBrowser's own settings only lasts until its next start.
* **What FileBrowser keeps:** its database, `appdata/filebrowser/database.sqlite`, holds its users, settings and shares. It survives container recreates (*Update Stack*, *Compose Up* after a change, `--update`) and is part of your appdata backup. (Test installs made from the `feat/multi-platform-installers` branch before commit 0111892 kept FileBrowser's database inside its container. After an update, FileBrowser starts with a new, empty database, user `admin` with the qBittorrent password, and keeps it from then on.)
* **Change a setting** (VPN keys, ports, password, paths): *Edit Stack > ENV*, save, then in the terminal:

  ```bash
  bash /mnt/user/appdata/torrent-stack/platforms/unraid/install.sh --apply
  ```

  `--apply` checks `.env` with `docker compose config`, refuses placeholder VPN keys, a password FileBrowser cannot store, ports that clash and a downloads folder inside the stack folder, fixes the folder permissions, stops qBittorrent, re-seeds the qBittorrent and Jackett configs (so a new password reaches qBittorrent), and starts the stack through Compose Manager, which recreates FileBrowser with the new password too. qBittorrent is stopped first because it writes its settings back when it stops, which would undo a new password. If seeding fails, qBittorrent is started again as it was. For changes that need no re-seeding (ports, VPN country), **Compose Up** in the UI is enough: Compose recreates only the containers whose settings changed.
* **Comments in `.env`:** `KEY=value # note` works (a space before the `#`), as in Docker Compose. The installer reads such lines the same way.
* **Image updates:** use Compose Manager. **Update Stack** pulls new images and recreates the containers; its update checks and scheduled updates are in *Settings > Compose*. The stack's own Watchtower stays off (`COMPOSE_PROFILES=` empty). Compose Manager already does the job and recreates the containers that share Gluetun's network along with it.
* **Optional env-editor** (the repo's web form for `.env`, with the Jackett indexer tab): it needs Python 3, which Unraid does not ship. With the community "Python 3 for UNRAID" plugin installed, run `bash /mnt/user/appdata/torrent-stack/scripts/setup.sh` and open `http://<unraid-ip>:9191`. It stays up only while that terminal runs. It uses the same `compose.yaml`, `.env` and project name as Compose Manager, so the two do not fight over the containers. The exception: if you add labels in Compose Manager's **Web UI** tab, it starts using an override file that the env-editor does not read. Then the env-editor's *Apply* recreates the containers without those labels, and the next Compose Up recreates them with the labels again. Pick one or the other.

## Update the installer's files

```bash
bash /mnt/user/appdata/torrent-stack/platforms/unraid/install.sh --update
```

This runs `git pull` in the stack folder (or downloads the repository again if it was not a git clone). It then checks `compose.yaml` against your `.env`, sets the folder owners and permissions the new `compose.yaml` needs (see [What it creates](#what-it-creates); an older install's `appdata/filebrowser` was writable for its owner only, and the new FileBrowser container would not start there), and runs Compose Manager's **Update Stack** (pull images, recreate containers). What is in your `.env` and in the `appdata/` files is not changed; only owners and permissions are, as described above.

**Only for test installs made from the `feat/multi-platform-installers` branch before commit 0111892** (the `main` branch had no Unraid installer before this one, so a normal install is never in this state): the `--update` you run is still the *old* installer, which pulls the new `compose.yaml` but does not know about the new folder permissions, so FileBrowser keeps restarting afterwards (its log says `unable to open database file`). Run the new installer once more to fix that:

```bash
bash /mnt/user/appdata/torrent-stack/platforms/unraid/install.sh --apply
```

The apps' settings live in `appdata/`, which git ignores, so `git pull` only refuses when a repository file was changed in the stack folder, for example `compose.yaml` edited in Compose Manager's editor. The installer then stops and says how to see and undo that change (`git -C /mnt/user/appdata/torrent-stack status` and `diff`; `checkout -- FILE` puts a file back).

## Uninstall

```bash
bash /mnt/user/appdata/torrent-stack/platforms/unraid/install.sh --uninstall
```

This runs Compose Manager's **Compose Down** (stops and removes the containers) and removes the Compose Manager entry. It keeps `/mnt/user/appdata/torrent-stack` (`.env`, `appdata/`) and your downloads.

Add `--purge` to also delete `/mnt/user/appdata/torrent-stack`. Downloads are never deleted: if `DOWNLOADS_PATH` or `INCOMPLETE_DOWNLOADS` in `.env` points inside the stack folder (or holds it), `--purge` stops before changing anything and tells you to move the downloads first.

The Compose Manager entry is removed the way Compose Manager's own *Delete Stack* removes it, but only when it holds nothing but Compose Manager's metadata. If the entry is the stack folder itself, only the metadata files are removed; an entry with its own compose file or `.env` is left alone.

## Options and variables

`install.sh --help` lists them all. The ones you are most likely to need:

| | |
|---|---|
| `--dry-run` | Print, change nothing. |
| `--unattended` / `-y` | No questions. Answers come from `TS_*` variables, the existing `.env`, or the defaults. |
| `TS_APPDATA`, `TS_DOWNLOADS`, `TS_TZ`, `TS_PUID`, `TS_PGID` | Folders and ids. |
| `TS_VPN_PROVIDER`, `TS_VPN_TYPE`, `TS_WIREGUARD_ADDRESSES`, `TS_OPENVPN_USER`, `TS_SERVER_COUNTRIES`, `TS_QBITTORRENT_USER` | Settings. |
| `TS_QBIT_WEBUI_PORT`, `TS_JACKETT_PORT`, `TS_FLARESOLVERR_PORT`, `TS_FILEBROWSER_PORT` | Ports on the Unraid server (defaults 8090, 9117, 8191, 8081). They must all differ; see [Limitations](#limitations-and-notes) for the few qBittorrent cannot use. |
| `TS_WIREGUARD_PRIVATE_KEY_FILE`, `TS_OPENVPN_PASSWORD_FILE`, `TS_QBITTORRENT_PASSWORD_FILE`, `TS_SCRIPT_NOTIFY_URL_FILE` | Secrets, read from the first line of a file (`chmod 600` it). The qBittorrent password is also FileBrowser's. The last one is the Discord webhook for port-forward messages; without it there is none (the `.env.example` placeholder becomes empty). Secrets are never taken from the command line, where they would end up in your shell history. |
| `TS_SOURCE_DIR=/path` | Use a local checkout instead of downloading (how it is tested). |
| `TS_REF=main`, `TS_REPO_URL` | Branch or tag, or a fork. |
| `TS_FORCE=1` | Take over an existing Compose Manager stack called `torrent-stack` that points somewhere else. |

## Limitations and notes

* **One stack per server**, named `torrent-stack`. The installer refuses if a Compose Manager stack with that name already exists elsewhere, if another stack already uses the folder, or if `torrent-stack` containers already run from a different compose file (for example a manual install). Stop or remove that one first.
* **Folder rules.** The appdata and downloads paths must be a share, or a folder in one (`/mnt/user/<share>[/...]`, or the same on a pool or disk); `/mnt/user` or `/mnt/cache` alone is refused. The share must already exist. No spaces, colons, quotes, `$`, backslashes or backticks in the path. The downloads folder must not be the stack folder, be inside it, or hold it (so not the whole appdata share). `/mnt/user/...` and `/mnt/<pool>/...` count as the same folder for these checks.
* **`/dev/net/tun`**: Gluetun needs it. If it is missing, the installer runs `modprobe tun`. If you see that warning, add `modprobe tun` to `/boot/config/go` so it is there after a reboot.
* **appdata on the array vs a pool:** `/mnt/user/appdata` works. If appdata is an [exclusive share](https://docs.unraid.net/unraid-os/release-notes/6.12.0/) (6.12+) or you use `/mnt/cache/appdata`, the apps skip Unraid's FUSE layer and run faster.
* **Incomplete downloads** live in `<downloads>/incomplete`, mounted separately into qBittorrent (as in `compose.yaml`). Finished files are copied across rather than moved instantly.
* **FileBrowser (FileBrowser Quantum 2.x, `ghcr.io/gtsteffaniak/filebrowser:stable`):**
  * Its login is always `admin` plus the qBittorrent password, set again from `.env` at every start (see [Day to day](#day-to-day)). The password must be 8 characters or more (FileBrowser itself wants 5) and at most 72 bytes: FileBrowser stores it as a bcrypt hash, and bcrypt refuses longer passwords. The installer and `--apply` check this. Letters outside plain ASCII take 2 to 4 bytes each.
  * The image always runs as uid 1000, whatever `PUID` is; `compose.yaml` adds it to group 100 (`users`, Unraid's `PGID`). That is why the installer gives `appdata/filebrowser` and the two download folders group write and setgid. In those folders FileBrowser can upload, rename and delete. Files it uploads belong to uid 1000 and group `users`.
  * Inside the folders **qBittorrent** creates (one per torrent, usually), FileBrowser can browse and download but not change anything. qBittorrent makes them `rwxr-xr-x` (umask 022, the usual default in containers; `compose.yaml` sets no `UMASK` for the LinuxServer image), so group 100 cannot write there. Use the Unraid share (SMB) for that. This follows from the permissions; it was not tested with a running qBittorrent (see [What was tested](#what-was-tested)).
* **No Community Applications templates.** Unraid's Docker tab can run Gluetun and put other containers on its network (*Network Type: Container*). This repo does not ship templates for that, for three reasons. First, templates have no "start after Gluetun is healthy". Second, community reports say containers on another container's network often need a manual rebuild after that container is updated ([forum thread](https://forums.unraid.net/topic/164846-dockers-using-vpn-network-not-rebuilding-after-update-of-vpn-docker/), [ContainerNetwork AutoFix](https://forums.unraid.net/topic/194313-support-containernetwork-autofix-cnaf-auto-fix-vpn-dependent-containers/)). Third, a second definition of the same stack, without `.env`, the port-forward script or the seeding, would drift from `compose.yaml`. Compose recreates the dependents together with Gluetun, and Compose Manager gives you the same Docker-tab management.
* **Ports.** `QBIT_WEBUI_PORT`, `JACKETT_PORT`, `FLARESOLVERR_PORT` and `FILEBROWSER_PORT` are ports on the Unraid server; any free ports work, but all four must differ. `compose.yaml` sends `JACKETT_PORT` to Jackett's 9117 and `FLARESOLVERR_PORT` to FlareSolverr's 8191 inside Gluetun's network, and qBittorrent's search plugin always talks to Jackett at `127.0.0.1:9117` there, so changing `JACKETT_PORT` needs no re-seeding. qBittorrent is different: its web UI rejects requests whose port differs from its own, so `QBIT_WEBUI_PORT` is used inside Gluetun's network too and cannot be 8000, 8191, 9117 or 9999 (Gluetun's control server, FlareSolverr, Jackett, Gluetun's health server). The installer and `--apply` refuse such values.
* **`TS_SOURCE_DIR`** is always copied without `.git`, `.env*` (except `.env.example`), `configs/` and `downloads/`, even when it is a git checkout.
* **The VPN connection itself was not tested** (no credentials in the test environment).

## What was tested

Tests: [`tests/run-tests.sh`](tests/run-tests.sh) (231 checks, all passing) and [`tests/integration-real-docker.sh`](tests/integration-real-docker.sh) (35 checks, all passing). Both ran in a throwaway Debian 13 Incus container, never on a real Unraid server. Docker 26.1 with Docker Compose **v5.5.0**, the version Compose Manager Plus installs. A generated `.env` also passes `docker compose config -q` with Compose v5.6.1.

* **A fake Unraid root**, built in a private mount namespace: `/etc/unraid-version`, `/var/local/emhttp/var.ini`, `/boot/config/plugins/...`, `/mnt/user/...`. It ran the **real Compose Manager Plus code** (commit `5e92275`, release 2026.10.27) with Unraid's real `Wrappers.php` (unraid/webgui `b135287`). The installer's calls to `compose_args.php` and `compose.sh` are the plugin's own code, not imitations.
* **Shims** stand in for `docker` (records start/stop/pull; `docker compose config` and the seeding container run for real), `modprobe` and `logger`.
* **Covered:** every refusal (no plugin, no plugin and no `docker compose` as on stock Unraid, the old plugin, an old Plus, Unraid 6.11, not Unraid, array stopped, Docker off, no terminal, missing tun, missing share, path outside `/mnt`, `/mnt/user` or a whole pool, a `:` in a path, name and folder conflicts, a seeding failure). Also: dry run (writes nothing, hides secrets), startup gating (placeholder keys: registered with autostart off, not started), `--apply`, idempotent re-runs, the interactive wizard on a pseudo-terminal (hidden keys not echoed), OpenVPN, `--update`, `--uninstall` and `--purge` (downloads kept), and the GitHub clone and tarball (no git) download paths.
* **Overlapping folders:** a downloads folder inside the stack folder, equal to it, holding it (the appdata share), or the same folder written as `/mnt/cache/...` is refused at install and at `--apply`; nothing is written. `--purge` with the downloads inside the stack folder (absolute or `./downloads`) stops before anything is stopped or deleted, and the files stay. A Compose Manager Projects Folder equal to the appdata share (also as `/mnt/cache/appdata`) is refused. An existing entry that *is* the stack folder: `--uninstall` removes only the metadata files and keeps `.env`, `appdata/` and the repository files.
* **qBittorrent is never left stopped:** when seeding fails during `--apply`, and when a re-run finds the VPN keys back at the placeholders, qBittorrent is stopped for seeding and then started again (without recreating anything).
* **Inline comments in `.env`:** with `QBIT_WEBUI_PORT=8090 # web UI`, `WIREGUARD_ADDRESSES=... # ...` and `TZ='Europe/Berlin' # zone`, `--apply` and a re-run read the same values as `docker compose` (checked against `docker compose config`).
* **`--update` from a git clone** (a local test repository standing in for GitHub): after the repository changed both tracked seed files, `--update` pulled them into `configs/`, kept the live `appdata/` files byte for byte, and ran Update Stack. `git status` is clean after the install. `TS_REF=main --update` fast-forwards too. A `compose.yaml` edited by hand still blocks the pull, with steps to fix it.
* **Ports:** with `JACKETT_PORT=19117` and `FLARESOLVERR_PORT=18191` the install succeeds, `docker compose config` publishes 19117 to Jackett's 9117 and 18191 to FlareSolverr's 8191, and the search plugin still points at `127.0.0.1:9117`, also after `--apply` with `JACKETT_PORT` changed again in `.env`. Refused, with nothing written: two apps on the same server port (at install and at `--apply`), and `QBIT_WEBUI_PORT=9117`.
* **FileBrowser's folders and password:** after an install, `appdata/filebrowser` and both download folders are 99:100 with mode 2775, while qBittorrent's config folder stays 755. A database FileBrowser made (uid 1000, mode 644) keeps its owner and content through `--apply` and becomes group 100, mode 664. `--update` turns the 755 folders of an older install into 2775 before Update Stack recreates the containers, and so does `--apply`. A downloads folder open to everyone (777) only gains setgid (2777). The rendered compose gives FileBrowser `FILEBROWSER_DATABASE_PATH=/config/database.sqlite`, group 100, `appdata/filebrowser` at `/config`, and the qBittorrent password (with a space, `$`, `"`, `\` and `#`) exactly as `FILEBROWSER_ADMIN_PASSWORD`. A 73-byte password, and a 37-character one that is 74 bytes, are refused at install; an 80-byte one is refused by `--apply` before anything starts; 72 bytes are accepted.
* **Generated files:** `docker compose config -q` passes on the generated project. Passwords with spaces, `$`, `"`, `\`, `#` and `'` read back unchanged through `docker compose` and through the env-editor's parser. The real seeding container (image by digest, nothing installed in it, stack folder read-only, as 99:100) wrote the PBKDF2 hash, the Jackett API key and the search plugin into `appdata/`, and nothing into `configs/`.
* **What the plugin sees:** its own code resolves the stack as project `torrent-stack` with `<appdata>/torrent-stack/compose.yaml` and `.env`. Its stack list (the Compose page) shows it, and its array-start autostart hook starts it once autostart is on (and not before).
* **The same containers for every tool:** Compose Manager's call and an env-editor style `docker compose -f compose.yaml` produce the same project name and the same per-service config hashes.
* **Real docker** (`integration-real-docker.sh`): Compose Manager's `compose.sh` created the containers as project `torrent-stack` from the appdata `compose.yaml`. qBittorrent, Jackett and FlareSolverr use Gluetun's network namespace, and Gluetun's container publishes 19117 to 9117 and 18191 to 8191 (`JACKETT_PORT`/`FLARESOLVERR_PORT` set to those) and 8090 to 8090. `update-qbittorrent.sh` is executable through the read-only mount Gluetun uses. An env-editor style `docker compose up -d filebrowser` did not recreate the running container. The seeded files are owned by uid 99, and the search plugin points at `127.0.0.1:9117`. FileBrowser, on the real image (FileBrowser Quantum v2.0.2-stable): it runs as uid 1000 with group 100; it created `appdata/filebrowser/database.sqlite` and logged no generated password; `admin` with the qBittorrent password (with a space, `$`, `"`, `\` and `#`) logs in through its API, a wrong password does not; through the API it uploaded a file into `incomplete/` (owned 1000:100) and deleted it again. After a forced recreate it reused its database (no new admin user) and the login still worked. After a new `QBITTORRENT_PASSWORD` in `.env` and `--apply` (which changes the database's group and permissions while FileBrowser runs), the new password logs in, the old one does not, the database was kept, and FileBrowser logged no database write errors. The upgrade path: with `appdata/filebrowser` set back to an old install's state (99:100, 755, no database), a recreated FileBrowser logged `unable to open database file` and kept restarting; after the new installer's `--apply` it started and the login worked. A manual check on the same image showed why the folder modes matter: with `appdata/filebrowser` at 755 and 99:100, FileBrowser stops at start ("unable to open database file"); after the old installer's `chown -R 99:100`, its database became read-only and logins failed.
* **Not tested:** a real Unraid server and its web UI. Unraid 6.12. A real VPN connection and port forwarding. Gluetun actually running: the test machine's kernel is booted with `ipv6.disable=1`, so `compose.yaml`'s IPv6 sysctl cannot be applied there; Unraid kernels have IPv6. The `modprobe tun` step on a real Unraid kernel. The "Python 3 for UNRAID" plugin with the env-editor. The seeding container on Unraid's default bridge network (in the test it used the host network and a test CA). Exclusive shares and real `/mnt/cache` paths (only the path checks saw `/mnt/cache`). Group write and setgid on Unraid's own `/mnt/user` file system (shfs) and on real shares: the tests used an ordinary Linux file system. FileBrowser working inside folders qBittorrent created (qBittorrent never ran, because Gluetun could not start). A real FileBrowser upload through its web page (the API calls the page makes were tested).

Run the tests yourself (root, on a throwaway Linux machine or container with Docker, PHP and internet access; the Docker Compose plugin must not be under `/usr/local`, which the test replaces with the fake Unraid tree):

```bash
bash platforms/unraid/tests/run-tests.sh
TS_TEST_DISPOSABLE=1 bash platforms/unraid/tests/integration-real-docker.sh   # writes Unraid paths: disposable machines only
```

Behind a TLS-inspecting proxy, the seeding container needs that proxy's CA: set `SHIM_EXTRA_CA=/path/to/ca.pem`, with the file outside `/usr/local` (for example `/root/ca.pem`), because the test hides the real `/usr/local`.

## References

* Compose Manager Plus: <https://github.com/mstrhakr/compose_plugin> (source read for the project layout, the `indirect`/`project_name`/`autostart` files, `compose_args.php` and `compose.sh`), and its forum thread, which notes that the original plugin is deprecated: <https://forums.unraid.net/topic/197334-plugin-compose-manager-plus/>
* Original Docker Compose Manager: <https://github.com/dcflachs/compose_plugin> (project name derived from the `name` file with `-` replaced by `_`), forum: <https://forums.unraid.net/topic/114415-plugin-docker-compose-manager/>
* Unraid release notes, base packages (git included; no python3): [7.3.2](https://docs.unraid.net/unraid-os/release-notes/7.3.2/), [7.0.0](https://docs.unraid.net/unraid-os/release-notes/7.0.0/), [6.12.0](https://docs.unraid.net/unraid-os/release-notes/6.12.0/) (also exclusive shares)
* Python on Unraid comes from a community plugin: <https://forums.unraid.net/topic/175402-plugin-python-3-for-unraid-611>
* Flash drive security (files cannot be made executable): <https://docs.unraid.net/unraid-os/system-administration/secure-your-server/secure-your-flash-drive/>
* Community Applications: <https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/community-applications/>
* Shares: <https://docs.unraid.net/unraid-os/using-unraid-to/manage-storage/shares/>
* `/etc/unraid-version` format: <https://forums.unraid.net/topic/76405-how-to-determine-which-version-of-unraid-you-are-currently-running>
* PUID 99 / PGID 100 (`nobody:users`) on Unraid: <https://forums.unraid.net/topic/117661-docker-user-puid-and-group-pgid-settings/>
* Time zone setting (`timeZone` in emhttp's state): unraid/webgui `emhttp/plugins/dynamix/DateTime.page`, <https://github.com/unraid/webgui>
* Containers on another container's network after an update: <https://forums.unraid.net/topic/164846-dockers-using-vpn-network-not-rebuilding-after-update-of-vpn-docker/>, <https://forums.unraid.net/topic/194313-support-containernetwork-autofix-cnaf-auto-fix-vpn-dependent-containers/>
* Gluetun port forwarding providers: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>
* Compose Manager Plus *Projects Folder* (any path can be set) and *Delete Stack* (removes the whole entry folder): `docs/configuration.md` and `source/compose.manager/include/Util.php` (`composeDeleteStackFolder`) in <https://github.com/mstrhakr/compose_plugin>
* FileBrowser Quantum in Docker: <https://filebrowserquantum.com/en/docs/getting-started/docker/>; environment variables (`FILEBROWSER_ADMIN_PASSWORD`, `FILEBROWSER_DATABASE_PATH`): <https://filebrowserquantum.com/en/docs/reference/environment-variables/>
* FileBrowser Quantum source at tag `v2.0.2-stable` (commit `2c071d1`, the version the `stable` image reported in the test), <https://github.com/gtsteffaniak/filebrowser>: `backend/pkg/settings/config.go` (`loadEnvConfig`: `FILEBROWSER_ADMIN_PASSWORD` overrides the config file; `SetDefaults`: admin username `admin`), `backend/pkg/settings/auth.go` (`ConfigTriggersAdminPasswordReset`: any admin password other than empty or `admin` is written to the admin user at startup), `backend/cmd/user.go` (`validateUserInfo`, run at every server start, does that reset), `backend/pkg/settings/password_policy.go` (minimum length 5), `_docker/Dockerfile` (user `filebrowser`, uid 1000; default database `/home/filebrowser/data/database.sqlite`)
* bcrypt accepts at most 72 bytes: <https://pkg.go.dev/golang.org/x/crypto/bcrypt> (`GenerateFromPassword`, `ErrPasswordTooLong`)
* LinuxServer images take an optional `UMASK` variable: <https://docs.linuxserver.io/images/docker-qbittorrent/> (section "Umask for running applications")
* Docker Compose `.env` syntax (inline comments need a space before `#`; text after a closing quote is ignored): <https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/>
