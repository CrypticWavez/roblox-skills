# Playbook: Ranked play and leaderboards (cross-cutting)

Kind: cross-cutting
Also: Action > Battlegrounds & Fighting; Shooter > Deathmatch Shooter; Sports & Racing > Racing

A neutral systems reference for any genre that ranks players: it maps ratings, ranked results and boards to kit modules, risks and checks. It picks no rating formula, tiers or rewards; every TBD belongs to the game's owner.

## Core loop as systems
- **Score source**: a server-measured result (time, points, wins, rating change).
- **Ranking**: order by score with defined tie-breaks (earlier submission, then key); standard, dense or ordinal ranks.
- **Persistent boards**: all-time or seasonal, stored in an ordered data store, read in pages.
- **Live boards**: short-lived boards (this hour, this event) in a MemoryStore sorted map with expiry.
- **Ranked mode**: placement matches, rating updates, tiers, decay, seasons (TBD).
- **Presentation**: top lists, the player's own rank, post-match changes.

## Kit modules
- `GameKit/Leaderboard`: pure ranking, tie-breaks, rank styles, score validation (finite, integer, in range), pack and unpack of score plus time.
- `GameKit/LeaderboardRoblox` (T4): OrderedDataStore boards with `GameKit/Retry`; writes are off unless enabled and keep only the better score.
- `GameKit/LiveBoard`, `GameKit/LiveBoardRoblox` (T4): MemoryStore sorted-map boards with expiry and range reads.
- `GameKit/TeamBalance`: balanced teams from ratings.
- `GameKit/RoundLoop`: the match result that feeds the rating.
- `GameKit/SeasonTrack`: season boundaries and season rewards.
- `UIKit/Components/LeaderboardPanel`: board display.
- `GameKit/Telemetry`: result and rating events.

## Data to author
- Board specs: name, direction (higher or lower is better), score bounds, time horizon for tie-breaks, page size (TBD).
- Rating model: formula, starting value, placement rules, decay (TBD).
- Tiers: thresholds and names as labels (TBD).
- Season calendar: UTC start and end, reset rule (TBD).

## Authority and abuse risks
- **Score injection**: only the server submits scores, computed from server state; a client never sends its own score.
- **Duplicate grants**: one rating update per finished match, keyed by match id.
- **Aborted matches**: no rating change (or a defined penalty) when a match is cancelled.
- **Win trading and smurfing**: detect repeated pairings and new accounts at high skill (TBD policy).
- **Boards on non-finite numbers**: `Leaderboard.scoreProblem` refuses NaN, infinities, fractions and out-of-range values before any write.

## Performance pitfalls
- Writing every score change: DataStore budgets are per server per minute; write on improvement and at most at a fixed rate.
- Reading the full board for each player: read the top page once per interval and cache it.
- MemoryStore range reads have limits per call; page large ranges.

## Policy notes
- Boards and ranks only show Roblox names; any player-chosen title is filtered.
- Prizes for ranks must not be Robux or real-value (Community Standards: no Robux or real-value contests).
- Persistent leaderboards registered in Creator Hub are in beta with one active persistent leaderboard per experience (genre coverage research, section 5).
- DataStores and MemoryStore need a published place for real behaviour: T4 here.

## Test checklist
- [ ] Rank styles and ties: equal scores order by submission time then key (`tests/gamekit_world_leaderboard.spec.luau`).
- [ ] NaN, infinite, fractional and out-of-range scores are refused with reasons.
- [ ] A worse score never replaces a better one (fake ordered store).
- [ ] Writes are refused with `writes_disabled` unless explicitly enabled.
- [ ] Live board entries expire at their time-to-live (fake sorted map with a clock).
- [ ] One rating change per match id, none for an aborted match.
- [ ] Board UI handles empty, delayed and failed reads.

## Design questions (TBD)
- TBD: Which boards exist: all-time, seasonal, live, per mode?
- TBD: Is there a ranked mode separate from casual play?
- TBD: Which rating model, and is it shown to players?
- TBD: Do seasons reset ratings fully or partially?
- TBD: What, if anything, do ranks reward?

## Reference systems
- OrderedDataStore, persistent leaderboards and MemoryStore sorted maps in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md), section 5; DataStore limits in the [gameplay libraries research](../../../../docs/research/gameplay-libraries-2026-10.md), section 3.
- Fakes: `tests/fakes/FakeOrderedStore.luau`, `tests/fakes/FakeLiveSortedMap.luau`.
- System X19 in the genre coverage research.
