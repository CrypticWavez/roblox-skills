# Playbook: Sports (ball games, team matches)

Kind: genre
Covers: Sports & Racing > Sports

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no sport, teams, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Match**: lobby, team assignment, kickoff or serve, play periods, scoring, end and results.
- **Ball (or object) physics**: possession, passing, shooting, serving, bounces and out of bounds.
- **Player actions**: run, sprint with stamina, jump, dive, tackle or block, aim with power.
- **Rules engine**: fouls, out of bounds, score events, restarts, timeouts.
- **Positions and roles**: optional roles per team (TBD).
- **Progression**: ratings, cosmetics, ranked seasons.

## Kit modules
- `GameKit/RoundLoop`, `GameKit/RoundLoopRoblox`: match periods, restarts and results.
- `GameKit/Fsm`: rule states (in play, dead ball, restart) with state in one attribute.
- `GameKit/TeamBalance`, `GameKit/Queue`: balanced teams that keep parties together; matchmaking.
- `GameKit/Zones`, `GameKit/ZonesRoblox`: goals, bounds, court areas.
- `GameKit/Movement`, `GameKit/Vitals`, `GameKit/Cooldowns`: sprint, stamina, action cooldowns.
- `GameKit/Knockback`: tackles and collisions as impulses.
- `GameKit/InputMap`: aim and power on keyboard, gamepad and touch.
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4): rankings and records.
- `UIKit/Components/Timer`, `UIKit/Components/TouchActionButton`, `UIKit/Components/Toast`: clock, touch actions, score events.
- `Cinematics/Cinematics`, `Feel/Shake`, `AVKit/AudioCues`: goal replays and crowd feedback.
- `SceneKit/Measure`: pitch or court sizes against player reach and jump.

## Data to author
- Field or court dimensions, goals and zones (TBD).
- Ball properties: size, mass, bounce, drag, possession radius (TBD).
- Action definitions: power curves, cooldowns, stamina costs (TBD).
- Rule set: scoring, fouls, restarts, period lengths, overtime (TBD).
- Team sizes and fill rules (TBD).

## Authority and abuse risks
- **Ball ownership**: one authority for the ball at a time; under Server Authority, sports physics is covered by the engine (genre coverage research, section 5); otherwise the server validates possession changes and kicks.
- **Score events**: goals and points are detected on the server from ball state and zones.
- **Speed and reach**: action range and power are bounded on the server.
- **Team switching and leaving**: rules for mid-match switches and leavers (TBD); rewards computed at the end on the server.

## Performance pitfalls
- Ball network ownership flipping between clients causes jitter; keep one owner and predict on others.
- High-rate remotes for aiming: send the action and its parameters once, not per frame.
- Crowd and stadium detail: impostors or low-detail crowds; budget stadium parts.

## Policy notes
- Real leagues, teams, players and logos are intellectual property; IP takedowns are a Community Standards item.
- Tournaments or ranks cannot award Robux or real-value prizes (Community Standards).
- Contact actions (tackles) count towards the violence answers in the Maturity & Compliance questionnaire.

## Test checklist
- [ ] Rule state machine: every restart path reaches play again; no dead ends (`GameKit/Fsm` validate).
- [ ] Goals and out-of-bounds detected on the server for fast balls between steps.
- [ ] Teams: sizes within the limit, parties together, deterministic for a fixed seed.
- [ ] Forged kick or possession remotes are refused (range, cooldown, possession).
- [ ] Server & Clients test with latency: possession changes look consistent on every client (T3).
- [ ] Every action has keyboard, gamepad and touch bindings.

## Design questions (TBD)
- TBD: Which sport or ball game, and how close to its real rules?
- TBD: Team sizes and match length?
- TBD: Are there positions or roles?
- TBD: Ranked play and seasons?
- TBD: How are fouls and contact handled?

## Reference systems
- Server Authority covers sports physics ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5); Roblox template "Team/FFA Arena" as a read-only reference.
- Systems X01, X16, X19 and X21 in the genre coverage research.
- Skill `roblox-multiplayer-integrity` for ownership and latency tests.
