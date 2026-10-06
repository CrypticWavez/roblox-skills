--!strict
-- Server-only atomic account/receipt core. No services or side effects inside transforms.
-- Retention: each receipt records when it was granted (`at`, unix seconds from options.now,
-- default os.time). Receipts older than minRetentionDays (default 30, a convention: Roblox
-- re-delivers an unacknowledged receipt for a limited time, UNVERIFIED how long) are pruned on
-- the next grant, and "receipt_capacity_requires_migration" is returned only when the receipts
-- still inside the window fill maxReceipts. Receipts stored without `at` (v1 data, or v2 data
-- written before retention) are stamped with the current time on first touch, so they are kept
-- for a full window. Dedupe inside the window is never given up to admit a new receipt.
local ReceiptLedger = {}
export type Product = {
	universeId: number,
	revision: string,
	balances: { [string]: number },
	entitlements: { [string]: boolean },
}
export type Account = {
	version: number,
	balances: { [string]: number },
	entitlements: { [string]: boolean },
	receipts: { [string]: { productId: number, revision: string, at: number } },
}
export type Result = {
	decision: string,
	reason: string,
	attempts: number,
	account: Account?,
	pruned: number?,
}
export type Options = {
	store: any,
	namespace: string,
	universeId: number,
	products: { [number]: Product },
	maxReceipts: number?,
	minRetentionDays: number?,
	now: (() -> number)?,
	maxBalances: number?,
	maxEntitlements: number?,
	maxBalance: number?,
	attempts: number?,
	wait: ((number) -> ())?,
}
local MAX_INTEGER = 9007199254740991
local DAY = 86400
ReceiptLedger.DEFAULT_RETENTION_DAYS = 30 -- convention, not a Roblox number

