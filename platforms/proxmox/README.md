# Proxmox VE: one-line install in an LXC container

`install.sh` runs on your Proxmox VE host. It creates one small, unprivileged Debian 13 container and installs the whole stack in it as ordinary system services: Gluetun (the VPN), qBittorrent with VueTorrent, Jackett, FlareSolverr, FileBrowser and the env-editor. There is no Docker inside the container.

qBittorrent, Jackett and FlareSolverr can only reach the internet through the VPN. A kill switch inside the container blocks them when the VPN is down. The in-container installer (`native/install.sh`, see [native/README.md](../../native/README.md)) sets that up. This script builds the container and hands over to it.

## Before you start

* **Proxmox VE 8.x or 9.x** on an **amd64** (x86-64) machine. Proxmox VE is only released for amd64, and the script uses the amd64 Debian template, so other hosts are refused. (The stack itself also runs on arm64; see the Incus installer.)
* **A root shell on the Proxmox host.** The easiest is the node's **Shell** button in the Proxmox web UI. Don't use `sudo` from another user.
* **An up-to-date host.** Every current Debian 13 template is a point release (13.1 or later). Proxmox's `pve-container` package refused those until version 5.3.1 (Proxmox VE 8) and 6.0.10 (Proxmox VE 9), both from early September 2025: `pct create` failed with "unsupported debian version '13.1'". If your host hasn't been updated since then, run `apt update && apt dist-upgrade` on it first. The script checks this before it creates anything and stops with that advice if needed.
* **Internet access** from the host (to download the Debian template) and from the container (Debian packages, GitHub).
* **A VPN provider with port forwarding.** See [Prerequisites](../../README.md#prerequisites) in the main README.
* **Space:** a 16 GiB container disk by default, plus room for downloads, either on that disk or on a host folder you mount in (see below).

## Install

Paste this into the host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh)"
```

1. Confirm that you want a new container.
2. Choose **Default** or **Advanced**:
   * **Default** asks only for a root password for the container (8 or more characters, typed twice) and, if you have more than one, which storage to use. Everything else uses the defaults below.
   * **Advanced** asks for every setting (see the next section) and shows a summary, which you can accept with **Create** or answer again with **Do-Over**.
3. Wait. The script downloads the newest Debian 13 template, creates and starts the container, updates its packages, copies in this repository and runs the in-container installer. Its output scrolls past in your terminal.
4. At the end you see the **env-editor address** (`http://<container-ip>:9191`) and its **first-run login**. Write the login down: it is only shown once. The installer also keeps a copy in `/root/torrent-stack.creds` inside the container. Delete that file once you've noted the login.
5. Open the env-editor in your browser, log in, enter your VPN provider's details, then press **Preview changes** and **Apply**. Gluetun, qBittorrent, Jackett and FlareSolverr only start once real VPN settings are saved. Until then only the env-editor and FileBrowser run.

## What the wizard asks

