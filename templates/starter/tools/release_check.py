"""Release-readiness checker (release-check/1). Publishing stays with the owner.

  python3 tools/release_check.py [--root DIR] [--out release/report.json]
  python3 tools/release_check.py --write-runbook docs/release-runbook.md

Tiers (ITEMS below; docs/release-runbook.md is generated from the same table):
  A  automated here, from the repository alone: PASS or FAIL (A16 hits the owner excepted: WAIVED_BY_OWNER)
  S  Studio checks on the owner's PC (private, unpublished place)
  O  owner-only account and Creator Hub actions
  P  observations after publishing
S, O and P items always report OWNER_REQUIRED. The owner signs them in release/owner-*.json
(release-owner/1); a signature shows up as owner_record and never turns the item into PASS. Agents do
not write those files (the guard hooks refuse it).
Inputs: release/release.json (release-meta/1), production/brief.json (game-brief/1), the files they
point to (catalog/1, the telemetry catalog, perf/1 budgets and captures, localisation CSVs, store art),
src/, the Rojo projects and assets/provenance.json. Writes release/report.json; exit 1 when an
automated check fails. Reads files only: it runs nothing, uploads nothing and calls no API.
"""
import argparse
import csv
import io
import json
import re
import struct
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import production  # noqa: E402  (tools/production.py: genres, devices, brief helpers)

SCHEMA = "release-check/1"
META_SCHEMA = "release-meta/1"
OWNER_SCHEMA = production.OWNER_SCHEMA
WALLY_DIRS = {"Packages", "ServerPackages", "DevPackages"}
FACTORY_DIR = "factory"  # the factory packages in a game repo (tools/new_project.py)
# GameKit Catalog.validate: the only top-level keys of a catalog/1 file (Catalog.define rejects others).
CATALOG_KEYS = ("schema", "mode", "products")
# GameKit Commerce.RANDOM_TAG: Commerce.canPrompt needs PolicyGate paidRandomItems for a product with this tag.
RANDOM_TAG = "paid_random_item"
LABEL = production.LABEL
STANDARD_TRANSACTION_TYPES = {"IAP", "Shop", "Gameplay", "ContextualPurchase", "TimedReward", "Onboarding"}
CLIENT_REALMS = {"client", "gui"}
REPLICATED_SERVICES = {"ReplicatedStorage", "ReplicatedFirst", "StarterPlayer", "StarterGui", "StarterPack", "Workspace", "Lighting"}
AUTHORING = {"SceneKit", "ProcGen", "Pipeline"}
# Leaf modules of authoring packages that kits require; new_project.py maps these files next to the kits.
AUTHORING_LEAVES = {"ProcGen/Rng.luau", "ProcGen/Grid.luau", "ProcGen/Graph.luau", "SceneKit/Vec.luau", "SceneKit/Lighting.luau"}
ENTRY_NODES = [
    ("ReplicatedFirst", "Loading"),
    ("ReplicatedStorage", "Shared"),
    ("ServerScriptService", "Server"),
    ("StarterPlayer", "StarterPlayerScripts", "Client"),
]
# brief engine key -> (Rojo service, property)
ENGINE_PROPERTIES = {
    "authority_mode": ("Workspace", "AuthorityMode"),
    "streaming_enabled": ("Workspace", "StreamingEnabled"),
    "signal_behavior": ("Workspace", "SignalBehavior"),
    "lighting_style": ("Lighting", "LightingStyle"),
    "prioritize_lighting_quality": ("Lighting", "PrioritizeLightingQuality"),
    "default_listener_location": ("SoundService", "DefaultListenerLocation"),
}

DOCS = "https://create.roblox.com/docs/en-us/"

# ---------------------------------------------------------------- the checklist

