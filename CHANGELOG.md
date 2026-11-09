# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The project had no version numbers until 2026-11-09, when versions 1.0.0 to 3.0.0 were assigned to its past merges after the fact. Each merged PR got one version, and its tag points at that PR's merge commit. 1.0.0 points at `14fc99d`, the last commit on `main` before the first PR. A commit pushed straight to `main` between two PRs counts toward the version of the PR after it.

A new major version means an existing install may need manual steps when you update. Look for the entries marked **BREAKING:**; each one says what to do. [CLAUDE.md](CLAUDE.md) defines what counts as a breaking change.

## [Unreleased]

### Added

- One-line installers for six platforms. Each one runs as root on the platform itself (on Incus, a member of the `incus-admin` group will also do): `bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/<platform>/install.sh)"`. It asks a few questions, or reads `TS_*` variables when there is no terminal, and accepts `TS_REF=<branch or tag>` and `TS_SOURCE_DIR=<local checkout>`. Each platform's `README.md` under `platforms/` says what the installer creates, how to update and uninstall, and what was and was not tested ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)):
  - `proxmox`, for Proxmox VE 8 and 9: creates an unprivileged Debian 13 LXC container with `/dev/net/tun` and installs the stack in it natively, without Docker.
  - `incus`, for Incus 6.0 or newer: the same in an Incus system container, reached through proxy devices or directly on your LAN.
  - `truenas`, for TrueNAS 25.10: registers the stack as a custom app through the TrueNAS API; you then manage it on the **Apps** screen.
  - `unraid`, for Unraid 7: sets the stack up as a Compose Manager Plus stack under **Docker > Compose**.
  - `synology`, for DSM 7.2 and later: adds a Container Manager project and a Task Scheduler boot task that loads the `tun` module.
  - `casaos`, for CasaOS and ZimaOS: installs the stack as one dashboard app, *Torrent Stack*, through CasaOS's app API.
- Native mode: `native/install.sh`, which the Proxmox VE and Incus installers run inside their container. It installs Gluetun (built from source), qBittorrent-nox with VueTorrent, Jackett, FlareSolverr, FileBrowser and the env-editor as systemd services named `torrent-<service>.service`. The repository lives in `/opt/torrent-stack` and uses the same `.env` keys as the Docker stack. Every component is pinned in `native/versions.env` and checked against its sha256 or git commit. Gluetun, qBittorrent, Jackett and FlareSolverr stay stopped until `.env` holds real VPN settings. There is no Watchtower; to update, run `bash /opt/torrent-stack/native/install.sh self-update` in the container, or the Proxmox VE or Incus installer with `--update` on the host. The other subcommands are `install`, `update`, `apply`, `status`, `reset-login` (a new env-editor password) and `uninstall [--purge]` ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- A kill switch for native mode. An nftables table, `inet torrent_killswitch`, loads at boot before the network comes up. Traffic from the `torrent` user, which runs the apps, may leave only over loopback, through the VPN tunnel (`tun0`), or as replies to LAN devices that opened one of the four web UI ports, and its DNS goes only to Gluetun. The container's network stays up whether Gluetun runs or not, and these rules hold while Gluetun is stopped or reconnecting. A timer reloads the table within a minute if something removes it ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- env-editor native mode (`TS_MODE=native`, set by the native install): **Apply** runs `native/install.sh apply <services>` and restarts only the affected `torrent-*` services. Values the native install cannot use are refused before they are saved. Docker mode works as before ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- A seeding CLI: `python3 scripts/env-editor/seed_configs.py --env /path/to/.env` writes the same qBittorrent, Jackett and FileBrowser configs as the env-editor's **Apply**, without the editor running. Options: `--config-root`, `--only jackett,qbit,filebrowser`, `--as-user UID:GID` and `--jackett-port PORT`. It never seeds the `.env.example` placeholder login ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- This changelog (`CHANGELOG.md`), with a version back-filled for every merged PR (see the note at the top).
- For contributors: `CLAUDE.md`, the rules every change follows for versioning, the changelog, the README and user-facing text.
- For contributors: the humanizer and structural-humanizer skills under `.claude/skills/`, vendored from [NulightJens/humanizer-stack](https://github.com/NulightJens/humanizer-stack) at commit `13f5c02` under its MIT licence, for editing user-facing text.

### Changed

- **BREAKING:** FileBrowser's login is now user `admin`, whatever `QBITTORRENT_USER` is, with the password in `QBITTORRENT_PASSWORD` ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)):
  - Give `QBITTORRENT_PASSWORD` a real value of at least 5 characters and at most 72 bytes. Don't use `admin` (FileBrowser ignores that and makes up a password of its own), and don't keep the `.env.example` placeholder, which is public.
  - To change the password, change `QBITTORRENT_PASSWORD`. `compose.yaml` passes it as `FILEBROWSER_ADMIN_PASSWORD`, and FileBrowser sets it again every time it starts, so a password changed inside FileBrowser lasts only until the next restart.
  - FileBrowser runs as uid 1000 in the `PGID` group and must be able to write `configs/filebrowser`. If it keeps restarting with `unable to open database file` after the update, run `sudo chown 1000:1000 configs/filebrowser` (if your `PUID`/`PGID` are not 1000, run `sudo chown PUID:PGID configs/filebrowser && sudo chmod 2775 configs/filebrowser` instead), then `docker compose up -d filebrowser`.
- **BREAKING:** `JACKETT_PORT` and `FLARESOLVERR_PORT` now set only the port on the host. `compose.yaml` publishes them as `JACKETT_PORT:9117` and `FLARESOLVERR_PORT:8191`, the ports Jackett and FlareSolverr always listen on inside the stack, so a non-default value now works. With the default ports nothing changes. If you had set another `JACKETT_PORT`, qBittorrent's search plugin may still point at that port inside the stack, where nothing listens now: set `"url": "http://127.0.0.1:9117"` in `configs/qbittorrent/qBittorrent/nova3/engines/jackett.json`, and the next search uses it. In Docker mode the env-editor now writes `127.0.0.1:9117` into that file itself ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- `update-qbittorrent.sh` no longer posts to Discord when `SCRIPT_NOTIFY_URL` is empty or still the `.env.example` placeholder ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- README: a platform installers table, the ports inside and outside the stack, a FileBrowser section, help for hosts booted with `ipv6.disable=1`, and upgrade notes for this version ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- CI: checks the installers and the native code on every PR ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).

### Fixed

- FileBrowser's database (users, shares and settings) now lives in `configs/filebrowser/database.sqlite` instead of inside the container, where it was lost every time the container was recreated, for example by an image update. Anything set up in FileBrowser before this update is lost one last time ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- `update-qbittorrent.sh` can log in to qBittorrent 5.3 and later, which answer a successful login with an empty `204 No Content`. The script used to read that as a failed login and never set the forwarded port ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- `update-qbittorrent.sh` and `scripts/setup.sh` are now executable in git. Gluetun runs the port-forward script directly through a read-only mount, so a copy without the executable bit never ran and qBittorrent's listen port was never updated. On a fresh clone, `./scripts/setup.sh` stopped with "Permission denied". `git pull` fixes both. A copy made without git needs `chmod 755 update-qbittorrent.sh`, then `docker compose up -d --force-recreate gluetun qbittorrent jackett flaresolverr` ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).
- env-editor: a changed qBittorrent login now takes effect on qBittorrent 5.x, which moves its web UI settings to a `[WebUI]` section on first start and stops reading the old keys ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).

