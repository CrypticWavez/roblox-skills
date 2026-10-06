--!strict
-- @tier T1
-- ShopCard: shows one catalog/1 product (Stage 0 GameKit/Catalog) by productKey: its name and
-- description keys, its icon (imageFor(iconKey) returns a content id, else a neutral
-- placeholder), a price line and a status. It never buys anything: there is no purchase prop
-- and no MarketplaceService call here (the spec scans this file for one); onSelect(productKey)
-- tells the game which product the player picked, and the game runs its own guarded purchase
-- flow. Prices are never written in data: the price prop is a Catalog.PriceInfo the game's
-- price provider produced at runtime (state ok with text, pending or unavailable). A product
-- that is disabled (every product in setup mode), already owned or unpriced cannot be selected.
-- In setup mode (catalog.mode == "setup", the factory and new repos) a watermark marks the card
-- as a preview. Tree:
--   ShopCard (TextButton) > Corner, Stroke, Padding, Layout, Icon (ImageLabel | Frame), Name,
--   Description?, Price, Status, Watermark?, Scale, FocusRing
local Build = require("../Build")
local Catalog = require("../../GameKit/Catalog")
local Style = require("../Style")

local ICON = 96 -- px, convention

local function productOf(props: { [string]: any }): any
	return Catalog.find(props.catalog, props.productKey)
end

-- The price line and whether the product may be selected, from catalog mode, product state,
-- ownership and price info.
local function status(props: { [string]: any }, product: any): (string, string?, boolean)
	local price = props.price
	local priceKey, priceText
	if price == nil or price.state == "pending" then
		priceKey = "uikit.price.pending"
	elseif price.state == "unavailable" then
		priceKey = "uikit.price.unavailable"
	else
		priceText = price.text
	end
	local statusKey = nil
	if props.owned then
		statusKey = "uikit.shop.owned"
	elseif not product.enabled or props.catalog.mode == "setup" then
		statusKey = "uikit.shop.unavailable"
	end
	return priceKey or "", priceText, statusKey == nil and priceText ~= nil
end

local function paint(root: any, props: { [string]: any }, ctx: Build.Context)
	local product = productOf(props)
	local priceKey, priceText, selectable = status(props, product)
	local price = root:FindFirstChild("Price")
	price.Text = priceText or ctx.text(priceKey)
	local statusLabel = root:FindFirstChild("Status")
	local statusKey = if props.owned
		then "uikit.shop.owned"
		elseif not product.enabled or props.catalog.mode == "setup" then "uikit.shop.unavailable"
		else nil
	statusLabel.Text = if statusKey then ctx.text(statusKey) else ""
	statusLabel.Visible = statusKey ~= nil
	-- Disabled cards stay selectable for gamepads (players can still read them) but do not act.
	root.Active = selectable
	root.AutoButtonColor = false
	root:SetAttribute("Selectable", selectable)
	root:SetAttribute("ProductKey", props.productKey)
	price.TextColor3 = Style.color(ctx.tokens, if selectable then "text" else "textMuted", ctx.env)
end

