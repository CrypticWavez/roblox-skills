# Genre coverage research: chart genres, systems, pipelines and factory gaps (verified 2026-10-06)

**Scope.** This pass covers four things:
- which Roblox genres are on the charts today;
- which gameplay systems and content pipelines each genre needs;
- what this SETUP_ONLY factory already covers and what it lacks;
- the genre-neutral systems that would let the factory build any of these genres.

It extends [tooling-2026-10.md](tooling-2026-10.md) and [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md) and does not repeat their tool records. It chooses no genre, theme, world, character, economy or production UI. The output is a genre-neutral system list and a kit plan.

**Method.**
- Every source was fetched on 2026-10-06; the full list is at the end.
- Primary sources:
  - create.roblox.com (the `.md` page variants);
  - devforum.roblox.com announcements;
  - the about.roblox.com newsroom;
  - GitHub repo, raw-file and release pages;
  - the Wally API.
- Chart data came from read-only GET requests:
  - the JSON endpoints that roblox.com/charts itself loads (`https://apis.roblox.com/explore-api/v1/get-sorts?...` and `.../get-sort-content?sortId=<id>&...`);
  - genre labels from `https://games.roblox.com/v1/games?universeIds=<ids>`.
- These endpoints are not in Roblox's published API reference, so their stability is UNVERIFIED. The games endpoint answered HTTP 400 to batches of about 10 ids but worked with 5 or 6. The search endpoint (`.../search-api/omni-search`) answered once and then returned HTTP 429. Sorts change by the hour: two reads of Top Playing Now on the same day returned different orders.
- Pages were read through a summarising fetcher, so quotes are short.
- **No revenue, retention or quality claims.** Only chart membership and rank at fetch time are reported, and concurrent player counts are left out on purpose.
- The "core systems" and pipeline columns are design analysis of each genre. They are not observations of the listed games.
- Nothing was installed, bought, signed up for or inserted.

**Decision rule.** The rule is the same as in the addendum:
- **SELECT**: adopt inside SETUP_ONLY, as a reference, a design constraint, a PC tool, or code to write in this repo.
- **REJECT**: do not adopt.
- **REVISIT**: the decision waits for the stated trigger.

---

## 1. Official genre taxonomy

Source: Genres doc, last updated 2026-10-02. The doc says "Roblox also uses this information when placing games in genre-specific top and trending sorts on the Charts page". Genre changes can take "several days" to reach discovery.

| Genre | Subgenres |
|---|---|
| Action | Battlegrounds & Fighting, Music & Rhythm, Open World Action |
| Adventure | Exploration, Scavenger Hunt, Story |
| Education | (none) |
| Entertainment | Music & Audio, Showcase & Hub, Video |
| Obby & Platformer | Classic Obby, Runner, Tower Obby |
| Party & Casual | Childhood Game, Coloring & Drawing, Minigame, Quiz |
| Puzzle | Escape Room, Match & Merge, Word |
| RPG | Action RPG, Open World & Survival RPG, Turn-based RPG |
| Roleplay & Avatar Sim | Animal Sim, Dress Up, Life, Morph Roleplay, Pet Care |
| Shooter | Battle Royale, Deathmatch Shooter, PvE Shooter |
| Shopping | Avatar Shopping |
| Simulation | Idle, Incremental Simulator, Physics Sim, Sandbox, Tycoon, Vehicle Sim |
| Social | (none) |
| Sports & Racing | Racing, Sports |
| Strategy | Board & Card Games, Tower Defense |
| Survival | 1 vs All, Escape |
| Utility & Other | (none) |

The games API also returns a legacy `genre` field from the older taxonomy, for example "Horror", "Town and City", "Fighting" and "FPS". The fields `genre_l1` and `genre_l2` carry the current labels.

**How the requested genre names map onto official labels.**

| Requested genre | Official label(s) |
|---|---|
| Simulator / incremental | Simulation > Incremental Simulator |
| Tycoon | Simulation > Tycoon |
| Obby / platformer, tower, difficulty chart | Obby & Platformer > Classic Obby, Runner, Tower Obby |
| Tower defense | Strategy > Tower Defense |
| Horror (story and chase) | No Horror genre. Survival > 1 vs All (chase) and Survival > Escape (story/escape). Legacy field "Horror" |
| RPG / adventure / anime | RPG > Action RPG, Open World & Survival RPG; Adventure > Exploration, Story |
| Battlegrounds / fighting | Action > Battlegrounds & Fighting |
| Shooter (FPS/TPS) | Shooter > Deathmatch Shooter, PvE Shooter, Battle Royale |
| Racing / driving | Sports & Racing > Racing; Simulation > Vehicle Sim |
| Roleplay / life sim / town | Roleplay & Avatar Sim > Life, Morph Roleplay, Pet Care, Animal Sim |
| Survival / crafting | Survival (often with no subgenre); RPG > Open World & Survival RPG |
| Social hangout / dress-up / fashion | Roleplay & Avatar Sim > Dress Up; Shopping > Avatar Shopping; Social; Entertainment |
| Party / minigames | Party & Casual > Minigame, Childhood Game, Quiz |
| Sports | Sports & Racing > Sports |
| Story / escape | Adventure > Story; Survival > Escape; Puzzle > Escape Room |
| Idle / clicker | Simulation > Idle |
| PvP arena / round-based | No single label: Action > Battlegrounds & Fighting, Shooter > Deathmatch Shooter, Survival > 1 vs All |
| Puzzle | Puzzle > Word, Match & Merge, Escape Room |
| Pet collection / trading | No single label: Simulation > Incremental Simulator, Roleplay & Avatar Sim > Pet Care |
| Sandbox / building | Simulation > Sandbox, Physics Sim |

## 2. Chart snapshot, 2026-10-06

The get-sorts call (computer, all countries) returned these sorts:
- Top Trending (`top-trending`)
- Up-and-Coming (`up-and-coming`)
- Top Playing Now (`top-playing-now`)
- Explore Something New (`made-with-build`)
- Fun with Friends (`fun-with-friends`)

It also returned device and country filters. A `top-revisited` sort answers too, but it was not used for examples, so that no retention claim is implied.

Names below have emoji and bracketed update tags removed. Ranks:
- **TPN n**: position in Top Playing Now (get-sort-content, 97 entries).
- **TT n**: position in Top Trending (get-sort-content, 95 entries).

### 2.1 Top Playing Now, positions 1 to 20, with official labels

| TPN | Game | universeId | genre_l1 > genre_l2 | Created |
|---|---|---|---|---|
| 1 | Steal An Egg | 10563114921 | Simulation > Tycoon | 2026 |
| 2 | Brookhaven RP | 1686885941 | Roleplay & Avatar Sim > Life | 2020 |
| 3 | 99 Nights in the Forest | 7326934954 | Survival > (none) | 2025 |
| 4 | Blox Fruits | 994732206 | RPG > Action RPG | 2019 |
| 5 | Adopt Me! | 383310974 | Roleplay & Avatar Sim > Pet Care | 2017 |
| 6 | Murder Mystery 2 | 66654135 | Survival > 1 vs All | 2014 |
| 7 | Ride A Pet | 10035204815 | Simulation > Tycoon | 2026 |
| 8 | Dandy's World | 5569032992 | Survival > Escape | 2024 |
| 9 | Jujutsu Shenanigans | 3508322461 | Action > Battlegrounds & Fighting | 2022 |
| 10 | RIVALS | 6035872082 | Shooter > Deathmatch Shooter | 2024 |
| 11 | Slayers 2 | 5595353122 | RPG > Open World & Survival RPG | 2024 |
| 12 | +1 Speed Keyboard Escape | 9584852943 | Simulation > Incremental Simulator | 2026 |
| 13 | Steal a Brainrot | 7709344486 | Simulation > Tycoon | 2025 |
| 14 | Fisch | 5750914919 | Simulation > (none) | 2024 |
| 15 | Murderers VS Sheriffs | 7219654364 | Action > Battlegrounds & Fighting | 2025 |
| 16 | Catalog Avatar Creator | 2711375305 | Shopping > Avatar Shopping | 2021 |
| 17 | Fish It! | 6701277882 | Simulation > Incremental Simulator | 2024 |
| 18 | Volleyball Legends | 6931042565 | Sports & Racing > Sports | 2024 |
| 19 | Forsaken | 6331902150 | Survival > 1 vs All | 2024 |
| 20 | +1 Loot To Forge | 10684750879 | Simulation > Incremental Simulator | 2026 |

