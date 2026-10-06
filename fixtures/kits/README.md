# Kit fixtures

Scripts, modules and probe registries for the SETUP_ONLY kits diagnostic place, [kits.project.json](../kits.project.json). The place maps every package under `ReplicatedStorage.Workbench` and these three folders. Run it only as an unpublished diagnostic place; nothing here is game content. Contract: [docs/runtime-kits.md](../../docs/runtime-kits.md).

| Folder | Becomes | Holds |
|---|---|---|
| [server/](server/) | `ServerScriptService.KitFixtures` | `.server.luau` fixture scripts and server-only ModuleScripts (server probe registries) |
| [client/](client/) | `StarterPlayer.StarterPlayerScripts.KitFixtures` | `.client.luau` fixture scripts |
| [shared/](shared/) | `ReplicatedStorage.KitFixtures` | ModuleScripts both sides require (shared probe registries, cutscene fixtures) |

Empty folders keep a `.gitkeep`; Rojo builds them as empty Folders.

## File prefixes (one owner each)

Every file starts with its owner's prefix. A group creates files only under its own prefixes.

| Prefix | Owner |
|---|---|
| `foundation_` | Stage 0 (coordinator) |
| `platform_` | G1 platform services |
| `authority_`, `action_` | G2 action kit |
| `economy_` | G3 economy kit |
| `ui_`, `cin_` | G4 UI kit and cinematics |
| `lookdev_` | G5 look, sound and feel |
| `level_` | G7 level, AI and playbooks |
| `kitsmoke_` | G9b verification harness |

## Rules

- **Opt-in by attribute.** A fixture script does nothing unless `Workspace:GetAttribute("SETUP_ONLY_KitFixture")` equals its fixture key; the project sets it to `none`. Keys in use: `authority` (G2), `ui-gallery` (G4), `lookdev` (G5), `kitsmoke` (G9b). A new key goes to the coordinator (COORDINATOR_CHANGES) for this table.
- **Probe registries** are ModuleScripts named `<prefix>_probes.luau` that return `{ [probeName] = function(ctx) ... end }`. They have no requires: kit modules come from `ctx.kit("GameKit/Signal")`, the Env from `ctx.env`, results go through `ctx.check(name, ok, detail)`. Probe names use the owner prefixes in docs/runtime-kits.md (section "Probe contract"). Example: [shared/foundation_probes.luau](shared/foundation_probes.luau).
- **Prove it loads.** Each registry is required and run against `tests/fakes/FakeEnv.luau` in a Lune spec of its owner, so a typo fails here, not first in Studio. Studio runs stay pending until the owner runs them.
- **Server Authority.** Simulation fixtures step from `RunService:BindToSimulation`, read `time()`, take input through Input Action System actions and keep at most 64 attributes per Instance.
