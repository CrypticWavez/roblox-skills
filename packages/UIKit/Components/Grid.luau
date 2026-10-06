--!strict
-- @tier T1
-- Grid: a responsive container that lays its children out in equal columns with UIGridLayout.
-- columns is a number or a table per device class ({ phone = 2, tablet = 3, desktop = 4,
-- console = 4, vr = 3 }; Grid.columnsFor is the pure pick, missing classes fall back to
-- desktop). Cells are cellHeight px tall and share the width minus gaps. scroll = true makes it a
-- ScrollingFrame whose canvas grows with the content (AutomaticCanvasSize Y), else a Frame that
-- grows (AutomaticSize Y). Children go in handle.parts.content (the root) in LayoutOrder; the
-- grid itself has no behaviour. update({ columns }) or a class change (re-mount with a new ctx)
-- recomputes the cell size. Tree:
--   Grid (Frame | ScrollingFrame) > Layout (UIGridLayout), Padding
local Build = require("../Build")

local DEFAULT_COLUMNS = { phone = 2, tablet = 3, desktop = 4, console = 4, vr = 3 }

-- Columns for a device class from a number or a per-device table.
local function columnsFor(device: string, spec: any): number
	if type(spec) == "number" then
		return spec
	end
	local table_ = spec or DEFAULT_COLUMNS
	return table_[device] or table_.desktop or DEFAULT_COLUMNS.desktop
end

local function cellSize(ctx: Build.Context, columns: number, gap: number, height: number): any
	return ctx.env.roblox.UDim2.new(1 / columns, -gap * (columns - 1) / columns, 0, height)
end

local function validColumns(spec: any): boolean
	if type(spec) == "number" then
		return spec % 1 == 0 and spec >= 1 and spec <= 12
	end
	if type(spec) ~= "table" then
		return false
	end
	for key, value in spec do
		if
			type(key) ~= "string"
			or DEFAULT_COLUMNS[key] == nil
			or type(value) ~= "number"
			or value % 1 ~= 0
			or value < 1
			or value > 12
		then
			return false
		end
	end
	return true
end

local Grid = Build.component({
	name = "Grid",
	schema = Build.schema({
		columns = { kind = "any" },
		cellHeight = { kind = "number", min = 8, max = 2048, default = 120 },
		gap = { kind = "number", min = 0, max = 128 },
		padding = { kind = "any" },
		scroll = { kind = "boolean", default = false },
	}),
	check = function(props: any): { string }
		if props.columns ~= nil and not validColumns(props.columns) then
			return { "columns must be 1-12 or a table of device = 1-12" }
		end
		return {}
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local columns = columnsFor(ctx.class.device, props.columns)
		local gap = props.gap or ctx.class.gutter
		local root
		if props.scroll then
			root = Build.make(ctx, "ScrollingFrame", {
				Name = "Grid",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = r.UDim2.fromScale(1, 1),
				CanvasSize = r.UDim2.new(),
				AutomaticCanvasSize = r.Enum.AutomaticSize.Y,
				ScrollingDirection = r.Enum.ScrollingDirection.Y,
				ScrollBarThickness = 6,
				Selectable = false,
			})
		else
			root = Build.frame(ctx, "Grid", {
				Size = r.UDim2.fromScale(1, 0),
				AutomaticSize = r.Enum.AutomaticSize.Y,
			})
		end
		Build.tag(root, "Grid")
		Build.make(ctx, "UIGridLayout", {
			Name = "Layout",
			CellSize = cellSize(ctx, columns, gap, props.cellHeight),
			CellPadding = r.UDim2.fromOffset(gap, gap),
			SortOrder = r.Enum.SortOrder.LayoutOrder,
			FillDirection = r.Enum.FillDirection.Horizontal,
			HorizontalAlignment = r.Enum.HorizontalAlignment.Left,
			VerticalAlignment = r.Enum.VerticalAlignment.Top,
			FillDirectionMaxCells = columns,
		}, root)
		if props.padding ~= nil then
			Build.padding(ctx, root, props.padding)
		end
		root:SetAttribute("Columns", columns)
		return root, { content = root, layout = root:FindFirstChild("Layout") }
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		if patch.columns ~= nil or patch.cellHeight ~= nil or patch.gap ~= nil then
			local p = handle.props
			local columns = columnsFor(ctx.class.device, p.columns)
			local gap = p.gap or ctx.class.gutter
			local layout = handle.parts.layout
			layout.CellSize = cellSize(ctx, columns, gap, p.cellHeight)
			layout.CellPadding = ctx.env.roblox.UDim2.fromOffset(gap, gap)
			layout.FillDirectionMaxCells = columns
			handle.root:SetAttribute("Columns", columns)
		end
	end,
})

Grid.columnsFor = columnsFor
Grid.DEFAULT_COLUMNS = table.freeze(DEFAULT_COLUMNS)

return Grid
