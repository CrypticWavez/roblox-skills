# {{NAME}}

Roblox game repository created by the factory project starter. Agents and people start with `AGENTS.md`. What the game is lives in `production/brief.json` (every field TBD until the owner or the game-build request decides it); decisions are logged in `docs/decisions.md`.

```
rokit install                                   # rojo, lune, stylua, selene, luau-lsp at the factory's pins
python3 tools/check.py                          # the gate: format, JSON, secrets, skills, brief, deps, assets, hooks, Selene, Lune specs, Rojo build
python3 tools/production.py status              # current stage and its exit gates
python3 tools/plan_issues.py                    # issue drafts for the current stage (no API calls)
python3 tools/release_check.py                  # release readiness: automated A-items; S/O/P items stay with the owner
rojo serve default.project.json                 # live sync into an unpublished test place
```

Layout: `src/server` boots the server phases, `src/client` the client phases, `src/shared` holds the boot runner, the config and shared code, `src/first` the loading screen, `src/gui` StarterGui, `src/assets` server-side assets, `src/localization` the localisation tables. Factory packages sit in `factory/` (see `AGENTS.md`; never `packages/`, which `wally install` deletes on Windows and macOS). Publishing is done by the owner from Studio, never by an agent or CI.
