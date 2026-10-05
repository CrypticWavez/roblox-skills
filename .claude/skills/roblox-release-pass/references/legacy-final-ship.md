<!-- Legacy checklist from roblox-final-ship-pass (original repo root), cleaned of escaped Markdown. -->

# Roblox Final Ship Pass

## Purpose

Use this skill when working in a Roblox Rojo-based repository that already has a mostly built game and now needs a final full completion pass.

This skill is for:

- final debugging
- full-system validation
- UI cleanup
- gameplay polish
- map polish
- multiplayer hardening
- exploit prevention
- error handling and fallbacks
- optimization
- publish-readiness

This skill should behave like a release engineer plus senior Roblox gameplay engineer.

## When to use

Use this skill when the user wants the game:

- fully completed
- tested end to end
- debugged
- polished visually
- hardened against exploits
- ready to publish

Typical requests:

- "finish the game"
- "make it publish ready"
- "do the final pass"
- "fix all bugs and glitches"
- "test and harden everything"
- "make sure the whole game works"

## Core behavior

Always begin by auditing the real repository and current live state before making major changes.

Do not assume systems work because code exists.

First inspect:

- repository structure
- Rojo mappings
- shared modules/configs
- server services/systems
- client controllers/UI
- remotes and authority boundaries
- persistence/profile/reward logic
- match flow
- party flow
- ranked flow
- combat flow
- maps and spawn logic
- UI states and transitions
- live Studio hierarchy through MCP if useful
- runtime output and obvious warnings/errors if available

Then produce a concise execution plan based on the actual current repo state.

Then execute autonomously in iterative passes until no major ship blockers remain.

## Development priorities

Priority order:

1. Critical runtime errors

2. Broken bootstraps and bad requires

3. Broken game loop flow

4. Broken UI states and interactions

5. Multiplayer/state authority issues

6. Persistence/reward integrity issues

7. Exploit-prone remotes and client trust issues

8. Missing fallbacks and brittle failure points

9. Performance issues and cleanup problems

10. Visual polish and presentation quality

11. Final tuning for fun and clarity

- the game is ready for immediate upload
