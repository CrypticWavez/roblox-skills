--!strict
-- @tier T1
-- DialogueBox: a speaker name, a line of text revealed by a typewriter and optional choices.
-- The reveal animates MaxVisibleGraphemes on the transition runner at cps characters per second
-- (45, convention); reduced motion shows the whole line at once. Advancing (a click on the box,
-- or handle.state.advance() from the ui.confirm IAS action) first completes a reveal, then calls
-- onContinue() when there are no choices. Choices (up to 6 { id, textKey | text }) appear as
-- Buttons once the line is shown; picking one calls onChoice(id) once. update({ textKey | text,
-- speaker..., choices }) shows the next line. Characters are counted with utf8.len, which matches
-- graphemes for most text; combined emoji count as several (UNVERIFIED against the engine's
-- grapheme rules, probe ui_gallery_audit). Tree:
--   DialogueBox (Frame) > Corner, Stroke, Size (UISizeConstraint), Hit (TextButton) > FocusRing,
--   Stack (Frame) > Padding, Layout, Speaker, Body, Next, Choices (Frame) > Layout, Choice_<id>
--   (Button)
local Build = require("../Build")
local Button = require("./Button")
local Check = require("../../GameKit/Check")
local Transitions = require("../Transitions")

local DEFAULT_CPS = 45 -- characters per second, convention
local MAX_CHOICES = 6

local function lineText(props: { [string]: any }, ctx: Build.Context): string
	return Build.text(ctx, props)
end

local function speakerText(props: { [string]: any }, ctx: Build.Context): string
	if props.speakerKey then
		return ctx.text(props.speakerKey)
	end
	return props.speaker or ""
end

-- Seconds a line of text takes to reveal at cps.
local function revealTime(text: string, cps: number): number
	local count = utf8.len(text) or #text
	return count / cps
end

local function buildChoices(container: any, props: { [string]: any }, ctx: Build.Context): { any }
	local out = {}
	for index, choice in props.choices or {} do
		local choiceProps = {
			textKey = choice.textKey,
			text = choice.text,
			variant = "secondary",
			fill = true,
			name = "Choice_" .. choice.id,
			layoutOrder = index,
		}
		local root, parts = Button.build(choiceProps, ctx)
		root.Parent = container
		table.insert(out, { id = choice.id, root = root, parts = parts, props = choiceProps })
	end
	return out
end

