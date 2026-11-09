# Roadmap

What's planned for qbittorrent-vpn-docker. Each planned item links to its GitHub issue, which holds the design and the discussion. Nothing here is promised by a date.

## Planned: Discord notifications

Today the stack posts to Discord only when the VPN's forwarded port changes. These four issues add more, in the order they'd be built:

1. **[#20](https://github.com/rob-paprocki/qbittorrent-vpn-docker/issues/20): a shared notification helper and a `NOTIFY_EVENTS` setting.** The other three depend on it. Everything new stays off until you list it in `NOTIFY_EVENTS`.
2. **[#21](https://github.com/rob-paprocki/qbittorrent-vpn-docker/issues/21): a message when a download finishes**, with its name, size, category and folder.
3. **[#23](https://github.com/rob-paprocki/qbittorrent-vpn-docker/issues/23): alerts for native installs.** Native mode has no Dockhand or Watchtower watching it, so this covers a failed or restart-looping service and the result of each update.
4. **[#22](https://github.com/rob-paprocki/qbittorrent-vpn-docker/issues/22): VPN status**: connected, back after an outage (with how long it lasted), and public IP changes. Nothing that sends through the VPN can report that it's down, so the outage is reported on reconnect. The Docker stack follows Gluetun's development builds while native mode pins a release, and the two need different approaches.

If the stack runs on a [docker-pve](https://github.com/rob-paprocki/docker-pve) VM, Dockhand can send more alerts from outside the VPN, including Gluetun going unhealthy ([docker-pve#16](https://github.com/rob-paprocki/docker-pve/issues/16)).

## Planned: documentation

The native guide and the six platform guides get the same treatment the README had: shorter, readable on a phone, and with images that follow your light or dark theme.

## Known problems, not yet filed as issues

- **Native mode, placeholder user name.** If you set the qBittorrent user back to the `.env.example` placeholder after setup, FileBrowser's password quietly returns to the first-run one, and the editor's preview doesn't say so.
- **`$` in other `.env` values (Docker mode).** Docker Compose reads `$` as the start of a variable, so a value such as an OpenVPN password reaches the containers shortened. The editor refuses `$` only in the qBittorrent password.
- **Unknown `.env` keys.** The env-editor drops keys that aren't in `.env.example` when it saves.
- **Unraid's `--update`** doesn't re-check the qBittorrent password the way `--apply` does.
- **Native mode, hand edits.** A password edited by hand into `.env` and applied with `native/install.sh apply`, without the editor, isn't checked.
- **Two different minimums.** Unraid's and Synology's `--apply` want 8 characters, while the editor accepts 5 bytes.
- **A misleading message.** `scripts/setup.sh` and the editor's startup message say the password is saved to `credentials.json`, but only a hash of it is.
- **Test and CI tidiness.** The TrueNAS CI step leaves a `__pycache__` folder, the TrueNAS test scripts leave their work folder in `/tmp`, and two test scripts can hang if stdin is a pipe.

## How to suggest something

Open an issue. If it's a change you'd like to make yourself, see the README's [Contributing](README.md#contributing) section.