Label counts for these 20:
- Simulation 7: Tycoon 3, Incremental Simulator 3, no subgenre 1.
- Survival 4.
- RPG 2.
- Action 2.
- Roleplay & Avatar Sim 2.
- Shooter 1.
- Shopping 1.
- Sports & Racing 1.

Four of the 20 universes were created in 2026, all four labelled Simulation. The first read of the same sort, earlier the same day, had the same top two entries in a different order below them.

### 2.2 Examples per requested genre

| Requested genre | Examples (2026-10-06) | Note |
|---|---|---|
| Simulator / incremental | +1 Speed Keyboard Escape (TPN 12, TT 4), Fish It! (TPN 17), +1 Loot To Forge (TPN 20, TT 8), Anime Dice (TPN 24, TT 16), Pet Simulator 99! (TPN 36), Sol's RNG (TPN 42), Bee Swarm Simulator (TPN 61) | Fisch (TPN 14) is labelled Simulation with no subgenre |
| Tycoon | Steal An Egg (TPN 1), Ride A Pet (TPN 7, TT 1), Steal a Brainrot (TPN 13), Break and Steal an Egg (TPN 29), Grow a Garden (TPN 57), Build An Ant Empire (TPN 73), Restaurant Tycoon 3 (TT 56) | The largest label group in the top 20 |
| Obby / platformer | TROLL Hug Tower (TPN 69, Tower Obby), Barry's Prison Run (TPN 88), Grapple Cart Obby (TT 19) | The last two have no subgenre label |
| Tower defense | Anime Vanguards (TPN 65), Tower Defense Simulator (TT 20), Tower Defense X (TT 49) | All Strategy > Tower Defense |
| Horror: chase | Murder Mystery 2 (TPN 6), Forsaken (TPN 19, TT 3), Violence District (TPN 27), Flee the Facility (TPN 46), 3008 (TPN 94) | Survival > 1 vs All; several carry legacy genre "Horror" |
| Horror: story / escape | Dandy's World (TPN 8), DOORS (TPN 26), THRESHOLD (TT 14); Evade (TPN 33) and Piggy (TPN 47) have Survival with no subgenre | Survival > Escape |
| RPG / adventure / anime | Blox Fruits (TPN 4), Slayers 2 (TPN 11, TT 2), Grand Piece Online (TPN 79); Adventure > Exploration: Dead Rails (TPN 55), Drill to Earth's Core (TPN 78) | |
| Battlegrounds / fighting | Jujutsu Shenanigans (TPN 9), Murderers VS Sheriffs (TPN 15), The Strongest Battlegrounds (TPN 21), Huss Valley (TPN 23), BedWars (TPN 34), Command An Army (TPN 41), Anime Ability Arena (TPN 87), Blade Ball (TPN 89) | |
| Shooter | RIVALS (TPN 10), Hypershot (TPN 43), One Tap (TPN 54), Sniper Arena (TPN 74) (all Deathmatch); Cold War (TT 9, Deathmatch); Notoriety (TT 83, PvE Shooter) | No Battle Royale label in the sorts read |
| Racing / driving | Vehicle Sim: Drag Drive Simulator (TPN 32), Driving Empire (TPN 52), American Plains Mudding (TPN 72), Southern Mudding (TPN 86), Midnight Chasers (TT 85), Taxi Boss (TT 40) | Only one Racing-labelled game was found (Formula Apex Racing, Sports & Racing > Racing), and it came from a search for "racing", not from a chart |
| Roleplay / life / town | Brookhaven RP (TPN 2), Adopt Me! (TPN 5, Pet Care), Berry Avenue (TPN 30), LifeTogether (TPN 37), Dreamville (TPN 45), Creatures of Sonaria (TPN 62, Animal Sim), Welcome to Bloxburg (TPN 70), Metro Life (TPN 92), Emergency Response: Liberty County (TT 23) | |
| Survival / crafting | 99 Nights in the Forest (TPN 3), Animal Hospital (TPN 28), 100 Days At Sea (TPN 67), DON'T LET HIM IN (TT, Survival); BlockSpin (TPN 76, Action > Open World Action) | Crafting features are not confirmed by labels |
| Social / dress-up / fashion | Dress To Impress (TPN 25, Dress Up), Royale High (TT 35, Dress Up), Catalog Avatar Creator (TPN 16) and My Avatar! (TPN 49) (Avatar Shopping), My Movie (TPN 84, Entertainment > Video) | No Social-labelled game in the sorts read |
| Party / minigames | Ball VS Ball (TPN 31, TT 7), Color My Flag (TPN 90), Squid Game X (TPN 95, Minigame), Duck Duck (Tag) (TT 53, Childhood Game) | Death Order: Simon Says (TT 45) is labelled Survival |
| Sports | Volleyball Legends (TPN 18), Illegal Soccer (TPN 22), Realistic Street Soccer (TPN 44), NFL Universe Football (TPN 48), Blue Lock: Rivals (TPN 60), Racket Rivals (TT 48) | |
| Story / escape | MONOCHROME (TPN 85, Puzzle > Escape Room); Survival > Escape titles above | No Adventure > Story label in the sorts read |
| Idle / clicker | none labelled Simulation > Idle in the sorts read | The closest observed label is Incremental Simulator |
| PvP arena / round-based | Murderers VS Sheriffs, Blade Ball, BedWars (Action), RIVALS, Sniper Arena (Shooter), Murder Mystery 2 (Survival > 1 vs All); KNIFE DUELS (TT 21), Dueling Grounds (TT 34) (labels not fetched) | No single label |
| Puzzle | Finish The Word! (TT 44, Puzzle > Word), MONOCHROME (TPN 85, Escape Room) | |
| Pet collection / trading | Pet Simulator 99! (TPN 36, Incremental Simulator), Adopt Me! (TPN 5, Pet Care), Ride A Pet (TPN 7, Tycoon) | No single label; trading is not confirmed by labels |
| Sandbox / building | Build and Kill Zombies (TPN 38, TT 17), Build A Boat For Treasure (TPN 97), Plane Crazy (TT 67) (all Sandbox); Fling Things and People (TPN 35, Physics Sim) | |

## 3. Genre to core systems (design analysis)

**Universal systems** (core in all 20 genres):
- X02 player data;
- X20 input mapping;
- X23 UI kit;
- X25 onboarding;
- X26 settings;
- X27 notifications;
- X28 analytics events;
- X29 monetization handled in a sandbox.

The matrix below covers the systems that differ by genre. **C** means core and **o** means common but optional; a blank means rarely needed.

Genre codes:

