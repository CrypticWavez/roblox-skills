<!-- Legacy checklist from roblox-combat-hardening-pass (original repo root), cleaned of escaped Markdown. -->

## When to use

Use this skill when the user wants:

- combat fixed
- exploit prevention for guns or damage
- hit detection improved
- better weapon feel
- combat bugs removed
- reliable PvP behavior

## Core behavior

Start by auditing the combat pipeline end to end.

Inspect:

- weapon modules/configs
- combat services/controllers
- fire/equip/reload/ADS flow
- remotes used for combat
- damage validation logic
- headshot/bodyshot logic if applicable
- ammo and reload state handling
- kill/assist/reward flow
- death/elimination handling
- client-side feedback vs server-side authority

Then plan root-cause fixes and execute them.

## Combat standards

Combat should be:

- responsive
- readable
- fair
- server-authoritative where it matters
- resilient to remote abuse
- free of common state bugs
- satisfying in feedback

## Required checks

Validate:

- no client-trusted damage
- no invalid fire-rate abuse
- no free reward/kill abuse through remotes
- clean equip/unequip behavior
- clean reload behavior
- consistent ammo logic
- no obvious duplicate damage processing
- no stale weapon state after death/respawn/match transitions
- clean hit marker and kill confirmation flow

## Execution flow

### Pass 1: Audit

- identify broken or exploit-prone combat paths
- identify weak feel/readability issues

### Pass 2: Authority and validation

- validate combat remotes
- harden server damage logic
- fix state machine problems
- fix ammo/reload/equip edge cases

### Pass 3: Feel and feedback

- improve shot feedback
- improve hit confirmation
- improve timing and readability
- tune obvious frustration points

### Pass 4: Final validation

- retest PvP/PvE combat loops
- confirm exploit-sensitive flows are hardened

## Output expectations

Summarize:

- files modified
- exploit-sensitive paths fixed
- combat feel improvements made
- remaining risk areas if any

## Success condition

This skill succeeds when combat is reliable, responsive, fair, and hardened against obvious remote abuse or state glitches.
