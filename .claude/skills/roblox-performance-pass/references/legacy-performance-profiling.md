<!-- Legacy checklist from roblox-performance-and-profiling-pass (original repo root), cleaned of escaped Markdown. -->

name: roblox-performance-and-profiling-pass

# Roblox Performance and Profiling Pass

## Purpose

Use this skill when the game needs smoother performance, cleaner object lifecycle handling, or reduced runtime waste.

This skill focuses on:

- hot loops
- duplicate connections
- cleanup issues
- excessive replication
- remote spam
- UI churn
- memory leaks
- match object lifecycle
- practical optimization guided by evidence

## When to use

Use this skill when the user asks to:

- optimize the game
- reduce lag
- improve FPS
- clean up performance
- prepare for release performance

## Core behavior

Audit:

- update loops
- event connections
- replicated state size/frequency
- projectile/effects cleanup
- UI redraw patterns
- match object creation/destruction
- expensive repeated lookups
- per-frame logic
- performance instrumentation if present

Then optimize the highest-value bottlenecks first.

## Quality standards

Optimizations should:

- preserve correctness
- reduce obvious waste
- improve cleanup
- reduce unnecessary network churn
- avoid destabilizing working systems

## Required checks

Validate:

- no leaked connections remain in changed flows
- no object buildup remains in changed flows
- no obvious spam remotes remain in changed flows
- cleanup occurs after rounds/matches/effects
- UI updates are not wastefully repeated
- gameplay correctness remains intact after optimization

## Execution flow

### Pass 1: Audit

- identify hotspots and waste
- identify lifecycle/cleanup problems

### Pass 2: Practical optimizations

- fix loops
- fix cleanup
- fix duplicate connections
- reduce unnecessary replication/UI churn

### Pass 3: Validation

- retest changed systems
- confirm no regressions

## Output expectations

Summarize:

- files modified
- bottlenecks addressed
- cleanup improvements made
- remaining performance risks if any

## Success condition

This skill succeeds when the changed systems are meaningfully leaner, cleaner, and still correct.