| Code | Genre | Code | Genre |
|---|---|---|---|
| SIM | simulator / incremental | SUR | survival / crafting |
| TYC | tycoon | SOC | social / dress-up / fashion |
| OBY | obby / platformer | PTY | party / minigames |
| TD | tower defense | SPO | sports |
| HOR | horror | STY | story / escape |
| RPG | RPG / adventure / anime | IDL | idle / clicker |
| BTL | battlegrounds / fighting | PVP | PvP arena / round-based |
| SHO | shooter | PUZ | puzzle |
| RAC | racing / driving | PET | pet collection / trading |
| RP | roleplay / life / town | SBX | sandbox / building |

| ID | System | SIM | TYC | OBY | TD | HOR | RPG | BTL | SHO | RAC | RP | SUR | SOC | PTY | SPO | STY | IDL | PVP | PUZ | PET | SBX |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| X01 | Round / match state machine | | | o | C | C | o | o | C | C | | o | o | C | C | o | | C | o | | o |
| X03 | Currency wallet + ledger | C | C | o | C | o | C | o | o | o | o | o | o | o | o | o | C | o | o | C | o |
| X04 | Inventory, items, equipment | o | o | | C | o | C | o | C | o | C | C | C | | o | o | o | C | | C | C |
| X05 | Progression, upgrades, multipliers, rebirth | C | C | o | C | o | C | o | o | o | o | o | o | o | o | | C | o | o | C | o |
| X06 | Quests, achievements, daily / streak rewards | C | o | o | o | o | C | o | o | o | o | o | o | o | o | C | C | o | o | C | o |
| X07 | Dialogue graph | | | | | o | C | | | | o | o | | | | C | | | o | | |
| X08 | NPC AI + navigation | o | o | | C | C | C | o | o | o | o | C | | o | o | C | | | | C | o |
| X09 | Combat + server hit validation | o | o | | o | o | C | C | C | | o | C | | o | o | o | | C | | o | o |
| X10 | Projectiles | | | o | C | | C | C | C | o | | o | | o | C | | | C | | | o |
| X11 | Checkpoints, stages, hazards, laps | o | | C | | C | o | | o | C | | o | | C | | C | | o | o | | o |
| X12 | Wave / encounter director | | o | | C | o | o | | o | | | C | | o | | o | | | | | o |
| X13 | Plots / ownership + generators | o | C | | | | | | | | o | o | | | | | C | | | o | C |
| X14 | Pets / followers + weighted rolls | C | o | | o | | o | o | | | o | | | | | | C | | | C | |
| X15 | Trading | o | o | | o | | o | | | | o | o | o | | | | o | | | C | o |
| X16 | Matchmaking, queues, parties, teleport | | | o | C | C | o | o | C | C | | o | | C | C | C | | C | o | | |
| X17 | Vehicles | o | o | o | | | o | | o | C | C | o | | o | | | | o | | o | C |
| X18 | Building / placement grid | | o | | C | | | | | | o | C | | | | | | o | o | | C |
| X19 | Leaderboards | C | o | C | o | o | o | o | C | C | | o | o | o | C | | C | C | C | o | |
| X21 | Movement abilities (sprint, dash, stamina) | o | | C | | C | C | C | C | | o | C | | o | C | o | | C | | | o |
| X22 | Interaction prompts | C | C | o | o | C | C | | o | o | C | C | C | o | | C | o | | C | C | C |
| X24 | Cutscenes / sequences | o | o | o | o | C | C | o | o | o | | o | o | o | o | C | | o | o | o | |
| X30 | Live-ops: timed events, rotating shop, season pass | C | C | o | C | o | C | o | C | o | o | o | C | o | o | o | C | o | o | C | o |
| X31 | Crafting / gathering | o | o | | | | C | | | | o | C | | | | | o | | o | o | C |
| X32 | World state: day/night, weather, events | o | o | | | C | o | | | o | C | C | o | | | C | o | | | o | o |
| X33 | Avatar customization / dress-up | | | o | | o | o | o | o | | C | | C | o | o | | | o | | o | |

## 4. Genre to content pipelines (design analysis) and factory coverage

| Genre | Level design | Models / art | Animation | UI | VFX / audio / cutscenes |
|---|---|---|---|---|---|
| SIM | zones / areas with gates, hub | collectibles, pets, upgrade props, item icons | pet idle/walk, hatch reveal | currency HUD, upgrade shop, odds info, inventory | pickup/level-up feedback, rarity reveal sequence |
| TYC | plot grid, dropper/conveyor lines | modular droppers, conveyors, buttons, buildings | machine loops | buy buttons, earnings HUD | purchase feedback, plot unlock sequence |
| OBY | linear courses, tower floors, jump ramps | obstacle and stage kit, checkpoints | character movement only | stage counter, timer | hazard telegraphs, completion sequence |
| TD | enemy lanes, build slots, base | towers, enemies (many variants), path props | enemy walk/death, tower attack | wave HUD, unit cards, placement ghost | hit/projectile VFX, wave stingers |
| HOR | interiors, rooms, chase loops, hiding spots | monster, props, doors | monster locomotion, scare clips | minimal HUD, objectives | lighting events, audio stingers, jump-scare camera sequences |
| RPG | open world / dungeons, towns | NPCs, enemies, weapons, armour | combat sets, NPC idles, emotes | inventory, quests, dialogue, skill bar | ability VFX, music states, story cutscenes |
| BTL | arena(s) | characters, ability props | combo/ability sets, hit reactions | ability bar, health, combo | hit-stop, camera shake, ability VFX |
| SHO | symmetric arenas, lanes, cover | weapons, attachments | first/third-person weapon sets | crosshair, ammo, killfeed, scoreboard | muzzle/impact VFX, positional audio |
| RAC | tracks with checkpoints, open roads | vehicles, track kit | vehicle rigs (wheels, suspension) | speedometer, position, lap timer | boost/skid VFX, engine audio |
| RP | town / settlement, interiors | houses, furniture, vehicles, clothing | emotes, sit/use clips | role / job menus, phone-style UI | ambient audio, day/night |
| SUR | biomes, forest, resources, base sites | resources, tools, structures, creatures | gather/craft/attack clips | crafting, inventory, survival meters | weather, night-event sequences |
| SOC | hubs, stages / runways | accessories / clothing (cages) | poses, emotes | wardrobe, voting / judging | spotlight sequences |
| PTY | many small arenas | minigame props | character only | round / results screens | round intro sequences |
| SPO | pitches / courts | balls, goals, kits | kick/throw/serve sets | score, timer, team UI | goal sequences, crowd audio |
| STY | authored chapters | set dressing, key items | scripted NPC clips | subtitles, objectives | heavy cutscenes |
| IDL | single screen / small area | generators, icons | loops | numbers-heavy panels | number pops |
| PVP | arenas | weapons / abilities | combat sets | scoreboard, killfeed | hit feedback |
| PUZ | puzzle rooms / boards | puzzle pieces | piece motions | board UI, hints | solve feedback |
| PET | hatch areas, hubs | many pets (variants), eggs | pet idle/walk/fly, hatch | pet inventory, trade window, odds | hatch sequence |
| SBX | build plots | building blocks / parts kit | none special | build toolbar, save / load | placement feedback |

**Factory coverage by pipeline.**
- **Level design.** Strong for rooms, dungeons, caves, arenas, settlements and forests:
  - `packages/ProcGen` (gap-matrix P01/P02 VERIFIED);
  - `packages/SceneKit` (S03);
  - `SceneKit/Measure.luau` (jump reach, clearances, sightlines).

  It lacks course and track generators: linear obstacle courses, tower floors, race-track loops with checkpoints, TD lanes with build slots, and minigame micro-arenas. It also lacks tycoon plot layouts. All of these are generator-shaped and fit ProcGen.
