// PreToolUse guard for Studio and Blender MCP tools. Read-only tools pass. Tools that create
// assets under Ethan's account or consume quota ask first. Luau that publishes, uploads or creates
// assets/places, or spends Robux directly, is denied; Luau that prompts a purchase or writes
// DataStores or MemoryStores asks. Names are matched as classes (CreateAsset*Async,
// Prompt*Purchase, ...) so new variants of an API are caught without listing each one.
import { decide, readEvent } from "./lib.mjs";

const event = readEvent();
const tool = event.tool_name || "";
const input = event.tool_input || {};
const ASK_TOOLS = /__(insert_asset|upload_image|store_image|generate_mesh|generate_material|generate_procedural_model|http_get)$/;
if (ASK_TOOLS.test(tool)) decide("ask", `${tool} creates assets, uses quota or reaches the network under Ethan's account. Confirm it targets the diagnostic place.`);

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

const code = String(input.code ?? input.luau ?? input.source ?? input.script ?? "");
if (code) {
	if (PUBLISH.test(code)) decide("deny", "Luau that publishes, uploads or creates assets/places on Roblox is blocked in SETUP_ONLY.");
	if (SPEND.test(code)) decide("deny", "Luau that completes a purchase spends Robux and is blocked in SETUP_ONLY.");
	if (PURCHASE.test(code)) decide("ask", "This Luau prompts a purchase or Robux transfer. Only allowed in a Studio test session on the diagnostic place.");
	if (DATASTORE_WRITE.test(code)) decide("ask", "This Luau writes DataStores or MemoryStores. Confirm the place is the unpublished diagnostic place, never production data.");
}
process.exit(0);
