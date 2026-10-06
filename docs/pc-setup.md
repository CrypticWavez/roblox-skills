# Owner PC setup

The steps an owner takes on the Windows or macOS PC that runs Roblox Studio and Blender. The factory repository never installs anything on the PC by itself. Agents run an install command only after the owner approves that exact command (research: [agent-tooling-connectors-2026-10.md](research/agent-tooling-connectors-2026-10.md) sections 9 to 11).

Every step below has a matching check in `tools/pc_doctor.py`. The doctor is read-only: it prints a report and writes nothing. It shows your home folder as `~`, but its output can still name local folders, so keep it out of the repository.

```text
python3 tools/pc_doctor.py                      # every check
python3 tools/pc_doctor.py --blender <Blender executable> --tools-dir <tools folder>
python3 tools/pc_doctor.py --json               # the same, as JSON on stdout
```

| Status | Meaning |
|---|---|
| PASS | the item is installed at the expected version |
| FAIL | something is wrong: a version differs from its pin, Aftman comes first on PATH, telemetry is on, or Node is older than 20. The exit code is 1 |
| TODO | an approved item is not installed yet |
| OPTIONAL | an optional extra is not installed |
| UNCHECKED | the check needs an argument (`--blender`, `--tools-dir`, a skill folder) |

In this document `<home>` means your user folder (`%USERPROFILE%` on Windows, `~` on macOS). No path below depends on a user name.

## Before you start

- **Node.js 20 or newer.** The Claude Code and Codex hooks run on Node. Install it with the vendor installer. Check: `node`.
- **Rokit 1.2.** Install it with the installer from the Rokit releases page (rojo-rbx/rokit). Then run `rokit install` in this repository to get the factory's pinned toolchain (rojo 7.7.0, lune 0.10.5, stylua 2.5.2, selene 0.31.0 and luau-lsp 1.70.1, from `rokit.toml`). Check: `toolchain:*`.

## The nine approved items

No admin rights on the PC? ImageMagick, Krita and Audacity (and Inkscape, under optional extras) also publish official portable or archive builds. Unpack one into the tools folder (item 6), add the folder that holds its executable to the user PATH and open a new terminal. The doctor finds each tool by its check command, so the tool needs a launcher on PATH under that name (for example `audacity`).

### 1. ImageMagick

Image conversions and checks on the PC (resize, alpha and format checks before an upload is even considered). Install ImageMagick 7 with the official installer from imagemagick.org. Keep its default security policy. Scripts must never pass untrusted file names to it unquoted. No gate or skill depends on it: the research rejected it as a repository dependency. Check: `imagemagick` (`magick -version`).

### 2. Krita

Raster painting for textures, UI art and thumbnails, mostly through its GUI. Install it from krita.org. The doctor looks for `krita` on PATH, then for the default install folder. Check: `krita`.

### 3. Audacity

Audio trimming, loudness work and export for owner-made sound effects. Install it from audacityteam.org. It is GUI only, so agents do not drive it. For automated audio checks, use FFmpeg/ffprobe. Check: `audacity`.

### 4. glTF Transform

A command-line tool that inspects and optimises glTF/GLB files: prune, dedup, texture resize. Use the pinned version, either as `npx @gltf-transform/cli@4.5.1 <command>` (no global install) or with `npm install --global @gltf-transform/cli@4.5.1`. The doctor only sees a global install. Check: `gltf-transform` (`gltf-transform --version`).

### 5. Material Maker

Procedural texture authoring (MIT, GitHub releases of RodZill4/material-maker). It ships as a portable folder. Unzip it into your tools folder (item 6) and add the folder that holds its executable to PATH. It has no confirmed headless export, so it stays an owner tool and no skill depends on it. Check: `material-maker`.

### 6. The tools folder

A plain folder outside every git repository, for example `<home>/roblox-tools`. It pins the Roblox command-line tools for work outside a repository. Copy [templates/pc-tools/rokit.toml](../templates/pc-tools/rokit.toml) into it, then run `rokit install` there. The file pins:
- the factory's five tools;
- darklua 0.19.0 (MIT; Luau bundling and require conversion for game repositories);
- Wally 0.3.2 (MPL-2.0; package installs only, because the guards deny `wally publish` and `wally login`).

Repositories keep their own `rokit.toml`, and Rokit uses the nearest one, so this folder never changes the factory's pins. Checks: `tools-folder` (with `--tools-dir <home>/roblox-tools`) and `pc-tools:darklua` / `pc-tools:wally`.

### 7. Rokit before Aftman on PATH

If Aftman was installed before Rokit, its shim folder can come first on PATH. A bare `rojo` then runs Aftman's shim and fails (gap matrix T09). Fix it in one of two ways:
- On Windows, open Settings > System > About > Advanced system settings > Environment Variables > Path (user variables) and move `%USERPROFILE%\.rokit\bin` above `%USERPROFILE%\.aftman\bin`.
- Uninstall Aftman. Rokit reads `aftman.toml`.