- **Models / art.** `tools/blender` builds 13 templates (humanoid, NPC, enemy, creature, weapon, prop, vehicle, building, modular kit, environment and tests), with QA, LODs and the round trip (B01, B04, B08). It lacks:
  - gameplay-prop kits (pickups, buttons/pads, droppers, conveyors, turrets, checkpoint gates, track and obby pieces);
  - a pet/follower template;
  - accessory templates with `_InnerCage`/`_OuterCage`;
  - an item-icon renderer: the render code makes framed stills (`bkit/render.py`) but has no transparent-background icon output;
  - texture baking (B06 colour loss).
- **Animation.** Covered today: `ops.keyframe_clip`, clip QA, `Creator/AnimationInspector.luau` and `Runtime/Motion.luau`. Missing:
  - a standard clip set per template;
  - the 2026 engine paths (local clip import, Animation Graphs, Adaptive Animation; section 5).
- **UI.** `Runtime/NativeUI.luau` (one panel, two themes, tokens) and `Creator/UI.luau` (HUD, menu tabs, inventory grid, shop display, settings) are fixture-grade. Missing:
  - a component library;
  - StyleSheet tokens;
  - Styling Transitions;
  - the genre screens listed above.
- **VFX.** `Creator/Effects.luau`, `Creator/EffectsPool.luau`, `Runtime/NativeEffects.luau` and `Runtime/Lifetime.luau` provide neutral recipes and pooling. There is no catalogue of gameplay-event recipes and no game-feel helpers (camera shake, hit-stop, number pops).
- **Audio.** `Runtime/AudioMixer.luau` and `Creator/AudioDirector.luau` are fine as pure logic. The backend `Runtime/NativeAudio.luau` creates `SoundGroup`s, which Roblox now discourages (section 5), so it is OUTDATED.
- **Cutscenes.** None. `SceneKit/Camera.luau` only frames captures.

## 5. Platform facts that shape these systems (2026)

- **Server Authority is a full release.** DevForum, 2026-07-09: setting `AuthorityMode` to Server sets `StreamingEnabled`, `NextGenerationReplication`, `UseFixedSimulation`, Deferred `SignalBehavior` and `PlayerScriptsUseInputActionSystem`. The docs (2026-10-02) add these rules:
  - gameplay logic binds to `RunService:BindToSimulation()` in ModuleScripts that run on both client and server;
  - code uses `time()`, not `tick()` or `os.time()`;
  - input goes through the Input Action System;
  - attributes are capped at 64 per instance;
  - animations and effects run in `RenderStepped`.

  The release says it covers character movement, vehicles, sports physics, Backpacks and Tools. Known limits: eight playing tracks per Animator, and remote events are not synchronised with the simulation timeline. **Consequence:** combat, movement, vehicle and ball systems must be written so that they can run under `BindToSimulation`.
- **Input Action System is GA** (docs 2026-10-02). It uses `InputContext`, `InputAction` and `InputBinding`, with touch via `GuiButton` (`UIButton`). The Input Action Manager and `InputActionLabel` are in beta. The docs say "each InputAction should have an InputBinding for gamepad, keyboard/mouse, and touch."
- **The animation stack changed this year.**
  - Animation Graphs are a full release (2026-07-15): state machines, Blend1D/2D, typed parameters through `AnimationTrack:SetParameter()`, and support in both authority modes. Graphs "must be published as assets" to work in live games.
  - Adaptive Animation is a full release (2026-04-29): `HumanoidRigDescription` and `DigitsRigDescription` let one animation play on custom rigs.
  - The Animation Clip Editor has imported FBX and glTF since its 2026-01-15 update, including multiple clips per file. Imports are "saved locally" to `ServerStorage/RBX_ANIMSAVES`, and uploading is a separate step.
  - `KeyframeSequenceProvider:RegisterKeyframeSequence` returns a temporary id that "cannot be used outside of Studio". Together with the local import, this is a **no-upload route to play clips in Studio tests**.
- **UI.** The beta thread for Styling Transitions was posted 2026-05-21 and reports a full release on 2026-07-27. Engine-native tweens on style changes and GuiState selectors (hover, press) are configured in the Style Editor or through `StyleRule`. The styling docs (2026-09-30) cover tokens, themes and state selectors.
- **Audio.** The docs (2026-10-02) say "Sound, SoundGroup, and SoundEffect objects are now discouraged" in favour of `AudioPlayer`, `AudioEmitter`, `AudioListener`, `AudioDeviceOutput`, `Wire` and modifiers such as `AudioFader`, `AudioReverb` and `AudioEqualizer`.
- **Data.**
  - Roblox publishes a reference architecture (2026-09-25):
    - `DataStoreWrapper` keeps a per-key serial queue with exponential-backoff retries;
    - `SessionLockedDataStoreWrapper` writes "a lock to the key's metadata inside the same UpdateAsync() call", with expiry and refresh;
    - player data autosaves every 180 s with per-player jitter;
    - `BindToClose` saves within the 30 s window;
    - receipts are deduplicated by PurchaseId.
  - The data store docs warn that Studio "accesses the same data stores as the client application". Whether an unpublished place can use data stores at all is UNVERIFIED (expected: no).
  - Data store storage rose from 100 MB to 500 MB (weekly recap, 2026-07-17).
  - MemoryStore (sorted map, queue, hash map) is "isolated between Studio and production". Quotas scale with users.
  - Persistent leaderboards (ordered data store registered in Creator Hub) are in beta, with "one active persistent leaderboard per experience" (docs 2026-10-02).
- **Systems Studio cannot test.**
  - "TeleportService doesn't support playtesting in Roblox Studio" (docs 2026-10-02).
  - The Party API (`Player.PartyId`, `SocialService:GetPartyAsync`, `GetPlayersByPartyId`; 2025-06-03) did not work in Studio. The Studio Party Simulator beta (2025-10-31) simulates it in Server & Clients mode.
  - AnalyticsService: "Events can only be sent from the server and in published games. Events can't be sent from the client or Studio" (custom-events and funnel docs, 2026-10-01/02). The documented APIs include `LogCustomEvent`, `LogOnboardingFunnelStepEvent` and `LogFunnelStepEvent`.
  - MatchmakingService scores eligible public servers using signals that are configured in Creator Hub (docs 2026-10-02). No Studio test method is documented.
- **Monetization policy.** The paid random items rules (docs 2026-10-02) apply to eggs, wheels, luck boosts and pity systems:
  - odds "must be displayed as a probability percentage, and the probability percentages of all final outcomes must sum to exactly 100%";
  - `PolicyService:GetPolicyInfoForPlayerAsync()` exposes `ArePaidRandomItemsRestricted` and `IsPaidItemTradingAllowed`.

  `MarketplaceService` now also has `PromptBulkPurchase` and `PromptRobuxTransferAsync`. The repo's `tools/hooks/guard_mcp.mjs` PURCHASE pattern already covers both, and `tools/hooks/selftest.mjs` checks them, so no guard gap was found.
- **Navigation and queries.**
  - PathfindingService (docs 2026-10-01): agent parameters, `PathfindingModifier` costs and PassThrough, `PathfindingLink`, recompute when the path is blocked ahead. The stated limits (summarised by the fetcher) are 3,000 studs and 20,000 nodes.
  - WorldRoot has `Blockcast`, `Spherecast`, `Shapecast`, `GetPartBoundsInBox`, `GetPartBoundsInRadius` and `GetPartsInPart`. The Region3 queries are deprecated.
- **Roblox-made reference content.**
  - Feature packages (docs 2026-10-02): Bundles, Missions (beta; 2026-07-27), Season Passes and Engagement Rewards (2026-07-24). All are obtained through the Toolbox (Creator Store), all need the Core feature package, and no licence is stated.
  - Templates (docs 2026-09-03) are "uncopylocked games": Platformer, Laser Tag, FPS System, Racing, Classic Racing, Classic Obby, Capture the Flag, Team/FFA Arena, Combat, Concert (event sequencing), Move It Simulator, Line Runner, Mansion of Wonder and environment kits.
  - Developer modules (2026-10-02): Selfie Mode, Merch Booth, Friends Locator, Spawn With Friends, Emote Bar, Profile Card, Photo Booth, Surface Art, Scavenger Hunt and Social Interactions.