local function integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function identifier(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and value:match("^[%w_%-]+$") ~= nil
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function mapCount(value: any): number
	local count = 0
	for _ in value do
		count += 1
	end
	return count
end

function ReceiptLedger.new(options: Options)
	assert(type(options) == "table" and options.store, "store required")
	assert(identifier(options.namespace, 24), "isolated namespace required (max 24 characters)")
	assert(integer(options.universeId, 1, MAX_INTEGER), "explicit universeId required")
	local namespace, storage = options.namespace, options.store
	local limits = {
		receipts = options.maxReceipts or 2048,
		balances = options.maxBalances or 32,
		entitlements = options.maxEntitlements or 256,
		balance = options.maxBalance or 1000000000000,
	}
	assert(integer(limits.receipts, 1, 10000) and integer(limits.balances, 1, 128), "invalid limits")
	assert(
		integer(limits.entitlements, 1, 1024) and integer(limits.balance, 1, MAX_INTEGER),
		"invalid limits"
	)
	local attempts = options.attempts or 3
	assert(integer(attempts, 1, 5), "attempts must be 1..5")
	local retentionDays = options.minRetentionDays or ReceiptLedger.DEFAULT_RETENTION_DAYS
	assert(
		type(retentionDays) == "number" and retentionDays >= 1 and retentionDays <= 3650,
		"minRetentionDays must be 1..3650"
	)
	local window = retentionDays * DAY
	local now = options.now or os.time
	assert(type(now) == "function", "now must be a function returning unix seconds")
	local waitFor = options.wait or function(_seconds: number) end
	local products: { [number]: Product } = {}
	for productId, product in options.products do
		assert(integer(productId, 1, MAX_INTEGER), "invalid productId")
		assert(product.universeId == options.universeId, "cross-universe product")
		assert(identifier(product.revision, 32), "grant revision required")
		assert(
			type(product.balances) == "table" and type(product.entitlements) == "table",
			"grant maps required"
		)
		assert(
			mapCount(product.balances) <= limits.balances
				and mapCount(product.entitlements) <= limits.entitlements,
			"grant too large"
		)
		for name, amount in product.balances do
			assert(identifier(name, 48) and integer(amount, 1, limits.balance), "invalid balance grant")
		end
		for name, value in product.entitlements do
			assert(identifier(name, 48) and value == true, "invalid entitlement grant")
		end
		assert(next(product.balances) ~= nil or next(product.entitlements) ~= nil, "empty grant")
		products[productId] = copy(product)
	end

	-- stamp: the time given to receipts stored without one.
	local function normalize(stored: any, stamp: number): (Account?, string?)
		if stored == nil then
			return { version = 2, balances = {}, entitlements = {}, receipts = {} }, nil
		end
		if type(stored) ~= "table" or (stored.version ~= 1 and stored.version ~= 2) then
			return nil, "unsupported_or_corrupt_schema"
		end
		for key in stored do
			if key ~= "version" and key ~= "balances" and key ~= "entitlements" and key ~= "receipts" then
				return nil, "unrecognized_account_field"
			end
		end
		if
			type(stored.balances) ~= "table"
			or type(stored.entitlements) ~= "table"
			or type(stored.receipts) ~= "table"
		then
			return nil, "corrupt_maps"
		end
		if
			mapCount(stored.balances) > limits.balances
			or mapCount(stored.entitlements) > limits.entitlements
			or mapCount(stored.receipts) > limits.receipts
		then
			return nil, "stored_capacity_exceeded"
		end
		local account: Account = { version = 2, balances = {}, entitlements = {}, receipts = {} }
		for name, amount in stored.balances do
			if not identifier(name, 48) or not integer(amount, 0, limits.balance) then
				return nil, "corrupt_balance"
			end
			account.balances[name] = amount
		end
		for name, value in stored.entitlements do
			if not identifier(name, 48) or value ~= true then
				return nil, "corrupt_entitlement"
			end
			account.entitlements[name] = true
		end
		for purchaseId, receipt in stored.receipts do
			if not identifier(purchaseId, 128) then
				return nil, "corrupt_receipt_id"
			end
			if stored.version == 1 then
				if not integer(receipt, 1, MAX_INTEGER) then
					return nil, "corrupt_v1_receipt"
				end
				account.receipts[purchaseId] = { productId = receipt, revision = "migrated_v1", at = stamp }
			elseif
				type(receipt) ~= "table"
				or not integer(receipt.productId, 1, MAX_INTEGER)
				or not identifier(receipt.revision, 32)
				or (receipt.at ~= nil and not integer(receipt.at, 0, MAX_INTEGER))
			then
				return nil, "corrupt_receipt"
			else
				account.receipts[purchaseId] =
					{ productId = receipt.productId, revision = receipt.revision, at = receipt.at or stamp }
			end
		end
		return account, nil
	end

	local api = {}
	function api:key(userId: number): string
		assert(integer(userId, 1, MAX_INTEGER), "invalid userId")
		return namespace .. ":" .. tostring(userId)
	end

	function api:process(receipt: any): Result
		if
			type(receipt) ~= "table"
			or not integer(receipt.PlayerId, 1, MAX_INTEGER)
			or not integer(receipt.ProductId, 1, MAX_INTEGER)
			or not identifier(receipt.PurchaseId, 128)
		then
			return { decision = "NotProcessedYet", reason = "invalid_receipt", attempts = 0 }
		end
		local product = products[receipt.ProductId]
		if product == nil then
			return { decision = "NotProcessedYet", reason = "unknown_product", attempts = 0 }
		end
		local stamp = now()
		if not integer(stamp, 0, MAX_INTEGER) then
			return { decision = "NotProcessedYet", reason = "invalid_clock", attempts = 0 }
		end
		local rejection: string? = nil
		local pruned = 0
		for attempt = 1, attempts do
			rejection = nil
			local ok, committed = pcall(function()
				return storage:UpdateAsync(api:key(receipt.PlayerId), function(stored: any): Account?
					-- May run repeatedly. Recreate candidate each time; do not grant Instances,
					-- emit events, yield, or perform additional datastore writes here.
					pruned = 0
					local account, failure = normalize(stored, stamp)
					if account == nil then
						rejection = failure
						return nil
					end
					local existing = account.receipts[receipt.PurchaseId]
					if existing then
						if existing.productId ~= receipt.ProductId then
							rejection = "receipt_product_mismatch"
							return nil
						end
						return account
					end
					-- Retention: drop receipts older than the window, then count what is left.
					for purchaseId, kept in account.receipts do
						if kept.at < stamp - window then
							account.receipts[purchaseId] = nil
							pruned += 1
						end
					end
					if mapCount(account.receipts) >= limits.receipts then
						rejection = "receipt_capacity_requires_migration"
						return nil -- Never evict in-window dedupe facts to admit a new receipt.
					end
					for name, amount in product.balances do
						local total = (account.balances[name] or 0) + amount
						if total > limits.balance then
							rejection = "balance_capacity"
							return nil
						end
						account.balances[name] = total
					end
					for name in product.entitlements do
						account.entitlements[name] = true
					end
					if
						mapCount(account.balances) > limits.balances
						or mapCount(account.entitlements) > limits.entitlements
					then
						rejection = "grant_capacity"
						return nil
					end
					account.receipts[receipt.PurchaseId] =
						{ productId = receipt.ProductId, revision = product.revision, at = stamp }
					return account
				end)
			end)
			if ok then
				local account = normalize(committed, stamp)
				local proof = account and account.receipts[receipt.PurchaseId]
				if proof and proof.productId == receipt.ProductId then
					return {
						decision = "PurchaseGranted",
						reason = "durable_record_confirmed",
						attempts = attempt,
						account = account,
						pruned = pruned,
					}
				end
				return {
					decision = "NotProcessedYet",
					reason = rejection or "commit_not_confirmed",
					attempts = attempt,
				}
			end
			if rejection then
				return { decision = "NotProcessedYet", reason = rejection, attempts = attempt }
			end
			if attempt < attempts then
				-- Caller supplies scheduler; errors never include raw platform error text.
				local waitOk = pcall(waitFor, math.min(0.25 * 2 ^ (attempt - 1), 2))
				if not waitOk then
					return { decision = "NotProcessedYet", reason = "retry_interrupted", attempts = attempt }
				end
			end
		end
		return { decision = "NotProcessedYet", reason = "store_unavailable", attempts = attempts }
	end

	return api
end

return ReceiptLedger
