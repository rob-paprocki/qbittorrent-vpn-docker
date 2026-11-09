# Synology DSM (Container Manager)

Installs this repository's stack (Gluetun VPN gateway, qBittorrent, Jackett, FlareSolverr, FileBrowser) on a Synology NAS with **DSM 7.2 or later**, as a **Container Manager project** you can see and manage in DSM.

One command over SSH does all of this:

- puts the repository in a project folder, by default `/volume1/docker/torrent-stack`;
- writes `.env` with absolute paths, the user id (PUID) of the DSM user you choose, PGID 100 (DSM's `users` group), your time zone, and your VPN and qBittorrent settings;
- seeds qBittorrent's password and the Jackett API key and search plugin, so you can log straight in to qBittorrent;
- prepares FileBrowser's folder, so FileBrowser keeps its users and settings; it logs in as `admin` with the same password as qBittorrent (see [FileBrowser](#filebrowser));
- adds the folder to Container Manager as the project `torrent-stack`;
- loads the `tun` kernel module now, and creates a Task Scheduler boot task (**Torrent stack boot**) that loads it at every boot and restarts the stack if DSM's own boot start left it half up;
- starts the stack, once the VPN keys are filled in.

The security property is the same as everywhere else: qBittorrent, Jackett and FlareSolverr live inside Gluetun's network (`network_mode: service:gluetun`), so they can only reach the internet through the VPN. If Gluetun or the VPN is down, they have no internet at all.

## Before you start

You need:

1. **DSM 7.2 or later** (Control Panel > Info Center). DSM 7.3 and 7.4 should work the same way (not tested).
2. **Container Manager** from Package Center. Installing it creates the `docker` shared folder. Container Manager 24.0.2-1543 or later is best (it has the `docker compose` command); older versions work with their `docker-compose`.
3. **SSH** turned on: Control Panel > Terminal & SNMP > Terminal > tick **Enable SSH service**.
4. **A shared folder for downloads**, for example `downloads` (Control Panel > Shared Folder > Create). The installer only makes folders *inside* shared folders; it never creates a shared folder itself. Keep the downloads apart from the project folder: the installer refuses a downloads folder inside the project folder, or a project folder inside the downloads. Folder names may only use letters, digits, `.`, `_` and `-` (no spaces).
5. **A DSM user for the apps.** The apps run as this user and own what they download. A dedicated user is best, for example `torrents` (Control Panel > User & Group > Create). Give it **Read/Write** on the `docker` and `downloads` shared folders (Control Panel > Shared Folder > select the folder > Edit > Permissions). Your own user also works. Do not give Read/Write on the `docker` shared folder to anyone else: Container Manager runs what is in there as root. (FileBrowser runs as its own user with the `users` group; to upload, rename or delete in FileBrowser, that group needs Read/Write on the downloads shared folder. The installer checks it and tells you; see [FileBrowser](#filebrowser).)
6. **A VPN provider that Gluetun supports, with port forwarding**: ProtonVPN, Private Internet Access, Perfect Privacy or PrivateVPN. Others connect, but nothing will seed (see the main [README](../../README.md)).
7. An Intel/AMD (x86_64) or ARM64 NAS. Older 32-bit ARM models cannot run all the images.

## Install

1. From your computer, log in to the NAS with an administrator account, then become root:

   ```bash
   ssh youradmin@192.168.1.20      # your NAS address; add -p PORT if you changed it
   sudo -i                         # enter the same password again
   ```

2. Run the installer:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)"
   ```

3. Answer the questions (press Enter to take the value in brackets):

   | Question | What to enter |
   |---|---|
   | Project folder | Where the stack lives. Default `/volume1/docker/torrent-stack`. An empty or new folder, or one with an earlier install of this stack. |
   | Downloads folder | A folder inside a shared folder, for example `/volume1/downloads`, and not inside the project folder. `incomplete/` is made inside it. |
   | DSM user name | The user from step 5 above. Its id becomes `PUID`; `PGID` is 100. |
   | Time zone | For example `Europe/Berlin`. |
   | VPN provider, protocol, keys, address, countries | From your VPN provider's WireGuard (or OpenVPN) config. Leave the key empty to fill it in later; the stack then waits. |
   | qBittorrent username and password | Leave the password empty to have one generated (it is printed at the end). At least 8 characters and at most 72 bytes, and not `admin`: FileBrowser's user `admin` gets the same password, and FileBrowser cannot use a longer one (see [FileBrowser](#filebrowser), "Password limits"). |

4. Check the summary, answer **Y**, and wait. The first start downloads the images, which takes a few minutes.

5. Open the web UIs (the installer prints the addresses):

   - qBittorrent: `http://<nas-ip>:8090`
   - Jackett: `http://<nas-ip>:9117`
   - FileBrowser: `http://<nas-ip>:8081`

   qBittorrent uses the login you entered; the password is also in `.env` (`QBITTORRENT_PASSWORD`). FileBrowser's login is user **`admin`** with **the same password**. See [FileBrowser](#filebrowser).

   These are the default ports on the NAS. To use others, give `TS_QBIT_WEBUI_PORT`, `TS_JACKETT_PORT`, `TS_FLARESOLVERR_PORT` or `TS_FILEBROWSER_PORT` when you run the installer, or change `QBIT_WEBUI_PORT`, `JACKETT_PORT`, `FLARESOLVERR_PORT` or `FILEBROWSER_PORT` in `.env` and run `--apply`. Each needs its own port. Inside the stack Jackett always listens on 9117 and FlareSolverr on 8191, whatever you pick, so qBittorrent's port cannot be 9117, 8191, 8000 or 9999 (those are taken inside Gluetun's network).

To see every step without changing anything, add `--dry-run`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)" install.sh --dry-run
```

It prints the `.env` it would write (secrets masked), every command, and every request it would send to Container Manager and Task Scheduler.

## What it creates

| What | Where |
|---|---|
| The repository's files, `compose.yaml`, `.env` (all owned by root and changeable only by root; `.env` also unreadable for others, mode 600) | `/volume1/docker/torrent-stack` |
| App configs (qBittorrent, Jackett, FlareSolverr owned by your DSM user; Gluetun by root) | `/volume1/docker/torrent-stack/configs` |
| FileBrowser's folder: its database (users, settings, shares). The folder is owned by your DSM user and the `users` group, mode `drwxrwsr-x` (2775), so FileBrowser can write it through the group; what FileBrowser writes there stays its own | `/volume1/docker/torrent-stack/configs/filebrowser` |
| Downloads | the folder you chose, plus `incomplete/` |
| Container Manager project `torrent-stack` | Container Manager > Project |
| Task Scheduler boot task **Torrent stack boot** (runs as root at boot-up) | Control Panel > Task Scheduler |
| Boot task log | `/var/log/torrent-stack-boot.log` |
| A previous `.env`, when you re-run the installer | `.env.bak` next to it |

## The tun device and the boot task

Gluetun needs the `/dev/net/tun` device. DSM does not always load the `tun` kernel module at boot, and without the device Docker will not create or start the Gluetun container. Loading it with `insmod /lib/modules/tun.ko` from a root Task Scheduler task set to **Boot-up** is the usual fix on Synology (Gluetun's own wiki gives the same command), and it is what the installer sets up. The task and the script it runs both survive DSM updates: DSM keeps its Task Scheduler tasks, and the script is `platforms/synology/boot.sh` in your project folder on the data volume, not in DSM's system partition.

The task also fixes a second, Synology-specific problem. At boot, Container Manager starts containers one at a time and ignores `depends_on`. qBittorrent, Jackett and FlareSolverr can then fail to start because Gluetun was not up yet, and Docker never retries a container that failed to start. So, after loading `tun`, `boot.sh`:

1. waits for Container Manager, then two minutes for its own boot start to finish;
2. if the stack is only half up, runs `docker compose up -d` for it (which starts Gluetun first and waits until it is healthy);
3. recreates any app that is running outside Gluetun's current network (that happens when Gluetun restarted on its own).

It leaves the stack alone when you stopped it yourself (Container Manager > Project > Stop), when it has no containers, and when the VPN keys are still the placeholders.

**Why the task does not simply run `boot.sh`.** The task runs as root, and `boot.sh` lives in a shared folder. Anyone who can write to that shared folder could rename the project folder, or wait until you delete it, put their own `boot.sh` at the same path, and have it run as root at the next boot. So the task's script (one line, which you can read in Task Scheduler > Edit > Task Settings) does this:

1. it loads `tun` itself (`insmod /lib/modules/tun.ko` when `/dev/net/tun` is missing), so that much always works;
2. it runs `boot.sh` only if root owns it and neither its group nor anyone else may change it;
3. otherwise it writes one line to the log (`... is missing, not owned by root, or writable by others; only loaded tun`) and stops.

`boot.sh` in turn only runs `docker compose` when `compose.yaml`, `.env` and `update-qbittorrent.sh` are root-only in the same way. The installer makes the repository's files root-only, and warns (`These files are not root-only`) if something still lets others change them. If you see either message, run `install.sh --update`, and check with `ls -l /volume1/docker/torrent-stack` that the files belong to root.

To check it: Control Panel > Task Scheduler should list **Torrent stack boot** (user root, event Boot-up). Select it and click **Run** to try it now, and read `/var/log/torrent-stack-boot.log`. You can also run it yourself: `bash /volume1/docker/torrent-stack/platforms/synology/boot.sh --now` (`--dry-run` only reports).

## Managing it in Container Manager

Open **Container Manager > Project > torrent-stack**: it shows the containers, their logs (Container > select > Details > Log) and resource use.

- **Start, Stop and Restart the whole project** with the **Action** menu. Do not start, stop or restart `gluetun`, `qbittorrent`, `jackett` or `flaresolverr` one by one on the Container page: the apps live inside Gluetun's network, and when Gluetun restarts alone they keep running with no network at all (Container Manager may also say "Container must join at least one network"). If that happened, run `install.sh --apply` or Restart the project.
- **Never change the network settings of `qbittorrent`, `jackett` or `flaresolverr` in Container Manager**, even if it says "Container must join at least one network". Adding a network to them replaces `network_mode: service:gluetun`, and their traffic would then leave the NAS outside the VPN. Restart the whole project, or run `install.sh --apply`, instead.
- **Do not edit the project's YAML in Container Manager.** Settings live in `.env`; `compose.yaml` stays as the repository ships it.
- **Clean** (`docker-compose down`) removes the containers and their images; **Build** then **Start**, or `install.sh --apply`, brings them back. Your configs and downloads are bind mounts and are not touched.
- **Delete** removes the project entry, and Synology says it deletes "the data of this project". Copy `configs/` and `.env` somewhere first if you ever use it. To uninstall, use `--uninstall` below instead.
- **Web portal**: leave it off; the apps have their own ports.

## Changing settings

The easy way: run the installer again (the same one-liner, or `bash /volume1/docker/torrent-stack/platforms/synology/install.sh`). It reads your current `.env`, offers it as the defaults, and only changes what you change. Secrets you leave empty are kept.

By hand: edit `.env` as root over SSH (it is root-only, so File Station and the Text Editor package cannot open it), then apply it:

```bash
vi /volume1/docker/torrent-stack/.env
bash /volume1/docker/torrent-stack/platforms/synology/install.sh --apply
```

`--apply` checks `.env` with Docker Compose, re-seeds qBittorrent and Jackett (stopping qBittorrent first, so it cannot write its old password back), checks again that the apps can write to their folders, starts or updates the stack, and makes sure the apps are inside Gluetun's network. It refuses an `.env` whose downloads folder is inside the project folder (or around it), two web UIs on the same port, a `QBITTORRENT_USER` or `QBITTORRENT_PASSWORD` still set to the `.env.example` placeholder, and a `QBITTORRENT_PASSWORD` that FileBrowser cannot use (shorter than 8 characters, longer than 72 bytes, or `admin`; see [FileBrowser](#filebrowser), "Password limits").

A new `QBITTORRENT_PASSWORD` is also FileBrowser's new `admin` password: Compose recreates the FileBrowser container with it, and its users and settings stay.

The repository's web `.env` editor (`scripts/setup.sh`) needs a Python with the `venv` and `ensurepip` modules, which DSM's built-in `python3` does not have; the installer only mentions it if it finds one. If you use it: it accepts a qBittorrent password from 5 bytes, while this installer's `--apply` and `--update` need at least 8 characters, so a shorter one saved there stops the next `--apply` until you choose a longer one. It also refuses a qBittorrent password with `$`, also one this installer wrote, because it writes `.env` again in double quotes, where Docker Compose expands `$name`; keep `$` out of the other values too while you use it.

## First-run seeding

The seeding is the repository's own seeding CLI (`scripts/env-editor/seed_configs.py`), the same code the env-editor runs on **Apply**, limited to qBittorrent (password hash, Jackett search plugin) and Jackett (API key). The search plugin is pointed at `http://127.0.0.1:9117`: qBittorrent shares Gluetun's network with Jackett, which listens on 9117 there whatever `JACKETT_PORT` (the port on the NAS) is. DSM 7 comes with `python3` (Python 3.8 according to user reports, without pip), and that is all these two need, so the installer runs the CLI with it. It reads the passwords from `.env` as root, then switches to the app user (`PUID:PGID`) before it writes anything, so a link planted in an app's config folder can never make root overwrite another file. None of the passwords is put on a command line.

