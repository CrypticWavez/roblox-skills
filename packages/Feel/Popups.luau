--!strict
-- @tier T0
-- Popups: damage, heal and reward numbers as data. Events with the same key on the same anchor
-- inside `window` seconds merge into one number (a burst of ticks reads as one total); each
-- anchor stacks its popups upward without overlap; at most `maxActive` are visible (the oldest
-- go first). Under reduced motion popups do not rise or pop; they fade in place. Text is
-- formatted with K/M/B suffixes. A popup carries `kind` (a label the game styles: damage, heal,
-- crit, reward ...) so meaning is never colour alone. FeelRoblox draws them with pooled
-- BillboardGuis.
--   Popups.new(options?) -> popups;  popups:push(event, now) -> id;  popups:step(now) -> visible
--   Popups.format(value) -> text;  Popups.aggregate(events, window) -> merged events
local Popups = {}

-- Text prefixes by kind so gains read as gains without colour (convention).
Popups.PREFIX = table.freeze({ heal = "+", reward = "+", pickup = "+" })

Popups.DEFAULTS = table.freeze({
	window = 0.15, -- seconds to merge same-key hits (convention)
	maxActive = 12, -- convention
	lifetime = 0.9, -- seconds
	rise = 2.5, -- studs over the lifetime
	gap = 0.7, -- studs between stacked popups of one anchor
	pop = 0.12, -- seconds of the scale pop
	popScale = 1.35,
})

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- 999 -> "999", 1234 -> "1.2K", 15300 -> "15.3K", 2500000 -> "2.5M"; negatives keep the sign.
function Popups.format(value: number): string
	assert(finite(value), "Popups.format: value must be finite")
	local sign = if value < 0 then "-" else ""
	local magnitude = math.abs(value)
	local units = { { at = 1e9, suffix = "B" }, { at = 1e6, suffix = "M" }, { at = 1e3, suffix = "K" } }
	for _, unit in units do
		if magnitude >= unit.at then
			local scaled = math.floor(magnitude / unit.at * 10) / 10
			local text = if scaled >= 100 or scaled % 1 == 0
				then string.format("%d", math.floor(scaled))
				else string.format("%.1f", scaled)
			return sign .. text .. unit.suffix
		end
	end
	if magnitude % 1 == 0 then
		return sign .. string.format("%d", magnitude)
	end
	return sign .. string.format("%.1f", magnitude)
end

export type Event = { key: string, kind: string?, value: number, anchor: any?, at: number? }

-- Pure merge of events (sorted by `at`): same key and anchor within `window` of the first event
-- of a group sum their values.
function Popups.aggregate(events: { Event }, window: number): { Event }
	local sorted = table.clone(events)
	table.sort(sorted, function(a, b)
		return (a.at or 0) < (b.at or 0)
	end)
	local out: { Event } = {}
	local open: { [string]: Event } = {}
	for _, event in sorted do
		local groupKey = tostring(event.anchor) .. "|" .. event.key
		local group = open[groupKey]
		if group and (event.at or 0) - (group.at or 0) <= window then
			group.value += event.value
		else
			local copy = table.clone(event)
			open[groupKey] = copy
			table.insert(out, copy)
		end
	end
	return out
end

export type Visible = {
	id: number,
	key: string,
	kind: string,
	value: number,
	text: string,
	anchor: any,
	age: number,
	alpha: number, -- 1 opaque .. 0 gone
	offset: number, -- studs above the anchor
	scale: number,
	count: number, -- events merged into it
}

export type Options = {
	window: number?,
	maxActive: number?,
	lifetime: number?,
	rise: number?,
	gap: number?,
	reducedMotion: boolean?,
}

function Popups.new(options: Options?)
	local opts: any = options or {}
	local config: any = table.clone(Popups.DEFAULTS)
	for key, value in opts do
		if key ~= "reducedMotion" then
			assert(config[key] ~= nil, "Popups: unknown option " .. tostring(key))
			assert(finite(value) and value >= 0, "Popups: option " .. key .. " must be a number >= 0")
			config[key] = value
		end
	end
	assert(config.lifetime > 0, "Popups: lifetime must be > 0")
	assert(
		config.maxActive >= 1 and config.maxActive % 1 == 0,
		"Popups: maxActive must be a whole number >= 1"
	)
	local reducedMotion = opts.reducedMotion == true
	local active: { any } = {}
	local serial = 0
	local api = {}

	function api:setReducedMotion(enabled: boolean)
		reducedMotion = enabled
	end

	-- Adds an event; returns the id of the popup that shows it (an existing one when merged).
	function api:push(event: Event, now: number): number
		assert(type(event) == "table" and type(event.key) == "string", "Popups: event needs a key")
		assert(finite(event.value), "Popups: event value must be finite")
		assert(finite(now), "Popups: now must be finite")
		for _, popup in active do
			if
				popup.key == event.key
				and popup.anchor == event.anchor
				and now - popup.born <= config.window
				and now - popup.born < config.lifetime
			then
				popup.value += event.value
				popup.count += 1
				popup.bumped = now -- re-pop on merge
				return popup.id
			end
		end
		serial += 1
		table.insert(active, {
			id = serial,
			key = event.key,
			kind = event.kind or event.key,
			value = event.value,
			anchor = event.anchor,
			born = now,
			bumped = now,
			count = 1,
		})
		while #active > config.maxActive do
			table.remove(active, 1)
		end
		return serial
	end

	-- Visible popups at `now`, oldest first, with layout. Expired popups are removed.
	function api:step(now: number): { Visible }
		for index = #active, 1, -1 do
			if now - active[index].born >= config.lifetime then
				table.remove(active, index)
			end
		end
		local stackIndex: { [any]: number } = {}
		local perAnchor: { [any]: number } = {}
		for _, popup in active do
			local anchorKey = popup.anchor or "_"
			perAnchor[anchorKey] = (perAnchor[anchorKey] or 0) + 1
		end
		local out: { Visible } = {}
		for _, popup in active do
			local anchorKey = popup.anchor or "_"
			local seen = (stackIndex[anchorKey] or 0) + 1
			stackIndex[anchorKey] = seen
			-- newest on the bottom row, older ones pushed up one gap each
			local row = perAnchor[anchorKey] - seen
			local age = now - popup.born
			local progress = math.clamp(age / config.lifetime, 0, 1)
			local rise = if reducedMotion then 0 else config.rise * (1 - (1 - progress) ^ 2)
			local popAge = now - popup.bumped
			local scale = 1
			if not reducedMotion and popAge < config.pop then
				scale = config.popScale - (config.popScale - 1) * (popAge / config.pop)
			end
			local alpha = if progress < 0.7 then 1 else math.clamp(1 - (progress - 0.7) / 0.3, 0, 1)
			table.insert(out, {
				id = popup.id,
				key = popup.key,
				kind = popup.kind,
				value = popup.value,
				text = (Popups.PREFIX[popup.kind] or "") .. Popups.format(popup.value),
				anchor = popup.anchor,
				age = age,
				alpha = alpha,
				offset = row * config.gap + rise,
				scale = scale,
				count = popup.count,
			})
		end
		return out
	end

	function api:clear()
		table.clear(active)
	end

	return api
end

return Popups
