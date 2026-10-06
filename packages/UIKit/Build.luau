--!strict
-- @tier T1
-- Build: what every UIKit component shares (docs/uikit.md "Components"): the build context, an
-- Instance factory, prop schemas and the component contract.
--   ctx = Build.context({ env, tokens?, theme?, class?, motion?, text?, on?, onChanged?,
--                         measure?, scope?, runner?, inputMap? })
--   Component.build(props, ctx) -> (root, parts)   pure tree, stable names, props validated
--   Component.attach(root, parts, props, ctx) -> handle   behaviour on a built tree
--   Component.mount(props, ctx, parent?) -> handle { root, parts, state, update, destroy }
-- build only creates Instances (env.roblox, so it runs in Lune); mount also wires behaviour
-- through ctx.on(instance, event, fn) and ctx.onChanged(instance, property, fn). The defaults
-- connect real engine events; Lune specs pass a fake hub and fire events by hand. Every
-- connection and Instance a handle makes is tracked by a Stage 0 Scope (ctx.scope:Extend()),
-- so handle:destroy() leaves nothing behind. Text comes from localisation keys through
-- ctx.text (UIKit/Localize); `text` props are for dynamic values (numbers, names). Fonts are
-- FontFace only (UIKit/Style). guard is the re-entrancy guard lifted from Creator/UI.
local Breakpoints = require("./Breakpoints")
local Check = require("../GameKit/Check")
local Ease = require("./Ease")
local Localize = require("./Localize")
local Scope = require("../GameKit/Scope")
local Style = require("./Style")
local Tokens = require("./Tokens")
local Transitions = require("./Transitions")

local Build = {}

export type Rect = { x: number, y: number, w: number, h: number }
export type Context = {
	env: any,
	tokens: Tokens.Tokens,
	class: Breakpoints.Class,
	motion: { reducedMotion: boolean },
	text: (key: string, args: { [any]: any }?) -> string,
	on: (instance: any, event: string, fn: (...any) -> ()) -> any,
	onChanged: (instance: any, property: string, fn: () -> ()) -> any,
	measure: (instance: any) -> Rect?,
	scope: any,
	runner: Transitions.Runner,
	inputMap: any?,
	glyphImage: ((key: string) -> string?)?,
}

-- Engine defaults (only called in Roblox; specs pass fakes).
local function robloxOn(instance: any, event: string, fn: (...any) -> ()): any
	return instance[event]:Connect(fn)
end
local function robloxOnChanged(instance: any, property: string, fn: () -> ()): any
	return instance:GetPropertyChangedSignal(property):Connect(fn)
end
local function robloxMeasure(instance: any): Rect?
	local position, size = instance.AbsolutePosition, instance.AbsoluteSize
	return { x = position.X, y = position.Y, w = size.X, h = size.Y }
end

export type ContextOptions = {
	env: any,
	tokens: Tokens.Tokens?,
	theme: string?,
	class: Breakpoints.Class?,
	motion: { reducedMotion: boolean? }?,
	text: ((key: string, args: { [any]: any }?) -> string)?,
	on: ((any, string, (...any) -> ()) -> any)?,
	onChanged: ((any, string, () -> ()) -> any)?,
	measure: ((any) -> Rect?)?,
	scope: any?,
	runner: Transitions.Runner?,
	inputMap: any?,
	glyphImage: ((key: string) -> string?)?,
}

-- A complete build context; options.env needs roblox (datatypes). Missing parts get defaults:
-- dark tokens, a 1280x720 keyboard desktop class, no reduced motion, kit default strings,
-- engine event wiring, a fresh Scope and a Transitions runner writing Instances.
function Build.context(options: ContextOptions): Context
	if type(options) ~= "table" or type(options.env) ~= "table" or options.env.roblox == nil then
		error("Build.context: needs { env } with env.roblox (Roblox datatypes)", 2)
	end
	local env = options.env
	local tokens = options.tokens or Tokens.resolve(options.theme)
	local runner = options.runner
		or Transitions.runner(Transitions.instanceApply(env), Transitions.instanceRead(), env)
	return {
		env = env,
		tokens = tokens,
		class = options.class
			or Breakpoints.classify({ viewport = { 1280, 720 }, input = "KeyboardAndMouse" }),
		motion = { reducedMotion = options.motion ~= nil and options.motion.reducedMotion == true },
		text = options.text or Localize.new():fn(),
		on = options.on or robloxOn,
		onChanged = options.onChanged or robloxOnChanged,
		measure = options.measure or robloxMeasure,
		scope = options.scope or Scope.new(env),
		runner = runner,
		inputMap = options.inputMap,
		glyphImage = options.glyphImage,
	}