local DialogueBox = Build.component({
	name = "DialogueBox",
	schema = Build.schema({
		speakerKey = { kind = "key" },
		speaker = { kind = "string", maxLength = 64 },
		choices = { kind = "list", max = MAX_CHOICES },
		cps = { kind = "number", min = 5, max = 1000, default = DEFAULT_CPS },
		onContinue = { kind = "function" },
		onChoice = { kind = "function" },
		maxWidth = { kind = "number", min = 200, max = 2048 },
	}, true),
	check = function(props: any): { string }
		local problems = {}
		if props.textKey == nil and props.text == nil then
			table.insert(problems, "needs textKey or text")
		end
		local seen = {}
		for index, choice in props.choices or {} do
			if type(choice) ~= "table" or not Check.label(choice.id) then
				table.insert(problems, "choices[" .. index .. "].id must be a lower_snake label")
			elseif seen[choice.id] then
				table.insert(problems, "choices[" .. index .. "].id is repeated")
			elseif choice.textKey == nil and choice.text == nil then
				table.insert(problems, "choices[" .. index .. "] needs textKey or text")
			else
				seen[choice.id] = true
			end
		end
		return problems
	end,
	build = function(props: { [string]: any }, ctx: Build.Context): (any, { [string]: any })
		local r = ctx.env.roblox
		local margin = ctx.class.margin
		local root = Build.surface(ctx, "DialogueBox", "surfaceRaised", {
			AnchorPoint = r.Vector2.new(0.5, 1),
			Position = r.UDim2.new(0.5, 0, 1, -margin),
			Size = r.UDim2.new(1, -2 * margin, 0, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
		})
		Build.tag(root, "DialogueBox")
		Build.corner(ctx, root, "lg")
		Build.stroke(ctx, root, "border", "hairline")
		Build.make(ctx, "UISizeConstraint", {
			Name = "Size",
			MaxSize = r.Vector2.new(props.maxWidth or ctx.tokens.size.contentMax * 0.6, math.huge),
		}, root)
		-- Hit covers the whole box under the content (labels do not sink input, so a click
		-- anywhere but a choice advances); Stack holds the flowing content.
		local hit = Build.make(ctx, "TextButton", {
			Name = "Hit",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = r.UDim2.fromScale(1, 1),
			ZIndex = 1,
		}, root)
		Build.feedback(ctx, hit, "lg", false)
		local stack = Build.frame(ctx, "Stack", {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			ZIndex = 2,
		}, root)
		Build.padding(ctx, stack, "lg")
		Build.list(ctx, stack, "Vertical", { gap = "sm" })
		local wrap = { Size = r.UDim2.fromScale(1, 0), AutomaticSize = r.Enum.AutomaticSize.Y, ZIndex = 2 }
		local speaker =
			Build.label(ctx, "Speaker", "label", speakerText(props, ctx), "textMuted", wrap, stack)
		speaker.LayoutOrder = 1
		speaker.Visible = speaker.Text ~= ""
		local body = Build.label(ctx, "Body", "body", lineText(props, ctx), nil, wrap, stack)
		body.LayoutOrder = 2
		body.MaxVisibleGraphemes = -1
		local nextLabel = Build.label(ctx, "Next", "caption", ctx.text("uikit.continue"), "textMuted", {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			TextXAlignment = r.Enum.TextXAlignment.Right,
			LayoutOrder = 3,
			Visible = false,
			ZIndex = 2,
		}, stack)
		local choices = Build.frame(ctx, "Choices", {
			Size = r.UDim2.fromScale(1, 0),
			AutomaticSize = r.Enum.AutomaticSize.Y,
			LayoutOrder = 4,
			Visible = false,
			ZIndex = 3,
		}, stack)
		Build.list(ctx, choices, "Vertical", { gap = "xs" })
		local built = buildChoices(choices, props, ctx)
		return root,
			{
				speaker = speaker,
				body = body,
				hit = hit,
				nextLabel = nextLabel,
				choices = choices,
				choiceButtons = built,
			}
	end,
	bind = function(handle: Build.Handle, ctx: Build.Context)
		local parts = handle.parts
		local revealing: any = nil
		local answered = false
		local lineScope = handle.scope:Extend()
		handle.state.revealed = false

		local function attachChoices()
			for _, choice in parts.choiceButtons do
				local props = table.clone(choice.props)
				local id = choice.id
				props.onActivated = function()
					if answered then
						return
					end
					answered = true
					local fn = handle.props.onChoice
					if fn then
						fn(id)
					end
				end
				Button.attach(choice.root, choice.parts, props, Build.with(ctx, { scope = lineScope }))
			end
		end

		local function finished()
			revealing = nil
			handle.state.revealed = true
			parts.body.MaxVisibleGraphemes = -1
			local hasChoices = #parts.choiceButtons > 0
			parts.choices.Visible = hasChoices
			parts.nextLabel.Visible = not hasChoices
			if hasChoices then
				local tree = Build.fadeTree(parts.choices)
				local fade, bindings = tree:plan("in", { duration = ctx.tokens.motion.duration.base })
				Build.play(ctx, fade, bindings)
			end
		end

		local function reveal()
			answered = false
			handle.state.revealed = false
			parts.choices.Visible = false
			parts.nextLabel.Visible = false
			local text = parts.body.Text
			local count = utf8.len(text) or #text
			if ctx.motion.reducedMotion or count == 0 then
				finished()
				return
			end
			parts.body.MaxVisibleGraphemes = 0
			local plan = Transitions.make("typewriter", "in", {
				Transitions.track("body", "MaxVisibleGraphemes", 0, count, {
					duration = revealTime(text, handle.props.cps),
					ease = "Linear.In",
				}),
			})
			-- Not Build.play: the reveal is pacing, not motion; reduced motion skips it above.
			revealing = ctx.runner:play(plan, { body = parts.body }, {
				onComplete = function(state: string)
					if state == "completed" then
						finished()
					end
				end,
			})
		end

		function handle.state.advance(): string
			if revealing then
				revealing:finish()
				return "revealed"
			end
			if #parts.choiceButtons > 0 then
				return "waiting_for_choice"
			end
			local fn = handle.props.onContinue
			if fn then
				fn()
			end
			return "continued"
		end
		handle.state.reveal = reveal

		-- Replaces the line (and choices) and reveals it again.
		function handle.state.show(props: { [string]: any })
			if revealing then
				revealing:cancel()
				revealing = nil
			end
			lineScope:Clean()
			for _, choice in parts.choiceButtons do
				choice.root:Destroy()
			end
			parts.speaker.Text = speakerText(props, ctx)
			parts.speaker.Visible = parts.speaker.Text ~= ""
			parts.body.Text = lineText(props, ctx)
			parts.choiceButtons = buildChoices(parts.choices, props, ctx)
			attachChoices()
			reveal()
		end

		handle.scope:Add(ctx.on(parts.hit, "Activated", function()
			handle.state.advance()
		end))
		attachChoices()
		reveal()
	end,
	update = function(handle: Build.Handle, patch: { [string]: any }, _ctx: Build.Context)
		if
			patch.textKey ~= nil
			or patch.text ~= nil
			or patch.textArgs ~= nil
			or patch.choices ~= nil
			or patch.speakerKey ~= nil
			or patch.speaker ~= nil
		then
			handle.state.show(handle.props)
		end
	end,
})

DialogueBox.revealTime = revealTime
DialogueBox.DEFAULT_CPS = DEFAULT_CPS

return DialogueBox
