--!strict
-- @tier T1
-- LeaderboardPanel: shows ranked rows { rank, name, value, highlight? } that a board produced
-- (GameKit leaderboard cores and their adapters fetch and sort; this only renders). At most 100
-- rows; an empty list shows emptyKey (default uikit.leaderboard.empty). Names are player display
-- names: RichText stays off so a name can never inject markup, and long names truncate. Values
-- format as integer, compact or time (RollingCounter.format and Timer.format). The highlighted
-- row (the local player) is raised and outlined, and tagged "Highlight". Ranks 1-3 use a heavier
-- weight instead of colour, so the kit stays neutral. Tree:
--   LeaderboardPanel (Frame) > Corner, Stroke, Padding, Title?, Empty, List (ScrollingFrame) >
--   Layout, Row_<index> (Frame) > Corner, Stroke?, Rank, Name, Value
local Build = require("../Build")
local Check = require("../../GameKit/Check")
local RollingCounter = require("./RollingCounter")
local Style = require("../Style")
local Timer = require("./Timer")

local MAX_ROWS = 100
local RANK_W, VALUE_W = 48, 120 -- px, convention

local function valueText(value: number, style: string): string
	if style == "time" then
		return Timer.format(value, "clock")
	end
	return RollingCounter.format(value, if style == "compact" then "compact" else "integer")
end

local function buildRows(list: any, props: { [string]: any }, ctx: Build.Context)
	local r = ctx.env.roblox
	for index, entry in props.entries do
		local row =
			Build.surface(ctx, "Row_" .. index, if entry.highlight then "surfaceRaised" else "surface", {
				Size = r.UDim2.new(1, 0, 0, props.rowHeight),
				LayoutOrder = index,
				BackgroundTransparency = if entry.highlight then 0 else 1,
			}, list)
		Build.corner(ctx, row, "sm")
		if entry.highlight then
			Build.stroke(ctx, row, "borderStrong", "thin")
			Build.tag(row, "Highlight")
		end
		local rank = Build.label(ctx, "Rank", "numeric", tostring(entry.rank), "textMuted", {
			Size = r.UDim2.new(0, RANK_W, 1, 0),
			TextWrapped = false,
			TextXAlignment = r.Enum.TextXAlignment.Center,
		}, row)
		if entry.rank <= 3 then
			rank.FontFace = Style.font(ctx.tokens, "mono", ctx.env, "Bold")
			rank.TextColor3 = Style.color(ctx.tokens, "text", ctx.env)
		end
		Build.label(ctx, "Name", "body", entry.name, nil, {
			Position = r.UDim2.fromOffset(RANK_W, 0),
			Size = r.UDim2.new(1, -(RANK_W + VALUE_W), 1, 0),
			TextWrapped = false,
			TextTruncate = r.Enum.TextTruncate.AtEnd,
			RichText = false,
		}, row)
		Build.label(ctx, "Value", "numeric", valueText(entry.value, props.valueStyle), nil, {
			AnchorPoint = r.Vector2.new(1, 0),
			Position = r.UDim2.fromScale(1, 0),
			Size = r.UDim2.new(0, VALUE_W - ctx.tokens.space.sm, 1, 0),
			TextWrapped = false,
			TextXAlignment = r.Enum.TextXAlignment.Right,
		}, row)
	end
end

local LeaderboardPanel = Build.component({
	name = "LeaderboardPanel",
	schema = Build.schema({
		entries = { kind = "list", required = true, max = MAX_ROWS },
		valueStyle = { kind = "enum", choices = { "integer", "compact", "time" }, default = "integer" },
		emptyKey = { kind = "key", default = "uikit.leaderboard.empty" },
		rowHeight = { kind = "number", min = 24, max = 120, default = 40 },
		width = { kind = "number", min = 200, max = 2048 },
		height = { kind = "number", min = 100, max = 4096, default = 420 },
	}, true),
	check = function(props: any): { string }
		local problems = {}
		for index, entry in props.entries do
			local where = "entries[" .. index .. "]"
			if type(entry) ~= "table" then
				table.insert(problems, where .. " must be a table")
				continue
			end
			if not (Check.integer(entry.rank) and entry.rank >= 1) then
				table.insert(problems, where .. ".rank must be an integer >= 1")
			end
			if type(entry.name) ~= "string" or entry.name == "" or #entry.name > 64 then
				table.insert(problems, where .. ".name must be a string of 1-64 bytes")
			end
			if not Check.finite(entry.value) then
				table.insert(problems, where .. ".value must be a finite number")
			end
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local root = Build.surface(ctx, "LeaderboardPanel", "surface", {
			Size = if props.width
				then r.UDim2.fromOffset(props.width, props.height)
				else r.UDim2.new(1, 0, 0, props.height),
		})
		Build.tag(root, "LeaderboardPanel")
		Build.corner(ctx, root, "lg")
		Build.stroke(ctx, root, "border", "hairline")
		Build.padding(ctx, root, "md")
		local top = 0
		local title = Build.text(ctx, props)
		if title ~= "" then
			Build.label(ctx, "Title", "title", title, nil, {
				Size = r.UDim2.new(1, 0, 0, ctx.tokens.text.title.size + 6),
				TextWrapped = false,
				TextTruncate = r.Enum.TextTruncate.AtEnd,
			}, root)
			top = ctx.tokens.text.title.size + 6 + ctx.tokens.space.sm
		end
		local list = Build.make(ctx, "ScrollingFrame", {
			Name = "List",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = r.UDim2.fromOffset(0, top),
			Size = r.UDim2.new(1, 0, 1, -top),
			CanvasSize = r.UDim2.new(),
			AutomaticCanvasSize = r.Enum.AutomaticSize.Y,
			ScrollingDirection = r.Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
		}, root)
		Build.list(ctx, list, "Vertical", { gap = "xxs" })
		Build.label(ctx, "Empty", "body", ctx.text(props.emptyKey), "textMuted", {
			Position = r.UDim2.fromOffset(0, top),
			Size = r.UDim2.new(1, 0, 0, props.rowHeight),
			TextXAlignment = r.Enum.TextXAlignment.Center,
			Visible = #props.entries == 0,
		}, root)
		buildRows(list, props, ctx)
		return root, { list = list }
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.entries == nil and patch.valueStyle == nil then
			return
		end
		local list = handle.parts.list
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		handle.root:FindFirstChild("Empty").Visible = #handle.props.entries == 0
		buildRows(list, handle.props, ctx)
	end,
})

LeaderboardPanel.valueText = valueText

return LeaderboardPanel
