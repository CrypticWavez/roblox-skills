<!-- Legacy checklist from roblox-mobile-and-controller-ux-pass (original repo root), cleaned of escaped Markdown. -->

name: roblox-mobile-and-controller-ux-pass

# Roblox Mobile and Controller UX Pass

## Purpose

Use this skill when a game supports or may support mobile and controller users and needs better usability across non-keyboard input methods.

This skill focuses on:

- input mapping
- controller focus flow
- touch interaction flow
- HUD readability
- button sizing/placement
- menu navigation
- safe-zone issues
- platform-specific friction

## When to use

Use this skill when the user asks to:

- improve controller support
- improve mobile UX
- make menus work better on console/mobile
- reduce input friction across platforms

## Core behavior

Audit:

- input handling
- UI navigation
- interact prompts
- HUD and screen density
- menu focus flow
- touch hitbox size and placement
- platform-specific assumptions

Then improve the most painful usability issues first.

## Quality standards

Cross-platform UX should be:

- readable
- reachable
- predictable
- not dependent on tiny click targets
- free of navigation dead ends
- appropriate for supported devices

## Required checks

Validate:

- controller can navigate key menus if controller is supported
- touch users can activate primary UI reliably if mobile is supported
- no tiny essential controls block progress
- HUD remains readable on smaller screens
- no hidden keyboard-only assumptions block core play

## Execution flow

### Pass 1: Audit

- identify biggest input and layout pain points

### Pass 2: Functional fixes

- improve navigation
- improve button sizes/placement
- improve prompts and focus

### Pass 3: Final UX polish

- improve clarity
- improve consistency
- retest main platform-critical flows

## Output expectations

Summarize:

- files modified
- input/UX issues fixed
- remaining platform limitations if any

## Success condition

This skill succeeds when supported non-keyboard input methods no longer feel neglected or broken.