- **Studio command line** (docs 2026-09-23): `--task RunScript --runScriptFile <file>` with `--localPlaceFile <path>`, `--outputFile <path>` and `--quitAfterExecution`. Scripts run "at the same permission level as the Studio command bar". Windows and macOS only.
- **RDC 2026 announcements** (newsroom, 2026-09-11):
  - "Scene Generator", described as prompt-to-scene, is coming later this year;
  - "Turn-Based Multiplayer Notifications" are "arriving in Studio Beta in October";
  - a Web Player is due by the end of the year;
  - Offline Play is due by mid-2027.
- **Cutscenes.** A search of create.roblox.com found no first-party cutscene or camera-sequence editor, only Creator Store plugins, the Concert template's event sequencing and tutorial code. The absence is UNVERIFIED.

## 6. Candidate records

### 6a. Facts

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| Genre taxonomy + Charts sorts | create.roblox.com/docs/production/publishing/experience-genres; roblox.com/charts (JSON endpoints undocumented) | Roblox | 17 genres | doc 2026-10-02 | active | Roblox terms | free |
| Server Authority + Input Action System | create.roblox.com/docs/projects/server-authority; /docs/input/input-action-system | Roblox | engine (Studio 741 era) | full release 2026-07-09; docs 2026-10-02 | active | Roblox terms | free |
| Animation stack 2026 (Graphs, Adaptive Animation, Clip Editor import, RegisterKeyframeSequence) | create.roblox.com/docs/animation/graph-editor; DevForum release threads | Roblox | engine | 2026-07-15 / 2026-04-29 / 2026-01-15 | active | Roblox terms | free |
| UI Styling + Styling Transitions | create.roblox.com/docs/ui/styling; DevForum thread 4646870 | Roblox | engine | transitions full release reported 2026-07-27; styling doc 2026-09-30 | active | Roblox terms | free |
| Audio API objects | create.roblox.com/docs/audio/objects | Roblox | engine | 2026-10-02 | active (Sound/SoundGroup discouraged) | Roblox terms | free |
| Player-data and purchasing reference architecture | create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing | Roblox | doc | 2026-09-25 | active | Roblox terms; code licence not stated (UNVERIFIED) | free |
| Cross-server services: MemoryStore, OrderedDataStore / persistent leaderboards, TeleportService, MatchmakingService, Party API + Party Simulator, AnalyticsService | create.roblox.com docs pages listed in Sources | Roblox | engine | docs 2026-10-01/02; Party Simulator beta 2025-10-31 | active; persistent leaderboards and Party Simulator in beta | Roblox terms | free (quotas) |
| PolicyService + paid random items policy | create.roblox.com/docs/production/monetization/paid-random-items | Roblox | policy | 2026-10-02 | active | Roblox terms | free |
| PathfindingService + WorldRoot spatial queries | create.roblox.com/docs/characters/pathfinding; WorldRoot reference | Roblox | engine | 2026-10-01 | active | Roblox terms | free |
| Feature packages (Missions, Engagement Rewards, Bundles, Season Passes) | create.roblox.com/docs/resources/feature-packages | Roblox | Creator Store packages; Missions "in beta" | 2026-07-24 to 2026-10-02 | active | not stated (UNVERIFIED) | free |
| Official templates | create.roblox.com/docs/resources/templates | Roblox | Studio landing-page templates | doc 2026-09-03 | active | not stated (UNVERIFIED) | free |
| Studio command-line interface | create.roblox.com/docs/studio/command-line-interface | Roblox | ships with Studio | doc 2026-09-23 | active | Roblox terms | free |
| ProfileStore | github.com/MadStudioRoblox/ProfileStore; Wally `lm-loleris/profilestore` | loleris (MadStudio) | Wally 1.0.3 (no GitHub releases) | unknown (commit pages not read) | not archived; 332 stars | Apache-2.0 | free |
| Lyra | github.com/paradoxum-games/lyra; Wally `paradoxum-games/lyra` | Paradoxum Games | 0.6.0 | release page "08 Jul", year unknown | not archived; 146 stars | MIT | free |
| Chickynoid | github.com/easy-games/chickynoid | MrChickenRocket and Brooke | no release shown (399 commits) | unknown | not archived; 265 stars | MIT | free |
| ShapecastHitbox | github.com/TeamSwordphin/ShapecastHitbox | TeamSwordphin | no release shown | unknown | not archived; 22 stars | MIT | free |
| FastCastRedux | github.com/EtiTheSpirit/FastCastRedux | EtiTheSpirit | n/a | n/a | the repo URL returned HTTP 404 on 2026-10-06 | unknown | free |
| Cmdr | github.com/evaera/Cmdr | evaera | no release shown | unknown | not archived; 527 stars | MIT | free |
| Creator Store cutscene plugins (for example "Cutscene Editor v2") | Creator Store search results | community | unknown | unknown | unknown | store page body unreadable | unknown |
| RDC 2026 Scene Generator; Turn-Based Multiplayer Notifications | about.roblox.com newsroom 2026-09-11 | Roblox | not released | n/a | announced | Roblox terms | unknown |

