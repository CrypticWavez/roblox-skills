# Playbook: Avatar shopping (catalogue browsing, try-on, outfits)

Kind: genre
Covers: Shopping > Avatar Shopping
Also: Roleplay & Avatar Sim > Dress Up

A neutral systems reference: it maps the genre to kit modules, data, risks and checks. It picks no items, layout, numbers or monetization; every TBD belongs to the game's owner. The items here are Roblox Marketplace items owned by their creators, not the experience's own items.

## Core loop as systems
- **Browse**: search and filter the Roblox avatar catalogue (categories, creators, price ranges set by the catalogue).
- **Try on**: preview items on the player's avatar or a mannequin without owning them.
- **Compose**: build full outfits, compare, undo, save looks.
- **Buy**: prompt the Roblox purchase of a Marketplace item or bundle (single or bulk); the experience never sets those prices.
- **Wear and share**: apply owned items, save outfits to the player's account where the API allows, show looks to others.

## Kit modules
- `GameKit/Outfits`, `GameKit/OutfitsRoblox`: outfit composition, try-on and applying a look to the avatar.
- `GameKit/CommerceRoblox`: purchase prompts and runtime price reads for catalog/1 entries; Marketplace item prompts follow the same flow (check its API covers them before relying on it); the factory hooks ask before any prompt.
- `GameKit/PolicyGate`, `GameKit/PolicyGateRoblox`: per-player policy flags, fail closed.
- `GameKit/RateLimit`, `GameKit/Retry`: catalogue search and prompt request limits; retries for web-backed calls.
- `GameKit/PlayerData`: saved looks inside the experience.
- `GameKit/TextFilter`, `GameKit/TextFilterRoblox` (T4): names for saved looks.
- `UIKit/Components/VirtualList`, `UIKit/Components/Grid`, `UIKit/Components/ShopCard`, `UIKit/Components/ConfirmDialog`: large result lists, item cards, purchase confirmations.
- `GameKit/Telemetry`: purchase-intent events (kit-event/1; AnalyticsService delivery is T4).

## Data to author
- Category and filter layout (TBD).
- Try-on rules: what can be previewed together, mannequin or own avatar (TBD).
- Saved look format and slot count (TBD).
- Featured lists, if any, as data from the owner (TBD).

## Authority and abuse risks
- **Prompt spam**: rate-limit purchase prompts per player; prompts only from explicit player actions.
- **Try-on as ownership**: preview never grants; equipping checks ownership through the platform.
- **Misleading listings**: labels and prices come from the catalogue API, never typed by the experience.
- **Search abuse**: limit query rate and length; filter any search text shown to others.

## Performance pitfalls
- Thousands of thumbnails: virtualise lists and load images on demand.
- Applying full outfits repeatedly: debounce try-on and apply a description once per change.
- Catalogue API calls are web requests with limits: cache results and back off with `GameKit/Retry`.

## Policy notes
- Purchases of Marketplace items go through Roblox prompts (`MarketplaceService`, including `PromptBulkPurchase`); the factory guards ask before any prompt and deny completed purchases ([genre coverage](../../../../docs/research/genre-coverage-2026-10.md), section 5).
- PolicyService flags are read per player through `GameKit/PolicyGate` and fail closed; which flags apply to Marketplace prompts is UNVERIFIED here (release research, section 1e lists them).
- Avatar Editor permissions (saving outfits to the account) prompt the player; check the current AvatarEditorService rules before designing around them.
- No misleading metadata or prices (Community Standards).

## Test checklist
- [ ] Prompts fire only from player actions and stay under the rate limit.
- [ ] Try-on never changes ownership; removing a preview restores the previous look exactly.
- [ ] Every price and label shown comes from the catalogue response, not authored text.
- [ ] Policy flags that deny purchases hide or disable buy buttons (fail closed with a fake policy).
- [ ] Search and browse stay inside the frame budget with large result pages.
- [ ] Saved looks restore after rejoin and mark items the player no longer owns.

## Design questions (TBD)
- TBD: Own avatar, mannequins, or both for try-on?
- TBD: Which filters and categories?
- TBD: Are saved looks shared with other players?
- TBD: Does the experience feature any items, and who chooses them?
- TBD: Is there anything to do besides shopping (photo spots, social areas)?

## Reference systems
- AvatarEditorService and MarketplaceService pages in the genre coverage research sources; developer modules Merch Booth and Photo Booth as read-only references (same research, section 5).
- PolicyService flags in the [release research](../../../../docs/research/release-monetization-analytics-2026-10.md), section 1e.
- System X33 in the genre coverage research; skill `roblox-persistence-and-commerce`.
