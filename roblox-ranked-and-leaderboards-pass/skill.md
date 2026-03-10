---

name: roblox-ranked-and-leaderboards-pass

description: Audits and improves ranked progression, rating changes, placements, stat integrity, and leaderboard surfaces for Roblox games with competitive progression.

---



\# Roblox Ranked and Leaderboards Pass



\## Purpose

Use this skill when a Roblox game has or needs competitive progression, visible rank tiers, MMR/rating logic, ranked results, or leaderboard surfaces.



This skill focuses on:

\- ranked queues

\- rating gain/loss logic

\- placement/calibration systems

\- rank tier presentation

\- match result processing

\- leaderboard integration

\- rank/stat integrity

\- anti-abuse protections

\- post-match rank feedback



\## When to use

Use this skill when the user asks to:

\- add ranked mode

\- fix rank updates

\- improve leaderboard UI

\- stabilize MMR logic

\- harden stat integrity

\- improve competitive progression



\## Core behavior

Start by auditing:

\- ranked services and configs

\- rating or MMR calculations

\- rank tiers

\- match-end reward/result processing

\- leaderboard write/read logic

\- ranked UI surfaces

\- stats persistence

\- anti-abuse protections around ranked rewards



Then fix root causes and improve clarity.



\## Quality standards

Ranked systems should be:

\- fair

\- authoritative

\- resistant to duplicate processing

\- understandable to players

\- visually clear

\- safe for production persistence



\## Required checks

Validate:

\- placement match flow if present

\- ranked queue entry rules

\- post-match rating change

\- win/loss processing

\- team result handling

\- no duplicate ranked grants

\- no invalid rank changes on aborted matches

\- rank tier display correctness

\- leaderboard update correctness

\- profile/rank screen correctness

\- fallback handling when leaderboard data is delayed or unavailable



\## Execution flow

\### Pass 1: Audit

\- identify ranking logic and UI gaps

\- identify integrity risks



\### Pass 2: Integrity fixes

\- fix rating calculations

\- fix result application

\- fix duplicate or invalid writes

\- fix tier display and thresholds



\### Pass 3: UI and clarity

\- improve rank feedback

\- improve leaderboard surfaces

\- improve post-match result clarity



\### Pass 4: Final validation

\- retest ranked flow and leaderboard integrity



\## Output expectations

Summarize:

\- files modified

\- ranked/leaderboard issues fixed

\- integrity hardening added

\- remaining risks if any



\## Success condition

This skill succeeds when ranked progression and leaderboards are coherent, persistent, fair, and resistant to obvious abuse or processing errors.

