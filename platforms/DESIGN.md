# Multi-platform installers — design contract

This document is the contract every installer in `platforms/` and `native/` is built against. Change it deliberately; the installers depend on the names and paths below.

## Goals

- A community-scripts-style one-liner per platform: run one command on the host (or in the platform's shell), answer a short whiptail wizard where a TTY exists, and end up with the stack running.
- The stack's security property is the same everywhere: **qBittorrent, Jackett and FlareSolverr can only reach the internet through the VPN.** If the VPN or Gluetun is down, they have no internet at all (fail closed, no leak).
- No telemetry and no runtime sourcing of third-party scripts. Installers are self-contained in this repo (MIT). Ideas and install steps may be adapted from [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) (MIT) with attribution in a header comment.
- Pinned versions everywhere (no "latest" lookups at install time; `api.github.com` is rate-limited and should not be required).

## Two install styles

| Style | Platforms | What runs |
|---|---|---|
| **Native system container** | Proxmox VE (LXC), Incus (system container) | One Debian 13 container. Gluetun, qBittorrent, Jackett, FlareSolverr, FileBrowser and the env-editor run as systemd services in that one container, so they share its single network namespace — the native equivalent of `network_mode: service:gluetun`. |
| **Docker Compose** | TrueNAS (custom App), Unraid, Synology DSM (Container Manager), CasaOS / ZimaOS | The existing `compose.yaml` (or a platform rendering of it), using each platform's own app/compose mechanism. |

## Repository layout and ownership

Parallel work must stay inside its own paths. Changes needed outside your paths are **reported, not made**.

| Path | Owner | Notes |
|---|---|---|
| `native/` | native core | In-container installer for Debian 13 system containers. |
| `scripts/env-editor/` | native core | Only to add native (systemd) mode and the seeding CLI below. Docker mode must keep working unchanged. |
| `update-qbittorrent.sh` | native core | Only if the native port-forward path needs it; keep Docker behaviour identical. |
| `scripts/setup.sh` | native core | Only to let the native installer reuse its venv build without launching the app. |
| `platforms/proxmox/` | Proxmox | Host-side one-liner (`pct`). |
| `platforms/incus/` | Incus | Host-side one-liner (`incus`). |
| `platforms/truenas/` | TrueNAS | Shell installer using the TrueNAS middleware API (`midclt`). |
| `platforms/unraid/` | Unraid | |
| `platforms/synology/` | Synology DSM | |
| `platforms/casaos/` | CasaOS / ZimaOS | |
| `compose.yaml`, `.env.example`, `README.md`, `UPSTREAMS.md`, `.github/` | integration (maintainer) | Do not edit in parallel work. |

Each `platforms/<p>/` contains at least `install.sh` (the one-liner target) and `README.md` (prerequisites, one-liner, what it creates, how to update, how to uninstall, limitations, and what was tested vs not).

One-liner form (matches docker-pve):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/<p>/install.sh)"
```

Every installer must also accept `TS_SOURCE_DIR=/path/to/checkout` (use a local checkout instead of cloning; this is how it is tested) and `TS_REF=<branch|tag>` (default `main`).

## Native system container contract (Proxmox and Incus)

### Guest

- Debian 13 (trixie), amd64 required, arm64 where every component ships an arm64 build.
- Unprivileged container. `/dev/net/tun` passed through by the host script. Nesting only if a component proves to need it (document why).
- Repo checkout lives at **`/opt/torrent-stack`** inside the guest; its `.env` (same keys as `.env.example`) is the single source of truth for both styles.
- Services run as user **`torrent`** with uid/gid from `PUID`/`PGID` (default 1000/1000). Gluetun and the env-editor run as root.

### Host script → guest hand-off

The host script creates the container, adds devices, gets the repo into `/opt/torrent-stack`, then runs (as root in the guest):

```bash
bash /opt/torrent-stack/native/install.sh install
```

Getting the repo in: with `TS_SOURCE_DIR` set, push that directory (excluding `.git`, `configs/`, `downloads/`, `.env`); otherwise install `git ca-certificates curl` in the guest and `git clone --depth 1 --branch "${TS_REF:-main}" https://github.com/rob-paprocki/qbittorrent-vpn-docker /opt/torrent-stack`.

The host script may pass initial settings as environment variables on that command (any `.env` key, e.g. `TZ`, `PUID`, `PGID`, `DOWNLOADS_PATH`); VPN credentials are normally entered afterwards in the env-editor.

### `native/install.sh` subcommands

