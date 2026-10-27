# qBittorrent + Gluetun VPN Docker Stack

A Docker Compose stack: Gluetun VPN gateway, qBittorrent (LinuxServer), Jackett, FlareSolverr, FileBrowser, and Watchtower. Pushes the VPN's forwarded port into qBittorrent on every reconnect and reports stack events to Discord.

Designed to drop into the Docker VM provisioned by the companion repo [docker-pve](https://github.com/rob-paprocki/docker-pve) (which pre-installs Dockge, Portainer, and Watchtower under `/opt/stacks/`), but works on any Docker host.

## Prerequisites

* Docker Engine 20.10+ with the Docker Compose plugin
* `/dev/net/tun` available on the host (loaded automatically on most Linux kernels)
* `NET_ADMIN` capability (granted via `cap_add` in the compose file)
* A VPN provider that supports port forwarding through Gluetun; the port-update flow depends on it. Gluetun currently covers ProtonVPN, Private Internet Access, Perfect Privacy, and PrivateVPN. NordVPN, Mullvad, and AirVPN are not supported on this path: the stack will connect, but qBittorrent's listen port will stay at 0 and nothing will seed.

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
sudo chown -R 1000:1000 configs downloads  # match PUID/PGID

# Launch the setup editor. First run creates a Python venv (~10 MB),
# auto-generates an admin password (printed to stdout, saved to
# configs/env-editor/credentials.json), then serves the form on :9191.
./scripts/setup.sh
```

Open `http://<host>:9191` in a browser, log in with the printed credentials, fill in VPN details and ports, hit **Preview changes** then **Apply**. The editor writes `.env`, seeds `qBittorrent.conf` (PBKDF2 password + search-plugin wiring), seeds the FileBrowser admin credentials (bcrypt, reusing the qBittorrent password), generates a Jackett API key, and brings the stack up. No temp-password log-grep dance, no plugin-install UI clicking, no API-key copy/paste.

The editor stays running — same URL, same login — for any future `.env` edit. It computes a diff of what's changing on save and only recycles the services that depend on the changed variables.

### Add indexers

With the stack up, the editor's **Indexers** tab lists everything in Jackett's catalog. Click **configure** on an indexer, fill in whatever credentials Jackett asks for (public trackers need none; private trackers prompt for passkey/cookie/etc.), save. Jackett's own UI at `http://<host>:${JACKETT_PORT}` still works if you prefer it.

### Deploy via Dockge (recommended on the paired docker-pve VM)

If the host is the Docker VM produced by [docker-pve](https://github.com/rob-paprocki/docker-pve), clone into `/opt/stacks/` as above and Dockge (at `http://<host>:5001`) will auto-discover `torrent-stack`. Dockge is handy for log tailing and ad-hoc text edits to `compose.yaml`; the env-editor is still the recommended path for `.env` changes because it handles the config-seeding and smart-restart.

### Upgrading from a pre-`name: torrent-stack` deployment

The compose file now declares `name: torrent-stack`. Earlier versions let Docker Compose derive the project name from the parent directory (`qbittorrent-vpn-docker` or `docker-vpn-qbittorrent`). If you are upgrading in place, bring the old project down under its old name first, then up under the new one so Docker doesn't leave orphaned containers:

```bash
docker compose -p qbittorrent-vpn-docker down   # or -p docker-vpn-qbittorrent, whichever you had
docker compose up -d
```

## Doing it manually (without the editor)

If you'd rather skip the editor and provision by hand — the stack still works end-to-end that way; the editor is a convenience, not a dependency.

* **`.env`** — `cp .env.example .env`, edit in `$EDITOR`.
* **FileBrowser** — default admin credential depends on the image version. If `admin / admin` fails, retrieve the initial password from the container log (`docker compose logs filebrowser | grep -i -E 'password|admin'`). Change it under **Settings → User Management**.
* **qBittorrent** — the LinuxServer image prints a temporary admin password on first start (`docker compose logs qbittorrent | grep -i -A1 'temporary.*password'`). Log in with it, set a permanent one in **Tools → Options → Web UI**, put it in `.env` as `QBITTORRENT_PASSWORD`. The port-update script uses that credential.
* **Jackett search plugin** — enable **Tools → Options → Search → "Enable search engine"** in qBittorrent, install the plugin via **Search → Search Plugins → Install new** with `https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/jackett.py`, then paste your Jackett API key into `./configs/qbittorrent/qBittorrent/nova3/engines/jackett.json`.
* **Jackett indexers** — add them in Jackett's own UI at `http://<host>:${JACKETT_PORT}`.

The `FILEBROWSER_PORT` compose binding is `0.0.0.0:${FILEBROWSER_PORT}` by default; firewall it off, use a reverse proxy, or set it to a loopback-only bind if the host is reachable from untrusted networks.

## Operational notes

* **Image tags.** Every image in `compose.yaml` is on a rolling tag (`:latest`, or `:stable` for FileBrowser); Watchtower pulls nightly. Pin a specific version in `compose.yaml` if reproducibility matters more than auto-update — see `UPSTREAMS.md` for the per-image rollback recipe. The Gluetun image is the one worth watching: provider env-variable renames have shipped as minor bumps there.
* **Watchtower fork.** `containrrr/watchtower` was archived on 2025-12-17 at `v1.7.1`. This stack runs `ghcr.io/nicholas-fedor/watchtower:latest`, the active community fork, which is drop-in compatible on env and labels. The Watchtower here is not fronted by `docker-socket-proxy`: it performs updates, so it would need `POST` allowed anyway, which the proxy would have to grant.
* **IPv6.** Disabled via a Docker sysctl on the gluetun service (`net.ipv6.conf.all.disable_ipv6=1`), which propagates to every container on `network_mode: service:gluetun`. The host's IPv6 is untouched.

## License

Released under the [MIT License](LICENSE). Copyright © 2025 Rob Paprocki.