### 6b. Assessment

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude / Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| Genre taxonomy + Charts sorts | official genre names; chart sorts by genre, device and country | Read-only GETs. The endpoints are undocumented and rate-limited (HTTP 429 seen) | `knowledge/records/` market records (workbench-scoped) | WebFetch / Codex web tools during research only | Dated, reproducible snapshots; genre names for playbooks and briefs | **SELECT** as the research reference. Never call these endpoints from a gate (see REJECT below) |
| Server Authority + IAS | engine prediction and rollback; input contexts and bindings | Removes the need for most custom movement anti-cheat; attribute and track limits | Chickynoid; `Creator/MovementProfile.luau` | Pure cores tested in Lune; adapters run through Studio MCP `execute_luau` / `start_stop_play` | Correct-by-construction combat, movement, vehicles and sports | **SELECT** as a design constraint for GameKit (BindToSimulation-compatible cores; IAS-only input) |
| Animation stack 2026 | graphs, retargeting, local multi-clip glTF/FBX import, Studio-only temporary ids | Publishing graphs or clips is an upload: ask first, and only in a game repo | `bkit` `keyframe_clip`, `roblox-animation-integration` skill | Local import is GUI; `RegisterKeyframeSequence` is callable from `execute_luau` | A no-upload Studio test path for clips; one clip set for pets and creatures | **SELECT**: update the skill and bkit; graphs stay local in this factory |
| UI Styling + Transitions | tokens, themes, state selectors, native transitions | none | `Runtime/NativeUI.luau` tokens table | `execute_luau` builds StyleSheets; `screen_capture` with Device Simulator | Engine-native polish with no framework dependency | **SELECT** as the UIKit base |
| Audio API objects | routable audio graph, effects, 3D emitters | none | `Runtime/NativeAudio.luau` (SoundGroup) | `execute_luau`; hearing needs a human | Current API; per-channel faders | **SELECT**: migrate the NativeAudio backend |
| Player-data reference architecture | session lock in key metadata, serial queues, autosave, shutdown flush, receipt dedupe | Studio hits live data stores, so test only with fakes here | `Runtime/ReceiptLedger.luau` | Spec for Lune fakes | The canonical algorithm to implement and test | **SELECT** as the spec for `GameKit/SessionStore` |
| Cross-server services | queues, sorted maps, leaderboards, teleports, server scoring, parties, analytics | Teleport and analytics cannot run in Studio; data stores in Studio are live | none in repo | Adapters with fakes in Lune; Party Simulator in Server & Clients; MemoryStore is usable in Studio (isolated) | Defines the adapter seams | **SELECT** as adapter targets. Verification beyond fakes is BLOCKED_EXTERNAL until a game repo has a private test universe |
| PolicyService + paid random items | regional gating; odds disclosure rules | compliance risk if ignored | none | Lune for the odds maths; policy calls through an adapter | Pets, eggs, RNG and trading built compliant from day one | **SELECT** as the requirement for `OddsTable` and `Trade` |
| Pathfinding + spatial queries | navmesh paths, costs, links; shapecasts and box queries | none | ProcGen grid reachability (P02 defect: not PathfindingService) | `execute_luau` probe on fixtures | NPC AI, hitboxes and placement validation on engine truth | **SELECT** |
| Feature packages | Missions: tasks, prerequisites, time windows, completion handler; Engagement Rewards: daily and time rewards; Bundles: receipt-id dedupe; Season Passes | Inserting them is a Creator Store asset insert (guard asks); licence not stated | GameKit Objectives, Streaks, LiveOps | Docs readable; insertion needs Studio | Proven API shapes to mirror | **SELECT** as a reference only. **REVISIT** inserting them in a game repo through `roblox-asset-intake` |
| Official templates | genre reference implementations (blasters, rounds, race cars and checkpoints, obby checkpoints and hazards, event sequencing) | licence not stated, so do not copy code | GameKit systems | Read in Studio | Behaviour references for RoundLoop, Checkpoints, Vehicles, Sequence | **SELECT** as a reference only (read, do not vendor) |
| Studio CLI RunScript | runs a Luau file in a local place file and writes output to a log, then quits | Command-bar permission level. Use only with `--localPlaceFile`; never with `--placeId`. Whether login is required, and whether it runs in edit or play mode, is UNVERIFIED | Studio MCP `execute_luau`; run-in-roblox (rejected) | A PC wrapper callable by both agents; not usable in the Linux container | Repeatable in-engine checks of GameKit adapters without MCP round trips | **SELECT** for the PC (not yet implemented; exercise once before relying on it) |
| ProfileStore | session-locked periodic saves; `StartSessionAsync`, `EndSession`, `MessageAsync`, `VersionQuery`, `Reconcile`; `ProfileStore.Mock` "fake" store | third-party runtime code with data authority | SessionStore (planned), Lyra | Wally; behaviour readable | A behavioural oracle and a Mock pattern for the fake store | **SELECT** as a reference only. **REVISIT** as a dependency if a game repo prefers it to GameKit SessionStore |
| Lyra | session locking, migrations, transactions, sharding, validation | README: transactions "not yet battle-tested in production at scale" | ProfileStore, SessionStore | Wally | Migration and transaction API ideas | **REJECT** now; **REVISIT** at 1.0 |
| Chickynoid | custom server-authoritative character controller with rollback and weapons | replaces the Humanoid pipeline | Server Authority (engine, GA) | Wally / GitHub | Superseded for new work | **REJECT**: engine Server Authority covers the need |
| ShapecastHitbox | shapecast melee hitboxes | small single-maintainer runtime code | native `Shapecast` / `Blockcast` / `GetPartBoundsInBox` | GitHub | marginal | **REJECT**: wrap the native queries in `GameKit/Hitbox` |
| FastCastRedux | projectile simulation | repo not found at the known URL | `GameKit/Projectile` (planned) | n/a | n/a | **REJECT** (status UNVERIFIED: moved or deleted) |
| Cmdr | in-game command console with typed arguments | adds a remote command surface to a game | none | Wally | QA shortcuts such as granting currency or skipping a wave | **REVISIT** in a game repo, Studio-only (`RunService:IsStudio()`), as a debug tool |
| Creator Store cutscene plugins | camera path authoring | plugin with full place access; unknown licence; insert needs approval | `GameKit/Sequence` (planned) | GUI only | unknown | **REJECT**: unverifiable; build a data-driven sequence module instead |
| RDC 2026 Scene Generator / Turn-Based Notifications | prompt-to-scene; turn notifications | Generated content and notifications are asset or production actions | SceneKit, ProcGen | unknown | unknown | **REVISIT** when released with docs |
| Automated chart scraping in gates or CI | periodic chart pulls | undocumented endpoints, 429 rate limit, volatile data | this doc | n/a | none for setup | **REJECT**: manual dated snapshots only |

## 7. Cross-genre system list: exists vs missing

Statuses use the repo's verification language. "Core in" counts the genres marked C in section 3; universal systems are core in 20.

