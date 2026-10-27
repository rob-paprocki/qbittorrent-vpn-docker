# Upstream dependencies

Every image this repo uses, where it comes from, and what to watch for.

Container images are on **rolling tags** (`:latest` or `:stable`), not version-pinned. Watchtower pulls nightly and announces each pull on the Discord notification channel, so a bad build makes noise. The breaking-signal notes below are what to re-read if the stack misbehaves after a Watchtower pull.

GitHub Actions references in `.github/workflows/*.yml` **are** pinned, and those still move through Dependabot:

- [`.github/dependabot.yml`](.github/dependabot.yml) auto-bumps the GitHub Actions pins. Non-major bumps group on one Monday PR; majors land solo.
- [`.github/workflows/label-major-bumps.yml`](.github/workflows/label-major-bumps.yml) adds the `breaking-candidate` label to any Dependabot PR crossing a major-version boundary. That label fires [`.github/workflows/claude-breaking-review.yml`](.github/workflows/claude-breaking-review.yml), which has Claude read the upstream changelog, grep this repo for the specific symbols flagged, and comment with a `REAL / NOT / UNCLEAR` verdict.

## Container images

### `qmcgaw/gluetun`

- **Tag:** `:latest`
- **Source:** [`qdm12/gluetun`](https://github.com/qdm12/gluetun) and the [port-forwarding wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md)
- **Breaking signals:** Gluetun carries the VPN provider wire protocols and the port-forwarding integration this stack relies on. **Minor bumps have shipped breaking changes** here, specifically provider-specific env variable renames. On a rolling tag that means Watchtower can silently pull a build that renames a `VPN_SERVICE_PROVIDER` env or changes the port-forwarding script contract. If port forwarding stops working after a pull, read the Gluetun release notes between the last two pulled image digests, and re-render `.env.example` against the current Gluetun env table if a rename is called out.
- **Pin to a specific version (if you need to roll back):** replace `:latest` with a tag from <https://github.com/qdm12/gluetun/releases>.

### `ghcr.io/flaresolverr/flaresolverr`

- **Tag:** `:latest`
- **Source:** [`FlareSolverr/FlareSolverr`](https://github.com/FlareSolverr/FlareSolverr)
- **Breaking signals:** API endpoint shape or the Jackett integration contract. Jackett's "FlareSolverr URL" setting is a stable `http://flaresolverr:8191` call; a protocol change would break that.
- **Pin to a specific version:** replace `:latest` with a tag from <https://github.com/FlareSolverr/FlareSolverr/releases>.

### `lscr.io/linuxserver/qbittorrent` and `lscr.io/linuxserver/jackett`

- **Tag:** `:latest`
- **Source:** LinuxServer uses the tag convention `<upstream_version>_v<libtorrent_version>-ls<build>` with a rolling `:latest`. No SemVer promise and no breaking-change log for the LinuxServer wrapper; breaking changes ship on the rolling tag without a major bump.
- **Breaking signals:** VueTorrent docker-mod compatibility (the theme is installed into qBittorrent via the `DOCKER_MODS: ghcr.io/vuetorrent/vuetorrent-lsio-mod:latest` env), `WEBUI_PORT` handling, PUID/PGID handling.
- **Pin to a specific version:** replace `:latest` with the exact `<version>_v<libtorrent>-ls<build>` string from `docker inspect` on a running container.

### `ghcr.io/nicholas-fedor/watchtower`

- **Tag:** `:latest`, the active community fork of the archived `containrrr/watchtower`.
- **Source:** [`nicholas-fedor/watchtower`](https://github.com/nicholas-fedor/watchtower)
- **Breaking signals:** env variable renames, label-prefix changes (`com.centurylinklabs.watchtower.*` is the stable prefix). This stack uses `WATCHTOWER_NOTIFICATION_URL`, `WATCHTOWER_SCOPE`, `WATCHTOWER_SCHEDULE`, and the shoutrrr URL scheme set.
- **Pin to a specific version:** replace `:latest` with a tag from <https://github.com/nicholas-fedor/watchtower/releases>. The paired `docker-pve` stack also runs this image; keep them aligned when pinning either.

### `ghcr.io/gtsteffaniak/filebrowser`

- **Tag:** `:stable`
- **Source:** [`gtsteffaniak/filebrowser`](https://github.com/gtsteffaniak/filebrowser) (the actively maintained fork)
- **Breaking signals:** admin credential flow (the current image prints a temporary admin password on first start; a change to that flow would need the README's post-install section updated). The mount path has to stay inside the downloads tree for security.
- **Pin to a specific version:** replace `:stable` with a tag from <https://github.com/gtsteffaniak/filebrowser/releases>.

## Non-container upstreams

### `scripts/env-editor` runtime

A host-side Python app, not a container, so no image to pin. Dependencies installed into a venv at `scripts/env-editor/.venv/` on first `./scripts/setup.sh` run.

- **Python**: 3.9+ (any version on PATH; `scripts/setup.sh` auto-picks the newest `python3*` it finds).
- **PyPI deps**: `flask`, `bcrypt`, `requests` — see `scripts/env-editor/requirements.txt`.
- **qBittorrent search plugin**: `scripts/env-editor/seed_configs.py` downloads `jackett.py` from <https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/jackett.py> on first seed. Delete `./configs/qbittorrent/qBittorrent/nova3/engines/jackett.py` to refetch.
- **Breaking signals:** Jackett's `/api/v2.0/indexers/<id>/config` schema — the Indexers tab is schema-driven, so a Jackett API change there would show up as a form that no longer validates against Jackett when submitted.
- **Pin / rollback:** edit `requirements.txt` and `rm -rf scripts/env-editor/.venv` to rebuild.

### GitHub Actions

- **Pinned at:** inside `.github/workflows/*.yml` (`actions/checkout@v4`, `ludeeus/action-shellcheck@2.0.0`, `anthropics/claude-code-action@v1`)
- **Source:** each action's own GitHub repo
- **Breaking signals:** `v1` → `v2` major on `claude-code-action` is the one most likely to actually require changes (prompt / input renames).
- **Auto-tracked:** yes, by Dependabot (`github-actions` ecosystem). Non-major bumps group on a Monday PR; majors land solo and get labelled `breaking-candidate` by `label-major-bumps.yml`.

## How to add a new image

1. Add the `image: <ref>:<tag>` line in `compose.yaml`. Use a rolling tag (`:latest`, or the image's documented stable channel) unless you have a specific reason to pin.
2. Add a section here with a source link, breaking signals, and a pin-to-a-specific-version paragraph for rollbacks.
3. If the image carries wire-protocol or integration contracts that have broken on minor bumps (like Gluetun), call that out explicitly in the breaking signals.
