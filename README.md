# qbittorrent-vpn-docker

[![Licence: MIT](https://img.shields.io/badge/licence-MIT-0969da)](LICENSE)
[![lint workflow status (shellcheck, Compose and image checks)](https://github.com/rob-paprocki/qbittorrent-vpn-docker/actions/workflows/lint.yml/badge.svg)](https://github.com/rob-paprocki/qbittorrent-vpn-docker/actions/workflows/lint.yml)

This stack runs qBittorrent and Jackett so that they reach the internet only through your VPN, and keeps the VPN's forwarded port in qBittorrent so your torrents seed.

If you run a home server or NAS and don't want your torrent client to show your own IP address, this stack does what you'd otherwise do by hand: it puts the apps inside a VPN container's network, copies the VPN's forwarded port into qBittorrent every time it changes, and connects qBittorrent's search to Jackett. A small web form, the env-editor, fills in the settings and logins for you.

It runs with Docker Compose on any Linux host, and one-line installers set it up on Proxmox VE, Incus, TrueNAS, Unraid, Synology DSM and CasaOS/ZimaOS. It was made for the Docker VM that the companion repo [docker-pve](https://github.com/rob-paprocki/docker-pve) creates, where [Dockhand](https://dockhand.pro) keeps the images up to date.

## Highlights

- **The VPN or nothing.** qBittorrent, Jackett and FlareSolverr share [Gluetun](https://github.com/qdm12/gluetun)'s network and have none of their own. If the VPN drops, they lose their connection instead of falling back to yours.
- **Torrents keep seeding.** Gluetun hands every new forwarded port to qBittorrent, with an optional Discord message.
- **A web form instead of config files.** The env-editor writes `.env`, sets qBittorrent's login, connects its search to Jackett, and restarts only what a change affects.
- **Six one-line installers**, plus plain Docker Compose anywhere else.
- **Image updates** come from Dockhand, the platform's own updater or the stack's optional Watchtower. Native mode pins every version instead.
- **FileBrowser shows only the downloads**, never `.env` or the app configs.

## How it works

![Diagram of the stack. At the top is the VPN provider, then the internet. A two-way arrow marked "only way out" joins it to a box called Gluetun's network. Inside the box, Gluetun (VPN tunnel and firewall, publishing ports 8090, 9117 and 8191) passes the forwarded port to qBittorrent with VueTorrent on 8090. qBittorrent searches through Jackett on 9117, and Jackett uses FlareSolverr on 8191. Below the box, outside it, are the env-editor on port 9191, which runs on the host, edits .env and restarts the apps, and FileBrowser on 8081, which has its own network and shows the downloads. A note at the bottom says that native mode on Proxmox VE and Incus runs the same apps as systemd units in one Debian 13 container, kept on the VPN by an nftables kill switch.](docs/images/architecture.svg)

1. Gluetun connects to your VPN provider. qBittorrent, Jackett and FlareSolverr share its network (`network_mode: service:gluetun`), so their traffic goes through the tunnel or nowhere.
2. Their web UIs are published on the `gluetun` container. The default ports are 8090 for qBittorrent with [VueTorrent](https://github.com/VueTorrent/VueTorrent), 9117 for Jackett and 8191 for FlareSolverr.
3. When the VPN assigns a forwarded port, Gluetun runs `update-qbittorrent.sh`, which logs in to qBittorrent and sets it as the listening port.
4. qBittorrent searches through Jackett at `127.0.0.1:9117`. Jackett passes sites behind a Cloudflare challenge to FlareSolverr.
5. FileBrowser (8081) has its own network and shows only the downloads.
6. The env-editor (9191) runs on the host. It edits `.env` and restarts what a change affects.
7. Native mode on Proxmox VE and Incus runs the same apps as systemd units in one Debian 13 container. Its network stays up when Gluetun stops, so an nftables kill switch lets the apps out only through the tunnel ([native/README.md](native/README.md)).

## Prerequisites

Every platform needs **a VPN provider that supports port forwarding through Gluetun**. The port-update flow depends on it. Gluetun currently covers ProtonVPN, Private Internet Access, Perfect Privacy and PrivateVPN. NordVPN, Mullvad and AirVPN are not supported on this path: the stack will connect, but qBittorrent's listen port will stay at 0 and nothing will seed. Gluetun's wiki has [the current list](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md).

From your provider you need the WireGuard private key and address, or an OpenVPN user name and password. ProtonVPN users on OpenVPN add `+pmp` to the user name to get port forwarding.

## Choose your platform

Each installer is one command, run as root on the platform itself (on Incus, a member of the `incus-admin` group will do). Read the platform's guide first: it says what you need, what the script creates, how to update and uninstall, and what was tested.

**Any Linux host with Docker** (Docker): no installer, see [Quick start](#quick-start). [Guide](platforms/docker/README.md)

**Proxmox VE 8 or 9** (native): one LXC container, run in the host's **Shell**. [Guide](platforms/proxmox/README.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh)"
```

**Incus 6.0 or newer** (native): one system container, run on the Incus host. [Guide](platforms/incus/README.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)"
```

**TrueNAS 25.10** (Docker): a custom app, run in **System > Shell** after `sudo -i`. [Guide](platforms/truenas/README.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)"
```

**Unraid 7** (Docker): a Compose Manager Plus stack, run in the web UI's terminal. [Guide](platforms/unraid/README.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/unraid/install.sh)"
```

**Synology DSM 7.2 or later** (Docker): a Container Manager project, run over SSH after `sudo -i`. [Guide](platforms/synology/README.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)"
```

**CasaOS or ZimaOS** (Docker): one dashboard app, run in a root shell. [Guide](platforms/casaos/README.md)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/casaos/install.sh)"
```

No GitHub release is published yet, so the one-liners install from `main`. With no terminal, an installer reads `TS_*` variables instead of asking. `TS_REF=<branch or tag>` installs a version other than `main`, and `TS_SOURCE_DIR=/path/to/checkout` uses a local copy. Options go after the quoted command, as in `bash -c "$(curl ...)" install.sh --help` (`install.sh` is only the name bash gives the script).

On Proxmox VE there are two ways to run it. The Proxmox installer puts the stack in one unprivileged LXC container, without Docker, with the kill switch and pinned versions. Or create a Docker VM with docker-pve and follow the Quick start in it: that suits you if you run other Compose stacks there too, and Dockhand updates the images.

## Quick start

This is the path for any Linux host with Docker, such as the VM docker-pve creates.

### Setup

You need Docker Engine 20.10+ with the Compose plugin, `git`, Python 3.9+ with its `venv` module (`python3-venv` on Debian and Ubuntu), and a root shell. The [Docker guide](platforms/docker/README.md#before-you-start) has the full list.

As root, clone the stack into `/opt/stacks/torrent-stack`:

```bash
mkdir -p /opt/stacks
cd /opt/stacks
git clone \
  https://github.com/rob-paprocki/qbittorrent-vpn-docker.git \
  torrent-stack
cd torrent-stack
```

Create the folders the apps write to, owned by uid and gid 1000 (`PUID` and `PGID`):

```bash
mkdir -p configs/filebrowser
mkdir -p downloads/incomplete
chown -R 1000:1000 configs downloads
```

Start the setup editor. Its first run builds a Python venv, then prints a password for the user `admin`, once. Write it down.

```bash
./scripts/setup.sh
```

Open `http://<host>:9191` and log in. Fill in your VPN details and a qBittorrent user and password, then press **Preview changes** and **Apply**. The editor writes `.env`, sets qBittorrent's login and its Jackett search, and starts the stack. It refuses a password FileBrowser can't use (see [the FAQ](#troubleshooting-and-faq)).

> [!WARNING]
> The editor serves plain HTTP on every interface, and its form holds your VPN key. It runs in the foreground: press Ctrl+C when you're done, and start it again with `./scripts/setup.sh` when you need it. The [Docker guide](platforms/docker/README.md#setup) shows how to keep it on `127.0.0.1` behind an SSH tunnel.

The full walkthrough, adding indexers, and setting it up without the editor are in the [Docker guide](platforms/docker/README.md#setup).

### Deploy on the paired docker-pve VM (Dockhand)

On the VM that docker-pve creates, do the [Setup](#setup) above as root. Then open Dockhand at `http://<vm>:3000`, choose **Stacks → Adopt** and select `torrent-stack`. Keep using the env-editor for `.env` changes. If you also run Dockge, use it only for logs and files. The [Docker guide](platforms/docker/README.md#deploy-on-the-paired-docker-pve-vm-dockhand) explains both.

## Check that it works

With plain Docker, in the stack folder:

```bash
docker compose ps
```

`gluetun` should show `(healthy)`, and qBittorrent, Jackett, FlareSolverr and FileBrowser should be up. Then check the VPN's address and the forwarded port:

```bash
docker compose logs gluetun \
  | grep -i 'public ip'
docker compose exec gluetun \
  cat /tmp/gluetun/forwarded_port
```

The address must be the VPN's, not your own. qBittorrent's listening port (in VueTorrent, under **Settings → Connection**) must be the forwarded port, not 0.

In native mode, `bash /opt/torrent-stack/native/install.sh status` inside the container shows the kill switch, the VPN's health and the forwarded port. The other platform guides say how to check their install.

The web UIs, at `http://<host>:<port>`:

| App | Port | Login |
|---|---|---|
| qBittorrent (VueTorrent) | 8090 | your qBittorrent user |
| Jackett | 9117 | none until you set one |
| FlareSolverr | 8191 | none; Jackett uses it |
| FileBrowser | 8081 | `admin`, qBittorrent password |
| env-editor | 9191 | `admin`, printed password |

Not every platform runs the env-editor; its guide says how to change settings there.

## Configuration

Every setting is a key in `.env`, which starts as a copy of `.env.example`. The env-editor and the installers fill it in, and the keys are the same on every platform (TrueNAS keeps them in its app's YAML instead). After editing `.env` by hand, run `docker compose up -d` with plain Docker, or `native/install.sh apply` in native mode; the other platform guides say what to run there.

<details>
<summary>All 28 keys, with their defaults</summary>

**Paths and system**

| Key | Default and meaning |
|---|---|
| `PUID` | `1000`. User ID qBittorrent and Jackett run as. Never 0. |
| `PGID` | `1000`. Their group ID; FileBrowser joins it. |
| `TZ` | `America/New_York`. Time zone for logs. |
| `CONFIG_PATH` | `./configs`. Holds each app's config folder. |
| `DOWNLOADS_PATH` | `./downloads`. Finished downloads. |
| <code>INCOMPLETE_<wbr>DOWNLOADS</code> | <code>./downloads/<wbr>incomplete</code>. Downloads in progress. |

**VPN**

| Key | Default and meaning |
|---|---|
| `VPN_TYPE` | `wireguard`, or `openvpn`. |
| `VPN_PROVIDER` | `protonvpn`. Gluetun's name for your provider. |
| `OPENVPN_USER` | Placeholder. OpenVPN only. |
| `OPENVPN_PASSWORD` | Placeholder. OpenVPN only. |
| `OPENVPN_PROTOCOL` | `udp`, or `tcp`. OpenVPN only. |
| <code>WIREGUARD_<wbr>PRIVATE_KEY</code> | Placeholder. The `PrivateKey` from your WireGuard config. |
| `WIREGUARD_ADDRESSES` | Placeholder. Its `Address` line. |
| `PORT_FORWARD_ONLY` | `on`. Use only servers with port forwarding. |
| `VPN_PORT_FORWARDING` | `on`. Ask for a forwarded port. Keep it on. |
| `SERVER_COUNTRIES` | `United States`. Exit countries, separated by commas. |

**Ports on the host**

| Key | Default and meaning |
|---|---|
| `QBIT_WEBUI_PORT` | `8090`. qBittorrent. Not 9117, 8191, 8000 or 9999. |
| `JACKETT_PORT` | `9117`. Jackett. |
| `FLARESOLVERR_PORT` | `8191`. FlareSolverr. |
| `FILEBROWSER_PORT` | `8081`. FileBrowser. |

Inside Gluetun's network, Jackett and FlareSolverr always listen on 9117 and 8191; their keys only change the port on the host ([details](platforms/docker/README.md#ports-inside-and-outside-the-stack)).

**qBittorrent and notifications**

| Key | Default and meaning |
|---|---|
| `QBITTORRENT_USER` | Placeholder. qBittorrent's web UI user. |
| <code>QBITTORRENT_<wbr>PASSWORD</code> | Placeholder. Its password, also the FileBrowser password for `admin`. |
| `SCRIPT_NOTIFY_URL` | Placeholder. A Discord webhook for the port script's messages; empty for none. |

`update-qbittorrent.sh` logs in with `QBITTORRENT_USER` and `QBITTORRENT_PASSWORD`. The password must be 5 to 72 bytes and not `admin`, and with Docker it can't contain `$` ([why](platforms/docker/README.md#filebrowser)).

**Watchtower** (optional)

| Key | Default and meaning |
|---|---|
| `COMPOSE_PROFILES` | Empty: Watchtower off. `watchtower` turns it on, and the keys below apply. |
| <code>WATCHTOWER_<wbr>NOTIFICATION_URL</code> | Placeholder. A Shoutrrr URL, such as `discord://…`. |
| <code>WATCHTOWER_<wbr>NOTIFICATION_LEVEL</code> | `info` (updates and errors), `debug` (every check) or `warn`. |
| <code>WATCHTOWER_<wbr>TITLE_TAG</code> | `qBittorrent Stack`. Title prefix. |
| <code>WATCHTOWER_<wbr>SCHEDULE</code> | `0 30 15 * * *`. Six-field cron, seconds first: 15:30 daily. |

</details>

## Troubleshooting and FAQ

<details>
<summary>qBittorrent's listening port stays at 0, and nothing seeds</summary>

Gluetun got no forwarded port, or couldn't pass it on. Check that your provider supports port forwarding ([Prerequisites](#prerequisites)), that `VPN_PORT_FORWARDING` and `PORT_FORWARD_ONLY` are `on`, and, for ProtonVPN on OpenVPN, that the user name ends in `+pmp`. Then look at `docker compose logs gluetun`. If the port-update script can't log in, `QBITTORRENT_USER` and `QBITTORRENT_PASSWORD` don't match qBittorrent's login. If Gluetun can't run the script, it has lost its executable bit ([fix](platforms/docker/README.md#operational-notes)).

</details>

<details>
<summary>The env-editor says "Not saved"</summary>

It names the reason above the form, which still holds what you typed. Usually it's the qBittorrent password, which is also FileBrowser's: it must be 5 to 72 bytes (letters outside A-Z take 2 to 4 bytes each) and not `admin`, and it can't be the `.env.example` placeholder. With Docker it also can't contain `$`, because Docker Compose would read it as a variable.

</details>

<details>
<summary>I lost the env-editor's password</summary>

With plain Docker, delete `configs/env-editor/credentials.json` in the stack folder and run `./scripts/setup.sh` again; it prints a new one. In native mode, run `bash /opt/torrent-stack/native/install.sh reset-login` inside the container. The editor only keeps a hash, so the old password can't be read back.

</details>

<details>
<summary>qBittorrent, Jackett and FlareSolverr lost their network</summary>

`gluetun` was restarted on its own, for example with a Docker UI's Restart button. The apps that share its network must be recreated with it:

```bash
docker compose up -d \
  --force-recreate gluetun \
  qbittorrent jackett flaresolverr
```

</details>

<details>
<summary>Gluetun won't start: "open sysctl net.ipv6.conf.all.disable_ipv6"</summary>

The host was booted with `ipv6.disable=1`. The [Docker guide](platforms/docker/README.md#hosts-booted-with-ipv6disable1) has two ways out.

</details>

<details>
<summary>FileBrowser keeps restarting: "unable to open database file"</summary>

Its config folder isn't writable for it. FileBrowser always runs as uid 1000, and a folder Docker created belongs to root. With `PUID` and `PGID` 1000:

```bash
chown 1000:1000 configs/filebrowser
docker compose up -d filebrowser
```

Other IDs need a group-writable folder ([FileBrowser](platforms/docker/README.md#filebrowser)).

</details>

<details>
<summary>FileBrowser can't delete inside a download</summary>

That happens when `PUID` isn't 1000, because qBittorrent's files aren't group-writable. The [FileBrowser section](platforms/docker/README.md#filebrowser) of the Docker guide shows how to set `UMASK` for qBittorrent.

</details>

<details>
<summary>How do I update?</summary>

Read the [changelog](CHANGELOG.md) first. It lists every change in the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a new major version means an existing install may need manual steps when you update. An entry marked **BREAKING:** says what to do.

Then, with plain Docker, follow [Updating](platforms/docker/README.md#updating) in the Docker guide. Each platform guide has its own.

</details>

## Getting help

One person maintains this as a hobby, so a reply can take a few days.

- **Questions and bugs:** open an [issue](https://github.com/rob-paprocki/qbittorrent-vpn-docker/issues). Say which platform you're on and add the relevant logs, such as `docker compose logs gluetun`, with keys and passwords removed.
- **Security problems:** report them privately, as [SECURITY.md](.github/SECURITY.md) explains, not in a public issue.
- **A bug in one of the apps:** report it to that project (see [Credits](#credits)).

## Contributing

Pull requests are welcome. Planned work is in [ROADMAP.md](ROADMAP.md), with an issue for each item. [CLAUDE.md](CLAUDE.md) has the rules every change follows: Semantic Versioning, a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) in the same PR, updated READMEs when behaviour changes, and how diagrams are made. The [PR template](.github/pull_request_template.md) asks for a summary, a test plan and a rollback line.

The `lint` and `installers` workflows run on every PR; `lint` also fails on a Mermaid block or on an image that doesn't follow the reader's theme. Each installer's guide says how to run its test suite, [platforms/DESIGN.md](platforms/DESIGN.md) explains how the installers are built, and [UPSTREAMS.md](UPSTREAMS.md) lists every pinned version and how to bump it.

## Licence

Released under the [MIT License](LICENSE). Copyright © 2025 Rob Paprocki.

## Credits

Made by [Rob Paprocki](https://github.com/rob-paprocki). The stack is built from:

- [Gluetun](https://github.com/qdm12/gluetun), the VPN client;
- [qBittorrent](https://www.qbittorrent.org) with the [VueTorrent](https://github.com/VueTorrent/VueTorrent) web UI;
- [Jackett](https://github.com/Jackett/Jackett) and [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr);
- [FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser);
- the [LinuxServer.io](https://www.linuxserver.io) qBittorrent and Jackett images;
- the [nicholas-fedor fork of Watchtower](https://github.com/nicholas-fedor/watchtower);
- qBittorrent's [Jackett search plugin](https://github.com/qbittorrent/search-plugins).

[UPSTREAMS.md](UPSTREAMS.md) lists each one with its version and source.
