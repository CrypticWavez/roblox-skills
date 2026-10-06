# Playbook: Dress up and fashion (outfits, themes, judging)

Kind: genre
Covers: Roleplay & Avatar Sim > Dress Up
Also: Shopping > Avatar Shopping

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no themes, items, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Round** (competitive dress up): a prompt or theme, a timed dressing phase, a showcase (runway), voting, results.
- **Wardrobe**: browse and combine items (clothing, accessories, hair, makeup, colours), preview, save looks.
- **Showcase**: walk a runway or pose in a spotlight with camera moments.
- **Voting**: players rate each other; results rank entries and grant rewards.
- **Collection** (free dress up): unlock items over time or by events; save outfits; photo moments.

## Kit modules
- `GameKit/Outfits`, `GameKit/OutfitsRoblox`: outfit composition, saved looks and applying them to the avatar.
- `GameKit/VotingRound`: submissions, ballots, anti-self-vote, tie breaks, seeded order.
- `GameKit/RoundLoop`, `GameKit/RoundLoopRoblox`: dressing, showcase, voting and results phases.
- `GameKit/Inventory`, `GameKit/ItemDefs`: owned wardrobe items and unlock sources.
- `GameKit/LiveOps`, `GameKit/SeasonTrack`: timed items and themes.
- `Cinematics/Cinematics`, `Cinematics/CinematicsRoblox`: runway camera sequences.
- `GameKit/AnimSet`: poses and walks in action slots.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): any player-written outfit names or theme suggestions.
- `UIKit/Components/Grid`, `UIKit/Components/VirtualList`, `UIKit/Components/Tabs`: large wardrobes that stay fast.
- `SceneKit/Lighting`: stage and runway lighting profiles.

## Data to author
- Wardrobe catalogue: item keys, slots, layering order, colour channels, unlock source (TBD).
- Theme list: labels only, picked by the owner (TBD).
- Round timings: dressing, showcase per player, voting (TBD).
- Voting rules: scale, who can vote, minimum ballots, tie break (TBD).
- Rewards per placement (TBD).

## Authority and abuse risks
- **Vote manipulation**: no self-votes, one ballot per entry per voter, server-side tally (`GameKit/VotingRound`); friends voting each other up is a design question (TBD).
- **Unowned items**: equipping checks server-side ownership; preview of unowned items is display-only.
- **Leaving to avoid a low score**: results are computed when voting ends, with a rule for leavers.
- **Text**: theme suggestions or outfit names are filtered.

## Performance pitfalls
- Wardrobes with hundreds of items: virtualised lists and thumbnails loaded on demand.
- Applying full outfits to many avatars at once (showcase): stagger application.
- Layered clothing on many characters: budget per server; check on low-end devices.

## Policy notes
- Layered clothing and accessories need cages (`_InnerCage`, `_OuterCage`); the factory has no licensed template cages yet (Blender research).
- Uploading avatar items to the Marketplace is outside this factory (the hooks deny uploads); in-experience unlocks are developer products or passes routed through `GameKit/CommerceRoblox`.
- Voting must not reward Robux or real-value prizes (Community Standards).
- Body and outfit content must stay within the Maturity & Compliance answers.

## Test checklist
- [ ] Voting: self-votes refused, one ballot per entry, ties broken by the seeded rule (`GameKit/VotingRound` spec).
- [ ] Round phases transition on time, including when the dressing player leaves.
- [ ] Equipping an unowned item through a forged remote is refused; preview never grants.
- [ ] Saved looks restore after rejoin and skip items no longer owned.
- [ ] Wardrobe scroll stays inside the frame budget with the full catalogue (`UIKit/Components/VirtualList`).
- [ ] Runway sequence can be skipped and respects reduced-motion settings.

## Design questions (TBD)
- TBD: Competitive rounds with voting, free dress up, or both?
- TBD: How are wardrobe items obtained?
- TBD: Who votes, on what scale, and are votes anonymous?
- TBD: Are themes fixed, rotating or suggested by players?
- TBD: Can players buy items they saw on others?

## Reference systems
- Avatar Editor and catalogue APIs in the [genre coverage research](../../../../docs/research/genre-coverage-2026-10.md) sources; cages and accessory limits in the [Blender research](../../../../docs/research/blender-animation-pipeline-2026-10.md).
- Developer modules Photo Booth and Selfie Mode as read-only references (genre coverage research, section 5).
- System X33 (avatar customisation) in the genre coverage research.
