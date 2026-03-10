---

name: roblox-weapons-and-animations-pass

description: Improves Roblox weapon systems and animation integration, including equip, reload, fire, idle, inspect, hit feedback, animation fallbacks, and presentation quality.

---



\# Roblox Weapons and Animations Pass



\## Purpose

Use this skill when a Roblox game has weapons or animation-driven action that needs better feel, presentation, and reliability.



This skill focuses on:

\- weapon rigs and configs

\- equip/reload/fire state

\- animation playback integration

\- animation fallback handling

\- presentation and feedback

\- first-person or third-person alignment

\- state bugs across respawn/match transitions



\## When to use

Use this skill when the user asks to:

\- polish guns

\- add or fix animations

\- improve weapon presentation

\- fix reload/equip/fire bugs

\- improve first-person feel



\## Core behavior

Audit:

\- weapon modules/configs

\- animation IDs and playback paths

\- state machines for equip/reload/fire/idle

\- weapon presentation hooks

\- death/respawn cleanup

\- camera or viewmodel integration if present



Then fix root causes and improve visual feel.



\## Quality standards

Weapons and animations should be:

\- readable

\- responsive

\- robust to missing assets

\- free of stale states

\- properly cleaned up

\- visually satisfying



\## Required checks

Validate:

\- equip works

\- reload works

\- fire works

\- idle state resets correctly

\- animation transitions are not broken

\- death/respawn resets weapon state

\- animation failures do not break gameplay

\- weapon alignment is acceptable

\- visual feedback supports gameplay clarity



\## Execution flow

\### Pass 1: Audit

\- identify broken animation/weapon state flow

\- identify weak presentation



\### Pass 2: Functional fixes

\- fix playback/state bugs

\- fix cleanup and reset behavior

\- add fallbacks



\### Pass 3: Presentation pass

\- improve transitions

\- improve animation hooks

\- improve feedback and feel



\### Pass 4: Final validation

\- retest weapon lifecycle and animation reliability



\## Output expectations

Summarize:

\- files modified

\- weapon/animation issues fixed

\- fallbacks added

\- presentation improvements made



\## Success condition

This skill succeeds when weapons and animations feel polished, reliable, and resilient to state or asset failures.

