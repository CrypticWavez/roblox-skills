// PreToolUse guard for Studio and Blender MCP tools. Read-only tools pass. Tools that create
// assets under Ethan's account or consume quota ask first; Luau that publishes, uploads,
// buys or writes DataStores is denied or asked.
import { decide, readEvent } from "./lib.mjs";

const event = readEvent();
const tool = event.tool_name || "";
const input = event.tool_input || {};
const ASK_TOOLS = /__(insert_asset|upload_image|store_image|generate_mesh|generate_material|generate_procedural_model|http_get)$/;
if (ASK_TOOLS.test(tool)) decide("ask", `${tool} creates assets, uses quota or reaches the network under Ethan's account. Confirm it targets the diagnostic place.`);

const code = String(input.code ?? input.luau ?? input.source ?? input.script ?? "");
if (code) {
	if (/SavePlaceAsync|CreatePlaceAsync|PublishAsync\b|CreateAssetAsync|SaveSelectedToRoblox|PublishToRoblox/.test(code)) {
		decide("deny", "Luau that publishes or uploads is blocked in SETUP_ONLY.");
	}
	if (/PromptProductPurchase|PromptPurchase|PromptGamePassPurchase|PromptSubscriptionPurchase/.test(code)) {
		decide("ask", "This Luau prompts a purchase. Only allowed in a Studio test session on the diagnostic place.");
	}
	if (/:(SetAsync|UpdateAsync|RemoveAsync|IncrementAsync)\(/.test(code)) {
		decide("ask", "This Luau writes DataStores. Confirm the place is the unpublished diagnostic place, never production data.");
	}
}
process.exit(0);
