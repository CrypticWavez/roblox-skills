<!-- Legacy checklist from roblox-tower-defense-wave-and-pathing-pass (original repo root), cleaned of escaped Markdown. -->

name: roblox-tower-defense-wave-and-pathing-pass

# Roblox Tower Defense Wave and Pathing Pass

## Purpose

Use this skill for tower defense games with waves, enemy paths, tower placement, targeting logic, and round economies.

This skill focuses on:

- wave logic
- enemy spawning
- pathing
- tower placement validation
- tower targeting
- round progression
- economy and rewards
- save/load if persistent upgrades exist

## When to use

Use this skill when the user wants to:

- build or improve a TD game
- fix wave bugs
- fix enemy paths
- improve tower placement
- improve targeting and round flow

## Core behavior

Audit:

- wave manager
- enemy path logic
- placement validation
- targeting and attack logic
- reward/economy logic
- round transitions
- failure/win conditions

Then fix correctness before polish.

## Quality standards

TD systems should be:

- deterministic
- readable
- fair
- free of broken pathing
- free of invalid placement exploits
- stable across wave transitions

## Required checks

Validate:

- wave start/end
- enemy spawn and path completion
- tower placement rules
- tower sell/upgrade logic if present
- targeting correctness
- reward grants
- failure/win flow
- no duplicated wave processing
- no invalid path breaks

## Execution flow

### Pass 1: Audit

- identify broken pathing and wave logic

### Pass 2: Logic fixes

- fix pathing
- fix placement and targeting
- fix reward and round transitions

### Pass 3: Polish

- improve readability and pacing
- improve wave/UI clarity

### Pass 4: Final validation

- retest complete wave flow

## Success condition

This skill succeeds when wave flow, pathing, targeting, and round logic are reliable and readable.
