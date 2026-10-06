# Playbook: Sandbox, physics and creation (building, drawing)

Kind: genre
Covers: Simulation > Sandbox; Simulation > Physics Sim; Party & Casual > Coloring & Drawing

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no parts, setting, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Create**: place, move, rotate, scale and connect parts or blocks on a plot; or colour regions and draw on a canvas.
- **Test**: run the creation (physics sims: launch, drive, float, break) and see the result.
- **Save and load**: creations persist as data and rebuild on load; slots and versions.
- **Share**: show creations to others, visit plots, galleries, votes (TBD).
- **Unlock**: new parts, colours or tools through progress or purchase.
- **Undo and redo**: every edit is reversible within a history.

## Kit modules
- `GameKit/PlacementGrid`: footprints, rotation, snapping, refusal reasons, serialise and restore (placement/1).
- `GameKit/Plots`: plot claim and ownership for each builder.
- `GameKit/Inventory`, `GameKit/ItemDefs`, `GameKit/Progression`: available parts, colours and unlocks.
- `GameKit/PlayerData`: saved creations within the data budget.
- `GameKit/VotingRound`: judging or contests when creations are shown.
- `GameKit/Moderation`, `GameKit/ModerationRoblox` (T4): owner-run removal and bans in live games.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): creation names and signs.
- `GameKit/RateLimit`, `GameKit/RemoteGuard`: edit request limits and validation.
- `GameKit/Vehicles`, `GameKit/Knockback`: driving or launching creations (physics sims).
- `UIKit/Components/Grid`, `UIKit/Components/Toggle`, `UIKit/Components/Slider`: build toolbar, colour picker, tools.
- `SceneKit/Budgets`: part and triangle budgets per plot.

## Data to author
- Part or block catalogue: sizes, footprints, connection rules, physics properties (TBD).
- Plot size, height limit and part cap per plot (TBD).
- Canvas: resolution or region map, palette, brush rules (TBD).
- Save format version and migration rules.
- Sharing rules: who can visit, copy or vote (TBD).

## Authority and abuse risks
- **Edits**: every place, move and delete is validated on the server (ownership, bounds, caps, collisions) and rate-limited.
- **Save payloads**: validate structure and size on the server before saving (DataStore value limit is 4,194,304 characters); refuse oversize or malformed data.
- **Physics griefing**: unanchored creations flung into other plots; plot-bound collision groups or bounds kill.
- **Offensive creations**: shapes, drawings and text that others see need report and removal paths; text is filtered.
- **Copying**: whether players may copy others' creations (TBD).

## Performance pitfalls
- Part counts: cap per plot and per server; merge static builds where possible.
- Physics: many unanchored assemblies at once; sleep or freeze idle creations.
- Saving on every edit: debounce saves; save on leave and at intervals.
- Canvas as thousands of parts: use coarse regions or texture-based approaches (verify before choosing).

## Policy notes
- "Free-form user creation" is a Maturity & Compliance questionnaire category; rewarded video ads are not available to experiences with free-form user creation (release research, section 2).
- Drawings and builds that others see are user-generated content; the kits have no image moderation, so sharing needs report, hide and remove paths (TBD with the owner).
- Text on creations (names, signs) must be filtered.

## Test checklist
- [ ] Placement refusals: out of plot, overlapping, over cap, not owned; each with its reason.
- [ ] Serialise and restore round-trips a full plot exactly; a corrupted or oversize save is refused before writing.
- [ ] Undo and redo restore the exact previous state for every edit kind.
- [ ] Edit requests above the rate limit are refused.
- [ ] A flung creation cannot leave its plot or affect another player's plot.
- [ ] A full server of maximum-size plots stays inside the frame budget (`Diagnostics/PerfProbe`, T3).
- [ ] Report and remove paths work for shared creations.

## Design questions (TBD)
- TBD: Grid blocks, free placement, or both?
- TBD: Is physics testing part of the loop?
- TBD: Are creations shared, visited, judged or copied?
- TBD: How many save slots, and how large can a creation be?
- TBD: Drawing canvas, coloring regions, building, or several?

## Reference systems
- Placement grid and its placement/1 save format: [PlacementGrid.luau](../../../../packages/GameKit/PlacementGrid.luau) and `tests/gamekit_world_placement.spec.luau`.
- Questionnaire and ads rules in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), sections 1b and 2; DataStore limits in the [gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), section 3.
- Systems X13, X18 and X31 in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md).
