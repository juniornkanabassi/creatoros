# CreatorOS

CreatorOS is a Mac app for video projects. It creates correctly named project folders from your own templates, with the right folder icons, and keeps track of every project as it moves from idea to published. I use it for every video I make.

[Releases](https://github.com/juniornkanabassi/creatoros/releases) · [App page](https://juniornkanabassi.com/apps/creatoros/)

There is no public download yet. The first one will be signed with my Developer ID, notarised by Apple and posted on this repository's Releases page. Until then you can build it from source (see below).

## What it does

You start with a template, a folder laid out the way you like to work, with your documents, project files and media folders inside it. CreatorOS imports a template from any folder, or from a Post Haste `.pht` file, and never changes the original. Templates can be grouped into sets, one per channel, brand or client, with a version for each format: Long, Short, Podcast and Live.

New Project shows the whole folder it is about to create as soon as you choose a set and a format, and updates the preview as you type. Folder names are built from the project number, the format, an optional campaign and the project name. A file named `Template`, or one whose name starts with `Template` followed by a space or a dot, takes the project's name. The next project number for each format is filled in for you. Every folder keeps its icon, and the outer folder gets the icon for its format.

Projects lists everything you have made across your drives and cloud folders, with a coloured badge for each location and a clear sign when a drive is not connected. You can search, filter, pin and group projects, open them in Finder or Premiere Pro, and browse their files in icon, list or column view. If you move a project folder, CreatorOS can find it again within your saved locations.

The Pipeline has two boards, one for recordings and one for live streams, with your own stages and colours. Each card holds the campaign, series, editor, notes and a Notion link. Ideas without a folder sit in the first column until you start them as a project. Changing a stage can also write a matching Finder tag on the folder.

For LucidLink, which refuses folder icon files, New Project has a Plain folders switch, and you can remove a project's folder icons before uploading and put them back afterwards.

## What you need

- A Mac with Apple silicon. Intel Macs are not supported.
- macOS 14 or later. I test it on macOS 26.
- Node.js 18 or later, but only if you want to use the MCP server with an AI assistant.

## Install

Once a release is out, download the disk image from the [Releases page](https://github.com/juniornkanabassi/creatoros/releases), open it and drag CreatorOS into Applications. Releases are signed with my Developer ID and notarised by Apple, so macOS only asks you to confirm the first time it opens.

## Updates

Releases signed with my Developer ID check for updates once a day and show you the release notes before anything changes. They install an update only when you say yes, unless you tick the option to install updates automatically, and CreatorOS › Check for Updates… checks straight away. A copy you build yourself, or one launched with `--data-directory`, has updates turned off.

## Privacy

CreatorOS works offline. It has no accounts, no analytics and no uploads. The only things it fetches are the update check from juniornkanabassi.com and the updates themselves from GitHub. Your library is stored in `~/Library/Application Support/Project Templates/` (the app's earlier name), and every schema upgrade keeps a backup of the old file. Removing a project from the list never touches its folder, and templates and idea workspaces that CreatorOS deletes go to the Bin. Removing an idea takes it off the list for good.

## Command line and AI assistants

Almost every action in the app is also a `creatoros` command and an MCP tool, so Claude, Codex and other assistants can create projects, move cards between stages and look things up for you. A command uses the same action as the matching button, though a few reach further (`stage move-all` also moves cards the board's filters are hiding), and most commands that move, rename or remove things accept `--dry-run` so you can see what would happen first.

```sh
CREATOROS="/Applications/CreatorOS.app/Contents/MacOS/creatoros"
"$CREATOROS" --help
"$CREATOROS" status --json
"$CREATOROS" project list --format Short --limit 10
"$CREATOROS" project create --format Short --title Example --dry-run
"$CREATOROS" project set-stage 001 --format Short --stage Editing
```

To connect the MCP server to Claude Code:

```sh
claude mcp add creatoros -- node "/Applications/CreatorOS.app/Contents/Resources/mcp/creatoros-mcp.mjs"
```

For Codex, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.creatoros]
command = "node"
args = ["/Applications/CreatorOS.app/Contents/Resources/mcp/creatoros-mcp.mjs"]
```

Change the paths if you installed the app somewhere else. The control socket only accepts connections from your own user account on the same Mac. The full list of about sixty commands and the rules they follow are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#ai-control).

## Building from source

You need an Apple silicon Mac and Xcode 26 or the Swift 6 command-line tools with a macOS SDK. The only dependency is Sparkle 2.10.0, which handles updates; SwiftPM fetches it.

```sh
swift build --scratch-path /private/tmp/content-template-build
swift run --scratch-path /private/tmp/content-template-build CoreChecks
zsh build.sh
```

`CoreChecks` is the test suite and prints `RESULT n checks passed`. `build.sh` writes `CreatorOS.app`, zipped into `../Outputs` outside the clone (set `CONTENT_TEMPLATE_OUTPUT_ROOT` to change it). It signs and notarises with my Developer ID when that certificate is in the keychain; on any other Mac it signs ad hoc, which is fine for running it yourself but which macOS treats as unverified. To try the app without touching a real library, launch it with `--data-directory` pointing at an empty temporary folder. The source layout, the checks and the install script are covered in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Limits worth knowing

Folder icons are macOS metadata, so they do not travel to Windows or phones. Whole-folder drag import, editing a managed template in place and sharing templates with other people are not built yet.

## Licence

Copyright (C) 2026 Junior Nkanabassi. Licensed under the GNU General Public License v3.0 or later (GPL-3.0-or-later); see [LICENSE](LICENSE). The CreatorOS name and icon are not covered by the licence.

In plain terms, you can use, change and share this code, but anything you distribute that is built on it has to stay open source under the same licence.

Sparkle, which handles updates, is under the MIT licence.