end

-- A copy of ctx with some fields replaced (a child scope, another class, ...).
function Build.with(ctx: Context, patch: { [string]: any }): Context
	local out: any = table.clone(ctx :: any)
	for key, value in patch do
		out[key] = value
	end
	return out
end

-- ------------------------------------------------------------------ Instances

-- An Instance of className with props (Name first, then the rest in key order so results are
-- deterministic) parented to parent.
function Build.make(ctx: Context, className: string, props: { [string]: any }?, parent: any?): any
	local instance = ctx.env.roblox.Instance.new(className)
	local p: { [string]: any } = props or {}
	if p.Name ~= nil then
		instance.Name = p.Name
	end
	local keys = {}
	for key in p do
		if key ~= "Name" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for _, key in keys do
		instance[key] = p[key]
	end
	if parent ~= nil then
		instance.Parent = parent
	end
	return instance
end

function Build.tag(instance: any, ...: string)
	for _, tag in { ... } do
		instance:AddTag(tag)
	end
end

local function udim(ctx: Context, px: number): any
	return ctx.env.roblox.UDim.new(0, px)
end

function Build.corner(ctx: Context, parent: any, radius: string | number?, name: string?): any
	return Build.make(
		ctx,
		"UICorner",
		{ Name = name or "Corner", CornerRadius = Style.radius(ctx.tokens, radius or "md", ctx.env) },
		parent
	)
end

function Build.padding(ctx: Context, parent: any, spec: any): any
	local props = Style.padding(ctx.tokens, spec, ctx.env)
	props.Name = "Padding"
	return Build.make(ctx, "UIPadding", props, parent)
end

function Build.stroke(ctx: Context, parent: any, slot: string, width: string | number?, name: string?): any
	local props = Style.stroke(ctx.tokens, slot, width or "hairline", ctx.env)
	props.Name = name or "Stroke"
	return Build.make(ctx, "UIStroke", props, parent)
end

export type ListOptions = {
	gap: (string | number)?,
	align: string?, -- Left, Center, Right
	valign: string?, -- Top, Center, Bottom
	wraps: boolean?,
	flex: string?, -- UIFlexAlignment on the main axis (Fill, SpaceBetween, ...)
	name: string?,
}

-- A UIListLayout ("Vertical" or "Horizontal") sorted by LayoutOrder.
function Build.list(ctx: Context, parent: any, direction: string, options: ListOptions?): any
	local o: ListOptions = options or {}
	local enum = ctx.env.roblox.Enum
	local props: { [string]: any } = {
		Name = o.name or "Layout",
		FillDirection = enum.FillDirection[direction],
		SortOrder = enum.SortOrder.LayoutOrder,
		Padding = udim(ctx, Tokens.space(ctx.tokens, o.gap or "sm")),
		HorizontalAlignment = enum.HorizontalAlignment[o.align or "Left"],
		VerticalAlignment = enum.VerticalAlignment[o.valign or "Top"],
	}
	if o.wraps then
		props.Wraps = true
	end
	if o.flex then
		if direction == "Horizontal" then
			props.HorizontalFlex = enum.UIFlexAlignment[o.flex]
		else
			props.VerticalFlex = enum.UIFlexAlignment[o.flex]
		end
	end
	return Build.make(ctx, "UIListLayout", props, parent)
end

-- A colour slot as a Transitions Color3 value { r, g, b } in 0-1.
function Build.color01(ctx: Context, slot: string): { number }
	local rgb = ctx.tokens.color[slot]
	if rgb == nil then
		error("Build.color01: unknown colour slot " .. tostring(slot), 2)
	end
	return { rgb[1] / 255, rgb[2] / 255, rgb[3] / 255 }
end

-- A UDim2 as a Transitions value { xs, xo, ys, yo }.
function Build.udim2(value: any): { number }
	return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
end

-- A transparent Frame.
function Build.frame(ctx: Context, name: string, props: { [string]: any }?, parent: any?): any
	local p: { [string]: any } = { Name = name, BackgroundTransparency = 1, BorderSizePixel = 0 }
	for key, value in props or {} :: { [string]: any } do
		p[key] = value
	end
	return Build.make(ctx, "Frame", p, parent)