ITEMS = [
    # Automated (A): run by this tool.
    {"id": "A01", "tier": "A", "title": "Project hygiene and engine settings",
     "spec": "No Rojo project overrides FilteringEnabled or turns LoadStringEnabled on. default.project.json maps the boot entry points (ReplicatedFirst.Loading, ReplicatedStorage.Shared, ServerScriptService.Server, StarterPlayerScripts.Client). Authoring packages (factory/SceneKit, factory/ProcGen, factory/Pipeline), the Wally folders (Packages, ServerPackages, DevPackages) and src/server never map into a replicated service; paths are compared case-insensitively, as Windows and macOS resolve them. Engine properties set in a project match the decided production/brief.json engine values.",
     "source": "starter layout; engine settings from the brief"},
    {"id": "A02", "tier": "A", "title": "Remotes go through RemoteGuard",
     "spec": "No code in src/ connects OnServerEvent or assigns OnServerInvoke directly: server handlers are registered through GameKit/RemoteGuard (rate limits, schema checks) or generated from a Blink schema (paths listed in release.json generated).",
     "source": "skill roblox-multiplayer-integrity"},
    {"id": "A03", "tier": "A", "title": "Catalog ready for release",
     "spec": "Monetization code needs a catalog/1 file (release.json catalog). It is in mode game, with only the top-level keys GameKit Catalog.define accepts (schema, mode, products) and a products list; keys are unique labels; kinds are devproduct, gamepass or subscription; ids are real (integers > 0, EXP- ids for subscriptions) and unique; every enabled product has ownershipVerified; grants are non-empty; display has a nameKey; adReward only on developer products with fixed grants; no price-like key anywhere. Code never hard-codes product, pass or subscription ids.",
     "source": "factory docs/runtime-kits.md (catalog/1); " + DOCS + "production/monetization/developer-products"},
    {"id": "A04", "tier": "A", "title": "Exactly one server receipt handler",
     "spec": "Developer products are granted only from one receipt handler (MarketplaceService.ProcessReceipt or BindReceiptHandler) in server code; none in client or shared code; no server grant keyed on PromptProductPurchaseFinished.",
     "source": DOCS + "production/monetization/developer-products"},
    {"id": "A05", "tier": "A", "title": "Paid random items disclosed and policy-gated",
     "spec": "Every paid random item (release.json paid_random_items) is tagged " + RANDOM_TAG + " in the catalog (the tag GameKit Commerce gates on PolicyGate paidRandomItems), and every catalog product with that tag is declared there. Each shows odds that sum to exactly 100% at display precision (2 decimals) through a localisation key before purchase, and the server applies a PolicyGate treatment for ArePaidRandomItemsRestricted (feature paidRandomItems). Trading of paid items is gated on IsPaidItemTradingAllowed (feature trading).",
     "source": DOCS + "production/monetization/paid-random-items (2026-10-02)"},
    {"id": "A06", "tier": "A", "title": "Player text is filtered",
     "spec": "When the game takes typed text (a TextBox), server code filters it through GameKit/TextFilter (TextService:FilterStringAsync); the client never filters. Roblox removes games that do not filter.",
     "source": DOCS + "ui/text-filtering (2026-10-01)"},
    {"id": "A07", "tier": "A", "title": "Motion and flash settings honoured",
     "spec": "Client code reads the reduced-motion preference (settings/1 reducedMotion or GuiService.ReducedMotionEnabled) and the flashes preference (reduceFlashing / allowFlashes).",
     "source": "factory docs/runtime-kits.md (settings/1)"},
    {"id": "A08", "tier": "A", "title": "Telemetry catalog defined and within limits",
     "spec": "The telemetry catalog (release.json telemetry) defines an onboarding funnel (1-100 steps); at most 10 funnels of 1-100 steps, 100 custom events with at most 3 fields, 5 currencies and 20 transaction types; names are lower_snake labels. Client and shared code never call AnalyticsService or require Telemetry.",
     "source": DOCS + "production/analytics (limits); factory docs/runtime-kits.md (kit-event/1)"},
    {"id": "A09", "tier": "A", "title": "Performance captures within budget",
     "spec": "Every declared device has a perf/1 stats capture (release.json perf.captures, from item S06) for one of its device classes, and each capture is within the perf/1 budgets for its class (frame_ms_p95, memory_mb, texture_mb_estimate and the counters).",
     "source": "factory docs/runtime-kits.md (perf/1); skill roblox-performance-pass"},
    {"id": "A10", "tier": "A", "title": "Asset provenance complete",
     "spec": "Every non-zero asset id in place content (src/, Rojo projects) is registered in assets/provenance.json as approved, with reviewer and script_review.",
     "source": "skill roblox-asset-intake"},
    {"id": "A11", "tier": "A", "title": "Localisation tables complete",
     "spec": "Localisation CSVs (Rojo LocalizationTable format: Key, Source, Context, Example, locale columns) parse; keys are present and unique; each translation keeps the Source placeholders; every key used in code (FormatByKey and similar) and every catalog display key exists.",
     "source": DOCS + "production/localization; rojo.space sync details"},
    {"id": "A12", "tier": "A", "title": "Debug tools disabled",
     "spec": "Config.debugCommands is not true; code that requires DebugCommands also checks RunService:IsStudio() (or Env.check / assertDiagnostic); no loadstring.",
     "source": "factory docs/runtime-kits.md (Env.check)"},
    {"id": "A13", "tier": "A", "title": "No deprecated or misused engine APIs",
     "spec": "Absent: GetProductInfo (use GetProductInfoAsync), PlayerOwnsAsset, PlayerOwnsBundle, UserHasBadge, PromptPremiumPurchase, FilterAndTranslateStringAsync, AnalyticsService:Fire*, ShowVideoAd, LegacyChatService, global wait/spawn/delay, tick(), LoadLibrary, legacy body movers. PromptGameInvite is preceded by CanSendGameInviteAsync and badge awards by GetBadgeInfoAsync in the same module.",
     "source": DOCS + "reference/engine; invite prompts and badges docs (2026-10-02)"},
    {"id": "A14", "tier": "A", "title": "Store and in-game text rules",
     "spec": "No hard-coded Robux prices (prices come from GetProductInfoAsync), no external URLs and no free-Robux or giveaway wording in client or shared code strings, localisation tables or release.json text.",
     "source": "Roblox Community Standards; " + DOCS + "production/promotion/social-media-links"},
    {"id": "A15", "tier": "A", "title": "Persistence through the data kit",
     "spec": "No direct DataStoreService use in src/ (sessions go through GameKit/PlayerData); client code never references PlayerData, ProfileStore or ServerPackages, and shared code never references ProfileStore or ServerPackages.",
     "source": "skill roblox-persistence-and-commerce"},
    {"id": "A16", "tier": "A", "title": "Publish-surface tripwire",
     "spec": "Committed workflows, tools and scripts contain no publish-capable command (rojo upload, mantle deploy, rbxcloud writes, tarmac/asphalt uploads, Wally or pesde registry uploads, versionType Published, place version or asset upload endpoints) unless the owner recorded an exception for that path.",
     "source": "AGENTS.md: publishing is owner-only"},
    {"id": "A17", "tier": "A", "title": "Release metadata and store art specs",
     "spec": "release/release.json (release-meta/1) is complete: name, description, genre and subgenre from Roblox's 17 genres, devices, audience (maturity label, reach), maturity summary, players, private servers XOR paid access, locales and version notes, all matching production/brief.json. Store art in the repo meets the specs: icon 512x512 square; thumbnails 16:9 in jpg, gif, png, tga or bmp, under 3 MB, at most 10; badge images 512x512; pass icons at most 512x512 in jpg, png or bmp.",
     "source": DOCS + "production/publishing/experience-icons, thumbnails, badges; production/monetization/passes (2026-10-02)"},
    # Studio (S): the owner's PC, an unpublished place built from this repo.
    {"id": "S01", "tier": "S", "title": "Critical flows in Play Solo and Server & Clients",
     "spec": "Join, onboarding, the core loop, fail and retry, leave and rejoin (data persists), each in Play Solo and in Server & Clients with 2+ clients; console free of errors.",
     "source": "skill roblox-release-pass"},
    {"id": "S02", "tier": "S", "title": "Mock purchases",
     "spec": "Developer products and passes only, in Studio test purchases: the receipt grants exactly once (repeat the prompt, rejoin mid-purchase); UI prices come from GetProductInfoAsync.",
     "source": DOCS + "production/monetization/developer-products"},
    {"id": "S03", "tier": "S", "title": "Player Emulator: locales and regions",
     "spec": "Each target locale (text fits, nothing untranslated where translations exist) and the regions that flip paid random items, trading and ads policy flags (Test > Player Emulator).",
     "source": DOCS + "studio/testing-modes (2026-10-02)"},
    {"id": "S04", "tier": "S", "title": "Device Simulator captures",
     "spec": "Screen captures of the main flows on each declared device (phone, tablet, console, desktop sizes), safe areas respected, touch and gamepad usable.",
     "source": "skill visual-qa"},
    {"id": "S05", "tier": "S", "title": "Telemetry sequence",
     "spec": "A Studio session with the telemetry recorder emits the expected onboarding, funnel and economy sequence (kit-event/1 lines).",
     "source": "factory docs/runtime-kits.md (kit-event/1)"},
    {"id": "S06", "tier": "S", "title": "Performance capture",
     "spec": "MicroProfiler / Script Profiler pass on the release candidate per device class; perf/1 stats saved under release/perf and listed in release.json perf.captures (feeds A09).",
     "source": "skill roblox-performance-pass"},
    {"id": "S07", "tier": "S", "title": "Boot report ok on both sides",
     "spec": "The BOOT_REPORT lines of the server and the client show ok=true in Play Solo and in Server & Clients; the loading screen clears; a forced phase failure shows the failed phase on the loading screen.",
     "source": "src/shared/Boot.luau"},
    # Owner (O): account, Creator Hub and publish actions.
    {"id": "O01", "tier": "O", "title": "Account requirements",
     "spec": "Public or Limited and 16+: account in good standing, at least 2 days old, age check (facial age estimation or government ID), maturity questionnaire complete. All ages including Kids (5-8) and Select (9-15): also account verification, 2FA and either 2 consecutive months of Roblox Plus/Premium or a refundable fee of 1,000 Robux (50,000 Robux for expedited review), and the game must pass evaluation; Kids needs a Minimal or Mild label, Select allows Moderate.",
     "source": DOCS + "production/publishing/publish-games-and-places; production/publishing/kids-and-select (2026-10-02)"},
    {"id": "O02", "tier": "O", "title": "Owner decided before the first publish",
     "spec": "User or group owner chosen before publishing. A transfer to a group keeps ids and URL but makes the game private and closes all servers; no re-transfer for 30 days; requests expire after 7 days.",
     "source": DOCS + "projects/game-ownership-transfer (2026-10-02)"},
    {"id": "O03", "tier": "O", "title": "Maturity & Compliance Questionnaire",
     "spec": "Complete and accurate: violence, blood, fear, crude humour, unplayable gambling, strong language, romance, alcohol, social hangouts, free-form user creation, sensitive issues, paid random items and trading, media sharing and content feeds, AI interactions. Inaccurate or missing answers restrict playability for everyone; Restricted is 18+ and unplayable in some regions. release.json maturity_summary is only the repo's summary of the answers.",
     "source": DOCS + "production/promotion/content-maturity (2026-10-02)"},
    {"id": "O04", "tier": "O", "title": "Audience progression",
     "spec": "Private (default), then Limited (playtesters, friends or community), then Public, in Creator Hub > Configure > Settings. At most 5 never-public private games can be made public per day.",
     "source": DOCS + "production/publishing/publish-games-and-places (2026-10-02)"},
    {"id": "O05", "tier": "O", "title": "Genre, devices, server size and access",
     "spec": "Genre (required, changeable once every 3 months) and subgenre as in release.json; playable devices; MaxPlayers and PreferredPlayers per place (Creator Dashboard); private servers or paid access, never both (paid access 25-1,000 Robux, public games only, not on Xbox, no refunds; changing a private-server price cancels active subscriptions).",
     "source": DOCS + "production/publishing/experience-genres; production/monetization/private-servers; production/monetization/paid-access-robux (2026-10-02)"},
    {"id": "O06", "tier": "O", "title": "Products, passes and subscriptions",
     "spec": "Created and priced in Creator Hub; their ids copied into the catalog with ownershipVerified (A03); Managed Pricing reviewed; GetUsersPriceLevelsAsync in place before regional pricing of developer products.",
     "source": DOCS + "production/monetization (2026-10-02)"},
    {"id": "O07", "tier": "O", "title": "Experience icon",
     "spec": "Square, made on the 512x512 template; readable down to 150x150; passes asset moderation (the file format is not stated in the docs).",
     "source": DOCS + "production/publishing/experience-icons (2026-10-02)"},
    {"id": "O08", "tier": "O", "title": "Thumbnails and video",
     "spec": "16:9, ideally 1920x1080, jpg/gif/png/tga/bmp, under 3 MB, up to 10 images or videos; 2 or more active thumbnails enable personalization (2-5 recommended). Video: 3 uploads per month, not on Xbox, PlayStation or VR, authentic in-game footage only: no misrepresented gameplay, real-world footage, spoken audio, music with lyrics, text claims or ads.",
     "source": DOCS + "production/publishing/thumbnails (2026-10-02)"},
    {"id": "O09", "tier": "O", "title": "Badges",
     "spec": "512x512 images shown with a circular crop; 5 free badges per game per 24 h, then 100 Robux each; only enabled badges are awarded (check GetBadgeInfoAsync).",
     "source": DOCS + "production/publishing/badges (2026-10-02)"},
    {"id": "O10", "tier": "O", "title": "Passes",
     "spec": "Pass icons up to 512x512 in jpg, png or bmp; passes are created after the first publish.",
     "source": DOCS + "production/monetization/passes (2026-10-02)"},
    {"id": "O11", "tier": "O", "title": "Friend invite prompt",
     "spec": "If the game prompts invites: an invite message is a Notification asset whose text has {experienceName} (required) and may have {displayName}; LaunchData is at most 200 characters (read with Player:GetJoinData); CanSendGameInviteAsync (in pcall) before SocialService:PromptGameInvite; a PromptMessage that overflows the UI is not shown.",
     "source": DOCS + "production/promotion/invite-prompts (2026-10-02)"},
    {"id": "O12", "tier": "O", "title": "Localisation settings",
     "spec": "Source language, Automatic Text Capture, Use Translated Content and Automatic Translation set in Experience Settings > Localization (18 languages; monthly character quotas; existing entries are never overwritten).",
     "source": DOCS + "production/localization/automatic-translations (2026-10-02)"},
    {"id": "O13", "tier": "O", "title": "Communication and social links",
     "spec": "Allow Strong Language decided; voice and camera settings; social links (up to 3, shown only to users age-checked 16+, the creator needs a 16+ age check); no social links inside the game.",
     "source": DOCS + "projects/configure-games; production/promotion/social-media-links (2026-09-23)"},
    {"id": "O14", "tier": "O", "title": "Publish from Studio",
     "spec": "The owner publishes (File > Publish to Roblox) with version notes. Agents never publish, upload or call publishing APIs.",
     "source": DOCS + "production/publishing/publish-games-and-places (2026-10-02)"},
    {"id": "O15", "tier": "O", "title": "After publish and rollback",
     "spec": "Restart choice (only servers with outdated versions, 1-60 minute delay); configs published; experiments started; rollback rehearsed: config kill switch first, Version History restore does not publish by itself.",
     "source": DOCS + "projects/update-games; projects/version-history (2026-10-02)"},
    # Post-publish (P): observations by the owner.
    {"id": "P01", "tier": "P", "title": "Performance dashboard",
     "spec": "Creator Hub performance filtered by place version (needs 100 or more daily active users).",
     "source": DOCS + "production/analytics"},
    {"id": "P02", "tier": "P", "title": "Funnels, economy and custom dashboards",
     "spec": "Populated (up to 24 h delay) and matching the S05 sequence.",
     "source": DOCS + "production/analytics"},
    {"id": "P03", "tier": "P", "title": "Retention, engagement, monetization and discovery",
     "spec": "D1/D7/D30 retention, playtime, monetization and discovery signals reviewed. Observations only, never pass or fail.",
     "source": DOCS + "production/analytics"},
]
ITEM_BY_ID = {item["id"]: item for item in ITEMS}
TIER_NAMES = {
    "A": "Automated (tools/release_check.py)",
    "S": "Studio, on the owner's PC",
    "O": "Owner: account, Creator Hub and publish",
    "P": "After publishing (owner observations)",
}