If DSM's `python3` cannot run it, the installer uses a throwaway `python:3.14.9-slim-trixie` container (pinned by tag and digest) instead. Nothing is installed into that container; the project folder and `.env` are mounted into it read-only, and only the configs folder is writable. The installer needs that image either way (it pulls it once if it is missing), because it also runs its write checks in it: can the apps' user, and can FileBrowser, write to their folders. Those check containers get no network. Both ways need internet access once, to download the Jackett search plugin for qBittorrent; the download is checked against the commit and sha256 pinned in `native/versions.env` and refused if it differs.

FileBrowser needs no seeding: `compose.yaml` gives it its password directly (next section).

## FileBrowser

FileBrowser (`ghcr.io/gtsteffaniak/filebrowser:stable`, FileBrowser Quantum v2.0.2-stable when this was written) shows your downloads folder in the browser, at `http://<nas-ip>:8081`.

- **Login:** user **`admin`**, password **`QBITTORRENT_PASSWORD`** from `.env` (the qBittorrent password). `compose.yaml` passes it as `FILEBROWSER_ADMIN_PASSWORD`, and FileBrowser sets the `admin` user's password from it **every time it starts**. The user name is always `admin`, even if your qBittorrent user has another name.
- **To change the password**, change the qBittorrent password: run the installer again, or edit `QBITTORRENT_PASSWORD` in `.env` and run `install.sh --apply`. A password you change in FileBrowser's own settings works only until FileBrowser next starts; then the one from `.env` is back. Other users you add in FileBrowser keep their passwords.
- **Password limits.** Because the qBittorrent password is also FileBrowser's `admin` password, the installer refuses one that FileBrowser (v2.0.2-stable) cannot use: in the wizard, with `--unattended` (`TS_QBITTORRENT_PASSWORD_FILE` or the existing `.env`), and in `.env` for `--apply` and `--update`, which then change nothing. It must be:
  - **at most 72 bytes.** FileBrowser stores the password as a bcrypt hash, and bcrypt takes no more. With a longer one, FileBrowser does not start on a new database and keeps its old password on an existing one. Bytes, not letters: A-Z, digits and ASCII punctuation take 1 byte each, accented letters 2, the euro sign 3, most emoji 4.
  - **not `admin`.** FileBrowser ignores that value: a new database gets a random password of its own, an existing one keeps its old password.
  - **at least 8 characters.** That is this installer's own minimum. FileBrowser's is 5 bytes: on a later start it refuses to set a shorter password and keeps its old one.
