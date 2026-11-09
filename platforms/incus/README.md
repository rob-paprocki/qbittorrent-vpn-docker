# Incus installer

`platforms/incus/install.sh` sets up the whole torrent stack in one Incus **system container**: Gluetun (VPN), qBittorrent with VueTorrent, Jackett, FlareSolverr, FileBrowser and the env-editor, all as systemd services inside one Debian 13 container. You run one command, answer a few questions (or none), and open the env-editor in a browser to enter your VPN details.

It runs wherever the `incus` command can manage your Incus server: on the Incus host itself, or on another computer whose `incus` client is set up for that server (see [Remote Incus servers](#remote-incus-servers)).

What the script does, in order:

1. Checks that `incus` is installed, that the server answers, that it can run containers, and that the image can be found.
2. Creates an **unprivileged** Debian 13 container (`images:debian/13`) with CPU and memory limits.
3. Gives it a network card: either on Incus's own bridge (default) or directly on your LAN.
4. Passes the host's `/dev/net/tun` into the container (Gluetun needs it for the VPN tunnel).
5. Optionally mounts a downloads folder from the host, with the right file ownership.
6. Copies this repository into the container at `/opt/torrent-stack` (or `git clone`s it there) and runs `native/install.sh install`, which installs and starts everything.
7. In the default network mode, adds Incus **proxy devices** so the web UIs are reachable on the host's own address.
8. Prints the web addresses and the env-editor login.

The VPN kill switch, the services and their configuration are the job of `native/install.sh`, which is the same on Proxmox and Incus. This script only builds and wires up the container around it.

## Before you start

* **Incus 6.0 LTS or newer.** Tested on Incus 6.0.0 (see [Incus versions](#incus-versions-60-lts-and-newer)). The Incus server must be **x86_64 (amd64) or aarch64 (arm64)**.
* **Permission to manage Incus**: run as root, or as a user in the `incus-admin` group. Members of the plain `incus` group get a restricted personal project that does not allow the devices this stack needs (see [Restricted projects](#restricted-projects)).
* **Internet access from the container**: it downloads Debian packages and the pinned app releases. Behind a proxy, set `TS_GUEST_PROXY=http://proxy:3128`.
* **`/dev/net/tun` on the Incus host** (present on practically every Linux system).
* **A VPN provider with port forwarding** that Gluetun supports (ProtonVPN, PIA, Perfect Privacy, PrivateVPN). See the main [README](../../README.md#prerequisites).
* Optional: **`whiptail`** for the wizard (`apt install whiptail` on Debian/Ubuntu, `newt` on Arch/Fedora). Without it, or without a terminal, the script uses the `TS_*` settings below and their defaults.
* Room for the container: plan for at least 8 GB of disk plus your downloads. 2 CPUs and 4 GiB of memory are the defaults (2 GiB is the practical minimum: Gluetun is compiled during the install, and FlareSolverr runs Chromium).

## Install

On the Incus host (or a computer whose `incus` client talks to it):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)"
```

On a terminal with `whiptail` you get a short wizard:

1. **Proceed?** Yes.
2. **Default or Advanced.** *Default* creates a container called `torrent-stack` with 2 CPUs and 4 GiB, on Incus's bridge, with the web UIs published on the host's address and downloads kept inside the container. *Advanced* asks for each setting (name, image, project, profiles, storage pool, disk size, CPU, memory, network mode, time zone, PUID/PGID, downloads folder, start with Incus).
3. Wait. The first install takes several minutes, longer on a slow connection or CPU (Gluetun is compiled from source).
4. Copy the **env-editor login** printed at the end (also saved inside the container in `/root/torrent-stack.creds`). In proxy mode the summary shows only the user and password there: open the host addresses listed above them. The creds file itself lists the container's own address, which other machines on your LAN cannot reach.
5. Open the env-editor URL, fill in your VPN details, press **Preview changes**, then **Apply**. Gluetun, qBittorrent, Jackett and FlareSolverr start once real VPN settings are saved; until then only the env-editor and FileBrowser run.

Without the wizard (no terminal, `--unattended`, or `TS_UNATTENDED=1`), set what you need as environment variables. Example: a container on the LAN bridge `br0` with downloads on `/tank/downloads`:

```bash
TS_NETWORK_MODE=lan TS_LAN_PARENT=br0 TS_DOWNLOADS_HOST_PATH=/tank/downloads \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)" install.sh --unattended
```

(`install.sh` after the quoted command is only the name bash gives the script; the arguments follow it.)

### All settings

| Variable | Default | What it does |
|---|---|---|
| `TS_NAME` | `torrent-stack` | Container name (also its hostname). |
| `TS_IMAGE` | `images:debian/13` | Image. Must be a Debian 13 container image. |
| `TS_REMOTE` | the client's default remote | Which Incus server to use (`incus remote list`). |
| `TS_PROJECT` | the remote's current project | Incus project. |
| `TS_PROFILE` | `default` | Profile(s), comma separated. The script adds its own network card on top, so the profile only needs a root disk (or set `TS_STORAGE`). |
| `TS_STORAGE` | the profile's root disk pool | Storage pool for the root disk. |
| `TS_DISK_SIZE` | the pool's default | Root disk size, e.g. `16GiB`. The `dir` pool driver ignores sizes. |
| `TS_CPU` | `2` | `limits.cpu`: a number of CPUs, or the CPUs to pin to (`0-3`). |
| `TS_MEMORY` | `4GiB` | `limits.memory`. |
| `TS_NETWORK_MODE` | `proxy` | `proxy` or `lan`; see [Network modes](#network-modes). |
| `TS_NETWORK` | the profile's bridge, else `incusbr0` | proxy mode: which Incus-managed bridge. |
| `TS_PROXY_ADDRESS` | `0.0.0.0` | proxy mode: host address the web UIs listen on (`0.0.0.0` = all of the host's addresses). Can be changed later: see [Changing the host ports or address](#changing-the-host-ports-or-address-later). |
| `TS_PROXY_PORT_OFFSET` | `0` | proxy mode: added to the host-side ports, e.g. `10000` publishes 18090, 19117, ... qBittorrent is special: on a new install its port inside the container moves too (`QBIT_WEBUI_PORT` becomes 18090), because qBittorrent only answers on its own port number. See [qBittorrent's port](#qbittorrents-port-and-the-offset). |
| `TS_LAN_PARENT` | (none) | lan mode: host bridge (e.g. `br0`) or network card (e.g. `enp3s0`). |
| `TS_LAN_NICTYPE` | `auto` | lan mode: `bridged` or `macvlan`; `auto` picks bridged for a bridge, macvlan for a network card, and uses a managed macvlan network as is. |
| `TS_VLAN` | (none) | lan mode: VLAN ID. |
| `TS_IP` | `dhcp` | lan mode: `dhcp` or a static address like `192.168.1.50/24`. |
| `TS_GATEWAY`, `TS_DNS` | (none) | lan mode with a static address: gateway (required) and DNS servers, separated by spaces or commas (default: the gateway). |
| `TS_TZ` | this machine's time zone | Time zone for the container and the apps. |
| `TS_PUID`, `TS_PGID` | `1000` | uid/gid the apps run as inside the container (and own downloaded files). |
| `TS_DOWNLOADS_HOST_PATH` | (none) | Folder on the Incus host to mount at `/mnt/downloads`, e.g. `/srv/downloads` or `/tank/downloads`. Empty: downloads stay on the container disk. System folders (`/usr`, `/var`, `/etc`, `/root`, ...) and bare top folders (`/srv`, `/mnt`, `/home`, ...) are refused. |
| `TS_DOWNLOADS_MAPPING` | `auto` | `auto`, `idmap`, `shift` or `none`; see [Downloads folder](#downloads-folder-from-the-host). |
| `TS_AUTOSTART` | `1` | `boot.autostart`: start the container whenever the Incus server starts. |
| `TS_HOST_WIREGUARD` | `1` | Ask Incus to load the host's `wireguard` kernel module (see [Kernel WireGuard](#kernel-wireguard)). |
| `TS_NESTING` | `0` | Set `security.nesting=true`. The stack does not need it. |
| `TS_GUEST_PROXY` | (none) | HTTP(S) proxy for downloads inside the container, e.g. `http://proxy:3128`. A proxy URL with a user name or password is refused: it would be visible in the host's process list. |
| `TS_SOURCE_DIR` | (none) | Copy this local checkout in instead of cloning from GitHub (how the script is tested). `.git`, `.env*` (except `.env.example`), `configs/` and `downloads/` are not copied. |
| `TS_REF` | `main` | Branch or tag to clone. |
| `TS_REPO_URL` | this project on GitHub | Repository to clone (for forks). |
| `TS_YES` | `0` | `1` = answer yes to the uninstall question (same as `--yes`). |
| `TS_FORCE` | `0` | `1` = allow `--update`/`--uninstall` on a container this script did not create, and let the script change the owner of an existing downloads folder that already holds someone else's files. |

## Network modes

### `proxy` (default): Incus's bridge plus proxy devices

The container sits on Incus's own bridge (normally `incusbr0`, a private network such as `10.x.x.x` that Incus NATs to the internet). Your LAN cannot reach that network directly, so the script adds one Incus **proxy device** per web UI. Incus listens on the host and forwards each connection into the container:

| Device | Host side (listen) | Container side (connect) |
|---|---|---|
| `proxy-env-editor` | `tcp:0.0.0.0:9191` | `tcp:127.0.0.1:9191` |
| `proxy-qbittorrent` | `tcp:0.0.0.0:8090` | `tcp:127.0.0.1:8090` |
| `proxy-jackett` | `tcp:0.0.0.0:9117` | `tcp:127.0.0.1:9117` |
| `proxy-flaresolverr` | `tcp:0.0.0.0:8191` | `tcp:127.0.0.1:8191` |
| `proxy-filebrowser` | `tcp:0.0.0.0:8081` | `tcp:127.0.0.1:8081` |

(The ports are the ones in the container's `.env`; `TS_PROXY_ADDRESS` and `TS_PROXY_PORT_OFFSET` change the host side, except for qBittorrent: see below.) You open `http://<incus-host>:9191` and so on.

Good to know:

* **Nothing else on the host may use those ports.** If one is taken during the install, the script says so, leaves that UI unpublished (the summary marks it) and keeps going. Free the port, or pick other ports (see [Changing the host ports or address later](#changing-the-host-ports-or-address-later)), then run `--sync-ports`, which exits with an error until every UI is published.
* **A port that becomes busy later stops the whole container from starting.** Incus refuses to start a container when one of its proxy devices cannot listen ("Failed to listen on 0.0.0.0:9117 ... address already in use"), and that takes the VPN, the kill switch and every UI down with it. This also happens at boot with `boot.autostart`. `--sync-ports`, `--update` and `--resume` recover from it: they remove the proxy devices, start the container, and add them back, leaving out (and reporting) the busy one. By hand: `incus config device remove torrent-stack proxy-jackett` (the device for the busy port), then `incus start torrent-stack`.
* **After changing a port in the env-editor** (for example `QBIT_WEBUI_PORT`), the proxy device still points at the old one. Re-publish:

  ```bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)" install.sh --sync-ports torrent-stack
  ```

  (`--update` does this too.)
* **Inside the container, every visitor comes from `127.0.0.1`.** These are Incus's non-NAT proxy devices: Incus opens a fresh connection from inside the container for each client. That is what makes them work with the kill switch whether the VPN is up or down (loopback traffic is always allowed). Two consequences:
  * **Never turn on qBittorrent's "Bypass authentication for clients on localhost"** (Tools → Options → Web UI). In this mode it would let everyone who can reach the host in without a password. It is off by default.
  * **Wrong qBittorrent logins lock everyone out.** qBittorrent counts failed logins per client address and, after 5 of them, bans that address for an hour (its defaults). Here every client has the same address, so a mistyped password, or an \*arr app still using an old password after you changed it in the env-editor, locks out every browser and app, *and* the port-forwarding script, which logs in from inside the container. While the ban lasts, a newly forwarded VPN port is not passed on to qBittorrent. The symptom is "Your IP address has been banned after too many failed authentication attempts" in the web UI. Wait an hour, or restart qBittorrent to clear the ban (bans are kept in memory): `incus exec torrent-stack -- systemctl restart torrent-qbittorrent`. If several apps or people log in to qBittorrent, prefer `lan` mode, where every client keeps its own address.

#### Changing the host ports or address later

Set `TS_PROXY_PORT_OFFSET` and/or `TS_PROXY_ADDRESS` on `--sync-ports` (or `--update`). The new values are stored on the container (`user.torrent-stack.proxy-port-offset` and `user.torrent-stack.proxy-address`), the proxy devices move, and later runs keep them:

```bash
TS_PROXY_PORT_OFFSET=10000 bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)" install.sh --sync-ports torrent-stack
```

That publishes the env-editor, Jackett, FlareSolverr and FileBrowser on 19191, 19117, 18191 and 18081. **qBittorrent stays on its own port** (8090 unless you changed it); the script says so. `TS_PROXY_ADDRESS=192.168.1.10` (one of the host's own addresses) publishes them on that address only; `TS_PROXY_ADDRESS=0.0.0.0` goes back to all addresses.

#### qBittorrent's port and the offset

qBittorrent checks the port in every request's `Host` header against the port it listens on, and answers `401 Unauthorized` to everything when they differ (its protection against DNS rebinding; its log then says "WebUI: Invalid Host header, port mismatch"). The browser sends the host-side port, so qBittorrent's host port must equal `QBIT_WEBUI_PORT` in the container. That is why:

* On a **new install** with `TS_PROXY_PORT_OFFSET`, the script also sets `QBIT_WEBUI_PORT` in the container's new `.env` to 8090 + offset (it says so), so every UI moves by the offset.
* **Changing the offset later** moves every UI except qBittorrent. To move qBittorrent, change `QBIT_WEBUI_PORT` in the env-editor (to a free host port), press Apply, then run `--sync-ports`.

Turning off qBittorrent's Host header check would also work, but it weakens that protection, so the script does not do it.
* A host firewall (ufw, firewalld, nftables) must allow the published ports from your LAN.
* `TS_PROXY_ADDRESS=0.0.0.0` publishes on every address of the host. If the host also faces an untrusted network, set it to the host's LAN address.

### `lan`: the container gets its own LAN address

The container's network card is attached to your LAN, so it gets an address from your router like any other machine, and you open `http://<container-ip>:9191`. No proxy devices are used and nothing is published on the host.

* **Bridge** (`TS_LAN_PARENT=br0`, a Linux bridge on the host that contains your LAN card): `nictype=bridged`. The host and the container can reach each other. This is the usual homelab setup.
* **Network card** (`TS_LAN_PARENT=enp3s0`): `nictype=macvlan`. No bridge needed, but **the host itself cannot reach the container** over macvlan (a Linux limitation, see the Incus NIC docs); other machines on the LAN can.
* **Managed macvlan network** (`incus network create lan --type=macvlan parent=enp3s0`, then `TS_LAN_PARENT=lan`): used as is (`network=lan`).
* `TS_VLAN=20` puts the container on a VLAN (bridged and macvlan only).
* **Address:** DHCP by default. The script prints the container's MAC address; reserve the address in your router so it stays the same. Or set a static one with `TS_IP=192.168.1.50/24 TS_GATEWAY=192.168.1.1` (and optionally `TS_DNS="1.1.1.1 9.9.9.9"`); the script writes it to `/etc/systemd/network/05-torrent-stack-eth0.network` in the container before its first boot. Delete that file and restart the container to go back to DHCP.

In both modes the kill switch inside the container keeps qBittorrent, Jackett and FlareSolverr off the internet unless the VPN is up; the web UIs stay reachable from your LAN either way.

## Downloads folder from the host

Without `TS_DOWNLOADS_HOST_PATH`, downloads live on the container's own disk (`/opt/torrent-stack/downloads`) and are deleted with the container.

With it, the host folder is mounted at `/mnt/downloads` (a `disk` device called `downloads`) and the install sets `DOWNLOADS_PATH=/mnt/downloads` and `INCOMPLETE_DOWNLOADS=/mnt/downloads/incomplete` in `.env`.

**Why ownership needs care:** the container is unprivileged, so its uid 1000 is not uid 1000 on the host but a high number (by default 1000000 + 1000). The apps run as `PUID` (1000) inside. You normally want the files to belong to an ordinary user on the host, so you can open them in a Samba share or another container. Incus offers three ways, and `TS_DOWNLOADS_MAPPING` picks one:

| Mapping | How | Host folder owner | Needs |
|---|---|---|---|
| `idmap` | `raw.idmap` maps just `PUID` and `PGID` straight through to the same host ids. Every other container id, root included, stays a high, unprivileged host id. | `PUID:PGID` (e.g. 1000:1000) | Any filesystem. The Incus docs ask for `root:PUID:1` and `root:PGID:1` in the host's `/etc/subuid` and `/etc/subgid` (the script adds them when it runs as root on the Incus host). The container restarts once, and Incus remaps its files when this is first applied. Not allowed in a [restricted project](#restricted-projects) unless `restricted.idmap.uid`/`gid` cover the ids. |
| `shift` | Idmapped mount (`shift=true` on the disk device). No host changes, no restart. | `PUID:PGID` | A kernel and filesystem with idmapped mounts: ext4, xfs, btrfs, ZFS 2.2+ and others; **not NFS or CIFS/SMB** mounts. **On that folder every container id is the same host id, so root in the container is root there** (see [Security notes](#security-notes)). |
| `none` | Plain bind mount. | the container's shifted ids, e.g. 1001000:1001000 | Nothing; but host users see odd owner numbers. |

`auto` (the default) tries `idmap` first, because it keeps the container's root an ordinary high uid on the host, which is what the stack's security relies on. If Incus refuses it (a restricted project) or the container does not start with it, the script tries `shift`. If Incus reports that idmapped mounts are not available (or not allowed) for that folder, it uses `none`. The result is stored in the container's `user.torrent-stack.downloads-mapping` key and printed. Set `TS_DOWNLOADS_MAPPING=shift` if you prefer no changes to the host's `/etc/subuid`.

When the script runs as root on the Incus host, it creates the folder if needed and sets the owner of the folder itself and of its `incomplete/` subfolder (nothing else; existing files are left alone). **An existing folder that already holds files and belongs to someone else keeps its owner:** the script warns and prints the `chown` command instead (or set `TS_FORCE=1` to let it change the owner). A symlink is followed to the real folder, and the real folder must pass the same checks. On a remote server, create the folder first and set its owner as in the table.

## What the script creates

On the Incus server, one container with:

| Item | Value |
|---|---|
| Image | `images:debian/13` (unprivileged; `security.nesting` off) |
| `limits.cpu`, `limits.memory` | `2`, `4GiB` (or your settings) |
| `boot.autostart` | `true` (or `false` with `TS_AUTOSTART=0`) |
| `linux.kernel_modules` | `wireguard` (unless the server cannot load it, or `TS_HOST_WIREGUARD=0`) |
| Device `eth0` (or the name of your profile's NIC device) | `nic`: `network=incusbr0`, or `nictype=bridged`/`macvlan parent=...` |
| Device `tun` | `unix-char`, `source=/dev/net/tun path=/dev/net/tun` |
| Device `downloads` (optional) | `disk`, host folder at `/mnt/downloads` (`shift=true` with the shift mapping) |
| `raw.idmap` (optional) | `uid PUID PUID` / `gid PGID PGID` with the idmap mapping |
| Devices `proxy-*` (proxy mode) | see [proxy mode](#proxy-default-incuss-bridge-plus-proxy-devices) |
| `user.torrent-stack.*` keys | mark the container as created by this script and remember the network mode, proxy settings, downloads mapping and how far the install got (`stage`: `setup`, `install`, `done`) |

Inside the container: the repository at `/opt/torrent-stack` with its `.env`, the services installed by `native/install.sh`, the first-run logins in `/root/torrent-stack.creds`, and the initial settings passed to the installer in `/root/.torrent-stack-incus.env` (time zone, PUID/PGID and download paths; no secrets; written before the container's first boot).

On the Incus host, only when needed: the downloads folder's owner, and `root:PUID:1` / `root:PGID:1` lines in `/etc/subuid` and `/etc/subgid` (idmap mapping).

## Update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)" install.sh --update torrent-stack
```

This starts the container if it is stopped and runs `native/install.sh self-update` in it, the same command you can run yourself inside the container (`incus exec torrent-stack -- bash /opt/torrent-stack/native/install.sh self-update`) and the same one the Proxmox installer uses. `self-update`:

1. gets the new version of `/opt/torrent-stack` from git (with `TS_SOURCE_DIR`, the script copies that folder in first instead); with `TS_REF=<branch or tag>` it switches to that one;
2. upgrades the container's Debian packages (`apt full-upgrade`, keeping config files you changed);
3. runs `native/install.sh update`, which reinstalls only the components whose pinned version changed and restarts only those.

Then the script re-publishes the proxy ports. Your `.env`, app settings and downloads are kept. A checkout updates from its own `origin` (the repository it was cloned from, which may be your fork).

**Your live app settings win over the repository's seed files.** The repository tracks two starting configs, `configs/qbittorrent/qBittorrent/qBittorrent.conf` and `configs/jackett/Jackett/ServerConfig.json`, and the apps rewrite them in place once they run. A plain `git pull` would refuse to update whenever a new commit changes one of them, so don't use it. `self-update` updates every file outside `configs/` and never writes into `configs/` (those folders belong to the apps' user), so your live files stay exactly as they are.

**While the VPN is down, the update cannot download anything**: once Gluetun runs, even root in the container reaches the internet only through the VPN. `self-update` says so and stops; stop Gluetun (`incus exec torrent-stack -- systemctl stop torrent-gluetun`), run the update, then start it again (`incus exec torrent-stack -- systemctl start torrent-gluetun`). The kill switch keeps the apps offline meanwhile.

### If the install stopped half-way

The script prints what to do next, depending on how far it got:

* **It failed while setting up the container** (the network card, `/dev/net/tun`, the downloads folder and its id mapping, before anything was installed in it): fix the cause it printed, remove the container with `incus delete --force torrent-stack` and run the installer again with the corrected `TS_*` settings. `--resume` refuses such a container, because those steps depend on the settings that need changing. A new install with the same name says so too.
* **It failed in the in-container part** (packages, getting the repository, `native/install.sh install`): `install.sh --resume torrent-stack` re-runs that part with the same settings (time zone, PUID/PGID, downloads paths are already saved in the container). The printed command repeats `TS_SOURCE_DIR`, `TS_PROJECT` and the like when you used them.

## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)" install.sh --uninstall torrent-stack
```

It shows what will be deleted and asks first (`--yes` skips the question for scripts). The container name and the options can come in any order: `--uninstall torrent-stack --yes` and `--uninstall --yes torrent-stack` do the same; the same goes for `--update`, `--sync-ports` and `--resume`. It deletes the container with everything inside it (`.env`, VPN settings, app configs, downloads on the container disk) and its proxy devices. **A downloads folder mounted from the host is not touched.** Lines the script added to `/etc/subuid`/`/etc/subgid` stay; remove them by hand if nothing else uses them.

To remove only the stack but keep the container: `incus exec torrent-stack -- bash /opt/torrent-stack/native/install.sh uninstall`.

## Remote Incus servers

The script talks to whatever `incus remote get-default` points at, or to `TS_REMOTE`. Everything goes through the Incus API, so it works the same for a remote server, except:

* It cannot create or chown the downloads folder or edit `/etc/subuid` on a remote server. Prepare those yourself (see [Downloads folder](#downloads-folder-from-the-host)); the script tells you what is needed.
* In proxy mode the printed URLs use the remote's host name from `incus remote list`.

## Kernel WireGuard

Gluetun uses the kernel's WireGuard when the host has the module loaded, and a slower userspace WireGuard otherwise. A container cannot load kernel modules, so the script sets `linux.kernel_modules=wireguard`, which makes Incus load it on the host before each start. If the server cannot load it (no such module), Incus would refuse to start the container; the script then removes the setting again, prints a warning and continues with userspace WireGuard. In a [restricted project](#restricted-projects) Incus refuses the setting itself; the script warns and carries on without it.

If a later host kernel lacks the module, Incus refuses to start the container (also at boot) until the setting is removed. `--update`, `--resume` and `--sync-ports` remove it for you. By hand: `incus config unset torrent-stack linux.kernel_modules`, then `incus start torrent-stack`. `TS_HOST_WIREGUARD=0` at install time skips the setting altogether.

## Security notes

* The container is **unprivileged** and `security.nesting` is **not** set: the stack runs no containers inside, and its services start without it. The script refuses to continue if a profile makes the container privileged.
* `/dev/net/tun` inside the container is root-owned with mode 0660 (the Incus default for `unix-char` devices). Only Gluetun, which runs as root, opens it.
* **Downloads folder and `shift=true`.** With the `idmap` mapping (what `auto` picks when it can), only `PUID`/`PGID` are the same inside and outside; root in the container is still an ordinary high uid on the host, including on the downloads folder. With `shift=true` (picked by `auto` only when `idmap` cannot be used, or when you ask for it), *every* container id is the same host id on that folder, so **root in the container is root on that folder**. Gluetun and the env-editor run as root and face the network, so a compromise of either could leave setuid-root programs in the host's downloads folder. Incus does not mount host folders `nosuid`. If you use `shift`, mount the host filesystem that holds the folder with `nosuid`, or on ZFS run `zfs set setuid=off tank/downloads`, and never run programs from the downloads folder on the host.
* The env-editor and FileBrowser are published on every host address in proxy mode (as in the Docker stack). Use `TS_PROXY_ADDRESS` or a host firewall if the host is reachable from untrusted networks.
* In proxy mode, qBittorrent sees every client as `127.0.0.1` (see [proxy mode](#proxy-default-incuss-bridge-plus-proxy-devices)): keep "Bypass authentication for clients on localhost" off, and expect one client's wrong passwords to lock out everyone for an hour.
* `TS_GUEST_PROXY` is passed to `incus exec` on its command line, which other users of the machine can see, so a proxy URL with a password is refused.
* As root on the Incus host, the script changes the owner of the downloads folder. To keep a typo from handing a system folder to uid 1000, system folders and bare top folders are refused (after following symlinks), and a folder that already holds someone else's files keeps its owner unless `TS_FORCE=1`.
* Some Debian/Ubuntu hosts with AppArmor 4 and older Incus 6.0.x packages blocked systemd's `PrivateUsers=` sandboxing inside containers (fixed in Debian's incus 6.0.3-5). If a service fails with "Failed to set up user namespacing: Permission denied", update Incus on the host.

### Restricted projects

A restricted project (`restricted=true`, as used for the per-user projects of the `incus` group) blocks `unix-char` devices, proxy devices, host-path disk devices, non-managed NICs (`nictype=bridged`/`macvlan`) and low-level options by default. The script warns when the project is restricted. Without the devices, creating the container fails with Incus's own error. Use an unrestricted project, or have an admin allow `restricted.devices.unix-char`, `restricted.devices.proxy`, `restricted.devices.disk` (and `restricted.devices.disk.paths`) and `restricted.devices.nic` as needed.

A restricted project always has its own profiles, and its `default` profile may have no root disk or network card. The script adds its own network card; set `TS_STORAGE` to a storage pool for the root disk (the script says so if it is needed).

Two low-level options the script uses are refused there too, and neither is fatal:

* `linux.kernel_modules` (kernel WireGuard): skipped with a warning; Gluetun uses userspace WireGuard unless the host already has the module loaded. `restricted.containers.lowlevel=allow` permits it.
* `raw.idmap` (the `idmap` downloads mapping): allowed only for host ids covered by the project's `restricted.idmap.uid` and `restricted.idmap.gid` (or with `restricted.containers.lowlevel=allow`). Otherwise `auto` falls back to `shift`. But Incus also refuses `shift=true` for a folder that is allowed through `restricted.devices.disk.paths` ("The "shift" property cannot be used with a restricted source path"), so in a restricted project `auto` normally ends at `none`, and the host folder belongs to the container's shifted ids.

## Incus versions (6.0 LTS and newer)

The script is written for and tested on **Incus 6.0 LTS** and uses only commands and options that exist there. Notes for newer releases:

* **Incus 7.0 LTS** (April 2026) changed `incus file push`/`pull` to behave like `cp` for directories. The script never pushes directories with `incus file push -r`: it streams the repository as a tar archive through `incus exec`, which behaves the same on every version. Single-file pushes (the settings and static-IP files) are unaffected.
* Incus 7.0 removed the iptables (xtables) firewall backend and cgroup v1 support and requires Linux 6.12+. That matters for the host, not for this script.
* **Incus 6.21** added `incus wait`. The script does not use it; it polls inside the container (systemd state, address, default route, DNS), which works on 6.0.
* `incus network list` has no `--columns` option in 6.0; the script reads its default CSV columns (name, type, managed).
* `shiftfs` is not supported by Incus at all; `shift=true` means kernel idmapped mounts on every Incus version.

## Limitations

* One container per stack. Running two copies on one host in proxy mode needs different ports for the second: install it with `TS_PROXY_PORT_OFFSET` (which also gives its qBittorrent its own port; see [qBittorrent's port](#qbittorrents-port-and-the-offset)).
* Proxy mode is IPv4 only (the proxy devices listen on an IPv4 address).
* Proxy mode hides the clients' real addresses from the apps (they all see `127.0.0.1`). Incus's NAT-mode proxy devices would keep them, but they need a static container address and a specific host address, which this script does not set up; use `lan` mode if the real addresses matter to you.
* Port changes made in the env-editor only reach the host's proxy devices when you run `--sync-ports` (or `--update`): the devices are host-side settings that a change inside the container cannot move.
* Static addresses are only set up in lan mode, and only on images that configure `eth0` with systemd-networkd (the `images:debian/13` image does).
* `TS_SOURCE_DIR` updates copy changed and new files but do not delete files that were removed from the source.
* The client must be Linux with bash 4.4+ and GNU tar (for `TS_SOURCE_DIR`).
* VMs are not supported: the stack is built for a system container.

## What was tested, and what was not

What was tested, on Ubuntu 24.04 with Incus 6.0.0 (LXC 5.0.3, kernel 6.18, `dir` storage pool, nftables firewall), against the real local Incus daemon, with `TS_SOURCE_DIR` pointing at a temporary copy of the repository in which `native/install.sh` is replaced by [`tests/stub-native-install.sh`](tests/stub-native-install.sh). The stub records the arguments and environment it is called with, creates `.env` like the real installer, writes `/root/torrent-stack.creds` in the real format and serves a small web page on every web UI port. [`tests/run-tests.sh`](tests/run-tests.sh) runs these checks:

* **Checks and validation:** bad names, memory sizes, profiles, missing images, static IP outside lan mode, lan mode without or with an unknown parent, Incus's own bridge given as a LAN, `--update` of a missing container (also with the name after another option), two container names, two actions, a name without an action, `--resume` without a name, an unknown option. Downloads folders inside system trees (`/etc`, `/root/.ssh`, `/usr/local/bin`, `/usr/bin`, `/boot/efi`, `/var/log`, `/var/lib/docker`, `/lib/modules`), bare top folders (`/srv`, `/mnt/`, `/home//`) and a symlink that leads into `/etc`. A `TS_GUEST_PROXY` with a password (refused, and the password is not echoed). Each is refused with a clear message and nothing is created.
* **Proxy mode** (managed bridge `incusbr0` + proxy devices): container created unprivileged, no nesting, with `limits.cpu`, `limits.memory`, `boot.autostart`; `/dev/net/tun` opens inside the container; `.env`, `.env.*` backups, `configs/` and `downloads/` from the source are not copied; the initial settings (`TZ`, `PUID`, `PGID`, `DOWNLOADS_PATH`, `INCOMPLETE_DOWNLOADS`) reach `native/install.sh install`; all five web UIs answer through the proxy devices on the host's loopback and LAN address (seen from inside as `127.0.0.1`); the summary shows the first-run logins from `/root/torrent-stack.creds` without the container's own URLs. Busy ports and port changes:
  * A host port that is already taken during the install is reported and marked "not published" without failing the install, and `--sync-ports` publishes it once free.
  * After changing `QBIT_WEBUI_PORT` in `.env`, `--sync-ports` moves the proxy device and closes the old port. The same works for an override line appended at the end of `.env`, which used to make `--sync-ports` and `--update` stop with an internal error.
  * `TS_PROXY_PORT_OFFSET` and `TS_PROXY_ADDRESS` given on `--sync-ports` move all devices and are kept for later runs. That includes a move where one UI's new port is another UI's old port, which used to fail. With `TS_PROXY_ADDRESS=127.0.0.1` the UIs answer on loopback but not on the LAN address. A bad offset is refused.
  * A host port taken while the container was stopped: a plain `incus start` fails, and `--sync-ports` starts the container without that proxy device, re-publishes the others, reports the busy one and exits 1, then exits 0 once the port is free again.
  * The printed update command repeats `TS_SOURCE_DIR` and the local script path.
* **Downloads folder:** `auto` picks `idmap` (`raw.idmap` maps only uid/gid 1000, no `shift=true`): `root:1000:1` added to `/etc/subuid`/`/etc/subgid`, the container restarted, `/mnt/downloads` is `1000:1000` inside, and a file written there as uid 1000 is `1000:1000` on the host. The `none` mapping with PUID 1001: the host folder belongs to the shifted uid 1001001 and shows as 1001:1001 inside (with `TS_FORCE=1` on a folder that already held a file owned by 1234, which kept its owner). An existing folder that holds someone else's files, without `TS_FORCE`: its owner and its files' owner are unchanged, no `incomplete/` is created in it, and the script warns that the apps may not be able to write.
* **Restricted project** (`restricted=true`, unix-char, proxy and the downloads path allowed, low-level options blocked): `linux.kernel_modules` and `raw.idmap` are refused by Incus with a warning and the install carries on; `shift=true` is refused too ("cannot be used with a restricted source path"), so `auto` ends at `none`, with `/mnt/downloads` as `1000:1000` inside; the env-editor answers through its proxy device; uninstall works.
* **Setup failures:** a profile that makes the container privileged, and `TS_DOWNLOADS_MAPPING=shift` where Incus cannot do idmapped mounts. Both make the script stop with the cause, print "remove the container and run the installer again" with the `incus delete` command and no `--resume` hint, and leave `stage=setup`. A new install with the same name says to remove the leftover first. `--resume` refuses such a container and runs nothing in it. The settings file (time zone, PUID) is already in the container.
* **Update, resume, uninstall:** `--update` copies the new source (or, from git, leaves that to the guest), runs `native/install.sh self-update` and re-checks the proxies; `--resume` re-runs the install with the saved settings; `--uninstall` refuses without `--yes` when there is no terminal, then deletes the container and its proxy devices and leaves the host downloads folder and its files in place. The container name is taken before or after `--yes`; two names, two actions, a name without an action and `--resume` without a name are refused before anything happens.
* **git mode:** a `git daemon` on the Incus bridge stood in for GitHub, with the repository's real seed files under `configs/`. The container clones `TS_REPO_URL` at `TS_REF`, `--update` runs `native/install.sh self-update` (the stub sources the real installer's git step), brings a new commit and names the checkout's own origin. After the live `qBittorrent.conf` was changed in the container (as the apps do) and the seed changed upstream, `--update` succeeded (a plain `git pull` refused this), brought the new commit, and kept the live file with its owner and mode. A further `--update` says "already up to date".
* **Project:** `TS_PROJECT` creates, updates, re-publishes and removes the container in another project, and the printed commands name the project.
* **LAN mode:** `nictype=bridged` on a Linux bridge with a DHCP server (dnsmasq) and NAT, standing in for a home LAN: DHCP address, printed LAN URLs, UIs reachable on the container's address, `--sync-ports` refused, update. Static IPv4 on the same bridge (systemd-networkd file) with `TS_DNS="8.8.8.8,8.8.4.4"`: one `DNS=` line per server (comma-separated input used to be glued into one invalid address), and systemd-networkd accepted both. `nictype=macvlan` on a veth interface standing in for a network card, reached from the host through a host-side macvlan, with DHCP.
* **Wizard:** the Advanced path with a recording `whiptail` stand-in on a pseudo-terminal: the answers (CPU, memory, network mode, port offset, time zone, no autostart) end up in the container.
* **Failure in the in-container part:** a failing `native/install.sh` makes the script exit non-zero, print the `--resume` command (with `TS_SOURCE_DIR` and the local script path) and the `incus delete` command, and keep the install log (mode 0600); running the printed `--resume` command exactly as printed finishes the install (`stage=done`).
* **Kernel WireGuard fallback:** the test host has no `wireguard` module (and no `modprobe`), so Incus refuses `linux.kernel_modules=wireguard`; the script removed it and started the container with a warning, every time.
* `bash -n` and `shellcheck -S warning` (0.11.0) are clean on `install.sh` and both test scripts. The final full run (`run-tests.sh --with-lan`) passed all 228 checks (201, plus 27 in the `lan-*` tests), and the runner put `/etc/subuid` and `/etc/subgid` back as they were.

**Real install with the final `native/install.sh`** (not the stub), on the same machine, in proxy mode with `TS_PROXY_PORT_OFFSET=30000`, `TS_PROXY_ADDRESS=127.0.0.1` and `TS_SOURCE_DIR` (the test machine intercepts TLS, so its CA was added to the test container; that is a test-network fixture, not something a normal LAN needs):

* The first run was started without that CA on purpose, so `native/install.sh install` failed (no internet): the script kept the install log (mode 600) and printed the `--resume` command. After adding the CA, `--resume` finished, and removed the kept log ("Removed the install log the failed run had kept").
* The output of `native/install.sh` showed up while it ran (on a pseudo-terminal: the first lines after 2 s, the downloads at 58 s, the end at 70 s), not all at the end.
* qBittorrent got `QBIT_WEBUI_PORT=38090` inside the container and the proxy device `listen=tcp:127.0.0.1:38090 connect=tcp:127.0.0.1:38090`. After filling in (fake) VPN settings and a qBittorrent login, logging in to qBittorrent **through the proxy device** returned 204, `/api/v2/app/version` answered `v5.3.0`; the same login with a `Host:` header naming another port returned 401 (qBittorrent's check, which used to break every request through an offset port). The env-editor answered 401 without and 200 with the first-run login, and FileBrowser, Jackett and FlareSolverr answered on their offset ports.
* The summary listed both first-run logins from `/root/torrent-stack.creds` (env-editor and FileBrowser). After the summary was changed to leave out the creds file's container URLs in proxy mode, a second real install (offset 40000, the same CA fixture, then `--resume`) showed both logins as `user: admin   password: ...` under the host URLs, the env-editor answered 401 without and 200 with that login through the proxy device, `reset-login` printed the new FileBrowser wording, and `--uninstall --yes fx2-native` (options before the name) deleted the container.
* A `QBITTORRENT_PASSWORD=Fx-pass-123 # set by the fx test` line in `.env`: qBittorrent got `Fx-pass-123` (the comment is not part of it, as in Docker Compose), and so did Gluetun's environment for the port-forward script.
* `apply` with the VPN key put back to the placeholder said "Left stopped until the VPN settings are filled in: gluetun qbittorrent jackett flaresolverr" instead of listing them as restarted.
* Kill switch, with Gluetun stopped and with Gluetun running but not connected: the `torrent` user had no internet and no DNS (HTTPS by name and by IP, DNS to the LAN, 1.1.1.1, 8.8.8.8 and the resolved stubs, ICMP), also inside the apps' own view; no packet from those probes left on `eth0` (the only packets seen were the replies to Gluetun's own WireGuard attempts).
* `--update` while Gluetun ran unconnected **failed** with the "stop Gluetun first" advice (before, it printed "[ OK ] Updated Debian packages" although nothing was fetched: `apt-get update` exits 0 then, `apt-get update --error-on=any` exits 100, both checked in the container). With Gluetun stopped, `--update` copied the source in and ran `native/install.sh self-update`: no git step for a copy, Debian packages upgraded, "Nothing changed; no service restarted".
* `native/install.sh reset-login`: a new password, the old one refused (401) and the new one accepted (200) through the proxy device, the new password not in the env-editor's journal, `/root/torrent-stack.creds` rewritten (mode 600).
* The port-forward script (`update-qbittorrent.sh`) logged in to qBittorrent 5.3 and set the forwarded port, and skipped the Discord message because the webhook was still the `.env.example` placeholder.

The same final `native/install.sh` was also installed **from git** (a local `git daemon` with a snapshot of this branch) through the Proxmox script; there the git update path (`self-update` after an upstream commit that changed the qBittorrent seed) was checked on the real stack. See [platforms/proxmox/README.md](../proxmox/README.md).

**Not tested** (not possible here, or not done):

* This script's git path with the real stack: here it ran with the stub (`--update` now goes through the real `native/install.sh` git step, which the stub sources); the real stack from git was installed through the Proxmox script only.
* A real `shift=true` idmapped mount: this machine's Incus refuses them ("Required idmapping abilities not available"), so only the refusal and the fallback were seen.
* Kernel WireGuard via `linux.kernel_modules` actually loading the module (no module on the test host). Real VPN connections (no VPN account). The qBittorrent login ban in proxy mode was checked in qBittorrent's source, not reproduced.
* A real LAN, router and physical NIC, VLANs (`TS_VLAN`), and managed macvlan networks (`TS_LAN_PARENT` naming an Incus macvlan network).
* A remote Incus server over HTTPS (`TS_REMOTE`), restricted projects with `restricted.idmap.uid`/`gid` set (where `idmap` would be allowed), `TS_GUEST_PROXY` without a password, `TS_DISK_SIZE` (the `dir` pool ignores sizes), ZFS/btrfs/LVM pools.
* Incus releases other than 6.0.0 (including 7.0 LTS), aarch64 servers, and hosts with AppArmor enabled (the test machine has no AppArmor).
* `boot.autostart` across a reboot of the Incus server, including the busy-port case at boot (the shared test daemon could not be restarted).
* The wizard on a real terminal with the real `whiptail`, and its Default path.

### Running the tests yourself

On a spare machine with Incus (as root): `bash platforms/incus/tests/run-tests.sh`. The tests publish the web UIs on the host ports 8090, 8081, 8191, 9117 and 9191 plus 20000 and plus 21000, and qBittorrent also on 8097 and 8099. The runner first checks that nothing else listens on those ports and stops, naming them, if something does; then pick other ports with, for example, `TS_TEST_PORT_OFFSET=40000`. Add `--with-lan` for the LAN tests, which temporarily create test network interfaces, an nftables NAT table and DHCP servers on that machine. Every test container is called `in-...` and is deleted afterwards, as are the test projects `in-proj` and `in-rproj` and the test profile `in-priv`. The `idmap` tests add `root:1000:1` lines to `/etc/subuid` and `/etc/subgid`; the test runner saves both files first and puts them back exactly as they were when it ends. The test runner also starts short-lived helpers on the host (a `git daemon` on the Incus bridge, small Python listeners that occupy a port) and stops them at the end. The real-stack check above was run by hand.

## Troubleshooting

* **"Could not publish ... address already in use"**: another program on the host uses that port. Free it, or move the UIs with `TS_PROXY_PORT_OFFSET=10000 ... --sync-ports torrent-stack` (see [Changing the host ports or address later](#changing-the-host-ports-or-address-later)), or change the app's port in the env-editor and then run `--sync-ports`. For qBittorrent only the last one works (see [qBittorrent's port](#qbittorrents-port-and-the-offset)).
* **qBittorrent answers 401 to everything (even the login page) through the host port**: its host port differs from `QBIT_WEBUI_PORT` in the container, for example after a proxy device was edited by hand. Run `--sync-ports torrent-stack`, which publishes it on its own port again.
* **Lost the env-editor login**: `incus exec torrent-stack -- bash /opt/torrent-stack/native/install.sh reset-login` makes a new password, prints it once and saves it in `/root/torrent-stack.creds` in the container. Until you set a real qBittorrent login, FileBrowser uses the same new password.
* **The container does not start: "Error occurred when starting proxy device ... Failed to listen on ..."**: a host port of one of the UIs was taken while the container was stopped (or before the host booted). Run `--sync-ports torrent-stack`: it starts the container without the busy port and tells you which one it is. Or remove that device by hand: `incus config device remove torrent-stack proxy-<name>` (names: `proxy-env-editor`, `proxy-qbittorrent`, `proxy-jackett`, `proxy-flaresolverr`, `proxy-filebrowser`), then `incus start torrent-stack`.
* **qBittorrent says "Your IP address has been banned after too many failed authentication attempts"** (proxy mode): someone, or an app, used a wrong password 5 times; everyone shares 127.0.0.1 in proxy mode. Fix the password in that app, then wait an hour or run `incus exec torrent-stack -- systemctl restart torrent-qbittorrent`.
* **"Container 'torrent-stack' is left over from an install whose setup failed"** or **"--resume cannot finish it"**: the first install stopped before anything was installed. `incus delete --force torrent-stack`, then install again.
* **The container does not start: "Failed to load kernel module"**: the host kernel no longer has the `wireguard` module. `incus config unset torrent-stack linux.kernel_modules`, then `incus start torrent-stack` (or run `--update`, which does that).
* **"The container has no working network"**: in lan mode, the parent interface does not reach a DHCP server (or the static settings are wrong). Check with `incus exec torrent-stack -- ip addr`.
* **Downloads not writable**: check the owner of the host folder against the table in [Downloads folder](#downloads-folder-from-the-host); `incus exec torrent-stack -- ls -ln /mnt/downloads` shows what the container sees.
* **Logs of a failed install** are kept (readable only by you) in `~/torrent-stack-<name>-install.log`. Container start problems: `incus info --show-log torrent-stack`.
* **Service status**: `incus exec torrent-stack -- bash /opt/torrent-stack/native/install.sh status`.

## References

* qBittorrent 5.3.0 source, Host header check (`validateHostHeader()`: a port other than the server's own is refused with 401): <https://github.com/qbittorrent/qBittorrent/blob/release-5.3.0/src/webui/webapplication.cpp>
* apt-get `--error-on=any` (fail the update on any error, even a transient one): <https://manpages.debian.org/trixie/apt/apt-get.8.en.html>
* Incus 6.0 docs, proxy devices: <https://linuxcontainers.org/incus/docs/stable-6.0/reference/devices_proxy/>
* Incus 6.0 docs, unix-char devices: <https://linuxcontainers.org/incus/docs/stable-6.0/reference/devices_unix_char/>
* Incus 6.0 docs, disk devices: <https://linuxcontainers.org/incus/docs/stable-6.0/reference/devices_disk/>
* Incus 6.0 docs, NIC devices (bridged, macvlan, host access): <https://linuxcontainers.org/incus/docs/stable-6.0/reference/devices_nic/>
* Incus 6.0 docs, idmaps and `raw.idmap`: <https://linuxcontainers.org/incus/docs/stable-6.0/userns-idmap/>
* Incus 6.0 docs, instance options (`boot.autostart`, `limits.*`, `linux.kernel_modules`, `security.*`): <https://linuxcontainers.org/incus/docs/stable-6.0/reference/instance_options/>
* Incus 6.0 docs, project restrictions: <https://linuxcontainers.org/incus/docs/stable-6.0/reference/projects/>
* Incus 6.0 source, the low-level options a restricted project blocks (`linux.kernel_modules`, `raw.idmap`, ...) and the `restricted.idmap.*` check: <https://github.com/lxc/incus/blob/stable-6.0/internal/server/project/permissions.go>
* Incus 6.0 source, disk device mount options (no `nosuid` on host folders; `shift=true` = dynamic owner shift): <https://github.com/lxc/incus/blob/stable-6.0/internal/server/device/disk.go>
* Incus 6.0 source, `raw.idmap` merged into the container's id map: <https://github.com/lxc/incus/blob/stable-6.0/internal/server/instance/drivers/driver_lxc.go>
* qBittorrent 5.3.0 source, login bans per client address (`clientId()`, `isBanned()`): <https://github.com/qbittorrent/qBittorrent/blob/release-5.3.0/src/webui/webapplication.cpp>; defaults of 5 failures and 3600 s: <https://github.com/qbittorrent/qBittorrent/blob/release-5.3.0/src/base/preferences.cpp>
* Incus 7.0 LTS release notes (file push changes, removals): <https://discuss.linuxcontainers.org/t/incus-7-0-lts-has-been-released/26641>
* Incus 6.21 announcement (`incus wait`): <https://stgraber.org/?p=1838>
* shiftfs removed from Incus, idmapped mounts instead: <https://discuss.linuxcontainers.org/t/migrating-lxd-5-20-incus-0-5-on-ubuntu-22-04-lts-zfs-2-1-5-and-shiftfs-support/19087/2>
* Sharing a host folder with `shift=true` / `raw.idmap`: <https://blog.simos.info/how-to-share-a-folder-between-a-host-and-a-container-in-incus/>
* AppArmor 4 and `PrivateUsers=` in Incus containers: <https://discuss.linuxcontainers.org/t/debian-testing-incus-server-prometheus-fails-to-start-in-container/23206>
* community-scripts/ProxmoxVE (MIT), source of the wizard style: <https://github.com/community-scripts/ProxmoxVE>
* Design contract for all installers: [`platforms/DESIGN.md`](../DESIGN.md)
