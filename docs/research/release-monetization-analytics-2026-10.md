# Release, monetization and analytics research: from finished build to published candidate (verified 2026-10-06)

**Scope.** What "ready to publish" means on Roblox today, and what this SETUP_ONLY factory should ship so that a future game repository can get from a finished build to a public, measurable, monetizable release. It covers:
- the publish path and experience settings;
- the Maturity & Compliance questionnaire and audience rules;
- store-page assets;
- localization, text filtering and chat;
- PolicyService and Community Standards blockers;
- versioning, rollback and ownership;
- AnalyticsService and the Creator Hub dashboards;
- the monetization APIs;
- what Roblox has published about discovery.

It ends with three designs: a machine-checkable release-readiness checklist, an analytics events module with a test double, and the owner-only publish step.

It extends [tooling-2026-10.md](tooling-2026-10.md) and [tooling-2026-10-addendum.md](tooling-2026-10-addendum.md). The addendum's section I already rejects Open Cloud publishing for agents, and this pass does not repeat that analysis. The parallel `genre-coverage-2026-10.md` pass names the analytics row X28 (`GameKit/Telemetry.luau`) and the monetization row X29 (`PromptAdapter`, `OddsTable`, `PolicyGate`). This doc gives those rows their API facts and designs, and uses the same module names. It chooses no genre, theme, economy, price or product.

**Method.**
- Every source was fetched on 2026-10-06; the full list is at the end.
- Primary sources:
  - create.roblox.com through the `.md` page variants listed in `/docs/llms.txt`;
  - DevForum announcements by Roblox staff;
  - GitHub repo pages and the Rojo docs.
- DevForum bug reports by community members are leads, not facts, and are labelled as such.
- Pages were read through a summarising fetcher, so quotes are short, and two pages that disagree are both reported.
- No revenue, retention or ranking claims of my own. Metric definitions are Roblox's.
- Nothing was installed, bought, signed up for, published or uploaded.

**Decision rule** (same as the addendum):
- **SELECT**: adopt inside SETUP_ONLY as a reference, a design constraint, a PC tool or code to write here.
- **REJECT**: do not adopt. This covers anything that publishes, uploads, spends or writes production data.
- **REVISIT**: the decision waits for a stated trigger, usually a future game repository.

**Workbench leads re-checked.** The two workbench-scoped records, `analytics-offline-session-foundation` and `analytics-release-commercial-review`, cite pages that were re-read here:
- publish, Kids and Select, regional pricing and paid random items: still current, and the facts are below;
- Creator Rewards: now replaces Engagement-Based Payouts;
- custom events and funnel events: still "published games" and server only.

The record's claim that Roblox funnels back-fill earlier steps was **not** found on the current funnel page (UNVERIFIED). DevEx was not re-checked.

---

## 1. What "ready to publish" means (platform facts)

### 1a. Publish path, audience and account requirements

| Fact | Source (docs page, last updated) |
|---|---|
| A new game is published from Studio with File > Publish to Roblox. Extra places are added with File > Publish to Roblox As > "Add as a new place". | `production/publishing/publish-games-and-places` (2026-10-02) |
| Audience levels: **Private** (default; users with Edit permission), **Limited** (playtesters, friends or community members), **Public**. They are set in Creator Hub under Configure > Settings. | same |
| To make a game Public or Limited and reach **16+ and Trusted Friends**, the creator needs an account in good standing that is at least 2 days old, an age check ("facial age estimation or government ID"), and a completed content maturity & compliance questionnaire. | same |
| To reach **all ages, including Kids and Select**, the creator also needs account verification, 2FA, and either 2 consecutive months of Roblox Plus/Premium or a refundable fee. The fee is 1,000 Robux, or 50,000 Robux for expedited review. The game must also pass evaluation. | same |
| The fee refund conditions disagree between pages. The publish page says the fee is refunded if the game keeps "25 highly engaged players" for 60 days. The Kids and Select page says evaluation completes at "250 unique plays by highly engaged age-checked users within a 60-day window". UNVERIFIED which one applies to what. | publish page; `production/publishing/kids-and-select` (2026-10-02) |
| Kids covers ages 5-8 and Select covers 9-15. A new game first runs a trial "only to age-checked 16+ users". Kids needs a Minimal or Mild maturity label; Select also allows Moderate. | `kids-and-select` |
| Limit: "5 private games that have never been public" can be made public per day. | publish page |
| Changes in Version History are restored either from Studio (Open Local Copy, then Save to Roblox As) or from Creator Hub (Restore). Restoring "does **not** automatically publish the changes". Published saves require version notes. No API is documented. | `projects/version-history` (2026-10-02) |
| Live updates: "players aren't immediately removed from old versions". Restart offers "Restart only servers with outdated versions" and a 1-60 minute delay. Roblox's advice for risky changes: "deploy early, hide content behind a config, and then change the config value to release your new content". | `projects/update-games` (2026-10-02) |
| Ownership: a game can be transferred to a group where you have publish access. Its ids and URL stay the same. The game "becomes private and all servers close" on acceptance, a game cannot be re-transferred for 30 days, and requests expire after 7 days. Which products, passes, data stores and badges move with it is not stated. | `projects/game-ownership-transfer` (2026-10-02) |

### 1b. Experience settings that gate release

| Setting | Fact | Source |
|---|---|---|
| Maturity & Compliance Questionnaire | Categories: violence, blood, fear, crude humour, unplayable gambling, strong language, romance, alcohol, social hangouts, free-form user creation, sensitive issues, paid random items and trading, media sharing and content feeds, AI interactions. "If an experience does not have accurate or all content maturity information, Roblox restricts the playability of the experience on the platform for all players." Repeated inaccuracy brings moderation consequences. Restricted content is 18+ (age-verified) and "unplayable" in some regions, such as Korea, Saudi Arabia and Türkiye. | `production/promotion/content-maturity` (2026-10-02) |
| Genre and subgenre | The genre is required and the subgenre optional. The genre feeds "genre-specific top and trending sorts". "You can only change genres once every three months." Roblox corrects inaccurate genres itself. | `production/publishing/experience-genres` (2026-10-02) |
| Studio Experience Settings | Basic Info: content maturity label, icon, screenshots and videos, playable devices. Communication: mic and camera. Permissions: playability. Monetization: badges, paid access, private servers, developer products. Security: Allow HTTP Requests, Secrets, Enable Studio Access to API Services, third-party sales and teleports, mesh/image APIs. Places: version history. Localization: source language, Automatic Text Capture, Use Translated Content, Automatic Translation. Other: Drafts Mode, Shutdown All Servers. | `studio/experience-settings` (2026-07-30) |
| Server size | `Players.MaxPlayers` "can only be set through a specific place's settings on the Creator Dashboard". `PreferredPlayers` is the matchmaker fill target and is below MaxPlayers. The upper limit was not found (UNVERIFIED). | `reference/engine/classes/Players` |
| Private servers | Allowed only once the game is public, and free or paid. "Changing the price of private servers **cancels all active subscriptions**." They cannot be combined with paid access. Under-13s may be blocked by parental settings. | `production/monetization/private-servers` (2026-10-02) |
| Paid access | 25 to 1,000 Robux. Needs a verified email and an account 30+ days old. Payouts are held in escrow for up to 7 days, and "Refunds are not available". The game must be public, cannot have private servers, and is not on Xbox. The revenue share is not stated. | `production/monetization/paid-access-robux` (2026-10-02) |
| Communication | An "Allow Strong Language" toggle relaxes text chat for older audiences. Assets and metadata still cannot contain strong language. | `projects/configure-games` (2026-10-02) |

### 1c. Store-page assets (icon, thumbnails, video, badges, passes)

