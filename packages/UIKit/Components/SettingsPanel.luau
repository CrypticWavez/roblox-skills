--!strict
-- @tier T1
-- SettingsPanel: the player settings screen generated from the settings/1 schema (Stage 0
-- GameKit/Settings, including a game's own game.* fields). One section per group (audio,
-- display, accessibility, controls, language, game) and one row per field: booleans are
-- Toggles, numbers Sliders (percent for 0-1 ranges), enums and the language a choice button
-- that cycles (DPadLeft/Right or Left/Right step it while selected). Labels are the fields'
-- labelKey (settings.<path>) and choices settings.choice.<value>; locale ids without a key show
-- as the id. Every change goes through Settings.set, so values stay valid, and calls
-- onChange(values, path, notes). The panel never saves: persistence is the game's (GameKit
-- SettingsStore, G1). update({ values }) refreshes every row without callbacks. Tree:
--   SettingsPanel (ScrollingFrame) > Padding, Layout, Section_<group> (Frame) > Layout, Heading,
--   Row_<path> (Toggle | Slider | Frame > Label, Choice (Button))
local Build = require("../Build")
local Button = require("./Button")
local Settings = require("../../GameKit/Settings")
local Slider = require("./Slider")
local Toggle = require("./Toggle")

local function rowName(path: string): string
	return "Row_" .. string.gsub(path, "%.", "_")
end

local function choicesOf(field: any, locales: { string }): { string }
	if field.kind == "locale" then
		return locales
	end
	return field.choices
end

local function choiceText(field: any, value: string, ctx: Build.Context): string
	local key = "settings.choice." .. value
	local text = ctx.text(key)
	if text == "[" .. key .. "]" then
		return if field.kind == "locale" then value else text
	end
	return text
end

local function sliderFormat(field: any): string
	return if field.min == 0 and field.max == 1 then "percent" else "number"
end