end

-- A Frame filled with a colour slot.
function Build.surface(ctx: Context, name: string, slot: string, props: { [string]: any }?, parent: any?): any
	local p = Style.surface(ctx.tokens, slot, ctx.env)
	p.Name = name
	for key, value in props or {} :: { [string]: any } do
		p[key] = value
	end
	local frame = Build.make(ctx, "Frame", p, parent)
	Build.tag(frame, "UIKitSurface")
	return frame
end

local TITLE_ROLES = { title = true, heading = true, display = true }

-- A TextLabel in a text role (FontFace, size, line height, colour slot). Text arrives already
-- localised, so AutoLocalize is off; RichText is off unless props turn it on.
function Build.label(
	ctx: Context,
	name: string,
	role: string,
	text: string,
	slot: string?,
	props: { [string]: any }?,
	parent: any?
): any
	local p = Style.text(ctx.tokens, role, ctx.env, slot)
	p.Name = name
	p.Text = text
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.TextWrapped = true
	p.RichText = false
	p.AutoLocalize = false
	p.TextXAlignment = ctx.env.roblox.Enum.TextXAlignment.Left
	for key, value in props or {} :: { [string]: any } do
		p[key] = value
	end
	local label = Build.make(ctx, "TextLabel", p, parent)
	Build.tag(label, "UIKitText")
	if TITLE_ROLES[role] then
		Build.tag(label, "UIKitTitle")
	end
	if slot == "textMuted" then
		Build.tag(label, "UIKitMuted")
	end
	return label
end

-- Fills a text object's FontFace/TextSize/colour from a role (for TextButtons and TextBoxes).
function Build.textProps(ctx: Context, instance: any, role: string, slot: string?)
	for key, value in Style.text(ctx.tokens, role, ctx.env, slot) do
		instance[key] = value
	end
	instance.AutoLocalize = false
	instance.RichText = false
end

-- ------------------------------------------------------------------ props

export type Field = {
	kind: string, -- string, number, integer, boolean, function, table, key, label, enum, list, any, instance
	required: boolean?,
	default: any,
	min: number?,
	max: number?,
	choices: { string }?,
	maxLength: number?,
}
export type Schema = { [string]: Field }

local function fieldProblem(name: string, field: Field, value: any): string?
	local kind = field.kind
	if kind == "any" then
		return nil
	elseif kind == "string" then
		if
			type(value) ~= "string"
			or (field.maxLength and utf8.len(value) and (utf8.len(value) :: number) > field.maxLength)
		then
			return name
				.. " must be a string"
				.. (if field.maxLength then " of at most " .. field.maxLength .. " characters" else "")
		end
	elseif kind == "number" or kind == "integer" then
		local ok = if kind == "integer" then Check.integer(value) else Check.finite(value)
		if not ok then
			return name .. " must be " .. (if kind == "integer" then "an integer" else "a finite number")
		end
		if field.min and value < field.min then
			return string.format("%s must be >= %s", name, tostring(field.min))
		end
		if field.max and value > field.max then
			return string.format("%s must be <= %s", name, tostring(field.max))
		end
	elseif kind == "boolean" then
		if type(value) ~= "boolean" then
			return name .. " must be a boolean"
		end
	elseif kind == "function" then
		if type(value) ~= "function" then
			return name .. " must be a function"
		end
	elseif kind == "table" or kind == "list" then
		if type(value) ~= "table" then
			return name .. " must be a " .. kind
		end
		if kind == "list" and #value == 0 and next(value) ~= nil then
			return name .. " must be a list"
		end
		if field.max and #value > field.max then
			return string.format("%s holds at most %d entries", name, field.max)
		end
	elseif kind == "key" then
		if not Localize.validKey(value) then
			return name .. " must be a localisation key (letters, digits, _ . -)"
		end
	elseif kind == "label" then
		if not Check.label(value) then
			return name .. " must be a lower_snake label"
		end
	elseif kind == "enum" then
		if type(value) ~= "string" or not table.find(field.choices :: { string }, value) then
			return name .. " must be one of " .. table.concat(field.choices :: { string }, ", ")
		end
	elseif kind == "instance" then
		if typeof(value) ~= "Instance" then
			return name .. " must be an Instance"
		end
	else
		return name .. ": schema has unknown kind " .. tostring(kind)
	end
	return nil
end

