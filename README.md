# qBittorrent + Gluetun VPN Docker Stack

A Docker Compose stack: **Gluetun** VPN gateway + **qBittorrent** (LinuxServer) + **Jackett** + **FlareSolverr** + **FileBrowser** + **Watchtower**. Automatically pushes the VPN's forwarded port into qBittorrent whenever the VPN re-connects, and reports stack events to Discord.

Designed to drop into the Docker VM provisioned by the companion repo [docker-pve](https://github.com/rob-paprocki/docker-pve) (which pre-installs Dockge, Portainer, and Watchtower under `/opt/stacks/`), but works on any Docker host.

## Prerequisites

* Docker Engine 20.10+ with the Docker Compose plugin
* `/dev/net/tun` available on the host (loaded automatically on most Linux kernels)
* `NET_ADMIN` capability (granted via `cap_add` in the compose file)
* **A VPN provider that supports port forwarding through Gluetun.** The port-update flow depends on it. As of this writing, Gluetun supports port forwarding for: **ProtonVPN, Private Internet Access, Perfect Privacy, PrivateVPN**. NordVPN, Mullvad and AirVPN are *not* supported for this path — the stack will connect, but qBittorrent's listen port will stay at 0 and nothing will seed.

See the current list in Gluetun's wiki: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md>

## Setup

```bash
# Pick a stacks dir (the paired docker-pve VM uses /opt/stacks/).
mkdir -p /opt/stacks && cd /opt/stacks

# Clone and move in.
git clone https://github.com/rob-paprocki/qbittorrent-vpn-docker.git
cd qbittorrent-vpn-docker

# Prep host-side state dirs so the containers can write them as PUID/PGID.
mkdir -p configs downloads/incomplete
# If PUID/PGID in .env are 1000, chown accordingly:
sudo chown -R 1000:1000 configs downloads

# Fill in your VPN credentials, Discord webhook, etc.
cp .env.example .env
nano .env

# Launch.
docker compose up -d
```

### Deploy via Dockge (recommended on the paired docker-pve VM)

If the host is the Docker VM produced by [docker-pve](https://github.com/rob-paprocki/docker-pve), clone into `/opt/stacks/` as above and Dockge (at `http://<host>:5001`) will auto-discover `torrent-stack`. Edit `.env` and start the stack from the Dockge UI — no CLI needed after the clone.

### Upgrading from a pre-`name: torrent-stack` deployment

The compose file now declares `name: torrent-stack`. Earlier versions let Docker Compose derive the project name from the parent directory (`qbittorrent-vpn-docker` or `docker-vpn-qbittorrent`). If you are upgrading in place, bring the old project down under its old name first, then up under the new one so Docker doesn't leave orphaned containers:

```bash
docker compose -p qbittorrent-vpn-docker down   # or -p docker-vpn-qbittorrent, whichever you had
docker compose up -d
```

## Post-install

### FileBrowser

The default admin credential depends on the FileBrowser image version. If `admin / admin` fails, retrieve the initial password from the container log:

```bash
docker compose logs filebrowser | grep -i -E 'password|admin'
```

Change it immediately under **Settings → User Management**. The default compose binds the UI to `0.0.0.0:${FILEBROWSER_PORT}` on the host; firewall it off, use a reverse proxy, or set `FILEBROWSER_PORT` to a loopback-only bind if the host is reachable from untrusted networks.

### qBittorrent

The LinuxServer qBittorrent image prints a temporary admin password to the container log on first start:

```bash
docker compose logs qbittorrent | grep -i -A1 'temporary.*password'
```

Log in with that password, then set a permanent one under **Tools → Options → Web UI** and put it in `.env` as `QBITTORRENT_USER` / `QBITTORRENT_PASSWORD`. `update-qbittorrent.sh` uses those credentials to push the forwarded port after each VPN reconnect.

### Jackett search plugin

Follow the upstream guide: <https://github.com/qbittorrent/search-plugins/wiki/How-to-configure-Jackett-plugin>

TL;DR after the stack is up:

1. In qBittorrent, enable the Search tab: **Tools → Options → Search → "Enable search engine"** (this is what first creates `configs/qbittorrent/qBittorrent/nova3/`).
2. In qBittorrent, install the Jackett plugin: **Search → Search Plugins → Install new**, paste
   `https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/jackett.py`
3. Open `./configs/qbittorrent/qBittorrent/nova3/engines/jackett.json`, paste your Jackett API key, and save.

## Operational notes

* **Image tags.** `qbittorrent` and `jackett` are LinuxServer images; their tag convention is `<upstream>_v<libtorrent>-ls<build>` with a rolling `:latest`. This repo leaves them on `:latest` and lets Watchtower pull nightly. Pin the tag in `compose.yaml` if reproducibility matters more than auto-update.
* **Watchtower is archived.** `containrrr/watchtower` was archived on 2025-12-17. It still works and this stack pins `v1.7.1`, but consider replacing it with a maintained fork (e.g. `nickfedor/watchtower`) or switching to notify-only tooling (`diun`, `renovate`) in a future revision.
* **Prowlarr.** Jackett is included for compatibility. If you plan to add Sonarr/Radarr later, consider [Prowlarr](https://wiki.servarr.com/prowlarr) instead — it supersedes Jackett for new deployments and integrates natively with the \*arr stack.
* **IPv6.** Disabled via a Docker sysctl on the gluetun service (`net.ipv6.conf.all.disable_ipv6=1`), which propagates to every container on `network_mode: service:gluetun`. The host's IPv6 is untouched.

## License

Released under the [MIT License](LICENSE) — Copyright © 2025 Rob Paprocki.
