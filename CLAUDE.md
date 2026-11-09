# Working on qbittorrent-vpn-docker

These rules apply to every change in this repository, whoever makes it.

## Versioning: Semantic Versioning 2.0.0

Releases follow [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html). Tags are `vMAJOR.MINOR.PATCH` (for example `v2.1.0`), annotated, and placed on the merge commit in `main`.

The **public interface** that SemVer protects is everything an existing install or a documented command relies on:

- `compose.yaml`: the service names, which services route through Gluetun, the published ports, the bind-mount layout (`CONFIG_PATH`, `DOWNLOADS_PATH`, `INCOMPLETE_DOWNLOADS`) and the Compose profiles;
- `.env.example`: every key's name and meaning, and its default;
- the scripts users run or that the stack runs: `scripts/setup.sh` and the env-editor (port 9191), `update-qbittorrent.sh` (Gluetun's port-forward hook) and the seeding CLI in `scripts/env-editor/seed_configs.py`;
- the installers: the one-liner for each platform under `platforms/`, `native/install.sh`, their flags and subcommands, the paths they install to, the systemd unit names and the kill switch's behaviour;
- the config files the stack writes under `CONFIG_PATH` and expects to find on the next start.

Pick the bump from the most significant change in the release:

| Bump | When | Examples |
|---|---|---|
| MAJOR | An existing install breaks or needs manual steps after updating, or a documented service, port, `.env` key, path, flag or default is removed or changes meaning | Renaming an `.env` key; turning Watchtower off by default; moving the config layout |
| MINOR | New functionality that leaves existing installs and documented commands working | A new platform installer; a new optional service; a new `.env` key with a safe default |
| PATCH | Fixes, docs, CI, and image or pin bumps that don't change documented behaviour | A port-forward script fix; a pinned-version bump; README corrections |

A dependency bump that changes documented behaviour (a port, a path, a default, a login flow) is MINOR or MAJOR, not PATCH. While a change is only on `main` and not released, it sits under `[Unreleased]` in the changelog.

## Changelog: Keep a Changelog 1.1.0

`CHANGELOG.md` follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

- Every PR that changes anything a user could notice adds a line under `## [Unreleased]` in the same PR. CI-only and repo-housekeeping changes may skip it.
- Group entries under `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` and `Security`, in that order, omitting empty groups.
- Write entries for the person running the stack, not for a reviewer: say what changed for them and what, if anything, they need to do. Link the PR as `([#15](https://github.com/rob-paprocki/qbittorrent-vpn-docker/pull/15))`.
- Breaking changes start with **BREAKING:** and say how to adapt (which `.env` keys to add or rename, which command to re-run).
- Keep the link references at the bottom (`[Unreleased]: …/compare/vX.Y.Z...HEAD`, `[X.Y.Z]: …/compare/vA.B.C...vX.Y.Z`) up to date.

### Cutting a release

1. Move the `[Unreleased]` entries into a new `## [X.Y.Z] - YYYY-MM-DD` section (ISO date) and update the link references, in a PR of its own or as the last commit of the PR being released.
2. After it merges, tag the merge commit: `git tag -a vX.Y.Z -m "vX.Y.Z" <sha>` and push the tag.
3. Create a GitHub Release for the tag, with that version's changelog section as the notes.

Never re-tag or move a published tag. If a release is wrong, publish a new PATCH.

## README

The README is the project's front page, so it should be more than a wall of text. When you change behaviour, update the README (and the matching `platforms/*/README.md` or `native/README.md`) in the same PR. Use these as the reference for what a good README covers:

- [banesullivan/README](https://github.com/banesullivan/README)
- [Utrecht University: README files](https://utrechtuniversity.github.io/workshop-computational-reproducibility/chapters/readme-files.html)
- [CodeRefinery: Writing good README files](https://coderefinery.github.io/documentation/writing-readme-files/)
- [UK Government Analysis Function: Project documentation](https://best-practice-and-impact.github.io/qa-of-code-guidance/project_documentation.html)

Keep these elements, and add them when they're missing:

- badges (licence, latest release, CI) at the top;
- one sentence saying what the project is for, then a short paragraph on who it's for and what problem it solves;
- a highlights list;
- a diagram (Mermaid renders on GitHub) where it explains the architecture or flow better than prose;
- a quick start someone can copy and paste, with its requirements;
- usage and configuration, using tables for options and defaults;
- troubleshooting or FAQ, using `<details>` blocks for long answers;
- how to get help, how to contribute, the licence, and credits.

Use GitHub alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) for things a reader must not miss, and sparingly.

## Writing anything a user will read

User-facing text here means the READMEs and other docs, `CHANGELOG.md`, release notes, the GitHub description and topics, PR and issue text, and the prompts, help text and messages the scripts and the env-editor show.

1. Write the first draft.
2. Run the **humanizer** skill on it: follow `.claude/skills/humanizer/SKILL.md`, and run `python3 .claude/skills/humanizer/scripts/copy_scan.py <file>` from the repo root.
3. Then run the **structural-humanizer** skill on the result: follow `.claude/skills/structural-humanizer/SKILL.md`, and run `python3 .claude/skills/structural-humanizer/scripts/structural_scan.py <file>`.
4. Re-check every fact the edits touched (versions, ports, paths, commands, `.env` keys, defaults) against the code. Polish must never change what the text claims.

The two skills are vendored from [NulightJens/humanizer-stack](https://github.com/NulightJens/humanizer-stack) at commit `13f5c02`, under its MIT licence (`.claude/skills/HUMANIZER-STACK-LICENSE`, attribution in `.claude/skills/HUMANIZER-STACK-ATTRIBUTION.md`). Update them by copying a newer commit over the top and recording the new commit here.

## Repository metadata

The GitHub description (one sentence, under about 120 characters) and topics must match what `main` does. When a change makes either one wrong (a new platform, a dropped component, a changed default), update them when the PR merges. Description text goes through the same humanizer passes as other user-facing text.
