<!-- Legacy checklist from roblox-tycoon-economy-and-rebirth-pass (original repo root), cleaned of escaped Markdown. -->

name: roblox-tycoon-economy-and-rebirth-pass

# Roblox Tycoon Economy and Rebirth Pass

## Purpose

Use this skill for Roblox tycoon games with earn-spend-upgrade loops, generators, unlock chains, and optional rebirth/prestige systems.

This skill focuses on:

- economy balance
- generator logic
- claim/ownership logic
- unlock flow
- upgrade chains
- rebirth/prestige
- anti-duplication protections
- persistence and integrity

## When to use

Use this skill when the user wants to:

- build or improve a tycoon
- fix rebirth logic
- fix money generation
- improve pacing
- harden ownership and reward logic

## Core behavior

Audit:

- tycoon ownership logic
- generators/droppers/conveyors or equivalent systems
- upgrade purchase logic
- currency generation
- rebirth/prestige logic
- save/load and unlock integrity
- UI surfaces for progression

Then fix root causes and improve progression quality.

## Quality standards

Tycoon progression should be:

- satisfying
- paced well
- authoritative
- resistant to duplication
- easy to understand
- safe to save/load

## Required checks

Validate:

- claim tycoon
- purchase upgrade
- unlock flow
- generator income
- currency spend
- rebirth/prestige rewards
- no double claim
- no duplicate income/reward abuse
- persistence of upgrades and rebirth state

## Execution flow

### Pass 1: Audit

- identify economy logic and exploit gaps

### Pass 2: Integrity fixes

- fix ownership and currency logic
- fix generator and upgrade bugs
- fix rebirth/prestige edge cases

### Pass 3: Pacing and polish

- improve clarity and economy flow
- improve progression surfaces

### Pass 4: Final validation

- retest tycoon lifecycle and persistence

## Success condition

This skill succeeds when the tycoon loop is stable, satisfying, and resistant to obvious economy abuse.
