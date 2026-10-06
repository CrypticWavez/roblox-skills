--!strict
-- @tier T1
-- InventoryGrid: a fixed-capacity grid of item slots. slots is a list (up to capacity, at most
-- 200) of { key, image?, glyph?, count?, labelKey? | label? } or false for an empty slot;
-- missing entries up to capacity are empty too. Slots are placed explicitly
-- (InventoryGrid.layout, pure) rather than by UIGridLayout, so Lune audits measure them and
-- every slot gets explicit NextSelection links (InventoryGrid.links) for gamepads. Slot size
-- is cellSize px (64 default, raised to the 44 px touch minimum on touch, convention); columns
-- is a number or a per-device table like Grid. Activation (click, tap, ui.confirm on the
-- selected slot) calls onSelect(index, key) and marks the slot selected (focus stroke plus the
-- "Selected" tag). Counts above 1 show in the corner; empty slots show nothing but stay
-- selectable (move targets). Tree:
--   InventoryGrid (ScrollingFrame) > Slot_<i> (TextButton) > Corner, Stroke, Icon (ImageLabel) |
--   Glyph (TextLabel), Count (TextLabel), Scale, FocusRing
local Build = require("../Build")
local Grid = require("./Grid")
local Style = require("../Style")

local MAX_CAPACITY = 200

-- Top-left offsets of slot index (1-based) in a grid of columns with cell size and gap.
local function layout(index: number, columns: number, cell: number, gap: number): (number, number)
	local zero = index - 1
	local column = zero % columns
	local row = zero // columns
	return column * (cell + gap), row * (cell + gap)
end

-- Neighbour indices of a slot (nil at the edges; the last row may be short).
local function links(index: number, columns: number, count: number): { [string]: number? }
	local zero = index - 1
	local column = zero % columns
	local out: { [string]: number? } = {}
	if column > 0 then
		out.left = index - 1
	end
	if column < columns - 1 and index + 1 <= count then
		out.right = index + 1
	end
	if index - columns >= 1 then
		out.up = index - columns
	end
	if index + columns <= count then
		out.down = index + columns
	elseif (count - 1) // columns > zero // columns then
		out.down = count -- the short last row: go to its last slot
	end
	return out
end

local function cellOf(props: { [string]: any }, ctx: Build.Context): number
	local cell = props.cellSize
	if ctx.class.touch then
		cell = math.max(cell, ctx.tokens.size.touchMin)
	end
	return cell
end

local function paintSlot(slot: any, item: any, selected: boolean, ctx: Build.Context)
	local empty = not item
	slot:SetAttribute("Empty", empty)
	slot:SetAttribute("ItemKey", if item then item.key else nil)
	slot.BackgroundColor3 =
		Style.color(ctx.tokens, if empty then "surfaceSunken" else "surfaceRaised", ctx.env)
	local stroke = slot:FindFirstChild("Stroke")
	stroke.Color = Style.color(ctx.tokens, if selected then "focus" else "border", ctx.env)
	stroke.Thickness = if selected then ctx.tokens.stroke.thick else ctx.tokens.stroke.hairline
	if selected then
		slot:AddTag("Selected")
	else
		slot:RemoveTag("Selected")
	end
	local icon = slot:FindFirstChild("Icon")
	icon.Image = if item and item.image then item.image else ""
	icon.Visible = item ~= false and item ~= nil and item.image ~= nil
	local glyph = slot:FindFirstChild("Glyph")
	glyph.Text = if item and item.glyph then item.glyph else ""
	glyph.Visible = item ~= false and item ~= nil and item.image == nil and item.glyph ~= nil
	local count = slot:FindFirstChild("Count")
	count.Text = if item and item.count and item.count > 1 then tostring(item.count) else ""
	local label = if item
		then (if item.labelKey then ctx.text(item.labelKey) else item.label)
		else ctx.text("uikit.inventory.empty")
	slot:SetAttribute("UIKitLabel", label)
end

