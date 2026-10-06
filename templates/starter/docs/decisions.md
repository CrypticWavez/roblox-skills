# Decisions

One row per decision: game design (the TBD fields of `production/brief.json` and the `AGENTS.md` tables), engine settings, tools and dependencies adopted (pins from `deps.json`), stage changes in `production/pipeline.json`, and every approval to publish, upload or spend. Newest last. When a brief field is decided, update `production/brief.json` and its `AGENTS.md` row in the same commit (the gate step `brief` checks they agree).

| Date | Decision | Decided by | Source | Notes |
|---|---|---|---|---|
| {{CREATED}} | Repository created from the factory project starter | owner (game-build request) | `starter.json` | Every brief and engine field is TBD; stage concept |
