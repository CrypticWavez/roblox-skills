// PreToolUse guard for Studio and Blender MCP tools (Claude Code and Codex). Read-only tools pass.
// Tools that create assets under Ethan's account or consume quota ask first. Every string in the
// tool input of any other tool (execute_luau, multi_edit edits, unknown field names) is checked as
// code: Luau that publishes, uploads or creates assets/places, spends Robux directly, or sends an
// HttpService write to a Roblox web API is denied; Luau that prompts a purchase or writes
// DataStores or MemoryStores asks. Names are matched as classes (CreateAsset*Async,
// Prompt*Purchase, ...) so new variants of an API are caught without listing each one. Blender:
// tools that reach third-party asset libraries or paid 3D generators ask; execute_blender_code
// that starts a publishing tool or writes to a Roblox web API is denied, and Python that reaches
// the network or a shell asks. In Codex every ask is a deny (lib.mjs). Code is matched as text:
// obfuscated code can still slip past (docs/mcp.md).
import { CODE_HTTP_CLI_WRITE, CODE_PUBLISH, ROBLOX_HOST, SCRIPT_WRITE, decide, readEvent } from "./lib.mjs";

// Fail closed: a bug in this guard must block the tool call, not wave it through.
process.on("uncaughtException", (err) => decide("deny", `guard_mcp.mjs failed (${err.message}); fix the hook (node tools/hooks/selftest.mjs) before retrying.`));

const event = readEvent();
const tool = event.tool_name || "";
const input = event.tool_input || {};
const ASK_TOOLS = /__(insert_asset|upload_image|store_image|generate_mesh|generate_material|generate_procedural_model|http_get)$/;
if (ASK_TOOLS.test(tool)) decide("ask", `${tool} creates assets, uses quota or reaches the network under Ethan's account. Confirm it targets the diagnostic place.`);

// Read-only tools take paths, queries and ids, not code, so a search for "SetAsync" is not a write.
const READ_TOOLS = /__(list_roblox_studios|get_studio_state|search_game_tree|inspect_instance|script_read|script_search|script_grep|get_console_output|screen_capture|get_scene_info|look|get_addon_status|disable_telemetry|get_\w+_status|viewport_\w+|open_viewport|search_mentions)$/;
if (READ_TOOLS.test(tool)) process.exit(0);

// Every string value in the input, at any depth, whatever its field is called. The text an edit
// replaces (old_string) is not new code.
const strings = (v, key = "") => (typeof v === "string" ? (/^old_?str(ing)?$/i.test(key) ? [] : [v]) : Array.isArray(v) ? v.flatMap((x) => strings(x, key)) : v && typeof v === "object" ? Object.entries(v).flatMap(([k, x]) => strings(x, k)) : []);
const code = strings(input).join("\n");

