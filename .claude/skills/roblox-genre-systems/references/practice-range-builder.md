<!-- Legacy checklist from roblox-practice-range-builder (original repo root), cleaned of escaped Markdown. -->

name: roblox-practice-range-builder

# Roblox Practice Range Builder

## Purpose

Use this skill when a game benefits from a warm-up space, weapon test zone, aim trainer, or low-pressure practice mode.

This skill focuses on:

- target lanes
- moving and static targets
- drill logic
- timing/accuracy readouts
- clean entry/exit flow
- weapon preview/testing
- low-friction UX

## When to use

Use this skill when the user wants:

- a practice range
- aim training
- weapon sandboxing
- warm-up area
- onboarding through practice

## Core behavior

Audit:

- current training/practice mode if it exists
- weapon test hooks
- UI surfaces for drill stats
- target logic
- mode entry/exit flow

Then build or improve a coherent training feature.

## Quality standards

Practice mode should be:

- easy to enter and leave
- immediately usable
- free of unnecessary friction
- useful for testing and warm-up
- visually clear
- isolated from ranked or reward abuse

## Required checks

Validate:

- range entry works
- range exit works
- static targets work
- moving targets work if supported
- drill timers and counters work
- stat feedback is readable
- no ranked/progression exploits are introduced through practice flow
- weapon swap/test flow is clean

## Execution flow

### Pass 1: Audit

- inspect current practice flow or lack of it
- identify best integration path

### Pass 2: Core implementation

- build targets/drills/UI
- wire entry/exit
- isolate progression/reward side effects as needed

### Pass 3: Polish

- improve readability
- improve atmosphere and usability
- improve drill feedback

### Pass 4: Final validation

- retest practice flow end to end

## Output expectations

Summarize:

- files created/modified
- training features added or improved
- abuse protections added
- remaining gaps if any

## Success condition

This skill succeeds when the game has a clean, useful, and non-abusive practice experience.
