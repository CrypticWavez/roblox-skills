---

name: roblox-party-and-matchmaking-pass

description: Audits and improves Roblox party systems, queue flow, matchmaking, private matches, team assembly, and queue-to-match lifecycle with strong multiplayer state integrity.

---



\# Roblox Party and Matchmaking Pass



\## Purpose

Use this skill when a Roblox game needs robust friend play, party management, queue handling, matchmaking flow, or private match support.



This skill focuses on:

\- party creation and invites

\- party membership state

\- leader controls

\- queue join/leave logic

\- queue state replication

\- matchmaking assembly

\- private match support

\- team balancing and fill logic

\- ready states if relevant

\- match launch and teardown



\## When to use

Use this skill when the user asks to:

\- add or fix party play

\- add matchmaking

\- fix queue bugs

\- fix invite flow

\- support private matches

\- stabilize queue -> match transitions



\## Core behavior

Start by auditing:

\- party services/modules

\- matchmaking services/queues

\- team assignment logic

\- remotes used for party and queue updates

\- UI state related to party and queue flow

\- match launch logic

\- cancellation flow

\- leave/rejoin behavior

\- cleanup behavior



Then plan and implement deterministic fixes.



\## Quality standards

Party and matchmaking systems should be:

\- authoritative

\- easy to understand

\- resilient to leaves and disconnects

\- free of duplicate processing

\- free of stranded queue states

\- cleanly integrated with lobby and match flow



\## Required checks

Validate:

\- create party

\- invite member

\- join party

\- leave party

\- leader leave

\- leader reassignment

\- kick/remove member if supported

\- party ready state if supported

\- queue join

\- queue cancel

\- queue with partial party

\- queue with full party

\- disconnect during queue

\- queue cleanup after match launch

\- private match flow

\- team balancing/fair assignment

\- no stale party UI after transitions



\## Execution flow

\### Pass 1: Audit

\- identify broken party state

\- identify queue state issues

\- identify launch and cleanup issues



\### Pass 2: Functional fixes

\- fix party creation/join/leave

\- fix queue join/cancel

\- fix leader controls

\- fix launch gating and validation



\### Pass 3: Hardening

\- fix disconnect/rejoin edge cases

\- fix duplicate processing

\- fix stale UI and replicated state

\- improve private match handling



\### Pass 4: Final validation

\- retest party and queue lifecycle end to end

\- ensure no major multiplayer blockers remain



\## Output expectations

Summarize:

\- files modified

\- party/matchmaking bugs fixed

\- edge cases hardened

\- remaining blockers if any



\## Success condition

This skill succeeds when parties and matchmaking are reliable, deterministic, and stable across queue, launch, match, and return flows.