-- Problems with props against a schema: unknown keys, missing required keys, wrong kinds.
function Build.validate(schema: Schema, props: any, component: string): { string }
	if type(props) ~= "table" then
		return { component .. ": props must be a table" }
	end
	local problems = {}
	for key, value in props do
		local field = schema[key]
		if field == nil then
			local allowed = {}
			for name in schema do
				table.insert(allowed, name)
			end
			table.sort(allowed)
			table.insert(
				problems,
				string.format(
					"%s: unknown prop %s (allowed: %s)",
					component,
					tostring(key),
					table.concat(allowed, ", ")
				)
			)
		else
			local problem = fieldProblem(tostring(key), field, value)
			if problem then
				table.insert(problems, component .. ": " .. problem)
			end
		end
	end
	for key, field in schema do
		if field.required and props[key] == nil then
			table.insert(problems, component .. ": " .. key .. " is required")
		end
	end
	table.sort(problems)
	return problems
end

-- props merged over the schema defaults; raises with every problem listed.
function Build.props(schema: Schema, props: any, component: string): { [string]: any }
	local problems = Build.validate(schema, props, component)
	if #problems > 0 then
		error(table.concat(problems, "; "), 3)
	end
	local out: { [string]: any } = {}
	for key, field in schema do
		if field.default ~= nil then
			out[key] = if type(field.default) == "table" then Check.copy(field.default) else field.default
		end
	end
	for key, value in props do
		out[key] = value
	end
	return out
end

-- Shared schema fields.
local TEXT: Schema = {
	textKey = { kind = "key" },
	text = { kind = "string", maxLength = 1024 },
	textArgs = { kind = "table" },
}
Build.TEXT = table.freeze(TEXT)

-- A schema made of the shared text fields plus extra.
function Build.schema(extra: Schema, withText: boolean?): Schema
	local out: Schema = {}
	if withText then
		for key, field in Build.TEXT do
			out[key] = field
		end
	end
	for key, field in extra do
		out[key] = field
	end
	out.name = out.name or { kind = "string", maxLength = 64 }
	out.layoutOrder = out.layoutOrder or { kind = "integer" }
	return out
end

-- The text of props: textKey through ctx.text (with textArgs), else text, else fallbackKey.
function Build.text(ctx: Context, props: { [string]: any }, fallbackKey: string?): string
	if props.textKey then
		return ctx.text(props.textKey, props.textArgs)
	elseif props.text then
		return props.text
	elseif fallbackKey then
		return ctx.text(fallbackKey, props.textArgs)
	end
	return ""
end

-- ------------------------------------------------------------------ components

export type Handle = {
	root: any,
	parts: { [string]: any },
	props: { [string]: any },
	state: { [string]: any },
	scope: any,
	ctx: Context,
	update: (self: Handle, patch: { [string]: any }) -> (),
	destroy: (self: Handle) -> (),
	destroyed: boolean,
}

export type Spec = {
	name: string,
	schema: Schema,
	build: (props: { [string]: any }, ctx: Context) -> (any, { [string]: any }),
	bind: ((handle: Handle, ctx: Context) -> ())?,
	update: ((handle: Handle, patch: { [string]: any }, ctx: Context) -> ())?,
	check: ((props: { [string]: any }) -> { string })?,
}

