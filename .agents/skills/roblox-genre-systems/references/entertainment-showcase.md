# Playbook: Entertainment (music and audio, showcases and hubs, video)

Kind: genre
Covers: Entertainment > Music & Audio; Entertainment > Showcase & Hub; Entertainment > Video
Also: Action > Music & Rhythm; Social > (none)

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no music, shows, venues, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Attend**: players arrive at a venue or space, find friends, watch or listen.
- **Show**: a scheduled or looping sequence of music, lights, camera moments and effects (concerts, showcases).
- **Listen**: curated playlists or radio-style audio with controls (music and audio experiences).
- **Watch**: video playback in a theatre or on screens (video experiences).
- **Explore and showcase**: walk through a built space that presents art, builds or products (showcase and hub).
- **Participate**: emotes, reactions, light interactions, photo moments.

## Kit modules
- `Cinematics/Cinematics`, `Cinematics/Spline`, `Cinematics/CinematicsRoblox`: show camera tracks and timed events.
- `AVKit/AudioDirector`, `AVKit/AudioGraph`, `AVKit/AudioGraphRoblox`, `AVKit/AudioMixer`: music scheduling, crossfades, buses and ducking on the Audio API.
- `AVKit/Vfx`, `AVKit/VfxLibrary`, `AVKit/Pool`: show effects with pooling.
- `SceneKit/Lighting`, `GameKit/WorldCycle`: lighting states and transitions.
- `GameKit/Fsm`: show state (doors open, pre-show, show, encore, after) serialised for late joiners.
- `GameKit/AnimSet`, `GameKit/AnimSetRoblox`: emotes and reactions.
- `GameKit/Interact`, `GameKit/Zones`: exhibits, seats, viewing areas.
- `GameKit/LiveOps`: scheduled shows from explicit UTC times.
- `UIKit/Components/Countdown`, `UIKit/Components/Slider`, `UIKit/Components/Toggle`: show countdown, volume and settings.
- `SceneKit/Building`, `SceneKit/Layout`, `SceneKit/Props`: venues and showcase spaces.

## Data to author
- Show timeline: cues keyed to time (camera, lights, effects, audio) (TBD).
- Playlist or audio asset list with rights confirmed by the owner (TBD).
- Venue layout and capacity (TBD).
- Schedule: show times in UTC, repeats (TBD).
- Exhibit data for showcases (TBD).

## Authority and abuse risks
- **Show sync**: the server owns the show clock; clients start cues from the server start time, so late joiners see the right moment.
- **Disruption**: rate-limit emotes, effects and reactions; personal-space or mute options (TBD).
- **Access**: VIP areas or backstage zones check entitlements on the server.

## Performance pitfalls
- Many simultaneous effects and lights for a full server: budget per show moment; test on a low-end device profile.
- Audio voices: cap concurrent players and use buses; `AutoLoad` off for cues outside the current section.
- Video: "A maximum of two videos can play simultaneously" (UI and cinematics research).
- Venue detail: keep the venue inside the scene budget class.

## Policy notes
- Audio and video assets need rights the owner holds; uploads are outside this factory (the hooks deny uploads).
- Video uploads need an ID-verified 13+ uploader and carry a per-upload Robux fee (UI and cinematics research); the factory never uploads.
- "Media sharing and content feeds" is a Maturity & Compliance questionnaire category.
- Sound, SoundGroup and SoundEffect are discouraged in favour of the Audio API objects.

## Test checklist
- [ ] A late joiner sees and hears the show at the correct moment (server clock, Server & Clients test, T3).
- [ ] Every cue in the timeline references an existing asset key and a known cue type.
- [ ] The audio graph routes every cue to the master bus (probe in `AVKit`, T3).
- [ ] A full venue stays inside the frame budget on a low-end device profile (`Diagnostics/PerfProbe`, T3).
- [ ] Shows start at the scheduled UTC time on every server.
- [ ] Camera moments are skippable and respect reduced-motion settings.

## Design questions (TBD)
- TBD: Live scheduled shows, looping shows, on-demand media, or a showcase space?
- TBD: Who provides the music or video, and are the rights confirmed?
- TBD: Is there participation beyond watching (emotes, votes, minigames)?
- TBD: Venue capacity and server size?
- TBD: Is the space also a social hub between shows?

## Reference systems
- Roblox "Concert" template's event sequencing as a read-only reference ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Audio API objects and voice budgets in the [visual and audio research](../../../../docs/research/visual-audio-assets-2026-10.md); VideoFrame limits in the [UI, cinematics and feel research](../../../../docs/research/ui-cinematics-feel-2026-10.md).
- Systems X24 and X32 in the genre coverage research.