| ID | System | Core in | Factory today | Status | Proposed deliverable | Priority |
|---|---|---|---|---|---|---|
| X01 | Round / match state machine | 7 (+8 optional) | none; checklist `.agents/skills/roblox-genre-systems/references/party-and-matchmaking.md` | MISSING | `packages/GameKit/StateMachine.luau`, `RoundLoop.luau` | P0 |
| X02 | Player data: session lock, migrations, autosave | 20 | `packages/Runtime/ReceiptLedger.luau` (UpdateAsync transforms, v1 to v2 migration, corrupt-schema refusal), `RobloxReceiptAdapter.luau` | PARTIAL | `GameKit/SessionStore.luau`, `Migrations.luau`, `tests/fakes/FakeDataStore.luau` | P0 |
| X03 | Currency wallet + economy ledger | 6 (+14) | ReceiptLedger balances for purchase grants only | PARTIAL | `GameKit/Wallet.luau`, `EconomySim.luau` | P0 |
| X04 | Inventory, item definitions, equipment | 9 | `Creator/UI.luau` `UI.validateItems`, `setInventory` view only | MISSING | `GameKit/ItemDefs.luau`, `Inventory.luau` | P0 |
| X05 | Progression, upgrades, multipliers, rebirth, offline accrual | 6 | none | MISSING | `GameKit/Progression.luau` | P1 |
| X06 | Quests, achievements, daily / streak rewards | 5 (+15) | none | MISSING | `GameKit/Objectives.luau`, `Streaks.luau` | P1 |
| X07 | Dialogue graph | 2 | none | MISSING | `GameKit/Dialogue.luau` | P1 |
| X08 | NPC AI + navigation | 6 | `ProcGen/Placement.luau` roles; grid reachability in `ProcGen/Validate.luau` | MISSING | `GameKit/NpcBrain.luau`, `NavAdapter.luau` | P1 |
| X09 | Combat + server hit validation | 5 (+10) | procedure in `roblox-multiplayer-integrity` and `references/legacy-combat-hardening.md` | MISSING | `GameKit/Combat.luau`, `HitValidation.luau`, `Hitbox.luau` | P0 |
| X10 | Projectiles | 6 | `Creator/EffectsPool.luau` (pooling only) | MISSING | `GameKit/Projectile.luau` | P1 |
| X11 | Checkpoints, stages, hazards, laps | 5 | `SceneKit/Measure.luau` `canJump` / `jumpReach` (design time) | MISSING | `GameKit/Checkpoints.luau` | P1 |
| X12 | Wave / encounter director | 2 (+7) | `ProcGen/Placement.luau` encounter slots | MISSING | `GameKit/WaveDirector.luau` | P1 |
| X13 | Plots / ownership + generators | 3 | `ProcGen/Settlement.luau` lots (layout only) | MISSING | `GameKit/Plots.luau`, `Generators.luau` | P1 |
| X14 | Pets / followers + weighted rolls | 3 (+5) | none | MISSING | `GameKit/Followers.luau`, `OddsTable.luau`, `PolicyGate.luau` | P1 |
| X15 | Trading | 1 (+9) | none | MISSING | `GameKit/Trade.luau` | P1 |
| X16 | Matchmaking, queues, parties, teleport | 8 | `Diagnostics/FaultQueue.luau` (transport faults only) | MISSING | `GameKit/Queue.luau`, `TeleportAdapter.luau`, `PartyAdapter.luau` | P1 |
| X17 | Vehicles | 3 (+9) | Blender `vehicle` template (`tools/blender/bkit/templates.py`) | MISSING (runtime) | `GameKit/Vehicles.luau` + SceneKit chassis plan | P1 |
| X18 | Building / placement grid | 3 (+4) | `ProcGen/Grid.luau` (layout time) | MISSING | `GameKit/PlacementGrid.luau` | P1 |
| X19 | Leaderboards | 8 | checklist `references/ranked-and-leaderboards.md` | MISSING | `GameKit/Leaderboard.luau` | P1 |
| X20 | Input mapping (IAS) | 20 | none | MISSING | `GameKit/InputMap.luau` | P0 |
| X21 | Movement abilities | 8 | `Creator/MovementProfile.luau` (planar preview maths), `Measure.ENGINE` | WEAK | `GameKit/Abilities.luau` | P1 |
| X22 | Interaction prompts | 11 | none | MISSING | `GameKit/Interact.luau` | P1 |
| X23 | UI kit | 20 | `Runtime/NativeUI.luau`, `Creator/UI.luau` (fixture-grade) | PARTIAL | `packages/UIKit/` | P0 |
| X24 | Cutscenes / sequences | 3 (+14) | `SceneKit/Camera.luau` (capture framing) | MISSING | `GameKit/Sequence.luau` | P1 |
| X25 | Tutorial / onboarding | 20 | workbench-scoped record `workflow-onboarding-evidence` only | MISSING | `GameKit/Onboarding.luau` | P1 |
| X26 | Settings (persisted) | 20 | `Creator/UI.luau` `setVolume` / `setReducedMotion` (not persisted) | PARTIAL | `GameKit/Settings.luau` | P2 |
| X27 | Notifications / toasts | 20 | none | MISSING | `GameKit/Toasts.luau` + UIKit Toast | P2 |
| X28 | Analytics event schema | 20 | `fixtures/analytics/` inputs only (gap-matrix Q08) | MISSING | `GameKit/Telemetry.luau` | P1 |
| X29 | Monetization sandbox + policy | 20 | `Runtime/ReceiptLedger.luau`, `RobloxReceiptAdapter.luau`, `CommerceCatalog.luau`; guards ask on prompts | PARTIAL | catalog schema, `PromptAdapter`, odds disclosure, `PolicyGate` | P1 |
| X30 | Live-ops (events, rotating shop, season pass) | 8 | checklist `references/liveops-events-and-shop.md` | MISSING | `GameKit/LiveOps.luau` | P2 |
| X31 | Crafting / gathering | 3 | none | MISSING | `GameKit/Crafting.luau` | P2 |
| X32 | World state (day/night, weather) | 4 | `SceneKit/Lighting.luau` static profiles | PARTIAL | `GameKit/WorldCycle.luau` | P2 |
| X33 | Avatar customization / dress-up | 2 (+9) | none | MISSING | `GameKit/Outfits.luau` | P2 |

**Pipeline and tooling rows.**

| ID | Item | Factory today | Status | Proposed deliverable | Priority |
|---|---|---|---|---|---|
| P-1 | Course, track and lane generators (obby, tower, race loop, TD lanes, micro-arenas) | none | MISSING | `ProcGen/Course.luau` + `Validate.course` | P1 |
| P-2 | Blender gameplay-prop kits, pet and accessory templates, icon renderer | 13 templates, no icons | PARTIAL | new `bkit` templates + `factory.py icons` | P1 |
| P-3 | Animation pipeline 2026 (clip sets, local import, graphs, adaptive) | `ops.keyframe_clip`, inspector | PARTIAL | bkit clip sets + skill update | P1 |
| P-4 | Audio backend on the Audio API | `Runtime/NativeAudio.luau` uses SoundGroup | OUTDATED | Audio API backend | P1 |
| P-5 | VFX and game-feel recipe library | neutral recipes and pooling | PARTIAL | `GameKit/Feedback.luau` + recipe catalogue | P1 |
| P-6 | Genre playbooks | 11 legacy checklists, 9 genres uncovered | WEAK | 12 new references + rewrite of the 11 | P1 |
| P-7 | Genre vertical-slice fixtures + starter packages | none | MISSING | `fixtures/slices/*`, starter `--packages GameKit UIKit` | P1 |
| P-8 | In-engine test runner on the PC | MCP only | MISSING | `tools/studio_run.py` (Studio CLI) | P1 |

**Summary:**
- None of the 33 cross-genre systems exists complete.
- Seven are partial or weak: X02, X03, X21, X23, X26, X29 and X32.
- The other 26 are missing.

This matches gap-matrix row Q07 ("no movement, combat, inventory or quest system").

## 8. Proposed kit and verification tiers

**Kit rules** (SETUP_ONLY-compatible):
1. **Two packages.** `packages/GameKit/` holds gameplay systems and `packages/UIKit/` holds components. Both are content-free:
   - every item, currency, price, odds table, wave or quest is data supplied by the game repository;
   - fixtures use `SETUP_ONLY_*` ids and placeholder numbers;
   - no default prices or drop rates.
2. **Pure core plus a thin adapter**, following the existing `ReceiptLedger` / `RobloxReceiptAdapter` pattern:
   - the core takes an injected clock, an RNG (`ProcGen/Rng.luau`) and a store, never touches services, and runs identically in Lune and Studio;
   - the adapter (`*Roblox.luau`) binds services such as DataStore, MemoryStore, Pathfinding, Teleport, IAS and AnalyticsService.
3. **Server Authority readiness.** Simulation-relevant cores expose a step function that can be bound with `RunService:BindToSimulation`, use `time()`, read input only through IAS actions, and keep replicated state within 64 attributes per instance.
4. **Fakes.** Shared fakes live in `tests/fakes/`:
   - `FakeDataStore`, with two simulated servers, throttling, crash-before-release and lock expiry;
   - `FakeMemoryStore`;
   - `FakeClock`;
   - `FakePolicy`.
5. **Scenario bots.** `tests/gamekit/scenarios/*.luau` run N seeded bots through a system for M rounds and assert invariants (conservation, no duplicates, no stuck states). Their result hashes join the fixture goldens, so behaviour changes are intentional, as with `--update-golden`.
6. **Starter.** `tools/new_project.py` offers GameKit and UIKit through `--packages`. They stay opt-in until their Studio adapters are verified.

**Verification tiers.**

| Tier | Where | What it proves |
|---|---|---|
| T0 | Linux container / CI: `lune run tests/run.luau <spec>` | Core logic, invariants, determinism, fuzz and migration chains |
| T1 | Container / CI: `rojo build` of `fixtures/gamekit.project.json` and `fixtures/uikit.project.json`, then deserialisation in Lune | Every require resolves; places build |
| T2 | Container / CI: headless `bpy` (`factory.py`) | Blender kits, clip sets, icons and their QA |
| T3 | Owner's PC with Studio on the unpublished diagnostic place: MCP (`execute_luau`, `start_stop_play`, Server & Clients, `screen_capture`, input simulation), Device Simulator, Party Simulator, or Studio CLI RunScript with `--localPlaceFile` | Adapters on the real engine, multi-client replication, UI at device sizes, Pathfinding and shapecasts |
| T4 | A published private test universe in a future game repo, only after explicit authorization | Teleports, live Party API, AnalyticsService delivery, real DataStores, purchase prompts. BLOCKED_EXTERNAL in this factory |

