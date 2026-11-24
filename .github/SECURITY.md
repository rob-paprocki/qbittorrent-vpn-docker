# Security policy

## Reporting

Use this repository's **Security** tab and choose **Report a vulnerability**. That sends a private report that only I can see, and I'll reply there.

Don't open a public issue for a vulnerability until a fix is released.

## Supported versions

Only the latest release gets fixes. Each change rolls forward; there are no backported releases.

## Known residual risks

These are documented, not fixed yet.

LinuxServer rolling tags. `lscr.io/linuxserver/qbittorrent` and `lscr.io/linuxserver/jackett` are pinned at `:latest`, so whichever updater you use (Dockhand, the platform's own, or this stack's optional Watchtower, off by default) may pull a new build at any time. The upstream tag convention `<version>-ls<build>` carries no SemVer promise and the LinuxServer team ships breaking changes without a major bump. Mitigation: Dockhand and Watchtower can report updates in a notification channel, and the stack can be rolled back by changing the tag to a specific `<version>-ls<build>` string. The native install pins every version instead.

VPN provider trust. All egress runs through Gluetun on the provider you configure in `.env`. The provider sees DNS, destination IPs, and traffic volume. The port-forwarding path requires a provider that supports it; providers that do not (NordVPN, Mullvad, AirVPN) leave qBittorrent's listen port at 0 and nothing seeds, which is a correctness issue rather than a security one.

FileBrowser scope. FileBrowser is bound to the downloads tree only. Mounting the project root or `configs/` would expose `.env`, VPN keys, qBittorrent session cookies, and the Jackett APIKey through its admin UI. The compose file is set up correctly; a future edit that changes the mount is a security change and should go through review.

Watchtower socket access. When you turn it on, this stack's Watchtower holds the raw `/var/run/docker.sock` because it updates containers. A socket proxy would not help: an updater needs `POST` on `/containers/create`, so the proxy would have to grant it.

## Scope

Reports in scope: the compose file, `.env.example`, the port-forwarding helper (`update-qbittorrent.sh`), the setup instructions in the README and in `platforms/docker/README.md`, and the trust model described there.

Out of scope: the containers themselves (file bugs upstream), the VPN provider, Docker, your network.
