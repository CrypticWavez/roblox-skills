---
name: roblox-genre-systems
description: Neutral genre playbooks that map each official Roblox genre and subgenre (17 genres, 43 subgenres, via references/taxonomy.json) to kit modules, data to author, authority risks, performance pitfalls, policy notes, test checklists and open design questions. Use to plan or audit a game's systems once its genre is given; it never picks a genre. Load the taxonomy, then only the matching playbook.
---

# Genre systems

## Purpose
Turn a genre's systems, risks and checks into a plan or audit for a game whose genre is already chosen. The playbooks are neutral references: they map Roblox's official genres and subgenres to the factory's kit modules, the data a game must author, abuse and performance risks, policy notes, test checklists and the design questions that stay open (TBD). **Gate:** in this factory repo, use them for reference and fixtures only; acting on a game happens in a game repository after an explicit game-build request (AGENTS.md, Boundary). The genre comes from the owner's request; this skill never picks or ranks one.

## Triggers
- A game-build request or brief names a genre, subgenre or informal genre word ("obby", "tycoon", "horror").
- Auditing an existing game's systems against its genre, or writing its completion contract.
- Checking which kit modules a genre needs, or which open questions to put to the owner.
- Editing a playbook or the taxonomy (then run the lint).

## Inputs
- The owner's genre and subgenre (official labels, or an informal word to resolve through `aliases`).
- The game's brief, target devices and audience, and its current build or requirements, when auditing.

## Required context
- `references/taxonomy.json` (genre-taxonomy/1): every official genre and subgenre from [genre coverage research](../../../docs/research/genre-coverage-2026-10.md), section 1, mapped to a primary playbook, extra `also` playbooks, or a reasoned exclusion (only Utility & Other). `aliases` resolves informal words; `cross_cutting` lists the four playbooks any genre may add.
- Only the playbooks the map names for the game: `references/<playbook>.md`. Do not read the others.
- Module names come from [runtime-kits.md](../../../docs/runtime-kits.md), section 11; tiers (T3 probe pending, T4 blocked external) from section 5.

## Tools
- `python3 tools/playbook_lint.py` (map, format, module names, neutral wording) and `python3 -m unittest tests/test_playbook_lint.py`.
- `ProcGen/Course` with `Validate.course` (obby, tower, race loop, lanes, micro-arena), the other ProcGen validators, `SceneKit/Measure` (jumps, reach, clearance).
- GameKit specs and slices (`lune run tests/run.luau gamekit`), `GameKit/EconomySim` for economy pacing.
- The cross-cutting skills under Related.

## Procedure
1. Resolve the genre: find the label in `references/taxonomy.json` (`genres[].subgenres[]`, or `<Genre> > (none)`), using `aliases` for informal words. Several labels are fine for a hybrid.
2. Load the primary playbook, then any `also` and cross-cutting playbooks the game actually needs.
3. Copy the playbook's "Design questions (TBD)" into the brief as open questions for the owner. Do not answer them.
4. For each system under "Core loop as systems", list its kit modules and the data to author; mark each module's tier (T0 to T4) from its header.
5. Turn every "Test checklist" item into an acceptance item with a measurable check (a Lune spec, a validator, a probe, a capture) or a human sign-off for fun, art, fairness and device feel.
6. Turn every "Authority and abuse risks" item into a server-side test (forged remotes, rate limits, duplicate grants) and every "Policy notes" item into a release-check item.
7. When editing playbooks: keep the format below, cite only modules from runtime-kits section 11 (or existing authoring modules), keep wording neutral, run the lint and `python3 tools/sync_skills.py`.

**Playbook format** (checked by `tools/playbook_lint.py`): line 1 `# Playbook: <title>`; header lines `Kind: genre | cross-cutting`, `Covers:` (genre playbooks: exactly the labels the map gives them), `Also:` (exactly the labels whose `also` names them); then the `##` sections, in order: Core loop as systems, Kit modules (at least 3 modules), Data to author, Authority and abuse risks, Performance pitfalls, Policy notes, Test checklist (at least 5 `- [ ]` items), Design questions (TBD) (at least 3 `- TBD: ...?` items), Reference systems. No genre recommendations, no prices.

## Outputs
- The genre's system list with kit modules, tiers and data to author.
- Acceptance items per checklist entry, each with evidence or an explicit deferral.
- Open design questions for the owner, copied verbatim as TBD.

## Acceptance
- Every checklist item maps to evidence from this session or a reasoned deferral; T3 items stay pending until a probe runs on the diagnostic place, T4 items stay BLOCKED_EXTERNAL here.
- No TBD is answered by the agent.
- After any edit, `python3 tools/playbook_lint.py` prints PASS and its unit tests pass.

## Failure
- The genre is not in the taxonomy: say so; use the closest label only if the owner agrees, and list what does not apply. Do not invent labels.
- A label is excluded (Utility & Other): apply the cross-cutting playbooks and platform skills case by case, as the exclusion says.
- An item cannot be measured: record it as a human sign-off, not a pass.
- A cited module does not exist yet (its group has not merged): plan against the name in runtime-kits section 11 and mark the item pending.

## Related
roblox-gameplay-kit, roblox-presentation-pass, roblox-level-design-review, roblox-procedural-generation, roblox-scene-authoring, roblox-persistence-and-commerce, roblox-multiplayer-integrity, roblox-ui-ux-pass, roblox-performance-pass.
