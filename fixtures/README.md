# Fixtures

What each entry in `fixtures/` is and what consumes it. Every place here is an unpublished SETUP_ONLY diagnostic, not game content. The gate step `fixtures-readme` fails when an entry is missing from this table, and `rojo-sourcemap` maps every `*.project.json` and fails on any `.luau` file no project reaches.

| Entry | What it is | Consumed by |
|---|---|---|
| [analytics/](analytics/) | Synthetic session events (`neutral_events.jsonl`) with the expected report and default exclusions | Nothing in this repo. Inherited inputs for workbench analytics tools that are not here (`tools/analytics_report.py`, `tests/test_analytics.py` on the owner's PC; record `analytics-offline-session-foundation`). Planning validation only, not game decisions. |
| [briefs/](briefs/) | Two hypothetical dry-run planning briefs | Nothing in this repo. Inherited inputs for workbench planning validators that are not here. Planning validation only: their genre and aesthetic fields are test inputs, not game decisions (gap matrix X02). |
| [content/](content/) | `neutral-graph.json`, a metadata-only content graph | Nothing in this repo. Inherited input for workbench content-graph tooling that is not here. |
| [creator/](creator/) | Five Creator diagnostic client scripts (UI, Effects, AudioMovement, MediaPlayback, World) | `creator.project.json`; gate steps `stylua`, `rojo-sourcemap`. |
| [creator.project.json](creator.project.json) | Rojo project SETUP_ONLY_Creator_Tools_Diagnostic: `packages/Runtime`, `packages/Creator`, `creator/` and `observation/Diagnostic.client.luau` | CI `rojo build`; gate `rojo-sourcemap`; Studio runs of the inherited Creator diagnostics (gap matrix R02). |
| [diagnostic.project.json](diagnostic.project.json) | Rojo project SETUP_ONLY_Workbench_Diagnostic: all of `packages/` plus `runtime/Diagnostic.client.luau` | CI `rojo build`; gate `rojo-sourcemap`; Studio runtime diagnostic. |
| [factory/](factory/) | `FactorySmoke.server.luau`, the Studio smoke test (SceneKit and ProcGen scenes, hashes against `tests/golden/studio-smoke.json`) | `factory.project.json`; skill `roblox-studio-testing`; gap matrix S02. |
| [factory.project.json](factory.project.json) | Rojo project SETUP_ONLY_Factory_Diagnostic: the six packages plus FactorySmoke (disabled) | CI `rojo build`; gate `rojo-sourcemap`; the Studio smoke run (S02). |
| [network/](network/) | Echo server and client scripts and `Settings.luau` | `network.project.json`; `Settings.luau` also by `tests/diagnostics/network.luau` (gate step `inherited-diagnostics-network`). |
| [network.project.json](network.project.json) | Rojo project SETUP_ONLY_Workbench_Network_Diagnostic | Studio network diagnostic (unpublished place). Its `SourceManifest` is generated into `build/network/` by `python3 tools/network_manifest.py`; CI builds it and `rojo-sourcemap` maps it. |
| [observation/](observation/) | `Diagnostic.client.luau` and `neutral-case.json`, a synthetic observation case | The script: `creator.project.json`. `neutral-case.json`: nothing in this repo; inherited input for the workbench `tools/scenario_capture.py`. |
| [runtime/](runtime/) | `Diagnostic.client.luau` and `economy_assumptions.json`, neutral arithmetic (not an economy design) | The script: `diagnostic.project.json`. `economy_assumptions.json`: nothing in this repo; inherited input for workbench tooling that is not here. |
