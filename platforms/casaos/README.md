# CasaOS / ZimaOS: install as a dashboard app

This installs the torrent stack (Gluetun VPN, qBittorrent with VueTorrent, Jackett, FlareSolverr, FileBrowser) on a CasaOS or ZimaOS box as **one app on the dashboard** called *Torrent Stack*. You start, stop, restart and uninstall it from the dashboard like any other app. Its icon opens qBittorrent.

qBittorrent, Jackett and FlareSolverr use Gluetun's network. When the VPN is down they have no internet at all, and they are not even started until Gluetun reports a working VPN connection.

The installer is one script, [`install.sh`](install.sh). It asks a few questions, writes `/DATA/AppData/torrent-stack/.env`, prepares the folders and logins, and hands the app to CasaOS through CasaOS's own app API. That is the same call the dashboard's *Install a customized app > Import* makes.

## Before you start

* **CasaOS 0.4.4 or newer** (tested: 0.4.15 on Debian 13), or **ZimaOS** (not tested, see [ZimaOS](#zimaos)). Check the version under *Settings* in the dashboard.
* **A root shell on the box.**
  * CasaOS: SSH in (or use the machine's console) and run `sudo -i`.
  * ZimaOS: *Settings > General > Developer Mode* turns on SSH and a web terminal. ZimaOS asks you to set the root password with a monitor attached the first time.
* **Internet access** from the box (GitHub, the container registries, pypi.org for the seeding helper).
* **A VPN account that supports port forwarding through Gluetun**: ProtonVPN, Private Internet Access, Perfect Privacy or PrivateVPN. Have the WireGuard *PrivateKey* and *Address* lines ready (or the OpenVPN username and password). Other Gluetun providers connect, but qBittorrent's port stays closed and nothing seeds. See the [Gluetun port-forwarding list](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md).
* **Free ports** 8090 (qBittorrent), 9117 (Jackett), 8191 (FlareSolverr), 8081 (FileBrowser), or pick others in the wizard.
* An **amd64 or arm64** machine (ZimaBoard, ZimaCube, Raspberry Pi 4/5, any x86 PC).

## Install

1. Open the root shell (see above).
2. Paste this and press Enter:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/casaos/install.sh)"
   ```

3. Answer the questions. Pressing Enter keeps the value shown.
   * **Downloads folder**: default `/DATA/Downloads`, CasaOS's Downloads share. A folder on a disk under `/media/...` works too, for example `/media/HDD/Downloads`. The installer makes an `incomplete` folder inside it. FileBrowser shares this folder on your network, so the installer refuses a folder that would expose more than downloads: a whole disk (`/media/HDD`), a top-level folder (`/DATA`), or any folder that contains the stack's settings.
   * **Time zone**: taken from the box.
   * **VPN provider** and **protocol**, then the **WireGuard private key** and **address** (or the OpenVPN username and password). Typed keys and passwords are hidden.
   * **Server countries**, for example `Netherlands,Switzerland`.
   * **qBittorrent user and password**. Leave the password empty and one is generated and shown at the end. FileBrowser's user `admin` gets the same password, so it must be 5 to 72 characters long and not `admin` (FileBrowser cannot take those; the installer says so).
   * **Discord webhook** (optional), for "port updated" messages.
   * **Web UI ports**: change them only if another app already uses one. These are the ports on the box; inside, Jackett and FlareSolverr keep their own ports (9117 and 8191), so changing them is safe.
   * **Automatic updates**: see [Updating](#updating). The default is no.
4. Confirm. CasaOS first checks the app definition (and that the ports are free). The installer then downloads the images (a few minutes the first time), seeds the logins and registers the app. It waits until every container runs the new settings and Gluetun is connected to the VPN.
5. Then it checks what Docker cannot see: that qBittorrent, Jackett and FlareSolverr really are in Gluetun's network, that every web UI answers on its port, and that qBittorrent accepts the login from `.env` (Gluetun's port-forward script uses the same login).
6. At the end it prints the addresses, for example `http://192.168.1.20:8090`, and the logins. Passwords are only printed to a terminal; when the output goes to a file (for example from cron), it says where to find them instead.

When something is wrong, the installer says what and stops with an exit code:

| Exit code | Meaning |
|---|---|
| 0 | Done; everything checked out. |
| 1 | An error before or while handing the app to CasaOS (the message says which). This includes CasaOS refusing the app (ports in use), and a change CasaOS could not apply in the background (it does not report that itself; its log, `journalctl -u casaos-app-management`, says why). |
| 2 | The app did not come up in time, nearly always because the VPN does not connect. The app stays installed and CasaOS keeps trying. Gluetun's log usually says why: `docker logs --tail 40 torrent-stack-gluetun-1`. Fix the VPN values in `.env`, then run `--apply`. |
| 3 | The app runs, but a check failed: a web UI does not answer, qBittorrent refused the `.env` login, or an app could not be put back into Gluetun's network. The message says which, and what to do. |

Re-running the one-liner is safe. It reuses your `.env` as the defaults and updates the existing app instead of adding a second one.

## What it creates

| Where | What |
|---|---|
| Dashboard | One app, *Torrent Stack*. The icon opens qBittorrent. The other web UIs are on their own ports (table below). |
| `/DATA/AppData/torrent-stack/` | This repository's files, plus the things below. CasaOS's convention is `/DATA/AppData/<app>`. |
| `.../torrent-stack/.env` | **Every setting**, including the VPN key and passwords. Readable by root only (0600). |
| `.../torrent-stack/configs/` | The apps' own settings (qBittorrent, Jackett, FlareSolverr, FileBrowser, Gluetun). They are kept by updates, `--apply` and `--uninstall`. |
| `.../torrent-stack/configs/filebrowser/database.sqlite` | FileBrowser's users and settings. Kept when the container is recreated (an update, a port change). |
| `.../torrent-stack/casaos-app.yml` | The app definition last sent to CasaOS (root only). Useful for a manual import. |
| `/DATA/Downloads/` and `/DATA/Downloads/incomplete/` | Finished and in-progress downloads. FileBrowser shows this folder. |
| `/var/lib/casaos/apps/torrent-stack/` | CasaOS's own copy of the app definition. CasaOS manages it; do not edit it. |

| Web UI | Default address | Login |
|---|---|---|
| qBittorrent (VueTorrent) | `http://<box>:8090` | the qBittorrent user and password from the wizard |
| Jackett | `http://<box>:9117` | none |
| FlareSolverr | `http://<box>:8191` | none (Jackett uses it) |
| FileBrowser | `http://<box>:8081` | user `admin`, the qBittorrent password |

Settings the installer makes for you:

* `PUID`/`PGID` **1000/1000**. That is CasaOS's own default for apps. The config folders and the `incomplete` folder belong to it.
* FileBrowser's image always runs as uid 1000, whatever `PUID` is, so the stack also gives it the `PGID` group. The folders the installer makes for it (FileBrowser's config folder, the `incomplete` folder, and the downloads folder if it did not exist yet) are writable for that group, with the setgid bit (mode `2775`), so what FileBrowser and qBittorrent create there stays in the `PGID` group. With the default 1000/1000 this changes nothing you would notice.
* An existing downloads folder keeps its owner and mode (`/DATA/Downloads` is writable by everyone). The installer warns you, with the command to fix it, if qBittorrent or FileBrowser could not write there.
* Absolute `/DATA/...` paths in `.env`.
* No Discord webhook unless you give one.
* Watchtower off unless you turn on automatic updates.

## First login

* **qBittorrent**: the user and password from the wizard. The installer already put the password into qBittorrent's settings, and checked that qBittorrent accepts it. It also installed the Jackett search plugin and wired it to Jackett's API key, so *Search* works as soon as you add indexers.
* **Jackett**: open it and add indexers (*Add indexer*). FlareSolverr is already set as its Cloudflare solver.
* **FileBrowser**: user `admin`, and the qBittorrent password (`QBITTORRENT_PASSWORD` in `.env`). The user name is FileBrowser's own default and cannot be changed here. FileBrowser sets that password again every time it starts, so:
  * when you change the qBittorrent password (edit `.env`, run `--apply`), FileBrowser's `admin` gets the new one too;
  * a password you change inside FileBrowser for `admin` only lasts until FileBrowser next starts (an update, a restart of the app, a reboot). Change `QBITTORRENT_PASSWORD` instead.

  Everything else FileBrowser keeps, in `configs/filebrowser/database.sqlite`: other users you add, their passwords, shares and settings stay when the container is recreated.

## Adding the VPN settings later

If you run the installer unattended without VPN values, it still prepares everything (`.env`, folders, logins). It does **not** register the app yet, because Gluetun and the apps behind it must not start with placeholder VPN credentials.

This differs on purpose from the repository's Proxmox and Incus installers, which start FileBrowser and the settings editor straight away so you can fill in the VPN there. On CasaOS the settings are edited in `.env`, not in a web page, and a half-started app on the dashboard would only open a dead qBittorrent page. So nothing at all is on the dashboard until the VPN values are in. Put the VPN values into `/DATA/AppData/torrent-stack/.env` (`VPN_TYPE`, then `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES`, or `OPENVPN_USER` and `OPENVPN_PASSWORD`) and run:

```bash
bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --apply
```

## Changing settings

`.env` is the single source of truth. To change anything (VPN, ports, password, countries):

1. Edit the file: `nano /DATA/AppData/torrent-stack/.env`
2. Apply it:

   ```bash
   bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --apply
   ```

`--apply` checks the file, lets CasaOS validate the new app definition, re-seeds qBittorrent if the login changed, and sends the definition to CasaOS. CasaOS recreates only the containers whose settings changed; the installer waits until it has, then runs the same checks as an install (shared network, web UIs, qBittorrent login).

A few things it takes care of:

* **qBittorrent's password.** qBittorrent 5 keeps its web UI login in a newer `[WebUI]` section of `qBittorrent.conf` once it has started the first time. The repository's seeding CLI writes the login there too in that case, so a changed password really reaches qBittorrent. If qBittorrent still refuses the login, `TS_RESEED=1 bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --apply` seeds it again. FileBrowser's `admin` gets the new password as well (CasaOS recreates FileBrowser with it). A password FileBrowser cannot take (shorter than 5 characters, longer than 72 bytes, or `admin`) is refused before anything changes.
* **Each setting once.** If `.env` sets something twice (for example a new password added at the end instead of changing the existing line), `--apply` refuses and names both line numbers. Docker would quietly use the last one, and qBittorrent and Gluetun could end up with different passwords. Re-running the installer's wizard keeps one line.
* **Ports.** `JACKETT_PORT` and `FLARESOLVERR_PORT` choose the port on the box. Inside Gluetun's network Jackett stays on 9117 and FlareSolverr on 8191, so the search plugin and Jackett's FlareSolverr link keep working. `QBIT_WEBUI_PORT` is the same inside and out, so it must not be 9117, 8191, 8000 or 9999 (used inside by Jackett, FlareSolverr and Gluetun).

Please **do not change the app in the dashboard's app settings dialog**:

* the next `--apply` overwrites whatever you changed there;
* that dialog's *Network* dropdown has no entry for "Gluetun's network". Picking a network there would move qBittorrent off the VPN.

Two more things to avoid on CasaOS:

* Do not run `docker compose` in `/DATA/AppData/torrent-stack`, and do not start the env-editor (`scripts/setup.sh`) here. Both start the repository's `compose.yaml` under the same project name and would take the containers away from CasaOS.
* A `$` cannot be used in any value (password, key, path). CasaOS runs the app definition through variable substitution twice, so `$...` would silently turn into an empty value. The installer refuses such a value and says which one.

## Restarting

Restart the **whole app** from the dashboard. The app is set up so that CasaOS then restarts Gluetun first and qBittorrent, Jackett and FlareSolverr after it (Compose's `restart: true` on their dependency), so they join Gluetun's new network.

Do not restart only the `gluetun` container (for example with `docker restart`). qBittorrent, Jackett and FlareSolverr would stay in Gluetun's old network, which has no connection at all: nothing leaks, but their web UIs stop answering while Docker still shows them as running. If that happens, run:

```bash
bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --apply
```

It notices, restarts those three into Gluetun's network, and checks the web UIs. If it cannot fix it, it tells you to **Stop** the app in the dashboard and then **Start** it.

## Updating

CasaOS only updates apps that come from an app store, so nothing updates this custom app on its own. Choose one:

* **By hand** (default): this downloads the repository's files again (your `.env` and `configs/` are kept), pulls new images, and applies them with the **new** copy of the installer, so fixes to the installer take effect straight away. CasaOS recreates what changed (Gluetun too, when the port-forward script changed):

  ```bash
  bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --update
  ```

  To run it nightly, add it to root's crontab (`crontab -e`):

  ```
  30 4 * * * umask 077; bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --update -y >/var/log/torrent-stack-update.log 2>&1
  ```

  `umask 077` keeps the log readable by root only. The installer never prints passwords into a log anyway.
* **Watchtower**: answer *yes* to *Automatic updates* in the wizard (or set `COMPOSE_PROFILES=watchtower` in `.env` and run `--apply`). This stack's own Watchtower then updates these containers nightly (only these: `scope=torrent-stack`).

`TS_REF=v1.2.3` (with `--update`) pins the repository to a tag instead of `main`. Later `--update` runs, the cron line included, stay on that tag (and on a fork given with `TS_REPO_URL`) until you pass another `TS_REF`.

## Uninstall

```bash
bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --uninstall
```

This removes the app and its containers from CasaOS and waits until CasaOS has finished (it also deletes the app's images, then its own copy of the app). **`/DATA/AppData/torrent-stack` (settings, `.env`) and your downloads are kept**, so installing again picks up where you left off. To delete the folder as well:

```bash
bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --uninstall --purge
```

Downloads are never deleted.

Uninstalling from the dashboard also works. Its dialog has a *Delete userdata (config folder)* checkbox, unticked by default. If you tick it, CasaOS deletes `/DATA/AppData/torrent-stack`, `.env` included. It also deletes every other folder of the app whose path contains `torrent-stack`, which is why the downloads folder must not have `torrent-stack` in its path. (`casaos-cli app-management uninstall` deletes the folder unless you add `-n`.)

## Install by hand (Import)

If the installer cannot talk to CasaOS (it says so), or you prefer to click:

1. Prepare everything without registering:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/casaos/install.sh)" install.sh --no-register
   ```

2. In the dashboard: **+** (next to *Apps*) > **Install a customized app** > **Import** (top right).
3. Paste the contents of `/DATA/AppData/torrent-stack/casaos-app.yml` into the *Docker Compose* tab. `install.sh --print-yaml` prints the same thing. Then **Submit** and **Install**.

That YAML contains your VPN key and passwords. Paste it only into your own CasaOS.

## Unattended install

Answers can come from environment variables; secrets come from files, never from the command line:

```bash
umask 077
printf '%s\n' 'YOUR-WIREGUARD-PRIVATE-KEY' > /root/wg.key
TS_WIREGUARD_PRIVATE_KEY_FILE=/root/wg.key TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  bash /path/to/install.sh --unattended
```

| Variable | Default | Meaning |
|---|---|---|
| `TS_APPDATA` | `/DATA/AppData` | The stack goes into `<it>/torrent-stack`. Only needed for the first install: later runs find the stack from the installed app, or from where the script itself is. |
| `TS_DOWNLOADS` | `/DATA/Downloads` | Downloads folder. |
| `TS_TZ`, `TS_PUID`, `TS_PGID` | box's zone, 1000, 1000 | |
| `TS_VPN_PROVIDER`, `TS_VPN_TYPE` | `protonvpn`, `wireguard` | |
| `TS_WIREGUARD_ADDRESSES`, `TS_OPENVPN_USER`, `TS_OPENVPN_PROTOCOL`, `TS_SERVER_COUNTRIES` | | |
| `TS_QBITTORRENT_USER` | `admin` | |
| `TS_QBIT_WEBUI_PORT`, `TS_JACKETT_PORT`, `TS_FLARESOLVERR_PORT`, `TS_FILEBROWSER_PORT` | 8090, 9117, 8191, 8081 | |
| `TS_WATCHTOWER` | `0` | `1` turns on Watchtower. |
| `TS_WIREGUARD_PRIVATE_KEY_FILE`, `TS_OPENVPN_PASSWORD_FILE`, `TS_QBITTORRENT_PASSWORD_FILE`, `TS_SCRIPT_NOTIFY_URL_FILE` | | Secrets: the first line of each file (chmod 600 it). |
| `TS_SOURCE_DIR` | | Use this local checkout instead of downloading (how the tests run). |
| `TS_REF`, `TS_REPO_URL` | `main`, this repo | Branch or tag, or a fork. `--update` remembers both. |
| `TS_CASAOS_API` | found automatically | app-management's address, e.g. `http://127.0.0.1:12345`, if it cannot be found. Must be on this machine. |
| `TS_WAIT` | `900` | Seconds to wait for the app to come up. |
| `TS_UI_WAIT` | `300` | Seconds the web UIs get to answer after that (qBittorrent first downloads the VueTorrent theme). |
| `TS_RESEED` | `0` | `1` seeds the qBittorrent login again even though `.env`'s login has not changed. |
| `TS_IPV6_SYSCTL` | `auto` | Gluetun's IPv6-off sysctl; see [Limitations](#limitations-and-known-issues). |
| `TS_FORCE` | `0` | `1` takes over a CasaOS app named `torrent-stack` that this installer did not create. |
| `TS_UI` | `whiptail` if present | `plain` for simple prompts. |

Options: `--apply`, `--update`, `--print-yaml`, `--uninstall [--purge]`, `--no-register`, `--dry-run` (shows every file and request, changes nothing; CasaOS is still asked to validate the app), `--unattended`/`-y`, `--help`. Exit codes: see [Install](#install).

## How it works

The installer turns `.env` plus the repository's `compose.yaml` into a CasaOS app definition, `casaos-app.yml`. It keeps the same services, images, settings and Gluetun health gate. Three things differ because of how CasaOS handles apps:

1. **Every value is written out.** CasaOS does not read `.env` files. It substitutes `$VARIABLES` from its own environment, so `${QBIT_WEBUI_PORT}` would arrive empty.
2. **Every path is absolute.** CasaOS reads the definition in a temporary folder, so `./update-qbittorrent.sh` would point nowhere.
3. **`x-casaos` metadata.** The app's id (`io.github.rob-paprocki.torrent-stack`), title, icon (embedded, nothing is fetched from a CDN), category, and the port the icon opens. Each service also carries short descriptions shown in CasaOS's settings dialog.

Two more differences:

4. **`restart: true`** on the dependency of qBittorrent, Jackett and FlareSolverr on Gluetun, so a restart of the app restarts them after Gluetun. (`compose.yaml` does not have it yet; it is reported for a change there.)
5. **A revision label on every container**, a short hash of that service's definition (for Gluetun, also of `update-qbittorrent.sh`). CasaOS applies changes in the background and, when that fails, keeps the old definition without reporting it, so the installer compares these labels with what it sent to know when CasaOS has really switched. It also means a new `update-qbittorrent.sh` recreates Gluetun: Docker keeps the old file mounted until then.

It then talks to CasaOS's **app-management API** on `127.0.0.1`. app-management accepts local calls without a login; that is how `casaos-cli` works. The address comes from `/var/run/casaos/app-management.url`, or else from the gateway port in `/etc/casaos/gateway.ini`. The calls are:

* `POST /v2/app_management/compose?dry_run=true` (or `PUT .../compose/torrent-stack?dry_run=true` when installed): CasaOS checks the definition and the ports and changes nothing. This comes first, before anything is downloaded, stopped or seeded, so a refusal leaves the running app as it was;
* `POST /v2/app_management/compose` to install, or `PUT /v2/app_management/compose/torrent-stack` to update. Both run in the background, so the installer watches the containers (their revision labels and images) until CasaOS has switched;
* `DELETE /v2/app_management/compose/torrent-stack?delete_config_folder=false` to uninstall and keep the data.

The images are pulled before CasaOS is called, so download progress and registry errors show in the terminal.

Everything else is as in `compose.yaml`, which the test suite checks: Jackett and FlareSolverr are published as `JACKETT_PORT:9117` and `FLARESOLVERR_PORT:8191`, and FileBrowser keeps its database in its config folder (`FILEBROWSER_DATABASE_PATH=/config/database.sqlite`), gets the qBittorrent password for `admin` (`FILEBROWSER_ADMIN_PASSWORD`) and the `PGID` group (`group_add`).

First-run seeding uses this repository's seeding CLI (`scripts/env-editor/seed_configs.py`): the qBittorrent password and the Jackett search plugin (the commit and checksum pinned in `native/versions.env`; a download that does not match is refused), pointed at `127.0.0.1:9117` (Jackett's own port inside Gluetun's network, whatever `JACKETT_PORT` is on the box), and the Jackett API key. FileBrowser needs no seeding (`compose.yaml` sets its password), so nothing needs `bcrypt` and nothing is installed from PyPI. It runs on the box's `python3` (3.8 or later); otherwise in a throwaway `python:3.14.9-slim-trixie` container pinned by digest, with the stack folder mounted read-only and only the configs folder writable (always on ZimaOS, which ships no python3 as far as we know). Either way it reads `.env` as root, then switches to the apps' user (`PUID:PGID`) before it writes anything, so a link planted in an app's config folder can never make root overwrite another file. qBittorrent is stopped while it is seeded, because it writes its settings back when it stops. Seeding is skipped when the login has not changed. It needs internet access once, for the search plugin.

## ZimaOS

ZimaOS grew out of CasaOS and keeps its app system. Its services are called `zimaos-app-management` and so on, but it keeps CasaOS's paths (`/DATA/AppData`, `/var/lib/casaos`, `/etc/casaos`) and the same Import dialog. The installer detects ZimaOS (`zimaos -v` or `/etc/os-release`) and handles its differences:

* the root filesystem is read-only, so everything goes to `/DATA` and nothing is installed into the system;
* ZimaOS does not seem to ship python3, git or whiptail (we could not check a real one). The installer needs none of them: it seeds in the throwaway container, downloads the repository as a tarball with curl, and asks plain prompts. If its `tar` is busybox's, that works too, as long as that busybox was built with `tar --exclude` (the installer only uses options both understand). Buildroot's default busybox has it, and ZimaOS is built with Buildroot; Ubuntu's `busybox-static` 1.36.1 does not, and `--update` then stops while copying the files.

**ZimaOS was not tested on a real ZimaOS machine** (only with a `zimaos -v` stand-in). If its app-management asks for a login (the installer would say "asked for a login"), use [Install by hand](#install-by-hand-import).

## Limitations and known issues

* **FileBrowser's `admin` password is always the qBittorrent one.** FileBrowser sets it again on every start, so changing it inside FileBrowser does not last (see [First login](#first-login)).
* **FileBrowser with a `PUID` other than 1000.** FileBrowser always runs as uid 1000 and reaches the downloads through the `PGID` group. It can see everything there, but it may not be able to delete or rename inside folders qBittorrent creates, because qBittorrent does not make them group-writable unless its `UMASK` setting says so (`compose.yaml` does not set one). With CasaOS's default `PUID` 1000 both apps are the same user and this does not come up.
* **Secrets are visible to CasaOS admins.** CasaOS keeps the app's settings, VPN key included, in its own copy of the app and shows them in the app's settings dialog to anyone who can log in to the dashboard. CasaOS's *Files* app can also open `/DATA/AppData/torrent-stack/.env`.
* **No `$` in values** (see [Changing settings](#changing-settings)).
* **One dashboard icon.** CasaOS gives an app one icon, which opens qBittorrent. Jackett, FlareSolverr and FileBrowser are on their ports.
* **No IPv6 sysctl on kernels without IPv6.** `compose.yaml` turns IPv6 off inside Gluetun's network with a sysctl. On a kernel booted with `ipv6.disable=1` that sysctl does not exist and Docker refuses to start Gluetun. The installer then leaves it out, with a warning; with IPv6 switched off in the kernel nothing can leak over IPv6. `TS_IPV6_SYSCTL=on|off` overrides the check.
* **The env-editor is not used here.** It runs `docker compose` on `compose.yaml`, which would take the containers away from CasaOS. Edit `.env` and run `--apply` instead.
* **Uninstalling deletes the images** (CasaOS does that).
* **Port forwarding** only works with the providers listed in [Before you start](#before-you-start).

## What was tested, and what was not

**Tested on a real CasaOS**: v0.4.15, installed with the official `get.casaos.io` script in a Debian 13 Incus container with Docker 26.1. Its app-management package is v0.4.10-alpha2, which reports itself as v0.4.5. Automated in [`tests/e2e-incus.sh`](tests/e2e-incus.sh) (51 checks, all passing) unless marked "by hand":

* A fresh install is accepted by app-management. It shows on the dashboard's app grid with its title, port and icon. qBittorrent, Jackett and FlareSolverr run in Gluetun's network namespace. CasaOS accepts the `restart: true` dependencies and the revision labels and keeps them on the containers.
* With a made-up WireGuard key, Gluetun runs but never gets healthy, so qBittorrent, Jackett and FlareSolverr are never started. A container in Gluetun's network cannot reach the internet, by IP or by name.
* CasaOS's `/DATA/Downloads` is writable for qBittorrent and FileBrowser (no warning), and the `incomplete` folder is made `1000:1000`, mode `2775`.
* A re-run and `--apply` update the app in place (PUT) without recreating containers. `--dry-run` changes no file and prints no secret. `--print-yaml` is clean YAML. `--uninstall` removes the app, waits until CasaOS has deleted its own copy too, and keeps `/DATA/AppData/torrent-stack`.
* With Gluetun swapped for an always-healthy test double, every app started under CasaOS and the installer's own checks (shared network, every web UI, qBittorrent login) passed. From another machine on the network: qBittorrent accepted the seeded password (and refused a wrong one), had the Jackett search plugin installed, and used the seeded save paths. Jackett accepted the seeded API key and FlareSolverr answered. FileBrowser accepted `admin` with the qBittorrent password and refused a wrong one; its database is in `configs/filebrowser` (folder `1000:1000`, mode `2775`), and CasaOS kept `group_add` on the container. No password was printed into the installer's log file.
* **A password change with `--apply`**: the new password logs in from the network, the old one is refused, and Gluetun's port-forward script has the new one. FileBrowser too takes the new password and refuses the old one, and it kept its database across the recreate (the same `admin` user id).
* **`JACKETT_PORT=9118`, `FLARESOLVERR_PORT=8192`**: both answer on the new ports from the network, and the search plugin still reaches Jackett inside.
* **Restarting the whole app through CasaOS** (the call the dashboard's Restart button makes): afterwards all four containers share Gluetun's new network and qBittorrent answers.
* **Gluetun restarted on its own** (`docker restart`): the web UIs went dead as described; `--apply` noticed, restarted the three apps into Gluetun's network, and qBittorrent answered again.
* By hand: a port already in use is refused with the port named, against CasaOS's own port check (during the first build). A change CasaOS could not apply in the background (its backup copy made to fail; CasaOS's log said `docker-compose.yml.bak: is a directory`): the containers kept the old settings and `--apply` exited 1 saying so, instead of reporting success. A failed image pull stopped `--apply` before anything was changed. The installed app's folder is read correctly from the YAML CasaOS returns.
* Seeding on the box's own python3.
* By hand, the real FileBrowser Quantum v2.0.2 image on plain Docker, with folders as the installer makes them for `PUID` 1001 / `PGID` 1002 and the same settings as `compose.yaml`: the database went to `/config`, `admin` with the given password logged in (a wrong one got 401), and after a restart with a new password the new one worked, the old one was refused and the `admin` user was the same. With the folder only handed to `PUID` (what the installer did before), FileBrowser could no longer write its database ("attempt to write a readonly database") and its password change failed.

The qBittorrent `[WebUI]` fix was also checked against the real `lscr.io/linuxserver/qbittorrent` image (qBittorrent 5.3.0) directly: re-seeding only the old keys left the old password working (401 for the new one); after the installer's copy into `[WebUI]` the new password worked (204) and the old one was refused.

**Tested with stand-ins** ([`tests/run-tests.sh`](tests/run-tests.sh), 174 checks with IceWhaleTech's validator, all passing; one more is skipped without a busybox): a fake app-management built from CasaOS-AppManagement's source and checked against the real one; shims for `docker`, `casaos -v` and `zimaos -v`; whiptail; a pseudo-terminal for the plain prompts; and stand-ins for what the apps do (qBittorrent 5's settings migration and login, which port answers inside Gluetun's network, network namespaces). The rendered app passes `docker compose config -q`, schema checks taken from CasaOS-AppStore and app-management, and **IceWhaleTech's own AppStore validator** (`validate_compose.py`). A drift check compares it with `compose.yaml` through `docker compose config`, with Watchtower off and on, the IPv6 sysctl on and off, Jackett and FlareSolverr on other host ports, and `PUID`/`PGID` 1001/1002; it allows only the differences listed in [How it works](#how-it-works). FileBrowser's part (database path, the qBittorrent password for `admin`, `PGID` as extra group) is checked on its own too, as are the folder modes, and with the kernel's own permission checks (`setpriv`) that uid 1000 with the `PGID` group can write FileBrowser's database and the downloads, and cannot without that group. Also covered: every refusal (not CasaOS, too old, no terminal, a login required, ports in use, someone else's app or containers, a `$` in a value, a key set twice in `.env`, a downloads folder that is a whole disk, a top-level folder, contains the stack or has the app name in it, a qBittorrent port taken inside Gluetun's network, a qBittorrent password FileBrowser cannot take), that a refusal by CasaOS's validation happens before qBittorrent is stopped or seeded, startup gating, `--no-register`, `--update` with a new image, `--update` with no git (tarball download), and busybox 1.37's `tar` (in an earlier round; this round only Ubuntu's `busybox-static` 1.36.1 was at hand, which has no `tar --exclude`, see [ZimaOS](#zimaos)), remembering the tag and fork, applying with the new installer, a new `update-qbittorrent.sh` recreating Gluetun, a password change, host-side port changes, a dead web UI and a refused login (exit 3), `TS_RESEED`, apps left outside Gluetun's network, a change CasaOS does not apply, finding the stack without `TS_APPDATA`, keeping an absolute `CONFIG_PATH`, the not-connected report, both wizards, `--uninstall --purge`, seeding in the container and on the host, and that no secret ends up on a `docker` or `curl` command line or in the output. Each of the new checks was confirmed to fail with its fix taken out (for the FileBrowser and folder checks: against the previous `install.sh`).

**Not tested:**

* A real VPN connection and port forwarding (no credentials). The restart and network checks above used a Gluetun test double; real Gluetun takes longer to restart but Compose keeps the same order.
* A real ZimaOS machine (only `zimaos -v`, git missing and busybox `tar` were simulated).
* CasaOS on Ubuntu, Raspberry Pi OS or arm64.
* Clicking through the dashboard itself (the Import dialog, the settings dialog, the Restart button); its code was read, and Restart was tested through the same API call.
* The nightly cron line on a real box.
* The seeding container against real pypi from inside nested Docker (this test machine intercepts TLS, which the throwaway python container does not trust). The same container command is exercised by the Unraid installer's tests.
* FileBrowser with a `PUID` other than 1000 under CasaOS itself (only the real image on plain Docker, and the permission checks in the shim tests), and deleting qBittorrent's downloads from FileBrowser in that case (see [Limitations](#limitations-and-known-issues)).
* The VueTorrent theme. Its docker mod is downloaded from ghcr.io inside the qBittorrent container, which hit the same TLS limit here.
* Real Gluetun with the IPv6 sysctl (the test kernel has `ipv6.disable=1`).

Run the tests yourself (root, a throwaway Linux machine with Docker Compose and python3-yaml):

```bash
bash platforms/casaos/tests/run-tests.sh
# optional: also run IceWhaleTech's validator
CASAOS_APPSTORE_DIR=/path/to/CasaOS-AppStore bash platforms/casaos/tests/run-tests.sh
# optional: busybox's tar for one update, as ZimaOS may have
CASAOS_TEST_BUSYBOX=/path/to/busybox bash platforms/casaos/tests/run-tests.sh
# real CasaOS in Incus (needs incus and the images:debian/13 image; downloads several GB)
bash platforms/casaos/tests/e2e-incus.sh
```

## References

* CasaOS-AppStore, compose and x-casaos spec: <https://github.com/IceWhaleTech/CasaOS-AppStore/blob/main/docs/specs/compose-and-x-casaos.md> (same text on ZimaSpace: <https://www.zimaspace.com/docs/developer/app-store-compose-x-casaos>)
* CasaOS-AppStore validator: <https://github.com/IceWhaleTech/CasaOS-AppStore/blob/main/.github/actions/validate-compose/scripts/validate_compose.py>
* CasaOS-AppManagement API: <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/api/app_management/openapi.yaml>
* Local calls without a login (JWT skipped for 127.0.0.1): <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/route/v2.go>
* Install, apply, uninstall and variable substitution: <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/route/v2/compose_app.go>, <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/service/compose_app.go>, <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/service/compose_service.go> (PUID/PGID defaults 1000/1000: <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/main/common/constants.go>)
* casaos-cli (same API, gateway port from `/etc/casaos/gateway.ini`): <https://github.com/IceWhaleTech/CasaOS-CLI>
* Dashboard's compose form (network modes, Import): <https://github.com/IceWhaleTech/CasaOS-UI/blob/main/src/components/Apps/ComposeConfig.vue>
* `casaos -v`: <https://github.com/IceWhaleTech/CasaOS/blob/main/main.go>
* CasaOS installer used by the end-to-end test: <https://get.casaos.io> (source: <https://github.com/IceWhaleTech/get>)
* ZimaOS releases and notes (1.7.1: uninstall keeps app data; 1.8.0: uninstall asks): <https://github.com/IceWhaleTech/ZimaOS>
* ZimaOS custom app Import steps: <https://www.zimaspace.com/docs/zimaos/paperless-ai-install>
* ZimaOS SSH / Developer Mode: <https://www.zimaspace.com/docs/zimaos/How-to-Open-SSH-in-ZimaOS>
* CasaOS to ZimaOS migration (same AppData and compose files): <https://www.zimaspace.com/docs/zimaos/casaos-to-zimaos-migration>
* ZimaOS service names (`zimaos-app-management`, `zimaos -v`; third-party cheat sheet): <https://computingforgeeks.com/casaos-zimaos-cli-cheat-sheet/>
* Gluetun with another app on ZimaOS (community): <https://shop.zimaspace.com/pages/zimaos-vpn-client-gluetun-app-routing>
* Gluetun port forwarding: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>
* FileBrowser Quantum (gtsteffaniak), v2.0.2-stable, the version `:stable` was when this was tested:
  * environment variables (`FILEBROWSER_ADMIN_PASSWORD`, `FILEBROWSER_DATABASE_PATH`): <https://filebrowserquantum.com/en/docs/reference/environment-variables/>
  * `FILEBROWSER_ADMIN_PASSWORD` read on every start, default user `admin`, minimum length 5: <https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/config.go>, <https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/password_policy.go>
  * the `admin` user's password set from it at every start, unless it is empty or `admin`: <https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/cmd/user.go>, <https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/auth.go>, first start: <https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/bootstrap_admin_password.go>
  * the image runs as uid 1000: <https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/_docker/Dockerfile>
  * bcrypt takes at most 72 bytes (golang.org/x/crypto v0.57.0, which it uses): <https://github.com/golang/crypto/blob/v0.57.0/bcrypt/bcrypt.go>
* `group_add` in the Compose that CasaOS's app-management builds on (compose-go v1.20.2, docker compose v2.23.3): <https://github.com/compose-spec/compose-go/blob/v1.20.2/types/types.go>, <https://github.com/docker/compose/blob/v2.23.3/pkg/compose/create.go>; versions from <https://github.com/IceWhaleTech/CasaOS-AppManagement/blob/v0.4.10-alpha2/go.mod>
* Buildroot's default busybox (`tar --exclude` is `CONFIG_FEATURE_TAR_FROM`): <https://github.com/buildroot/buildroot/blob/master/package/busybox/busybox.config>
* Compose file reference: <https://docs.docker.com/reference/compose-file/> (`depends_on` with `restart: true`: <https://docs.docker.com/reference/compose-file/services/#depends_on>)
* How CasaOS's Compose restarts an app (only `restart: true` dependencies keep their order): <https://github.com/docker/compose/blob/v2.23.3/pkg/compose/restart.go>, and the dependency label it reads back: <https://github.com/docker/compose/blob/v2.23.3/pkg/compose/compose.go>
* qBittorrent's move of the web UI settings to `[WebUI]` (migration 11): <https://github.com/qbittorrent/qBittorrent/blob/master/src/app/upgrade.cpp>
* FlareSolverr's `PORT` variable: <https://github.com/FlareSolverr/FlareSolverr#environment-variables>
* Gluetun's own ports inside its network: control server 8000 <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md>, health server 9999 <https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/healthcheck.md>
* Output style: community-scripts/ProxmoxVE <https://github.com/community-scripts/ProxmoxVE> (MIT)
