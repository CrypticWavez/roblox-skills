---

name: roblox-obby-checkpoint-and-flow-pass

description: Audits and improves obby progression, checkpoints, stage flow, respawn logic, hazard readability, fail-state recovery, and mobile/controller usability.

---



\# Roblox Obby Checkpoint and Flow Pass



\## Purpose

Use this skill for obstacle course and platforming games where progression flow, checkpoints, hazards, and respawn logic matter.



This skill focuses on:

\- checkpoints

\- stage progression

\- respawn logic

\- hazard readability

\- fail-state recovery

\- input friction

\- progression UI

\- fairness and readability



\## When to use

Use this skill when the user wants to:

\- build or improve an obby

\- fix checkpoints

\- fix respawn flow

\- improve hazard readability

\- make progression smoother



\## Core behavior

Audit:

\- checkpoint system

\- stage progression state

\- respawn behavior

\- hazard and kill-part behavior

\- recovery after failure

\- UI and stage indicators

\- mobile/controller friction if relevant



Then fix and smooth the player journey.



\## Quality standards

An obby should be:

\- readable

\- fair

\- not frustrating for broken-system reasons

\- clear in progression

\- safe in checkpoint persistence

\- smooth to retry



\## Required checks

Validate:

\- checkpoint activation

\- respawn to latest checkpoint

\- stage progression

\- death/reset flow

\- no checkpoint skipping through broken logic

\- no lost progress through broken save state if persistence exists

\- readable hazard telegraphing



\## Execution flow

\### Pass 1: Audit

\- identify progression/respawn pain points



\### Pass 2: Functional fixes

\- fix checkpoint and respawn logic

\- fix stage flow

\- fix progress save issues if present



\### Pass 3: UX polish

\- improve clarity and retry flow

\- improve stage readability



\### Pass 4: Final validation

\- retest stage progression and fail-state recovery



\## Success condition

This skill succeeds when the obby flow is smooth, readable, and checkpoint progression is reliable.

