# Security policy

## Reporting

Open a private GitHub Security Advisory on this repository, or email `rob.paprocki.14@gmail.com` with `[security:qbittorrent-vpn-docker]` in the subject line. Expect a first reply inside five business days; this is a hobby repo with one maintainer.

Do not open a public issue for a vulnerability until a fix is released.

## Supported versions

Only the current `main` branch is supported. Each change rolls forward; there are no backported releases.

## Known residual risks

These are documented, not fixed yet.

LinuxServer rolling tags. `lscr.io/linuxserver/qbittorrent` and `lscr.io/linuxserver/jackett` are pinned at `:latest`, so Watchtower may pull a new build at any time. The upstream tag convention `<version>-ls<build>` carries no SemVer promise and the LinuxServer team ships breaking changes without a major bump. Mitigation: Watchtower reports the pull in the configured notification channel and the stack can be rolled back by changing the tag to a specific `<version>-ls<build>` string.

VPN provider trust. All egress runs through Gluetun on the provider you configure in `.env`. The provider sees DNS, destination IPs, and traffic volume. The port-forwarding path requires a provider that supports it; providers that do not (NordVPN, Mullvad, AirVPN) leave qBittorrent's listen port at 0 and nothing seeds, which is a correctness issue rather than a security one.

FileBrowser scope. FileBrowser is bound to the downloads tree only. Mounting the project root or `configs/` would expose `.env`, VPN keys, qBittorrent session cookies, and the Jackett APIKey through its admin UI. The compose file is set up correctly; a future edit that changes the mount is a security change and should go through review.

Watchtower socket access. Watchtower in this stack holds the raw `/var/run/docker.sock` because it updates containers. The paired docker-pve stack uses a `docker-socket-proxy` only in front of its monitor-only Watchtower; the same reasoning applies here (an updater needs `POST` on `/containers/create`, so a proxy would have to grant it).

## Scope

Reports in scope: the compose file, `.env.example`, the port-forwarding helper (`update-qbittorrent.sh`), the setup instructions in the README, and the trust model described there.

Out of scope: the containers themselves (file bugs upstream), the VPN provider, Docker, your network.