-- A component module from a spec. The module exposes name, schema, validate(props),
-- build(props, ctx) and mount(props, ctx, parent?); spec.check adds cross-field problems.
function Build.component(spec: Spec): { [string]: any }
	local module: { [string]: any } = { name = spec.name, schema = spec.schema }

	function module.validate(props: any): { string }
		local problems = Build.validate(spec.schema, props, spec.name)
		if #problems == 0 and spec.check then
			for _, problem in spec.check(props) do
				table.insert(problems, spec.name .. ": " .. problem)
			end
		end
		return problems
	end

	local function prepare(props: any): { [string]: any }
		local problems = module.validate(props)
		if #problems > 0 then
			error(table.concat(problems, "; "), 3)
		end
		return Build.props(spec.schema, props, spec.name)
	end

	local function construct(full: { [string]: any }, ctx: Context): (any, { [string]: any })
		local root, parts = spec.build(full, ctx)
		if full.name then
			root.Name = full.name
		end
		if full.layoutOrder then
			root.LayoutOrder = full.layoutOrder
		end
		root:SetAttribute("UIKitComponent", spec.name)
		Build.tag(root, "UIKit", spec.name)
		return root, parts
	end

	local attach: (any, { [string]: any }, { [string]: any }, Context) -> Handle
	attach = function(root: any, parts: { [string]: any }, full: { [string]: any }, ctx: Context): Handle
		local scope = ctx.scope:Extend()
		local child = Build.with(ctx, { scope = scope })
		local handle: any = {
			root = root,
			parts = parts or {},
			props = full,
			state = {},
			scope = scope,
			ctx = child,
			destroyed = false,
		}
		scope:Add(root)
		-- Runs before the Destroy above (LIFO): stop any motion on the tree first.
		scope:Add(function()
			ctx.runner:stop(root)
			for _, item in root:GetDescendants() do
				ctx.runner:stop(item)
			end
		end)
		function handle.update(self: any, patch: { [string]: any })
			if self.destroyed then
				error(spec.name .. ": update after destroy", 2)
			end
			local merged = table.clone(self.props)
			for key, value in patch do
				merged[key] = value
			end
			local problems = module.validate(merged)
			if #problems > 0 then
				error(table.concat(problems, "; "), 2)
			end
			self.props = Build.props(spec.schema, merged, spec.name)
			if spec.update then
				spec.update(self, patch, child)
			end
		end
		function handle.destroy(self: any)
			if self.destroyed then
				return
			end
			self.destroyed = true
			scope:Destroy()
		end
		if spec.bind then
			spec.bind(handle, child)
		end
		return handle
	end

	-- (root, parts): the pure tree. parts names the inner Instances (and, for composites, the
	-- child { root, parts, props } a later attach wires).
	function module.build(props: any, ctx: Context): (any, { [string]: any })
		local full = prepare(props)
		local root, parts = construct(full, ctx)
		return root, parts or {}
	end

	-- Wires behaviour onto a tree build() made (composites call it for their children inside
	-- their own bind, with the parent handle's ctx so one destroy cleans both).
	function module.attach(root: any, parts: { [string]: any }?, props: any, ctx: Context): Handle
		local full = prepare(props)
		return attach(root, parts or {}, full, ctx)
	end

	function module.mount(props: any, ctx: Context, parent: any?): Handle
		local full = prepare(props)
		local root, parts = construct(full, ctx)
		local handle = attach(root, parts or {}, full, ctx)
		if parent ~= nil then
			root.Parent = parent
		end
		return handle
	end

	return module
end

-- ------------------------------------------------------------------ behaviour helpers

-- Plays a plan on ctx.runner, reduced first under ctx.motion.reducedMotion (opacity tracks
-- become fades of at most tokens.motion.reducedFade s, everything else jumps to its end).
function Build.play(
	ctx: Context,
	plan: Transitions.Plan,
	bindings: { [string]: any },
	options: Transitions.PlayOptions?
): Transitions.Handle
	local chosen = plan
	if ctx.motion.reducedMotion and not plan.reduced then
		chosen = Transitions.reduce(plan, ctx.tokens.motion.reducedFade)
	end
	return ctx.runner:play(chosen, bindings, options)
end

-- Calls fn once after `seconds` on the runner's clock (PreRender in the game, runner:step in
-- specs), so timers and motion share one clock and pause together. Never reduced. Returns a
-- cancel function; ctx.scope cancels it on clean.
function Build.after(ctx: Context, seconds: number, fn: () -> ()): () -> ()
	assert(Check.finite(seconds) and seconds >= 0, "Build.after: seconds must be >= 0")
	local proxy = { Value = 0 }
	local plan: any = {
		kind = "transition",
		name = "after",
		phase = "in",
		duration = seconds,
		tracks = {
			{
				node = "clock",
				property = "Value",
				from = 0,
				to = 1,
				delay = 0,
				duration = seconds,
				ease = "Linear.In",
			},
		},
		reduced = false,
	}
	-- tracked: stop is in ctx.scope. Finishing or stopping untracks it, so a long-lived scope
	-- does not collect one entry per timer.
	local tracked = false
	local stop: () -> ()
	local function untrack()
		if tracked then
			tracked = false
			pcall(ctx.scope.Remove, ctx.scope, stop)
		end
	end
	local handle = ctx.runner:play(plan, { clock = proxy }, {
		onComplete = function(state: string)
			if state ~= "completed" then
				return
			end
			untrack()
			fn()
		end,
	})
	stop = function()
		handle:cancel()
		untrack()
	end
	if handle:state() == "playing" then
		tracked = true
		ctx.scope:Add(stop)
	end
	return stop