- **What it keeps:** its database, `configs/filebrowser/database.sqlite`, holds its users, settings and shares. It survives restarts, reboots, `install.sh --update`, and Clean and Build in Container Manager. Its configuration file is the image's own (`/home/filebrowser/data/config.yaml`: the downloads appear under `/srv/downloads`, password login, passwords of at least 5 bytes).
- **Its folder.** The image always runs as its own user, uid 1000, whatever `PUID` is; `compose.yaml` adds the `PGID` group (100, `users`) so it can use the stack's folders through that group. The installer makes `configs/filebrowser` owned by your DSM user and the `users` group with mode `drwxrwsr-x` (2775: the group may write, and new files keep the group). On DSM, setting a mode with `chmod` switches a folder from DSM's own (Windows ACL) permissions to plain Unix permissions ([Synology](https://kb.synology.com/en-us/DSM/tutorial/Revert_to_Windows_ACL_permission)). That is intended here, and only for this one folder: otherwise FileBrowser would only get in if the `users` group had Read/Write on the whole `docker` shared folder. The installer never changes the owner of the files FileBrowser writes there (if they belonged to your DSM user, FileBrowser could no longer write its own database).
- **Changing your downloads (upload, rename, delete).** FileBrowser can do that only where its group may write. The installer does **not** `chmod` your downloads: on DSM that would switch them, and every download moved into them from `incomplete/`, to plain Unix permissions, and change who can reach them over the network. Instead it checks what FileBrowser can do and, if it cannot change the downloads, prints this:

  ```
  [WARN] FileBrowser (uid 1000, group users) cannot change files in /volume1/downloads.
  ```

  To allow it, give the group Read/Write on the shared folder: Control Panel > Shared Folder > select `downloads` > Edit > Permissions > choose **Local groups** in the drop-down > `users` > tick **Read/Write** > Save ([Synology](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_privilege?version=7)). Then run `install.sh --apply`; it checks again. Every DSM user is in the `users` group, so this lets every DSM user change that shared folder too. For a narrower way, create a group (Control Panel > User & Group > Group > Create, for example `torrents`) with only the apps' user in it, give that group Read/Write on the downloads shared folder, and run the installer again with `TS_PGID` set to its number (`grep '^torrents:' /etc/group | cut -d: -f3`). If you leave it as it is, FileBrowser may only show the downloads, or nothing, depending on what the shared folder allows the `users` group; qBittorrent does not need it, and File Station can do the same.
- **Analytics:** FileBrowser Quantum has an anonymous usage report that is **off** until an administrator turns it on in its settings ([source](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/analytics.go)). Leave it off if you do not want it.

## Updates

Container Manager has no automatic updater: it marks images with a newer `latest` version, but you rebuild yourself. This installer leaves the stack's own Watchtower off (`COMPOSE_PROFILES=` empty) and gives you one command that updates the repository files, pulls new images and recreates the containers in the right order:

```bash
bash /volume1/docker/torrent-stack/platforms/synology/install.sh --update
```

First it checks the qBittorrent login in `.env` as `--apply` does: a placeholder, or a password FileBrowser cannot use, stops it before anything is changed (see [FileBrowser](#filebrowser), "Password limits"). Then it downloads a fresh copy of the repository (with `git` if the Git Server package is installed, otherwise as a `.tar.gz` with `curl`) and copies its files over the project folder. `.env`, `.env.bak`, `configs/` and `downloads/` are never overwritten; as with `--apply`, the config folders' owners and FileBrowser's folder mode are set again, and the files FileBrowser keeps (its users and settings) stay as they are. The project folder is deliberately not a git checkout: `configs/` holds two files git tracks, which the seeding and the apps rewrite, and that would make every later `git pull` fail. If you cloned the repository with git yourself (the main README's way) and then ran this installer, `git status` will list the repository files as changed after an update. That is expected; keep using `--update`, not `git pull`. Add `--dry-run` to see what an update would change, including the request it would send to Container Manager.

To run it automatically: Control Panel > Task Scheduler > Create > Scheduled Task > User-defined script, user **root**, a weekly schedule, and as the script `bash /volume1/docker/torrent-stack/platforms/synology/install.sh --update --unattended`.

Avoid Container Manager's per-image **Update** for `gluetun`: it recreates Gluetun alone and leaves the apps without network (the boot task or `--apply` repairs that). Watchtower has the same risk for Gluetun, which is why it stays off here; you can still turn it on with `COMPOSE_PROFILES=watchtower` in `.env` and `--apply`.

## Uninstall

```bash
bash /volume1/docker/torrent-stack/platforms/synology/install.sh --uninstall
```

This stops and removes the containers. The project folder (configs, `.env`) and your downloads stay, and so do the Container Manager project entry (re-running the installer uses it again) and the boot task (with no containers it only loads `tun`).

To remove everything except your downloads:

```bash
bash /volume1/docker/torrent-stack/platforms/synology/install.sh --uninstall --purge
```

This also removes the Container Manager project and the boot task, and deletes the project folder. If DSM does not accept the request to remove the boot task, the installer says so; then delete it yourself: Control Panel > Task Scheduler > select **Torrent stack boot** > Action > Delete. Downloads are never deleted:

- if `.env` names a downloads folder inside the project folder (or around it), for example `DOWNLOADS_PATH=./downloads` from the main README, `--purge` does not delete the folder, the project entry or the boot task, and tells you to move the downloads first;
- a folder that does not hold this stack (no `compose.yaml` with `name: torrent-stack`, next to the repository's files) is never deleted or changed, for example when `TS_STACK_DIR` was mistyped.

## Without questions (advanced)

`--unattended` (or `-y`) takes every answer from environment variables, the existing `.env`, or the defaults. Secrets come from files (first line; `chmod 600` them), never from the command line:

```bash
TS_USER=torrents TS_DOWNLOADS=/volume1/downloads \
TS_WIREGUARD_PRIVATE_KEY_FILE=/root/wg.key TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
TS_QBITTORRENT_PASSWORD_FILE=/root/qbit.pw \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)" install.sh --unattended
```

All variables are listed by `install.sh --help`: `TS_STACK_DIR`, `TS_DOWNLOADS`, `TS_USER` (or `TS_PUID`), `TS_PGID`, `TS_TZ`, `TS_VPN_PROVIDER`, `TS_VPN_TYPE`, `TS_WIREGUARD_ADDRESSES`, `TS_OPENVPN_USER`, `TS_SERVER_COUNTRIES`, `TS_QBITTORRENT_USER`, the four port variables, the `*_FILE` secrets (`TS_WIREGUARD_PRIVATE_KEY_FILE`, `TS_OPENVPN_PASSWORD_FILE`, `TS_QBITTORRENT_PASSWORD_FILE`, `TS_SCRIPT_NOTIFY_URL_FILE`), `TS_SOURCE_DIR` (install from a local checkout), `TS_REF` (branch or tag) and `TS_REPO_URL` (a fork).

## Troubleshooting

- **Gluetun does not start: "error gathering device information ... /dev/net/tun"**: the tun device is missing. Run `bash /volume1/docker/torrent-stack/platforms/synology/boot.sh --tun-only`, then `install.sh --apply`, and check that the boot task exists.
- **qBittorrent, Jackett or FlareSolverr have no network** after something restarted Gluetun: run `install.sh --apply` (or Restart the whole project).
- **The project shows no containers or "stopped" in Container Manager while the web UIs work**: Container Manager may not have noticed containers started from SSH. Select the project, **Action > Build**, then **Start**; it is the same Compose project, so nothing is duplicated.
- **The installer could not add the project or the boot task** (it prints "by hand" steps): follow those steps once in DSM. They do exactly what the installer would have done. Use the project name `torrent-stack` exactly: it is the Compose project name in `compose.yaml`, and another name would start a second copy.
- **"cannot write to"** warning: the DSM user lacks permission on a shared folder. Give it Read/Write (Control Panel > Shared Folder > Edit > Permissions), then `install.sh --apply`.
- **"FileBrowser ... cannot change files in"** warning: see [FileBrowser](#filebrowser), "Changing your downloads". It only matters if you want to upload, rename or delete in FileBrowser.
- **"FileBrowser ... cannot write to its folder"** warning: FileBrowser cannot keep its users and settings. `ls -ld /volume1/docker/torrent-stack/configs/filebrowser` should show `drwxrwsr-x`, your DSM user and `users`; `install.sh --apply` sets that again.
- **FileBrowser does not take your password**: its user is `admin` (not your qBittorrent user name) and its password is `QBITTORRENT_PASSWORD` from `.env`, also after you changed it in FileBrowser (it is put back at every start). Its log (Container Manager > Container > `torrent-stack-filebrowser-1` > Details > Log) should say `Using admin password from FILEBROWSER_ADMIN_PASSWORD environment variable`.
- **The boot log says "only loaded tun" or "is not root-only"**: the boot task found `boot.sh`, `compose.yaml`, `.env` or `update-qbittorrent.sh` changeable by someone other than root (or missing), so it did not run them as root. See [the boot task](#the-tun-device-and-the-boot-task); `install.sh --update` puts the files back as root-only.
- **"holds another application's compose.yaml"**: the project folder you gave belongs to another Container Manager project. Pick an empty or new folder, or the folder of this stack.
- **"is an older copy of this repository"**: you cloned the repository there earlier (the main README's way). The installer replaces its repository files with a fresh download and keeps `.env` and `configs/`. If your `.env` keeps the downloads in `./downloads`, move them to a folder outside the project folder first: the installer asks for one.
- **The web UIs do not open from other computers**, and you use DSM's firewall (Control Panel > Security > Firewall): allow the ports (8090, 9117, 8081 by default) or your LAN.
- **The Gluetun log says it uses a userspace WireGuard implementation**: normal on DSM, whose kernels have no WireGuard module. It works, using more CPU.
- **Gluetun misbehaves after an image update**: `compose.yaml` follows Gluetun's `latest` tag, and Synology guides have pinned specific Gluetun versions when a release misbehaved on DSM. `UPSTREAMS.md` in the repository explains how to pin a version.

## Limitations

- The Container Manager and Task Scheduler requests are the ones DSM's web UI sends (`SYNO.Docker.Project` and `SYNO.Core.EventScheduler`, called locally as root with `synowebapi`). Synology does not document them publicly. The parameters follow the third-party documentation and field reports listed below. If your DSM answers differently, the installer prints the by-hand steps and carries on, and if Container Manager writes `compose.yaml` differently from the repository's, the installer puts the repository's version back.
- `--uninstall` without `--purge` does not remove the Container Manager project entry or the boot task: the project's Delete can remove the folder's files, so they are left for you to remove in DSM. `--purge` removes both through the API (`SYNO.Docker.Project delete`, `SYNO.Core.EventScheduler delete`); neither request has been tried on a real DSM.
- FileBrowser's user is always `admin`, and its password always follows `QBITTORRENT_PASSWORD`: a password changed in FileBrowser itself is put back at its next start. It changes your downloads only once its group has Read/Write on the downloads shared folder, which the installer leaves for you to set (see [FileBrowser](#filebrowser)). qBittorrent creates its files without write access for the group (the image's default umask), so even then FileBrowser may not be able to change everything inside the folders qBittorrent made, depending on how DSM applies the shared folder's permissions to them.
- The boot task's "root-only" check reads ordinary file ownership and permissions. DSM's shared-folder permissions (ACLs) can let others change a file whatever those say; that is why only administrators and the app user should have Read/Write on the `docker` shared folder.
- Folder paths may only use letters, digits, `.`, `_`, `-` and `/`, because the project folder ends up in the command the boot task runs as root.
- A project folder on an encrypted shared folder that is not mounted at boot leaves the boot task without its script until you unlock it (it still loads `tun`).
- The web `.env` editor does not run on DSM's built-in Python (see Changing settings).
- `QBIT_WEBUI_PORT` is the same number on the NAS and inside the stack (qBittorrent's web UI refuses a request for another port), so it cannot be 8000, 8191, 9117 or 9999, which are used inside Gluetun's network. The installer and `--apply` refuse those, and two web UIs on the same port.
- No Discord webhook is set by default (the `.env.example` placeholder becomes empty). Give one with `TS_SCRIPT_NOTIFY_URL_FILE=/root/webhook.txt` (a `chmod 600` file) or put it in `.env` as `SCRIPT_NOTIFY_URL`.

## What was tested, and what was not

Tested (`platforms/synology/tests/run-tests.sh`):

- `bash -n` and `shellcheck -S warning` on `install.sh`, `boot.sh`, the test runner and the shell shims: clean.
- 330 checks (all passed on the last run) in a throwaway, privileged Debian 13 Incus container shaped like DSM 7.2: `/etc.defaults/VERSION`, the `docker` and `downloads` shared folders, a DSM user (uid 1026, group 100), `/lib/modules/tun.ko`, a `python3` without bcrypt or pip, and shims in DSM's own paths for `synowebapi`, `synopkg`, `docker`/`docker-compose` and `insmod`. The docker shim runs the real docker-compose for every compose call it validates and runs containers as real processes in real network namespaces. The `synowebapi` shim only accepts JSON-encoded parameters and DSM's task-name rules. Covered:
  - refusals: not DSM, DSM 7.1, Container Manager missing or stopped, Docker down, unknown user, folders outside or at the top of a shared folder, a missing shared folder;
  - folders: a downloads folder inside the project folder, around it, equal to it, the whole `docker` shared folder, or reached through a symlink, are all refused before anything is written; so are folder names with brackets, spaces or `/./`;
  - another application's folder (its own `compose.yaml` and `.env`): install, `--apply` and `--purge` refuse it and leave its files alone;
  - `--dry-run` changes nothing and shows the requests;
  - a fresh install without VPN keys (files, modes, root-only repository files, ownership, seeding with `python3` verified against the password, the search plugin pointed at `127.0.0.1:9117`, no FileBrowser file, `configs/filebrowser` at 2775 with your user and group 100, the downloads' modes left alone, one project, one boot task, not started). `docker compose config` of the result is checked for FileBrowser: `FILEBROWSER_ADMIN_PASSWORD` equal to the qBittorrent password, the database in `/config`, `/config` being `configs/filebrowser`, `group_add` 100, and the published ports;
  - a re-run with keys and a password with spaces, quotes, a backslash and `$`: read back exactly by Compose (for Gluetun and as FileBrowser's admin password), matching hash, nothing duplicated, all five services up, the apps inside Gluetun's network namespace, no secret on any command line or in any API request, no container log read;
  - ports: other Jackett, FlareSolverr and FileBrowser ports are written to `.env`, published to 9117, 8191 and 80 inside the stack, shown in the printed addresses, and leave the search plugin at `127.0.0.1:9117`; two web UIs on one port, and a qBittorrent port of 9117, are refused, also by `--apply`, as is a password under 8 characters;
  - the [password limits](#filebrowser), in a UTF-8 locale (where bash counts letters, not bytes): `admin`, 7 characters, 73 bytes (37 two-byte letters) and 75 bytes (25 three-byte letters) are refused by the wizard (`TS_QBITTORRENT_PASSWORD_FILE`), leaving `.env` alone; `admin`, 7 characters, 73 bytes and the `.env.example` placeholder in `.env` are refused by `--apply` and by `--update`, which then stop, pull, copy and start nothing; 8 characters and 72 bytes (36 two-byte letters) are accepted, and after `--apply` Compose reads the 72 bytes back exactly, for Gluetun and as FileBrowser's admin password, and qBittorrent's hash matches them;
  - FileBrowser's folder: `--apply` leaves the owner of FileBrowser's own database (uid 1000) alone and sets the folder back to 2775; FileBrowser's write check (uid 1000 with group 100, as the image runs) warns about downloads it cannot change, with the DSM steps, and passes once the group may write; a symlink put in place of `configs/filebrowser` or `incomplete/` does not make root change what it points to;
  - `--apply`, apps left outside Gluetun's network, every `boot.sh` path (tun via insmod or `mknod`, half-started stack, stale apps, stopped by hand, placeholders, a `compose.yaml` others could change, dry run);
  - the boot task's own script, run with `sh` as Task Scheduler would: it loads tun and runs a root-only `boot.sh`, and refuses (logging why, still loading tun) a `boot.sh` owned by another user, group- or world-writable, or put back by someone after the folder was moved away; a task pasted by hand with other spacing is recognised;
  - an older checkout of the repository (git clone without `platforms/`, owned by the user, `.env` copied from `.env.example`): its files are refreshed from a download, `.env` and the runtime config are kept, PGID 1000 becomes 100, the boot task is created;
  - downloading the repository with git (from a local git server, not GitHub) and as a `.tar.gz` with curl (no git); the project folder is never a git checkout, and `--update` works after upstream changed a tracked config seed, keeping the seeded qBittorrent config;
  - the standalone `docker-compose`, no `jq`, the seeding-container fallback (`.env` read-only, nothing installed) and both seeding paths failing, `--update` and `--update --dry-run` (shows the Container Manager update it would send), API failures, a mangled `compose.yaml`, name and folder conflicts, an existing boot task, a missing write permission, files that cannot be made root-only, `--uninstall`, and `--purge` (which also removes the boot task, and keeps the folder when the downloads are inside it, including `DOWNLOADS_PATH=./downloads`).
- The generated project passes `docker compose config -q` with Compose v2.9.0 and v2.20.1 (versions Container Manager has shipped) and v5.6.1, with `.env` read implicitly the way Container Manager runs Compose.
- 49 checks (all passed) with the host's real Docker:
  - the seeding container exactly as `install.sh` runs it (`python:3.14.9-slim-trixie`, nothing installed, `.env` read-only, which is checked) seeds qBittorrent (the hash matches the password) and Jackett, points the search plugin at `127.0.0.1:9117` although `JACKETT_PORT` is 19117, and writes no FileBrowser file;
  - the seeding CLI also runs on Python 3.8 (`python:3.8.20-slim-bookworm`), the version DSM 7 ships;
  - the real FileBrowser image (`ghcr.io/gtsteffaniak/filebrowser:stable`, v2.0.2-stable) started from the repository's own `compose.yaml` (only its network and published port taken away by an override, as this test host's Docker has no bridge networking), with an `.env` as on DSM (PUID 1026, PGID 100, the password with spaces, quotes, a backslash and `$`) and its folders prepared by `install.sh`'s own `fix_ownership`: `admin` logs in with exactly that password and is not asked to change it, a wrong one is refused, its log names `FILEBROWSER_ADMIN_PASSWORD` and no generated password, its database is `configs/filebrowser/database.sqlite` owned by uid 1000 and group 100; a user added in FileBrowser survives a restart and a recreate; a password changed in FileBrowser is replaced by `.env`'s at the next start; after `fix_ownership` again (as `--apply` runs it) and a recreate, there are no read-only database errors; a new `QBITTORRENT_PASSWORD` becomes its password and the old one stops working; it runs as uid 1000 with group 100 added, cannot write downloads that only their owner may write, and can once the group may write; `install.sh`'s FileBrowser write check, run with the real Docker, agrees both times. The password limits on the same container: 36 two-byte letters (72 bytes) become its admin password; with 73 bytes it logs `bcrypt: password length exceeds 72 bytes` and keeps the old password; with 4 characters it logs `password must be at least 5 characters` and keeps the old one; with `admin` the old one stays too, and `admin` does not log in;
  - the write check names only the folder it cannot write.

  (On the test host this needed `--network host` and the host's proxy CA, which is test-only.)

Not tested:

- **No real Synology NAS or DSM.** No DSM machine or VM was available (the test host has no KVM).
- The `SYNO.Docker.Project` and `SYNO.Core.EventScheduler` requests (create, get, update, delete) against real DSM: whether the project then appears and behaves in Container Manager exactly like one made in the UI, and whether a task made this way can be edited in Task Scheduler (Synology says only tasks created on that page can be).
- Whether DSM's Task Scheduler runs the one-line task script with `sh` or `bash` (it is written to work with either), and real boot timing on DSM, a real `insmod` of DSM's `tun.ko`, and Container Manager's Build/Start/Stop/Clean/Delete buttons on this stack.
- DSM's shared-folder ACLs: permissions they deny (simulated with ordinary file modes), and what `stat` shows for files whose ACLs let others write (the root-only check reads ordinary ownership and modes only). In particular: that Read/Write for the `users` group on the downloads shared folder lets FileBrowser (uid 1000, which is no DSM user, with group 100) change the downloads, including the folders qBittorrent creates; that the `chmod 2775` of `configs/filebrowser` behaves on DSM as plain Unix permissions; and what FileBrowser can see in the downloads without that permission.
- DSM's own `python3` (the tests used Debian's, and the Python 3.8 image for the version).
- A real VPN connection (no credentials here), Gluetun on DSM's kernels, ARM models, DSM 7.3/7.4 differences.
- The interactive questions (the tests use `--unattended`, which runs the same code without prompts), and downloading from GitHub itself (the tests download from a local git server and a local `.tar.gz`).

## References

Synology (official):

- Container Manager release notes (versions, required DSM, "docker compose" in the CLI from 24.0.2-1543): <https://www.synology.com/en-global/releaseNote/ContainerManager>
- DSM release notes: <https://www.synology.com/en-global/releaseNote/DSM>
- Container Manager help, Project (create from a path, Build/Start/Stop/Restart/Clean/Delete and the compose commands behind them): <https://kb.synology.com/en-global/DSM/help/ContainerManager/docker_project?version=7>
- Task Scheduler help (triggered tasks, task-name rules, "only tasks created on this page"): <https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_taskscheduler?version=7>
- Sign in with root privilege via SSH (`sudo -i`): <https://kb.synology.com/en-global/DSM/tutorial/How_to_login_to_DSM_with_root_permission_via_SSH_Telnet>
- Assign shared folder permissions: <https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_privilege?version=7>
- Running `chmod` on a file or folder changes it from Windows ACL to Unix permission ("How do I revert file or folder permission from Unix permission to Windows ACL permission?"): <https://kb.synology.com/en-us/DSM/tutorial/Revert_to_Windows_ACL_permission>
- "All users belong to the \"users\" group by default and cannot be removed from this group" (DSM 7.4 specifications, Account, identity and privileges): <https://www.synology.com/en-global/dsm/7.4/software_spec/account_identity_privileges>
- What kind of CPU does my NAS have: <https://kb.synology.com/en-global/DSM/tutorial/What_kind_of_CPU_does_my_NAS_have>
- Developer guide, Docker Project worker (Container Manager projects are compose folders with `compose.yaml`): <https://help.synology.com/developer-guide/resource_acquisition/docker-project.html>

Gluetun and Docker:

- Gluetun wiki, TUN device errors (`insmod /lib/modules/tun.ko`): <https://github.com/qdm12/gluetun-wiki/blob/main/errors/tun.md>
- Gluetun wiki, VPN port forwarding: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>
- Compose file `name` element: <https://docs.docker.com/reference/compose-file/version-and-name/>
- Docker Compose releases used in the tests: <https://github.com/docker/compose/releases/tag/v2.9.0>, <https://github.com/docker/compose/releases/tag/v2.20.1>
- FileBrowser Quantum, source of v2.0.2-stable (the image's version): `FILEBROWSER_ADMIN_PASSWORD` read in `loadEnvConfig` (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/config.go>); the admin user is `auth.adminUsername`, default `admin`, and its password is reset from the configured one when it is neither empty nor `admin` (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/auth.go>); that reset runs in `validateUserInfo` (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/cmd/user.go>), called at every start (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/cmd/root.go>); `FILEBROWSER_DATABASE_PATH` (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/database_paths.go>); a password that is set or changed needs at least `auth.methods.password.minLength` bytes, default 5 (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/password_policy.go>), checked in `UpdateUser` (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/users.go>) but not when the first admin user is made (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/quick_setup.go>; FileBrowser stops if that hash fails); passwords are hashed with bcrypt (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/utils/crypto.go>), whose `GenerateFromPassword` refuses more than 72 bytes (golang.org/x/crypto v0.57.0, the version in `backend/go.mod`: <https://github.com/golang/crypto/blob/v0.57.0/bcrypt/bcrypt.go>); analytics off unless enabled (<https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/analytics.go>). Project: <https://github.com/gtsteffaniak/filebrowser>
- LinuxServer qBittorrent image, umask (`UMASK`, default 022): <https://github.com/linuxserver/docker-qbittorrent#umask-for-running-applications>

Community (not Synology; used for the undocumented parts):

- N4S4/synology-api, `SYNO.Docker.Project` methods and parameters (list, get, create with name/share_path/content, update, delete with preserve_content): <https://n4s4.github.io/synology-api/docs/apis/classes/docker_api>, source <https://github.com/N4S4/synology-api/blob/master/synology_api/docker_api.py>
- N4S4/synology-api, `SYNO.Core.EventScheduler` (create/set parameters, `delete` with `task_name`): <https://github.com/N4S4/synology-api/blob/master/synology_api/event_scheduler.py>
- rjadams82/synology-docker-project-automate (calling `SYNO.Docker.Project` locally with `synowebapi`, JSON-quoted parameters, "the Projects module will not be aware" of plain `docker compose`): <https://github.com/rjadams82/synology-docker-project-automate>
- Dzhuneyt, running a Container Manager project from Task Scheduler with `synowebapi`: <https://dzhuneyt.com/post/synology-cron-docker-compose>
- isaackehle/iac PR 8, a field report on Container Manager's boot order breaking `network_mode: service:` containers, and the `SYNO.Core.EventScheduler` create request: <https://github.com/isaackehle/iac/pull/8>
- DrFrankenstein, qBittorrent with Gluetun in Container Manager (tun boot task, project steps, Gluetun version notes): <https://drfrankenstein.co.uk/qbittorrent-with-gluetun-vpn-in-container-manager-on-a-synology-nas/>
- TRaSH Guides, Synology (PUID from `id`, group `users` 100, shared folder permissions): <https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Synology/>
- Immich docs, Synology (a `.env` next to the compose file in a Container Manager project): <https://docs.immich.app/install/synology/>
- 007revad, Synology scripts (`synopkg status` exit codes, `/etc.defaults/VERSION`, `jq` on DSM 7): <https://github.com/007revad/Synology_ContainerManager_IPv6>, <https://github.com/007revad/Synology_HDD_db>
- Persistent Synology configuration with boot-up tasks on `/volume1`: <https://goral.net.pl/post/persistent-synology-configuration/>
- pip is not installed with DSM's Python: <https://techoverflow.net/2024/06/13/how-to-install-pip-on-synology-nas/>
- DSM 7 ships Python 3.8 as its system `python3` (user reports): <https://synology-forum.de/threads/python-version.137839>, <https://www.blackvoid.club/dsm-7-release-candidate-is-here/>
