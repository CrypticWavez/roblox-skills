# Economy

Status: TBD

Prompts only. The numbers here are the game's decisions (owner or game-build request), checked with a
simulation before alpha (skill roblox-persistence-and-commerce). Never put prices in data or UI text:
Roblox prices are read at runtime (release check A14).

## Currencies and items
> Prompt: Each currency or item, how it is earned (sources) and spent (sinks). AnalyticsService economy events track at most 5 currencies.

## Flow per session
> Prompt: Expected earn and spend per session for a new, a mid-term and a long-term player. What stops inflation?

## Progression pacing
> Prompt: How long each milestone takes; which pacing values are tuned live (configs) and their safe ranges.

## Monetization
> Start from `python3 tools/monetize.py plan` (it writes the catalog, offers, boosts, perks, shop layout and `docs/design/monetization.md` for the genre; `check` keeps them consistent; release check A18).
> Prompt: Developer products, passes and subscriptions (catalog/1 keys, no prices), what each grants, and why it is fair. Paid random items? Then odds, disclosure and the policy treatment (release check A05).

## Rewarded ads
> Prompt: Are there any? Rewards must be fixed, never random, and gated by policy.

## Trading
> Prompt: Is there any? Then the policy gate for paid items (`trading`) and the abuse cases.

## Telemetry
> Prompt: The economy transaction types (at most 20) and the funnels that show whether the economy works.

## Simulation results
> Prompt: The simulation run (seed, inputs, outputs) that backs the numbers above.
