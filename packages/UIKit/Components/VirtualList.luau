--!strict
-- @tier T1
-- VirtualList: a vertical ScrollingFrame for long lists with fixed-height rows that keeps only
-- the visible rows (plus overscan) as Instances and recycles them while scrolling, so 10 000
-- entries cost the same as 20. VirtualList.window (pure) gives the first and last row for a
-- scroll offset; the component pools Row_<slot> frames, positions each at (index - 1) * rowHeight
-- and calls render(row, index, ctx) whenever a slot shows a new index (render fills the row:
-- labels, buttons, images; it must not keep its own references to the row). The window follows
-- CanvasPosition and AbsoluteSize changes (ctx.onChanged) and the viewport height comes from
-- ctx.measure. update({ count }) resizes the canvas and redraws. Tree:
--   VirtualList (ScrollingFrame) > Row_1 .. Row_n (Frame, attribute Index)
local Build = require("../Build")

local MAX_COUNT = 1000000
local MAX_POOL = 200

-- First and last row index (1-based, inclusive) visible in a viewport of height viewport at
-- scroll offset scroll, widened by overscan rows; (1, 0) when there is nothing to show.
local function window(
	scroll: number,
	viewport: number,
	rowHeight: number,
	count: number,
	overscan: number?
): (number, number)
	if count <= 0 or rowHeight <= 0 or viewport <= 0 then
		return 1, 0
	end
	local extra = overscan or 0
	local first = math.floor(math.max(scroll, 0) / rowHeight) + 1 - extra
	local last = math.ceil((math.max(scroll, 0) + viewport) / rowHeight) + extra
	return math.max(first, 1), math.min(last, count)
end

local VirtualList = Build.component({
	name = "VirtualList",
	schema = Build.schema({
		count = { kind = "integer", min = 0, max = MAX_COUNT, required = true },
		rowHeight = { kind = "number", min = 1, max = 2048, required = true },
		render = { kind = "function", required = true },
		overscan = { kind = "integer", min = 0, max = 20, default = 3 },
		gap = { kind = "number", min = 0, max = 256, default = 0 },
		viewportHint = { kind = "number", min = 1, max = 8192, default = 600 },
	}),
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local stride = props.rowHeight + props.gap
		local root = Build.make(ctx, "ScrollingFrame", {
			Name = "VirtualList",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = r.UDim2.fromScale(1, 1),
			CanvasSize = r.UDim2.new(0, 0, 0, math.max(props.count * stride - props.gap, 0)),
			AutomaticCanvasSize = r.Enum.AutomaticSize.None,
			ScrollingDirection = r.Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = r.Color3.fromRGB(table.unpack(ctx.tokens.color.borderStrong)),
			ElasticBehavior = r.Enum.ElasticBehavior.WhenScrollable,
			Selectable = false,
		})
		Build.tag(root, "VirtualList")
		return root, {}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local r = ctx.env.roblox
		local root = handle.root
		local pool: { any } = {}
		local shown: { [number]: number } = {} -- slot -> index

		local function slotFor(index: number): number
			return ((index - 1) % #pool) + 1
		end

		local function refresh()
			local p = handle.props
			local stride = p.rowHeight + p.gap
			local rect = ctx.measure(root)
			local viewport = if rect and rect.h > 0 then rect.h else p.viewportHint
			local first, last = window(root.CanvasPosition.Y, viewport, stride, p.count, p.overscan)
			local needed = math.min(math.max(last - first + 1, 0), MAX_POOL)
			-- Grow the pool to cover the window (never shrinks: rows are cheap once made).
			while #pool < needed do
				local slot = #pool + 1
				local row = Build.frame(ctx, "Row_" .. slot, {
					Size = r.UDim2.new(1, 0, 0, p.rowHeight),
					Visible = false,
				}, root)
				pool[slot] = row
			end
			if #pool == 0 then
				return
			end
			local used: { [number]: boolean } = {}
			for index = first, math.min(last, first + #pool - 1) do
				local slot = slotFor(index)
				used[slot] = true
				local row = pool[slot]
				if shown[slot] ~= index then
					shown[slot] = index
					row.Position = r.UDim2.fromOffset(0, (index - 1) * stride)
					row:SetAttribute("Index", index)
					local ok, err = pcall(p.render, row, index, ctx)
					if not ok then
						ctx.env.report("VirtualList render error: " .. tostring(err))
					end
				end
				row.Visible = true
			end
			for slot, row in pool do
				if not used[slot] then
					row.Visible = false
					shown[slot] = nil
				end
			end
			handle.state.first, handle.state.last = first, last
		end
		handle.state.refresh = refresh
		function handle.state.invalidate()
			table.clear(shown)
		end
		-- Scrolls so row index is at the top (clamped to the canvas).
		function handle.state.scrollTo(index: number)
			local p = handle.props
			local stride = p.rowHeight + p.gap
			local target = math.clamp(index, 1, math.max(p.count, 1))
			root.CanvasPosition = r.Vector2.new(0, (target - 1) * stride)
			refresh()
		end
		handle.state.pool = pool
		handle.scope:Add(ctx.onChanged(root, "CanvasPosition", refresh))
		handle.scope:Add(ctx.onChanged(root, "AbsoluteSize", refresh))
		refresh()
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, ctx: Build.Context)
		local p = handle.props
		if patch.count ~= nil or patch.rowHeight ~= nil or patch.gap ~= nil then
			local stride = p.rowHeight + p.gap
			handle.root.CanvasSize = ctx.env.roblox.UDim2.new(0, 0, 0, math.max(p.count * stride - p.gap, 0))
		end
		-- Every visible row renders again (data under the same indices may have changed).
		handle.state.invalidate()
		handle.state.refresh()
	end,
})

VirtualList.window = window
VirtualList.MAX_POOL = MAX_POOL

return VirtualList
