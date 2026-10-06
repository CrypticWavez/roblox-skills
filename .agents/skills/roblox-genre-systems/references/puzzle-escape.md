# Playbook: Puzzles, escape rooms and scavenger hunts

Kind: genre
Covers: Puzzle > Escape Room; Puzzle > Match & Merge; Puzzle > Word; Adventure > Scavenger Hunt
Also: Survival > Escape

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no puzzles, words, setting, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Room puzzles** (escape room): interactable objects, clues, locks and codes, inventory items combined or used; solving opens the next room before a timer runs out.
- **Board puzzles** (match and merge): a grid of pieces, moves that match or merge, cascades, goals per level, limited moves or time.
- **Word puzzles**: letters or words entered, checked against a word list, scored, often timed or competitive.
- **Scavenger hunts**: hidden finds across a map, clue chains, a found-set that persists.
- **Hints**: tiered hints on a timer or a currency (TBD).
- **Progress**: levels, rooms or sets completed; stars or times; boards.

## Kit modules
- `GameKit/Fsm`: puzzle and room states (locked, solved, open) as serialisable state.
- `GameKit/Interact`, `GameKit/InteractRoblox`, `GameKit/Zones`: interactables, find points, room triggers.
- `GameKit/Inventory`, `GameKit/ItemDefs`: carried clues and key items.
- `GameKit/Objectives`: level and hunt goals, found-sets.
- `GameKit/RoundLoop`: timed escape runs with teams.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4): best times and scores.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): words players enter that others see.
- `GameKit/PlayerData`: level progress and found-sets.
- `ProcGen/Rng`: seeded boards and shuffles (same seed, same board).
- `ProcGen/Dungeon`: seeded room graphs for escape runs.
- `UIKit/Components/Grid`, `UIKit/Components/Tooltip`, `UIKit/Components/Timer`: boards, hints, timers.
- `Feel/Popups`, `AVKit/AudioCues`: solve feedback.

## Data to author
- Puzzle definitions: state, valid actions, solution check, hint tiers (TBD).
- Board rules: grid size, piece set, match or merge rules, goals per level, move limits (TBD).
- Word list and scoring rules; a block list for words never shown (TBD).
- Hunt data: find points, clue text, order rules (TBD).
- Room sequence: authored or seeded, timer per room (TBD).

## Authority and abuse risks
- **Solution leaks**: never send the solution to the client before it is solved; check answers on the server.
- **Brute force**: rate-limit answer attempts per player (`GameKit/RateLimit`).
- **Board state**: the server owns the board and applies moves; the client sends moves, not results.
- **Find spoofing**: a find counts only when the server sees the player near the find point.
- **Shared rooms**: one player's solve updates the room for the team; actions by non-members are refused.

## Performance pitfalls
- Cascades on large boards animated per piece on the server: compute on the server, animate on the client.
- Word lists in a replicated module: large lists cost memory on every client; check words on the server.
- Many interactable prompts in one room: show prompts only near the player.

## Policy notes
- Words players type and others see must be filtered; a word list may still contain words that the filter blocks in some contexts.
- Hints sold for Robux are developer products; hint randomness bought with Robux would fall under the paid random items rules.
- Fear levels in escape rooms go into the Maturity & Compliance questionnaire.

## Test checklist
- [ ] Every authored or seeded puzzle is solvable (a solver or a recorded solution replays to the solved state).
- [ ] Same seed gives the same board; a board with no valid move is detected and reshuffled (board puzzles).
- [ ] Answers are checked on the server; the client never holds the solution before solving.
- [ ] Answer attempts above the rate limit are refused.
- [ ] Found-sets and level progress persist across rejoin.
- [ ] Player-entered words pass the filter path before others see them.
- [ ] Room graphs from `ProcGen/Dungeon` pass connectivity and reachability checks.

## Design questions (TBD)
- TBD: Room puzzles, board puzzles, word puzzles, finds, or a mix?
- TBD: Solo, co-op or competitive?
- TBD: Authored puzzles or seeded generation?
- TBD: Are hints free, timed or paid?
- TBD: Is there a timer, and what happens when it runs out?

## Reference systems
- Developer module Scavenger Hunt as a read-only reference ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Text filtering rules in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1d.
- Fixture `dungeon` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); systems X06, X22 and X24 in the genre coverage research.