### Security

- qBittorrent runs the Python code of its Jackett search plugin, which used to come from the moving `master` branch of `qbittorrent/search-plugins`. The env-editor and the seeding CLI now install it from a pinned commit instead, and refuse it if its sha256 differs from the one in `native/versions.env` ([#17](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/17)).

## [3.0.0] - 2026-11-08

### Added

- env-editor: a **Watchtower → Run Watchtower** setting. Turning it off also removes the running Watchtower container ([#15](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/15)).
- README: adopting the stack in Dockhand on the docker-pve VM (**Stacks → Adopt**); using Dockge next to it only for logs and file edits, because its **Start**, **Update** and **Deploy** buttons recreate every container; cloning into `/opt/stacks/torrent-stack` and moving an existing clone there; the `python3-venv` package the setup editor needs; and why `gluetun` must be restarted together with qBittorrent, Jackett and FlareSolverr, never alone ([#15](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/15)).
- A Sponsor button on the repository, for GitHub Sponsors, Buy Me a Coffee and PayPal ([1e4db01](https://github.com/rob-paprocki/qbittorrent-vpn-docker/commit/1e4db01), [509e83e](https://github.com/rob-paprocki/qbittorrent-vpn-docker/commit/509e83e)).

### Changed

- **BREAKING:** Watchtower is off by default. It runs only when the `watchtower` Compose profile is on, set with the new `.env` key `COMPOSE_PROFILES`, which is empty in `.env.example`. On the docker-pve VM, Dockhand updates the stack instead. An existing Watchtower container keeps running after the update, because `docker compose up` leaves a service with a disabled profile alone, so choose one: to keep this stack's own Watchtower, add `COMPOSE_PROFILES=watchtower` to `.env` (env-editor: **Watchtower → Run Watchtower: on**); if you don't want it, remove the container with `docker compose rm -s -f watchtower` ([#15](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/15)).

### Fixed

- `scripts/setup.sh` recovers from a half-built Python venv. On a host without `python3-venv`, a failed first run used to leave a broken `.venv` that later runs skipped, ending in `No module named 'bcrypt'`. Now it rebuilds the venv until `requirements.txt` has installed, prints a `python3-venv` hint when the venv cannot be created, reinstalls when `requirements.txt` changes, and keeps working after the checkout is renamed or moved. Existing installs rebuild the venv once on the next run ([#15](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/15)).

## [2.2.0] - 2026-10-27

### Added

- env-editor, a web form for `.env` that also does the first-boot setup. `scripts/setup.sh` creates a Python venv in `scripts/env-editor/.venv` on first run (Python 3.9 or newer on the host) and serves the form on `http://<host>:9191` behind HTTP basic auth. The user is `admin`. Its generated password is printed once, and `configs/env-editor/credentials.json` keeps only a bcrypt hash of it, so write the password down; to get a new one, delete that file and start the editor again. **Preview changes** shows a diff and the services that will restart. **Apply** writes `.env`, seeds qBittorrent's login and the Jackett search plugin, generates a Jackett API key, seeds the FileBrowser admin, and restarts only the services the change affects. An indexers page lists and configures Jackett's indexers. `ENV_EDITOR_BIND` overrides the address, and `ENV_EDITOR_USER` the user name when the login is first created. In this version `scripts/setup.sh` is not executable in git, so start it with `bash scripts/setup.sh` ([#13](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/13)).

### Changed

- README: setup now goes through the env-editor. The manual steps are kept under "Doing it manually" ([#13](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/13)).

## [2.1.0] - 2026-10-26

### Changed

- Gluetun, FlareSolverr, Watchtower and FileBrowser now use rolling tags (`:latest`, and `:stable` for FileBrowser) instead of pinned versions, as qBittorrent and Jackett already did, so Watchtower keeps all six images up to date. Keep an eye on Gluetun: provider settings have been renamed in its minor releases before, and the first sign is port forwarding that stops working. To hold an image at one version, pin its tag in `compose.yaml`; `UPSTREAMS.md` has the rollback steps for each image ([#12](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/12)).

### Fixed

- `UPSTREAMS.md`: the FileBrowser source link pointed at a repository that does not exist ([#12](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/12)).

## [2.0.10] - 2026-10-25

### Security

- FileBrowser updated from `v2.0.1-stable` to `2.0.2-stable`, which includes upstream security fixes, among them one for stored XSS through crafted file names and one for API tokens that ignored their stored permission limits ([#7](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/7)).

## [2.0.9] - 2026-10-25

### Changed

- CI: `actions/checkout` updated from v4 to v7 ([#6](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/6)).

## [2.0.8] - 2026-10-25

### Changed

- CI: the Claude breaking-change review now works on Dependabot's PRs. Before, it started on them but was denied permission and posted no comment ([#11](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/11)).

## [2.0.7] - 2026-10-25

### Changed

- CI: the Claude breaking-change review passes `github_token` itself, so it no longer fails at the GitHub App token exchange ([#10](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/10)).

## [2.0.6] - 2026-10-24

### Changed

- CI: the Claude breaking-change review runs on `pull_request_target`, so a PR that edits the workflow file no longer stops it ([#9](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/9)).

## [2.0.5] - 2026-10-24

### Changed

- CI: the Claude breaking-change review gets the `id-token: write` permission it needs to start ([#8](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/8)).

## [2.0.4] - 2026-10-24

### Changed

- CI: Dependabot replaces Renovate for GitHub Actions and image updates, and major version bumps are labelled `breaking-candidate` for review ([#5](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/5)).

## [2.0.3] - 2026-10-24

### Added

- `.github/SECURITY.md`: how to report a vulnerability privately, and the known risks that are not fixed yet (rolling LinuxServer tags, trust in the VPN provider, FileBrowser's mounts, Watchtower's access to the Docker socket) ([#4](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/4)).
- `UPSTREAMS.md`: every image the stack uses, its tag and source, and what to check before updating it ([#4](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/4)).

### Changed

- CI: Renovate for dependency updates, and a workflow in which Claude checks PRs labelled `breaking-candidate` against the upstream changelog ([#4](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/4)).

## [2.0.2] - 2026-10-23

### Changed

- README: wording edits only; no instructions changed ([#3](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/3)).

## [2.0.1] - 2026-10-23

### Changed

- Watchtower now uses `ghcr.io/nicholas-fedor/watchtower:v1.23.2`, the maintained fork of `containrrr/watchtower`, which was archived on 2025-12-17. It reads the same settings and labels, so there is nothing to change ([#2](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/2)).

## [2.0.0] - 2026-10-23

### Added

- `.gitignore` keeps `.env`, the download folders and the apps' runtime files out of git, so secrets such as the Jackett API key cannot be committed by accident ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).

### Changed

- **BREAKING:** `compose.yaml` names the Compose project `torrent-stack`. Before, Docker Compose named it after the folder you cloned into (`qbittorrent-vpn-docker` or `docker-vpn-qbittorrent`). To update in place without leaving orphaned containers, first take the old project down under its old name with `docker compose -p qbittorrent-vpn-docker down` (or `-p docker-vpn-qbittorrent`, whichever you had), then run `docker compose up -d` ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- **BREAKING:** `PUID` and `PGID` default to 1000 instead of 0 in `.env.example`, so a new install no longer runs the LinuxServer apps (qBittorrent and Jackett) as root. An existing `.env` keeps its values, so an existing install is unchanged. If you change yours to 1000, give the folders to that user first: `sudo chown -R 1000:1000 configs downloads` ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- Gluetun (`v3.41.3`), FlareSolverr (`v3.5.2`), Watchtower (`1.7.1`) and FileBrowser (`v2.0.1-stable`) are pinned to fixed versions. qBittorrent and Jackett stay on `:latest` ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- `WATCHTOWER_NOTIFICATION_LEVEL` defaults to `info` instead of `debug` in `.env.example`; `debug` sent a notification on every image check. An existing `.env` keeps its value, so change it to `info` yourself for fewer notifications ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- The `OPENVPN_USER` example no longer ends in `+pmp`. ProtonVPN users add `+pmp` to their user name themselves to get port forwarding ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- README: the right clone URL and folder, the providers whose port forwarding works with this stack (ProtonVPN, Private Internet Access, Perfect Privacy and PrivateVPN), the first login for qBittorrent and FileBrowser, the Jackett plugin steps, and deploying with Dockge ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- CI: shellcheck, `docker compose config`, a check that `.env.example` and `compose.yaml` use the same keys, and a JSON check on every PR ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).

### Removed

- **BREAKING:** FileBrowser no longer shows the project folder (`/srv/stack`) or the config folder (`/srv/configs`). Anyone with the FileBrowser login could read `.env`, the VPN keys, the Jackett API key and qBittorrent's session cookies through them. It now shows only `DOWNLOADS_PATH`, at `/srv/downloads`; edit configs on the host instead ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- The `.env` keys `DISABLE_IPV6`, `NORDVPN_*` and `MULLVAD_*`. Nothing read them (Gluetun has no `DISABLE_IPV6` setting), and leftover lines in your `.env` are ignored ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).

### Fixed

- IPv6 is now actually off for Gluetun and every app on its network, through the sysctl `net.ipv6.conf.all.disable_ipv6=1` on the `gluetun` service. `DISABLE_IPV6=on` never did this. The host's IPv6 is untouched ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- Jackett's seed config is valid JSON (it had a trailing comma) and listens on all interfaces, so the published `JACKETT_PORT` reaches its web UI ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).
- `update-qbittorrent.sh` checks that the forwarded port is a number from 1 to 65535 before it contacts qBittorrent; an empty port file used to send an empty update. It also removes its cookie file when it is interrupted ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).

### Security

- qBittorrent's seed config asks for a login from localhost too (`WebUI\LocalHostAuth=true`). Before, every container on Gluetun's network could use qBittorrent's web API without a password. If your qBittorrent config is older than this version, check that **Tools → Options → Web UI → Bypass authentication for clients on localhost** is off ([#1](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/1)).

## [1.0.0] - 2025-10-16

### Added

- First version: a Docker Compose stack in which qBittorrent (LinuxServer image, with the VueTorrent web UI), Jackett and FlareSolverr share the network of a Gluetun VPN container and start once it is healthy.
- `update-qbittorrent.sh`, Gluetun's port-forwarding hook: it sets qBittorrent's listen port to the VPN's forwarded port and reports the result to a Discord webhook.
- FileBrowser on `FILEBROWSER_PORT` for the downloads, config and project folders, and Watchtower to update the containers on a schedule, with Discord notifications.
- `.env.example` with the VPN, path, port and notification settings (ports 8090 for qBittorrent, 9117 for Jackett, 8191 for FlareSolverr and 8081 for FileBrowser), and seed configs for qBittorrent and Jackett.

[Unreleased]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.2.0...v3.0.0
[2.2.0]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.10...v2.1.0
[2.0.10]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.9...v2.0.10
[2.0.9]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.8...v2.0.9
[2.0.8]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.7...v2.0.8
[2.0.7]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.6...v2.0.7
[2.0.6]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.5...v2.0.6
[2.0.5]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.4...v2.0.5
[2.0.4]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.3...v2.0.4
[2.0.3]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.2...v2.0.3
[2.0.2]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/rob-paprocki/qbittorrent-vpn-docker/releases/tag/v1.0.0
