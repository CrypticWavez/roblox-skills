# Playbook: Board and card games (turn-based strategy)

Kind: genre
Covers: Strategy > Board & Card Games
Also: Puzzle > Match & Merge; RPG > Turn-based RPG

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no game, cards, rules, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Table**: players sit at a table (2 or more), host or matchmaking fills seats, spectators watch.
- **Game state**: a board, decks, hands, piles and scores as data; one authoritative state.
- **Turns**: whose turn it is, legal moves, timers, passes and timeouts.
- **Hidden information**: hands and decks hidden from other players; reveals by rule.
- **Randomness**: shuffles and dice from a seeded server RNG.
- **End and results**: win conditions, ratings, rematches.
- **Collection** (deck builders): owned cards, deck building, unlocks.

## Kit modules
- `GameKit/Fsm`: turn phases and game states; `Fsm:serialize()` keeps the state in one attribute.
- `ProcGen/Rng`: seeded shuffles and rolls (same seed, same order) for replays and tests.
- `GameKit/RoundLoop`, `GameKit/Queue`, `GameKit/TeamBalance`: tables, matchmaking, team games.
- `GameKit/Inventory`, `GameKit/ItemDefs`: owned cards or pieces for collection games.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4): ratings and records.
- `GameKit/PlayerData`: saved collections, decks and unfinished games (TBD).
- `GameKit/RemoteGuard`, `GameKit/RateLimit`: validated move requests.
- `GameKit/BehaviorTree`: AI opponents with a per-tick budget.
- `UIKit/Components/Grid`, `UIKit/Components/Card`, `UIKit/Components/Timer`: board, cards, turn timer.
- `Feel/Spring`, `AVKit/AudioCues`: card and piece motion and sounds.

## Data to author
- Rules: setup, legal moves per phase, scoring, end conditions (TBD).
- Card or piece definitions and deck lists (TBD).
- Turn timer and timeout rule (TBD).
- AI difficulty levels as behaviour data (TBD).
- Seat counts and spectator rules (TBD).

## Authority and abuse risks
- **Hidden information**: never replicate other players' hands or deck order to a client; send each player only their view.
- **Illegal moves**: the server validates every move against the rules and the current phase.
- **Out-of-turn actions**: refused with a reason.
- **RNG manipulation**: shuffles happen on the server with a server seed; the seed is not revealed until the game ends (if ever).
- **Stalling**: turn timers and timeout rules; leavers handled by rule (forfeit, AI takeover).

## Performance pitfalls
- Sending the full state every move: send moves and per-player view deltas.
- Physics for cards and pieces: keep them anchored and animate on the client.
- Many tables in one server: one state machine per table, ticked by events, not per frame.

## Policy notes
- No simulated gambling: wagering currency on outcomes, especially purchasable currency, is not allowed (Community Standards); "unplayable gambling" is a questionnaire category.
- Card packs bought with Robux follow the paid random items rules; trading pack results checks `IsPaidItemTradingAllowed`.
- Real-world card games and board games may be intellectual property (IP takedowns).

## Test checklist
- [ ] Rules engine: every legal move is accepted and a set of illegal moves is refused, per phase.
- [ ] A client's view never contains another player's hidden cards (inspect every payload in a spec).
- [ ] Same seed gives the same shuffle; replaying recorded moves reproduces the final state.
- [ ] Timeouts and leavers resolve by rule without blocking the table.
- [ ] AI opponents only make legal moves and finish within the tick budget.
- [ ] Odds for paid packs sum to exactly 100% (`GameKit/OddsTable`).

## Design questions (TBD)
- TBD: Which game or rule set, and is it original?
- TBD: Real-time turns with timers or asynchronous play?
- TBD: Fixed components or collected decks?
- TBD: AI opponents, and at which difficulties?
- TBD: Ranked play?

## Reference systems
- Turn-based multiplayer notifications were announced for Studio beta (RDC 2026, [genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5; REVISIT when released).
- Fsm and Rng contracts in [runtime-kits.md](../../../../docs/runtime-kits.md), sections 4 and 12.
- Systems X01, X04 and X19 in the genre coverage research.