| Setting | Default | Notes |
|---|---|---|
| Container ID | next free ID | Checked across the whole cluster. |
| Hostname | `torrent-stack` | Lowercase letters, digits and `-`. |
| CPU cores | 2 | |
| RAM | 4096 MiB | FlareSolverr's Chromium and the Gluetun build like 2 GiB or more. |
| Swap | 512 MiB | |
| Disk | 16 GiB | Downloads land here too unless you mount a host folder. |
| Storage for the disk | `local-lvm` if present | Only storages that can hold container disks (`rootdir`) are offered. |
| Storage for the template | `local` if present | Only storages that can hold templates (`vztmpl`) are offered. |
| Bridge | `vmbr0` | |
| VLAN tag | none | |
| IPv4 | DHCP | Or a static address with prefix, e.g. `192.168.1.50/24`, plus a gateway. |
| DNS servers | the host's | Space-separated list. |
| Root password | asked | Advanced: may be left empty (then use an SSH key or `pct enter`). It is set with `chpasswd` inside the container, never on a command line. |
| SSH public key | none | Paste a key, or the path to a file of keys. Debian's SSH server only lets root in with a key, not a password. |
| PUID / PGID | 1000 / 1000 | The user and group the apps run as inside the container, so the owner of downloaded files. |
| Downloads folder on the host | none | See [Keeping downloads on the host](#keeping-downloads-on-the-host). |
| Start on boot | yes | |
| Time zone | the host's | Not asked; set `TS_TZ` to override. |

## What it creates

On the host:

* **One container**, created with `pct create` and these options:

  | Option | Why |
  |---|---|
  | `--unprivileged 1` | Root inside the container is an ordinary high user ID on the host, so a break-out lands as nobody special. |
  | `--features nesting=1` | **Needed for Debian 13.** Its systemd runs services in their own namespaces, which an unprivileged container is only allowed to do with nesting. Without it services fail and the console stays blank. Proxmox's own docs say nesting "is also required by systemd to isolate services". Proxmox VE 9.1 documents this, 9.2 shows a warning when it is off, and the web UI turns nesting on for new unprivileged containers. Nesting gives the container more of the host's `/proc` and `/sys` to look at. In an unprivileged container that is the accepted trade-off. `keyctl` is not set, because no Docker runs here. |
  | `--dev0 /dev/net/tun` | Gluetun needs the TUN device for the VPN. This is Proxmox's built-in device passthrough (Proxmox VE 8.1 and later). On 8.0 the script adds the two classic config lines instead: `lxc.cgroup2.devices.allow: c 10:200 rwm` and `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file`. |
  | `--net0 name=eth0,bridge=…,ip=…` | Your network choices. IPv6 is not configured. |
  | `--onboot`, `--tags torrent-stack;vpn;qbittorrent`, `--timezone`, `--ostype debian`, `--arch amd64` | Start on boot, tags so `--update` can find the container, the host's time zone. |
  | `--mp0 <host folder>,mp=/mnt/downloads` | Only if you chose a downloads folder. |

* **The Debian template** (`debian-13-standard_…_amd64.tar.zst`) on the template storage, if it wasn't there already.
* `/etc/modules-load.d/torrent-stack-wireguard.conf`, which loads the host's WireGuard kernel module at boot. A container can't load kernel modules itself, and Gluetun falls back to slower userspace WireGuard without it. Set `TS_HOST_WIREGUARD=0` to skip this.
* With a downloads folder: that folder and its `incomplete/` subfolder (created if missing) get a new owner. With the `idmap` choice, two lines are added to `/etc/subuid` and `/etc/subgid` (see below).
* While an install is unfinished: `/root/torrent-stack-<ID>-settings.env` (root-only) with your answers, so a retry can reuse them. It holds no password, and it is deleted as soon as the install finishes. See [If the install fails](#if-the-install-fails).

Inside the container:

* This repository in `/opt/torrent-stack`: a git clone of `main`, or a copy of `TS_SOURCE_DIR`.
* `/root/.torrent-stack-proxmox.env` holds the starting values handed to the installer (time zone, PUID/PGID, downloads path). They are only used to create `/opt/torrent-stack/.env` the first time. After that, change settings in the env-editor.
* Everything `native/install.sh install` sets up: services, kill switch, configs. See [native/README.md](../../native/README.md).

## Keeping downloads on the host

You can keep downloads in a folder on the Proxmox host (a ZFS dataset, a big disk, a mounted share) instead of inside the container's disk. The script mounts it in the container at `/mnt/downloads` and tells the installer to use it.

**About user IDs.** In an unprivileged container every user ID is shifted: user 1000 inside the container is user **101000** on the host (Proxmox adds 100000). The apps run as `PUID` (1000 by default) inside, so they can only write to the folder if the host sees it as owned by the matching ID. The wizard offers two ways:

* **shift** (default, simplest): the script makes the folder owned by `101000:101000` on the host (100000 + PUID/PGID). Inside the container it shows up as owned by 1000:1000. On the host and on any share exported from it, the files belong to user 101000.
* **idmap**: the folder keeps `1000:1000` on the host, which is handy if a Samba/NFS share or other containers already use that ID. The script adds `lxc.idmap` lines to `/etc/pve/lxc/<ID>.conf` that pass that one user and group straight through (the method from the Proxmox wiki page *Unprivileged LXC containers*). It also adds `root:1000:1` to `/etc/subuid` and `/etc/subgid`, so Proxmox is allowed to use that mapping.

**Which folders are allowed.** Because the apps in the container can write to this folder, the script refuses system folders. It checks the folder's real path, so `//`, `/./etc` or a symbolic link that leads into a system folder are caught too. When the path is a symbolic link to a normal folder, the real folder is used. Refused:

* anything under `/etc`, `/usr`, `/boot`, `/dev`, `/proc`, `/sys`, `/run`, `/bin`, `/sbin`, `/lib…` and `/var`. The one exception is a folder of your own under `/var/lib/vz` (Proxmox's `local` storage), such as `/var/lib/vz/downloads`, but not the folders Proxmox manages there (`template`, `images`, `dump`, `snippets`, `private`, `import`);
* `/` itself, and the top folders `/root`, `/home`, `/opt`, `/srv`, `/mnt`, `/media`, `/tmp`, plus a storage's own mount point `/mnt/pve/<storage>`. A folder inside them is fine, e.g. `/mnt/pve/nas/downloads`;
* another guest's disk, such as `…/subvol-101-disk-0`, `…/images/101` or `…/private/101`;
* names with anything other than letters, digits and `. _ - + @` (a comma, `=` or `:` would confuse Proxmox's mount point settings);
* an `incomplete/` subfolder that is a symbolic link. A container that already uses the folder could have planted one to make the script change the owner of a host folder.

Only the folder itself and `incomplete/` are changed. Files already in it keep their owner. If qBittorrent must write into existing subfolders, change them yourself. In **shift** mode that is `chown -R 101000:101000 /your/folder`, in **idmap** mode `chown -R 1000:1000 /your/folder` (use your PUID/PGID).

A network share that "squashes" root (NFS `root_squash`, most SMB mounts) won't let the host change owners. Set the ownership on the NAS instead, or mount the share with the right `uid=`/`gid=` options.

Proxmox VE 9.2 added a per-mount-point `idmap=` option that does the same thing more neatly. The script uses the `lxc.idmap` method because it works on every 8.x and 9.x release.

## Updating

From the Proxmox host. The word `install.sh` is just the name bash gives the script; the arguments come after it:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh)" install.sh --update 105
```

Leave out the ID if only one container has the `torrent-stack` tag. The update starts the container if it's stopped and runs `native/install.sh self-update` in it, then prints the status of each service. `self-update` is the same on Proxmox and Incus, and you can run it yourself inside the container (`pct enter 105`, or SSH):

```bash
bash /opt/torrent-stack/native/install.sh self-update
```

(`bash /opt/torrent-stack/platforms/proxmox/install.sh --update` inside the container does the same.) It:

1. gets the new version of `/opt/torrent-stack` from git;
2. upgrades the container's Debian packages (`apt full-upgrade`, keeping config files you changed);
3. runs `native/install.sh update`, which installs only the components whose pinned version changed and restarts only those.

* To switch to a specific release or branch, add `TS_REF=<tag-or-branch>` in front of the host command (or use `self-update --ref <tag-or-branch>` inside).
* If you installed from a local copy (`TS_SOURCE_DIR`), there is no git checkout to pull. Run the host command with `TS_SOURCE_DIR=/path/to/checkout` again: it copies the files in, then runs `self-update`, which skips the git step.
* Your live settings survive the update. qBittorrent and Jackett keep their settings in two files that this repository also ships as starting points (`configs/qbittorrent/qBittorrent/qBittorrent.conf` and `configs/jackett/Jackett/ServerConfig.json`), and the apps rewrite them as they run. A plain `git pull` would refuse to update once a new version changes one of those starting files, so don't use it. `self-update` updates every file outside `configs/` and never writes into `configs/` (those folders belong to the apps' user), so your live files stay exactly as they are. The shipped versions only matter on the very first start.
* **While the VPN is down, the update cannot download anything**: once Gluetun runs, even root in the container reaches the internet only through the VPN. The update says so and stops. Stop Gluetun (`pct exec 105 -- systemctl stop torrent-gluetun`), update, then start it again (`pct exec 105 -- systemctl start torrent-gluetun`). The kill switch keeps the apps offline meanwhile.

## If the install fails

The container is kept and the script tells you two commands:

* **retry**: `bash -c "$(curl …)" install.sh --resume <ID>` re-runs the in-container install. It is safe to repeat. If you installed with `TS_REF`, `TS_SOURCE_DIR` or `TS_REPO_URL`, the printed command already has them in front, so copy it as shown.
* **remove**: `pct stop <ID>; pct destroy <ID> --purge 1`.

In the wizard you are also asked whether to remove the unfinished container right away.

**Your answers are kept.** As soon as the container exists, the script saves your answers (PUID/PGID, time zone, downloads folder, branch and source) in `/root/torrent-stack-<ID>-settings.env` on the host, root-only. `--resume` reads them, so you don't have to repeat any `TS_*` settings. A `TS_*` variable you do give on the `--resume` command wins over the saved value. The file holds no password and is deleted once the install has finished. If it is missing, `--resume` works the IDs out from the container's config (its `lxc.idmap` lines, or the owner of the downloads folder) and its time zone, and says so.

**Root password.** The password is set as soon as the container has started, before the network check (the most likely place for an install to stop). If the container never started, the password could not be set yet. `--resume` then asks for it again in the wizard, takes it from `TS_ROOT_PASSWORD_FILE`, or, unattended, warns you to set it with `pct exec <ID> -- passwd`.

When the in-container installer itself failed, its output is kept in `/root/torrent-stack-<ID>-install.log` on the host (root-only). It may contain the first-run login, so delete it once you've looked. A later successful install or `--resume` of that container deletes it for you.

## Lost the env-editor login

Inside the container, see whether `/root/torrent-stack.creds` is still there. If not, make a new login:

```bash
pct exec 105 -- bash /opt/torrent-stack/native/install.sh reset-login
```

It prints the new password once, saves it in `/root/torrent-stack.creds` in the container, and restarts the env-editor so the new password works right away. Until you set a real qBittorrent login, FileBrowser uses the same new password.

## Uninstall

```bash
pct stop 105
pct destroy 105 --purge 1
```

`--purge 1` also removes the container from backup and replication jobs. A downloads folder you mounted from the host is **not** deleted. Things the script added to the host stay until you remove them:

* the template: `pveam remove local:vztmpl/debian-13-standard_…_amd64.tar.zst`
* `/etc/modules-load.d/torrent-stack-wireguard.conf`
* with **idmap**: the `root:<PUID>:1` / `root:<PGID>:1` lines in `/etc/subuid` and `/etc/subgid`
* after an install that never finished: `/root/torrent-stack-<ID>-settings.env` and perhaps `/root/torrent-stack-<ID>-install.log`

## Unattended install

Without a terminal, or with `TS_UNATTENDED=1`, the script asks nothing and takes its settings from these variables (they also pre-fill the wizard):

| Variable | Meaning |
|---|---|
| `TS_CTID`, `TS_HOSTNAME`, `TS_CORES`, `TS_RAM`, `TS_SWAP`, `TS_DISK` | as in the table above |
| `TS_ROOTFS_STORAGE`, `TS_TEMPLATE_STORAGE` | storage IDs |
| `TS_BRIDGE`, `TS_VLAN`, `TS_IP`, `TS_GATEWAY`, `TS_DNS` | network |
| `TS_ROOT_PASSWORD_FILE` | a file holding the root password (`chmod 600` it). Passwords are never taken from the command line. |
| `TS_SSH_KEY_FILE` | a file of SSH public keys |
| `TS_TZ`, `TS_PUID`, `TS_PGID`, `TS_ONBOOT` | time zone, user/group IDs, start on boot (1/0) |
| `TS_DOWNLOADS_HOST_PATH`, `TS_DOWNLOADS_MAPPING` | host downloads folder; `shift` or `idmap` |
| `TS_SOURCE_DIR` | copy this local checkout in instead of cloning (skips `.git`, `configs/`, `downloads/`, `.env` and other `.env.*` files) |
| `TS_REF`, `TS_REPO_URL` | branch/tag and repository to clone |
| `TS_GUEST_PROXY` | an HTTP proxy for downloads inside the container. The host's own proxy variables are not copied in on purpose: a proxy on the host's `127.0.0.1` can't be reached from the container. |
| `TS_HOST_WIREGUARD=0` | don't load the WireGuard module on the host |
| `TS_FORCE=1` | let `--update` work on a container without the `torrent-stack` tag |

Example:

```bash
# read -s keeps the password out of the screen and the shell history
read -rs -p 'Container root password: ' PW && echo && install -m 600 /dev/null /root/ct-pw && printf '%s\n' "$PW" > /root/ct-pw && unset PW
TS_UNATTENDED=1 TS_CTID=150 TS_IP=192.168.1.50/24 TS_GATEWAY=192.168.1.1 \
TS_ROOT_PASSWORD_FILE=/root/ct-pw TS_DOWNLOADS_HOST_PATH=/tank/downloads \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh)"
rm /root/ct-pw
```

`bash install.sh --help` lists everything.

## Limitations

* amd64 only (Proxmox VE itself is amd64 only).
* IPv4 only. The script sets no IPv6 address on the container's network card. Keeping the apps' traffic inside the VPN is the kill switch's job, not the network settings' (see [native/README.md](../../native/README.md)).
* **Proxmox VE 8.0** has no built-in device passthrough. There the script uses the classic `lxc.*` lines, which only work if the host's `/dev/net/tun` has its normal mode `0666` (the script warns otherwise). Updating to 8.1 or later avoids this.
* If the container gets no IPv4 address with DHCP, update the host: Proxmox VE 9.1 fixed DHCP for Debian 13 containers. Or use a static address (`pct set <ID> --net0 …`). Then run `--resume`: your answers and the root password are already in place.
* In a cluster, the container is created on the node you run the script on.
* No telemetry, nothing fetched at run time except the Debian template (through Proxmox's `pveam`), Debian packages and this repository.

## What was tested, and what was not

There was no Proxmox VE host to test on. What was done instead:

* `bash -n` and `shellcheck -S warning` are clean on `install.sh`, `tests/run-tests.sh` and `tests/shims/whiptail`.
* **Command stand-ins.** `tests/shims/` has stand-ins for `pct`, `pveam`, `pvesm`, `pvesh`, `pveversion`, `whiptail` (answers come from environment variables), `timedatectl`, `modprobe`, `modinfo` and `dpkg`. They record every call. The `pct` stand-in checks `pct create` and `pct set` against the official Proxmox VE API schema (the same `apidoc.js` the [pct manual](https://pve.proxmox.com/pve-docs/pct.1.html) is generated from): option names, types, ranges, enums, patterns and the property strings for `net0`, `dev0`, `mp0`, `rootfs` and `features`. The formats are re-implemented after Proxmox's `pve-common` and `pve-container` source. A self-test shows it rejects 16 kinds of bad arguments. Like `pct`, it refuses `exec` and `push` on a stopped container.
* **Record tests** (259 checks, 20 of them the self-test above; no containers). For these the `pct` stand-in also answers `test -f` and `cat` from the files that were pushed, and it can pretend the container gets no IPv4 address or does not start. Checked:
  * the exact `pct create` arguments for Default, Advanced (static IP, gateway in subnet, VLAN, DNS, SSH key, password retry, Do-Over) and Proxmox VE 8.0;
  * Do-Over: the password and SSH key from the first pass can be kept, or cleared by leaving them empty;
  * the root password reaching only `chpasswd`'s stdin, never a command line or a log;
  * the `lxc.idmap`, `/etc/subuid` and `/etc/subgid` lines and folder ownership in both mapping modes;
  * newest-template selection, and falling back to an already-downloaded template when offline;
  * what goes into the source tarball and what is kept out;
  * the refusals (Proxmox 7, arm64, a `TS_GUEST_PROXY` with a password, not root, ID in use, bad IP, gateway outside the subnet, system folder, missing bridge, PUID 0, wrong storage, no whiptail on a terminal, Cancel);
  * `--update`, `--resume` and finding the container by its tag;
  * **update with live config files:** the clone snippet from `install.sh` and the git step of the real `native/install.sh self-update`, run with real `git` against a local "upstream" whose new commits change the tracked `qBittorrent.conf` and `ServerConfig.json`. The live files keep their content, owner and mode, a seed you deleted stays deleted, a live file that upstream starts tracking is kept, a file removed upstream is removed, a hand-edited file that the update would change stops the update (and is named), switching to a tag works, and a failed update leaves the live files alone. (The old `git pull` refused this update; that was reproduced first.);
  * **`--resume` after an early failure:** a first run that stops waiting for the network, and first runs where the container does not start. `--resume`, with no `TS_*` settings repeated, reuses the saved PUID/PGID, time zone, downloads folder, branch (`TS_REF`) and `TS_SOURCE_DIR`; it does not set the password twice; it warns when a chosen password could never be set; and without the saved file it works the IDs out from `lxc.idmap` or the folder owner. The printed retry command keeps `TS_REF` / `TS_SOURCE_DIR`. The answers file is root-only, holds no password, and is gone after success;
  * **downloads folder paths:** `//`, `/./etc/`, `/var/lib/pve-cluster`, a symbolic link into `/etc` and a symbolic-link `incomplete/` are refused, and nothing is created or chowned. A link to a normal folder uses the real folder. 20 more paths are checked directly;
  * hostnames and DNS lists with `*` or `?` are refused even when files with matching names exist.
* **Real hand-off** (78 checks): `pct` backed by a real Incus Debian 13 system container (`px-<ID>`), with a stub `native/install.sh` that records its arguments and environment. Checked:
  * the stub received `install`, `TZ`, `PUID`, `PGID`, `DOWNLOADS_PATH` and `INCOMPLETE_DOWNLOADS`, and no host variables;
  * `/opt/torrent-stack` is complete and root-owned, without `.git`, `.env`, `configs/` or `downloads/`;
  * a TUN interface can be created both through the `dev0` path and through the Proxmox VE 8.0 `lxc.*` lines;
  * systemd runs with nesting, and the root password, SSH key, hostname and time zone are set;
  * the summary shows the URL and login;
  * the git clone of `main` and the clear "no native installer" failure, then `--resume`;
  * `--update` from the host and from inside the container, both through `native/install.sh self-update` (the stub runs the real installer's git step);
  * `--update`, from the host and from inside the container, on the real clone of `main` after an "upstream" commit changed the tracked `qBittorrent.conf`. The live file (owned by the app user, mode 600) was kept both times;
  * after the failed first run, the retry hint keeps `TS_REF` and the answers file exists; it is removed once `--resume` finishes;
  * `pct destroy` leaves the host downloads folder alone.
* **Real install with the final `native/install.sh`** (not the stub): this script, unchanged, with `pct` backed by the same Incus stand-in (container 9501), installing **from git**: a local `git daemon` served a snapshot of this branch as `TS_REPO_URL`, so the container cloned it like the one-liner clones GitHub. Checked:
  * the install finished, with the real first-run logins (env-editor and FileBrowser) shown from `/root/torrent-stack.creds`; the env-editor answered 401 without and 200 with the login, FileBrowser answered; the kill switch was loaded, the `torrent` user could not resolve or reach github.com while root could;
  * `--update 9501` from the host after an "upstream" commit that changed the tracked `qBittorrent.conf` and another file: the checkout moved to the new commit, the other file changed, the live `qBittorrent.conf` (rewritten by the installer, owned by `torrent`) stayed byte for byte the same, Debian packages were upgraded, "Nothing changed; no service restarted";
  * `--update` from inside the container after a commit that changed the env-editor: "Installed env-editor", "Restarted: env-editor" and nothing else;
  * `--resume 9501` with a stale `/root/torrent-stack-9501-install.log` on the host: finished, kept the existing checkout, removed that log;
  * `native/install.sh install`'s output appeared while it ran.
  The test network intercepts HTTPS, so the stand-in added its CA to the container (after boot, with a check that it reached the CA bundle).
* Run them yourself as root: `platforms/proxmox/tests/run-tests.sh record` (fast), or `incus` for the real-container part. Both check every `pct` call against the Proxmox API schema, `apidoc.js`: the runner downloads it with `curl` from <https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js> and deletes it at the end. Offline, download it first (`curl -fsSLo apidoc.js https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js`) and run with `TS_TEST_APIDOC=$PWD/apidoc.js`. If the test machine has no `/etc/pve`, the runner creates an empty one only for the run and removes it afterwards.

Not tested:

* **Real Proxmox VE**: `pct`'s own behaviour, real storages (LVM-thin, ZFS, directories), `pveam` downloads, the web UI console, clusters.
* **The Proxmox +100000 user-ID shift on the bind mount.** Incus uses its own ID range, so the host-side ownership was checked, but not writes from the container through the mount.
* **The `idmap` mode end to end.** `lxc.idmap` was checked as text only; it would have needed changes to the test host's `/etc/subuid`.
* **Static IP, VLAN and DNS inside a real container.** The values were checked as `pct` arguments; Incus gave the test container a fixed DHCP lease instead.
* **The real stack from a `TS_SOURCE_DIR` copy through this script.** The real stack ran from git here; the copy path ran with the stub (and with the real stack through the Incus script).
* **The interactive `--resume` password prompt.** The unattended paths (password file, warning) were tested; the wizard prompt was not.
* **Real VPN connectivity.** No VPN credentials were available.
* **Test-network quirks.** The test machine's `/dev/net/tun` is `0600` (Proxmox's is `0666`), so the PVE 8.0 test bound a `0666` copy of the same device. The test network intercepts HTTPS, so its CA was added to the test container. Neither applies on a normal Proxmox host.

## References

* apt-get `--error-on=any` (fail the update on any error, even a transient one): <https://manpages.debian.org/trixie/apt/apt-get.8.en.html>
* pct manual (options, `dev[n]`, `features`, `mp[n]`, `idmap`, `exec`, `push`, `destroy`): <https://pve.proxmox.com/pve-docs/pct.1.html>
* Proxmox VE API schema (used to validate the `pct create` calls): <https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js>
* Proxmox VE roadmap / release notes (device passthrough in 8.1, GUI for it in 8.2, Debian 13 DHCP fix and "systemd needs nesting" documented in 9.1, the nesting warning and per-mount-point idmap in 9.2): <https://pve.proxmox.com/wiki/Roadmap>
* Debian 13 point releases refused by older `pve-container` (the `<= 13` check, fixed in 5.3.1 / 6.0.10): <https://git.proxmox.com/?p=pve-container.git;a=commit;h=b69cdbc21fb070ed2f25fbec9a1c22aa1c76fd82> and the changelogs <https://git.proxmox.com/?p=pve-container.git;a=blob_plain;f=debian/changelog;hb=refs/heads/stable-bookworm>, <https://git.proxmox.com/?p=pve-container.git;a=blob_plain;f=debian/changelog;hb=HEAD>
* pveam, pvesm and pvesh manuals: <https://pve.proxmox.com/pve-docs/pveam.1.html>, <https://pve.proxmox.com/pve-docs/pvesm.1.html>, <https://pve.proxmox.com/pve-docs/pvesh.1.html>
* Unprivileged LXC containers (uid mapping, `lxc.idmap`, `/etc/subuid`): <https://pve.proxmox.com/wiki/Unprivileged_LXC_containers>
* Debian 13 without nesting (forum, Proxmox staff explanation): <https://forum.proxmox.com/threads/lxc-debian-13-with-nesting-disabled-no-console.173418/>
* "warn that nesting may be required for systemd" (pve-devel patch): <https://lists.proxmox.com/pipermail/pve-devel/2025-November/077080.html>
* Proxmox template index: <http://download.proxmox.com/images/aplinfo-pve-9.dat>
* pct exec/push implementation (keep-env, running-container checks): <https://git.proxmox.com/?p=pve-container.git;a=blob;f=src/PVE/CLI/pct.pm>
* Parameter formats: <https://git.proxmox.com/?p=pve-common.git;a=blob;f=src/PVE/JSONSchema.pm> and <https://git.proxmox.com/?p=pve-container.git;a=blob;f=src/PVE/LXC/Config.pm>
* community-scripts (MIT), whose LXC flow this script follows: <https://github.com/community-scripts/ProxmoxVE> and <https://github.com/community-scripts/core> (`pve/backend.func`, `ui/validate.func`)
