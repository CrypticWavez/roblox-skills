-- Opt-in server adapter; loading this module does not bind anything or open storage.
-- Tier T4 for real receipts: only a real purchase (an owner-only action) exercises the engine
-- path. The decision mapping, binding and duplicate handling are Lune-tested against
-- tests/fakes/FakeMarketplace (tests/gamekit_platform_commerce.spec.luau).
--   store(dataStore)                         the UpdateAsync seam ReceiptLedger.new({ store }) takes
--   handler(ledger, onResult?, enums?)       a BindReceiptHandler callback -> Enum.ReceiptDecision
--   bind(marketplace, ledger, onResult?, enums?)
--                                            MarketplaceService:BindReceiptHandler(
--                                            Enum.ReceiptType.DeveloperProduct, handler); returns
--                                            the connection. Bind once per server.
--   callback(ledger, onResult?, enums?)      the legacy ProcessReceipt callback ->
--                                            Enum.ProductPurchaseDecision. Bound handlers take
--                                            precedence; ProcessReceipt still receives receipts no
--                                            handler claims (the ad-reward docs still name
--                                            ProcessReceipt: keep it until that path is verified)
-- enums defaults to the Roblox Enum global; Lune specs pass require("@lune/roblox").Enum.
-- onResult receives { decision, reason, attempts, pruned?, purchaseId?, productId?, playerId? }
-- after each receipt (errors in it are ignored); use it for telemetry after the durable commit.
local Adapter = {}

function Adapter.store(dataStore)
	return {
		UpdateAsync = function(_, key, transform)
			return dataStore:UpdateAsync(key, function(value, info)
				local nextValue = transform(value)
				if nextValue == nil then
					return nil
				end
				-- Preserve existing user metadata when replacing the value.
				return nextValue,
					if info then info:GetUserIds() else nil,
					if info then info:GetMetadata() else nil
			end)
		end,
	}
end

local function enumsOf(enums)
	local found = enums or Enum
	assert(found ~= nil, "RobloxReceiptAdapter: Enum unavailable (pass enums outside Roblox)")
	return found
end

-- Runs the ledger and reports; true only when the grant is durably recorded.
local function process(ledger, receipt, onResult)
	local ok, result = pcall(function()
		return ledger:process(receipt)
	end)
	local fields = if type(receipt) == "table" then receipt else {}
	if not ok then
		-- Raw platform error text is never forwarded.
		result = { decision = "NotProcessedYet", reason = "ledger_error", attempts = 0 }
	end
	if onResult then
		pcall(onResult, {
			decision = result.decision,
			reason = result.reason,
			attempts = result.attempts,
			pruned = result.pruned,
			purchaseId = fields.PurchaseId,
			productId = fields.ProductId,
			playerId = fields.PlayerId,
		})
	end
	return result.decision == "PurchaseGranted"
end

function Adapter.callback(ledger, onResult, enums)
	return function(receipt)
		local decisions = enumsOf(enums).ProductPurchaseDecision
		return if process(ledger, receipt, onResult)
			then decisions.PurchaseGranted
			else decisions.NotProcessedYet
	end
end

function Adapter.handler(ledger, onResult, enums)
	return function(receipt)
		local decisions = enumsOf(enums).ReceiptDecision
		return if process(ledger, receipt, onResult) then decisions.Processed else decisions.NotProcessedYet
	end
end

function Adapter.bind(marketplace, ledger, onResult, enums)
	local found = enumsOf(enums)
	assert(
		marketplace ~= nil and marketplace.BindReceiptHandler ~= nil,
		"MarketplaceService with BindReceiptHandler required"
	)
	assert(ledger ~= nil and ledger.process ~= nil, "ReceiptLedger required")
	return marketplace:BindReceiptHandler(
		found.ReceiptType.DeveloperProduct,
		Adapter.handler(ledger, onResult, found)
	)
end

return Adapter
