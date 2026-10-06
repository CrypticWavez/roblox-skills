---
name: roblox-performance-pass
description: Measure and fix Roblox performance - frame time (MicroProfiler, perf/1 p50/p95/p99 captures from Diagnostics/PerfProbe), memory and instance counts, part/triangle budgets, connections and loops, replication bandwidth, UI churn, VFX lifetime - with numbers before and after. Use for lag, frame drops, memory growth, server heartbeat issues.
---

# Performance pass

## Purpose
Performance claims backed by numbers measured before and after each fix, in the Studio mode where the cost occurs. **Gate:** production skill. It acts on a game repository only after an explicit game-build request (AGENTS.md, Boundary); in this factory repo run it only against fixtures.

## Triggers
Lag, frame drops, memory growth, server heartbeat drops, long load times, part or triangle budgets exceeded.

## Inputs
The scenario that is slow, target device classes and budgets (frame time, memory, parts, triangles, network KB/s), the current build.

## Required context
`references/legacy-performance-profiling.md`; `docs/runtime-kits.md` section 9.7 (the perf/1 stats table: `frame_ms` p50/p95/p99, `memory_mb` per category, `counts`, `device_class`, `source`); budget sources: SceneKit `Validate.scene(scene, { maxParts })` (default 5000), ProcGen rule `maxParts` (`performance_part_estimate`), Blender `BUDGETS` in `tools/blender/bkit/qa.py`.

## Tools
- Studio MicroProfiler and Developer Console (memory, `Stats` network KB/s), Studio MCP `start_stop_play`, `execute_luau`, `get_console_output`.
- `packages/Diagnostics/PerfProbeRoblox.luau` (T3): `capture(env, { frames, timeout, deviceClass, sceneHash })` reads Stats memory per DeveloperMemoryTag, `InstanceCount`, a bounded Workspace walk (parts, lights, particles, sounds, highlights), `SceneTriangleCount` on the client, and Heartbeat step times, into a perf/1 table. A counter it cannot read is absent, never 0.
- `packages/Diagnostics/PerfProbe.luau` (T0, pure): `frameStats` (nearest-rank percentiles), `build`, `validate`, `collector`, `compare(before, after)` (per-metric deltas).
- Probes: `perf_capture` (server registry; `python3 tools/studio_run.py --probe perf_capture`) and `perf_capture_client` (client registry, play session only); see roblox-studio-testing.
- `packages/Creator/EffectsPool.luau` and `packages/Runtime/Lifetime.luau` for bounded VFX lifetimes.

## Procedure
1. Baseline in the right mode (client FPS in Test; server heartbeat and memory in Server & Clients): a perf/1 capture (`perf_capture` / `perf_capture_client`, or `PerfProbeRoblox.capture` through `execute_luau` during play), MicroProfiler dumps for where the time goes, Developer Console network KB/s. Frame timing needs a running session: in Edit mode `RunService:IsRunning()` is false and the probe records no `frame_ms`.
2. Static checks: part budgets from SceneKit/ProcGen validation, Blender QA triangle budgets, per-frame loops (RenderStepped/Heartbeat), connections without cleanup, `while true` without yields, frequent remote traffic.
3. Fix the highest cost first: merge static geometry, stream large worlds (StreamingEnabled), pool and bound VFX (EffectsPool, Lifetime), throttle replication, disconnect on cleanup.
4. Re-measure with the same scenario, frame count and device class; record before/after and `PerfProbe.compare(before, after)`.

## Outputs
A before/after table per metric and scenario (mode, device class, value, budget), the two perf/1 tables (each passes `PerfProbe.validate`) and their `compare` deltas, and the fixes made.

## Acceptance
Stated budgets met on the target device class with recorded numbers; correctness tests still pass.

## Failure
- Numbers vary run to run: repeat the scenario and report the median, not the best run.
- The cost is on a device you do not have: record it as unverified (device emulation is not physical-device evidence).
- A perf/1 counter is missing: the engine read failed or the member does not exist (Stats member names are UNVERIFIED until `perf_capture` has run in Studio). Report it as missing; never fill in 0.
- Device classes (`phone_low` ... `console`) and budgets are conventions until calibrated on real devices; say so next to any pass or fail against them.

## Related
roblox-scene-authoring, roblox-procedural-generation, roblox-release-pass.