# ---------------------------------------------------------------- source scanning


LONG_COMMENT = re.compile(r"--\[(=*)\[")
LONG_STRING = re.compile(r"\[(=*)\[")


def strip_comments(text):
    """Luau source with comments removed (strings kept; line breaks kept so line numbers hold)."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "-" and text.startswith("--", i):
            m = LONG_COMMENT.match(text, i)
            if m:
                end = text.find("]" + m.group(1) + "]", m.end())
                end = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            out.append("\n" * text.count("\n", i, end))
            i = end
        elif c == "[" and LONG_STRING.match(text, i):
            level = LONG_STRING.match(text, i).group(1)
            end = text.find("]" + level + "]", i + len(level) + 2)
            end = n if end < 0 else end + len(level) + 2
            out.append(text[i:end])
            i = end
        elif c in "\"'`":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def realm_of(rel):
    parts = rel.split("/")
    if len(parts) < 2 or parts[0] != "src":
        return "other"
    return {"server": "server", "client": "client", "first": "client", "gui": "gui", "shared": "shared"}.get(parts[1], "shared")


class Source:
    def __init__(self, rel, raw):
        self.rel, self.raw, self.realm = rel, raw, realm_of(rel)
        self.code = strip_comments(raw)

    def line(self, index):
        return self.code.count("\n", 0, index) + 1

    def hits(self, regex):
        return [(self.line(m.start()), m) for m in regex.finditer(self.code)]


def walk_files(base, suffixes):
    if not base.is_dir():
        return []
    out = []
    for path in sorted(base.rglob("*")):
        if path.is_file() and path.suffix in suffixes and not (WALLY_DIRS & set(path.relative_to(base).parts)):
            out.append(path)
    return out


def load_sources(root):
    return [Source(p.relative_to(root).as_posix(), p.read_text(encoding="utf-8", errors="replace"))
            for p in walk_files(root / "src", {".luau", ".lua"})]


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "missing"
    except (OSError, ValueError) as err:
        return None, str(err)


def decided(value):
    return not production.is_tbd(value)


# ---------------------------------------------------------------- context


class Context:
    def __init__(self, root):
        self.root = root
        self.meta, self.meta_error = read_json(root / "release" / "release.json")
        if not isinstance(self.meta, dict):
            self.meta = {}
        self.brief, _ = read_json(root / "production" / "brief.json")
        if not isinstance(self.brief, dict):
            self.brief = {}
        self.sources = load_sources(root)
        self.records, self.owner_problems = production.owner_records(root)
        self.exceptions = owner_exceptions(root)
        catalog_rel = self.meta.get("catalog") or "src/shared/catalog.json"
        self.catalog_rel = catalog_rel
        self.catalog, self.catalog_error = read_json(root / catalog_rel)
        self.csv_keys, self.csv_problems, self.csv_files, self.csv_cells = load_localization(root, self.meta.get("localization") or ["src/localization"])

    def realm(self, *realms):
        return [s for s in self.sources if s.realm in realms]

    def any_code(self, regex, realms=None):
        return any(regex.search(s.code) for s in self.sources if realms is None or s.realm in realms)

    def products(self):
        if isinstance(self.catalog, dict) and isinstance(self.catalog.get("products"), list):
            return [p for p in self.catalog["products"] if isinstance(p, dict)]
        return []


def owner_exceptions(root):
    out = []
    for path in sorted((root / "release").glob("owner-*.json")):
        data, err = read_json(path)
        if err or not isinstance(data, dict) or data.get("schema") != OWNER_SCHEMA:
            continue
        for entry in data.get("exceptions", []):
            if isinstance(entry, dict) and entry.get("id") and entry.get("path") and entry.get("reason"):
                out.append({"id": entry["id"], "path": entry["path"], "file": f"release/{path.name}"})
    return out


def load_localization(root, dirs):
    keys, problems, files, cells = {}, [], [], []
    for entry in dirs:
        base = root / entry
        paths = [base] if base.is_file() else walk_files(base, {".csv"})
        for path in paths:
            rel = path.relative_to(root).as_posix()
            files.append(rel)
            try:
                rows = list(csv.reader(io.StringIO(path.read_text(encoding="utf-8-sig"))))
            except (OSError, csv.Error, UnicodeDecodeError) as err:
                problems.append(f"{rel}: does not parse ({err})")
                continue
            if not rows or "Key" not in rows[0] or "Source" not in rows[0]:
                problems.append(f"{rel}: the header needs Key and Source columns (Key,Source,Context,Example,<locales>)")
                continue
            header = rows[0]
            k, s = header.index("Key"), header.index("Source")
            locales = [i for i, name in enumerate(header) if name not in ("Key", "Source", "Context", "Example")]
            for number, row in enumerate(rows[1:], start=2):
                row = row + [""] * (len(header) - len(row))
                key, source = row[k].strip(), row[s]
                if not key:
                    problems.append(f"{rel}:{number}: a row without a Key")
                    continue
                if key in keys:
                    problems.append(f"{rel}:{number}: duplicate key {key} (first in {keys[key]})")
                keys.setdefault(key, f"{rel}:{number}")
                wanted = set(re.findall(r"\{[^{}]*\}", source))
                cells.append((rel, number, source))
                for i in locales:
                    text = row[i]
                    cells.append((rel, number, text))
                    if text and set(re.findall(r"\{[^{}]*\}", text)) != wanted:
                        problems.append(f"{rel}:{number}: {header[i]} placeholders differ from Source for key {key}")
    return keys, problems, files, cells


# ---------------------------------------------------------------- automated checks
# Each returns (problems, evidence). No problems: PASS.

def project_files(root):
    return sorted(root.glob("*.project.json"))


def prop_value(value):
    if isinstance(value, dict) and len(value) == 1:
        return next(iter(value.values()))
    return value


def node_path(node):
    raw = node.get("$path") if isinstance(node, dict) else None
    if isinstance(raw, dict):
        raw = raw.get("optional")
    return raw.replace("\\", "/").strip("/") if isinstance(raw, str) else None


def check_a01(ctx):
    problems, evidence = [], []
    projects = project_files(ctx.root)
    if not (ctx.root / "default.project.json").is_file():
        problems.append("default.project.json missing")
    engine = ctx.brief.get("engine") if isinstance(ctx.brief.get("engine"), dict) else {}
    for path in projects:
        data, err = read_json(path)
        if err:
            problems.append(f"{path.name}: {err}")
            continue
        tree = data.get("tree", {}) if isinstance(data, dict) else {}

        def walk(node, trail, replicated):
            if not isinstance(node, dict):
                return
            props = node.get("$properties")
            if isinstance(props, dict):
                if "FilteringEnabled" in props:
                    problems.append(f"{path.name}: {'.'.join(trail)} sets FilteringEnabled (deprecated; never override it)")
                if prop_value(props.get("LoadStringEnabled")) is True:
                    problems.append(f"{path.name}: {'.'.join(trail)} turns LoadStringEnabled on")
            target = node_path(node)
            if replicated and target:
                # Folded: Windows and macOS (case-insensitive) open Packages/ for packages/, Factory/ for factory/.
                head = [part for part in target.lower().replace("\\", "/").split("/") if part not in ("", ".")]
                if (len(head) == 1 and head[0] in {d.lower() for d in WALLY_DIRS}) \
                        or (head[:1] == [FACTORY_DIR] and (len(head) == 1 or (head[1] in {a.lower() for a in AUTHORING}
                                                                       and "/".join(head[1:]) not in {f.lower() for f in AUTHORING_LEAVES}))) \
                        or "/".join(head).startswith("src/server"):
                    problems.append(f"{path.name}: {'.'.join(trail)} maps {target} into a replicated service (server or authoring code reaches clients)")
            for key, child in node.items():
                if not key.startswith("$"):
                    walk(child, trail + [key], replicated or (len(trail) == 0 and key in REPLICATED_SERVICES))

        walk(tree, [], False)
        if path.name == "default.project.json":
            for entry in ENTRY_NODES:
                node = tree
                for name in entry:
                    node = node.get(name) if isinstance(node, dict) else None
                if not isinstance(node, dict):
                    problems.append(f"default.project.json: {'.'.join(entry)} is not mapped (boot entry point)")
            for key, (service, prop) in ENGINE_PROPERTIES.items():
                props = (tree.get(service) or {}).get("$properties") or {}
                if prop in props and decided(engine.get(key, production.TBD)) and prop_value(props[prop]) != engine[key]:
                    problems.append(f"default.project.json: {service}.{prop} is {prop_value(props[prop])!r} but the brief decided engine.{key} = {engine[key]!r}")
    evidence.append(f"{len(projects)} Rojo project(s) checked")
    return problems, evidence


REMOTE_HANDLER = re.compile(r"\.\s*OnServerEvent\b|\bOnServerInvoke\s*=")


def is_generated(ctx, src):
    listed = [g.strip("/") for g in ctx.meta.get("generated", []) if isinstance(g, str)]
    if any(src.rel == g or src.rel.startswith(g + "/") for g in listed):
        return True
    head = "\n".join(src.raw.splitlines()[:10]).lower()
    return "generated" in head and "blink" in head


def check_a02(ctx):
    problems, generated = [], 0
    for src in ctx.sources:
        if is_generated(ctx, src):
            generated += 1
            continue
        for line, match in src.hits(REMOTE_HANDLER):
            problems.append(f"{src.rel}:{line}: handles a remote directly ({match.group(0).strip('. ')}); register it through GameKit/RemoteGuard or a Blink schema")
    guarded = sum(1 for s in ctx.sources if "RemoteGuard" in s.code)
    return problems, [f"{len(ctx.sources)} source files, {guarded} use RemoteGuard, {generated} Blink-generated"]


MONETIZATION = re.compile(r"\bPrompt\w*Purchase\b|\bProcessReceipt\b|\bBindReceiptHandler\b|\bUserOwnsGamePassAsync\b")
ID_CALL = re.compile(r"\b(?:Prompt\w*Purchase|UserOwnsGamePassAsync|GetProductInfoAsync|GetSubscriptionProductInfoAsync)\s*\(([^()]*)\)")
PRICE_KEY = re.compile(r"^(price.*|cost|robux.*)$", re.IGNORECASE)
KINDS = {"devproduct", "gamepass", "subscription"}
GRANT_TYPES = {"currency", "item", "entitlement", "custom"}


def price_keys(value, trail="catalog"):
    found = []
    if isinstance(value, dict):
        for key, child in value.items():
            if PRICE_KEY.match(str(key)):
                found.append(f"{trail}.{key}")
            found += price_keys(child, f"{trail}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found += price_keys(child, f"{trail}[{index}]")
    return found


def check_a03(ctx):
    problems = []
    for src in ctx.sources:
        for line, match in src.hits(ID_CALL):
            if re.search(r"\b\d{4,}\b|EXP-\d+", match.group(1)):
                problems.append(f"{src.rel}:{line}: hard-coded product id in {match.group(0)[:60]}; read it from the catalog")
        for line, _ in src.hits(re.compile(r"[\"']EXP-\d+[\"']")):
            problems.append(f"{src.rel}:{line}: hard-coded subscription id; read it from the catalog")
    uses = ctx.any_code(MONETIZATION)
    if ctx.catalog_error == "missing":
        if uses:
            problems.append(f"monetization code but no catalog at {ctx.catalog_rel} (catalog/1)")
        return problems, ["no catalog and no monetization code" if not uses else ""]
    if ctx.catalog_error:
        return problems + [f"{ctx.catalog_rel}: {ctx.catalog_error}"], []
    catalog = ctx.catalog
    if not isinstance(catalog, dict) or catalog.get("schema") != "catalog/1":
        return problems + [f"{ctx.catalog_rel}: schema must be catalog/1"], []
    if catalog.get("mode") != "game":
        problems.append(f"{ctx.catalog_rel}: mode is {catalog.get('mode')!r}; a release needs mode game with real ids")
    for key in sorted(str(k) for k in catalog if k not in CATALOG_KEYS):
        problems.append(f"{ctx.catalog_rel}: unexpected top-level key {key!r} (GameKit Catalog.define accepts only {', '.join(CATALOG_KEYS)})")
    if not isinstance(catalog.get("products"), list):
        problems.append(f"{ctx.catalog_rel}: products must be a list")
    else:
        for index, product in enumerate(catalog["products"], 1):
            if not isinstance(product, dict):
                problems.append(f"{ctx.catalog_rel}: products[{index}] must be an object (GameKit Catalog.define rejects it)")
    keys, ids = set(), set()
    for index, product in enumerate(ctx.products()):
        key = product.get("key")
        where = f"{ctx.catalog_rel} product {key or index}"
        if not (isinstance(key, str) and LABEL.match(key)) or key in keys:
            problems.append(f"{where}: key must be a unique lower_snake label")
        keys.add(key)
        kind = product.get("kind")
        if kind not in KINDS:
            problems.append(f"{where}: kind must be one of {sorted(KINDS)}")
        pid = product.get("id")
        if kind == "subscription":
            real = isinstance(pid, str) and re.fullmatch(r"EXP-\d+", pid) and pid != "EXP-0"
        else:
            real = isinstance(pid, int) and not isinstance(pid, bool) and pid > 0
        if not real:
            problems.append(f"{where}: id {pid!r} is a placeholder or invalid (real ids only in mode game)")
        elif pid in ids:
            problems.append(f"{where}: duplicate id {pid}")
        ids.add(pid)
        for flag in ("enabled", "ownershipVerified"):
            if not isinstance(product.get(flag), bool):
                problems.append(f"{where}: {flag} must be true or false")
        if product.get("enabled") is True and product.get("ownershipVerified") is not True:
            problems.append(f"{where}: enabled without ownershipVerified (the owner confirms the id belongs to this game, item O06)")
        grants = product.get("grants")
        if not (isinstance(grants, list) and grants and all(isinstance(g, dict) and g.get("type") in GRANT_TYPES for g in grants)):
            problems.append(f"{where}: grants must be a non-empty list of currency, item, entitlement or custom grants")
        display = product.get("display")
        if not (isinstance(display, dict) and isinstance(display.get("nameKey"), str) and display["nameKey"]):
            problems.append(f"{where}: display.nameKey missing (localisation key, never text)")
        reward = product.get("adReward")
        if reward is not None and not isinstance(reward, bool):
            problems.append(f"{where}: adReward must be true or false (GameKit Catalog.define)")
        elif reward is True:
            fixed = isinstance(grants, list) and all(
                isinstance(g, dict) and g.get("type") in {"currency", "item", "entitlement"} for g in grants)
            if kind != "devproduct" or not fixed:
                problems.append(f"{where}: adReward only on developer products, with fixed currency, item or entitlement grants")
    for trail in price_keys(catalog):
        problems.append(f"{ctx.catalog_rel}: price-like key {trail}; prices are runtime reads (GetProductInfoAsync)")
    return problems, [f"{len(ctx.products())} product(s) in {ctx.catalog_rel}"]


RECEIPT = re.compile(r"\bProcessReceipt\s*=(?!=)|\bBindReceiptHandler\s*\(")


def check_a04(ctx):
    problems, handlers = [], []
    for src in ctx.sources:
        for line, _ in src.hits(RECEIPT):
            if src.realm == "server":
                handlers.append(f"{src.rel}:{line}")
            else:
                problems.append(f"{src.rel}:{line}: receipt handler outside server code")
        if src.realm == "server":
            for line, _ in src.hits(re.compile(r"\bPromptProductPurchaseFinished\b")):
                problems.append(f"{src.rel}:{line}: PromptProductPurchaseFinished on the server; grant developer products only from the receipt handler")
    devproducts = [p for p in ctx.products() if p.get("kind") == "devproduct" and p.get("enabled") is True]
    if devproducts and not handlers:
        problems.append(f"{len(devproducts)} enabled developer product(s) but no server receipt handler")
    if len(handlers) > 1:
        problems.append(f"{len(handlers)} receipt handlers ({', '.join(handlers)}); exactly one may exist")
    return problems, [f"receipt handlers: {', '.join(handlers) or 'none'}; enabled developer products: {len(devproducts)}"]


TWO_PLACES = Decimal("0.01")


def percent(value):
    return Decimal(str(value)).quantize(TWO_PLACES, rounding=ROUND_HALF_UP)


def check_a05(ctx):
    problems = []
    entries = ctx.meta.get("paid_random_items", [])
    if not isinstance(entries, list):
        return ["release.json paid_random_items must be a list"], []
    declared = {e.get("product") for e in entries if isinstance(e, dict)}
    tagged = {p.get("key") for p in ctx.products() if RANDOM_TAG in (p.get("tags") or [])}
    for key in sorted(tagged - declared, key=str):
        problems.append(f"catalog product {key} is tagged {RANDOM_TAG} but has no release.json paid_random_items entry")
    keys = {p.get("key") for p in ctx.products()}
    for index, entry in enumerate(entries):
        where = f"paid_random_items[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: must be an object")
            continue
        if ctx.catalog is not None and entry.get("product") not in keys:
            problems.append(f"{where}: product {entry.get('product')!r} is not in the catalog")
        elif ctx.catalog is not None and entry.get("product") not in tagged:
            problems.append(f"{where}: catalog product {entry.get('product')!r} is not tagged {RANDOM_TAG}, so Commerce prompts it without the PolicyGate paidRandomItems check")
        odds = entry.get("odds")
        if isinstance(odds, str):
            odds, err = read_json(ctx.root / odds)
            if err:
                problems.append(f"{where}: odds file {entry.get('odds')}: {err}")
                continue
        weights = entry.get("weights")
        if isinstance(weights, dict) and weights:
            if not all(isinstance(w, int) and not isinstance(w, bool) and w > 0 for w in weights.values()):
                problems.append(f"{where}: weights must be positive integers")
                continue
            total = sum(weights.values())
            odds = {k: Decimal(w) * 100 / total for k, w in weights.items()}
        if not (isinstance(odds, dict) and odds and all(isinstance(v, (int, float, Decimal)) and not isinstance(v, bool) and v > 0 for v in odds.values())):
            problems.append(f"{where}: odds must map outcomes to positive percentages (or weights to positive integers)")
            continue
        shown = sum(percent(v) for v in odds.values())
        if shown != Decimal("100.00"):
            problems.append(f"{where}: displayed odds sum to {shown}% at 2 decimals; they must sum to exactly 100%")
        key = entry.get("disclosure_key")
        if not (isinstance(key, str) and key in ctx.csv_keys):
            problems.append(f"{where}: disclosure_key {key!r} is not a localisation key (odds are shown before purchase)")
    if entries:
        server = ctx.realm("server")
        if not any(re.search(r"paidRandomItems|ArePaidRandomItemsRestricted", s.code) for s in server):
            problems.append("paid random items but no server policy treatment (PolicyGate feature paidRandomItems / ArePaidRandomItemsRestricted)")
        trades = any(re.search(r"require\([^)]*\bTrade\b", s.code) for s in ctx.sources)
        if trades and not any(re.search(r"\btrading\b|IsPaidItemTradingAllowed", s.code) for s in server):
            problems.append("trading with paid random items but no IsPaidItemTradingAllowed gate (PolicyGate feature trading)")
    return problems, [f"{len(entries)} paid random item(s) declared"]


def check_a06(ctx):
    problems = []
    boxes = [s.rel for s in ctx.sources if re.search(r"\bTextBox\b", s.code)]
    for path in walk_files(ctx.root / "src", {".rbxmx", ".json"}):
        if path.name.endswith((".model.json", ".rbxmx")) and "TextBox" in path.read_text(encoding="utf-8", errors="ignore"):
            boxes.append(path.relative_to(ctx.root).as_posix())
    for src in ctx.realm("client", "gui", "shared"):
        for line, _ in src.hits(re.compile(r"\bFilterStringAsync\b")):
            problems.append(f"{src.rel}:{line}: FilterStringAsync outside server code (filtering is server-only)")
    if boxes and not any(re.search(r"\bTextFilter\b|\bFilterStringAsync\b", s.code) for s in ctx.realm("server")):
        problems.append(f"text input ({', '.join(sorted(set(boxes))[:3])}) but no server text filtering (GameKit/TextFilter)")
    return problems, [f"text input in {len(set(boxes))} file(s)"]


def check_a07(ctx):
    client = ctx.realm("client", "gui", "shared")
    motion = [s.rel for s in client if re.search(r"\breducedMotion\b|\bReducedMotionEnabled\b", s.code)]
    flashes = [s.rel for s in client if re.search(r"\breduceFlashing\b|\ballowFlashes\b", s.code)]
    problems = []
    if not motion:
        problems.append("no client code reads reducedMotion / GuiService.ReducedMotionEnabled")
    if not flashes:
        problems.append("no client code reads reduceFlashing / allowFlashes")
    return problems, [f"reduced motion read in {len(motion)} file(s), flashes in {len(flashes)}"]


def labels(values, where, problems):
    for value in values:
        if not (isinstance(value, str) and LABEL.match(value)):
            problems.append(f"{where}: {value!r} is not a lower_snake label (max 64)")


def check_a08(ctx):
    problems = []
    rel = ctx.meta.get("telemetry") or "src/shared/telemetry.json"
    data, err = read_json(ctx.root / rel)
    for src in ctx.realm("client", "gui", "shared"):
        for line, _ in src.hits(re.compile(r"\bAnalyticsService\b|require\([^)]*\bTelemetry\b")):
            problems.append(f"{src.rel}:{line}: analytics from client or shared code (server only)")
    if err:
        return problems + [f"{rel}: {err}"], []
    if not isinstance(data, dict):
        return problems + [f"{rel}: must be an object"], []
    onboarding = data.get("onboarding")
    if not (isinstance(onboarding, list) and 1 <= len(onboarding) <= 100):
        problems.append(f"{rel}: onboarding must list 1-100 steps (the onboarding funnel)")
    else:
        labels(onboarding, f"{rel} onboarding", problems)
    funnels = data.get("funnels") or {}
    if not isinstance(funnels, dict) or len(funnels) > 10:
        problems.append(f"{rel}: at most 10 funnels")
    else:
        labels(funnels.keys(), f"{rel} funnels", problems)
        for name, funnel in funnels.items():
            steps = funnel.get("steps") if isinstance(funnel, dict) else None
            if not (isinstance(steps, list) and 1 <= len(steps) <= 100):
                problems.append(f"{rel}: funnel {name} needs 1-100 steps")
            else:
                labels(steps, f"{rel} funnel {name}", problems)
    custom = data.get("custom") or {}
    if not isinstance(custom, dict) or len(custom) > 100:
        problems.append(f"{rel}: at most 100 custom events")
    else:
        labels(custom.keys(), f"{rel} custom", problems)
        for name, spec in custom.items():
            fields = (spec or {}).get("fields", []) if isinstance(spec, dict) else None
            if not isinstance(fields, list) or len(fields) > 3:
                problems.append(f"{rel}: custom event {name} has more than 3 fields")
            else:
                labels(fields, f"{rel} custom {name} fields", problems)
    economy = data.get("economy") or {}
    currencies = economy.get("currencies", []) if isinstance(economy, dict) else None
    types = economy.get("transactionTypes", []) if isinstance(economy, dict) else None
    if not isinstance(currencies, list) or len(currencies) > 5:
        problems.append(f"{rel}: at most 5 currencies")
    else:
        labels(currencies, f"{rel} currencies", problems)
    if not isinstance(types, list) or len(types) > 20:
        problems.append(f"{rel}: at most 20 transaction types")
    else:
        labels([t for t in types if t not in STANDARD_TRANSACTION_TYPES], f"{rel} transaction types", problems)
    progression = data.get("progression") or {}
    if isinstance(progression, dict):
        labels(progression.keys(), f"{rel} progression", problems)
    return problems, [f"{rel}: {len(onboarding or [])} onboarding steps, {len(funnels)} funnels, {len(custom)} custom events"]


PERF_COUNTERS = ["instances", "parts", "triangles", "shadowed_lights", "particle_rate", "playing_sounds", "highlights"]


def capture_values(stats):
    values = {}
    frame = stats.get("frame_ms") or {}
    if isinstance(frame.get("p95"), (int, float)):
        values["frame_ms_p95"] = frame["p95"]
    memory = stats.get("memory_mb") or {}
    if isinstance(memory.get("total"), (int, float)):
        values["memory_mb"] = memory["total"]
    if isinstance(stats.get("texture_mb_estimate"), (int, float)):
        values["texture_mb_estimate"] = stats["texture_mb_estimate"]
    for name in PERF_COUNTERS:
        value = (stats.get("counts") or {}).get(name)
        if isinstance(value, (int, float)):
            values[name] = value
    return values


def check_a09(ctx):
    problems = []
    perf = ctx.meta.get("perf") or {}
    devices = ctx.meta.get("devices")
    if not decided(devices) or not isinstance(devices, list):
        return ["release.json devices is TBD; performance is checked per declared device"], []
    budgets, err = read_json(ctx.root / (perf.get("budgets") or "release/perf/budgets.json"))
    if err or not isinstance(budgets, dict) or budgets.get("kind") != "budgets":
        return [f"perf/1 budgets file: {err or 'not a perf/1 budgets document'}"], []
    classes = budgets.get("classes") or {}
    covered = {}
    for rel in perf.get("captures") or []:
        stats, err = read_json(ctx.root / rel)
        if err or not isinstance(stats, dict) or stats.get("kind") != "stats":
            problems.append(f"{rel}: {err or 'not a perf/1 stats capture'}")
            continue
        cls = stats.get("device_class")
        budget = classes.get(cls)
        if not isinstance(budget, dict) or not budget or production.is_tbd(budget):
            problems.append(f"{rel}: no decided budget for device class {cls!r}")
            continue
        covered.setdefault(cls, []).append(rel)
        for name, value in capture_values(stats).items():
            limit = budget.get(name)
            if isinstance(limit, (int, float)) and not isinstance(limit, bool) and value > limit:
                problems.append(f"{rel}: {name} {value} over the {cls} budget {limit}")
    for device in devices:
        options = production.DEVICES.get(device, [])
        if not any(c in covered for c in options):
            problems.append(f"device {device}: no capture for device class {' or '.join(options) or '?'} (release item S06)")
    return problems, [f"{sum(len(v) for v in covered.values())} capture(s) for {', '.join(sorted(covered)) or 'no class'}"]


ASSET_ID_PATTERNS = [
    re.compile(r"rbxassetid://(\d+)", re.IGNORECASE),
    re.compile(r"rbxthumb://[^\s\"'<>]*?\bid=(\d+)", re.IGNORECASE),
    re.compile(r"https?://(?:[a-z0-9-]+\.)*roblox\.com/(?:[a-z-]+/)*?(?:asset|library|catalog|bundles|badges|game-pass|games|marketplace/asset|store/asset)/(\d+)", re.IGNORECASE),
    re.compile(r"https?://(?:[a-z0-9-]+\.)*roblox\.com/[^\s\"'<>]*?[?&](?:id|assetid)=(\d+)", re.IGNORECASE),
    re.compile(r"\b(?:asset|mesh|texture|sound|animation|image|decal)_?id\b[\"']?\s*[:=]\s*[\"']?(\d+)\b", re.IGNORECASE),
]
CONTENT_SUFFIXES = (".luau", ".lua", ".rbxmx", ".rbxlx", ".project.json", ".model.json", ".meta.json")


def asset_ids_in(text):
    hits = set()
    for regex in ASSET_ID_PATTERNS:
        for match in regex.finditer(text):
            hits.add((text.count("\n", 0, match.start()) + 1, int(match.group(1))))
    return sorted(hits)


def provenance_registry(root):
    data, err = read_json(root / "assets" / "provenance.json")
    if err or not isinstance(data, dict) or not isinstance(data.get("assets"), list):
        return None, f"assets/provenance.json: {err or 'needs an assets list (asset-provenance/1)'}"
    return {e.get("id"): e for e in data["assets"] if isinstance(e, dict)}, None


def asset_problems(root, paths):
    """Ids in place content that are not approved with reviewer and script_review (shared with tools/check.py)."""
    registry, err = provenance_registry(root)
    if err:
        return [err], 0
    problems, count = [], 0
    for path in paths:
        rel = path.relative_to(root).as_posix()
        for line, aid in asset_ids_in(path.read_text(encoding="utf-8", errors="ignore")):
            if aid == 0:
                continue
            count += 1
            entry = registry.get(aid)
            if entry is None:
                problems.append(f"{rel}:{line}: asset id {aid} is not registered in assets/provenance.json")
            elif rel.endswith(CONTENT_SUFFIXES) and entry.get("approval") != "approved":
                problems.append(f"{rel}:{line}: asset id {aid} is {entry.get('approval')!r}; only approved assets go in place content")
            elif entry.get("approval") == "approved" and not (str(entry.get("reviewer", "")).strip() and str(entry.get("script_review", "")).strip()):
                problems.append(f"{rel}:{line}: asset id {aid} is approved without reviewer and script_review")
    return problems, count


def place_content(root):
    paths = [p for p in walk_files(root / "src", {".luau", ".lua", ".rbxmx", ".rbxlx", ".json"}) if p.name.endswith(CONTENT_SUFFIXES) or p.suffix in (".luau", ".lua")]
    return paths + project_files(root)


def check_a10(ctx):
    problems, count = asset_problems(ctx.root, place_content(ctx.root))
    return problems, [f"{count} asset id reference(s) in place content"]


BY_KEY = re.compile(r"ByKey\s*\(\s*[\"']([^\"']+)[\"']")


def check_a11(ctx):
    problems = list(ctx.csv_problems)
    if not ctx.csv_files:
        problems.append("no localisation table (release.json localization: CSV files or folders)")
    for src in ctx.sources:
        for line, match in src.hits(BY_KEY):
            if match.group(1) not in ctx.csv_keys:
                problems.append(f"{src.rel}:{line}: localisation key {match.group(1)} is not in any table")
    for product in ctx.products():
        display = product.get("display") if isinstance(product.get("display"), dict) else {}
        for field in ("nameKey", "descriptionKey"):
            key = display.get(field)
            if isinstance(key, str) and key not in ctx.csv_keys:
                problems.append(f"catalog {product.get('key')}: {field} {key} is not in any localisation table")
    return problems, [f"{len(ctx.csv_files)} table(s), {len(ctx.csv_keys)} key(s)"]


def check_a12(ctx):
    problems = []
    config = ctx.root / "src" / "shared" / "Config.luau"
    if config.is_file() and re.search(r"\bdebugCommands\s*=\s*true\b", strip_comments(config.read_text(encoding="utf-8"))):
        problems.append("src/shared/Config.luau: debugCommands = true")
    for src in ctx.sources:
        if re.search(r"\bDebugCommands\b", src.code) and src.rel != "src/shared/Config.luau" \
                and not re.search(r"IsStudio\s*\(|assertDiagnostic|Env\.check", src.code):
            problems.append(f"{src.rel}: uses DebugCommands without an IsStudio() / Env.check guard")
        for line, _ in src.hits(re.compile(r"\bloadstring\s*\(")):
            problems.append(f"{src.rel}:{line}: loadstring")
    return problems, ["debug switches checked"]


DEPRECATED = [
    (re.compile(r"\bGetProductInfo\s*\("), "GetProductInfo (use GetProductInfoAsync)"),
    (re.compile(r"\bPlayerOwnsAsset\s*\("), "PlayerOwnsAsset (use PlayerOwnsAssetAsync)"),
    (re.compile(r"\bPlayerOwnsBundle\s*\("), "PlayerOwnsBundle (use PlayerOwnsBundleAsync)"),
    (re.compile(r"\bUserHasBadge\s*\("), "UserHasBadge (use UserHasBadgeAsync)"),
    (re.compile(r"\bPromptPremiumPurchase\b"), "PromptPremiumPurchase"),
    (re.compile(r"\bFilterAndTranslateStringAsync\b"), "FilterAndTranslateStringAsync"),
    (re.compile(r"\bAnalyticsService\s*:\s*Fire\w*"), "AnalyticsService:Fire* (use the Log* methods through Telemetry)"),
    (re.compile(r"\bShowVideoAd\b"), "ShowVideoAd"),
    (re.compile(r"\bLegacyChatService\b|\bChatServiceRunner\b"), "legacy chat (use TextChatService)"),
    (re.compile(r"(?<![\w.:])(?<!function )(?:wait|spawn|delay)\s*\("), "global wait/spawn/delay (use task.*)"),
    (re.compile(r"(?<![\w.:])tick\s*\(\s*\)"), "tick() (use time() or os.clock())"),
    (re.compile(r"\bLoadLibrary\b"), "LoadLibrary"),
    (re.compile(r"Instance\.new\(\s*[\"']Body(?:Velocity|Gyro|Position|Force|AngularVelocity|Thrust)[\"']"), "legacy body mover (use constraints)"),
]
PAIRED = [
    (re.compile(r"\bPromptGameInvite\s*\("), re.compile(r"\bCanSendGameInviteAsync\b"), "PromptGameInvite without CanSendGameInviteAsync"),
    (re.compile(r"\bAwardBadge(?:Async)?\s*\("), re.compile(r"\bGetBadgeInfoAsync\b"), "badge award without GetBadgeInfoAsync (award only enabled badges)"),
]


def check_a13(ctx):
    problems = []
    for src in ctx.sources:
        for regex, why in DEPRECATED:
            for line, _ in src.hits(regex):
                problems.append(f"{src.rel}:{line}: {why}")
        for use, needed, why in PAIRED:
            if use.search(src.code) and not needed.search(src.code):
                problems.append(f"{src.rel}:{src.line(use.search(src.code).start())}: {why}")
    return problems, [f"{len(ctx.sources)} source files scanned"]


PRICE_TEXT = re.compile(r"R\$\s*\d|\d[\d,.]*\s*(?:Robux|R\$)|\s*\d", re.IGNORECASE)
URL_TEXT = re.compile(r"https?://|\bwww\.[a-z0-9-]+\.|discord\.gg/", re.IGNORECASE)
GIVEAWAY = re.compile(r"free\s*robux|robux\s*giveaway|\bgiveaways?\b", re.IGNORECASE)
STRING = re.compile(r"\"(?:[^\"\\\n]|\\.)*\"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`")


def check_a14(ctx):
    problems = []
    texts = []
    for src in ctx.realm("client", "gui", "shared"):
        for match in STRING.finditer(src.code):
            texts.append((f"{src.rel}:{src.line(match.start())}", match.group(0)))
    texts += [(f"{rel}:{number}", text) for rel, number, text in ctx.csv_cells]
    for field in ("name", "description", "version_notes"):
        if isinstance(ctx.meta.get(field), str):
            texts.append((f"release.json {field}", ctx.meta[field]))
    for where, text in texts:
        if PRICE_TEXT.search(text):
            problems.append(f"{where}: hard-coded Robux price; show prices from GetProductInfoAsync")
        if URL_TEXT.search(text):
            problems.append(f"{where}: external URL in player-facing text (only the store page's social links may link out)")
        if GIVEAWAY.search(text):
            problems.append(f"{where}: free-Robux or giveaway wording")
    return problems, [f"{len(texts)} player-facing string(s) scanned"]


def check_a15(ctx):
    problems = []
    for src in ctx.sources:
        for line, _ in src.hits(re.compile(r"\bDataStoreService\b|:\s*GetDataStore\s*\(|:\s*GetOrderedDataStore\s*\(|:\s*GetGlobalDataStore\s*\(")):
            problems.append(f"{src.rel}:{line}: direct DataStore use; sessions go through GameKit/PlayerData")
        if src.realm in CLIENT_REALMS:
            pattern = r"\bPlayerData\b|\bProfileStore\b|\bServerPackages\b"
        elif src.realm == "shared":
            pattern = r"\bProfileStore\b|\bServerPackages\b"
        else:
            continue
        for line, match in src.hits(re.compile(pattern)):
            problems.append(f"{src.rel}:{line}: {match.group(0)} referenced from {src.realm} code (server-only)")
    return problems, ["persistence boundaries checked"]


PUBLISH_PATTERNS = [
    re.compile(r"\brojo(?:\.exe)?\b[^\n]{0,80}?\bupload\b", re.IGNORECASE),
    re.compile(r"\bmantle\b[^\n]{0,40}?\b(?:deploy|destroy)\b", re.IGNORECASE),
    re.compile(r"\btarmac\b[^\n]{0,80}?\b(?:upload-image|sync)\b", re.IGNORECASE),
    re.compile(r"\basphalt\b[^\n]{0,40}?\b(?:sync|upload)\b", re.IGNORECASE),
    re.compile(r"\brbxcloud\b[^\n]{0,80}?\b(?:publish|create|update|set|delete|increment|remove|archive|restore|execute|send)\b", re.IGNORECASE),
    re.compile(r"\b(?:wally|pesde)\b[^\n]{0,40}?\bpublish\b", re.IGNORECASE),
    re.compile(r"versionType\W{0,4}Published", re.IGNORECASE),
    re.compile(r"/universes/[^\s\"']*/places/[^\s\"']*/versions", re.IGNORECASE),
    re.compile(r"apis\.roblox\.com/assets/v1/assets", re.IGNORECASE),
]
TRIPWIRE_DIRS = [".github", "tools", "scripts", ".codex", ".claude"]
TRIPWIRE_SUFFIXES = {".yml", ".yaml", ".sh", ".ps1", ".bat", ".cmd", ".py", ".mjs", ".js", ".ts", ".toml", ".json", ".luau", ".lua"}
TRIPWIRE_EXEMPT = ("tools/hooks/", "tools/release_check.py", ".claude/settings.json", ".codex/rules/", ".codex/hooks.json")


def tripwire_files(root):
    files = [p for p in root.iterdir() if p.is_file() and (p.suffix in TRIPWIRE_SUFFIXES or p.name == "Makefile")]
    for name in TRIPWIRE_DIRS:
        files += walk_files(root / name, TRIPWIRE_SUFFIXES)
    rels = {p: p.relative_to(root).as_posix() for p in files}
    return sorted(p for p, rel in rels.items() if not rel.startswith(TRIPWIRE_EXEMPT) and "/skills/" not in "/" + rel)


def check_a16(ctx):
    hits, excepted = [], []
    allowed = {(e["path"].strip("/")): e["file"] for e in ctx.exceptions if e["id"] == "A16"}
    for path in tripwire_files(ctx.root):
        rel = path.relative_to(ctx.root).as_posix()
        text = path.read_text(encoding="utf-8", errors="ignore")
        for regex in PUBLISH_PATTERNS:
            for match in regex.finditer(text):
                where = f"{rel}:{text.count(chr(10), 0, match.start()) + 1}: {match.group(0)[:60]}"
                (excepted if rel in allowed else hits).append(where)
    evidence = [f"excepted by the owner: {e}" for e in excepted]
    return [f"{h} (publish-capable; publishing is owner-only)" for h in hits], evidence or ["no publish-capable command found"]


THUMB_FORMATS = {"jpg", "jpeg", "gif", "png", "tga", "bmp"}
PASS_FORMATS = {"jpg", "jpeg", "png", "bmp"}


def image_info(path):
    """(format, width, height) from the file header, or (None, 0, 0)."""
    data = Path(path).read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        w, h = struct.unpack(">II", data[16:24])
        return "png", w, h
    if data[:6] in (b"GIF87a", b"GIF89a"):
        w, h = struct.unpack("<HH", data[6:10])
        return "gif", w, h
    if data[:2] == b"BM" and len(data) >= 26:
        w, h = struct.unpack("<ii", data[18:26])
        return "bmp", w, abs(h)
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return "jpg", w, h
            i += 2 + length
        return None, 0, 0
    if Path(path).suffix.lower() == ".tga" and len(data) >= 18:
        w, h = struct.unpack("<HH", data[12:16])
        return "tga", w, h
    return None, 0, 0


def art_problems(root, art):
    problems = []
    if not isinstance(art, dict):
        return ["store_art must be an object"]

    def files(key):
        value = art.get(key) or []
        return [value] if isinstance(value, str) else [v for v in value if isinstance(v, str)]

    def info(rel):
        path = root / rel
        if not path.is_file():
            problems.append(f"store_art: {rel} missing")
            return None
        fmt, w, h = image_info(path)
        if fmt is None:
            problems.append(f"store_art: {rel} is not a readable png, jpg, gif, bmp or tga image")
            return None
        return fmt, w, h, path.stat().st_size

    for rel in files("icon"):
        got = info(rel)
        if got and (got[1], got[2]) != (512, 512):
            problems.append(f"store_art icon {rel}: {got[1]}x{got[2]}; the icon template is 512x512 square")
    thumbs = files("thumbnails")
    if len(thumbs) > 10:
        problems.append(f"store_art: {len(thumbs)} thumbnails; at most 10")
    for rel in thumbs:
        got = info(rel)
        if got:
            fmt, w, h, size = got
            if fmt not in THUMB_FORMATS:
                problems.append(f"store_art thumbnail {rel}: format {fmt}")
            if w * 9 != h * 16:
                problems.append(f"store_art thumbnail {rel}: {w}x{h} is not 16:9 (1920x1080 recommended)")
            if size >= 3 * 1024 * 1024:
                problems.append(f"store_art thumbnail {rel}: {size} bytes; keep thumbnails under 3 MB")
    for rel in files("badges"):
        got = info(rel)
        if got and (got[1], got[2]) != (512, 512):
            problems.append(f"store_art badge {rel}: {got[1]}x{got[2]}; badge images are 512x512 (circular crop)")
    for rel in files("passes"):
        got = info(rel)
        if got and (got[0] not in PASS_FORMATS or got[1] > 512 or got[2] > 512):
            problems.append(f"store_art pass icon {rel}: {got[0]} {got[1]}x{got[2]}; at most 512x512 in jpg, png or bmp")
    return problems


def check_a17(ctx):
    meta = ctx.meta
    if ctx.meta_error:
        return [f"release/release.json: {ctx.meta_error}"], []
    problems = []
    if meta.get("schema") != META_SCHEMA:
        problems.append(f"release.json schema must be {META_SCHEMA!r}")
    for field in ("name", "description", "maturity_summary", "version_notes"):
        if not decided(meta.get(field, production.TBD)) or not production.text_ok(meta.get(field)):
            problems.append(f"release.json {field} is TBD or empty")
    genre = meta.get("genre") if isinstance(meta.get("genre"), dict) else {}
    primary, sub = genre.get("primary"), genre.get("subgenre", None)
    if primary not in production.GENRES:
        problems.append(f"release.json genre.primary {primary!r} is not one of Roblox's 17 genres")
    elif sub is not None and sub not in production.GENRES[primary]:
        problems.append(f"release.json genre.subgenre {sub!r} is not a {primary} subgenre (null when none)")
    devices = meta.get("devices")
    if not (isinstance(devices, list) and devices and all(d in production.DEVICES for d in devices)):
        problems.append(f"release.json devices must be a non-empty list from {sorted(production.DEVICES)}")
    audience = meta.get("audience") if isinstance(meta.get("audience"), dict) else {}
    label, reach = audience.get("maturity_label"), audience.get("reach")
    if label not in production.MATURITY_LABELS:
        problems.append(f"release.json audience.maturity_label must be one of {production.MATURITY_LABELS} (the questionnaire's result, item O03)")
    if reach not in ("16_plus", "all_ages"):
        problems.append("release.json audience.reach must be 16_plus or all_ages")
    elif reach == "all_ages" and label == "Restricted":
        problems.append("release.json: a Restricted label cannot reach all ages")
    players = meta.get("players") if isinstance(meta.get("players"), dict) else {}
    top, preferred = players.get("max"), players.get("preferred")
    if not (isinstance(top, int) and isinstance(preferred, int) and 1 <= preferred <= top):
        problems.append("release.json players needs integers max and preferred with 1 <= preferred <= max")
    access = meta.get("access") if isinstance(meta.get("access"), dict) else {}
    if not all(isinstance(access.get(k), bool) for k in ("private_servers", "paid_access")):
        problems.append("release.json access.private_servers and access.paid_access must be true or false")
    elif access["private_servers"] and access["paid_access"]:
        problems.append("release.json: private servers and paid access cannot be combined")
    locales = meta.get("locales") if isinstance(meta.get("locales"), dict) else {}
    source, targets = locales.get("source"), locales.get("targets")
    if not (isinstance(source, str) and production.LOCALE.match(source)) or not (isinstance(targets, list) and all(isinstance(t, str) and production.LOCALE.match(t) for t in targets)):
        problems.append("release.json locales needs a source locale id and a list of target locale ids")
    brief = ctx.brief
    pairs = [
        ("genre", genre, brief.get("genre")),
        ("devices", devices, brief.get("devices")),
        ("players", {"max": top, "preferred": preferred}, brief.get("players_per_server")),
        ("locales", locales, brief.get("locales")),
        ("audience.maturity_label", label, (brief.get("audience") or {}).get("maturity_label") if isinstance(brief.get("audience"), dict) else None),
    ]
    for name, mine, theirs in pairs:
        if theirs is None or production.is_tbd(theirs):
            problems.append(f"production/brief.json {name} is TBD; decide it before release")
        elif name == "devices" and isinstance(mine, list) and isinstance(theirs, list):
            if sorted(mine) != sorted(theirs):
                problems.append(f"release.json devices {mine} differ from the brief {theirs}")
        elif mine != theirs:
            problems.append(f"release.json {name} {mine!r} differs from the brief {theirs!r}")
    problems += art_problems(ctx.root, meta.get("store_art") or {})
    return problems, [f"genre {primary or '?'}, devices {devices if isinstance(devices, list) else '?'}"]


CHECKS = {f"A{n:02d}": globals()[f"check_a{n:02d}"] for n in range(1, 18)}


# ---------------------------------------------------------------- report and runbook


def run_checks(root):
    root = Path(root).resolve()
    ctx = Context(root)
    items = []
    for item in ITEMS:
        entry = {"id": item["id"], "tier": item["tier"], "title": item["title"], "spec": item["spec"], "source": item["source"]}
        if item["tier"] == "A":
            try:
                problems, evidence = CHECKS[item["id"]](ctx)
            except Exception as err:  # a crash is a failure, never a pass
                problems, evidence = [f"checker error: {type(err).__name__}: {err}"], []
            evidence = [e for e in evidence if e]
            if item["id"] == "A16" and not problems and any(e.startswith("excepted") for e in evidence):
                status = "WAIVED_BY_OWNER"
            else:
                status = "FAIL" if problems else "PASS"
            entry.update(status=status, problems=problems, evidence=evidence)
        else:
            record = ctx.records.get(item["id"])
            entry.update(status="OWNER_REQUIRED", problems=[], evidence=[], owner_record=record)
        items.append(entry)
    automated = [i for i in items if i["tier"] == "A"]
    owner = [i for i in items if i["tier"] != "A"]
    summary = {
        "automated_pass": sum(i["status"] == "PASS" for i in automated),
        "automated_fail": sum(i["status"] == "FAIL" for i in automated),
        "automated_waived": sum(i["status"] == "WAIVED_BY_OWNER" for i in automated),
        "owner_required": len(owner),
        "owner_recorded": sum(1 for i in owner if i.get("owner_record")),
        "owner_file_problems": ctx.owner_problems,
        "agent_checks_pass": all(i["status"] != "FAIL" for i in automated),
        "publish": "owner-only",
    }
    return {"schema": SCHEMA, "generated_by": "tools/release_check.py", "summary": summary, "items": items}


def runbook_text():
    lines = [
        "# Release runbook",
        "",
        "Generated from the checklist in `tools/release_check.py` (`python3 tools/release_check.py --write-runbook docs/release-runbook.md`);",
        "do not edit by hand. Skill: roblox-release-pass.",
        "",
        "- Run `python3 tools/release_check.py` (or `python3 tools/check.py --tier pre-release`). It writes `release/report.json`",
        "  (release-check/1) and exits 1 while an automated item fails.",
        "- Automated items (A) report PASS or FAIL. Every Studio (S), owner (O) and post-publish (P) item reports",
        "  OWNER_REQUIRED, always: no tool or agent can pass it. The owner records what they did in a",
        "  `release/owner-<name>.json` file (below); the report then shows it as `owner_record`.",
        "- Publishing, uploads, product creation and every Creator Hub setting are the owner's. Agents prepare and check;",
        "  the owner publishes from Studio.",
        "",
        "Owner record (release-owner/1), written by the owner only:",
        "",
        "```json",
        '{"schema": "release-owner/1", "owner": "<owner or role>",',
        ' "records": [{"id": "O03", "date": "YYYY-MM-DD", "note": "questionnaire answered; label Mild"}],',
        ' "exceptions": [{"id": "A16", "path": "<file>", "reason": "<why this file may hold a publish command>", "date": "YYYY-MM-DD"}]}',
        "```",
        "",
    ]
    for tier, name in TIER_NAMES.items():
        lines += [f"## {name}", "", "| ID | Item | Spec | Source |", "|---|---|---|---|"]
        for item in ITEMS:
            if item["tier"] == tier:
                spec = item["spec"].replace("|", "\\|")
                lines.append(f"| {item['id']} | {item['title']} | {spec} | {item['source'].replace('|', '/')} |")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="game repository root")
    ap.add_argument("--out", help="report path (default <root>/release/report.json)")
    ap.add_argument("--write-runbook", metavar="PATH", help="write the runbook generated from the checklist and exit")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    if args.write_runbook:
        target = Path(args.write_runbook)
        target = target if target.is_absolute() else root / target
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(runbook_text(), encoding="utf-8")
        print(f"wrote {target}")
        return 0
    report = run_checks(root)
    out = Path(args.out) if args.out else root / "release" / "report.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for item in report["items"]:
        if item["tier"] == "A":
            why = f": {item['problems'][0]}" + (f" (+{len(item['problems']) - 1} more)" if len(item["problems"]) > 1 else "") if item["problems"] else ""
            print(f"[{item['status']}] {item['id']} {item['title']}{why}")
    s = report["summary"]
    print(f"automated: {s['automated_pass']} pass, {s['automated_fail']} fail, {s['automated_waived']} waived by the owner; "
          f"owner items: {s['owner_required']} OWNER_REQUIRED ({s['owner_recorded']} recorded by the owner); publish: owner-only")
    print(f"report: {out}")
    return 0 if s["agent_checks_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
