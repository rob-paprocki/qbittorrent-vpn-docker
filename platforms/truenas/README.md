# TrueNAS: install as a custom app

`install.sh` runs in the TrueNAS shell. It installs the stack as a TrueNAS **custom app**, built from this repository's `compose.yaml`. The app runs Gluetun (the VPN), qBittorrent with VueTorrent, Jackett, FlareSolverr and FileBrowser. You then manage the app on the **Apps** screen like any other TrueNAS app.

qBittorrent, Jackett and FlareSolverr share Gluetun's network, as they do with plain Docker Compose. Their only way to the internet is the VPN. If Gluetun or the VPN is down, they have no internet at all.

Written for **TrueNAS 25.10** ("Goldeye") and its API.

## Before you start

* **TrueNAS 25.10.** 24.10 and 25.04 also have custom apps and the installer runs there with a warning, but they were not tested. Older versions are refused: they had no Docker-based apps.
* **Apps set up.** In the web UI open **Apps**. If TrueNAS asks you to choose a pool, do that first (**Apps > Configuration > Choose Pool**).
* **A root shell.** Open **System > Shell** in the web UI, or SSH in as your admin user. Then type `sudo -i` (enter your admin password if asked). The prompt should end in `#`.
* **Internet access** from TrueNAS (GitHub, Docker Hub, ghcr.io, lscr.io).
* **A VPN provider with port forwarding**: ProtonVPN, PIA, Perfect Privacy or PrivateVPN. See [Prerequisites](../../README.md#prerequisites) in the main README. You can also install first and add the VPN details later.
* **Free ports** on the TrueNAS address: 8090 (qBittorrent), 9117 (Jackett), 8191 (FlareSolverr) and 8081 (FileBrowser). You can choose others. The installer checks for clashes with other apps, the web UI and anything else listening. (For Jackett and FlareSolverr only the port on the TrueNAS address changes: `compose.yaml` publishes them as `<port>:9117` and `<port>:8191`, because inside the VPN container those two apps always listen on 9117 and 8191. qBittorrent shares that network, so it can't use 9117 or 8191, and the installer refuses them.)
* **Dataset names without `:` or spaces.** ZFS allows `:`, but a Docker volume line can't hold one.

## Install

In the root shell, paste:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)"
```

1. Answer the questions (see the next section). Pressing Enter keeps the value shown in brackets.
2. Wait. The installer:
   * creates the datasets,
   * copies this repository onto the dataset,
   * writes the first-run configs,
   * downloads the five images,
   * and creates the app.

   This takes a few minutes, mostly for the image downloads.
3. At the end it prints the web addresses and the **qBittorrent login**. Write the login down. You can also find it again in the app's YAML (**Apps > torrent-stack > Edit**, look for `QBITTORRENT_PASSWORD`).
4. If you skipped the VPN settings, only FileBrowser runs for now. See [Adding the VPN settings later](#adding-the-vpn-settings-later).

If `whiptail` or `dialog` is installed, the installer uses it for the questions. Otherwise (TrueNAS's build list doesn't include either) they are plain prompts.

## What the wizard asks

| Question | Default | Notes |
|---|---|---|
| App name | `torrent-stack` | Lowercase letters, digits and `-`, up to 40 characters (TrueNAS's rule). |
| Pool | the Apps pool | Only asked when you have more than one pool. |
| Parent dataset | `<pool>/torrent-stack` | Created if missing. If it exists, it must not hold a `source` folder of your own, and the apps must not be able to write to it (see [What it creates](#what-it-creates)). |
| Downloads dataset | `<parent>/downloads` | Created if missing. An existing dataset (for example a media share) works too. The installer then leaves its permissions alone and warns if PUID/PGID can't write to it. |
| PUID / PGID | 568 / 568 | 568 is TrueNAS's built-in `apps` user and group. Use your own user's IDs (`id -u NAME`, `id -g NAME`) if downloaded files should belong to you. |
| VPN settings now? | yes | Provider, WireGuard or OpenVPN, the key or username/password, exit countries. You can say no and add them later. |
| Change ports? | no | The four web UI ports. |
| qBittorrent username | `admin` | FileBrowser's admin user is always `admin`, with the same password (see [First login](#first-login)). |
| qBittorrent password | generated | Leave it empty to get a random 24-character password, shown at the end. A password you type needs 6 characters or more and at most 72 bytes, and cannot be `admin`, because it is also FileBrowser's admin password (see [Password limits](#password-limits)). The wizard asks again until it can be used. |
| Discord webhook | none | For the port-forward notifications of `update-qbittorrent.sh`. |
| Time zone | TrueNAS's | Not asked; taken from **System > General**. Set `TS_TZ` to override. |

## What it creates

**Datasets** (only the ones that don't exist yet):

| Dataset | Preset | What's in it |
|---|---|---|
| `<pool>/torrent-stack` | Generic | `source/`: a copy of this repository (without `.git`, `.env`, `.env.*` backups except `.env.example`, `configs/` and `downloads/`), marked with a `.torrent-stack-source` file. Gluetun runs `update-qbittorrent.sh` from here. |
| `<pool>/torrent-stack/configs` | Apps | One folder per app: `gluetun`, `qbittorrent`, `jackett`, `flaresolverr`, `filebrowser`. |
| `<pool>/torrent-stack/downloads` | Apps | Finished downloads, plus `incomplete/` for downloads in progress. |

"Apps" is TrueNAS's own preset for app data. It gives the `apps` user (568) write access. The parent dataset is deliberately Generic. `update-qbittorrent.sh` runs as root inside Gluetun, so the installer makes `source/` root-owned and read-only for everyone else. It also removes any ACL that `source/` inherited.

**The `source/` folder is replaced on every run**, so the installer is careful about which folder that is:

* It only fills a folder that is new, empty, or carries its `.torrent-stack-source` marker file. If the parent dataset already has a `source` folder with other files in it, the installer stops before changing anything and says so. Move that folder away, or pick another parent dataset.
* It never follows a hand-edited YAML somewhere else. If you change the `update-qbittorrent.sh` line in the app's YAML to point at another folder, the next run warns and points it back at `source/`, and leaves the other folder alone.
* It stays inside the parent dataset: another dataset mounted inside `source/` is not touched.
* Nobody but root may be able to write to the parent dataset. Otherwise a container user could swap `source/` for a script of their own, and Gluetun would run it as root. If PUID or the `apps` user (568) can write to an existing parent dataset, the installer stops and asks you to fix its permissions. If it created the dataset in this run, it fixes them itself.

**Owners and modes.** The FileBrowser image always runs as user 1000, whatever PUID is. `compose.yaml` gives it PGID as an extra group (`group_add`), so the folders FileBrowser uses must be writable for that group:

| Folder | Owner | Mode | Why |
|---|---|---|---|
| `configs/gluetun`, `qbittorrent`, `jackett`, `flaresolverr` | PUID:PGID | as created (755) | The user each app runs as. |
| `configs/filebrowser` | 1000:PGID | 2770 | FileBrowser's database. Writable for user 1000 and group PGID. The `2` (setgid) makes new files there belong to PGID. Closed to everyone else: the database holds FileBrowser's password hashes and the key that signs its logins. Every run sets this folder back to 1000:PGID and 2770. |
| the downloads dataset, if the installer creates it | PUID:PGID | 2775 | qBittorrent saves there as PUID:PGID. FileBrowser gets in through group PGID. |
| `incomplete/`, if the installer creates it | PUID:PGID | 2775 | The same. |

The installer sets the owners through the TrueNAS API. It sets the modes with a plain `chmod g+rwxs`, because the API (`filesystem.setperm`) would first strip the dataset's ACL. The Apps preset allows `chmod`: its datasets have `aclmode=passthrough`. The preset's ACL already gives the owner, the owning group and the `apps` user (568) write access, and its entries are marked to be inherited by new files and folders.

A downloads dataset you already had keeps its owner and mode. The installer warns if PUID:PGID (qBittorrent) or FileBrowser (user 1000 with group PGID) can't write to it, and prints the commands that fix it.

**First-run configs**: the installer runs the repository's seeding CLI (`scripts/env-editor/seed_configs.py`) with TrueNAS's own Python. It sets the qBittorrent password and enables search, gives Jackett an API key, and connects qBittorrent's Jackett search plugin to it at `127.0.0.1:9117`. That is where Jackett listens inside the VPN container, whatever its port on the TrueNAS address is. This happens only on a first install, after a qBittorrent login change, or with `--reseed`. FileBrowser needs no seeding (see [First login](#first-login)). Around that:

* **qBittorrent's own defaults come first.** The LinuxServer image only writes its default `qBittorrent.conf` when there is no file yet, and the seeding creates one. So the installer writes those defaults itself first: downloads go to `/downloads` (your downloads dataset), unfinished ones to `/downloads/incomplete`, and UPnP is off. It adds the settings of the repository's own starting `qBittorrent.conf`, which the other Docker platforms copy: VueTorrent as the web UI (`/vuetorrent`; the VueTorrent mod installs it but, like its predecessor mod, does not switch it on), the login asked for even from localhost, and the incomplete folder in use. Without this, qBittorrent would save into its config folder and show its plain web UI.
* **The search plugin is pinned.** The Jackett search plugin (a Python file that qBittorrent runs) comes from the commit pinned in `native/versions.env` and is checked against its sha256. If the pin is missing from your checkout, the installer stops: the seeding CLI refuses an unpinned plugin too.
* **qBittorrent 5.3 keeps its login in a `[WebUI]` section.** It moves the login there on its first start and then ignores the old place. The seeding CLI now writes a re-seeded login into `[WebUI]` as well. The installer also moves the old copies left in `[Preferences]` into `[WebUI]`.
* **All of this runs as PUID:PGID, not as root** (with `setpriv`). The containers can change anything in their config folders, links included. A root process writing there could be tricked into overwriting a file on TrueNAS itself. It runs in a private mount namespace (`unshare`) that shows it only qBittorrent's and Jackett's config folders and the repository copy, the way the containers see them. That matters for a PUID other than 568: TrueNAS's Apps preset lets only root and the `apps` user into the configs dataset itself.

**The app**: a custom app created through the TrueNAS API (`app.create`). Its YAML is `compose.yaml` with these changes:

* **The settings are written in place.** TrueNAS keeps only the YAML, not a `.env` file. Values that `compose.yaml` takes from `.env` (`${VPN_PROVIDER}` and so on) appear in the YAML itself. To change a setting, edit the YAML in the web UI or re-run the installer (see [Changing settings later](#changing-settings-later)).
* **Every `$` is doubled.** A password like `pa$s` appears as `pa$$s`, so Docker Compose doesn't treat `$s` as a variable.
* **Paths are full dataset paths** (`/mnt/tank/torrent-stack/...`), including `update-qbittorrent.sh`.
* **No Watchtower.** TrueNAS checks app images for updates itself (see [Updating](#updating)).
* **No `name:` line.** TrueNAS names the project `ix-<app name>` itself.
* **VPN gating.** While the VPN settings are still the placeholders from `.env.example`, Gluetun, qBittorrent, Jackett and FlareSolverr get `profiles: [vpn-not-configured]`. TrueNAS then starts only FileBrowser.

  Without this, Gluetun would exit on the placeholder key. `docker compose up` would report "dependency failed to start", and TrueNAS would delete the half-created app again.

Everything else is `compose.yaml` as it is, with nothing added for TrueNAS. That includes the Jackett and FlareSolverr port mapping (`<JACKETT_PORT>:9117`, `<FLARESOLVERR_PORT>:8191`) and FileBrowser's settings: its database in its config folder, its admin password from `QBITTORRENT_PASSWORD`, and the extra PGID group.

Gluetun keeps `/dev/net/tun` and `NET_ADMIN`, and qBittorrent, Jackett and FlareSolverr keep `network_mode: service:gluetun`. The installer refuses to produce a YAML without them. It also refuses a `compose.yaml` that keeps FileBrowser's database outside a folder on the configs dataset, because TrueNAS recreates the containers on every update and the database would be emptied each time. Before it creates anything it also checks that `/dev/net/tun` exists on the TrueNAS host (trying `modprobe tun` once): TrueNAS deletes an app whose first start fails.

## First login

* **qBittorrent**: `http://<truenas-ip>:8090`, with the login printed at the end.
* **Jackett**: `http://<truenas-ip>:9117`. Its API key is set, and qBittorrent's search tab already uses it. Add indexers in Jackett.
* **FileBrowser**: `http://<truenas-ip>:8081`. User `admin`, with the qBittorrent password. (FileBrowser's admin user is always called `admin`, even if you chose another qBittorrent username.) There is no generated first password to look for in a log.

  `compose.yaml` hands the qBittorrent password to FileBrowser as `FILEBROWSER_ADMIN_PASSWORD` (under `filebrowser` in the app's YAML). FileBrowser sets the `admin` password to it **every time it starts**. A password you change for `admin` inside FileBrowser therefore lasts only until the next restart or app update. To change it for good, change the qBittorrent password with the installer (see [Changing settings later](#changing-settings-later)), which updates both.

  **What FileBrowser keeps**: everything else. Its database is `configs/filebrowser/database.sqlite` on your configs dataset (`FILEBROWSER_DATABASE_PATH=/config/database.sqlite` in `compose.yaml`). Users you add, shares and settings survive restarts, app updates and TrueNAS recreating the containers.

### Password limits

The qBittorrent password is also FileBrowser's `admin` password, so the installer refuses one that FileBrowser (v2.0.2-stable) cannot use. It checks the wizard's answer (and asks again), `TS_QBITTORRENT_PASSWORD_FILE`, and the password it reads back from the app's YAML on a re-run, `--update` or `--print-yaml`. A refused password stops the installer before it changes anything. The password must be:

* **at most 72 bytes.** FileBrowser stores it as a bcrypt hash, and bcrypt takes no more. With a longer one, FileBrowser does not start on a new database and keeps its old password on an existing one. Bytes, not letters: A-Z, digits and ASCII punctuation take 1 byte each, accented letters 2, the euro sign 3, most emoji 4.
* **not `admin`.** FileBrowser ignores that value: a new database gets a random password of its own, an existing one keeps its old password.
* **at least 6 characters**, qBittorrent's own minimum. FileBrowser's is 5 bytes: on a later start it refuses to set a shorter password and keeps its old one.

## Adding the VPN settings later

**The easy way:** run the installer again (the same one-liner). It finds the app and asks whether to change settings. Answer yes and enter the VPN details. It keeps everything else.

**By hand in the web UI:**

1. Open **Apps**, select the app, click **Edit**.
2. Under `gluetun:` > `environment:`, fill in `VPN_SERVICE_PROVIDER` and `VPN_TYPE`. Then either `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES`, or `OPENVPN_USER` and `OPENVPN_PASSWORD`. A `$` in a value must be written as `$$`.
3. Delete the `profiles:` entry (the `profiles:` line and the `- vpn-not-configured` line below it) from `gluetun`, `qbittorrent`, `jackett` and `flaresolverr`.
4. Save. TrueNAS recreates the containers.

## Changing settings later

You can edit the app's YAML in the web UI (**Apps > app > Edit**), or re-run the installer and answer yes to "Change any settings?". Unattended re-runs take `TS_*` variables (see [Unattended install](#unattended-install)).

The installer reads the settings back from the app's current YAML, including changes you made in the web UI. It keeps them when it rebuilds the YAML.

Two things to know:

* **Changing the qBittorrent password.** The password is in three places: in the YAML twice (Gluetun's port-forward script uses it, and FileBrowser's admin password is set from it) and in qBittorrent's own config. Change it with the installer: the wizard, or `TS_QBITTORRENT_PASSWORD_FILE=...` (see [Password limits](#password-limits) for what it accepts). The installer notices the change, stops the app, rewrites qBittorrent's config, updates the YAML and starts the app again. If you change it in the web UI's YAML instead, change the `QBITTORRENT_PASSWORD` line under `gluetun`, then run the installer with `--reseed`, so qBittorrent and FileBrowser get it too. A password there that FileBrowser cannot use makes the installer stop with an error until you change it again. (The installer reads the password from that line. If you only change `FILEBROWSER_ADMIN_PASSWORD`, the next run sets it back to the qBittorrent password.)
* **Changing PUID/PGID** re-owns the config folders. It does not re-own the downloads; the installer tells you the `chown` command to run.

## Updating

**Images** (new Gluetun, qBittorrent and other releases): `compose.yaml` uses rolling tags such as `:latest`. With **Apps > Configuration > Settings > Check for docker image updates** on (the default), TrueNAS looks for newer images and marks apps that have them with a yellow badge. Its documentation doesn't say how the update button behaves for custom apps. The sure way is this shell command, which pulls the newer images and recreates the app:

```bash
midclt call -j app.pull_images torrent-stack '{"redeploy": true}'
```

The stack's own Watchtower is off, because TrueNAS handles image updates.

**The stack itself** (a newer `compose.yaml` or `update-qbittorrent.sh` from this repository):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)" install.sh --update
```

It refreshes the repository copy and rebuilds the YAML from the new `compose.yaml`, with your settings. Before changing anything it lists what will change. A `removed:` line is something in the current YAML that `compose.yaml` doesn't have, such as an extra variable you added by hand. Those are dropped; add them again afterwards.

If nothing changed, the app is left alone. Add `--dry-run` to see what it would do without doing it.

**If an update fails halfway** (for example the VPN doesn't come up and Gluetun stays unhealthy), the installer says what state the app is in now. TrueNAS saves the new YAML before it starts the containers, so the YAML may already be the new one. Fix the cause and run the same command again. If nothing is left to change, it starts the app: a crashed one, or one that the installer itself stopped earlier to rewrite its configs. An app that you stopped yourself stays stopped in an unattended run. The wizard asks whether to start it. The summary at the end always shows the app's state.

## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)" install.sh --uninstall
```

or delete the app on the Apps screen. Either way the datasets and everything in them stay: configs, downloads and the repository copy. To remove those too, delete the datasets in **Datasets** (select `<pool>/torrent-stack` > **Delete**).

The images are kept as well; remove them under **Apps > Configuration > Manage Container Images**, or set `TS_REMOVE_IMAGES=1` when uninstalling.

## Unattended install

Without a terminal, or with `--unattended`, nothing is asked: everything comes from `TS_*` variables. Every `.env.example` setting can be given as `TS_<SETTING>`. For secrets, use `TS_<SETTING>_FILE`, pointing at a file only root can read. That keeps the secret out of your shell history and out of the process list.

```bash
install -m 600 /dev/null /root/wg.key && nano /root/wg.key     # paste the WireGuard private key
TS_UNATTENDED=1 TS_POOL=tank TS_VPN_PROVIDER=protonvpn TS_VPN_TYPE=wireguard \
  TS_WIREGUARD_PRIVATE_KEY_FILE=/root/wg.key TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_SERVER_COUNTRIES=Switzerland \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)"
```

A password in `TS_QBITTORRENT_PASSWORD_FILE` follows the [Password limits](#password-limits). The other variables are `TS_APP_NAME`, `TS_POOL`, `TS_DATASET`, `TS_DOWNLOADS_DATASET`, `TS_SOURCE_DIR`, `TS_REF` and `TS_UI`. Run with `--help` for the full list.

## Install via YAML by hand

If you'd rather paste the YAML into **Apps > Discover Apps > Install via YAML** yourself, the installer can print it:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)" install.sh --print-yaml > /root/torrent-stack.yaml
```

The file holds your secrets. Delete it after pasting.

`--print-yaml` changes nothing, so do the rest yourself first:

1. Create the datasets.
2. Create the folders the YAML mounts. Make `configs/filebrowser` owned by `1000:PGID` with mode 2770 (`chown 1000:PGID` and `chmod 2770`): FileBrowser runs as uid 1000 and keeps its database there, and in a folder it cannot write to it keeps restarting with "unable to open database file".
3. Copy `update-qbittorrent.sh` to the `source` path the YAML names. Make it root-owned, mode 755.
4. Do the first-run steps from [Doing it manually](../docker/README.md#doing-it-manually-without-the-editor) in the Docker guide.

Letting the installer create the app does all of this for you.

## Known custom-app pitfalls

* **Since 25.10 the YAML needs a top-level `services:` key.** A YAML that only uses `include:` is rejected with *"YAML is missing required "services" key"*; add `services: {}` to it. The installer's YAML always has `services:`.
* **TrueNAS deletes an app whose first start fails.** If `docker compose up` fails while the app is created, TrueNAS removes the app again. That happens with a failed image pull, a port already in use, or Gluetun exiting on bad VPN credentials. You only see *"Failed 'up' action ... check /var/log/app_lifecycle.log"*, and users have reported that log being empty. The datasets and configs survive, so you can fix the cause and run the installer again.

  The installer avoids the common causes. It pulls each image first, so a pull problem is reported per image. It checks the ports beforehand. It gates the VPN apps while the VPN settings are placeholders.
* **Image pulls inside app creation can time out.** TrueNAS gives `docker compose up` 20 minutes, including the image downloads. Users have worked around failures by pulling the images first, which the installer now does. Docker Hub rate limits show up as *"toomanyrequests"*. Try again later, sign in under **Apps > Configuration > Sign-in to a Docker registry**, or set a registry mirror under **Apps > Configuration > Settings**.
* **Saving the YAML recreates every container**, and TrueNAS runs `up --force-recreate` on every change. Expect a VPN reconnect and a qBittorrent restart. Anything a container keeps outside its mounted folders is lost then. That is why `compose.yaml` keeps FileBrowser's database in its config folder, and the installer refuses a `compose.yaml` that doesn't.
* **An update that fails still saves the YAML.** TrueNAS writes the new YAML first and then starts the containers. If the start fails, the app is left crashed with the new YAML (see [Updating](#updating)).
* **Restart the whole app, not Gluetun alone.** qBittorrent, Jackett and FlareSolverr share Gluetun's network. Use the app's **Stop**/**Start** (or Restart) on the Apps screen.
* **Comments disappear.** TrueNAS reads the YAML and writes it back out, so comments are lost, including the explanation at the top of the installer's YAML.
* **Host paths must be on a pool**, not inside TrueNAS's own `ix-apps` dataset. The installer refuses both.
* **Secrets in commands.** `midclt call` in 25.10 takes its arguments only on the command line, where every local user can read them. The installer therefore sends the app's YAML through TrueNAS's own Python API client, reading it from a private file. TrueNAS 27's `midclt` can read the arguments from standard input instead (`midclt call METHOD -`).

## Where TrueNAS keeps things

* The app's YAML (with secrets) is under `/mnt/.ix-apps/app_configs/<app name>/`, readable only by root. Anyone with admin access to the web UI can see it via **Edit**.
* The containers are named `ix-<app name>-<service>-1`, for example `ix-torrent-stack-gluetun-1`.
* TrueNAS's logs for app actions are `/var/log/app_lifecycle.log` and `/var/log/middlewared.log`.

## Limitations

* x86-64 only in practice (TrueNAS itself is x86-64).
* The env-editor web page from the main README is not used on TrueNAS. TrueNAS appliances shouldn't have extra software installed on the host, and the app's YAML takes its place.
* FileBrowser's admin user is always `admin`, and its password always follows the qBittorrent password (see [First login](#first-login)).
* **Files in the downloads are not group-writable.** qBittorrent saves them with its default umask 022 (files `rw-r--r--`, folders `rwxr-xr-x`), and FileBrowser creates its own the same way (its default 644/755). The downloads folder itself is group-writable, so FileBrowser can delete or rename what sits directly in it. With plain permissions it can't change or delete files inside a folder that qBittorrent created. The Apps preset's inherited ACL (group Modify) may give the group that access on TrueNAS. That was not tried on real ZFS.
* FileBrowser publishes its port on all addresses, as in the main stack. Firewall it or put it behind a reverse proxy if TrueNAS is reachable from untrusted networks.

## What was tested, and what was not

Tested on a Linux test machine, not on TrueNAS. The test suite is `platforms/truenas/tests/run-tests.sh`; it needs root.

It replaces `midclt` and TrueNAS's Python API client with stand-ins that record every call. Each call is checked against the parameters documented for TrueNAS 25.10, including whether it's a job (`-j`); `app.delete` is also checked against 27.0. The stand-ins also run the YAML through `docker compose config`, as TrueNAS's middleware does.

The real installer runs against the real repository, with real seeding, inside a private mount namespace whose `/mnt` is empty. On the last run all 258 checks passed. They cover:

* a fresh install without VPN settings (gated), including qBittorrent's default paths, the pinned search plugin (sha256), and FileBrowser's database path and password in the YAML;
* that the app's services are exactly what `docker compose config` makes of `compose.yaml` with the same settings, apart from the differences listed under [What it creates](#what-it-creates). So the installer adds no FileBrowser or port settings of its own;
* the folder owners and modes in the table above (FileBrowser's folder 2770, downloads and `incomplete/` 2775), checked as user 1000 with and without group PGID; a FileBrowser folder at 755 set back to 2770 by a re-run; the warning for an existing downloads dataset that FileBrowser can't write to;
* a `compose.yaml` that keeps FileBrowser's database outside the configs dataset (refused);
* adding VPN settings later; a re-run with no changes; settings edited in the web UI being kept, and a `FILEBROWSER_ADMIN_PASSWORD` edited on its own going back to the qBittorrent password;
* the [password limits](#password-limits): `admin`, 5 characters, 73 bytes (37 two-byte letters) and 75 bytes (25 three-byte letters) are refused before any dataset, permission or app call, from `TS_QBITTORRENT_PASSWORD_FILE`, and from the app's YAML (edited in the web UI) on `--update` and `--print-yaml`; the wizard refuses them and asks again, through plain prompts and through `whiptail`. 6 characters and 72 bytes (of 1-, 2-, 3- and 4-byte letters) are accepted, and a 72-byte password arrives exactly in both places in the YAML and in qBittorrent's hash. A good password from `TS_QBITTORRENT_PASSWORD_FILE` replaces a refused one in the YAML;
* a password change triggering a re-seed after qBittorrent's first start, with the new login landing in `[WebUI]` (checked with a real container too: a password with `$` and `"` arrives exactly as typed);
* `--dry-run`, `--print-yaml` and `--uninstall`;
* an existing downloads dataset, OpenVPN, PUID 1000, with the configs dataset closed to uid 1000 (as the Apps preset is) while the seeding still works;
* the `source/` folder: someone else's `source` folder refused before any change (also with `--dry-run`); a YAML edited to mount the script from another folder or from a pool's top folder (that folder is left alone); a file system mounted inside `source/` (not emptied); a parent dataset the apps user can write to (refused); a second app on the same parent dataset (refused);
* Jackett and FlareSolverr on other host ports (published to 9117/8191 inside, read back unchanged on a re-run, qBittorrent's search plugin still at `127.0.0.1:9117`), and qBittorrent on 9117 (refused);
* `:` in a dataset name or path (refused before anything is created), and PUID/PGID written with leading zeros;
* recovery: a failed `app.update` (TrueNAS keeps the new YAML, the app crashes), and a failed `app.start` after a re-seed. In both cases running the same command again starts the app. An app the user stopped stays stopped, and one started by hand since is left alone;
* a link planted in a config folder (pointing at a root-owned file) does not let the re-seed change that file;
* refusals: port clashes, Gluetun's internal ports, old versions, Apps not set up, `ix-apps` paths, failed pulls, someone else's app, non-root;
* the wizard through plain prompts and through `whiptail`;
* that no secret ever appears on a `midclt` command line;
* `shellcheck -S warning` and `bash -n`.

A second script, `platforms/truenas/tests/runtime-images.sh`, checks the same seeding against the real images, with no network. On the last run all 18 checks passed. It used qBittorrent 5.3.0 (`lscr.io/linuxserver/qbittorrent:latest`, ls487) and FileBrowser v2.0.2-stable:

* qBittorrent logs in with the seeded password, saves to `/downloads` and `/downloads/incomplete`, and has UPnP off;
* after its first start, a re-seeded password works, both with and without the installer's `[WebUI]` step (the seeding CLI now writes `[WebUI]` itself);
* FileBrowser, started from the rendered YAML (that is, `compose.yaml`'s service), accepts `admin` with the qBittorrent password (one with `$` in it) and refuses `admin`/`admin`. It keeps its database after `up --force-recreate`;
* FileBrowser's container user is uid 1000 with the extra group 568. Through its own web API it creates a folder in a 568:568, 2775 downloads folder (the folder gets group 568), and deletes a file saved there as 568:568, 644. With the downloads at 755 it can't create anything.

Not tested:

* **A real TrueNAS**: the real middleware's behaviour beyond what its documentation and 25.10.8 source show, real ZFS datasets and ACLs, and real image pulls. In particular, the write-access checks (the parent dataset as PUID and as 568, the downloads as FileBrowser's user, all with `setpriv`) and the `chmod g+rwxs` on new folders were only tried with plain Unix permissions on tmpfs, not with NFSv4 ACLs. Nor was it tried whether `filesystem.setperm` with `stripacl` fixes a parent dataset that inherited an ACL, or whether the Apps preset's inherited ACL makes the files qBittorrent saves group-writable.
* Jackett and FlareSolverr reachable on changed ports from the LAN: the published-port mapping was checked in the YAML, not with a running stack (no Docker bridge networking here).
* The installer's use of TrueNAS's real `truenas_api_client` library. The stand-in has the same interface as the 25.10 source, but the real library was not exercised.
* A real VPN connection: no VPN credentials were available.
* TrueNAS 24.10, 25.04 and 27.0 on real systems.

## References

* VueTorrent LinuxServer mod (the predecessor of `vuetorrent-lsio-mod`, which says it is compatible): after adding it, "Use alternative Web UI" and the files location `/vuetorrent` are set by hand: <https://github.com/gabe565/linuxserver-mod-vuetorrent>
* TrueNAS 25.10 API: [app.create](https://api.truenas.com/v25.10/api_methods_app.create.html), [app.update](https://api.truenas.com/v25.10/api_methods_app.update.html), [app.query](https://api.truenas.com/v25.10/api_methods_app.query.html), [app.config](https://api.truenas.com/v25.10/api_methods_app.config.html), [app.delete](https://api.truenas.com/v25.10/api_methods_app.delete.html), [app.start](https://api.truenas.com/v25.10/api_methods_app.start.html), [app.stop](https://api.truenas.com/v25.10/api_methods_app.stop.html), [app.image.pull](https://api.truenas.com/v25.10/api_methods_app.image.pull.html), [app.pull_images](https://api.truenas.com/v25.10/api_methods_app.pull_images.html), [app.used_ports](https://api.truenas.com/v25.10/api_methods_app.used_ports.html), [docker.status](https://api.truenas.com/v25.10/api_methods_docker.status.html), [docker.config](https://api.truenas.com/v25.10/api_methods_docker.config.html), [pool.query](https://api.truenas.com/v25.10/api_methods_pool.query.html), [pool.dataset.query](https://api.truenas.com/v25.10/api_methods_pool.dataset.query.html), [pool.dataset.create](https://api.truenas.com/v25.10/api_methods_pool.dataset.create.html), [filesystem.chown](https://api.truenas.com/v25.10/api_methods_filesystem.chown.html), [filesystem.setperm](https://api.truenas.com/v25.10/api_methods_filesystem.setperm.html), [system.version](https://api.truenas.com/v25.10/api_methods_system.version.html), [system.general.config](https://api.truenas.com/v25.10/api_methods_system.general.config.html), [JSON-RPC overview](https://api.truenas.com/v25.10/jsonrpc.html)
* TrueNAS 27.0 API (for the differences): [app.create](https://api.truenas.com/v27.0/api_methods_app.create.html), [app.delete](https://api.truenas.com/v27.0/api_methods_app.delete.html)
* TrueNAS docs, Install via YAML (25.10): <https://www.truenas.com/docs/scale/25.10/scaleuireference/apps/installcustomappscreens/>
* TrueNAS docs, Apps screens (25.10; Configuration menu, update badges, "Check for docker image updates"): <https://www.truenas.com/docs/scale/25.10/scaleuireference/apps/>
* TrueNAS middleware source, release/25.10.8: [custom_app_utils.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/apps/custom_app_utils.py) (validation), [custom_app.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/apps/custom_app.py) (create and clean-up on failure), [compose_utils.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/apps/compose_utils.py) (`up --force-recreate`, 1200 s limit), [crud.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/apps/crud.py), [pool_/dataset.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/pool_/dataset.py) (the Apps preset's ACL), [apps_images/images.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/apps_images/images.py), [debian/control](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/debian/control) (what ships with the middleware)
* `midclt` / Python API client: [25.10.8](https://github.com/truenas/api_client/blob/release/25.10.8/truenas_api_client/__init__.py) (arguments only on the command line) and [27.0.0](https://github.com/truenas/api_client/blob/release/27.0.0/truenas_api_client/__init__.py) (`-` reads standard input)
* TrueNAS build manifest, release/25.10.8 (git ships): <https://github.com/truenas/scale-build/blob/release/25.10.8/conf/build.manifest>
* Forum: [25.10 RC1 custom app YAML input bug](https://forums.truenas.com/t/25-10-rc1-custom-app-yaml-input-bug/55300) (the `services` key), [Can't spin up custom docker-compose.yml, no logs in app_lifecycle.log](https://forums.truenas.com/t/cant-spin-up-custom-docker-compose-yml-file-no-logs-in-var-log-app-lifecycle-log/67097) (pre-pulling images)
* TechnoTim, TrueNAS Docker Pro (the `services: {}` workaround): <https://technotim.com/posts/truenas-docker-pro/>
* FileBrowser Quantum v2.0.2-stable. The image runs as uid 1000 (group 1000) and sets `FILEBROWSER_DATABASE_PATH` / `FILEBROWSER_CONFIG` to `/home/filebrowser/data`: [_docker/Dockerfile](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/_docker/Dockerfile). `FILEBROWSER_ADMIN_PASSWORD` sets `auth.adminPassword`, the admin user is `admin` by default (no environment variable changes that), and new files and folders get 644/755: [backend/pkg/settings/config.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/config.go) (`loadEnvConfig`, `SetDefaults`). On every start `validateUserInfo` resets the `admin` user's password to it unless it is empty or `admin`: [cmd/root.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/cmd/root.go), [cmd/user.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/cmd/user.go), [auth.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/auth.go) (`ConfigTriggersAdminPasswordReset`). A first password is only generated (and logged) when none is set: [state/bootstrap_admin_password.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/bootstrap_admin_password.go). The password limits: a password that is set or changed must have at least `auth.methods.password.minLength` bytes, default 5 ([pkg/settings/password_policy.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/password_policy.go), `MinLength: 5` in `config.go`), checked in `UpdateUser` ([state/users.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/users.go)) but not when the first admin user is made ([state/quick_setup.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/quick_setup.go), which stops FileBrowser if hashing fails). Passwords are hashed with bcrypt ([utils/crypto.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/utils/crypto.go)), whose `GenerateFromPassword` refuses more than 72 bytes ([bcrypt.go in golang.org/x/crypto v0.57.0](https://github.com/golang/crypto/blob/v0.57.0/bcrypt/bcrypt.go), the version in [backend/go.mod](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/go.mod)). The database path: [database_paths.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/database_paths.go)
* TrueNAS's Apps preset: `aclmode=PASSTHROUGH`, the `NFS4_RESTRICTED` ACL (owner@ Full Control, group@ Modify, both inherited) plus user 568 Modify: [pool_/dataset.py](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/pool_/dataset.py), [the NFS4_RESTRICTED template](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/alembic/versions/22.02/2021-08-26_14-35_add-acl-templates.py). What `aclmode` means for `chmod` (passthrough allows it; setgid needs it): [OpenZFS zfsprops(7)](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)
* LinuxServer qBittorrent: [init script](https://github.com/linuxserver/docker-qbittorrent/blob/master/root/etc/s6-overlay/s6-rc.d/init-qbittorrent-config/run) (defaults only copied when there is no `qBittorrent.conf`), [defaults/qBittorrent.conf](https://github.com/linuxserver/docker-qbittorrent/blob/master/root/defaults/qBittorrent.conf), [Dockerfile](https://github.com/linuxserver/docker-qbittorrent/blob/master/Dockerfile) (`HOME=/config`)
* qBittorrent settings migrations (migration 11 moves the web UI login to `[WebUI]`): [src/app/upgrade.cpp at release-5.3.0](https://github.com/qbittorrent/qBittorrent/blob/release-5.3.0/src/app/upgrade.cpp)
* LinuxServer Jackett listens on 9117 (its service waits for `nc -z localhost 9117`): [svc-jackett/run](https://github.com/linuxserver/docker-jackett/blob/master/root/etc/s6-overlay/s6-rc.d/svc-jackett/run); FlareSolverr's `PORT` (default 8191): [src/flaresolverr.py](https://github.com/FlareSolverr/FlareSolverr/blob/master/src/flaresolverr.py)
* qBittorrent search plugins (the Jackett plugin, pinned by commit in `native/versions.env`): <https://github.com/qbittorrent/search-plugins>
* `app.update` saves the YAML before `compose up` and skips `up` for a stopped app: [crud.py do_update / update_internal](https://github.com/truenas/middleware/blob/release/25.10.8/src/middlewared/middlewared/plugins/apps/crud.py); app states: [app.query](https://api.truenas.com/v25.10/api_methods_app.query.html)
* Docker Compose interpolation (`$$` for a literal `$`): <https://docs.docker.com/reference/compose-file/interpolation/>
* Docker Compose profiles: <https://docs.docker.com/reference/compose-file/profiles/>
