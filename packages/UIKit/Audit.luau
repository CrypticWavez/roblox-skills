--!strict
-- @tier T1
-- Audit: automated UI checks with stable rule ids (docs/uikit.md "Audits"). Audit.run takes a
-- snapshot (a flat list of nodes with rectangles, colours and flags) and returns a
-- ui-audit/1 report. Rules:
--   touch_target       interactive node under minTouch px (44, convention) on touch devices
--   contrast           text below WCAG 4.5:1 (3:1 for large text), disabled text exempt
--   text_size          TextSize under minText (12, convention; Roblox docs floor is 9)
--   safe_area          interactive node (error) or text (warn) outside the safe rectangle
--   overlap            two visible interactive siblings overlapping
--   gamepad_reachable  a Selectable node the gamepad cannot reach from the entry node
--   legacy_font        text using a legacy font family (Font enum / Gotham / LegacyArial)
--   text_scaled        TextScaled set (it bypasses the player's PreferredTextSize)
--   text_fit           TextFits false (Studio) or pseudo-localised text likely overflowing
--   shadow_budget      more than 100 UIShadows (Roblox guidance)
--   canvas_group_size  a CanvasGroup with AutomaticSize (docs: use static sizes)
-- Snapshots come from Audit.fromInstances(root, options): it walks an Instance tree (Lune or
-- Roblox) and measures each GuiObject with options.measure (AbsolutePosition/AbsoluteSize in
-- Studio through AuditRoblox; Audit.staticMeasure in Lune, which ignores layouts and
-- constraints, so layout truth is Studio only, probe ui_gallery_audit).
-- Gamepad reachability follows explicit NextSelection links and otherwise a nearest-in-
-- direction approximation of engine navigation, honouring SelectionGroup + Stop; the engine's
-- own algorithm is not published, so this rule is a heuristic until the probe confirms it.
local Check = require("../GameKit/Check")
local Localize = require("./Localize")
local Tokens = require("./Tokens")

local Audit = {}
Audit.SCHEMA = "ui-audit/1"
Audit.RULES = table.freeze({
	"touch_target",
	"contrast",
	"text_size",
	"safe_area",
	"overlap",
	"gamepad_reachable",
	"legacy_font",
	"text_scaled",
	"text_fit",
	"shadow_budget",
	"canvas_group_size",
})
-- FontFace families behind the legacy Font enum values (Font.fromEnum: Legacy is LegacyArial,
-- Arial/ArialBold are Arial, the Gotham values are GothamSSm). A TextLabel whose FontFace was
-- never set reads LegacyArial, so a component that forgets FontFace is caught here.
Audit.LEGACY_FAMILIES = table.freeze({ "LegacyArial", "Arial", "GothamSSm" })

export type Rect = { x: number, y: number, w: number, h: number }
export type Node = {
	path: string,
	parent: string?,
	class: string,
	rect: Rect?,
	visible: boolean,
	interactive: boolean?,
	selectable: boolean?,
	disabled: boolean?,
	text: string?,
	textSize: number?,
	bold: boolean?,
	textColor: { number }?,
	background: { number }?,
	fontFamily: string?,
	textScaled: boolean?,
	textFits: boolean?,
	next: { [string]: string }?,
	group: string?,
	groupStop: { [string]: boolean }?,
	automaticSize: boolean?,
	lineHeight: number?,
}
export type Finding = { rule: string, severity: "error" | "warn", path: string, detail: any }
export type Options = {
	device: string?,
	touch: boolean?,
	viewport: { number }?,
	safe: Rect?,
	minTouch: number?,
	minText: number?,
	contrastBody: number?,
	contrastLarge: number?,
	largeSize: number?,
	largeBoldSize: number?,
	entry: string?,
	rules: { string }?,
	pseudo: boolean?,
	shadows: number?,
}
export type Report = {
	schema: string,
	device: string,
	findings: { Finding },
	counts: { [string]: number },
	checked: number,
	ok: boolean,
}

local function area(a: Rect, b: Rect): number
	local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
	local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
	if w <= 0 or h <= 0 then
		return 0
	end
	return w * h
end

local function inside(inner: Rect, outer: Rect): boolean
	local eps = 0.5
	return inner.x >= outer.x - eps
		and inner.y >= outer.y - eps
		and inner.x + inner.w <= outer.x + outer.w + eps
		and inner.y + inner.h <= outer.y + outer.h + eps
end

local function center(r: Rect): (number, number)
	return r.x + r.w / 2, r.y + r.h / 2
end

-- Problems with a snapshot (empty when usable).
function Audit.validateSnapshot(nodes: any): { string }
	if type(nodes) ~= "table" then
		return { "snapshot must be a list of nodes" }
	end
	local problems = {}
	local seen: { [string]: boolean } = {}
	for index, node in nodes do
		local where = "nodes[" .. index .. "]"
		if type(node) ~= "table" or type(node.path) ~= "string" or node.path == "" then
			table.insert(problems, where .. ": needs a path")
			continue
		end
		if seen[node.path] then
			table.insert(problems, where .. ": duplicate path " .. node.path)
		end
		seen[node.path] = true
		if type(node.class) ~= "string" then
			table.insert(problems, node.path .. ": needs a class")
		end
		if node.rect ~= nil then
			local r = node.rect
			if
				type(r) ~= "table"
				or not (Check.finite(r.x) and Check.finite(r.y) and Check.finite(r.w) and Check.finite(r.h))
			then
				table.insert(problems, node.path .. ": rect needs finite x, y, w, h")
			end
		end
	end
	return problems
end

local DIRECTIONS = { "up", "down", "left", "right" }

-- Nearest selectable in a direction (weighted toward the axis), honouring group Stop.
local function neighbour(node: Node, direction: string, pool: { Node }): Node?
	local cx, cy = center(node.rect :: Rect)
	local stop = node.group ~= nil and node.groupStop ~= nil and (node.groupStop :: any)[direction] == true
	local best, bestScore = nil, math.huge
	for _, other in pool do
		if other == node then
			continue
		end
		if stop and other.group ~= node.group then
			continue
		end
		local ox, oy = center(other.rect :: Rect)
		local dx, dy = ox - cx, oy - cy
		local along, across
		if direction == "down" then
			along, across = dy, dx
		elseif direction == "up" then
			along, across = -dy, dx
		elseif direction == "right" then
			along, across = dx, dy
		else
			along, across = -dx, dy
		end
		if along > 1 then
			local score = along + 2 * math.abs(across)
			if score < bestScore then
				best, bestScore = other, score
			end
		end
	end
	return best
end

-- Runs the rules over a snapshot. Raises on a malformed snapshot.
function Audit.run(nodes: { Node }, options: Options?): Report
	local problems = Audit.validateSnapshot(nodes)
	if #problems > 0 then
		error("Audit.run: " .. table.concat(problems, "; "), 2)
	end
	local o: Options = options or {}
	local device = o.device or "desktop"
	local touch = if o.touch ~= nil then o.touch else (device == "phone" or device == "tablet")
	local minTouch = o.minTouch or 44
	local minText = o.minText or 12
	local contrastBody = o.contrastBody or 4.5
	local contrastLarge = o.contrastLarge or 3
	local largeSize = o.largeSize or 24
	local largeBoldSize = o.largeBoldSize or 19
	local enabled: { [string]: boolean } = {}
	for _, rule in o.rules or Audit.RULES do
		enabled[rule] = true
	end
	local findings: { Finding } = {}
	local function add(rule: string, severity: "error" | "warn", path: string, detail: any)
		if enabled[rule] then
			table.insert(findings, { rule = rule, severity = severity, path = path, detail = detail })
		end
	end

	local visible: { Node } = {}
	for _, node in nodes do
		if node.visible ~= false then
			table.insert(visible, node)
		end
	end

	local selectables: { Node } = {}
	for _, node in visible do
		local r = node.rect
		if node.interactive and r then
			if touch and (r.w < minTouch - 0.5 or r.h < minTouch - 0.5) then
				add("touch_target", "error", node.path, { w = r.w, h = r.h, min = minTouch })
			end
			if o.safe and not inside(r, o.safe) then
				add("safe_area", "error", node.path, { rect = r, safe = o.safe })
			end
		elseif node.text ~= nil and node.text ~= "" and r and o.safe and not inside(r, o.safe) then
			add("safe_area", "warn", node.path, { rect = r, safe = o.safe })
		end
		if node.selectable and node.interactive and r and r.w > 0 and r.h > 0 then
			table.insert(selectables, node)
		end
		if node.text ~= nil and node.text ~= "" then
			local size = node.textSize
			if size ~= nil and size < minText then
				add("text_size", "error", node.path, { size = size, min = minText })
			end
			if node.textColor and node.background and not node.disabled then
				local ratio = Tokens.contrast(node.textColor :: any, node.background :: any)
				local large = size ~= nil
					and (size >= largeSize or (node.bold == true and size >= largeBoldSize))
				local need = if large then contrastLarge else contrastBody
				if ratio + 1e-9 < need then
					add(
						"contrast",
						"error",
						node.path,
						{ ratio = math.floor(ratio * 100 + 0.5) / 100, need = need, large = large }
					)
				end
			end
			if node.fontFamily and table.find(Audit.LEGACY_FAMILIES, node.fontFamily) then
				add("legacy_font", "error", node.path, { family = node.fontFamily })
			end
			if node.textScaled then
				add("text_scaled", "warn", node.path, "TextScaled ignores PreferredTextSize")
			end
			if node.textFits == false then
				add("text_fit", "error", node.path, { text = node.text })
			elseif o.pseudo and r and size then
				local pseudo = Localize.pseudo(node.text :: string)
				if not Localize.estimateFits(pseudo, size, r.w, r.h, node.lineHeight) then
					add("text_fit", "warn", node.path, { pseudo = true, w = r.w, h = r.h })
				end
			end
		end
		if node.class == "CanvasGroup" and node.automaticSize then
			add("canvas_group_size", "warn", node.path, "CanvasGroup with AutomaticSize")
		end
	end

	-- Overlap between interactive siblings.
	local byParent: { [string]: { Node } } = {}
	for _, node in visible do
		if node.interactive and node.rect and node.parent then
			local list = byParent[node.parent :: string] or {}
			byParent[node.parent :: string] = list
			table.insert(list, node)
		end
	end
	for _, list in byParent do
		table.sort(list, function(a: Node, b: Node): boolean
			return a.path < b.path
		end)
		for i = 1, #list do
			for j = i + 1, #list do
				local shared = area(list[i].rect :: Rect, list[j].rect :: Rect)
				if shared > 1 then
					add("overlap", "error", list[i].path, { with = list[j].path, area = shared })
				end
			end
		end
	end

	-- Gamepad reachability from the entry node.
	if #selectables > 0 then
		table.sort(selectables, function(a: Node, b: Node): boolean
			local ra, rb = a.rect :: Rect, b.rect :: Rect
			if math.abs(ra.y - rb.y) > 0.5 then
				return ra.y < rb.y
			end
			if math.abs(ra.x - rb.x) > 0.5 then
				return ra.x < rb.x
			end
			return a.path < b.path
		end)
		local byPath: { [string]: Node } = {}
		for _, node in selectables do
			byPath[node.path] = node
		end
		local entry = (o.entry and byPath[o.entry]) or selectables[1]
		local reached: { [Node]: boolean } = { [entry] = true }
		local queue = { entry }
		local index = 1
		while index <= #queue do
			local node = queue[index]
			index += 1
			for _, direction in DIRECTIONS do
				local link = node.next and (node.next :: any)[direction]
				local target: Node? = nil
				if link ~= nil then
					target = byPath[link]
				else
					target = neighbour(node, direction, selectables)
				end
				if target and not reached[target] then
					reached[target] = true
					table.insert(queue, target)
				end
			end
		end
		for _, node in selectables do
			if not reached[node] then
				add("gamepad_reachable", "error", node.path, { entry = entry.path })
			end
		end
	end

	local shadows = o.shadows or 0
	if shadows > 100 then
		add("shadow_budget", "warn", "<root>", { count = shadows, max = 100 })
	end

	table.sort(findings, function(a: Finding, b: Finding): boolean
		if a.rule ~= b.rule then
			return a.rule < b.rule
		end
		return a.path < b.path
	end)
	local counts: { [string]: number } = {}
	local errors = 0
	for _, finding in findings do
		counts[finding.rule] = (counts[finding.rule] or 0) + 1
		if finding.severity == "error" then
			errors += 1
		end
	end
	return {
		schema = Audit.SCHEMA,
		device = device,
		findings = findings,
		counts = counts,
		checked = #visible,
		ok = errors == 0,
	}
end

-- Paths of findings with a rule (for specs and quick reads).
function Audit.paths(report: Report, rule: string): { string }
	local out = {}
	for _, finding in report.findings do
		if finding.rule == rule then
			table.insert(out, finding.path)
		end
	end
	return out
end

-- ------------------------------------------------------------------ snapshots from Instances

local function rgb(color: any): { number }
	return {
		math.clamp(math.round(color.R * 255), 0, 255),
		math.clamp(math.round(color.G * 255), 0, 255),
		math.clamp(math.round(color.B * 255), 0, 255),
	}
end

local function blend(top: { number }, below: { number }, transparency: number): { number }
	local alpha = 1 - math.clamp(transparency, 0, 1)
	return {
		math.round(top[1] * alpha + below[1] * (1 - alpha)),
		math.round(top[2] * alpha + below[2] * (1 - alpha)),
		math.round(top[3] * alpha + below[3] * (1 - alpha)),
	}
end

local function familyOf(fontFace: any): string?
	if fontFace == nil then
		return nil
	end
	local family = fontFace.Family
	if type(family) ~= "string" then
		return nil
	end
	return string.match(family, "([%w]+)%.json$") or family
end

-- Children of parent in a stable order (Name, then LayoutOrder, then child order) and the path
-- segment of each: its Name, with "#2", "#3", ... on later siblings of the same name, so
-- paths stay unique when a list holds several "Button"s.
local function ordered(parent: any): ({ any }, { [any]: string })
	local children = parent:GetChildren()
	local index: { [any]: number } = {}
	for position, child in children do
		index[child] = position
	end
	local function order(item: any): number
		return if item:IsA("GuiObject") then item.LayoutOrder else 0
	end
	table.sort(children, function(a: any, b: any): boolean
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		if order(a) ~= order(b) then
			return order(a) < order(b)
		end
		return index[a] < index[b]
	end)
	local segments: { [any]: string } = {}
	local seen: { [string]: number } = {}
	for _, child in children do
		local count = (seen[child.Name] or 0) + 1
		seen[child.Name] = count
		segments[child] = if count == 1 then child.Name else child.Name .. "#" .. count
	end
	return children, segments
end

-- The snapshot path of instance under root ("Root.List.Button#2"), as fromInstances names it.
function Audit.pathOf(root: any, instance: any): string
	local parts = {}
	local cursor = instance
	while cursor ~= nil and cursor ~= root do
		local parent = cursor.Parent
		if parent == nil then
			break
		end
		local _, segments = ordered(parent)
		table.insert(parts, 1, segments[cursor])
		cursor = parent
	end
	table.insert(parts, 1, root.Name)
	return table.concat(parts, ".")
end

export type SnapshotOptions = {
	measure: (instance: any) -> Rect?,
	backdrop: { number }?, -- colour behind the root (default black, a 3D scene at night)
	textFits: ((instance: any) -> boolean?)?,
}

-- A flat snapshot of every GuiObject under root (root included when it is one). Paths are
-- relative to root ("Root.Panel.Button"). Visibility folds in ancestors' Visible/Enabled;
-- interactive means a GuiButton or TextBox that is Active and Interactable; background is the
-- composited colour behind the node.
function Audit.fromInstances(root: any, options: SnapshotOptions): { Node }
	assert(
		type(options) == "table" and type(options.measure) == "function",
		"Audit.fromInstances: needs options.measure"
	)
	local nodes: { Node } = {}
	local backdrop = options.backdrop or { 0, 0, 0 }
	local function walk(
		instance: any,
		path: string,
		parentPath: string?,
		shown: boolean,
		behind: { number },
		disabled: boolean,
		group: string?,
		stop: { [string]: boolean }?
	)
		local isGui = instance:IsA("GuiObject")
		local here = shown
		local color = behind
		local groupHere, stopHere = group, stop
		if instance:IsA("LayerCollector") then
			here = here and instance.Enabled
		end
		if isGui then
			here = here and instance.Visible
			if instance.BackgroundTransparency < 1 then
				color = blend(rgb(instance.BackgroundColor3), behind, instance.BackgroundTransparency)
			end
			local interactiveClass = instance:IsA("GuiButton") or instance:IsA("TextBox")
			local enabled = instance.Interactable and instance.Active
			local off = disabled or not instance.Interactable
			if instance.SelectionGroup then
				groupHere = path
				stopHere = {
					up = instance.SelectionBehaviorUp.Name == "Stop",
					down = instance.SelectionBehaviorDown.Name == "Stop",
					left = instance.SelectionBehaviorLeft.Name == "Stop",
					right = instance.SelectionBehaviorRight.Name == "Stop",
				}
			end
			local node: Node = {
				path = path,
				parent = parentPath,
				class = instance.ClassName,
				rect = options.measure(instance),
				visible = here,
				interactive = interactiveClass and enabled,
				selectable = instance.Selectable,
				disabled = off,
				group = groupHere,
				groupStop = stopHere,
				automaticSize = instance.AutomaticSize.Name ~= "None",
			}
			local links = {}
			local any = false
			for _, side in { "Up", "Down", "Left", "Right" } do
				local target = instance["NextSelection" .. side]
				if target ~= nil and target:IsDescendantOf(root) then
					links[string.lower(side)] = Audit.pathOf(root, target)
					any = true
				end
			end
			if any then
				node.next = links
			end
			if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				node.text = instance.Text
				node.textSize = instance.TextSize
				-- Text that is not drawn (TextTransparency 1, e.g. the first frame of a fade-in) has no
				-- contrast to check; partly transparent text is blended and checked.
				if instance.TextTransparency < 0.99 then
					node.textColor = blend(rgb(instance.TextColor3), color, instance.TextTransparency)
				end
				node.background = color
				node.fontFamily = familyOf(instance.FontFace)
				node.bold = instance.FontFace.Weight.Value >= 600
				node.textScaled = instance.TextScaled
				node.lineHeight = instance.LineHeight
				if options.textFits then
					node.textFits = options.textFits(instance)
				end
			end
			table.insert(nodes, node)
		end
		local children, segments = ordered(instance)
		for _, child in children do
			if child:IsA("GuiBase2d") then
				walk(
					child,
					path .. "." .. segments[child],
					if isGui then path else parentPath,
					here,
					color,
					disabled or (isGui and not instance.Interactable),
					groupHere,
					stopHere
				)
			end
		end
	end
	walk(root, root.Name, nil, true, backdrop, false, nil, nil)
	return nodes
end

-- Number of UIShadow instances under root (for the shadow_budget rule).
function Audit.countShadows(root: any): number
	local count = 0
	for _, item in root:GetDescendants() do
		if item.ClassName == "UIShadow" then
			count += 1
		end
	end
	return count
end

-- A measure function that computes rectangles from Position, Size, AnchorPoint and UIPadding
-- (scale and offset) inside a viewport, the way Roblox does for unconstrained children. It
-- ignores layouts, constraints, AutomaticSize and ScreenGui insets beyond `safe`: Lune specs
-- use it on explicitly positioned trees; real layout comes from Studio.
function Audit.staticMeasure(viewport: { number }, safe: Rect?): (instance: any) -> Rect?
	local cache: { [any]: Rect } = setmetatable({}, { __mode = "k" }) :: any
	local function content(instance: any, rect: Rect): Rect
		local padding = instance:FindFirstChildOfClass("UIPadding")
		if padding == nil then
			return rect
		end
		local left = padding.PaddingLeft.Scale * rect.w + padding.PaddingLeft.Offset
		local right = padding.PaddingRight.Scale * rect.w + padding.PaddingRight.Offset
		local top = padding.PaddingTop.Scale * rect.h + padding.PaddingTop.Offset
		local bottom = padding.PaddingBottom.Scale * rect.h + padding.PaddingBottom.Offset
		return {
			x = rect.x + left,
			y = rect.y + top,
			w = math.max(rect.w - left - right, 0),
			h = math.max(rect.h - top - bottom, 0),
		}
	end
	local measure: (any) -> Rect?
	measure = function(instance: any): Rect?
		if cache[instance] then
			return cache[instance]
		end
		local parent = instance.Parent
		local outer: Rect
		if parent == nil or not parent:IsA("GuiBase2d") then
			outer = { x = 0, y = 0, w = viewport[1], h = viewport[2] }
		elseif parent:IsA("LayerCollector") then
			local insets = parent:IsA("ScreenGui") and parent.ScreenInsets.Name ~= "None"
			outer = if insets and safe then safe else { x = 0, y = 0, w = viewport[1], h = viewport[2] }
		else
			local parentRect = measure(parent)
			if parentRect == nil then
				return nil
			end
			outer = content(parent, parentRect)
		end
		if not instance:IsA("GuiObject") then
			return outer
		end
		local size, position, anchor = instance.Size, instance.Position, instance.AnchorPoint
		local w = outer.w * size.X.Scale + size.X.Offset
		local h = outer.h * size.Y.Scale + size.Y.Offset
		local x = outer.x + outer.w * position.X.Scale + position.X.Offset - anchor.X * w
		local y = outer.y + outer.h * position.Y.Scale + position.Y.Offset - anchor.Y * h
		local rect = { x = x, y = y, w = w, h = h }
		cache[instance] = rect
		return rect
	end
	return measure
end

return Audit
