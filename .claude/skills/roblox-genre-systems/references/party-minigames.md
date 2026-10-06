# Playbook: Party and casual (minigames, childhood games, quizzes)

Kind: genre
Covers: Party & Casual > Minigame; Party & Casual > Childhood Game; Party & Casual > Quiz
Also: Party & Casual > Coloring & Drawing; Education > (none); Puzzle > Word

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no games, questions, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Rotation**: a lobby picks the next short game (vote, random or fixed order), plays it, scores it, repeats.
- **Minigames**: small rule sets on small arenas (last one standing, race to a goal, collect the most, avoid hazards).
- **Childhood games**: playground rules (tag, hide and seek, follow the leader, red light green light) with roles and simple win checks.
- **Quiz**: timed questions, answers locked in, scored by correctness and speed, results per round.
- **Session score**: points across rounds, winners per session, light rewards.
- **Drop-in**: players join mid-session as spectators or into the next round.

## Kit modules
- `GameKit/RoundLoop`, `GameKit/RoundLoopRoblox`: rotation, intermission, round, results.
- `GameKit/Fsm`: per-minigame rule states (setup, play, end) with serialisable state.
- `GameKit/TeamBalance`: fair teams and role picks (tagger, seeker) with parties kept together.
- `GameKit/VotingRound`: map or minigame votes with tie breaks.
- `GameKit/Zones`, `GameKit/Interact`: goals, hazards, tag range, hiding spots.
- `GameKit/Perception`: hide-and-seek visibility checks when an AI or rule needs them.
- `GameKit/Leaderboard`, `GameKit/LiveBoard`: session and live boards.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): typed answers or names that others see.
- `ProcGen/Course`: `Course.microArena` gives small arenas with fair spawns, hazard rings and cover; `Validate.course` checks spawn separation, symmetry, fairness and clearance.
- `UIKit/Components/Countdown`, `UIKit/Components/Toast`, `UIKit/Components/LeaderboardPanel`: round timer, events, results.
- `Cinematics/Cinematics`, `Feel/Cues`: round intros and winner moments.

## Data to author
- Minigame list: rules per game (players, duration, win condition, arena kind) (TBD).
- Arena parameters per minigame: seed, size, players, hazard and cover options (TBD).
- Question bank: questions, answers, categories, difficulty, time limit (TBD).
- Scoring: points per placement, speed bonus, session totals (TBD).
- Rotation rule: vote, random without repeats, or fixed (TBD).

## Authority and abuse risks
- **Tags and eliminations**: decided on the server from positions and ranges.
- **Quiz answers**: the correct answer is never sent to clients before the answer window closes; answers after the window are refused.
- **Vote stuffing**: one vote per player per ballot, server tally.
- **AFK and griefing**: idle players move to spectators; rules for players who block others (TBD).
- **Mid-round joins**: joiners wait for the next round unless the rules allow drop-in.

## Performance pitfalls
- Building each arena from scratch per round: prebuild or pool arenas; clean up with `GameKit/Scope` between rounds.
- Many short-lived effects at round end: pool them.
- Question banks in a replicated module: keep answers on the server.

## Policy notes
- Typed quiz answers or player names that others see must be filtered.
- Prizes cannot be Robux or real-value (Community Standards); no simulated gambling in score bets.
- Childhood-game rules with physical contact or fear elements still count towards questionnaire answers.

## Test checklist
- [ ] Every minigame's rule machine ends in a result from every state (no stuck rounds), including when players leave.
- [ ] Generated micro-arenas pass `Validate.course` (`spawn_separation`, `spawn_symmetry`, `spawn_clear`, `spawn_fairness`, `piece_overlap`).
- [ ] Quiz: answers after the window are refused; the correct answer is absent from client payloads before it closes.
- [ ] Team and role picks are deterministic for a fixed seed and keep parties together.
- [ ] Rotation never repeats a game earlier than the rule allows.
- [ ] Drop-in players are placed per the rule and never inherit a running round's state.

## Design questions (TBD)
- TBD: How many minigames, and how are they chosen each round?
- TBD: Individual, team, or mixed scoring?
- TBD: Quizzes: whose questions, which topics, and are answers typed or chosen?
- TBD: What happens to eliminated players during a round?
- TBD: Do session results carry over between visits?

## Reference systems
- Fixture `course_micro_arena` in [build_fixtures.luau](../../../../tools/lune/build_fixtures.luau); arena checks in `tests/procgen_course.spec.luau`.
- Roblox templates "Team/FFA Arena" and "Line Runner" as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Systems X01, X11, X16 and X19 in the genre coverage research.