Windows searches the system Path before every user entry. If `.aftman\bin` is listed under System variables, reordering the user variables cannot fix it: remove it from the system Path (this needs admin rights) or uninstall Aftman. Until then, renaming Aftman's `rojo.exe` shim (for example to `rojo.exe.aftman-disabled`) lets a bare `rojo` reach Rokit and can be undone, but `path-order` keeps failing, because Aftman's other shims, or a reinstalled `rojo` shim, would come first again.

Open a new terminal, then run `rojo --version`. It should print 7.7.0. Checks: `path-order` and `toolchain:rojo`.

### 8. The Blender MCP telemetry check

The `blender` MCP server (mcp-for-blender 2.1.8) runs with `DISABLE_TELEMETRY=true` from [.mcp.json](../.mcp.json) and `.codex/config.toml`. The Blender add-on has its own telemetry preference, and older add-on versions defaulted it to on (gap matrix M04). To check it:
1. In Blender, open Edit > Preferences > Add-ons > the MCP add-on.
2. Make sure telemetry is unticked.
3. Click Save Preferences.

`pc_doctor --blender <Blender executable>` reads that preference through Blender in background mode. It never saves preferences. Checks: `telemetry:server` (the repository configs) and `telemetry:addon`.

### 9. The user-skills copy

You can copy the starter's game-facing skills (the `SKILLS` list in `tools/new_project.py`) into your user skill folders, so Claude Code and Codex find them in any game repository:

```text
python3 tools/user_skills.py --claude <home>/.claude/skills --codex <home>/.agents/skills           # dry run
python3 tools/user_skills.py --claude <home>/.claude/skills --codex <home>/.agents/skills --apply
```

How the copy behaves:
- Each skill gets a `.factory-stamp.json` with the factory commit and a hash of its files.
- Running the command again updates outdated skills.
- A skill you edited in place is kept unless you add `--force`.
- Your own skills in those folders are never touched.
- The tool refuses folders inside a git repository.

Rerun it after pulling the factory. Check: `skills-copy:claude` and `skills-copy:codex` (defaults to those two folders; `--claude-skills` and `--codex-skills` override them).

## Optional extras

### Inkscape

SVG to PNG from the command line (`inkscape --export-type=png --export-filename=out.png in.svg`), for UI icons and frames that agents write as SVG text. Install it with `winget install Inkscape.Inkscape` or the installer from inkscape.org. Check: `inkscape`.

### VS Code extensions

The five selected extensions are listed below. The Rojo extension is not on the list: it is stale, and the CLI does the same job. Install each one with `code --install-extension <id>`. Check: `vscode-extensions`.

| Extension | Id |
|---|---|
| Luau Language Server | `JohnnyMorganz.luau-lsp` |
| StyLua | `JohnnyMorganz.stylua` |
| Selene | `Kampfkarren.selene-vscode` |
| Claude Code | `anthropic.claude-code` |
| Codex | `openai.chatgpt` |

### Blender Lab MCP trial

The official Blender Lab MCP server (v1.0.3, GPL-3.0-or-later, Blender 5.1 or newer) is a candidate replacement for mcp-for-blender. To trial it:
- install its add-on from the Blender Lab extensions repository;
- install its server from the pinned git tag, as described in [docs/mcp.md](mcp.md);
- never let two MCP clients share one Blender.

Check: `blender-lab` (a `blender_lab` entry in `.mcp.json`).

## Claude Code luau-lsp plugin

This repository ships a local plugin (`plugins/luau-lsp`, listed in `.claude-plugin/marketplace.json`) that gives Claude Code Luau diagnostics through luau-lsp. To enable it:
1. Fetch the pinned Roblox definitions and API docs: `python3 tools/luau_defs.py`. They go into `build/luau-lsp/`.
2. Write the kit sourcemap once: `python3 tools/luau_analyze.py`. It runs `rojo sourcemap` into `build/luau-lsp/sourcemap.json`, which the plugin reads for `require` resolution. Rerun it after adding modules.
3. In Claude Code, run `/plugin marketplace add ./` from the repository root, then `/plugin install luau-lsp@roblox-factory`.
4. Accept the workspace trust prompt.

The plugin runs the `luau-lsp` that `rokit install` puts on PATH (1.70.1). It never passes `--enable-crash-reporting`, so luau-lsp sends no crash reports. Claude Code then receives luau-lsp's diagnostics after each edit of a `.luau` file. Cloud sessions do not start language servers. `python3 -m unittest tests.test_luau_analyze` checks the manifests and, when a luau-lsp binary is on PATH, runs a language-server round trip with the plugin's arguments.

## After setup

Run `python3 tools/pc_doctor.py` again, and `python3 tools/check.py` in the repository. Do not paste the doctor's output into the repository or a public issue: it can name local folders.