end

-- A ScreenGui on a token layer (DisplayOrder tokens.layer[layer]) with the defaults UIKit
-- expects: ScreenInsets CoreUISafeInsets (content stays inside the device safe area and below
-- the Roblox top bar), ResetOnSpawn off and sibling z-ordering. Full-bleed backgrounds
-- (scrims, letterbox, loading covers) pass fullscreen = true (ScreenInsets None).
function Build.screenGui(ctx: Context, name: string, layer: string, fullscreen: boolean?): any
	local order = ctx.tokens.layer[layer]
	if order == nil then
		error("Build.screenGui: unknown layer " .. tostring(layer), 2)
	end
	local enum = ctx.env.roblox.Enum
	return Build.make(ctx, "ScreenGui", {
		Name = name,
		DisplayOrder = order,
		ResetOnSpawn = false,
		ZIndexBehavior = enum.ZIndexBehavior.Sibling,
		ScreenInsets = if fullscreen then enum.ScreenInsets.None else enum.ScreenInsets.CoreUISafeInsets,
		AutoLocalize = false,
	})
end

-- Re-entrancy guard (lifted from Creator/UI): invoke(callback, ...) refuses while busy or
-- closed and counts failures; destroy() runs onDestroy once.
function Build.guard(onDestroy: (() -> ())?): any
	assert(onDestroy == nil or type(onDestroy) == "function", "Build.guard: cleanup must be a function")
	local api: any = { closed = false, busy = false, failures = 0 }
	function api.invoke(self: any, callback: (...any) -> ...any, ...: any): (boolean, string?)
		assert(type(callback) == "function", "Build.guard: callback required")
		if self.closed then
			return false, "closed"
		end
		if self.busy then
			return false, "busy"
		end
		self.busy = true
		local ok = pcall(callback, ...)
		self.busy = false
		if not ok then
			self.failures += 1
			return false, "callback_failed"
		end
		return not self.closed, if self.closed then "closed_during_callback" else nil
	end
	function api.destroy(self: any)
		if self.closed then
			return
		end
		self.closed = true
		if onDestroy then
			local ok = pcall(onDestroy)
			if not ok then
				self.failures += 1
			end
		end
	end
	return api
end

-- Interactable, Active, AutoButtonColor and Selectable together (disabled UI is
-- NonInteractable, so StyleSheet :NonInteractable rules apply).
function Build.setEnabled(instance: any, enabled: boolean)
	instance.Interactable = enabled
	instance.Active = enabled
	instance.Selectable = enabled
	if instance:IsA("GuiButton") then
		instance.AutoButtonColor = false
	end
end

-- Press and focus feedback plus a guarded activation callback for a GuiButton:
-- MouseButton1Down/Up drive the UIScale "Scale" and SelectionGained/Lost show the "FocusRing"
-- frame (both made by Build.feedback); Activated calls onActivated() through a guard, so a
-- callback can never re-enter itself. Under reduced motion the press scale is skipped.
function Build.pressable(handle: Handle, button: any, onActivated: (() -> ())?, ctx: Context)
	local guard = Build.guard()
	handle.scope:Add(function()
		guard:destroy()
	end)
	handle.state.guard = guard
	local scale = button:FindFirstChild("Scale")
	local ring = button:FindFirstChild("FocusRing")
	local snappy = ctx.tokens.motion.spring.snappy
	local settle = Ease.spring(snappy).settle(0, 1e-3)
	local function pressTo(value: number)
		if scale == nil or ctx.motion.reducedMotion then
			return
		end
		local plan = {
			kind = "transition",
			name = "press",
			phase = "in",
			duration = settle,
			tracks = {
				{
					node = "scale",
					property = "Scale",
					to = value,
					delay = 0,
					duration = settle,
					spring = snappy,
				},
			},
			reduced = false,
		}
		ctx.runner:play(plan :: any, { scale = scale })
	end
	handle.scope:Add(ctx.on(button, "MouseButton1Down", function()
		if button.Interactable then
			pressTo(0.96)
		end
	end))
	handle.scope:Add(ctx.on(button, "MouseButton1Up", function()
		pressTo(1)
	end))
	handle.scope:Add(ctx.on(button, "MouseLeave", function()
		pressTo(1)
	end))
	if ring then
		handle.scope:Add(ctx.on(button, "SelectionGained", function()
			ring.Visible = true
		end))
		handle.scope:Add(ctx.on(button, "SelectionLost", function()
			ring.Visible = false
		end))
	end
	handle.scope:Add(ctx.on(button, "Activated", function()
		if not button.Interactable or onActivated == nil then
			return
		end
		guard:invoke(onActivated)
	end))
