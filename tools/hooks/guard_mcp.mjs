// PreToolUse guard for MCP tools (Claude Code and Codex). Every tool of the factory's two servers has
// an explicit class; a tool or server this guard does not know asks (a deny in Codex, lib.mjs).
//  - Roblox_Studio (all 26 tools of the built-in server): reads pass; tools that create assets under
//    the owner's account, consume quota, reach the network or start Studio's own agent (subagent, whose
//    tool calls no hook sees) ask; every string in the input of the code, play and input tools
//    (execute_luau, multi_edit edits, unknown field names) is checked as code. Luau that publishes,
//    uploads or creates assets/places, spends Robux directly, prompts a subscription, Robux transfer or
//    bulk purchase (not safely mocked in Studio), or sends an HttpService write to a Roblox web API is
//    denied; Luau that prompts another purchase or writes DataStores or MemoryStores asks, also when it
//    does so through a GameKit/Runtime adapter that hides the API name (CommerceRoblox.prompt,
//    LeaderboardRoblox, LiveBoardRoblox, MemoryQueueRoblox, PlayerData backends, RobloxReceiptAdapter).
//    Names are matched as classes (CreateAsset*Async, Prompt*Purchase, ...) so new variants of an API
//    are caught.
//  - blender* servers: paid 3D generation and third-party asset libraries are denied (credits; Poly
//    Haven API terms and mixed Sketchfab/Poly Pizza licences); the vendor feedback upload asks;
//    execute_blender_code that starts a publishing tool or writes to a Roblox web API is denied, and
//    Python that reaches the network or a shell asks.
//  - any other server (claude.ai connectors, Claude or Codex plugins, ChatGPT apps, user-level servers)
//    asks, except the read-only tools of a GitHub server.
// Code is matched as text: obfuscated code and adapters required under another name can still slip
// past (docs/mcp.md).
import { CODE_HTTP_CLI_WRITE, CODE_PUBLISH, ROBLOX_HOST, SCRIPT_WRITE, decide, readEvent } from "./lib.mjs";

// Fail closed: a bug in this guard must block the tool call, not wave it through.
process.on("uncaughtException", (err) => decide("deny", `guard_mcp.mjs failed (${err.message}); fix the hook (node tools/hooks/selftest.mjs) before retrying.`));

const event = readEvent();
const tool = String(event.tool_name || "");
const input = event.tool_input || {};
// mcp__<server>__<tool>; a Codex app keeps its own "__" inside the tool part (mcp__codex_apps__x__y).
const [, server = "", name = ""] = /^mcp__(.+?)__(.+)$/.exec(tool) ?? [];

// Every string value in the input, at any depth, whatever its field is called. The text an edit
// replaces (old_string) is not new code.
const strings = (v, key = "") => (typeof v === "string" ? (/^old_?str(ing)?$/i.test(key) ? [] : [v]) : Array.isArray(v) ? v.flatMap((x) => strings(x, key)) : v && typeof v === "object" ? Object.entries(v).flatMap(([k, x]) => strings(x, k)) : []);
const code = strings(input).join("\n");

