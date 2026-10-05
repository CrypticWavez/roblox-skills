<!-- Legacy checklist from roblox-datastore-migration-pass (original repo root), cleaned of escaped Markdown. -->

name: roblox-datastore-migration-pass

# Roblox DataStore Migration Pass

## Purpose

Use this skill when a Roblox game’s saved data schema has evolved and needs safer version handling or migration support.

This skill focuses on:

- schema versioning
- default profile upgrades
- migration transforms
- backwards compatibility
- corrupted/partial profile handling
- safe fallback behavior

## When to use

Use this skill when the user wants to:

- change save data schema
- add new save fields safely
- migrate old profiles
- fix version upgrade issues
- avoid data loss after updates

## Core behavior

Audit:

- current profile schema
- load path
- default profile template
- version fields
- migration logic if any
- save path and integrity protections

Then add or improve migration flow.

## Quality standards

Migration systems should:

- be explicit
- be safe
- preserve player progress where possible
- avoid silent corruption
- avoid duplication or invalid defaults

## Required checks

Validate:

- old profile upgrade path
- partial profile fallback behavior
- default field injection
- no repeated migration duplication bugs
- safe write-back after migration
- no broken assumptions after migration

## Execution flow

### Pass 1: Audit

- identify schema/version gaps

### Pass 2: Migration implementation

- add versioned migration logic
- add default/fallback handling
- improve safety around upgrade path

### Pass 3: Validation

- retest old/new profile compatibility assumptions

## Success condition

This skill succeeds when evolving profile data can be upgraded safely and predictably.