local InventoryGrid = Build.component({
	name = "InventoryGrid",
	schema = Build.schema({
		slots = { kind = "list", required = true, max = MAX_CAPACITY },
		capacity = { kind = "integer", min = 1, max = MAX_CAPACITY, required = true },
		columns = { kind = "any" },
		cellSize = { kind = "number", min = 24, max = 256, default = 64 },
		gap = { kind = "number", min = 0, max = 64 },
		selected = { kind = "integer", min = 1, max = MAX_CAPACITY },
		onSelect = { kind = "function" },
	}),
	check = function(props: any): { string }
		local problems = {}
		if #props.slots > props.capacity then
			table.insert(problems, "slots holds more entries than capacity")
		end
		for index, item in props.slots do
			if item ~= false then
				if type(item) ~= "table" or type(item.key) ~= "string" or item.key == "" then
					table.insert(problems, "slots[" .. index .. "] must be false or { key, ... }")
				elseif item.image ~= nil and not string.match(tostring(item.image), "^rbx%w*://") then
					table.insert(problems, "slots[" .. index .. "].image must be a content id")
				elseif
					item.count ~= nil
					and not (type(item.count) == "number" and item.count >= 0 and item.count % 1 == 0)
				then
					table.insert(problems, "slots[" .. index .. "].count must be an integer >= 0")
				end
			end
		end
		if props.columns ~= nil then
			for _, problem in Grid.validate({ columns = props.columns }) do
				table.insert(problems, (string.gsub(problem, "^Grid: ", "")))
			end
		end
		if props.selected ~= nil and props.selected > props.capacity then
			table.insert(problems, "selected is beyond capacity")
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local columns = Grid.columnsFor(ctx.class.device, props.columns or 5)
		local cell = cellOf(props, ctx)
		local gap = props.gap or ctx.tokens.space.sm
		local rows = math.ceil(props.capacity / columns)
		local width = columns * cell + (columns - 1) * gap
		local height = rows * cell + (rows - 1) * gap
		local root = Build.make(ctx, "ScrollingFrame", {
			Name = "InventoryGrid",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = r.UDim2.new(0, width + 8, 1, 0),
			CanvasSize = r.UDim2.fromOffset(width, height),
			ScrollingDirection = r.Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			Selectable = false,
		})
		Build.tag(root, "InventoryGrid")
		local slots = {}
		for index = 1, props.capacity do
			local x, y = layout(index, columns, cell, gap)
			local slot = Build.make(ctx, "TextButton", {
				Name = "Slot_" .. index,
				Text = "",
				AutoButtonColor = false,
				BorderSizePixel = 0,
				Position = r.UDim2.fromOffset(x, y),
				Size = r.UDim2.fromOffset(cell, cell),
				LayoutOrder = index,
			}, root)
			Build.tag(slot, "InventorySlot")
			Build.corner(ctx, slot, "md")
			Build.stroke(ctx, slot, "border", "hairline")
			Build.make(ctx, "ImageLabel", {
				Name = "Icon",
				BackgroundTransparency = 1,
				AnchorPoint = r.Vector2.new(0.5, 0.5),
				Position = r.UDim2.fromScale(0.5, 0.5),
				Size = r.UDim2.fromScale(0.7, 0.7),
				ScaleType = r.Enum.ScaleType.Fit,
				Visible = false,
			}, slot)
			Build.label(ctx, "Glyph", "title", "", nil, {
				Size = r.UDim2.fromScale(1, 1),
				TextXAlignment = r.Enum.TextXAlignment.Center,
				TextWrapped = false,
				Visible = false,
			}, slot)
			Build.label(ctx, "Count", "caption", "", nil, {
				AnchorPoint = r.Vector2.new(1, 1),
				Position = r.UDim2.new(1, -4, 1, -2),
				Size = r.UDim2.new(1, -8, 0, ctx.tokens.text.caption.size),
				TextXAlignment = r.Enum.TextXAlignment.Right,
				TextWrapped = false,
				ZIndex = 2,
			}, slot)
			Build.feedback(ctx, slot, "md")
			paintSlot(slot, props.slots[index] or false, props.selected == index, ctx)
			slots[index] = slot
		end
		for index, slot in slots do
			local near = links(index, columns, props.capacity)
			if near.left then
				slot.NextSelectionLeft = slots[near.left]
			end
			if near.right then
				slot.NextSelectionRight = slots[near.right]
			end
			if near.up then
				slot.NextSelectionUp = slots[near.up]
			end
			if near.down then
				slot.NextSelectionDown = slots[near.down]
			end
		end
		root:SetAttribute("Columns", columns)
		return root, { slots = slots }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		handle.state.selected = handle.props.selected
		local function choose(index: number)
			local before = handle.state.selected
			handle.state.selected = index
			local slots = handle.parts.slots
			if before and slots[before] then
				paintSlot(slots[before], handle.props.slots[before] or false, false, ctx)
			end
			paintSlot(slots[index], handle.props.slots[index] or false, true, ctx)
		end
		handle.state.select = choose
		for index, slot in handle.parts.slots do
			Build.pressable(handle, slot, function()
				choose(index)
				local fn = handle.props.onSelect
				if fn then
					local item = handle.props.slots[index]
					fn(index, if item then item.key else nil)
				end
			end, ctx)
		end
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.capacity ~= nil or patch.columns ~= nil or patch.cellSize ~= nil or patch.gap ~= nil then
			error("InventoryGrid: capacity, columns, cellSize and gap cannot change after mount", 3)
		end
		if patch.selected ~= nil then
			handle.state.selected = patch.selected
		end
		for index, slot in handle.parts.slots do
			paintSlot(slot, handle.props.slots[index] or false, handle.state.selected == index, ctx)
		end
	end,
})

InventoryGrid.layout = layout
InventoryGrid.links = links

return InventoryGrid