end

type FadeOptions = { duration: number?, delay: number?, ease: string? }
export type FadeTree = {
	plan: (self: FadeTree, phase: string, options: FadeOptions?) -> (any, { [string]: any }),
	restore: (self: FadeTree) -> (),
	count: number,
}

-- A fade over every visible part of a tree without a CanvasGroup (full-screen CanvasGroups
-- cost texture memory and render blank past the client's cap): captures each GuiObject's
-- resting BackgroundTransparency (when < 1), TextTransparency and ImageTransparency and each
-- enabled UIStroke's Transparency now, then :plan("in" | "out") returns (plan, bindings) that
-- fade between fully transparent and those resting values. Capture once at mount, so an
-- interrupted fade never becomes the new resting state.
function Build.fadeTree(root: any): FadeTree
	local entries: { { target: any, property: string, rest: number } } = {}
	local list = { root }
	for _, item in root:GetDescendants() do
		table.insert(list, item)
	end
	for _, item in list do
		if item:IsA("GuiObject") then
			if item.BackgroundTransparency < 1 then
				table.insert(
					entries,
					{ target = item, property = "BackgroundTransparency", rest = item.BackgroundTransparency }
				)
			end
			if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
				table.insert(
					entries,
					{ target = item, property = "TextTransparency", rest = item.TextTransparency }
				)
			elseif item:IsA("ImageLabel") or item:IsA("ImageButton") then
				table.insert(
					entries,
					{ target = item, property = "ImageTransparency", rest = item.ImageTransparency }
				)
			end
		elseif item:IsA("UIStroke") and item.Enabled then
			table.insert(entries, { target = item, property = "Transparency", rest = item.Transparency })
		end
	end
	local tree: any = { count = #entries }
	-- Writes every captured resting value back (after a finished fade-out, before the tree is
	-- captured again, so the next capture sees resting values and not transparent ones).
	function tree.restore(_self: any)
		for _, entry in entries do
			entry.target[entry.property] = entry.rest
		end
	end
	function tree.plan(_self: any, phase: string, options: FadeOptions?): (any, { [string]: any })
		local o: FadeOptions = options or {}
		local duration = o.duration or 0.2
		local ease = o.ease or (if phase == "out" then "Quad.In" else "Quad.Out")
		local tracks, bindings = {}, {}
		for index, entry in entries do
			local node = "fade_" .. index
			bindings[node] = entry.target
			table.insert(tracks, {
				node = node,
				property = entry.property,
				from = if phase == "out" then entry.rest else 1,
				to = if phase == "out" then 1 else entry.rest,
				delay = o.delay or 0,
				duration = duration,
				ease = ease,
			})
		end
		local plan = {
			kind = "transition",
			name = "fadeTree",
			phase = phase,
			duration = if #tracks > 0 then (o.delay or 0) + duration else 0,
			tracks = tracks,
			reduced = false,
		}
		return plan, bindings
	end
	return tree
end

-- The press-feedback children a pressable button needs: UIScale "Scale" and a hidden
-- "FocusRing" frame (outset by the focus stroke, same corner radius) shown while selected.
-- An empty SelectionImageObject hides the engine's default highlight so only the ring shows.
-- scale = false leaves out the UIScale (controls that must not shrink while dragged).
function Build.feedback(ctx: Context, button: any, radius: (string | number)?, scale: boolean?)
	local r = ctx.env.roblox
	if scale ~= false then
		Build.make(ctx, "UIScale", { Name = "Scale", Scale = 1 }, button)
	end
	local outset = ctx.tokens.stroke.focus * 2
	local ring = Build.frame(ctx, "FocusRing", {
		AnchorPoint = r.Vector2.new(0.5, 0.5),
		Position = r.UDim2.fromScale(0.5, 0.5),
		Size = r.UDim2.new(1, outset, 1, outset),
		Visible = false,
		ZIndex = 2,
	}, button)
	Build.corner(ctx, ring, radius or "md")
	Build.stroke(ctx, ring, "focus", "focus")
	button.SelectionImageObject = Build.frame(ctx, "SelectionImage", { Size = r.UDim2.new() })
end

return Build