## 9. Summary

**Selected.**
- References and design constraints:
  - the Roblox genre taxonomy and Charts sorts (research only);
  - Server Authority and the Input Action System;
  - the 2026 animation stack (Animation Graphs, Adaptive Animation, Clip Editor local import, `RegisterKeyframeSequence`);
  - UI Styling and Styling Transitions;
  - the Audio API objects;
  - the player-data and purchasing reference architecture;
  - the cross-server services as adapter targets;
  - PolicyService and the paid random items rules;
  - PathfindingService and WorldRoot queries.
- Read-only references: the feature packages and templates.
- ProfileStore as a behavioural reference.
- The Studio CLI RunScript route for the PC.
- Not yet implemented:
  - GameKit and UIKit;
  - ProcGen Course;
  - the bkit kits, clip sets and icons;
  - the Audio API backend;
  - the 12 genre playbooks;
  - the slice fixtures;
  - `tools/studio_run.py`.

**Rejected.**
- Chickynoid (superseded by Server Authority).
- ShapecastHitbox (native queries suffice).
- FastCastRedux (repo 404).
- Lyra for now.
- Creator Store cutscene plugins.
- Automated chart scraping in gates.

**Revisit (with trigger).**
- Lyra: when it reaches 1.0.
- Cmdr: in a game repo, as a Studio-only debug tool.
- Feature-package insertion: in a game repo, through asset intake.
- ProfileStore as a dependency: a game repo's choice.
- RDC Scene Generator and Turn-Based Notifications: when released with docs.

**Follow-ups for the coordinator** (not done here, because this pass writes one file):
- run `python3 tools/knowledge_index.py`;
- cite this doc in gap-matrix rows Q07, Q08 and R01/R02 (NativeAudio OUTDATED), and add rows for the P0 systems;
- consider a guard rule that denies Studio CLI `--task RunScript` combined with `--placeId`.

## Sources (all fetched 2026-10-06)

- Taxonomy and charts:
  - https://create.roblox.com/docs/en-us/production/publishing/experience-genres.md
  - https://devforum.roblox.com/t/introducing-improved-genres-and-new-subgenres/3173148 (lead, not read)
  - `https://apis.roblox.com/explore-api/v1/get-sorts?sessionId=<uuid>&device=computer&country=all`
  - `https://apis.roblox.com/explore-api/v1/get-sort-content?sessionId=<uuid>&sortId=<top-playing-now|top-trending|top-revisited>&device=computer&country=all`
  - `https://games.roblox.com/v1/games?universeIds=<up to 6 ids>`
  - `https://apis.roblox.com/search-api/omni-search?searchQuery=<q>&sessionId=<uuid>&pageType=all`
- Server Authority and input:
  - https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993
  - https://create.roblox.com/docs/en-us/projects/server-authority.md
  - https://create.roblox.com/docs/en-us/input/input-action-system.md
- Animation:
  - https://create.roblox.com/docs/en-us/animation/graph-editor.md
  - https://devforum.roblox.com/t/full-release-animation-graphs-create-complex-character-motion-visually/4739840
  - https://devforum.roblox.com/t/full-release-adaptive-animation-use-one-animation-across-any-rig/4605672
  - https://devforum.roblox.com/t/full-release-animation-clip-editor-improved-importing-and-gltf-support/4260501
  - https://create.roblox.com/docs/en-us/reference/engine/classes/KeyframeSequenceProvider.md
  - https://devforum.roblox.com/t/weekly-recap-july-13-%E2%80%93-17-animation-graphs-go-live-5%C3%97-more-data-store-storage/4743286
- UI and audio:
  - https://devforum.roblox.com/t/studio-beta-styling-transitions/4646870
  - https://create.roblox.com/docs/en-us/ui/styling.md
  - https://create.roblox.com/docs/en-us/audio/objects.md
- Data and services:
  - https://create.roblox.com/docs/en-us/cloud-services/data-stores/player-data-purchasing.md
  - https://create.roblox.com/docs/en-us/cloud-services/data-stores.md
  - https://create.roblox.com/docs/en-us/cloud-services/memory-stores.md
  - https://create.roblox.com/docs/en-us/players/leaderboards.md
  - https://create.roblox.com/docs/en-us/projects/teleport.md
  - https://create.roblox.com/docs/en-us/matchmaking.md
  - https://devforum.roblox.com/t/party-api-is-here-enable-connected-player-experiences-and-drive-deeper-engagement/3676068
  - https://devforum.roblox.com/t/beta-studio-party-simulator-play-test-your-party-based-logic/4037049
  - https://create.roblox.com/docs/en-us/production/analytics/custom-events.md
  - https://create.roblox.com/docs/en-us/production/analytics/funnel-events.md
- Monetization:
  - https://create.roblox.com/docs/en-us/production/monetization/paid-random-items.md
  - https://create.roblox.com/docs/en-us/production/monetization/developer-products.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/MarketplaceService.md
- Navigation and queries:
  - https://create.roblox.com/docs/en-us/characters/pathfinding.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/WorldRoot.md
  - https://create.roblox.com/docs/en-us/workspace/collisions.md
  - https://create.roblox.com/docs/en-us/workspace/raycasting.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/AvatarEditorService.md
- Reference content:
  - https://create.roblox.com/docs/en-us/resources/feature-packages.md
  - https://create.roblox.com/docs/en-us/resources/feature-packages/bundles.md
  - https://create.roblox.com/docs/en-us/resources/feature-packages/missions.md
  - https://create.roblox.com/docs/en-us/resources/feature-packages/engagement-rewards.md
  - https://create.roblox.com/docs/en-us/resources/templates.md
  - https://create.roblox.com/docs/en-us/resources/modules.md
  - https://create.roblox.com/docs/en-us/resources/the-mystery-of-duvall-drive/supporting-systems.md
- Tooling and roadmap:
  - https://create.roblox.com/docs/en-us/studio/command-line-interface.md
  - https://about.roblox.com/newsroom/2026/09/rdc-2026-the-world-needs-more-play
- Libraries:
  - https://github.com/MadStudioRoblox/ProfileStore
  - https://github.com/MadStudioRoblox/ProfileStore/releases
  - https://raw.githubusercontent.com/MadStudioRoblox/ProfileStore/main/wally.toml
  - https://madstudioroblox.github.io/ProfileStore/api/
  - https://github.com/paradoxum-games/lyra
  - https://github.com/paradoxum-games/lyra/releases
  - https://api.wally.run/v1/package-metadata/paradoxum-games/lyra
  - https://github.com/easy-games/chickynoid
  - https://github.com/TeamSwordphin/ShapecastHitbox
  - https://github.com/EtiTheSpirit/FastCastRedux (HTTP 404)
  - https://github.com/evaera/Cmdr
- Repo files read: `AGENTS.md`, `reports/gap-matrix.json`, `.agents/skills/roblox-genre-systems/` (SKILL.md and all 11 references), `.agents/skills/roblox-persistence-and-commerce/SKILL.md`, `.agents/skills/roblox-multiplayer-integrity/SKILL.md`, `.agents/skills/roblox-ui-ux-pass/SKILL.md`, `.agents/skills/roblox-animation-integration/SKILL.md`, `.agents/skills/roblox-level-design-review/SKILL.md`, `packages/*` headers, `tools/blender/bkit/templates.py`, `tools/hooks/guard_mcp.mjs`, `docs/architecture.md`, `docs/starter.md`, `knowledge/INDEX.md`, `knowledge/records/tools-options.json`.