// A write request to a Roblox web API from code: requests.post / fetch {method} / HttpService
// PostAsync / RequestAsync {Method = "POST"}, or an HTTP command-line client with a write flag.
const ROBLOX_WRITE = (text) => ROBLOX_HOST.test(text) && (SCRIPT_WRITE.test(text) || CODE_HTTP_CLI_WRITE.test(text) || /:\s*PostAsync\s*\(/.test(text));

// ---- Roblox Studio (built-in MCP server; 26 tools per create.roblox.com/docs/studio/mcp, 2026-10-02) ----
const STUDIO_SERVER = /^roblox_studio$/i;
// Reads: paths, queries and ids, not code, so a search for "SetAsync" is not a write. skill returns
// Roblox's built-in Assistant skills, wait_job_finished polls a job an asked generate_* started,
// search_asset searches the Creator Store (inserting is insert_asset, which asks).
const STUDIO_READ = /^(list_roblox_studios|get_studio_state|search_game_tree|inspect_instance|script_read|script_search|script_grep|get_console_output|screen_capture|skill|wait_job_finished|search_asset)$/;
// Asset creation, quota, network, and subagent: Roblox's explore/playtest agent inside Studio, whose
// own tool calls never reach these hooks (which tools it may call is not documented).
const STUDIO_ASK = /^(insert_asset|upload_image|store_image|generate_mesh|generate_material|generate_procedural_model|http_get|subagent)$/;
// Code, play and input tools: allowed unless their strings fail the code checks below.
const STUDIO_CODE = /^(execute_luau|multi_edit|start_stop_play|user_keyboard_input|user_mouse_input|character_navigation)$/;

// Publish / upload / create on Roblox: SavePlaceAsync, CreatePlaceAsync, CreatePlaceInPlayerInventoryAsync,
// CreateAssetAsync, CreateAssetVersionAsync, PromptCreateAssetAsync, PromptCreateAvatar*Async,
// Upload*Async, MessagingService:PublishAsync, plugin SaveSelectedToRoblox / PromptSaveSelection*.
const PUBLISH = /\bSavePlace(Async)?\b|CreatePlace\w*Async|CreateAsset\w*Async|PromptCreate\w*Async|Upload\w*Async|PublishAsync\b|PublishToRoblox|PublishPackage|SaveSelectedToRoblox|PromptSaveSelection/;
// Completes a purchase without a prompt.
const SPEND = /Perform\w*Purchase/;
// Prompts with no safe Studio mock: subscriptions (a Studio play-mode subscription prompt reportedly
// takes the real payment path, DevForum 4676620), Robux transfers (not mocked in team tests, DevForum
// 4625943), Premium (the deprecated predecessor of PromptRobloxSubscriptionPurchase) and bulk avatar
// purchases (no documented mock). docs/research/release-monetization-analytics-2026-10.md section 9.
const UNMOCKED_PURCHASE = /Prompt(Roblox)?SubscriptionPurchase|PromptPremiumPurchase|PromptRobuxTransfer\w*|PromptBulkPurchase/;
// Every other MarketplaceService/CommerceService purchase prompt (PromptPurchase, PromptProductPurchase,
// PromptGamePassPurchase, PromptBundlePurchase, PromptCommerceProductPurchase, ...), subscription
// cancellation and real-world commerce. Studio simulates product and pass purchases.
const PURCHASE = /Prompt\w*Purchase|PromptCancelSubscription|PromptRealWorldCommerce/;
// DataStore / OrderedDataStore writes (SetAsync, UpdateAsync, RemoveAsync, IncrementAsync,
// RemoveVersionAsync) and MemoryStore writes (sorted map / hash map Set/Update/RemoveAsync, queue
// AddAsync and RemoveAsync), with or without a space before the call.
const DATASTORE_WRITE = /\b(Set|Update|Remove|Increment|RemoveVersion|Add)Async\b/;
// The kits' own adapters make those calls inside the place, so the API name never shows in the code
// sent here. Code that names an adapter and uses one of its purchase or write entry points is
// classified like the call it wraps. Matched by name: an adapter required under another name, or a
// module already in the place that calls one, is a residual (docs/mcp.md).
// An entry point read or called as .name, :name or ["name"] (table.remove is not one).
const ENTRY = (names) => String.raw`(?<!\btable)[.:]\s*(?:${names})\b|\[\s*["'](?:${names})["']\s*\]`;
// An adapter option set to anything but a literal false or nil.
const ON = (names) => String.raw`\b(?:${names})\s*=(?!=|\s*(?:false|nil)\b)`;
const kits = (pairs) => pairs.map(([kit, use]) => [new RegExp(String.raw`\b${kit}\b`), new RegExp(use)]);
// GameKit/CommerceRoblox.prompt opens PromptProductPurchase, PromptGamePassPurchase or
// PromptSubscriptionPurchase. Which one is catalog data the guard cannot see, so it asks (and
// Commerce.canPrompt refuses a subscription unless the caller says the place is live).
const KIT_PURCHASE = kits([["CommerceRoblox", ENTRY("prompt")]]);
// LeaderboardRoblox submit/remove (OrderedDataStore; writes = true turns them on), LiveBoardRoblox
// maps written by LiveBoard submit/remove (MemoryStore sorted map), MemoryQueueRoblox push/ack/cycle
// (MemoryStore queue AddAsync/RemoveAsync), the PlayerData DataStore and ProfileStore backends
// (PlayerDataRoblox.chooseBackend picks one in Studio with allowStudioDataStores), and the Runtime
// receipt ledger's DataStore seam RobloxReceiptAdapter.store.
const KIT_STORE_WRITE = kits([
	["LeaderboardRoblox", `${ENTRY("submit|remove")}|${ON("writes")}`],
	["LiveBoardRoblox", ENTRY("submit|remove")],
	["MemoryQueueRoblox", ENTRY("push|ack|cycle")],
	["PlayerData(?:Roblox)?", `${ENTRY("dataStoreBackend|profileStoreBackend")}|${ON("allowStudioDataStores")}`],
	["RobloxReceiptAdapter", ENTRY("store")],
]);
const usesKit = (pairs, text) => pairs.some(([kit, use]) => kit.test(text) && use.test(text));

function checkLuau() {
	if (!code) return;
	if (PUBLISH.test(code)) decide("deny", "Luau that publishes, uploads or creates assets/places on Roblox is blocked in SETUP_ONLY.");
	if (SPEND.test(code)) decide("deny", "Luau that completes a purchase spends Robux and is blocked in SETUP_ONLY.");
	if (UNMOCKED_PURCHASE.test(code)) decide("deny", "Luau that prompts a subscription, Premium, Robux transfer or bulk purchase is blocked: Studio does not reliably mock these, so a test can charge a real account. Test product and pass prompts instead; the rest is an owner check in a published place.");
	if (ROBLOX_WRITE(code)) decide("deny", "Luau that sends an HttpService write (PostAsync, RequestAsync with POST/PUT/PATCH/DELETE) to a Roblox web API reaches production data and is blocked in SETUP_ONLY.");
	if (PURCHASE.test(code)) decide("ask", "This Luau prompts a purchase. Only allowed in a Studio test session on the diagnostic place, where product and pass purchases are simulated.");
	if (usesKit(KIT_PURCHASE, code)) decide("ask", "This Luau opens a purchase prompt through GameKit/CommerceRoblox.prompt. The guard cannot see the product kind, and a subscription prompt is not safely mocked in Studio. Only allowed in a Studio test session on the diagnostic place, for a product or pass.");
	if (DATASTORE_WRITE.test(code)) decide("ask", "This Luau writes DataStores or MemoryStores. Confirm the place is the unpublished diagnostic place, never production data.");
	if (usesKit(KIT_STORE_WRITE, code)) decide("ask", "This Luau writes DataStores or MemoryStores through a kit adapter (LeaderboardRoblox submit/remove or writes = true, LiveBoardRoblox, MemoryQueueRoblox push/ack/cycle, a PlayerData DataStore/ProfileStore backend or allowStudioDataStores, RobloxReceiptAdapter.store). Confirm the place is the unpublished diagnostic place, never production data.");
}

if (STUDIO_SERVER.test(server)) {
	if (STUDIO_READ.test(name)) process.exit(0);
	if (name === "subagent") decide("ask", `${tool} starts Roblox's own explore/playtest agent inside Studio. The factory hooks never see the tools that agent calls (it may insert assets or use generation quota). Confirm the prompt, and that the diagnostic place is the selected Studio.`);
	if (STUDIO_ASK.test(name)) decide("ask", `${tool} creates assets, uses quota or reaches the network under the owner's account. Confirm it targets the diagnostic place.`);
	checkLuau();
	if (!STUDIO_CODE.test(name)) decide("ask", `${tool} is a Studio MCP tool this guard does not classify yet (Roblox adds tools to the built-in server without notice). Confirm what it does, then classify it in tools/hooks/guard_mcp.mjs and docs/mcp.md.`);
	process.exit(0);
}

// ---- Blender (mcp-for-blender 2.1.8 names, plus the 1.x names of the same features) ----------------
const BLENDER_SERVER = /^blender[\w-]*$/i;
// generate_3d (Hyper3D Rodin, Hunyuan3D, Tripo: paid credits or quota), search_assets / import_asset
// (Poly Haven through its API, whose terms forbid commercial use; Sketchfab and Poly Pizza models with
// per-model licences); 1.x: search_*/download_*/get_*_preview, generate_*, poll_*_job_status,
// import_generated_asset*. Assets come in through tools/fetch_assets.py and skill roblox-asset-intake.
const BLENDER_DENY = /^(generate_\w+|import_\w+|search_assets|search_\w*(polyhaven|sketchfab|polypizza|hyper3d|hunyuan|rodin|tripo)\w*|download_\w+|poll_\w+|get_(polyhaven_categories|\w*_preview))$/;
// Uploads the session trajectory to the vendor when its telemetry is on.
const BLENDER_ASK = /^record_trajectory_feedback$/;
const BLENDER_READ = /^(get_scene_info|look|get_addon_status|disable_telemetry|get_\w+_status|viewport_\w+|open_viewport|search_mentions)$/;
const BLENDER_CODE = /^execute_blender_code\w*$/;
// Python sent to execute_blender_code that reaches the network or a shell, or hides what it runs.
const PY_NET_SHELL = new RegExp(
	[
		String.raw`^[ \t]*(?:import|from)[ \t]+[^\n#]*\b(?:urllib\d?|urllib3|requests|httpx|aiohttp|http|socket|socketserver|ssl|ftplib|smtplib|poplib|imaplib|telnetlib|xmlrpc|websockets?|paramiko|pycurl|subprocess|pty|multiprocessing|ctypes|webbrowser|asyncio)\b`,
		String.raw`\b(?:os|posix|nt)\s*\.\s*(?:system|popen|exec\w*|spawn\w*|posix_spawn\w*|startfile|fork\w*)\b`, // os.system(...)
		String.raw`\bfrom[ \t]+(?:os|posix|nt)[ \t]+import\b[^\n]*\b(?:system|popen|exec\w*|spawn\w*|posix_spawn\w*|startfile|fork\w*)\b`,
		String.raw`(?<![.\w])(?:__import__|exec|eval|compile)\s*\(|\bimportlib\b`, // dynamic code can hide any of the above
		String.raw`\bbpy\s*\.\s*ops\s*\.\s*(?:wm\s*\.\s*(?:url_open\w*|path_open)|extensions\s*\.|preferences\s*\.\s*(?:addon_install|extension_\w+)|script\s*\.)`,
		String.raw`\bbpy\s*\.\s*utils\s*\.\s*execfile\b`,
	].join("|"),
	"m",
);

if (BLENDER_SERVER.test(server)) {
	if (BLENDER_DENY.test(name))
		decide("deny", `${tool} reaches a paid 3D generator or a third-party asset library (Poly Haven API terms forbid commercial use; Sketchfab and Poly Pizza licences vary per model). The factory never uses them: fetch CC0 files with tools/fetch_assets.py and register them through skill roblox-asset-intake.`);
	if (BLENDER_ASK.test(name)) decide("ask", `${tool} uploads the session to the add-on vendor when its telemetry is on. Confirm telemetry is off and why the feedback is needed.`);
	if (BLENDER_READ.test(name)) process.exit(0);
	if (!BLENDER_CODE.test(name)) decide("ask", `${tool} is a Blender MCP tool this guard does not classify. Confirm what it does, then classify it in tools/hooks/guard_mcp.mjs and docs/mcp.md.`);
	if (CODE_PUBLISH.test(code)) decide("deny", "This Blender Python starts a publishing tool (rojo upload, mantle deploy, tarmac sync, asphalt, rbxcloud writes, wally/pesde publish or login); SETUP_ONLY forbids publishing and uploads.");
	if (ROBLOX_WRITE(code)) decide("deny", "This Blender Python sends a write request to a Roblox web API (Open Cloud assets, places, DataStores are production data); SETUP_ONLY forbids it.");
	if (PY_NET_SHELL.test(code)) decide("ask", "This Blender Python reaches the network or a shell (or builds code dynamically). Confirm what it contacts or runs; downloads need provenance (skill roblox-asset-intake).");
	process.exit(0);
}

// ---- every other MCP server -------------------------------------------------------------------------
// Read-only tools of a GitHub server (the official GitHub MCP server, a Claude plugin or connector
// wrapping it): get_*, list_*, search_*, *_read, actions_get/actions_list.
const GITHUB_SERVER = /github/i;
const GITHUB_READ = /^(get_\w+|list_\w+|search_\w+|\w+_read|actions_(get|list))$/;
if (GITHUB_SERVER.test(server) && GITHUB_READ.test(name)) process.exit(0);
decide(
	"ask",
	`${tool || "This tool"} belongs to an MCP server the factory does not configure (a claude.ai connector, a Claude or Codex plugin, a ChatGPT app or a user-level server), so this guard cannot tell what it reads, writes or sends. Confirm it; the factory itself needs only Roblox_Studio, blender and read-only GitHub tools (docs/mcp.md).`,
);
