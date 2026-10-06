# Playbook: Parties, queues and matchmaking (cross-cutting)

Kind: cross-cutting
Also: Party & Casual > Minigame; Shooter > Battle Royale; Sports & Racing > Sports; Survival > 1 vs All

A neutral systems reference for any genre with matches: it maps parties, queues, team balance and server hand-off to kit modules, risks and checks. It picks no mode, team size or rules; every TBD belongs to the game's owner.

## Core loop as systems
- **Party**: players group up (Roblox Party API or an in-game party), with a leader, invites, leave and kick.
- **Queue**: a party or a solo player joins a queue for a mode; the queue groups tickets into matches by size, skill and wait time.
- **Team split**: the match assigns teams, keeping parties together and balancing skill.
- **Hand-off**: the match moves to a reserved server (teleport) or starts in place; players who fail to arrive are handled.
- **Return**: after the match, players go back to the lobby with results; queue and party state is cleaned up.
- **Private matches**: invite-only matches with custom settings (TBD).

## Kit modules
- `GameKit/Queue`, `GameKit/MemoryQueueRoblox` (T4): ticket queue core and its cross-server MemoryStore adapter.
- `GameKit/TeamBalance`: deterministic skill- and party-aware split with a size difference limit and swap passes.
- `GameKit/PartyRoblox`: Roblox Party API reads (`Player.PartyId`, party members).
- `GameKit/TeleportRoblox` (T4): reserved servers and teleport with retry; not testable in Studio.
- `GameKit/RoundLoop`, `GameKit/RoundLoopRoblox`: match phases on the match server.
- `GameKit/Fsm`: party and ticket state machines with serialisable state.
- `GameKit/Retry`, `GameKit/RemoteGuard`, `GameKit/RateLimit`: retries on cross-server calls; validated, rate-limited party and queue remotes.
- `UIKit/Components/TeleportTransition`, `UIKit/Components/LoadingScreen`, `UIKit/Components/Modal`: queue status and hand-off screens.

## Data to author
- Modes: team count, team size, fill rules, whether partial parties may join (TBD).
- Queue rules: skill bands, widening over wait time, maximum wait (TBD).
- Team balance options: `maxSizeDiff`, swap rounds, party handling (TBD).
- Hand-off rules: arrival timeout, what happens to no-shows, backfill (TBD).

## Authority and abuse risks
- **Leader actions**: only the leader can queue or kick; the server checks membership on every request.
- **Queue flooding**: rate-limit join and leave per player.
- **Stale tickets**: a ticket for a player who left must be removed before matching (MemoryStore entries expire, but not instantly).
- **Duplicate matches**: a ticket is consumed by exactly one match (atomic remove from the queue).
- **Skill manipulation**: skill values come from server-side ratings, never from the client.

## Performance pitfalls
- Polling MemoryStore too often: queue operations count against MemoryStore quotas, which scale with users; batch and back off with `GameKit/Retry`.
- Teleporting a whole party in separate calls: teleport the group together where the API allows.
- Lobby UI updated on every queue change for every player: send state changes, not periodic full snapshots.

## Policy notes
- Teleports and MemoryStore are T4 here: TeleportService does not run in Studio playtests, and MemoryStore is isolated between Studio and production (genre coverage research, section 5).
- The Party API was simulated in Studio only through the Party Simulator beta (Server & Clients mode); treat party behaviour as unverified until tested there.
- Private-match codes that players type are user text: filter before showing to others.

## Test checklist
- [ ] Party lifecycle: create, invite, join, leave, leader leave with reassignment, kick.
- [ ] Queue: join, cancel, partial party, full party, disconnect while queued; no stranded tickets.
- [ ] Team split: parties stay together, size difference within the limit, same input gives the same teams.
- [ ] A ticket is never placed in two matches (fake queue with concurrent matchers).
- [ ] Hand-off timeout: no-shows are removed and the match still starts or cancels per the rule.
- [ ] Return to lobby leaves no party or queue UI stale.
- [ ] Party Simulator run in Server & Clients mode once a game repo exists (T3); real teleports only in a test universe (T4).

## Design questions (TBD)
- TBD: Which modes exist, with which team sizes?
- TBD: Is skill used for matching, and from which rating?
- TBD: Does the match run on the lobby server or on a reserved server?
- TBD: Are private matches offered, and with which settings?
- TBD: Is backfill allowed for players who leave?

## Reference systems
- Roblox Party API, Party Simulator, MatchmakingService, TeleportService and MemoryStore facts in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md), section 5.
- Roblox templates "Team/FFA Arena" and "Capture the Flag" as read-only references (same research, section 5).
- Slice tests: `tests/gamekit_world_teams.spec.luau`; system X16 in the genre coverage research.
