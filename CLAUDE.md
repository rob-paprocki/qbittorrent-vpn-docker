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
- a diagram where it explains the architecture or flow better than prose (see **Images and diagrams** below);
- a quick start someone can copy and paste, with its requirements;
- usage and configuration, using tables for options and defaults where they fit a phone screen (two short columns, no long code in the cells), and lists where they don't;
- troubleshooting or FAQ, using `<details>` blocks for long answers;
- how to get help, how to contribute, the licence, and credits.

Use GitHub alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) for things a reader must not miss, and sparingly.

### Images and diagrams

- **No Mermaid**, or any other diagram that GitHub draws in the browser. The GitHub mobile app shows those as raw code. Commit each diagram as an image, generated with a free and open-source tool from a source file kept in the repository, and write the command that regenerates it next to the source.
- **Every image must suit the reader's theme**, light or dark, on github.com and in the GitHub mobile app. That covers diagrams, screenshots, logos and badges. Before merging, run the **Checks before merging** at the end of this section.

The lint workflow enforces both: it fails on a Mermaid block in any tracked Markdown file, and on an image from the repository that doesn't switch with the theme in one of the two ways below.

#### Diagrams: one self-switching SVG

Diagram sources live in `docs/images/` as Mermaid files (`NAME.mmd`). Mermaid is only the source language here: the diagram is rendered offline to SVG and committed, so GitHub never draws it. The tools are pinned in `docs/images/package.json` and `package-lock.json`: `@mermaid-js/mermaid-cli` 12.0.0, `mermaid` 12.3.0 and `puppeteer` 25.13.0 ([UPSTREAMS.md](UPSTREAMS.md) says how to bump them).

Keep diagrams narrow. GitHub's README column is about 327 px wide on a 393 px phone, and a wider SVG is scaled down, text included. Aim for a natural width of about 380 px or less, so that text stays at 13 px or larger at phone width. Wrap labels at about 16 characters with `<br/>`, and split a long flow into two diagrams.

After editing a `.mmd` file or `docs/images/mermaid-light.json` / `mermaid-dark.json`, regenerate from the repo root:

```bash
docs/images/render.sh          # every diagram
docs/images/render.sh NAME     # just NAME.mmd
```

`render.sh` installs the pinned tools with `npm ci` into a temporary folder it deletes afterwards, renders each diagram once with each config, and runs `postprocess.py`, which writes three files:

- `NAME-light.svg` and `NAME-dark.svg`, one per theme;
- `NAME.svg`, the one the docs show. It is the light render plus the dark render's colours inside `@media (prefers-color-scheme: dark)`, drawn on an opaque rounded panel, with a fixed width and height so it never stretches.

`render.sh` needs Node.js 22.13 or later, npm and python3. Puppeteer downloads its own Chrome on the first run; to use a Chrome or Chromium you already have, set `PUPPETEER_EXECUTABLE_PATH` to it. Box sizes come from the fonts on the machine that renders, so render where Arial or Liberation Sans is installed. Commit the `.mmd` file, any config change and all three SVGs together.

Show the diagram as a plain image, not inside a link, with a path relative to the Markdown file that shows it. Give it alt text that walks through every step and branch, and follow it with a short numbered list of the same flow, because the mobile app may not show the image:

```markdown
![Flowchart of what X does: first A, then B. If C, D; otherwise E.](docs/images/NAME.svg)
```

On github.com, the SVG follows the GitHub theme setting in Chromium-based browsers such as Chrome and Edge (tested in Chromium) and in Firefox (reported, not tested here). Safari and the other WebKit browsers, which include every browser on an iPhone or iPad, follow the device's appearance instead (also reported, not tested here). A reader whose GitHub theme differs from their device's then sees the other palette, and the opaque panel keeps that readable. The GitHub mobile app hasn't been tested.

#### Screenshots and other raster images: a `<picture>` pair

Commit `NAME-light.png` and `NAME-dark.png` and show both, with the light one as the fallback:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/NAME-dark.png">
  <img alt="What the screenshot shows" src="docs/images/NAME-light.png">
</picture>
```

Don't use the `#gh-dark-mode-only` and `#gh-light-mode-only` URL fragments. Inside a link, and anywhere outside github.com, both images show.

#### Badges

Badges stay single images from shields.io or GitHub Actions; don't make light/dark pairs. A badge is a link, so a fragment pair shows both images, and a `<picture>` pair doesn't reliably follow the GitHub theme. A shields badge is an opaque pill that reads the same on both themes, as long as its white text has enough contrast: use a message colour of at least 4.5:1, such as `0969da` (blue, 5.19:1) or `b35900` (orange, 4.83:1), not shields' own `blue` (4.38:1) or `E57000` (3.16:1). Give every badge alt text that says what it shows, and check that it renders without an error message. A release badge, for example, shows an error until a release is published.

#### Checks before merging

For every new or changed image:

1. Look at it at phone width (a 393 px wide browser window, or your browser's device mode) and on a desktop, in both GitHub themes (Settings → Appearance). Browse the README (or the guide that shows it) on the pull request's branch, so GitHub serves the new files.
2. Check that no text spills out of its box and that diagram text is at least 13 px at phone width.
3. Check contrast in both themes. Text needs at least 4.5:1 against what is directly behind it, and lines and borders at least 3:1. The diagram palette in the two config files gives text 13.9:1 (light) and 12.3:1 (dark), lines 4.55:1 on white and 4.16:1 on GitHub's dark background (4.27:1 and 3.80:1 on a subgraph's fill). If you change a colour, measure it again.
4. If you can, open the README in the GitHub mobile app too, and record what you saw in the pull request.

## Writing anything a user will read

User-facing text here means the READMEs and other docs, `CHANGELOG.md`, release notes, the GitHub description and topics, PR and issue text, and the prompts, help text and messages the scripts and the env-editor show.

1. Write the first draft.
2. Run the **humanizer** skill on it: follow `.claude/skills/humanizer/SKILL.md`, and run `python3 .claude/skills/humanizer/scripts/copy_scan.py <file>` from the repo root.
3. Then run the **structural-humanizer** skill on the result: follow `.claude/skills/structural-humanizer/SKILL.md`, and run `python3 .claude/skills/structural-humanizer/scripts/structural_scan.py <file>`.
4. Re-check every fact the edits touched (versions, ports, paths, commands, `.env` keys, defaults) against the code. Polish must never change what the text claims.

The two skills are vendored from [NulightJens/humanizer-stack](https://github.com/NulightJens/humanizer-stack) at commit `13f5c02`, under its MIT licence (`.claude/skills/HUMANIZER-STACK-LICENSE`, attribution in `.claude/skills/HUMANIZER-STACK-ATTRIBUTION.md`). Update them by copying a newer commit over the top and recording the new commit here.

## Repository metadata

The GitHub description (one sentence, under about 120 characters) and topics must match what `main` does. When a change makes either one wrong (a new platform, a dropped component, a changed default), update them when the PR merges. Description text goes through the same humanizer passes as other user-facing text.
