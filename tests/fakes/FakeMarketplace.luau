--!strict
-- FakeMarketplace: a MarketplaceService double for Lune specs of GameKit/Commerce,
-- GameKit/CommerceRoblox and Runtime/RobloxReceiptAdapter. It models the calls those modules make:
--   GetProductInfoAsync(id, infoType)        developer products (InfoType.Product) and passes
--                                            (InfoType.GamePass): { Name, PriceInRobux, IsForSale }
--   GetSubscriptionProductInfoAsync(id)      { Name, DisplayPrice, IsForSale }
--   UserOwnsGamePassAsync(userId, passId)    boolean
--   GetUserSubscriptionStatusAsync(player, id)  { IsSubscribed, IsRenewing }
--   GetUsersPriceLevelsAsync(userIds)        a list of { UserId, PriceLevel } (shape UNVERIFIED)
--   Prompt{Product,GamePass,Subscription}Purchase(player, id)  recorded in fake.prompts, nothing else
--   BindReceiptHandler(receiptType, handler) one handler per receipt type; returns a connection
--   ProcessReceipt                           the legacy callback field (fallback for deliver)
-- Test controls: fail(method, n, message) makes the next n calls raise; deliver(receipt) hands a
-- receipt to the bound DeveloperProduct handler (or ProcessReceipt) and returns the decision name;
-- calls[method] counts calls. With env and latency, the Async reads wait env.wait(latency).
-- No real product, purchase or Robux is involved: every id is a test fixture.
local FakeMarketplace = {}

export type Options = {
	products: { [number]: { [string]: any } }?,
	passes: { [number]: { [string]: any } }?,
	subscriptions: { [string]: { [string]: any } }?,
	owned: { [number]: { [number]: boolean } }?,
	subscribed: { [number]: { [string]: boolean } }?,
	priceLevels: { [number]: number }?,
	env: any?,
	latency: number?,
}

local function enumName(value: any): string
	if typeof(value) == "EnumItem" then
		return value.Name
	end
	return tostring(value)
end

function FakeMarketplace.new(options: Options?): any
	local opts: Options = options or {}
	local fake = {
		products = opts.products or {},
		passes = opts.passes or {},
		subscriptions = opts.subscriptions or {},
		owned = opts.owned or {},
		subscribed = opts.subscribed or {},
		priceLevels = opts.priceLevels or {},
		prompts = {} :: { { method: string, userId: number?, id: any } },
		handlers = {} :: { [string]: any },
		calls = {} :: { [string]: number },
		failures = {} :: { [string]: { n: number, message: string } },
		ProcessReceipt = nil :: any,
	}

	local function enter(method: string)
		fake.calls[method] = (fake.calls[method] or 0) + 1
		if opts.env ~= nil and opts.latency ~= nil then
			opts.env.wait(opts.latency)
		end
		local failure = fake.failures[method]
		if failure ~= nil and failure.n > 0 then
			failure.n -= 1
			error(failure.message, 0)
		end
	end

	function fake.fail(_self: any, method: string, n: number?, message: string?)
		fake.failures[method] = { n = n or 1, message = message or "HTTP 500 (Internal Server Error)" }
	end

	function fake.GetProductInfoAsync(_self: any, id: number, infoType: any): { [string]: any }
		enter("GetProductInfoAsync")
		local kind = enumName(infoType)
		local source = if kind == "GamePass"
			then fake.passes
			elseif kind == "Product" then fake.products
			else nil
		if source == nil then
			error("FakeMarketplace: unsupported InfoType " .. kind, 0)
		end
		local info = source[id]
		if info == nil then
			error("FakeMarketplace: no " .. kind .. " " .. tostring(id), 0)
		end
		return table.clone(info)
	end

	function fake.GetSubscriptionProductInfoAsync(_self: any, id: string): { [string]: any }
		enter("GetSubscriptionProductInfoAsync")
		local info = fake.subscriptions[id]
		if info == nil then
			error("FakeMarketplace: no subscription " .. tostring(id), 0)
		end
		return table.clone(info)
	end

	function fake.UserOwnsGamePassAsync(_self: any, userId: number, passId: number): boolean
		enter("UserOwnsGamePassAsync")
		local owned = fake.owned[userId]
		return owned ~= nil and owned[passId] == true
	end

	function fake.GetUserSubscriptionStatusAsync(_self: any, player: any, id: string): { [string]: any }
		enter("GetUserSubscriptionStatusAsync")
		local subscribed = fake.subscribed[player.UserId]
		local active = subscribed ~= nil and subscribed[id] == true
		return { IsSubscribed = active, IsRenewing = active }
	end

	function fake.GetUsersPriceLevelsAsync(_self: any, userIds: { number }): { { [string]: any } }
		enter("GetUsersPriceLevelsAsync")
		local out = {}
		for _, userId in userIds do
			table.insert(out, { UserId = userId, PriceLevel = fake.priceLevels[userId] or 0 })
		end
		return out
	end

	local function prompt(method: string)
		return function(_self: any, player: any, id: any)
			enter(method)
			table.insert(fake.prompts, { method = method, userId = player and player.UserId, id = id })
		end
	end
	fake.PromptProductPurchase = prompt("PromptProductPurchase")
	fake.PromptGamePassPurchase = prompt("PromptGamePassPurchase")
	fake.PromptSubscriptionPurchase = prompt("PromptSubscriptionPurchase")

	function fake.BindReceiptHandler(_self: any, receiptType: any, handler: any): any
		enter("BindReceiptHandler")
		assert(type(handler) == "function", "BindReceiptHandler: handler must be a function")
		local name = enumName(receiptType)
		fake.handlers[name] = handler
		local connection = { Connected = true }
		function connection.Disconnect(self: any)
			if fake.handlers[name] == handler then
				fake.handlers[name] = nil
			end
			self.Connected = false
		end
		return connection
	end

	-- Delivers a developer-product receipt the way Roblox does: the bound handler first, else the
	-- legacy ProcessReceipt callback. Returns the decision's name, or "Unhandled" with neither.
	function fake.deliver(_self: any, receipt: { [string]: any }): string
		local handler = fake.handlers.DeveloperProduct
		if handler ~= nil then
			return enumName(handler(table.clone(receipt)))
		end
		if fake.ProcessReceipt ~= nil then
			return enumName(fake.ProcessReceipt(table.clone(receipt)))
		end
		return "Unhandled"
	end

	return fake
end

return FakeMarketplace
