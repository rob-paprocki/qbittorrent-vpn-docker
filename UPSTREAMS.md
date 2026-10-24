# Upstream dependencies

Every pinned version in this repo, where it comes from, and what to watch for.

Renovate ([`renovate.json`](renovate.json)) opens PRs for bumps on a Monday morning cadence. Major-version bumps land on their own PR with the `breaking-candidate` label, which triggers [`.github/workflows/claude-breaking-review.yml`](.github/workflows/claude-breaking-review.yml); that workflow has Claude read the upstream changelog, decide whether the bump is a real break for this repo, and comment on the PR with a verdict. This file is the human companion.

## Container images (pinned)

### `qmcgaw/gluetun`

- **Pinned at:** `v3.41.3` (in `compose.yaml`)
- **Source:** [`qdm12/gluetun`](https://github.com/qdm12/gluetun) and the [port-forwarding wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md)
- **Breaking signals:** Gluetun carries VPN provider wire protocols and the port-forwarding integration this stack relies on. Both majors and minors are tagged `breaking-candidate` in `renovate.json` because provider-specific env variable renames have shipped as minors before. Changelog items under "BREAKING" or named provider removal are the signals to check.
- **Bump by hand:** change `image: qmcgaw/gluetun:...`, re-render the `.env.example` surface against the current Gluetun env table, redeploy.

### `ghcr.io/flaresolverr/flaresolverr`

- **Pinned at:** `v3.5.2`
- **Source:** [`FlareSolverr/FlareSolverr`](https://github.com/FlareSolverr/FlareSolverr)
- **Breaking signals:** API endpoint shape or the Jackett integration contract. Jackett's "FlareSolverr URL" setting is a stable `http://flaresolverr:8191` call; a protocol change would break that.
- **Bump by hand:** change the image tag. Verify Jackett's FlareSolverr URL still returns a 200 on `/health`.

### `ghcr.io/nicholas-fedor/watchtower`

- **Pinned at:** `v1.23.2` — the active community fork of the archived `containrrr/watchtower`.
- **Source:** [`nicholas-fedor/watchtower`](https://github.com/nicholas-fedor/watchtower)
- **Breaking signals:** env variable renames, label-prefix changes (`com.centurylinklabs.watchtower.*` is the stable prefix). This stack uses `WATCHTOWER_NOTIFICATION_URL`, `WATCHTOWER_SCOPE`, `WATCHTOWER_SCHEDULE`, and the shoutrrr URL scheme set.
- **Bump by hand:** change the image tag. The paired `docker-pve` stack pins the same image and the same tag; keep them in sync when bumping either.

### `ghcr.io/gtsteffaniak/filebrowser`

- **Pinned at:** `v2.0.1-stable`
- **Source:** [`gtstef/filebrowser`](https://github.com/gtstef/filebrowser) (the actively maintained fork)
- **Breaking signals:** admin credential flow (the current image prints a temporary admin password on first start; a change to that flow would need the README's post-install section updated). The mount path has to stay inside the downloads tree for security.
- **Bump by hand:** change the image tag. Re-read the FileBrowser post-install section in the README to confirm the admin credential path still matches.

## Container images (floating)

### `lscr.io/linuxserver/qbittorrent` and `lscr.io/linuxserver/jackett`

- **Pinned at:** `:latest` (not pinned)
- **Source:** LinuxServer uses the tag convention `<upstream_version>_v<libtorrent_version>-ls<build>` with a rolling `:latest`. No SemVer promise and no breaking-change log for the LinuxServer wrapper; breaking changes ship on the rolling tag without a major bump.
- **Why left on `:latest`:** pinning requires watching two upstream version streams (qBit itself, libtorrent) plus the LinuxServer build number, and tracking them properly is Round-4 work. Watchtower pulls nightly and reports the pull through the notification channel, so a bad build announces itself.
- **Renovate behaviour:** both are explicitly disabled in `renovate.json` so Renovate does not try to bump `:latest` to itself every week.
- **Bump by hand (pin, if desired):** replace `:latest` with the exact `<version>_v<libtorrent>-ls<build>` string shown by `docker inspect` on a running container.

## Non-container upstreams

### GitHub Actions

- **Pinned at:** inside `.github/workflows/*.yml` (`actions/checkout@v4`, `ludeeus/action-shellcheck@2.0.0`, `anthropics/claude-code-action@v1`)
- **Source:** each action's own GitHub repo
- **Breaking signals:** `v1` → `v2` major on `claude-code-action` is the one most likely to actually require changes (prompt / input renames).
- **Bump by hand:** change the `@` tag. Renovate also opens PRs for these.

## How to add a new pinned dep

1. Add the `image: ...:<tag>` line in `compose.yaml` (standard Docker Compose Renovate manager picks it up automatically).
2. If the dep deserves `breaking-candidate` on minors too (like `qmcgaw/gluetun`), add a `packageRules` entry in `renovate.json` naming it.
3. Add a section here with a source link, breaking signals, and a bump-by-hand paragraph.
