# Playbook: Social hub and cosmetics

Kind: genre
Covers: Social > (none)
Also: Entertainment > Showcase & Hub; Roleplay & Avatar Sim > Life

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no theme, items, numbers or monetization; every TBD belongs to the game's owner.

## Core loop as systems
- **Hangout space**: a hub with spots to gather, sit, pose and talk; small shared activities.
- **Self-expression**: emotes, poses, cosmetics, name tags or titles, photo spots.
- **Social actions**: friend finding, invites, gifting, shared activities, reactions.
- **Cosmetic progression**: unlocks from time, activities, events or purchases.
- **Moderation surface**: chat, reports, blocking, personal space.

## Kit modules
- `GameKit/Outfits`, `GameKit/OutfitsRoblox`: avatar customisation and saved looks.
- `GameKit/Inventory`, `GameKit/ItemDefs`: owned cosmetics and titles.
- `GameKit/Interact`, `GameKit/Zones`: seats, pose spots, activity areas.
- `GameKit/AnimSet`, `GameKit/AnimSetRoblox`: emotes and poses in the standard slots plus `action_1..action_8`.
- `GameKit/LiveOps`, `GameKit/Streaks`: timed cosmetics and return rewards.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): any player-written text (names, signs, bios).
- `GameKit/Moderation`, `GameKit/ModerationRoblox` (T4): owner-run bans in live games.
- `GameKit/PartyRoblox`: party-aware joins.
- `UIKit/Components/Grid`, `UIKit/Components/Tabs`, `UIKit/Components/Toast`: wardrobe, menus, notifications.
- `SceneKit/Layout`, `SceneKit/Props`: hub layout and seating.

## Data to author
- Hub layout: zones, seating, activity spots, photo spots (TBD).
- Cosmetic catalogue: item keys, slots, unlock sources (TBD; catalog/1 for anything sold).
- Emote and pose list mapped to `action_1..action_8` slots (TBD).
- Title and badge rules (TBD).
- Event calendar for timed cosmetics (TBD).

## Authority and abuse risks
- **Cosmetic spoofing**: equipped items are checked against server-owned inventory; the client cannot equip unowned items.
- **Text**: every player-written string is filtered before others see it (`GameKit/TextFilter`); unfiltered text is a removal risk.
- **Harassment**: blocking hides the blocked player's text and interactions; personal-space options (TBD).
- **Gifting**: gifts are server transactions with rate limits and checks against `IsPaidItemTradingAllowed` when paid items move.
- **Emote spam**: rate-limit social actions per player (`GameKit/RateLimit`).

## Performance pitfalls
- Many detailed avatars in one place: cap server size for the hub, use level-of-detail for distant characters.
- Per-player name tags and effects: pool billboards, hide beyond a distance.
- Animations: at most 8 playing tracks per Animator under Server Authority; layered emotes must respect that.

## Policy notes
- "Social hangouts" is a Maturity & Compliance questionnaire category; romance and dating content are not allowed (Community Standards).
- External links are not allowed in-game; only the Social Links feature (release research, section 1).
- Voice and camera are experience settings under Communication; age and eligibility rules apply (check before relying on them).
- Text filtering is mandatory for user text that others can see.

## Test checklist
- [ ] Equipping an unowned cosmetic through a forged remote is refused.
- [ ] Every player text field passes through the filter path before display (static grep plus a spec of the routing).
- [ ] Blocking hides the blocked player's messages and interactions on the blocker's client.
- [ ] Seats and pose spots release correctly when a player leaves or resets.
- [ ] A full server of avatars stays inside the frame-time budget on a low-end device profile (`Diagnostics/PerfProbe`, T3).
- [ ] Timed cosmetics appear and expire at the configured UTC times (`GameKit/LiveOps` spec).

## Design questions (TBD)
- TBD: Which shared activities exist inside the hub?
- TBD: How are cosmetics obtained: time, activities, events, purchases?
- TBD: Is there player-written content (signs, bios, names)?
- TBD: Are voice or camera features part of the experience?
- TBD: Server size and whether friends are placed together?

## Reference systems
- Roblox developer modules Emote Bar, Profile Card, Photo Booth, Selfie Mode, Friends Locator, Spawn With Friends and Social Interactions as read-only references ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- Text filtering, chat and social links in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1.
- Systems X22, X27 and X33 in the genre coverage research.