| Asset | Spec and rules | Source |
|---|---|---|
| Icon | Square, on a 512x512 template; it is shown down to 150x150. It must pass asset moderation. The file format is not stated. | `production/publishing/experience-icons` (2026-10-02) |
| Thumbnails | "16:9 aspect ratio", ideally 1920x1080, in .jpg, .gif, .png, .tga or .bmp, kept "under 3 MB" (stated in the personalization section). Up to 10 images or videos. **Thumbnail personalization** starts with 2 or more active thumbnails (Roblox recommends 2-5) and shifts impressions to the winner for each group. | `production/publishing/thumbnails` (2026-10-02) |
| Video | Quota of 3 uploads per month; not supported on Xbox, PlayStation or VR. Must show authentic in-game content. Not allowed: misrepresented gameplay, artificial visuals, real-world footage, spoken audio or music with lyrics, and text, claims or advertisements. Allowed: camera work, minor post-processing and Roblox catalogue music. Length, resolution and file-size limits are not published (UNVERIFIED). | same |
| Badges | 512x512 with a circular crop. 5 free per game per 24 h, then "each additional badge costs 100 Robux". Award only enabled badges, so check `GetBadgeInfoAsync` first. | `production/publishing/badges` (2026-10-02) |
| Pass icon | Up to 512x512, in .jpg, .png or .bmp. Passes are created after publishing. | `production/monetization/passes` (2026-10-02) |
| Social links | Facebook, Twitter, YouTube, Twitch, Discord, Guilded and a Roblox community; up to 3. Only users age-checked as 16+ see them, and the creator needs a 16+ age check. "You **cannot** share social media links directly within a game." | `production/promotion/social-media-links` (2026-09-23) |

### 1d. Localization, text filtering and chat

| Area | Fact | Source |
|---|---|---|
| Automatic translation | Translates blank entries of the localization table and never overwrites existing ones. Automatic Text Capture collects `AutoLocalize` UI strings; capture takes "up to a few days" in live play or 1-2 minutes in Studio. There are 18 languages, monthly character quotas, and entries can be locked. Text in images, default leaderboards and chat, and platform-pulled pass and badge names are not captured. | `production/localization/automatic-translations` (2026-10-02) |
| Dynamic content | The Open Cloud `TranslateText` is "in early development and is subject to change". It is server only and RCC-authenticated: "You must deploy code to a test instance to test the API from Studio." | `production/localization/auto-translate-dynamic-content` (2026-10-02) |
| Rojo | "Any file with the `csv` extension is transformed into a `LocalizationTable` instance" in Roblox's import/export format (Key, Source, Context, Example, then locale columns). | rojo.space `docs/v7/sync-details` |
| Text filtering | Filter any displayed text "that you don't have explicit control over": TextBox input, generated text, web content and stored text. Use `TextService:FilterStringAsync(text, fromUserId, context?)`, then `GetNonChatStringForBroadcastAsync` or `GetNonChatStringForUserAsync`. Filter after submit, not per character. "If Roblox receives reports or automatically detects that your game doesn't apply text filtering, then the system removes the game until you add filtering." `FilterStringAsync` "throws if `fromUserId` is not online". `FilterAndTranslateStringAsync` is deprecated. | `ui/text-filtering` (2026-10-01); `reference/engine/classes/TextService` |
| Chat | TextChatService "automatically filters chat messages". `CanUserChatAsync`, `CanUsersChatAsync` (server) and `CanUsersDirectChatAsync` (server, used with `TextChannel:SetDirectChatRequester()` for 1:1 channels under parental controls). Legacy chat migration deadline was 2025-04-30, with auto-migration from May 2025 (staff announcement 2025-01-13). | `chat/in-experience-text-chat` (2026-10-02); `reference/engine/classes/TextChatService`; DevForum 3376880 |
| Moderation of captures | `ModerationService` submits player screenshots and videos for review. It is "restricted to allow-listed universes". | `reference/engine/classes/ModerationService` |
| Bans | `Players:BanAsync` by default propagates bans to "suspected alternate accounts", can add an optional device block, and can be scoped to a place or the universe. `UnbanAsync` and `GetBanHistoryAsync` also exist. | `reference/engine/classes/Players` |

### 1e. PolicyService and Community Standards items that block games

**PolicyService.** `GetPolicyInfoForPlayerAsync(player)` returns:
- `AreAdsAllowed`;
- `ArePaidRandomItemsRestricted`;
- `IsContentSharingAllowed`;
- `IsEligibleToPurchaseCommerceProduct`;
- `IsEligibleToPurchaseSubscription`;
- `IsPaidItemTradingAllowed`;
- `IsPhotoToAvatarAllowed`;
- `IsSubjectToChinaPolicies`;
- `IsEndlessContentLoadAllowed`;
- `IsEndlessContentAutoplayAllowed`;
- `AllowedExternalLinkReferences` (legacy, always empty).

The class also has `CanViewBrandProjectAsync`. In Studio, the **Player Emulator** (Test menu, "Enable Test Profile") emulates locale and region, and the region "may impact other toggles" that follow `GetPolicyInfoForPlayerAsync()` (`studio/testing-modes`, 2026-10-02).

**Paid random items** (`production/monetization/paid-random-items`, 2026-10-02):
- Odds must be percentages that "sum to exactly 100%" and must be shown before purchase.
- Odds must update when an outcome can only be obtained once.
- Probability modifiers must be "numerically explained".
- When `ArePaidRandomItemsRestricted` is true, the game must apply one of six treatments: an unpaid path, a predetermined order, a direct purchase, hiding the item, blocking the purchase, or keeping the user out of the area.
- When `IsPaidItemTradingAllowed` is false, the game "must not allow them to access the ability to trade the resulting outcome of a paid random item or other paid items".

**Community Standards** (about.roblox.com, no date shown). These rules commonly block a release:
- "Deceptive, sensational, duplicative, or otherwise misleading content or metadata ... used to drive discoverability, monetization, or engagement".
- No external URLs "except by using the Social Links feature".
- No simulated or real gambling, and no Robux or real-value contests.
- IP takedowns, romance or dating, sexual content, extremism, and requests for personal information.

The two platform rules from 1b and 1d also block a release: an incomplete or inaccurate maturity questionnaire, and missing text filtering. Ads Manager adds that games whose "metadata and place files ... closely resemble existing games on Roblox are not prioritized for recommendations" (`production/promotion/ads-manager`, 2026-10-02).

## 2. Monetization APIs (2026 state)