local SettingsPanel = Build.component({
	name = "SettingsPanel",
	schema = Build.schema({
		values = { kind = "table", required = true },
		fields = { kind = "list" },
		groups = { kind = "list" },
		locales = { kind = "list", default = { "auto", "en-us" } },
		onChange = { kind = "function" },
	}),
	check = function(props: any): { string }
		local problems = {}
		local fields = props.fields or Settings.FIELDS
		for _, problem in Settings.validate(props.values, fields) do
			table.insert(problems, "values: " .. problem)
		end
		for _, group in props.groups or {} do
			if not table.find(Settings.GROUPS, group) then
				table.insert(problems, "groups: unknown group " .. tostring(group))
			end
		end
		for _, locale in props.locales or {} do
			if
				type(locale) ~= "string"
				or not (locale == "auto" or string.match(locale, "^[a-z][a-z][a-z]?"))
			then
				table.insert(problems, "locales: " .. tostring(locale) .. " is not a locale id")
			end
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local fields = props.fields or Settings.FIELDS
		local root = Build.make(ctx, "ScrollingFrame", {
			Name = "SettingsPanel",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = r.UDim2.fromScale(1, 1),
			CanvasSize = r.UDim2.new(),
			AutomaticCanvasSize = r.Enum.AutomaticSize.Y,
			ScrollingDirection = r.Enum.ScrollingDirection.Y,
			ScrollBarThickness = 6,
			Selectable = false,
		})
		Build.tag(root, "SettingsPanel")
		Build.padding(ctx, root, { "md", "lg" })
		Build.list(ctx, root, "Vertical", { gap = "xl" })
		local rows: { [string]: any } = {}
		local order = 0
		for groupIndex, group in props.groups or Settings.GROUPS do
			local section: any = nil
			for _, field in fields do
				if field.group ~= group then
					continue
				end
				if section == nil then
					section = Build.frame(ctx, "Section_" .. group, {
						Size = r.UDim2.fromScale(1, 0),
						AutomaticSize = r.Enum.AutomaticSize.Y,
						LayoutOrder = groupIndex,
					}, root)
					Build.list(ctx, section, "Vertical", { gap = "sm" })
					Build.label(ctx, "Heading", "heading", ctx.text("settings.group." .. group), nil, {
						Size = r.UDim2.fromScale(1, 0),
						AutomaticSize = r.Enum.AutomaticSize.Y,
						LayoutOrder = 0,
					}, section)
				end
				order += 1
				local value = Settings.get(props.values, field.path)
				local name = rowName(field.path)
				if field.kind == "boolean" then
					local p = { textKey = field.labelKey, value = value, name = name, layoutOrder = order }
					local root_, parts = Toggle.build(p, ctx)
					root_.Parent = section
					rows[field.path] =
						{ kind = "toggle", field = field, root = root_, parts = parts, props = p }
				elseif field.kind == "number" then
					local p = {
						textKey = field.labelKey,
						min = field.min,
						max = field.max,
						step = field.step or 0,
						value = value,
						format = sliderFormat(field),
						name = name,
						layoutOrder = order,
					}
					local root_, parts = Slider.build(p, ctx)
					root_.Parent = section
					rows[field.path] =
						{ kind = "slider", field = field, root = root_, parts = parts, props = p }
				else
					local row = Build.frame(ctx, name, {
						Size = r.UDim2.new(
							1,
							0,
							0,
							if ctx.class.touch then ctx.tokens.size.touchMin else ctx.tokens.size.control
						),
						LayoutOrder = order,
					}, section)
					Build.label(ctx, "Label", "body", ctx.text(field.labelKey), nil, {
						Size = r.UDim2.new(0.5, 0, 1, 0),
						TextWrapped = false,
						TextTruncate = r.Enum.TextTruncate.AtEnd,
					}, row)
					local p = {
						text = choiceText(field, value, ctx),
						variant = "secondary",
						size = "sm",
						name = "Choice",
						width = 180,
					}
					local button, parts = Button.build(p, ctx)
					button.AnchorPoint = r.Vector2.new(1, 0.5)
					button.Position = r.UDim2.fromScale(1, 0.5)
					button.Parent = row
					rows[field.path] =
						{ kind = "choice", field = field, root = button, parts = parts, props = p, row = row }
				end
			end
		end
		return root, { rows = rows }
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local fields = handle.props.fields or Settings.FIELDS
		handle.state.values = handle.props.values
		handle.state.handles = {}

		local function commit(path: string, value: any)
			local values, notes = Settings.set(handle.state.values, path, value, fields)
			handle.state.values = values
			local fn = handle.props.onChange
			if fn then
				fn(values, path, notes)
			end
		end

		for path, row in handle.parts.rows do
			local props = table.clone(row.props)
			if row.kind == "toggle" then
				props.onChanged = function(value: boolean)
					commit(path, value)
				end
				handle.state.handles[path] = Toggle.attach(row.root, row.parts, props, ctx)
			elseif row.kind == "slider" then
				props.onChanged = function(value: number)
					commit(path, value)
				end
				handle.state.handles[path] = Slider.attach(row.root, row.parts, props, ctx)
			else
				local field = row.field
				local function cycle(delta: number)
					local list = choicesOf(field, handle.props.locales)
					local current = Settings.get(handle.state.values, path)
					local at = table.find(list, current) or 1
					local nextValue = list[((at - 1 + delta) % #list) + 1]
					commit(path, nextValue)
					local button = handle.state.handles[path]
					button:update({ text = choiceText(field, Settings.get(handle.state.values, path), ctx) })
				end
				props.onActivated = function()
					cycle(1)
				end
				local button = Button.attach(row.root, row.parts, props, ctx)
				handle.state.handles[path] = button
				button.scope:Add(ctx.on(row.root, "InputBegan", function(input: any)
					local key = input.KeyCode and input.KeyCode.Name
					if key == "DPadLeft" or key == "Left" then
						cycle(-1)
					elseif key == "DPadRight" or key == "Right" then
						cycle(1)
					end
				end))
			end
		end

		-- Shows values in every row without calling onChange.
		function handle.state.refresh(values: any)
			handle.state.values = values
			for path, row in handle.parts.rows do
				local value = Settings.get(values, path)
				local child = handle.state.handles[path]
				if row.kind == "choice" then
					child:update({ text = choiceText(row.field, value, ctx) })
				else
					child:update({ value = value })
				end
			end
		end
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, _ctx: Build.Context)
		if patch.fields ~= nil or patch.groups ~= nil or patch.locales ~= nil then
			error("SettingsPanel: fields, groups and locales cannot change after mount", 3)
		end
		if patch.values ~= nil then
			handle.state.refresh(patch.values)
		end
	end,
})

SettingsPanel.rowName = rowName

return SettingsPanel