// A write request to a Roblox web API from code: requests.post / fetch {method} / HttpService
// PostAsync / RequestAsync {Method = "POST"}, or an HTTP command-line client with a write flag.
const ROBLOX_WRITE = (text) => ROBLOX_HOST.test(text) && (SCRIPT_WRITE.test(text) || CODE_HTTP_CLI_WRITE.test(text) || /:\s*PostAsync\s*\(/.test(text));

// ---- Blender (mcp-for-blender 2.1.8 names, plus the 1.x names of the same features) ----------------
// generate_3d (Hyper3D Rodin, Hunyuan3D, Tripo: paid or quota), search_assets / import_asset
// (Poly Haven, Sketchfab, Poly Pizza downloads), record_trajectory_feedback (uploads to the vendor
// when its telemetry is on); 1.x: search_*/download_*/get_*_preview, generate_*, poll_*_job_status,
// import_generated_asset*. get_scene_info, look, get_addon_status and the *_status tools stay allowed.
const BLENDER_TOOL = /^mcp__blender\w*?__(\w+)$/;
const BLENDER_ASK_TOOLS =
	/^(generate_\w+|import_\w+|search_assets|search_\w*(polyhaven|sketchfab|polypizza)\w*|download_\w+|poll_\w+|get_(polyhaven_categories|\w*_preview)|record_trajectory_feedback)$/;
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
const blender = BLENDER_TOOL.exec(tool);
if (blender) {
	if (BLENDER_ASK_TOOLS.test(blender[1]))
		decide("ask", `${tool} reaches a third-party asset library or a paid/quota 3D generator (or the vendor's telemetry). Assets need a licence and provenance record (skill roblox-asset-intake); generation can cost money.`);
	if (CODE_PUBLISH.test(code)) decide("deny", "This Blender Python starts a Roblox publishing tool (rojo upload, mantle deploy, tarmac sync, asphalt, rbxcloud writes); SETUP_ONLY forbids publishing and uploads.");
	if (ROBLOX_WRITE(code)) decide("deny", "This Blender Python sends a write request to a Roblox web API (Open Cloud assets, places, DataStores are production data); SETUP_ONLY forbids it.");
	if (PY_NET_SHELL.test(code)) decide("ask", "This Blender Python reaches the network or a shell (or builds code dynamically). Confirm what it contacts or runs; downloads need provenance (skill roblox-asset-intake).");
	process.exit(0);
}

// Publish / upload / create on Roblox: SavePlaceAsync, CreatePlaceAsync, CreatePlaceInPlayerInventoryAsync,
// CreateAssetAsync, CreateAssetVersionAsync, PromptCreateAssetAsync, PromptCreateAvatar*Async,
// Upload*Async, MessagingService:PublishAsync, plugin SaveSelectedToRoblox / PromptSaveSelection*.
const PUBLISH = /\bSavePlace(Async)?\b|CreatePlace\w*Async|CreateAsset\w*Async|PromptCreate\w*Async|Upload\w*Async|PublishAsync\b|PublishToRoblox|PublishPackage|SaveSelectedToRoblox|PromptSaveSelection/;
// Completes a purchase without a prompt.
const SPEND = /Perform\w*Purchase/;
// Every MarketplaceService/CommerceService purchase prompt (PromptPurchase, PromptProductPurchase,
// PromptGamePassPurchase, PromptBundlePurchase, PromptPremiumPurchase, PromptSubscriptionPurchase,
// PromptRobloxSubscriptionPurchase, PromptBulkPurchase, PromptCommerceProductPurchase, ...) plus
// Robux transfers and subscription cancellation.
const PURCHASE = /Prompt\w*Purchase|PromptRobuxTransfer|PromptCancelSubscription|PromptRealWorldCommerce/;
// DataStore / OrderedDataStore writes (SetAsync, UpdateAsync, RemoveAsync, IncrementAsync,
// RemoveVersionAsync) and MemoryStore writes (sorted map / hash map Set/Update/RemoveAsync, queue
// AddAsync and RemoveAsync), with or without a space before the call.
const DATASTORE_WRITE = /\b(Set|Update|Remove|Increment|RemoveVersion|Add)Async\b/;

if (code) {
	if (PUBLISH.test(code)) decide("deny", "Luau that publishes, uploads or creates assets/places on Roblox is blocked in SETUP_ONLY.");
	if (SPEND.test(code)) decide("deny", "Luau that completes a purchase spends Robux and is blocked in SETUP_ONLY.");
	if (ROBLOX_WRITE(code)) decide("deny", "Luau that sends an HttpService write (PostAsync, RequestAsync with POST/PUT/PATCH/DELETE) to a Roblox web API reaches production data and is blocked in SETUP_ONLY.");
	if (PURCHASE.test(code)) decide("ask", "This Luau prompts a purchase or Robux transfer. Only allowed in a Studio test session on the diagnostic place.");
	if (DATASTORE_WRITE.test(code)) decide("ask", "This Luau writes DataStores or MemoryStores. Confirm the place is the unpublished diagnostic place, never production data.");
}
process.exit(0);