| Area | Fact | Source |
|---|---|---|
| **Receipts: new API** | `MarketplaceService:BindReceiptHandler(transactionType: Enum.ReceiptType, handler, filter?)` returns a connection. Receipt types: `DeveloperProduct`, `RobuxTransferSender`, `RobuxTransferReceiver`. The handler returns `Enum.ReceiptDecision.Processed` or `NotProcessedYet`. Bound handlers take precedence over `ProcessReceipt`, and unmatched developer-product receipts "fall through" to the legacy `ProcessReceipt` callback. Receipt fields: `PurchaseId`, `PlayerId`, `PlaceIdWherePurchased`, `ReceiptType`, `ProductId`, `CurrencyType`, `CurrencySpent` and `TransferRequestId`. | `reference/engine/classes/MarketplaceService`; staff announcement 2026-05-04 (DevForum 4618396) |
| Receipts: legacy | `ProcessReceipt(receiptInfo): Enum.ProductPurchaseDecision` (`PurchaseGranted` / `NotProcessedYet`) is still documented and "highly recommended". `ProductPurchaseChannel`: `InExperience`, `ExperienceDetailsPage`, `AdReward`, `CommerceProduct`. | same; `reference/engine/enums/ProductPurchaseChannel` |
| Cross-game sales | "The ability to sell developer products and passes outside of the originating game or experience details page" ended on 2026-05-29. | DevForum 4618396 |
| Product info | `GetProductInfo` is **deprecated**; use `GetProductInfoAsync(id, infoType?)`, which batches concurrent calls. Other new and current APIs: `GetDeveloperProductsAsync`, `UserOwnsGamePassAsync` (cached, batched), `PlayerOwnsAssetAsync`, `OpenShop(player)` (Roblox's personalised shop overlay), `RankProductsAsync` (10/min), `RecommendTopProductsAsync` (5/min) and `GetUsersPriceLevelsAsync`. `PromptPremiumPurchase` is deprecated in favour of `PromptRobloxSubscriptionPurchase` (Roblox Plus). | `MarketplaceService` reference |
| Developer products | Created in Creator Hub after publishing; 1 to 1 billion Robux. Grant only from receipts, never from `PromptProductPurchaseFinished`. "Items for sale in test mode cost actual Robux." | `production/monetization/developer-products` (2026-10-02) |
| Passes | 1 to 1 billion Robux. Promoted passes are 50-800 Robux. Check ownership with `UserOwnsGamePassAsync` (pcall). | `production/monetization/passes` (2026-10-02) |
| Subscriptions | Ids look like `EXP-...`. Local-currency tiers are USD 2.99, 4.99, 7.99, 9.99 and 14.99 (needs ID or phone verification); Robux subscriptions start at 49 Robux. Benefits must be honoured, identical across platforms, and never moved off-platform. Unavailable in 12 countries (Argentina, China, Colombia, India, Indonesia, Japan, Russia, Taiwan, Türkiye, UAE, Ukraine, Vietnam). APIs: `GetUserSubscriptionStatusAsync`, `GetUserSubscriptionDetailsAsync`, `GetUserSubscriptionPaymentHistoryAsync`, `GetSubscriptionProductInfoAsync`, `PromptSubscriptionPurchase`, `UserSubscriptionStatusChanged`. | `production/monetization/subscriptions` (2026-10-02) |
| **Managed Pricing** | "Combines price optimization and regional pricing under a single opt-in". New games and items enrol automatically, and items can opt out. | `production/monetization/managed-pricing` (2026-10-02) |
| Regional pricing | Never more than a 70% discount. On by default for passes and Robux subscriptions; developer products need dynamic prices first. "If you have hard-coded the price into your game's UI, that number does not update." Before regional pricing for developer products, "Implement the `GetUsersPriceLevelsAsync` method to regulate item transfers"; do not cache it, and call it at join. **Dynamic Price Check** (Creator Hub, published games only, up to 5 test accounts, "Price pinned" or "Location pinned") finds hard-coded prices. | `production/monetization/regional-pricing` (2026-10-02) |
| Price optimization | Needs "at least 60,000 transactions over the previous 30 days". Tests run for about three weeks and need dynamic prices in code. Covers passes and developer products, not subscriptions. | `production/monetization/price-optimization` (2026-10-02) |
| Rewarded video ads | `AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)`, `CreateAdRewardFromDevProductId`, `ShowRewardedVideoAdAsync(player, reward, placementId?)` (server); grant "from your ProcessReceipt implementation". Eligibility: the creator is 13+ with ID and 2FA; the game is public with "At least 2,000 unique visitors per month", an approved questionnaire and no free-form user creation. Rewards cannot be random, cannot gate progress, and cannot be Robux. | `production/promotion/rewarded-video-ads` (2026-10-02); `reference/engine/classes/AdService` |
| Immersive ads | `AdGui` on parts, 8x4.5 to 32x18 studs, plus portal ads. Same 2,000-visitor threshold. "Hide, replace, or block ad content" for ineligible users through PolicyService. | `production/monetization/immersive-ads` (2026-10-02) |
| Robux transfers | Plus subscribers send 10-500 Robux, and the game earns 10%. Handled through `BindReceiptHandler` with the transfer receipt types. | `production/monetization/robux-transfers` (2026-10-02) |
| Creator Rewards | Daily engagement rewards and audience expansion rewards. "Engagement Based Payouts and Creator Affiliate programs have been discontinued and replaced with Creator Rewards." | `creator-rewards` (2026-10-02) |
| Best practices (Roblox's) | Durable vs consumable items; shops that are "integrated", "contextual" and "inviting"; "be accurate and truthful in your descriptions". | `production/game-design/monetization-foundations` (2026-09-30) |

**Studio purchase behaviour.**
- **Developer products and assets.** Studio purchases are simulated: "you won't be charged for in-game purchases made in Studio" (staff, 2016-07-12; DevForum 26974). This is old but still the documented basis for the repo's "test purchases" assumption in `docs/mcp.md`.
- **Subscriptions.** A community bug report (2026-06-10, DevForum 4676620; staff "assigned ... for further review"; still open on 2026-07-04 in the thread) says a Studio play-mode subscription prompt "proceeds to ask debit card information" and that "Proceeding through the purchase flow charges the debit card".
- **Robux transfers.** A community feature request (2026-05-09, DevForum 4625943) says transfers fail in Server & Clients and "aren't mocked" in Team Test.

Both reports are UNVERIFIED. The safe consequence is the same either way: see section 9.

## 3. Analytics (AnalyticsService and dashboards)

**AnalyticsService methods** (class reference):

| Method | Signature |
|---|---|
| `LogCustomEvent` | `(player, eventName, value?, customFields?)` |
| `LogEconomyEvent` | `(player, flowType: Enum.AnalyticsEconomyFlowType, currencyType, amount, endingBalance, transactionType: string, itemSku, customFields?)` |
| `LogFunnelStepEvent` | `(player, funnelName, funnelSessionId, step?, stepName, customFields?)` |
| `LogOnboardingFunnelStepEvent` | `(player, step, stepName, customFields?)` |
| `LogProgressionEvent` | `(player, pathName, status: Enum.AnalyticsProgressionType, level, levelName, customFields?)`, plus `LogProgressionStartEvent`, `LogProgressionCompleteEvent` and `LogProgressionFailEvent` |
| `LogJourneyEvent` | `(player, journeyName, nodeName, journeySessionId, customFields?)`. Non-linear paths, shown as Sankey diagrams |
| `GetPlayerSegmentsAsync` | `(player)`. Yields, server only. Returns `HasData`, `ActivePayerStatus`, `EngagementLevel`, `UserAcquisitionSource` and other coarse buckets, cached per server session |
| Deprecated | `FireEvent`, `FireCustomEvent`, `FireInGameEconomyEvent`, `FireLogEvent`, `FirePlayerProgressionEvent` |

**Environment.** "Events can only be sent from the server and in published games. Events can't be sent from the client or Studio" (custom, funnel and economy pages, 2026-10-01/02). The progression and journey methods have no guide page (both URLs return 404), so whether the same rule applies to them is UNVERIFIED (expected: yes).

**Limits** (`production/analytics/event-types`, custom-events, funnel-events, economy-events, custom-fields; 2026-10-01/02):
- Event counts:
  - 100 custom event names;
  - 10 funnels with 100 steps each;
  - only the 10 most recent `funnelSessionId`s per user per funnel are tracked;
  - a repeated step counts once.
- Custom fields:
  - up to 3 custom fields (`Enum.AnalyticsCustomFieldKeys.CustomField01..03.Name`);
  - the values "must be **strings**";
  - 8,000 combined values across the three fields, after which values are grouped as "Other".
- Economy:
  - transaction types are `IAP`, `Shop`, `Gameplay`, `ContextualPurchase`, `TimedReward`, `Onboarding`, plus custom types up to 20 in total (grouped as "Other" after 20);
  - item SKUs are grouped as "Other" after 100;
  - currencies: the economy page says "up to five currencies" and the event-types page says 10 resource types. They conflict, so design for **5**.
- Rate limit: "120 + (20 * CCU)" requests per minute per game.
- Data lag: charts populate in "up to 24 hours".
- Names: journey, progression and node names cannot be empty or contain commas, quotes or newlines, and journey names cannot start with `__` (class reference).

**Dashboards** (`production/analytics`, 2026-10-02):
- Home (DAU) and Realtime.
- Retention: D1, D7 and D30 by first-play cohort, in daily and weekly views.
- Engagement: average session time, "the total time users spend in your game divided by the number of sessions", and new-user first-session retention at X minutes.
- Monetization: payer conversion and ARPPU.
- Acquisition by source.
- Economy, Funnels, Explore (custom events) and Insights alerts.
- **Performance** by device, platform and **place version** with P10, P50 and P90. Charts need at least 100 DAU, and Roblox says to "filter by place version" to catch release regressions.

**Configs and experiments.** Experience configs are live key-values: up to 1,000 active, 100,000-character strings and JSON, publish in 15 s to 1 min or gradually over 15 min, with a History page for rollback. The API is `ConfigService:GetConfigAsync()`, `GetConfigForPlayerAsync(player)` (server only), `SetTestingValue` and `ClearTestingValue`. Staged values are visible in Studio play sessions.

Experiments are A/B tests on config keys (in-game, up to 2 variants plus control) or matchmaking tests (1 at a time). They run 14-60 days, report D1/D7 retention, playtime, ARPU and payer conversion, and need a `GetConfigForPlayerAsync` call per player. Both have been available to all creators since 2025-11-06 (staff announcement). Sources: `production/configs`, `production/experiments` (2026-10-02), `reference/engine/classes/ConfigService`, DevForum 4051385.

A community report of `GetConfigForPlayerAsync` hanging 30 s in games without configs was confirmed fixed by staff on 2026-06-23 (DevForum 4686600). The adapter should still pcall it and fall back to defaults.

**Open Cloud analytics** (staff, 2026-08-24, DevForum 4828676): Analytics Query API (read, `universe.analytics:read`, `https://apis.roblox.com/analytics-query-api/v1/universes/{UniverseId}/metrics`), plus Experiments, Thumbnail Personalization and Events APIs (read and write).

## 4. Discovery: what Roblox says

The sources are `discovery` (2026-10-02) and `discovery-faq` (2026-10-02). They are Roblox's statements, not mine.
- **Home "Recommended for You" works in two stages.** Retrieval uses "engagement, retention, and monetization". Ranking is personalised from users who found the game through recommendations.
- **Most important signals:**
  - play-through rate (PTR), "the rate at which users play your game after seeing it in the Recommended for You sort";
  - first play bounce rate (a negative signal);
  - play days per user over D1, D2-7 and D8-28;
  - playtime per user, capped at 60 min per day.
- **Secondary signals:** intentional co-play days, qualified play sessions (which filter "accidental clicks or quick bounces"), spend days and Robux spend per user.
- **Other channels do not count.** "Roblox doesn't count the engagement, monetization, or retention of users first acquired from ads, curation, friends, search, social media, or any other source in the ranking stage." A user acquired by an ad "will generally not subsequently see your game in RFY".
- **New games are not held back.** Early signals (PTR, bounce) "kick in immediately".
- **Traffic also moves for outside reasons.** These are updates, algorithm changes, seasonality and competitors.
- **Creator controls:**
  - accurate titles and descriptions, avoiding giveaway-led titles;
  - original thumbnails with personalization;
  - correct genre;
  - "Reusing an existing thumbnail alone shouldn't negatively affect discoverability".
- **Charts.** Staff describe only "Top Playing Now", as concurrent users (DevForum 3529809, 2025-03-05). How the other chart sorts are computed is not documented (UNVERIFIED). Genre sorts use the genre setting.
- **`RecommendationService` is not about Home.** It (`production/recommendation`, 2026-09-25) is an in-game recommender for a game's own items or levels. It warns against logging impressions more than once per session, or logging plays from external traffic ("ruin the accuracy").

**Consequence for the factory.** The Roblox-named signals map to telemetry that the factory can define without choosing a game:
- first-session events: load finished, first action, onboarding steps;
- session end;
- progression;
- economy.

The existing `fixtures/analytics/` events (`session_start`, `load_finished`, `first_action`, `onboarding_complete`, `core_loop_complete`, `offer_viewed`, `purchase_prompted`, `purchase_confirmed`, `economy_source`, `economy_sink`, `session_end`) already have this shape. The PTR and bounce figures themselves exist only in the Creator Hub dashboards.

---

## 5. Candidate records

### 5a. Facts

| Candidate | Official source | Publisher | Version | Last update | Maintenance | Licence | Price |
|---|---|---|---|---|---|---|---|
| AnalyticsService (custom, funnel, onboarding, economy, progression, journey, segments) | create.roblox.com/docs/reference/engine/classes/AnalyticsService | Roblox | engine (Studio 741 era) | guides 2026-10-01/02 | active; `Fire*` methods deprecated | Roblox Terms of Use | free |
| ConfigService + Experiments | create.roblox.com/docs/production/configs ; /docs/production/experiments | Roblox | GA for all creators 2025-11-06 | 2026-10-02 | active | Roblox Terms of Use | free |
| MarketplaceService 2026 receipt and pricing APIs (`BindReceiptHandler`, `GetProductInfoAsync`, `GetUsersPriceLevelsAsync`, subscription APIs, `OpenShop`) | create.roblox.com/docs/reference/engine/classes/MarketplaceService | Roblox | engine | `BindReceiptHandler` announced 2026-05-04 | active; `GetProductInfo` and `PromptPremiumPurchase` deprecated | Roblox Terms of Use | free (Roblox takes its fees on sales; not researched) |
| PolicyService | create.roblox.com/docs/reference/engine/classes/PolicyService | Roblox | engine | policy pages 2026-10-02 | active | Roblox Terms of Use | free |
| TextService + TextChatService | create.roblox.com/docs/ui/text-filtering ; /docs/chat/in-experience-text-chat | Roblox | engine | 2026-10-01/02 | active; legacy chat migrated in 2025 | Roblox Terms of Use | free |
| LocalizationTable via Rojo `.csv` + automatic translation | create.roblox.com/docs/production/localization ; rojo.space/docs/v7/sync-details | Roblox; rojo-rbx | engine; Rojo 7.7.x (pinned 7.7.0) | 2026-10-02 | active | Roblox terms; Rojo MPL-2.0 | free (translation quotas) |
| Studio Player Emulator, mock purchases, Device Simulator | create.roblox.com/docs/studio/testing-modes | Roblox | Studio | 2026-10-02 | active | Roblox terms | free |
| Creator Hub release surfaces (questionnaire, audience, genre, thumbnails and personalization, Managed Pricing, Dynamic Price Check, Version History, restart servers) | create.roblox.com/docs/production/publishing/publish-games-and-places and the pages in section 1 | Roblox | web | 2026-10-02 | active | Roblox terms | free; Kids and Select route needs Plus/Premium or a refundable fee |
| Discovery and analytics-dashboard docs | create.roblox.com/docs/discovery ; /docs/discovery-faq ; /docs/production/analytics | Roblox | docs | 2026-10-02 | active | Roblox terms (docs content CC-BY-4.0 per creator-docs, UNVERIFIED for served pages) | free |
| AdService (rewarded video) + immersive ads | create.roblox.com/docs/production/promotion/rewarded-video-ads ; /docs/production/monetization/immersive-ads | Roblox | engine | 2026-10-02 | active; `ShowVideoAd` decommissioned | Roblox terms | free (pays the publisher) |
| Open Cloud Place Publishing | create.roblox.com/docs/cloud/guides/usage-place-publishing | Roblox | v1 | 2026-10-02 | active | Roblox terms | free with API key |
| Open Cloud Analytics Query API | DevForum 4828676 | Roblox | v1 | announced 2026-08-24 | new | Roblox terms | free with API key |
| Open Cloud Experiments / Thumbnail Personalization / Universe PATCH | DevForum 4828676 ; create.roblox.com/docs/cloud/reference/Universe | Roblox | v1 / v2 | 2026-08-24 / unknown | new / active | Roblox terms | free with API key |
| Mantle | github.com/blake-mealey/mantle | blake-mealey | not shown | not shown | **"no longer maintained"** | MIT | free |
| rbxcloud | github.com/Sleitnick/rbxcloud | Sleitnick | v0.17.0 | 2025-03-23 | active, small | MIT | free |
| GameAnalytics Roblox SDK | github.com/GameAnalytics/GA-SDK-ROBLOX | GameAnalytics | 2.2.6 | 2025-02-25 | not archived | MIT (SDK); service terms not read | SDK free; the service needs a GameAnalytics account |
| Ads Manager (sponsored and search ads) | create.roblox.com/docs/production/promotion/ads-manager | Roblox | web | 2026-10-02 | active | Roblox terms | paid (ad credits) |
| RecommendationService | create.roblox.com/docs/production/recommendation | Roblox | engine | 2026-09-25 | beta status not stated | Roblox terms | free |

### 5b. Assessment

| Candidate | Purpose / capabilities | Security | Overlap | Automation (Claude / Codex) | Benefit | Decision |
|---|---|---|---|---|---|---|
| AnalyticsService | Native funnels, economy, progression, journeys and custom events feeding the Creator Hub dashboards and experiments | Server only; no PII in field values; data is visible to the game's collaborators | workbench offline report; GameAnalytics | Studio cannot send, so the adapter needs a recorder in Studio and a fake in Lune. Ingestion is BLOCKED_EXTERNAL here | One schema serves every genre; the dashboards Roblox uses for its own guidance | **SELECT** as the target of `GameKit/Telemetry` (section 8) |
| ConfigService + Experiments | Live values, kill switches, staged rollouts, A/B tests on retention, playtime and monetization | Config publishes are production changes, so they are owner-only. `SetTestingValue` is per server | hard-coded constants; Zyntex-style community A/B (not researched) | The adapter with defaults is testable in Lune. Studio sees staged values. Whether it works in an unpublished place is UNVERIFIED | Roblox's own recommended release safety ("hide content behind a config"); rollback without a publish | **SELECT** as `GameKit/Config` with in-code defaults |
| MarketplaceService 2026 APIs | `BindReceiptHandler` with `ReceiptDecision`, dynamic prices, price levels, subscription status, `OpenShop` | Prompts move money and are guarded. Grants only from receipts | `Runtime/RobloxReceiptAdapter.luau` (legacy `ProcessReceipt`), `Runtime/CommerceCatalog.luau` | Lune with fakes; mock purchases in Studio for products and passes only | Regional pricing and price optimisation need dynamic prices; one receipt path for products, ad rewards and transfers | **SELECT**: add `Adapter.bind` and a `CommerceRoblox` platform adapter (section 10) |
| PolicyService | Per-player flags for random items, trading, ads, subscriptions and content sharing | Policy failures must fail closed | genre-coverage `PolicyGate` | Player Emulator region in Studio; `FakePolicy` in Lune | Compliance for RNG, trading, ads and subscriptions from day one | **SELECT** as `GameKit/PolicyGate` (fail closed) |
| TextService + TextChatService | Mandatory filtering for user text; chat permission checks | Removal risk if missing; filter after submit | none | Lune for routing logic; Studio filtering behaviour UNVERIFIED | Prevents a known removal cause | **SELECT** as `GameKit/TextFilter` plus a static check |
| LocalizationTable via Rojo CSV | Keys in version control, automatic translation for blanks, `AutoLocalize` control | none | `Creator/UI.luau` localize helpers; UIKit `Localize` (ui-cinematics pass) | Lune parses CSVs; Player Emulator locale in Studio | Text-fit and key coverage become gateable | **SELECT** |
| Player Emulator, mock purchases, Device Simulator | Locale, region and policy emulation; simulated product and pass purchases; device sizes | Subscription and transfer prompts are not safely mocked (section 2) | MCP `screen_capture` | GUI toggles; flows driven through MCP on the PC | Tier S evidence (section 7) | **SELECT** (PC, owner present) |
| Creator Hub release surfaces | Everything in sections 1-2 that only an account holder can do | account, money, production | none | none for agents | The owner's checklist (tier O) | **SELECT** as a reference: owner-run only |
| Discovery and dashboard docs | Roblox's statements on signals and metric definitions | none | none | WebFetch during research | Telemetry design and post-publish observation plan (tier P) | **SELECT** as a reference; no predictions |
| AdService + immersive ads | Ad rewards through developer-product receipts (`ProductPurchaseChannel.AdReward`); `AdGui` placement | Thresholds and policy gating; rewards cannot be random or progress gates | ReceiptLedger | Lune for gating logic only | Keeps future ad hooks compliant | **SELECT** as design constraints only (PolicyGate `AreAdsAllowed`, ledger accepts the `AdReward` channel). Integration is **REVISIT** in a game repo |
| Open Cloud Place Publishing | POST a place file as a Published version (`universe-places` write) | Publishes, needs a secret key. Some instance types, such as SurfaceAppearance and PartOperation, are not updated, so "publish from Studio after modifying them" | Studio File > Publish | Denied by `tools/hooks` for both clients | none in SETUP_ONLY | **REJECT** for agents and CI here; the owner's runbook may name it (section 9) |
| Open Cloud Analytics Query API | Read time-series metrics | Read-only, but needs an owner-created key on a real game | Creator Hub dashboards | GET is not denied by the guards; there is no key here | Offline reports from real data | **REVISIT** in a game repo with an owner-created, read-only, IP-restricted key |
| Open Cloud Experiments / Thumbnails / Universe PATCH | Manage experiments, thumbnails and settings | Production writes | Creator Hub | Denied (Open Cloud writes) | none here | **REJECT** |
| Mantle | infrastructure as code for experiences | deploys | Creator Hub | denied by the guards | none | **REJECT** (unmaintained, and a deploy tool) |
| rbxcloud | Open Cloud CLI (place publishing, data stores, messaging, Luau execution and more) | publish-capable | none | the guards deny everything except `get*`/`list*`/`help` | none here | **REJECT** (unchanged) |
| GameAnalytics SDK | Third-party analytics over HttpService | Data leaves Roblox; needs HTTP enabled and keys in the game | AnalyticsService | sign-up required | duplicates native dashboards | **REJECT** |
| Ads Manager | paid user acquisition | spending | none | none | none here; ad-acquired users do not feed RFY ranking (section 4) | **REJECT** (spending is out of bounds) |
| RecommendationService | in-game recommender for a game's own items or levels | data-quality rules | none | none | only for content-catalogue games | **REVISIT** when a game repo has a user-generated or level catalogue |

## 6. What the repo has today vs the 2026 APIs

- **`packages/Runtime/ReceiptLedger.luau`: current.**
  - It matches the reference architecture: PurchaseId dedupe inside `UpdateAsync`, no side effects in the transform, and `PurchaseGranted` only after a confirmed durable record.
  - It keys grants by `ProductId`, so ad-reward receipts (channel `AdReward`) and Commerce receipts flow through unchanged.
  - Gap: it does not record `ProductPurchaseChannel`, and the Robux-transfer receipt types (no `ProductId`; `TransferRequestId` instead) are out of scope. That is fine for now.
- **`packages/Runtime/RobloxReceiptAdapter.luau`: legacy-only.** `Adapter.callback` returns `Enum.ProductPurchaseDecision` for `ProcessReceipt`, which still works and receives receipts that no bound handler claims. Add `Adapter.bind(marketplace, ledger, onResult)` on `BindReceiptHandler(Enum.ReceiptType.DeveloperProduct, ...)`, mapping to `Enum.ReceiptDecision`. Keep `callback` until the ad-reward path through `BindReceiptHandler` is verified, because the ad docs still say "ProcessReceipt" (UNVERIFIED).
- **`packages/Runtime/CommerceCatalog.luau`: current in shape.** It is display-only: `preview_only` and never purchasable, entries must be "verified and disabled", subscriptions are re-checked and never stored. Its `platform.productInfo` seam must be bound to `GetProductInfoAsync` (`GetProductInfo` is deprecated), and no adapter exists yet.
- **Guards (`tools/hooks/guard_mcp.mjs`).**
  - Publish and create APIs are denied.
  - `Prompt\w*Purchase`, `PromptRobuxTransfer` and `PromptCancelSubscription` are **ask** in Claude and deny in Codex.
  - Given section 2, `PromptSubscriptionPurchase`, `PromptRobloxSubscriptionPurchase` and `PromptRobuxTransferAsync` should become **deny** in both clients until Roblox documents a safe Studio mock (section 9).
- **`fixtures/analytics/`.** It holds inputs and an expected report for a workbench tool that is not in this repo (gap-matrix Q08). Its event vocabulary fits the telemetry design below.
- **`roblox-release-pass` skill.** It writes `reports/release-readiness.json` but has no tool, tiers or owner list (gap-matrix Q02).

## 7. Release-readiness checklist (machine-checkable vs owner)

**Deliverable.** Ship `tools/release_check.py` in `templates/starter/`, with a declarative `release/release.json` and two release fixtures (one good, one seeded with violations) under `fixtures/release/`. A factory self-test proves that every A-tier rule fires on the bad fixture and passes on the good one. The tool writes `reports/release-readiness.json` with entries of the form `{id, tier, status, evidence}`.

Statuses:
- `PASS` and `FAIL` for tier A;
- `BLOCKED_EXTERNAL` for tiers S and P without fresh evidence;
- `OWNER_TODO` for tier O until the owner records it.

Tier O and tier P items can **never** be passed by the tool or an agent.

Tiers:
- **A**: agent, Linux container or CI, static or Lune;
- **S**: Studio on the owner's PC, private place;
- **O**: owner-only account or Creator Hub action;
- **P**: post-publish observation by the owner.

| ID | Tier | Check | How it is verified | Basis |
|---|---|---|---|---|
| A01 | A | Game gate passes at `--tier pre-release --strict` | `tools/check.py` exit code | repo rule |
| A02 | A | Rojo build succeeds and the place deserialises | `rojo build`, Lune `roblox` lib | repo rule |
| A03 | A | `release/release.json` validates. It records: name and description; genre and subgenre from the 17-genre list; devices; audience target; private servers XOR paid access; locales; version notes for this publish; the owner's maturity-answer summary | JSON schema | 1a, 1b |
| A04 | A | Exactly one server-side developer-product receipt binding (`BindReceiptHandler` DeveloperProduct, or one `ProcessReceipt =`); none in client code; no grants keyed only on `Prompt*PurchaseFinished`. The ledger duplicate-receipt spec passes | grep over `src/server` and `src/client`; Lune spec | 2 |
| A05 | A | Catalog consistency: every product id used in code is in the catalog; ids are unique; subscription ids match `^EXP-`; no ad-reward product grants a random outcome | Lune spec over the catalog plus grep | 2 |
| A06 | A | No hard-coded prices in UI strings or LocalizationTables (Robux amounts next to a price word or glyph); prices come from `GetProductInfoAsync` / `GetDeveloperProductsAsync` | regex scan | regional pricing |
| A07 | A | Deprecated or legacy APIs absent: `GetProductInfo(`, `PlayerOwnsAsset(`, `PlayerOwnsBundle(`, `PromptPremiumPurchase`, `FilterAndTranslateStringAsync`, `AnalyticsService:Fire*`, `ShowVideoAd`, LegacyChatService | grep (Selene overlay later; see addendum H) | 1d, 2, 3 |
| A08 | A | Analytics schema valid: server-only call sites; within the limits in section 3; names follow the rules; field values are strings | Telemetry catalog construction in Lune; grep that `Telemetry` is not required from client code | 3 |
| A09 | A | Text: every path that reads `TextBox.Text` and shows it to others goes through `GameKit/TextFilter`; direct-chat channels use `CanUsersDirectChatAsync` + `SetDirectChatRequester` | static heuristic plus Lune routing spec | 1d |
| A10 | A | No external URLs in in-game strings; no "free Robux" or giveaway wording in metadata | regex over `src/`, CSVs and `release.json` | 1e, 4 |
| A11 | A | Paid random items: each odds table sums to exactly 100% at display precision; an odds-UI key is shown before purchase; a PolicyGate treatment exists for `ArePaidRandomItemsRestricted`; trades are gated by `IsPaidItemTradingAllowed` | `OddsTable` spec plus grep | 1e |
| A12 | A | Ads: every `AdGui` / `AdService` use sits behind `PolicyGate.adsAllowed`; rewarded ads are not referenced from progression gates (flagged for review) | grep plus review flag | 2 |
| A13 | A | Localization: CSVs parse; keys unique; placeholders match across locales; every `FormatByKey` key exists; pseudo-locale overflow audit | Lune or Python spec | 1d |
| A14 | A | Store-page source art in the repo: icon 512x512 square; thumbnails 16:9 (1920x1080), allowed format, under 3 MB, at most 10; pass icons at most 512x512 in jpg/png/bmp; badge icons 512x512 with content inside the circle (warning) | Python image-header check | 1c |
| A15 | A | Persistence: `BindToClose` flush present when data stores are used; writes only through SessionStore; Studio-only debug tools wrapped in `RunService:IsStudio()` | grep plus specs | genre-coverage X02 |
| A16 | A | Every `Config` key read in code has an in-code default and is listed in `release/configs.json`; new content defaults to off | Lune spec | 1a, 3 |
| A17 | A | Publish-surface tripwire: committed workflows and scripts contain no publish-capable command (the `CODE_PUBLISH` patterns plus `versionType=Published`) unless listed in an owner-recorded exception | grep with the guard patterns | section 9 |
| S01 | S | Critical-flow matrix from `roblox-release-pass` (join, onboarding, core loop, fail and retry, leave and rejoin) in Test and Server & Clients | MCP console plus captures | skill |
| S02 | S | Mock purchases: developer products and passes only; ledger grants once; UI shows `GetProductInfoAsync` prices | MCP on a private place (guard asks) | 2 |
| S03 | S | Player Emulator: each target locale (text fit), plus regions that flip paid-random-items, trading and ads flags | captures per locale and region | 1e |
| S04 | S | Device Simulator captures for each declared device | `screen_capture` | 1b |
| S05 | S | Telemetry recorder in a Studio session emits the expected event sequence; the offline report runs on it | console JSONL to `tools/analytics_report.py` | 8 |
| S06 | S | Performance capture (MicroProfiler / Script Profiler) for the release candidate | `roblox-performance-pass` | addendum G |
| O01 | O | Account: age check, good standing, 2+ days old. For all ages: 2FA plus Plus/Premium for 2 months or the refundable fee | owner | 1a |
| O02 | O | Owner (user or group) decided **before** the first publish | owner | 1a |
| O03 | O | Maturity & Compliance Questionnaire complete and accurate (A03 holds only the owner's summary) | owner | 1b |
| O04 | O | Audience progression: Private, then Limited (playtesters), then Public | owner | 1a |
| O05 | O | Genre and subgenre set (changeable once every 3 months); devices; MaxPlayers and PreferredPlayers per place; private servers or paid access | owner | 1b |
| O06 | O | Products, passes and subscriptions created and priced; Managed Pricing reviewed; `GetUsersPriceLevelsAsync` in place before regional pricing for developer products | owner | 2 |
| O07 | O | Icon, 2 or more thumbnails (personalization), optional video (3 per month), description, social links (16+), badges (5 free per day) | owner | 1c |
| O08 | O | Localization languages, Automatic Text Capture and automatic translation enabled | owner | 1d |
| O09 | O | Publish from Studio (File > Publish to Roblox) with version notes | owner | 1a, section 9 |
| O10 | O | After publish: restart choice (outdated servers only, with a delay); configs published; experiments started; Dynamic Price Check run | owner | 1a, 2, 3 |
| O11 | O | Rollback rehearsed: config kill switch first; Version History restore, then publish | owner | 1a |
| P01 | P | Performance dashboard filtered by place version (needs 100 or more DAU) | owner, Creator Hub | 3 |
| P02 | P | Funnel, economy and custom dashboards populated (up to 24 h) and matching the S05 sequence | owner | 3 |
| P03 | P | Retention (D1/D7/D30), engagement, monetization and discovery signals (PTR, bounce, play days, playtime) reviewed. These are observations only and never a pass/fail | owner | 3, 4 |

Human sign-offs on fun, art, fairness and physical devices remain separate (repo verification language).

## 8. Analytics events module: `GameKit/Telemetry` with a sandbox and a test double

**Design goals.**
- One genre-neutral schema that compiles to every AnalyticsService method.
- Every limit enforced before Roblox's silent "Other" bucketing.
- Gameplay never fails because of analytics.
- Fully testable in Lune and observable in Studio, where AnalyticsService cannot send.

**Pure core** (`packages/GameKit/Telemetry.luau`). It touches no services; the clock, id generator and sink are injected:

```luau
export type Catalog = {
	custom: { [string]: { fields: { string }? } }?, -- <= 100 names; <= 3 named string fields
	onboarding: { string }?, -- ordered step names
	funnels: { [string]: { steps: { string } } }?, -- <= 10 funnels, <= 100 steps
	economy: { currencies: { string }, transactionTypes: { string }? }?, -- <= 5 currencies; <= 20 types
	progression: { [string]: true }?, -- path names
	journeys: { [string]: { nodes: { string } } }?,
}
Telemetry.new({ catalog: Catalog, sink: Sink, clock: () -> number, newId: () -> string, strict: boolean? })
-- api:custom(player, name, value?, fields?)        api:onboarding(player, stepName)
-- api:funnelStart(player, funnel) -> sessionId    api:funnelStep(player, funnel, sessionId, stepName)
-- api:economy(player, "source"|"sink", currency, amount, endingBalance, txType, sku?, fields?)
-- api:progression(player, path, "start"|"complete"|"fail"|"custom", level, levelName?, fields?)
-- api:journey(player, journey, node, sessionId, fields?)
-- api:report() -> { accepted, rejected: { [reason]: number }, cardinality, budgetDrops }
```

**Rules in the core:**
- **Names.** Validated against the catalog and Roblox's name rules: not empty; no commas, quotes or newlines; no leading `__`.
- **Fields.**
  - Fields are declared by name per event, and the core maps them to `CustomField01..03` in declaration order.
  - Values must be strings.
  - A per-server distinct-combination counter warns at 80% of 8,000. It only sees one server, so it is an early warning, not proof.
- **Steps and amounts.**
  - Onboarding and funnel steps are numbered from catalog order, so the step number and name can never drift.
  - Economy amounts must be positive and finite, and `endingBalance` must be at least 0.
- **Failures.**
  - Invalid calls return `false, reason` and are counted. With `strict = true`, used in specs, they raise.
  - Budget: a token bucket with a configurable per-server rate. The documented "120 + 20*CCU" per minute is game-wide, so the per-server share is a convention. Overflow is dropped and counted, never queued without bound.
- **Privacy.** No user names, chat or free text in field values. Values longer than 64 characters are rejected; that limit is a convention and is not documented.
- **Ordering.** Emit only after durable state. Wallet and ReceiptLedger callers log economy events from `onResult` after the commit, never inside an `UpdateAsync` transform, which is the rule `ReceiptLedger.luau` already states.

**Sinks** (`packages/GameKit/TelemetryRoblox.luau`):
- **`live(AnalyticsService)`.**
  - Asserts it is running on the server.
  - Maps calls to the methods in section 3: `Enum.AnalyticsEconomyFlowType`, `Enum.AnalyticsEconomyTransactionType.<Name>.Name` for the standard types, and `Enum.AnalyticsProgressionType`.
  - Each call is wrapped in `pcall`.
- **`recorder(print)`.** Used when `RunService:IsStudio()` is true. It writes one line per event, `TELEMETRY_JSON {...}`, with `synthetic = true` and `environment = "studio"`. MCP `get_console_output` can collect these lines into JSONL in the same shape as `fixtures/analytics/neutral_events.jsonl`.
- **Never both.** A live sink never receives synthetic events.

**Test double** (`tests/fakes/FakeAnalytics.luau`). It records each call with the exact argument list in AnalyticsService order and fails on client context. It shares the core's validation table, so a fake call that passes is a real call with the same arguments. It also simulates throttling and exposes `calls()` and `byMethod()`.

**Specs** (`tests/gamekit/telemetry.spec.luau`):
- limits at the boundary: the 100th custom event passes and the 101st fails; the same for 10 funnels, 100 steps, 3 fields and 5 currencies;
- name rules;
- field mapping;
- step numbering;
- budget drops;
- strict and lenient modes;
- determinism: seeded `newId` gives the same JSONL hash.

**Offline report.** Re-implement `tools/analytics_report.py` with a unittest so that `fixtures/analytics/neutral_events.jsonl` reproduces `fixtures/analytics/expected_report.json`, including its `input_sha256`. This closes Q08 without the workbench copy, and the S05 recorder output feeds the same tool.

**Default event vocabulary.** These are SETUP_ONLY suggestions; the game repo owns the catalog:
- an onboarding funnel ending at a configurable "first core action";
- `session_end` (custom, value = seconds);
- `load_finished` (custom, value = seconds);
- economy events from Wallet and ReceiptLedger;
- progression from Objectives and Checkpoints.

They follow the Roblox-named discovery signals (first session, bounce, play days) without predicting any outcome.

## 9. Keeping the publish step owner-only

Already in place (`docs/mcp.md`, `tools/hooks/`):
- Luau `SavePlaceAsync`, `CreatePlace*`, `CreateAsset*`, `Upload*Async`, `PublishAsync` and plugin save-to-Roblox calls are denied.
- Bash `rojo upload`, `mantle deploy`, tarmac and asphalt uploads, `rbxcloud` writes and every write request to Roblox web APIs (including the `versionType=Published` POST) are denied.
- Codex turns every ask into a deny.

Confirmed this pass:
- The Studio command line has no publish or save task. Its tasks are `EditPlace`, `EditPlaceRevision`, `EditFile`, `RunScript` and `TryAsset` (`studio/command-line-interface`, 2026-09-23).
- The Studio MCP tool list has no publish tool (tooling section 1a).
- So the only publish routes are the Studio GUI, the Creator Hub, and an Open Cloud key, and all three belong to the owner.

Recommended changes (owner approval needed for hook edits):
1. **Deny** `PromptSubscriptionPurchase`, `PromptRobloxSubscriptionPurchase` and `PromptRobuxTransferAsync` in `guard_mcp.mjs` for both clients, with selftest cases. The reason is the community reports in section 2 that these prompts are not safely mocked. Product and pass prompts stay **ask**.
2. **Tripwire A17** in the starter gate. A committed file that can publish (workflow, script) fails the gate unless the owner lists it in `release/owner-exceptions.json`. Agents cannot defeat this by editing that file, because a PreToolUse ask on `Edit|Write` to `release/owner-*.json` (deny in Codex) makes owner records owner-only. This is a tripwire, not a security boundary: a CI job with a secret is still the owner's decision.
3. **Owner runbook** `docs/release-runbook.md` in `templates/starter/`. It covers the O-tier steps in order:
   - Studio publish with version notes;
   - restart "only servers with outdated versions" with a delay;
   - config kill switch, then Version History restore and publish, as the rollback ladder;
   - the post-publish P-tier review.

   It names Open Cloud place publishing only as an owner-run option, with a key scoped to `universe-places` write on one game, never stored in the repo, and with the instance-type caveat from section 5b.
4. **Skill update.** `roblox-release-pass` should cite the tiers, call `tools/release_check.py`, and state that agents finish at "A and S green, O and P listed". `roblox-persistence-and-commerce` should cite `BindReceiptHandler` / `ReceiptDecision` alongside the legacy callback.

## 10. Other deliverables (genre-neutral)

- **`Runtime/RobloxReceiptAdapter.luau`.** Add `Adapter.bind(marketplace, ledger, onResult)` as described in section 6.
- **`GameKit/CommerceRoblox.luau`.** Binds CommerceCatalog's `platform` to `GetProductInfoAsync`, `UserOwnsGamePassAsync` and `GetUserSubscriptionStatusAsync`. It adds `priceLevels(userIds)` on `GetUsersPriceLevelsAsync`, called at join and not cached, for trade and gift caps.
- **`GameKit/PolicyGate.luau`.** Wraps `GetPolicyInfoForPlayerAsync` with **fail-closed** defaults:
  - ads off;
  - paid random items restricted;
  - paid trading off;
  - subscriptions ineligible;
  - content sharing off.

  It caches per player per session. It comes with a `tests/fakes/FakePolicy.luau` that has region presets.
- **`GameKit/TextFilter.luau`.**
  - A submit-then-filter flow: `FilterStringAsync`, then the broadcast or per-user variant.
  - On failure it shows nothing (fail closed).
  - Helpers for `CanUsersChatAsync` / `CanUsersDirectChatAsync`.
- **`GameKit/Config.luau`.** ConfigService adapter with in-code defaults, a pcall and timeout, and `refresh()` on `UpdateAvailable`. It comes with `FakeConfig` for specs and is the basis of A16 and of the rollback ladder.
- **Localization checker.** Rojo CSV LocalizationTables plus the A13 spec. It shares the pseudo-locale with the UIKit `Localize` module proposed in `ui-cinematics-feel-2026-10.md`.
- **Store-art checker.** The A14 checker, plus a Blender render preset (`tools/blender`) for icon (512x512) and thumbnail (1920x1080) previews of neutral fixtures. Real store art is game content and is made in the game repo.

## 11. Proposed gap-matrix updates (not applied here)

- **Q02 (Release readiness, MISSING, P3).** Raise to P1. Fix: `tools/release_check.py` with A/S/O/P tiers, release fixtures and the runbook (sections 7 and 9). Evidence: this doc.
- **Q08 (Analytics, MISSING, P3).** Raise to P1. Fix: `GameKit/Telemetry` with sinks and `FakeAnalytics`, plus the `tools/analytics_report.py` port verified against the existing fixtures (section 8).
- **R02 (Studio-bound inherited modules).** Add to the defect text that `RobloxReceiptAdapter` targets only the legacy `ProcessReceipt` path.
- **New row.** "Guard: subscription and transfer prompts are ask, not deny" (section 9.1).

## 12. Summary

**Selected:**
- the AnalyticsService target with the `Telemetry` core, sinks, fake and offline report;
- ConfigService and Experiments, through a `Config` adapter;
- the MarketplaceService 2026 APIs, through `Adapter.bind` and `CommerceRoblox`;
- PolicyService, through a fail-closed `PolicyGate`;
- TextService and TextChatService, through `TextFilter`;
- LocalizationTable through Rojo CSV, with a checker;
- the Studio Player Emulator, mock purchases and Device Simulator (PC, owner present);
- Creator Hub release surfaces, the discovery docs and the dashboard docs as references (owner-run);
- AdService and immersive-ads rules as design constraints only.

**Rejected:**
- Open Cloud Place Publishing for agents and CI;
- the Open Cloud Experiments, Thumbnail and Universe write APIs;
- Mantle;
- rbxcloud;
- the GameAnalytics SDK;
- Ads Manager.

**Revisit:**
- Open Cloud Analytics Query API (game repo, read-only key);
- RecommendationService (games with a level or user-content catalogue);
- ad integration (a game that meets the 2,000-visitor threshold).

## 13. UNVERIFIED

- Kids and Select thresholds: "25 highly engaged players" (publish page, fee refund) vs "250 unique plays" (Kids and Select page, evaluation).
- Economy currency limit: 5 (economy page) vs 10 (event-types page).
- Whether progression and journey events also require the server and a published game; their guide pages return 404.
- The funnel back-fill claim in the workbench record.
- Whether `BindReceiptHandler` receives ad-reward receipts; the ad docs still say ProcessReceipt.
- That Studio subscription prompts use the real payment path, and that Robux transfers are not mocked in Team Test (community reports only).
- ConfigService and automatic text capture in an unpublished place.
- How `FilterStringAsync` behaves in Studio.
- How chart sorts other than Top Playing Now are computed.
- Video thumbnail length, resolution and size limits; the icon file format; title and description length limits (not researched).
- MaxPlayers upper bound.
- The paid-access revenue share.
- The Universe resource fields (Open Cloud v2).
- Which products, passes, data stores and badges move with an ownership transfer.
- Whether the creator-docs CC-BY-4.0 licence covers the served pages.

## Sources (all fetched 2026-10-06)

- Roblox publishing and settings:
  - https://create.roblox.com/docs/en-us/production/publishing/publish-games-and-places.md
  - https://create.roblox.com/docs/en-us/production/publishing/kids-and-select.md
  - https://create.roblox.com/docs/en-us/production/promotion/content-maturity.md
  - https://create.roblox.com/docs/en-us/projects/configure-games.md
  - https://create.roblox.com/docs/en-us/studio/experience-settings.md
  - https://create.roblox.com/docs/en-us/projects/version-history.md
  - https://create.roblox.com/docs/en-us/projects/update-games.md
  - https://create.roblox.com/docs/en-us/projects/game-ownership-transfer.md
  - https://create.roblox.com/docs/en-us/production/publishing/experience-genres.md
  - https://create.roblox.com/docs/en-us/production/publishing/account-verification.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/Players.md
  - https://create.roblox.com/docs/en-us/studio/command-line-interface.md
  - https://create.roblox.com/docs/en-us/studio/testing-modes.md
  - https://create.roblox.com/docs/llms.txt
- Store page:
  - https://create.roblox.com/docs/en-us/production/publishing/experience-icons.md
  - https://create.roblox.com/docs/en-us/production/publishing/thumbnails.md
  - https://create.roblox.com/docs/en-us/production/publishing/badges.md
  - https://create.roblox.com/docs/en-us/production/promotion/social-media-links.md
- Localization, text and chat:
  - https://create.roblox.com/docs/en-us/production/localization.md
  - https://create.roblox.com/docs/en-us/production/localization/automatic-translations.md
  - https://create.roblox.com/docs/en-us/production/localization/auto-translate-dynamic-content.md
  - https://rojo.space/docs/v7/sync-details/
  - https://create.roblox.com/docs/en-us/ui/text-filtering.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/TextService.md
  - https://create.roblox.com/docs/en-us/chat/in-experience-text-chat.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/TextChatService.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/ModerationService.md
  - https://devforum.roblox.com/t/update-on-legacy-chat-deprecation-and-textchatservice-migration/3376880
- Policy and standards:
  - https://create.roblox.com/docs/en-us/reference/engine/classes/PolicyService.md
  - https://create.roblox.com/docs/en-us/production/monetization/paid-random-items.md
  - https://about.roblox.com/community-standards
  - https://en.help.roblox.com/hc/en-us/articles/36495190721172-Commerce-Standards (physical merchandise only; not used for in-game rules)
- Monetization:
  - https://create.roblox.com/docs/en-us/reference/engine/classes/MarketplaceService.md
  - https://create.roblox.com/docs/en-us/reference/engine/enums/ProductPurchaseChannel.md
  - https://create.roblox.com/docs/en-us/production/monetization/developer-products.md
  - https://create.roblox.com/docs/en-us/production/monetization/passes.md
  - https://create.roblox.com/docs/en-us/production/monetization/subscriptions.md
  - https://create.roblox.com/docs/en-us/production/monetization/managed-pricing.md
  - https://create.roblox.com/docs/en-us/production/monetization/regional-pricing.md
  - https://create.roblox.com/docs/en-us/production/monetization/price-optimization.md
  - https://create.roblox.com/docs/en-us/production/monetization/paid-access-robux.md
  - https://create.roblox.com/docs/en-us/production/monetization/private-servers.md
  - https://create.roblox.com/docs/en-us/production/monetization/immersive-ads.md
  - https://create.roblox.com/docs/en-us/production/promotion/rewarded-video-ads.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/AdService.md
  - https://create.roblox.com/docs/en-us/production/monetization/robux-transfers.md
  - https://create.roblox.com/docs/en-us/creator-rewards.md
  - https://create.roblox.com/docs/en-us/production/game-design/monetization-foundations.md
  - https://create.roblox.com/docs/en-us/production/promotion/ads-manager.md
  - https://devforum.roblox.com/t/disabling-cross-game-sales-of-passes-and-dev-products-and-introducing-the-transfers-api/4618396
  - https://devforum.roblox.com/t/mock-purchases-in-studio/26974
  - https://devforum.roblox.com/t/subscription-studio-play-mode-subscription-test-purchase-uses-real-purchase-path-instead-of-test-path/4676620 (community report)
  - https://devforum.roblox.com/t/allow-promptrobuxtransferasync-to-be-used-in-server-clients-testing/4625943 (community request)
- Analytics, configs and experiments:
  - https://create.roblox.com/docs/en-us/reference/engine/classes/AnalyticsService.md
  - https://create.roblox.com/docs/en-us/production/analytics.md
  - https://create.roblox.com/docs/en-us/production/analytics/event-types.md
  - https://create.roblox.com/docs/en-us/production/analytics/custom-events.md
  - https://create.roblox.com/docs/en-us/production/analytics/funnel-events.md
  - https://create.roblox.com/docs/en-us/production/analytics/economy-events.md
  - https://create.roblox.com/docs/en-us/production/analytics/custom-fields.md
  - https://create.roblox.com/docs/en-us/production/analytics/engagement.md
  - https://create.roblox.com/docs/en-us/production/analytics/retention.md
  - https://create.roblox.com/docs/en-us/production/analytics/performance.md
  - https://create.roblox.com/docs/en-us/production/analytics/get-started.md
  - https://create.roblox.com/docs/en-us/production/game-design/analytics-essentials.md
  - https://create.roblox.com/docs/en-us/reference/engine/enums/AnalyticsEconomyTransactionType.md
  - https://create.roblox.com/docs/en-us/reference/engine/enums/AnalyticsProgressionType.md
  - https://create.roblox.com/docs/en-us/production/configs.md
  - https://create.roblox.com/docs/en-us/production/experiments.md
  - https://create.roblox.com/docs/en-us/reference/engine/classes/ConfigService.md
  - https://devforum.roblox.com/t/live-now-use-configs-and-experiments-to-grow-your-game-faster/4051385
  - https://devforum.roblox.com/t/configservicegetconfigforplayerasync-yields-for-30-seconds-and-then-errors-when-called-in-an-experience-without-configs/4686600
  - https://devforum.roblox.com/t/new-opencloud-apis-for-analytics-events-experiments-and-thumbnail-personalization/4828676
- Discovery:
  - https://create.roblox.com/docs/en-us/discovery.md
  - https://create.roblox.com/docs/en-us/discovery-faq.md
  - https://create.roblox.com/docs/en-us/production/recommendation.md
  - https://devforum.roblox.com/t/introducing-top-playing-now-on-charts/3529809
- Open Cloud:
  - https://create.roblox.com/docs/en-us/cloud/guides/usage-place-publishing.md
  - https://create.roblox.com/docs/en-us/cloud/reference/Universe
- Third party:
  - https://github.com/blake-mealey/mantle
  - https://github.com/Sleitnick/rbxcloud
  - https://github.com/GameAnalytics/GA-SDK-ROBLOX
