# Core loop

Status: TBD

Prompts only. Replace each prompt with the game's answer, decided from the game-build request or by the
owner, then set `Status:` to `draft` or `agreed` (the concept stage's file gate reads it). Log each
decision in `docs/decisions.md` and mirror brief fields in `production/brief.json`.

## The loop in one sentence
> Prompt: What does a player do again and again, and why do they want to do it once more?

## Moment to moment (seconds)
> Prompt: Verbs, inputs (Input Action System actions) and the feedback for each. What feels good about doing it?

## Session (minutes)
> Prompt: How does a session start, build and end? What is the target session length (brief `session_minutes`)?

## Long term (days)
> Prompt: What brings a player back tomorrow? Which goal is visible from the first session?

## Failure and retry
> Prompt: How can a player fail, what do they lose, and how fast can they try again?

## Social
> Prompt: What do players do with or against each other? What works solo? Players per server (brief `players_per_server`)?

## First five minutes
> Prompt: The onboarding steps in order. They become the onboarding funnel in `src/shared/telemetry.json` (release check A08).

## Systems needed
> Prompt: Which kit modules (starter.json `modules`, skill roblox-genre-systems) cover the loop, and what is new code?

## Open questions
> Prompt: What is still unknown, and which playtest answers it?
