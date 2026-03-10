---

name: roblox-release-regression-pass

description: Performs a focused regression pass on a Roblox repo after major changes, retesting critical flows, catching reintroduced bugs, and stabilizing the game before release.

---



\# Roblox Release Regression Pass



\## Purpose

Use this skill after major feature work, refactors, or polish passes to ensure critical player flows have not regressed.



This skill focuses on:

\- end-to-end regression testing

\- critical flow validation

\- bug reintroduction detection

\- ship blocker detection

\- focused final fixes



\## When to use

Use this skill when the user wants to:

\- do a final verification pass

\- ensure nothing broke

\- catch regressions before publish

\- stabilize after many changes



\## Core behavior

Audit:

\- what changed recently

\- what major systems are high risk

\- what player-facing flows must still work

\- what known fragile areas exist



Then retest and repair regressions.



\## Quality standards

Regression passes should:

\- prioritize critical loops

\- catch reintroduced bugs quickly

\- focus on real player-impacting flows

\- avoid unnecessary broad rewrites



\## Required checks

Retest:

\- title -> lobby -> match or equivalent loop

\- save/load and rewards

\- UI navigation

\- major gameplay systems

\- party/matchmaking if applicable

\- ranked/progression if applicable

\- cleanup/return flows

\- recently modified systems



\## Execution flow

\### Pass 1: Audit

\- identify likely regressions



\### Pass 2: Regression testing

\- retest critical flows

\- reproduce issues

\- prioritize fixes



\### Pass 3: Repair and retest

\- fix regressions

\- revalidate affected flows



\## Success condition

This skill succeeds when major player-facing regressions are removed and release confidence is restored.

