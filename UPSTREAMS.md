# Upstream dependencies

Everything this repo pulls in from elsewhere, where it comes from, how to move it to a newer version, and what to watch for.

There are two pinning regimes:

* **The compose stack** (plain Docker, the docker-pve VM, and the Docker-style installers for TrueNAS, Unraid, Synology and CasaOS) uses **rolling image tags** (`:latest` or `:stable`). Updates come from Dockhand on the docker-pve VM, from the platform's own updater, or from the stack's optional Watchtower (off by default). A bad upstream build therefore reaches you without a commit here; the breaking signals below are what to re-read if the stack misbehaves after an image update.
* **The native install** (Proxmox VE and Incus, `native/`) **pins everything**: every download in `native/versions.env` with a sha256 or a git commit, every Python package in `native/locks/` with hashes. Nothing changes until a commit here changes a pin. These pins are bumped by hand; no bot reads them.

In between sit the installers' own pins (the seeding image, the qBittorrent search plugin) and the platform versions and APIs each installer depends on. They are listed under [Platform installers](#platform-installers).

GitHub Actions references in `.github/workflows/*.yml` are pinned too, and those move through Dependabot:

- [`.github/dependabot.yml`](.github/dependabot.yml) auto-bumps the GitHub Actions pins. Non-major bumps group on one Monday PR; majors land solo. Its `docker-compose` entry finds nothing to bump while every `image:` line is on a rolling tag.
- [`.github/workflows/label-major-bumps.yml`](.github/workflows/label-major-bumps.yml) adds the `breaking-candidate` label to any Dependabot PR crossing a major-version boundary. That label fires [`.github/workflows/claude-breaking-review.yml`](.github/workflows/claude-breaking-review.yml), which has Claude read the upstream changelog, grep this repo for the specific symbols flagged, and comment with a `REAL / NOT / UNCLEAR` verdict.

## Container images

### `qmcgaw/gluetun`

