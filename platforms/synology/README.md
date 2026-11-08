# Synology DSM (Container Manager)

Installs this repository's stack (Gluetun VPN gateway, qBittorrent, Jackett, FlareSolverr, FileBrowser) on a Synology NAS with **DSM 7.2 or later**, as a **Container Manager project** you can see and manage in DSM.

One command over SSH does all of this:

- puts the repository in a project folder, by default `/volume1/docker/torrent-stack`;
- writes `.env` with absolute paths, the user id (PUID) of the DSM user you choose, PGID 100 (DSM's `users` group), your time zone, and your VPN and qBittorrent settings;
- seeds qBittorrent's password and the Jackett API key and search plugin, so you can log straight in to qBittorrent;
- adds the folder to Container Manager as the project `torrent-stack`;
- loads the `tun` kernel module now, and creates a Task Scheduler boot task (**Torrent stack boot**) that loads it at every boot and restarts the stack if DSM's own boot start left it half up;
- starts the stack, once the VPN keys are filled in, and shows you FileBrowser's first-run password (FileBrowser makes its own; see [FileBrowser](#filebrowser)).

The security property is the same as everywhere else: qBittorrent, Jackett and FlareSolverr live inside Gluetun's network (`network_mode: service:gluetun`), so they can only reach the internet through the VPN. If Gluetun or the VPN is down, they have no internet at all.

## Before you start

You need:

1. **DSM 7.2 or later** (Control Panel > Info Center). DSM 7.3 and 7.4 should work the same way (not tested).
2. **Container Manager** from Package Center. Installing it creates the `docker` shared folder. Container Manager 24.0.2-1543 or later is best (it has the `docker compose` command); older versions work with their `docker-compose`.
3. **SSH** turned on: Control Panel > Terminal & SNMP > Terminal > tick **Enable SSH service**.
4. **A shared folder for downloads**, for example `downloads` (Control Panel > Shared Folder > Create). The installer only makes folders *inside* shared folders; it never creates a shared folder itself. Keep the downloads apart from the project folder: the installer refuses a downloads folder inside the project folder, or a project folder inside the downloads. Folder names may only use letters, digits, `.`, `_` and `-` (no spaces).
5. **A DSM user for the apps.** The apps run as this user and own what they download. A dedicated user is best, for example `torrents` (Control Panel > User & Group > Create). Give it **Read/Write** on the `docker` and `downloads` shared folders (Control Panel > Shared Folder > select the folder > Edit > Permissions). Your own user also works. Do not give Read/Write on the `docker` shared folder to anyone else: Container Manager runs what is in there as root.
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
   | qBittorrent username and password | Leave the password empty to have one generated (it is printed at the end). |

4. Check the summary, answer **Y**, and wait. The first start downloads the images, which takes a few minutes.

5. Open the web UIs (the installer prints the addresses):

   - qBittorrent: `http://<nas-ip>:8090`
   - Jackett: `http://<nas-ip>:9117`
   - FileBrowser: `http://<nas-ip>:8081`

   qBittorrent uses the login you entered; the password is also in `.env` (`QBITTORRENT_PASSWORD`). FileBrowser's login is user `admin` with the first-run password the installer prints at the end. FileBrowser asks you to choose a new one when you first log in. See [FileBrowser](#filebrowser).

To see every step without changing anything, add `--dry-run`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)" install.sh --dry-run
```

It prints the `.env` it would write (secrets masked), every command, and every request it would send to Container Manager and Task Scheduler.

## What it creates

| What | Where |
|---|---|
| The repository's files, `compose.yaml`, `.env` (all owned by root and changeable only by root; `.env` also unreadable for others, mode 600) | `/volume1/docker/torrent-stack` |
| App configs (qBittorrent, Jackett, FlareSolverr, FileBrowser owned by your DSM user; Gluetun by root) | `/volume1/docker/torrent-stack/configs` |
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

`--apply` checks `.env` with Docker Compose, re-seeds qBittorrent and Jackett (stopping qBittorrent first, so it cannot write its old password back), starts or updates the stack, and makes sure the apps are inside Gluetun's network. It refuses an `.env` whose downloads folder is inside the project folder (or around it).

The repository's web `.env` editor (`scripts/setup.sh`) needs a Python with the `venv` and `ensurepip` modules, which DSM's built-in `python3` does not have; the installer only mentions it if it finds one.

## First-run seeding

The seeding is the repository's own seeding CLI (`scripts/env-editor/seed_configs.py`), the same code the env-editor runs on **Apply**, limited to qBittorrent (password hash, Jackett search plugin) and Jackett (API key). DSM 7 comes with `python3` (Python 3.8 according to user reports, without pip), and that is all these two need, so the installer runs the CLI with it. It reads the passwords from `.env` as root, then switches to the app user (`PUID:PGID`) before it writes anything, so a link planted in an app's config folder can never make root overwrite another file. None of the passwords is put on a command line.

If DSM's `python3` cannot run it, the installer uses a throwaway `python:3.14.9-slim-trixie` container (pinned by tag and digest) instead. Nothing is installed into that container; the project folder and `.env` are mounted into it read-only, and only the configs folder is writable. Both ways need internet access once, to download the Jackett search plugin for qBittorrent; the download is checked against the commit and sha256 pinned in `native/versions.env` and refused if it differs.

The CLI's third seeder, FileBrowser's admin login, is not used here, because the current FileBrowser image never reads the file it writes (next section).

## FileBrowser

The current FileBrowser image (`ghcr.io/gtsteffaniak/filebrowser:stable`, v2.0.2-stable when this was written) behaves differently from what this repository's `compose.yaml` and seeding CLI expect. This affects every Docker platform of the repository, and a fix in `compose.yaml` has been asked for. Until then, on DSM:

- **Login:** user `admin`, with a **first-run password** that FileBrowser makes itself and writes to its log. The installer reads it from there and prints it (`FileBrowser login: admin / ...`). FileBrowser asks you to choose a new password when you first log in. To see the first-run password again: Container Manager > Container > `torrent-stack-filebrowser-1` > Details > Log, the line `Generated initial admin password`, or over SSH:

  ```bash
  docker logs torrent-stack-filebrowser-1 2>&1 | grep -i "initial admin password"
  ```

- **Its users and settings live inside the container**, not in `configs/filebrowser` (the image keeps them in `/home/filebrowser/data`). Stopping and starting keeps them. When the container is **recreated** (`install.sh --update`, or Clean and Build in Container Manager), FileBrowser starts over with a new first-run password, shown in its log the same way.
- **It cannot change your downloads.** The image runs as its own user (uid 1000), not as your DSM user, so it can show the downloads folder but cannot upload, rename or delete anything in it. Use File Station for that.

## Updates

Container Manager has no automatic updater: it marks images with a newer `latest` version, but you rebuild yourself. This installer leaves the stack's own Watchtower off (`COMPOSE_PROFILES=` empty) and gives you one command that updates the repository files, pulls new images and recreates the containers in the right order:

```bash
bash /volume1/docker/torrent-stack/platforms/synology/install.sh --update
```

It downloads a fresh copy of the repository (with `git` if the Git Server package is installed, otherwise as a `.tar.gz` with `curl`) and copies its files over the project folder. `.env`, `.env.bak`, `configs/` and `downloads/` are never touched. The project folder is deliberately not a git checkout: `configs/` holds two files git tracks, which the seeding and the apps rewrite, and that would make every later `git pull` fail. If you cloned the repository with git yourself (the main README's way) and then ran this installer, `git status` will list the repository files as changed after an update. That is expected; keep using `--update`, not `git pull`. Add `--dry-run` to see what an update would change, including the request it would send to Container Manager.

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
- **The boot log says "only loaded tun" or "is not root-only"**: the boot task found `boot.sh`, `compose.yaml`, `.env` or `update-qbittorrent.sh` changeable by someone other than root (or missing), so it did not run them as root. See [the boot task](#the-tun-device-and-the-boot-task); `install.sh --update` puts the files back as root-only.
- **"holds another application's compose.yaml"**: the project folder you gave belongs to another Container Manager project. Pick an empty or new folder, or the folder of this stack.
- **"is an older copy of this repository"**: you cloned the repository there earlier (the main README's way). The installer replaces its repository files with a fresh download and keeps `.env` and `configs/`. If your `.env` keeps the downloads in `./downloads`, move them to a folder outside the project folder first: the installer asks for one.
- **The web UIs do not open from other computers**, and you use DSM's firewall (Control Panel > Security > Firewall): allow the ports (8090, 9117, 8081 by default) or your LAN.
- **The Gluetun log says it uses a userspace WireGuard implementation**: normal on DSM, whose kernels have no WireGuard module. It works, using more CPU.
- **Gluetun misbehaves after an image update**: `compose.yaml` follows Gluetun's `latest` tag, and Synology guides have pinned specific Gluetun versions when a release misbehaved on DSM. `UPSTREAMS.md` in the repository explains how to pin a version.

## Limitations

- The Container Manager and Task Scheduler requests are the ones DSM's web UI sends (`SYNO.Docker.Project` and `SYNO.Core.EventScheduler`, called locally as root with `synowebapi`). Synology does not document them publicly. The parameters follow the third-party documentation and field reports listed below. If your DSM answers differently, the installer prints the by-hand steps and carries on, and if Container Manager writes `compose.yaml` differently from the repository's, the installer puts the repository's version back.
- `--uninstall` without `--purge` does not remove the Container Manager project entry or the boot task: the project's Delete can remove the folder's files, so they are left for you to remove in DSM. `--purge` removes both through the API (`SYNO.Docker.Project delete`, `SYNO.Core.EventScheduler delete`); neither request has been tried on a real DSM.
- FileBrowser makes its own first-run password, keeps its users inside its container and cannot change the downloads (see [FileBrowser](#filebrowser)). That needs a change in the repository's `compose.yaml`.
- The boot task's "root-only" check reads ordinary file ownership and permissions. DSM's shared-folder permissions (ACLs) can let others change a file whatever those say; that is why only administrators and the app user should have Read/Write on the `docker` shared folder.
- Folder paths may only use letters, digits, `.`, `_`, `-` and `/`, because the project folder ends up in the command the boot task runs as root.
- A project folder on an encrypted shared folder that is not mounted at boot leaves the boot task without its script until you unlock it (it still loads `tun`).
- The web `.env` editor does not run on DSM's built-in Python (see Changing settings).
- `JACKETT_PORT` and `FLARESOLVERR_PORT` must stay 9117 and 8191. The repository's `compose.yaml` publishes each port as the same number on the NAS, and Jackett and FlareSolverr always listen on 9117 and 8191 inside their containers, so any other value would publish a port nothing answers on. The installer and `--apply` refuse other values, and refuse a `QBIT_WEBUI_PORT` of 8000, 8191, 9117 or 9999 (used inside Gluetun's network). This needs a change in `compose.yaml` to lift.
- No Discord webhook is set by default (the `.env.example` placeholder becomes empty). Give one with `TS_SCRIPT_NOTIFY_URL_FILE=/root/webhook.txt` (a `chmod 600` file) or put it in `.env` as `SCRIPT_NOTIFY_URL`.

## What was tested, and what was not

Tested (`platforms/synology/tests/run-tests.sh`):

- `bash -n` and `shellcheck -S warning` on `install.sh`, `boot.sh`, the test runner and the shell shims: clean.
- 237 checks (all passed on the last run) in a throwaway, privileged Debian 13 Incus container shaped like DSM 7.2: `/etc.defaults/VERSION`, the `docker` and `downloads` shared folders, a DSM user (uid 1026, group 100), `/lib/modules/tun.ko`, a `python3` without bcrypt or pip, and shims in DSM's own paths for `synowebapi`, `synopkg`, `docker`/`docker-compose` and `insmod`. The docker shim runs the real docker-compose for every compose call it validates and runs containers as real processes in real network namespaces. The `synowebapi` shim only accepts JSON-encoded parameters and DSM's task-name rules. Covered:
  - refusals: not DSM, DSM 7.1, Container Manager missing or stopped, Docker down, unknown user, folders outside or at the top of a shared folder, a missing shared folder;
  - folders: a downloads folder inside the project folder, around it, equal to it, the whole `docker` shared folder, or reached through a symlink, are all refused before anything is written; so are folder names with brackets, spaces or `/./`;
  - another application's folder (its own `compose.yaml` and `.env`): install, `--apply` and `--purge` refuse it and leave its files alone;
  - `--dry-run` changes nothing and shows the requests;
  - a fresh install without VPN keys (files, modes, root-only repository files, ownership, seeding with `python3` verified against the password, no FileBrowser file, one project, one boot task, not started);
  - a re-run with keys and a password with spaces, quotes, a backslash and `$`: read back exactly by Compose, matching hash, nothing duplicated, all five services up, the apps inside Gluetun's network namespace, no secret on any command line or in any API request, FileBrowser's first-run password read from its log;
  - `--apply`, apps left outside Gluetun's network, every `boot.sh` path (tun via insmod or `mknod`, half-started stack, stale apps, stopped by hand, placeholders, a `compose.yaml` others could change, dry run);
  - the boot task's own script, run with `sh` as Task Scheduler would: it loads tun and runs a root-only `boot.sh`, and refuses (logging why, still loading tun) a `boot.sh` owned by another user, group- or world-writable, or put back by someone after the folder was moved away; a task pasted by hand with other spacing is recognised;
  - an older checkout of the repository (git clone without `platforms/`, owned by the user, `.env` copied from `.env.example`): its files are refreshed from a download, `.env` and the runtime config are kept, PGID 1000 becomes 100, the boot task is created;
  - downloading the repository with git (from a local git server, not GitHub) and as a `.tar.gz` with curl (no git); the project folder is never a git checkout, and `--update` works after upstream changed a tracked config seed, keeping the seeded qBittorrent config;
  - the standalone `docker-compose`, no `jq`, the seeding-container fallback (`.env` read-only, nothing installed) and both seeding paths failing, `--update` and `--update --dry-run` (shows the Container Manager update it would send), API failures, a mangled `compose.yaml`, name and folder conflicts, an existing boot task, a missing write permission, files that cannot be made root-only, `--uninstall`, and `--purge` (which also removes the boot task, and keeps the folder when the downloads are inside it, including `DOWNLOADS_PATH=./downloads`).
- The generated project passes `docker compose config -q` with Compose v2.9.0 and v2.20.1 (versions Container Manager has shipped) and v5.6.1, with `.env` read implicitly the way Container Manager runs Compose.
- 16 checks (all passed) with the host's real Docker:
  - the seeding container exactly as `install.sh` runs it (`python:3.14.9-slim-trixie`, nothing installed, `.env` read-only, which is checked) seeds qBittorrent (the hash matches the password) and Jackett, and writes no FileBrowser file;
  - the seeding CLI also runs on Python 3.8 (`python:3.8.20-slim-bookworm`), the version DSM 7 ships;
  - the real FileBrowser image (`ghcr.io/gtsteffaniak/filebrowser:stable`, v2.0.2-stable), started as on DSM: `install.sh`'s own code finds its first-run password in the log, FileBrowser accepts it (and asks for a new one) and refuses a wrong one, it reads its settings from `/home/filebrowser/data`, and it cannot write to downloads owned by the DSM user;
  - the write check names only the folder it cannot write.

  (On the test host this needed `--network host` and the host's proxy CA, which is test-only.)

Not tested:

- **No real Synology NAS or DSM.** No DSM machine or VM was available (the test host has no KVM).
- The `SYNO.Docker.Project` and `SYNO.Core.EventScheduler` requests (create, get, update, delete) against real DSM: whether the project then appears and behaves in Container Manager exactly like one made in the UI, and whether a task made this way can be edited in Task Scheduler (Synology says only tasks created on that page can be).
- Whether DSM's Task Scheduler runs the one-line task script with `sh` or `bash` (it is written to work with either), and real boot timing on DSM, a real `insmod` of DSM's `tun.ko`, and Container Manager's Build/Start/Stop/Clean/Delete buttons on this stack.
- DSM's shared-folder ACLs: permissions they deny (simulated with ordinary file modes), and what `stat` shows for files whose ACLs let others write (the root-only check reads ordinary ownership and modes only).
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
- What kind of CPU does my NAS have: <https://kb.synology.com/en-global/DSM/tutorial/What_kind_of_CPU_does_my_NAS_have>
- Developer guide, Docker Project worker (Container Manager projects are compose folders with `compose.yaml`): <https://help.synology.com/developer-guide/resource_acquisition/docker-project.html>

Gluetun and Docker:

- Gluetun wiki, TUN device errors (`insmod /lib/modules/tun.ko`): <https://github.com/qdm12/gluetun-wiki/blob/main/errors/tun.md>
- Gluetun wiki, VPN port forwarding: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>
- Compose file `name` element: <https://docs.docker.com/reference/compose-file/version-and-name/>
- Docker Compose releases used in the tests: <https://github.com/docker/compose/releases/tag/v2.9.0>, <https://github.com/docker/compose/releases/tag/v2.20.1>
- FileBrowser Quantum (the `gtsteffaniak/filebrowser` image: settings in `/home/filebrowser/data`, `FILEBROWSER_CONFIG`, first-run admin password): <https://github.com/gtsteffaniak/filebrowser>

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
