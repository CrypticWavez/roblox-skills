# Playbook: Music and rhythm games

Kind: genre
Covers: Action > Music & Rhythm
Also: Entertainment > Music & Audio

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no songs, charts, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Chart**: a timed list of notes (lanes, times, holds) authored for a song.
- **Play**: notes approach; the player hits inputs in time; each hit is judged against timing windows.
- **Score**: judgements, combo, accuracy, grade; results per song.
- **Calibration**: audio and input latency offsets per player and device.
- **Progress**: songs unlocked, difficulties, best scores and boards.
- **Multiplayer** (optional): versus or co-op on the same song with synced start.

## Kit modules
- `AVKit/AudioDirector`, `AVKit/AudioGraph`, `AVKit/AudioGraphRoblox`: scheduled playback and the audio graph on the Audio API.
- `GameKit/InputMap`, `GameKit/InputMapRoblox`: lane actions bound for keyboard, gamepad and touch.
- `GameKit/Settings`, `GameKit/SettingsStore`: per-player offset and display settings.
- `GameKit/Fsm`: song states (loading, countdown, playing, results).
- `GameKit/Leaderboard`, `GameKit/LeaderboardRoblox` (T4): per-song boards.
- `GameKit/RoundLoop`: synced multiplayer songs.
- `GameKit/PlayerData`, `GameKit/Progression`: unlocks and best scores.
- `UIKit/Components/ProgressBar`, `UIKit/Components/RollingCounter`, `UIKit/Components/TouchActionButton`: song progress, score, touch lanes.
- `Feel/Popups`, `Feel/Cues`: judgement feedback.

## Data to author
- Song list with rights confirmed by the owner (TBD).
- Charts: note times, lanes, holds, difficulty (TBD).
- Judgement windows, combo and scoring rules (TBD).
- Default offsets per platform and a calibration routine (TBD).

## Authority and abuse risks
- **Score claims**: the client judges for feel, but the server receives timestamped inputs (or a compact replay) and checks them against the chart before accepting a score.
- **Impossible accuracy**: flag runs whose timing distribution is not plausible (TBD rule).
- **Chart tampering**: the server holds the chart used for validation.
- **Board writes**: only server-validated scores, at a bounded rate.

## Performance pitfalls
- Note objects created per note: pool note visuals and draw them in UI, not as world parts.
- Frame timing: judge against the audio clock, not frame counts; frame drops must not shift judgement.
- Audio load: preload the song before the countdown; check `IsReady` with a timeout.

## Policy notes
- Music needs rights the owner holds; uploads are outside this factory (the hooks deny uploads).
- Store videos may not contain music with lyrics (release research, section 1c).
- Flashing visuals respect reduced-motion and safe-flash settings.

## Test checklist
- [ ] Judgement maths: inputs at each window boundary get the expected judgement (pure spec).
- [ ] A recorded input replay validates against its chart; a shifted or altered replay is refused.
- [ ] Offsets from settings apply to judgement and display consistently.
- [ ] Every lane has keyboard, gamepad and touch bindings.
- [ ] Audio-to-visual sync measured in Studio on the diagnostic place (T3; perceived sync is a human sign-off).
- [ ] Multiplayer start is synced from a server time across clients (T3).

## Design questions (TBD)
- TBD: Which input scheme: lanes, positions, or gestures?
- TBD: Where do songs come from, and are their rights confirmed?
- TBD: Solo, versus or co-op?
- TBD: Are charts authored by the owner or by players?
- TBD: How strict are timing windows on touch devices?

## Reference systems
- Audio API objects and the audio graph design in the [visual and audio research](../../../../docs/research/visual-audio-assets-2026-10.md).
- Input Action System facts in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md), section 5.
- Store-video music rule in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1c.
