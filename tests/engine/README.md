# Engine probes

Studio entry scripts for tier-T3 evidence. Each `tests/engine/<probe>.luau` is a RunScript entry for the unpublished kits diagnostic place built from [fixtures/kits.project.json](../../fixtures/kits.project.json). The contract (names, owner prefixes, registries, the line format) is [docs/runtime-kits.md](../../docs/runtime-kits.md) section 7. Nothing here runs in this container or in CI: Studio exists only on the owner's Windows or macOS PC.

## Line format

A run prints one line per check and exactly one done line, in canonical JSON (`GameKit/Probe`):

```text
ENGINE_CHECK {"check":"place_is_diagnostic","detail":{"reason":null},"ok":true,"probe":"foundation_env_studio"}
ENGINE_DONE {"checks":10,"errors":0,"failed":0,"ok":true,"passed":10,"probes":["foundation_env_studio"]}
```

A run without `ENGINE_DONE`, with counts that disagree with its check lines, or with a failed check, is a FAIL. Details carry counts and flags, never machine paths, user names or ids.

## Entries

| Entry | What it runs |
|---|---|
| `foundation_env_studio.luau` | Stage 0: the Studio Env (template for every entry) |
| `kitsmoke_all.luau` | `Pipeline/KitSmoke`: every shared and server `*_probes` registry merged, plus `kitsmoke_registries` (each registry loaded, no duplicate or invalid names) |
| `perf_capture.luau` | `Diagnostics/PerfProbeRoblox`: Stats memory, instance count, a Workspace walk and (in a running session) Heartbeat frame times as perf/1 |

Probes that live in a registry but have no entry here run through `kitsmoke_all` (and their own group's entry, when it has one).

## Running on the owner's PC

```text
python3 tools/studio_run.py --list
python3 tools/studio_run.py --probe kitsmoke_all --build
python3 tools/studio_run.py --probe perf_capture
```

`--build` runs `rojo build fixtures/kits.project.json -o build/kits.rbxl`. `tools/studio_run.py` starts Studio with the documented command line (`--task RunScript --localPlaceFile <place> --runScriptFile <entry> --outputFile <tmp> --quitAfterExecution`) and writes `reports/engine/<probe>.json` (schema `engine-report/1`: status, counts, failures, the commit, the entry's sha256, the place's sha256). It refuses `--placeId`, `--universeId` and every other published target, and a place outside `build/`. Where Studio is absent it writes `build/engine/<probe>.json` with status BLOCKED_EXTERNAL and exits 3; that is never a pass.

UNVERIFIED until the first run: whether the Studio CLI needs a logged-in user, and that RunScript runs in Edit mode (the docs say scripts run at command-bar level once the place loads). In Edit mode `RunService:IsRunning()` is false, so `perf_capture` skips frame timing and says so in check `frame_timing`.

## Play-session runs

Client probes (`perf_capture_client`) and anything that needs a running simulation run in a play session:

1. Open `build/kits.rbxl`, set the Workspace attribute `SETUP_ONLY_KitFixture` to `kitsmoke`, press Play.
2. `fixtures/kits/server/kitsmoke_Runner.server.luau` and `fixtures/kits/client/kitsmoke_Runner.client.luau` run the shared plus server, and shared plus client, registries.
3. Save the Output (or the Studio MCP console output) to a file under `build/` and record it:
   `python3 tools/studio_run.py --probe kitsmoke_all --from-output build/<file>.txt`

The report's `source.route` is `from-output` and `source.output_sha256` pins the captured file. Output from `lune run tools/lune/kit_smoke.luau` parses the same way but is Lune evidence, not Studio evidence: never record it under `reports/engine/`.

## Lune side

`lune run tools/lune/kit_smoke.luau` loads every registry, runs the G9b registries against fakes (`tests/fakes/FakeKitSmoke.luau`) and compares their lines with `tests/golden/kit-smoke.json`; `tests/pipeline_kitsmoke.spec.luau` asserts the same golden. Each group runs its own registry against its own fakes in its spec. That proves the probes load and their logic holds; the module stays T3 until the Studio output exists. `python3 tools/kit_tiers.py` joins every tier header with these reports.
