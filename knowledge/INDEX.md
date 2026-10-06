# Knowledge and research index

Generated from `docs/research/*.md` and `knowledge/records/*.json` by `python3 tools/knowledge_index.py`; edit those, not this file. Gate steps: `knowledge-index` (this file is current), `knowledge-paths` (record scopes), `doc-links` (links and URLs).

Record scope `repo`: every path the record cites exists in this repository. Scope `workbench`: copied from the owner's local workbench; the paths, commands and receipts it cites exist only there, so its status (`*_on_workbench`) is a workbench observation this repo cannot reproduce. Treat it as a lead to re-check, not as evidence.

## Research docs

| Doc | Title |
|---|---|
| [agent-tooling-connectors-2026-10.md](../docs/research/agent-tooling-connectors-2026-10.md) | Agent tooling: connectors, plugins, skills, Studio plugins and creator-PC tools for Claude and Codex (verified 2026-10-06) |
| [blender-animation-pipeline-2026-10.md](../docs/research/blender-animation-pipeline-2026-10.md) | Blender and animation pipeline to Roblox (verified 2026-10-06) |
| [gameplay-libraries-2026-10.md](../docs/research/gameplay-libraries-2026-10.md) | Open-source Luau gameplay libraries and package managers (verified 2026-10-06) |
| [genre-coverage-2026-10.md](../docs/research/genre-coverage-2026-10.md) | Genre coverage research: chart genres, systems, pipelines and factory gaps (verified 2026-10-06) |
| [pipeline-audit-2026-10.md](../docs/research/pipeline-audit-2026-10.md) | Pipeline audit for production quality (verified 2026-10-06) |
| [release-monetization-analytics-2026-10.md](../docs/research/release-monetization-analytics-2026-10.md) | Release, monetization and analytics research: from finished build to published candidate (verified 2026-10-06) |
| [tooling-2026-10-addendum.md](../docs/research/tooling-2026-10-addendum.md) | Tooling research addendum (verified 2026-10-06) |
| [tooling-2026-10.md](../docs/research/tooling-2026-10.md) | Roblox Game-Production Workbench: Tooling Research (verified 2026-10-05) |
| [ui-cinematics-feel-2026-10.md](../docs/research/ui-cinematics-feel-2026-10.md) | UI, transitions, cutscenes and game feel: research (verified 2026-10-06) |
| [visual-audio-assets-2026-10.md](../docs/research/visual-audio-assets-2026-10.md) | Visual quality, lighting, materials, VFX, audio and free asset sources: research (verified 2026-10-06) |

## Knowledge records

| Record | File | Type | Status | Scope | Title |
|---|---|---|---|---|---|
| `analytics-offline-session-foundation` | [analytics-foundation.json](records/analytics-foundation.json) | workflow | partially_verified_on_workbench | workbench | Privacy-bounded offline session analytics |
| `analytics-release-commercial-review` | [analytics-release-policy.json](records/analytics-release-policy.json) | quality_criterion | researched_only | workbench | Release, earnings and policy review contract |
| `failure-gallery-canonical-path` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Gallery GET traversal and unguarded HEAD exposed files outside its allowlist |
| `failure-native-report-fail-open` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Incomplete or nonfinite constructed native reports were accepted |
| `failure-production-dependency-drift` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Planning resumed after acceptance artifacts changed |
| `failure-media-recovery-eof` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Repeated media intake missed deleted bytes; full clip sampling asked for EOF |
| `failure-studio-startup-layout` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Startup viewport and report lifetime made early native observations invalid |
| `failure-project-mcp-trust` | [failures.json](records/failures.json) | failure | blocked_on_workbench | workbench | Blender project MCP activation is blocked by normal host trust state |
| `failure-native-readback-output-cap` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Large native source readback was truncated |
| `failure-effects-moving-camera` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Effect counts passed while the capture missed the cues |
| `failure-observation-status-overflow` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Native observation status text overflowed |
| `failure-gate-optional-evidence` | [failures.json](records/failures.json) | failure | verified_on_workbench | workbench | Missing native receipts could leave a passing local gate |
| `failure-network-cold-start-deadline` | [failures.json](records/failures.json) | failure | partially_verified_on_workbench | workbench | Two Studio clients joined but sent no input before watchdog |
| `kit-event-offline-report` | [kits-build-2026-10.json](records/kits-build-2026-10.json) | workflow | verified | repo | Offline kit-event/1 analytics report |
| `lune-engine-gaps-2026-10` | [kits-build-2026-10.json](records/kits-build-2026-10.json) | failure | verified | repo | Lune 0.10.5 differs from the engine in ways that break kit specs |
| `workflow-blender-studio-import` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Blender-to-Studio import workflow: local preview and unverified native transfer |
| `workflow-motion-contact-review` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Responsive melee anticipation and recovery: curves, markers and contact diagnostics |
| `workflow-native-ui-state-review` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Readable mobile shop layouts and responsive native item cards |
| `workflow-onboarding-evidence` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | First-minute onboarding patterns and missing timing evidence |
| `workflow-effects-inspection` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Bounded native effect recipes and resource pooling |
| `workflow-source-bound-observation` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Camera and state traces tied to actual source readback |
| `workflow-world-query-review` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Scoped world geometry, grid, spawn-overlap and sightline review |
| `workflow-network-fault-review` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Local client/server echo, synthetic faults and disconnect review |
| `workflow-owned-window-recording` | [production-tools.json](records/production-tools.json) | workflow | partially_verified_on_workbench | workbench | Owned diagnostic HWND recording and retained decode verification |
| `tools-options` | [tools-options.json](records/tools-options.json) | tool_catalog | researched_only | repo | Focused optional art and authoring tools |