| Command | Behaviour |
|---|---|
| `install` | Idempotent. Creates `.env` from `.env.example` if missing (applying any `.env` keys passed as environment variables), installs packages and pinned components, writes systemd units and the kill switch, starts the env-editor (and FileBrowser), and prints the env-editor URL and its first-run credentials. Apps that need the VPN start only once VPN settings are filled in (see Startup gating). |
| `update` | Re-reads `native/versions.env` and installs any component whose pinned version changed; restarts only what changed. Run after `git -C /opt/torrent-stack pull`. |
| `apply [service...]` | Re-render every config derived from `.env` and restart the named services (all when none given). This is what the env-editor calls in native mode. |
| `status` | One line per service: active state and version. |
| `uninstall` | Stop and remove units, kill switch and installed binaries; keep `/opt/torrent-stack/configs`, downloads and `.env` unless `--purge`. |

Pinned versions live in `native/versions.env` (Gluetun, qBittorrent-nox static build, VueTorrent, Jackett, FlareSolverr, FileBrowser, Go toolchain used to build Gluetun).

### Service names

`gluetun`, `qbittorrent`, `jackett`, `flaresolverr`, `filebrowser`, `env-editor` — systemd units `torrent-<name>.service`. These names match the compose services and `scripts/env-editor/restart_map.py`, so the env-editor maps keys to units 1:1. `watchtower` does not exist in native mode (updates are `native/install.sh update`).

### Network and kill switch (security-critical)

- Gluetun runs natively (built from source, as community-scripts' Gluetun LXC does) and owns the VPN tunnel and its own firewall.
- **A persistent kill switch independent of Gluetun** (nftables) must make the `torrent` user's traffic leave only via loopback or the VPN interface (`tun0`/`wg0`, whatever Gluetun creates), plus replies to inbound LAN connections to the web UIs. It is installed before any app starts and stays in force when Gluetun is stopped, crashed or reconnecting. Gluetun's own firewall alone is not enough natively: unlike Docker, the container's network namespace survives Gluetun stopping.
- No DNS leaks: the `torrent` user resolves only through Gluetun's DNS (127.0.0.1) or through the tunnel.
- LAN access to the web UIs on the `.env` ports (`QBIT_WEBUI_PORT`, `JACKETT_PORT`, `FLARESOLVERR_PORT`, `FILEBROWSER_PORT`) and the env-editor (9191) must work while the VPN is up **and** while it is down.
- Port forwarding: Gluetun runs `update-qbittorrent.sh` as `VPN_PORT_FORWARDING_UP_COMMAND` with the same environment as in Docker; the forwarded-port file path must match what the script reads.

### Startup gating

Gluetun and the apps behind it must not start with placeholder VPN credentials (values from `.env.example`). The env-editor and FileBrowser start immediately so the user can configure the stack.

### env-editor in native mode

- Same UI. Native mode is selected by the unit (for example `TS_MODE=native` in its environment).
- Apply calls `native/install.sh apply <services>` instead of `docker compose up -d <services>`; profiled services (`watchtower`) are ignored.
- **Seeding CLI** (also usable by Docker-style installers): `python3 scripts/env-editor/seed_configs.py --env /path/to/.env [--config-root DIR]` runs the same seeders as the env-editor's Apply (qBittorrent password + search-plugin wiring, Jackett API key, FileBrowser admin) non-interactively and exits non-zero on failure.

## Docker-style platforms contract (TrueNAS, Unraid, Synology, CasaOS/ZimaOS)

- Use the repo's `compose.yaml` and `.env` semantics. Platform specifics (absolute data paths, default PUID/PGID, how the platform registers a stack) belong in `platforms/<p>/`.
- Gluetun needs `/dev/net/tun` and `NET_ADMIN`; document and handle platforms where the tun device or module is not available by default.
- Keep the stack's Watchtower off (`COMPOSE_PROFILES` empty) unless the platform has no updater the user would rather use; say which in the README.
- First-run seeding: use the seeding CLI when the platform can run it, otherwise document the manual first-run steps from the main README.
- An installer that registers the stack with a platform API must be idempotent (re-running updates, not duplicates) and support a dry-run that prints what it would send.

## Testing (what "tested" means in this repo)

- `bash -n` and `shellcheck -S warning` clean on every shell script.
- Native: end-to-end in a real Incus Debian 13 container (install, units active, env-editor reachable, apply restarts units, update idempotent, kill switch blocks the `torrent` user's internet with Gluetun stopped and while the VPN is not connected, web UIs reachable over the container's LAN address). Real VPN connectivity cannot be tested without credentials; say so.
- Platform scripts that call tools unavailable here (`pct`, `midclt`, DSM/Unraid/CasaOS tooling): test against faithful command shims that record calls, and validate any generated payload/compose (`docker compose config -q`, schema checks against official API docs).
- READMEs state plainly what was and was not tested.