local ShopCard = Build.component({
	name = "ShopCard",
	schema = Build.schema({
		catalog = { kind = "table", required = true },
		productKey = { kind = "string", maxLength = 64, required = true },
		price = { kind = "table" },
		owned = { kind = "boolean", default = false },
		imageFor = { kind = "function" },
		width = { kind = "number", min = 120, max = 1024, default = 220 },
		onSelect = { kind = "function" },
	}),
	check = function(props: any): { string }
		local problems = {}
		for _, problem in Catalog.validate(props.catalog) do
			table.insert(problems, "catalog: " .. problem)
		end
		if #problems > 0 then
			return problems
		end
		if Catalog.find(props.catalog, props.productKey) == nil then
			table.insert(problems, "productKey " .. tostring(props.productKey) .. " is not in the catalog")
		end
		local price = props.price
		if price ~= nil then
			if price.state ~= "ok" and price.state ~= "pending" and price.state ~= "unavailable" then
				table.insert(problems, "price.state must be ok, pending or unavailable")
			elseif price.state == "ok" and (type(price.text) ~= "string" or price.text == "") then
				table.insert(problems, "price.text is required when price.state is ok")
			end
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local product = productOf(props)
		local display = product.display
		local root = Build.make(ctx, "TextButton", {
			Name = "ShopCard",
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			BackgroundColor3 = r.Color3.fromRGB(table.unpack(ctx.tokens.color.surfaceRaised)),
			Size = r.UDim2.fromOffset(props.width, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
		})
		Build.tag(root, "ShopCard", "UIKitSurface")
		Build.corner(ctx, root, "lg")
		Build.stroke(ctx, root, "border", "hairline")
		Build.padding(ctx, root, "md")
		Build.list(ctx, root, "Vertical", { gap = "xs", align = "Center" })
		local image = if display.iconKey and props.imageFor then props.imageFor(display.iconKey) else nil
		if type(image) == "string" and image ~= "" then
			Build.make(ctx, "ImageLabel", {
				Name = "Icon",
				Image = image,
				BackgroundTransparency = 1,
				Size = r.UDim2.fromOffset(ICON, ICON),
				ScaleType = r.Enum.ScaleType.Fit,
				LayoutOrder = 1,
			}, root)
		else
			local placeholder = Build.surface(ctx, "Icon", "surfaceSunken", {
				Size = r.UDim2.fromOffset(ICON, ICON),
				LayoutOrder = 1,
			}, root)
			Build.corner(ctx, placeholder, "md")
		end
		local wrap = {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			TextXAlignment = r.Enum.TextXAlignment.Center,
		}
		local name = Build.label(ctx, "Name", "title", ctx.text(display.nameKey), nil, wrap, root)
		name.LayoutOrder = 2
		if display.descriptionKey then
			local description = Build.label(
				ctx,
				"Description",
				"caption",
				ctx.text(display.descriptionKey),
				"textMuted",
				wrap,
				root
			)
			description.LayoutOrder = 3
		end
		local price = Build.label(ctx, "Price", "numeric", "", nil, wrap, root)
		price.LayoutOrder = 4
		local statusLabel = Build.label(ctx, "Status", "caption", "", "textMuted", wrap, root)
		statusLabel.LayoutOrder = 5
		if props.catalog.mode == "setup" then
			local mark = Build.surface(ctx, "Watermark", "warning", {
				AnchorPoint = r.Vector2.new(0.5, 0),
				Position = r.UDim2.new(0.5, 0, 0, 0),
				Size = r.UDim2.fromScale(1, 0),
				AutomaticSize = r.Enum.AutomaticSize.Y,
				LayoutOrder = 0,
			}, root)
			Build.corner(ctx, mark, "sm")
			Build.label(ctx, "Text", "caption", ctx.text("uikit.shop.setup_watermark"), "warningText", {
				Size = r.UDim2.fromScale(1, 0),
				AutomaticSize = r.Enum.AutomaticSize.Y,
				TextXAlignment = r.Enum.TextXAlignment.Center,
			}, mark)
			root:SetAttribute("SetupOnly", true)
		end
		Build.feedback(ctx, root, "lg")
		paint(root, props, ctx)
		return root, {}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		Build.pressable(handle, handle.root, function()
			local p = handle.props
			local _, _, selectable = status(p, productOf(p))
			if selectable and p.onSelect then
				p.onSelect(p.productKey)
			end
		end, ctx)
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.catalog ~= nil or patch.productKey ~= nil then
			error("ShopCard: catalog and productKey cannot change after mount (build a new card)", 3)
		end
		paint(handle.root, handle.props, ctx)
	end,
})

-- (priceKey, priceText, selectable) for props (exposed for specs and custom layouts).
function ShopCard.status(props: { [string]: any }): (string, string?, boolean)
	return status(props, productOf(props))
end

return ShopCard
