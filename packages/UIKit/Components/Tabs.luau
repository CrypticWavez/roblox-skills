--!strict
-- @tier T1
-- Tabs: a segmented row of equal-width tabs with a sliding indicator. items is a list of
-- { id, textKey | text } (2-8 entries, ids lower_snake); selected names the current id and
-- onSelected(id) fires when the user picks another. Activation, or handle.state.step(1 / -1)
-- (bind it to the ui.tab_next / ui.tab_prev IAS actions), changes the selection; the indicator
-- slides on a snappy spring (reduced motion jumps). The selected tab has the "Selected" tag, the
-- Selected attribute and the accent text slot (plus the indicator, so selection is not colour
-- alone). Tabs are positioned explicitly (no layout object), so audits measure them in Lune, and
-- NextSelectionLeft/Right chain them for gamepads. Tree:
--   Tabs (Frame) > Corner, Bar (Frame) > Tab_<id> (TextButton) > Label, Scale, FocusRing;
--   Indicator (Frame) > Corner
local Build = require("../Build")
local Check = require("../../GameKit/Check")
local Style = require("../Style")
local Transitions = require("../Transitions")

local INDICATOR_H, INSET = 3, 8 -- px, convention

local function indexOf(items: { any }, id: string): number?
	for index, item in items do
		if item.id == id then
			return index
		end
	end
	return nil
end

local function indicatorPosition(index: number, count: number): { number }
	return { (index - 1) / count, INSET, 1, -INDICATOR_H }
end

local function tabHeight(ctx: Build.Context): number
	local h = ctx.tokens.size.control
	if ctx.class.touch then
		h = math.max(h, ctx.tokens.size.touchMin)
	end
	return h
end

local function paint(handleRoot: any, items: { any }, selected: string, ctx: Build.Context)
	local bar = handleRoot:FindFirstChild("Bar")
	for _, item in items do
		local tab = bar:FindFirstChild("Tab_" .. item.id)
		local on = item.id == selected
		tab:SetAttribute("Selected", on)
		if on then
			tab:AddTag("Selected")
		else
			tab:RemoveTag("Selected")
		end
		tab:FindFirstChild("Label").TextColor3 =
			Style.color(ctx.tokens, if on then "text" else "textMuted", ctx.env)
	end
	handleRoot:SetAttribute("Selected", selected)
end

local Tabs = Build.component({
	name = "Tabs",
	schema = Build.schema({
		items = { kind = "list", required = true, max = 8 },
		selected = { kind = "label" },
		onSelected = { kind = "function" },
		width = { kind = "number", min = 0, max = 4096 },
	}),
	check = function(props: any): { string }
		local problems = {}
		local items = props.items
		if #items < 2 then
			table.insert(problems, "items needs 2-8 entries")
		end
		local seen = {}
		for index, item in items do
			if type(item) ~= "table" or not Check.label(item.id) then
				table.insert(problems, "items[" .. index .. "].id must be a lower_snake label")
				continue
			end
			if seen[item.id] then
				table.insert(problems, "items[" .. index .. "].id " .. item.id .. " is repeated")
			end
			seen[item.id] = true
			if item.textKey == nil and item.text == nil then
				table.insert(problems, "items[" .. index .. "] needs textKey or text")
			end
		end
		if props.selected ~= nil and not seen[props.selected] then
			table.insert(problems, "selected names no item")
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local items = props.items
		local count = #items
		local selected = props.selected or items[1].id
		local h = tabHeight(ctx)
		local root = Build.surface(ctx, "Tabs", "surfaceSunken", {
			Size = if props.width then r.UDim2.fromOffset(props.width, h) else r.UDim2.new(1, 0, 0, h),
		})
		Build.corner(ctx, root, "md")
		local bar = Build.frame(ctx, "Bar", { Size = r.UDim2.fromScale(1, 1) }, root)
		local tabs = {}
		for index, item in items do
			local tab = Build.make(ctx, "TextButton", {
				Name = "Tab_" .. item.id,
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				LayoutOrder = index,
				Position = r.UDim2.fromScale((index - 1) / count, 0),
				Size = r.UDim2.fromScale(1 / count, 1),
			}, bar)
			Build.tag(tab, "Tab")
			tab:SetAttribute("TabId", item.id)
			Build.label(ctx, "Label", "button", Build.text(ctx, item), nil, {
				Size = r.UDim2.fromScale(1, 1),
				TextXAlignment = r.Enum.TextXAlignment.Center,
				TextTruncate = r.Enum.TextTruncate.AtEnd,
				TextWrapped = false,
			}, tab)
			Build.feedback(ctx, tab, "md")
			tabs[index] = tab
		end
		for index, tab in tabs do
			if tabs[index - 1] then
				tab.NextSelectionLeft = tabs[index - 1]
			end
			if tabs[index + 1] then
				tab.NextSelectionRight = tabs[index + 1]
			end
		end
		local at = indexOf(items, selected) :: number
		local p = indicatorPosition(at, count)
		local indicator = Build.surface(ctx, "Indicator", "accent", {
			Position = r.UDim2.new(p[1], p[2], p[3], p[4]),
			Size = r.UDim2.new(1 / count, -2 * INSET, 0, INDICATOR_H),
			ZIndex = 2,
		}, root)
		Build.corner(ctx, indicator, "pill")
		paint(root, items, selected, ctx)
		return root, { bar = bar, indicator = indicator, tabs = tabs }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		handle.state.selected = handle.props.selected or handle.props.items[1].id
		local function choose(id: string, notify: boolean): boolean
			local items = handle.props.items
			local at = indexOf(items, id)
			if at == nil or id == handle.state.selected then
				return false
			end
			handle.state.selected = id
			paint(handle.root, items, id, ctx)
			Build.play(
				ctx,
				Transitions.make("tabs", "in", {
					Transitions.track(
						"indicator",
						"Position",
						nil,
						indicatorPosition(at, #items),
						{ spring = ctx.tokens.motion.spring.snappy }
					),
				}),
				{ indicator = handle.parts.indicator }
			)
			if notify and handle.props.onSelected then
				handle.props.onSelected(id)
			end
			return true
		end
		handle.state.select = choose
		-- Moves the selection by delta tabs (clamped, no wrap) and reports it.
		function handle.state.step(delta: number): boolean
			local items = handle.props.items
			local at = indexOf(items, handle.state.selected) :: number
			local target = math.clamp(at + delta, 1, #items)
			return choose(items[target].id, true)
		end
		for index, tab in handle.parts.tabs do
			local id = handle.props.items[index].id
			Build.pressable(handle, tab, function()
				choose(id, true)
			end, ctx)
		end
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, _ctx: Build.Context)
		if patch.items ~= nil then
			error("Tabs: items cannot change after mount (build a new Tabs)", 3)
		end
		if patch.selected ~= nil then
			handle.state.select(patch.selected, false)
		end
	end,
})

Tabs.indicatorPosition = indicatorPosition

return Tabs
