# Playbook: Story and chapter-based adventures

Kind: genre
Covers: Adventure > Story
Also: Adventure > Exploration; Adventure > Scavenger Hunt; Survival > Escape

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no story, characters, setting, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Chapters**: an ordered sequence of authored levels, each with objectives, set pieces and an ending.
- **Narrative delivery**: cutscenes, dialogue, subtitles, environmental storytelling.
- **Objectives**: find, use, reach, survive, solve; tracked and shown.
- **Party play**: a group plays a chapter together; late joiners and leavers are handled.
- **Checkpoints and failure**: restart from a checkpoint within a chapter.
- **Replay value**: endings, collectables, chapter select, timed runs.

## Kit modules
- `Cinematics/Cinematics`, `Cinematics/Spline`, `Cinematics/CinematicsRoblox`: cinematics/1 camera tracks with events, skippable.
- `GameKit/Dialogue` (dialogue/1), `UIKit/Components/DialogueBox`: conversations and subtitles.
- `GameKit/Objectives`: chapter objectives and collectables.
- `GameKit/Checkpoints`: respawn points within a chapter.
- `GameKit/Fsm`: chapter and set-piece state machines with serialisable state.
- `GameKit/Interact`, `GameKit/Zones`: story triggers and interactables.
- `GameKit/NavAgent`, `GameKit/BehaviorTree`, `GameKit/Perception`: scripted and reactive NPCs.
- `GameKit/TeleportRoblox` (T4), `GameKit/PartyRoblox`: moving a party between chapter places.
- `AVKit/AudioDirector`, `AVKit/AudioCues`: music states and stingers.
- `SceneKit/Lighting`, `GameKit/WorldCycle`: mood per scene.
- `UIKit/Localize`: subtitles and UI text as localisation keys.

## Data to author
- Chapter list: order, places, objectives, checkpoints, endings (TBD).
- Cutscene tracks (cinematics/1) and dialogue trees (dialogue/1) (TBD).
- Trigger map: zone or objective events to cutscenes, audio and lighting cues (TBD).
- Subtitle and UI text as localisation keys (TBD).
- Party rules: size, late join, what happens on leave (TBD).

## Authority and abuse risks
- **Chapter skipping**: chapter unlocks are server-side and saved; a client cannot load a later chapter it has not reached.
- **Objective spoofing**: progress counts from server events.
- **Cutscene desync in parties**: the server starts sequences; each client can skip its own view without changing shared state.
- **Teleport payloads**: data carried between places is validated on arrival (T4 for real teleports).

## Performance pitfalls
- Set pieces with many moving parts: animate on clients from a server start time.
- Large authored levels: stream by area and keep the current chapter's assets only.
- Long audio files: within the audio size limits, `AutoLoad` off for cues outside the current scene.

## Policy notes
- Fear, violence and sensitive themes go into the Maturity & Compliance questionnaire.
- Localised and generated text must still pass text filtering when it comes from players.
- Story beats that ask players for personal information are not allowed (Community Standards).

## Test checklist
- [ ] Every chapter can be completed from every checkpoint (scripted run or recorded route).
- [ ] Chapter unlocks persist and cannot be forced by a client.
- [ ] Each cutscene can be skipped, replays correctly, and respects reduced-motion settings.
- [ ] Dialogue trees validate: every option reaches a node or an end.
- [ ] A party member leaving mid-chapter does not block objectives for the rest.
- [ ] Subtitles exist for every voiced or important audio line (localisation keys present).

## Design questions (TBD)
- TBD: How many chapters, and released all at once or over time?
- TBD: Solo, party or both?
- TBD: One place with all chapters or one place per chapter?
- TBD: Are there multiple endings or choices that matter?
- TBD: What carries over between chapters?

## Reference systems
- Roblox "The Mystery of Duvall Drive" supporting systems and the "Concert" template's event sequencing as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Cinematics design in the [UI, cinematics and feel research](../../../../docs/research/ui-cinematics-feel-2026-10.md).
- Systems X06, X07, X24 and X32 in the genre coverage research.