- **Tag:** `:latest`
- **Source:** [`qdm12/gluetun`](https://github.com/qdm12/gluetun) and the [port-forwarding wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md)
- **Breaking signals:** Gluetun carries the VPN provider wire protocols and the port-forwarding integration this stack relies on. **Minor bumps have shipped breaking changes** here, specifically provider-specific env variable renames. On a rolling tag that means an updater can silently pull a build that renames a `VPN_SERVICE_PROVIDER` env or changes the port-forwarding script contract. If port forwarding stops working after a pull, read the Gluetun release notes between the last two pulled image digests, and re-render `.env.example` against the current Gluetun env table if a rename is called out.
  - `update-qbittorrent.sh` reads the port from `/tmp/gluetun/forwarded_port`. The wiki says that file "will be deprecated in v4.0.0". Before Gluetun v4, change the script to take the port as an argument (`{{PORT}}` in `VPN_PORT_FORWARDING_UP_COMMAND`).
  - Gluetun runs `VPN_PORT_FORWARDING_UP_COMMAND` without a shell, so `update-qbittorrent.sh` must stay executable (mode 755 in git).
  - Ports 8000 (control server) and 9999 (health server) are taken inside the shared network; `QBIT_WEBUI_PORT` must avoid them.
- **Pin to a specific version (if you need to roll back):** replace `:latest` with a tag from <https://github.com/qdm12/gluetun/releases>.

### `ghcr.io/flaresolverr/flaresolverr`

- **Tag:** `:latest`
- **Source:** [`FlareSolverr/FlareSolverr`](https://github.com/FlareSolverr/FlareSolverr)
- **Breaking signals:** API endpoint shape or the Jackett integration contract. Jackett reaches FlareSolverr at `http://127.0.0.1:8191` (its `FlareSolverrUrl` in `configs/jackett/Jackett/ServerConfig.json`): both share Gluetun's network, and FlareSolverr listens on its default port 8191 there, whatever `FLARESOLVERR_PORT` is (`compose.yaml` publishes `FLARESOLVERR_PORT:8191`). A change of FlareSolverr's default port (`PORT`) or of its `/v1` API would break that.
- **Pin to a specific version:** replace `:latest` with a tag from <https://github.com/FlareSolverr/FlareSolverr/releases>.

### `lscr.io/linuxserver/qbittorrent` and `lscr.io/linuxserver/jackett`

- **Tag:** `:latest`
- **Source:** LinuxServer uses the tag convention `<upstream_version>_v<libtorrent_version>-ls<build>` with a rolling `:latest`. No SemVer promise and no breaking-change log for the LinuxServer wrapper; breaking changes ship on the rolling tag without a major bump.
- **Breaking signals:** VueTorrent docker-mod compatibility (the theme is installed into qBittorrent via the `DOCKER_MODS: ghcr.io/vuetorrent/vuetorrent-lsio-mod:latest` env), `WEBUI_PORT` handling, PUID/PGID handling.
  - qBittorrent 5.3 moved the web UI login from `[Preferences] WebUI\...` to a `[WebUI]` section (settings migration 11) and answers a good login with `204 No Content` instead of `Ok.`. The seeding CLI writes the login into `[WebUI]` once that section exists, and `update-qbittorrent.sh` accepts both answers. A further move of these settings would make a re-seeded password silently ignored.
  - Jackett must keep listening on 9117 inside the container: `compose.yaml` publishes `JACKETT_PORT:9117`, and qBittorrent's search plugin is wired to `http://127.0.0.1:9117`.
- **Pin to a specific version:** replace `:latest` with the exact `<version>_v<libtorrent>-ls<build>` string from `docker inspect` on a running container.

### `ghcr.io/nicholas-fedor/watchtower`

- **Tag:** `:latest`, the active community fork of the archived `containrrr/watchtower`. Optional: only runs with the `watchtower` Compose profile (`COMPOSE_PROFILES=watchtower`); off by default because Dockhand updates the stack on the paired docker-pve VM. The Docker-style installers leave it off too (TrueNAS drops the service from its app altogether); CasaOS, which has no updater for custom apps, offers it as "Automatic updates". The native install has no Watchtower.
- **Source:** [`nicholas-fedor/watchtower`](https://github.com/nicholas-fedor/watchtower)
- **Breaking signals:** env variable renames, label-prefix changes (`com.centurylinklabs.watchtower.*` is the stable prefix). This stack uses `WATCHTOWER_NOTIFICATION_URL`, `WATCHTOWER_NOTIFICATION_LEVEL`, `WATCHTOWER_NOTIFICATION_TITLE_TAG`, `WATCHTOWER_SCOPE`, `WATCHTOWER_SCHEDULE`, `--cleanup`, and the shoutrrr URL scheme set. How it orders the containers on `network_mode: service:gluetun` when Gluetun gets a new image has not been tested here (see "Known follow-ups" in [platforms/DESIGN.md](platforms/DESIGN.md)).
- **Pin to a specific version:** replace `:latest` with a tag from <https://github.com/nicholas-fedor/watchtower/releases>.

### `ghcr.io/gtsteffaniak/filebrowser`

- **Tag:** `:stable` (FileBrowser Quantum; `v2.0.2-stable` when this was written)
- **Source:** [`gtsteffaniak/filebrowser`](https://github.com/gtsteffaniak/filebrowser) (the actively maintained fork); environment variables: <https://filebrowserquantum.com/en/docs/reference/environment-variables/>
- **What `compose.yaml` relies on:**
  - `FILEBROWSER_DATABASE_PATH=/config/database.sqlite`: the database (users, shares, settings, the login signing key) lives in the mounted `configs/filebrowser`. Without it the image keeps the database under `/home/filebrowser/data`, which is not mounted, and loses it whenever the container is recreated.
  - `FILEBROWSER_ADMIN_PASSWORD=${QBITTORRENT_PASSWORD}`: on every start FileBrowser sets the password of its `admin` user to this value (its default admin user name is `admin`; no environment variable changes that). The log then says `Using admin password from FILEBROWSER_ADMIN_PASSWORD environment variable`. Passwords need 5 to 72 bytes: the minimum is `auth.methods.password.minLength`, default 5, compared with the length in bytes ([password_policy.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/password_policy.go)), and the bcrypt hash of golang.org/x/crypto v0.57.0 refuses more than 72 ([bcrypt.go](https://github.com/golang/crypto/blob/v0.57.0/bcrypt/bcrypt.go)). The value `admin` (like an empty one) is ignored: a new database then gets a random password that FileBrowser logs once, and an existing one keeps its stored password ([auth.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/pkg/settings/auth.go) `ConfigTriggersAdminPasswordReset`, [bootstrap_admin_password.go](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/backend/internal/state/bootstrap_admin_password.go)). The env-editor and every installer refuse a qBittorrent password outside these rules ([platforms/DESIGN.md](platforms/DESIGN.md#the-qbittorrent-password)), so a change to them (a new `minLength` default, another hash) needs those checks changed too.
  - The image runs as uid 1000 whatever `PUID` is; `group_add: ["${PGID}"]` lets it use the stack's folders through the PGID group. It can change only what that group may write, and qBittorrent's files are not group-writable unless the `qbittorrent` service sets `UMASK=002` (see the FileBrowser part of [platforms/docker/README.md](platforms/docker/README.md#filebrowser)).
  - The downloads are mounted at `/srv/downloads`, and nothing else: the mount must stay inside the downloads tree, because `configs/` and `.env` hold secrets.
- **Breaking signals:** a rename of either environment variable (the database would silently go back to unmounted storage, and the `admin` password to a generated one printed in the log), a change of the image's uid, or of the default admin user name. After an image update, check the log for the two lines `Using admin password from FILEBROWSER_ADMIN_PASSWORD environment variable` and `SQLite database initialized at /config/database.sqlite`. The TrueNAS installer refuses a `compose.yaml` whose FileBrowser database is outside the configs dataset.
- **Not used any more:** `configs/filebrowser/settings.yaml`, with a bcrypt `auth.adminPassword`, which the env-editor wrote on Apply until `seed_configs.py`'s FileBrowser seeder was removed. The image never reads it (its config file is `FILEBROWSER_CONFIG=/home/filebrowser/data/config.yaml`, set in [_docker/Dockerfile](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/_docker/Dockerfile)). A copy left in an existing install is not deleted and can be removed by hand.
- **Pin to a specific version:** replace `:stable` with a tag from <https://github.com/gtsteffaniak/filebrowser/releases>.

## Platform installers

### Native components: `native/versions.env`

`native/install.sh` reads this file as plain `KEY=VALUE` data (it is never `source`d) and checks every download against it before using it. A mismatch stops the install.

| Component | Keys | Pinned (2026-11-08) | Source |
|---|---|---|---|
| Go toolchain (only to build Gluetun; deleted after the build) | `GO_VERSION`, `GO_SHA256_AMD64`, `GO_SHA256_ARM64` | 1.27.3 | <https://go.dev/dl/> (checksums: <https://go.dev/dl/?mode=json>) |
| Gluetun, built from source | `GLUETUN_VERSION`, `GLUETUN_COMMIT` | v3.41.3 | <https://github.com/qdm12/gluetun> |
| qBittorrent-nox, userdocs static build | `QBITTORRENT_RELEASE`, `QBITTORRENT_SHA256_AMD64`, `QBITTORRENT_SHA256_ARM64` | `release-5.3.0_v2.1.2` | <https://github.com/userdocs/qbittorrent-nox-static/releases> |
| VueTorrent | `VUETORRENT_VERSION`, `VUETORRENT_SHA256` | v2.36.1 | <https://github.com/VueTorrent/VueTorrent/releases> |
| Jackett, self-contained binaries | `JACKETT_VERSION`, `JACKETT_SHA256_AMD64`, `JACKETT_SHA256_ARM64` | v0.24.3030 | <https://github.com/Jackett/Jackett/releases> |
| FlareSolverr, run from source | `FLARESOLVERR_VERSION`, `FLARESOLVERR_COMMIT` | v3.5.2 | <https://github.com/FlareSolverr/FlareSolverr> |
| FileBrowser Quantum | `FILEBROWSER_VERSION`, `FILEBROWSER_SHA256_AMD64`, `FILEBROWSER_SHA256_ARM64` | v2.0.2-stable | <https://github.com/gtsteffaniak/filebrowser/releases> |
| qBittorrent's Jackett search plugin | `QBIT_SEARCH_PLUGINS_COMMIT`, `QBIT_JACKETT_PLUGIN_SHA256` | commit `b67ae21` | <https://github.com/qbittorrent/search-plugins> |

**How to bump one:**

1. Read the release notes. Change the version line in `native/versions.env`.
2. Get the new checksums with the helper the installer provides:

   ```bash
   bash native/install.sh pins
   ```

   It downloads every pinned file, for amd64 and arm64, and prints ready-to-paste `KEY=sha256` lines, plus `GLUETUN_COMMIT` and `FLARESOLVERR_COMMIT` from `git ls-remote` (for an annotated tag, the commit it points at). It needs only bash, curl, git and sha256sum, and no root, so run it on any Linux machine with internet access. This is trust on first use: it records whatever GitHub serves today, so read the release notes before you paste. For the search plugin, pick the new commit first (`git ls-remote https://github.com/qbittorrent/search-plugins refs/heads/master`), put it in `QBIT_SEARCH_PLUGINS_COMMIT`, then run `pins` for its sha256.
3. For FlareSolverr, regenerate `native/locks/flaresolverr.txt` too (below). `install` and `update` stop if FlareSolverr's own pins are missing from it.
4. Commit, then in the container: `bash /opt/torrent-stack/native/install.sh self-update` (or the host script's `--update`). `update` reinstalls and restarts only the components whose lines changed. A change to how a component is installed, with the same version, needs its `RECIPE` number in `native/install.sh` bumped so `update` notices.

**Breaking signals, per component** (details in [native/README.md](native/README.md)):

- **Gluetun:** the native build depends on things Gluetun's Docker image normally provides. `native/lib/dockerfile_env.py` extracts the `ENV` block of the Dockerfile at the pinned tag (Gluetun crashes without those defaults); the build patches one path in `internal/alpine/alpine.go` and stops with a message if upstream moved that line; the kill switch keeps the apps away from the control server on 8000, whose default authentication changed across versions. The `/tmp/gluetun/forwarded_port` deprecation above applies here too. A new Gluetun may need a newer Go: check its `go.mod`.
- **qBittorrent:** settings migrations (the 5.3 `[WebUI]` move above; `native/lib/render.py` moves old keys across) and the release tag format `release-<qBittorrent>_v<libtorrent>`.
- **Jackett:** needs Debian's `libicu76`; a Jackett that wants another ICU version needs `PACKAGES` in `native/install.sh` changed. It runs with `--NoUpdates` and `--DataFolder`.
- **FlareSolverr:** the install changes its chromedriver path (`/app/chromedriver`) and stops if upstream moved it; it uses Debian's `chromium` and `chromium-driver`, which apt keeps current.
- **FileBrowser:** `native/lib/filebrowser-prestart.sh` sets the admin password with `filebrowser user set admin --password --admin`, reading the password on stdin. A change to that command breaks the native login.
- **Search plugin:** it is Python code that qBittorrent runs. The pins are shared: `scripts/env-editor/seed_configs.py` reads the same two lines, for the env-editor and every Docker-style installer, and refuses a download whose sha256 differs.

### Native Python packages: `native/locks/`

| File | Holds | Generated from |
|---|---|---|
| `env-editor.txt` | The env-editor's venv in the native install (bcrypt 5.0.0, flask 3.1.3, requests 2.34.2 and their dependencies) | `scripts/env-editor/requirements.txt` |
| `flaresolverr.txt` | All 24 Python packages FlareSolverr needs, dependencies included | FlareSolverr's `requirements.txt` at `FLARESOLVERR_VERSION` |
| `build-tools.txt` | setuptools 84.2.1, to build `func-timeout`, which ships only as source | a file containing just `setuptools` |

Every line has an exact version and the sha256 of each file pip may use; pip runs with `--require-hashes --no-deps`. Regenerate on Debian 13 (Python 3.13) with pip-tools 7.5.2, keeping the comment block at the top of each file:

```bash
python3 -m venv /tmp/lock && /tmp/lock/bin/pip install pip-tools==7.5.2
/tmp/lock/bin/pip-compile --generate-hashes --allow-unsafe --strip-extras --no-header \
    --output-file native/locks/env-editor.txt scripts/env-editor/requirements.txt
# FlareSolverr: its requirements.txt from the new release tag
/tmp/lock/bin/pip-compile --generate-hashes --allow-unsafe --strip-extras --no-header \
    --output-file native/locks/flaresolverr.txt requirements.txt
```

`update` rebuilds a venv next to the old one when its lock file changed, and swaps it in only once pip succeeded.

**bcrypt** (in `env-editor.txt`, and `bcrypt>=4.0` in `requirements.txt` for Docker mode) hashes and checks the env-editor's own login only; its generated password is 24 characters. Since 5.0 it raises `ValueError` for a password longer than 72 bytes instead of cutting it short (checked with bcrypt 5.0.0). The qBittorrent password no longer goes through it: FileBrowser hashes that one itself, with Go's bcrypt and the same 72-byte limit, which the env-editor and every installer check (see [FileBrowser](#ghcriogtsteffaniakfilebrowser) above).

### The seeding image

`python:3.14.9-slim-trixie@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8`, pinned by tag and digest as `SEED_IMAGE` in three places that must be kept in step: `platforms/unraid/install.sh`, `platforms/synology/install.sh` and `platforms/casaos/install.sh`. It runs `seed_configs.py --only jackett,qbit` (standard library only, nothing pip-installed) when the host has no usable `python3`: always on Unraid, as a fallback on Synology and CasaOS, and always on ZimaOS. Synology also runs all its write checks in it (as the app user PUID:PGID and as FileBrowser's uid 1000), so the Synology installer always needs the image (it pulls it once if missing), even when DSM's `python3` does the seeding. TrueNAS seeds with TrueNAS's own `python3` and needs no image.

To bump it: pick a newer `python:3.X.Y-slim-trixie` tag, get its digest with `docker buildx imagetools inspect python:<tag>` (the top `Digest:` line, which covers every architecture; `docker pull` followed by `docker image inspect --format '{{index .RepoDigests 0}}'` gives the same value), replace `SEED_IMAGE` in all three installers, and run their test suites. Breaking signals: `seed_configs.py` must keep running on Python 3.8 (DSM 7's `python3`) as well as on the image's Python.

### Platform versions and APIs

Each installer checks the platform version where it can, and was written against one platform API. Moving to a new platform release means changing the check, re-reading that API, and rerunning `platforms/<p>/tests/run-tests.sh`.

| Installer | Refused / warned at run time | Written and tested against | Where |
|---|---|---|---|
| Proxmox VE | Refuses anything but 8.x and 9.x (`pveversion`) and non-amd64 hosts. Probes the host's `pve-container` and refuses one that cannot create Debian 13.1+ containers (fixed in 5.3.1 for PVE 8, 6.0.10 for PVE 9). PVE 8.0 gets the classic `lxc.*` lines for `/dev/net/tun`; 8.1+ uses `--dev0`. | `pct`/`pveam`/`pvesm`/`pvesh` per the PVE API schema (`apidoc.js`, which the tests validate against). Template: the newest `debian-13-standard` that `pveam` offers (not pinned). | `check_pve_version`, `check_debian13_support` in `platforms/proxmox/install.sh` |
| Incus | No version check. | Incus 6.0 LTS (tested 6.0.0); notes for 7.0 in its README. Image: `images:debian/13` (rolling; `TS_IMAGE` overrides). | `platforms/incus/install.sh` |
| TrueNAS | Refuses anything older than 24.10; warns on anything but 25.10. | Middleware API v25.10 (`app.create`, `app.update`, `app.query`, `app.pull_images`, `pool.dataset.create`, ...) through `midclt` and TrueNAS's own `truenas_api_client`; `app.delete` also checked against 27.0. | version check in `platforms/truenas/install.sh`; parameter tables in its test shims |
| Unraid | `MIN_UNRAID=6.12.0` (warns on anything but 7.x); `CM_MIN_VERSION=2026.09.03` (Compose Manager Plus, the release that pins each stack's project name); refuses the old Docker Compose Manager plugin. | Compose Manager Plus's stack folder layout and `compose.sh`. | top of `platforms/unraid/install.sh` |
| Synology DSM | `MIN_DSM=7.2`. | `SYNO.Docker.Project` (list, get, create, update, delete) and `SYNO.Core.EventScheduler` (get, create, delete), `version=1`, called with `synowebapi --exec`. Synology does not document these; they follow what DSM's web UI sends. Compose v2.9.0 and v2.20.1 (Container Manager's) and v5.6.1. | top of `platforms/synology/install.sh` |
| CasaOS / ZimaOS | `MIN_CASAOS=0.4.4`. | CasaOS-AppManagement's v2 API (`POST`/`PUT`/`DELETE /v2/app_management/compose[/torrent-stack]`, with `dry_run=true` first), tested on CasaOS 0.4.15. | top of `platforms/casaos/install.sh` |

## Non-container upstreams

### `scripts/env-editor` runtime (Docker mode)

A host-side Python app, not a container, so no image to pin. Dependencies installed into a venv at `scripts/env-editor/.venv/` by `./scripts/setup.sh`, which rebuilds it whenever `requirements.txt` changes or an earlier build failed partway (it compares the file's sha256 with `.venv/.requirements.sha256`, written after a successful install). The native install builds the same venv from the hash-pinned `native/locks/env-editor.txt` instead.

- **Python**: 3.9+ with the `venv` module (`python3-venv` on Debian/Ubuntu). `scripts/setup.sh` uses `$PYTHON` if set, else `python3` (whatever version it is), and only when there is no `python3` tries `python3.12`, `python3.11`, `python3.10` and `python3.9`, in that order. A host whose only Python is `python3.13` or newer without a `python3` link needs `PYTHON=python3.13 ./scripts/setup.sh`.
- **PyPI deps**: `flask>=3.0`, `bcrypt>=4.0`, `requests>=2.31` (`scripts/env-editor/requirements.txt`). Not pinned in Docker mode: `setup.sh` installs whatever PyPI has that matches.
- **qBittorrent search plugin**: `scripts/env-editor/seed_configs.py` downloads `jackett.py` from the commit pinned in `native/versions.env` (`QBIT_SEARCH_PLUGINS_COMMIT`) and refuses it unless its sha256 matches `QBIT_JACKETT_PLUGIN_SHA256`. It does so only when the plugin file is missing: delete `./configs/qbittorrent/qBittorrent/nova3/engines/jackett.py` to fetch it again after a pin bump.
- **Breaking signals:** Jackett's `/api/v2.0/indexers/<id>/config` schema. The Indexers tab is built from that schema, so a Jackett API change there would show up as a form that no longer validates against Jackett when submitted.
- **Pin / rollback:** edit `requirements.txt`; the next `./scripts/setup.sh` run rebuilds the venv. Regenerate `native/locks/env-editor.txt` from it as well.

### GitHub Actions

- **Pinned at:** inside `.github/workflows/*.yml`: `actions/checkout@v7` (`lint.yml`, `claude-breaking-review.yml`, `installers.yml`), `ludeeus/action-shellcheck@2.0.0` (`lint.yml`), `anthropics/claude-code-action@v1` (`claude-breaking-review.yml`). These are tags, not commit SHAs.
- **Source:** each action's own GitHub repo
- **Breaking signals:** `v1` → `v2` major on `claude-code-action` is the one most likely to actually require changes (prompt / input renames). `action-shellcheck`'s `severity` and `scandir` inputs are what `lint.yml` uses.
- **Auto-tracked:** yes, by Dependabot (`github-actions` ecosystem). Non-major bumps group on a Monday PR; majors land solo and get labelled `breaking-candidate` by `label-major-bumps.yml`.

### CI-only Python package

- **Pinned at:** `.github/workflows/installers.yml`, step "Python with PyYAML (pinned, in a venv)": `PyYAML==6.0.3` with `--require-hashes`, one `--hash=sha256:` per wheel it may use, the Linux x86-64 (manylinux) wheels for CPython 3.12, 3.13 and 3.14 (<https://pypi.org/project/PyYAML/6.0.3/#files>). The TrueNAS helper and the CasaOS schema check need it; nothing else in CI installs from PyPI.
- **Auto-tracked:** no. Dependabot has no `pip` ecosystem here, and the pin sits in a heredoc, not in a requirements file it could read. Bump it by hand: new version, and the sha256 of each of those wheels from its PyPI files page.
- **Breaking signals:** pip stops with a hash mismatch, or finds no matching wheel, when `ubuntu-latest` moves to a Python version the list has no wheel for. Add that wheel's hash.

### Diagram tools (`docs/images/`)

- **Pinned at:** `docs/images/package.json` and `package-lock.json`: `@mermaid-js/mermaid-cli` 12.0.0, `mermaid` 12.3.0 (an npm `overrides` entry) and `puppeteer` 25.13.0.
- **Used for:** rendering the README diagram with `docs/images/render.sh` (see CLAUDE.md, "Images and diagrams"). Nothing here runs in the stack or in an installer.
- **Breaking signals:** a Mermaid release that changes layout, the `classic` look or label wrapping shows up as different SVGs after a re-render; `postprocess.py` refuses to build the theme-aware SVG if the light and dark renders stop matching outside their stylesheet.
- **Bump by hand:** change the versions in `docs/images/package.json`, run `npm install --package-lock-only` in `docs/images/` to refresh the lock file, run `docs/images/render.sh`, and check every diagram again at phone width in both themes. Not tracked by Dependabot.

## How to add a new image

1. Add the `image: <ref>:<tag>` line in `compose.yaml`. Use a rolling tag (`:latest`, or the image's documented stable channel) unless you have a specific reason to pin.
2. Add a section here with a source link, breaking signals, and a pin-to-a-specific-version paragraph for rollbacks.
3. If the image carries wire-protocol or integration contracts that have broken on minor bumps (like Gluetun), call that out explicitly in the breaking signals.
4. The native install has no images: a new service there is a new component in `native/versions.env` (with checksums), a `stage_<name>` function and unit in `native/install.sh`/`native/lib/render.py`, and an entry in the table above. The Docker-style installers copy `compose.yaml`'s services (TrueNAS and CasaOS render them into their own formats), so check their drift tests too.
