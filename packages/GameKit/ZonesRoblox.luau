--!strict
-- @tier T3
-- probe: action_zones_enter_exit
-- ZonesRoblox: part-defined zones and a server step that feeds player positions to a tracker.
--   * defFromPart(part) reads a BasePart (CFrame, Size, Shape) and its attributes into a Zones
--     definition: ZoneId (default: the part name), ZoneKind (area, hazard, kill, gate),
--     ZoneHysteresis, ZonePriority, HazardAmount, HazardInterval, HazardKind,
--     HazardImmediate, GateOrder, GateFinish, GateMinTime, GateDirectional (the gate faces the
--     part's LookVector). Ball parts become spheres; blocks become AABBs, or prisms when turned
--     about Y; any other tilt is refused with a reason.
--   * fromParts(parts) collects definitions and problems; feed the definitions to Zones.define.
--   * start(tracker, { players, runService, course?, onEvents? }, env) binds a non-yielding step
--     (AuthorityRoblox.bindStep) that reads each character's HumanoidRootPart CFrame and calls
--     tracker:step; gate events also go to the course. Returns stop().
-- defFromPart runs in Lune with @lune/roblox parts; start needs Studio (the probe).
local AuthorityRoblox = require("./AuthorityRoblox")
local Vec = require("../SceneKit/Vec")

local ZonesRoblox = {}
ZonesRoblox.TILT_TOLERANCE = 1e-4

local function v3(value: any): Vec.V3
	return Vec.new(value.X, value.Y, value.Z)
end

local function label(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local lowered = string.lower(name)
	if string.match(lowered, "^[a-z][a-z0-9_]*$") and #lowered <= 64 then
		return lowered
	end
	return nil
end

-- A Zones definition from a part, or (nil, problems).
function ZonesRoblox.defFromPart(part: any): (any?, { string })
	local problems = {}
	local name = tostring(part.Name)
	local id = label(part:GetAttribute("ZoneId") or name)
	if id == nil then
		table.insert(problems, string.format("%s: ZoneId (or the part name) must be a label", name))
	end
	local cframe = part.CFrame
	local size = v3(part.Size)
	local center = v3(cframe.Position)
	local shape
	local ok, partShape = pcall(function()
		return part.Shape
	end)
	if ok and partShape ~= nil and partShape.Name == "Ball" then
		shape = { kind = "sphere", center = center, radius = math.min(size.x, size.y, size.z) / 2 }
	else
		local up = v3(cframe.UpVector)
		if math.abs(up.y - 1) > ZonesRoblox.TILT_TOLERANCE then
			table.insert(problems, string.format("%s: zone parts may only turn about the Y axis", name))
			return nil, problems
		end
		local right = v3(cframe.RightVector)
		local back = Vec.scale(v3(cframe.LookVector), -1)
		local h = Vec.scale(size, 0.5)
		if
			math.abs(math.abs(right.x) - 1) <= ZonesRoblox.TILT_TOLERANCE
			or math.abs(right.x) <= ZonesRoblox.TILT_TOLERANCE
		then
			-- Axis-aligned (0, 90, 180 or 270 degrees): an AABB with the extents swapped as needed.
			local hx = if math.abs(right.x) > 0.5 then h.x else h.z
			local hz = if math.abs(right.x) > 0.5 then h.z else h.x
			shape = {
				kind = "aabb",
				min = Vec.new(center.x - hx, center.y - h.y, center.z - hz),
				max = Vec.new(center.x + hx, center.y + h.y, center.z + hz),
			}
		else
			local points = {}
			for _, corner in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
				local p = Vec.add(
					center,
					Vec.add(Vec.scale(right, corner[1] * h.x), Vec.scale(back, corner[2] * h.z))
				)
				table.insert(points, { x = p.x, z = p.z })
			end
			shape = { kind = "prism", points = points, minY = center.y - h.y, maxY = center.y + h.y }
		end
	end
	local kind = part:GetAttribute("ZoneKind") or "area"
	local def: { [string]: any } = {
		id = id,
		shape = shape,
		kind = kind,
		hysteresis = part:GetAttribute("ZoneHysteresis"),
		priority = part:GetAttribute("ZonePriority"),
	}
	if kind == "hazard" then
		def.hazard = {
			amount = part:GetAttribute("HazardAmount"),
			interval = part:GetAttribute("HazardInterval"),
			damageKind = part:GetAttribute("HazardKind"),
			immediate = part:GetAttribute("HazardImmediate"),
		}
	elseif kind == "gate" then
		def.gate = {
			order = part:GetAttribute("GateOrder"),
			finish = part:GetAttribute("GateFinish"),
			minTime = part:GetAttribute("GateMinTime"),
			direction = if part:GetAttribute("GateDirectional") == true then v3(cframe.LookVector) else nil,
		}
	end
	if #problems > 0 then
		return nil, problems
	end
	return def, problems
end

-- Definitions for parts in name order, and every problem found.
function ZonesRoblox.fromParts(parts: { any }): ({ any }, { string })
	local sorted = table.clone(parts)
	table.sort(sorted, function(a: any, b: any): boolean
		return tostring(a.Name) < tostring(b.Name)
	end)
	local defs, problems = {}, {}
	for _, part in sorted do
		local def, partProblems = ZonesRoblox.defFromPart(part)
		if def then
			table.insert(defs, def)
		end
		for _, problem in partProblems do
			table.insert(problems, problem)
		end
	end
	return defs, problems
end

-- Root positions of players with a character: { [UserId] = V3 }.
function ZonesRoblox.positions(players: any): { [number]: Vec.V3 }
	local out = {}
	for _, player in players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			out[player.UserId] = v3(root.CFrame.Position)
		end
	end
	return out
end

export type Options = {
	players: any,
	runService: any,
	course: any?,
	onEvents: ((events: { any }, courseEvents: { any }) -> ())?,
	allowFallback: boolean?,
}

-- Steps the tracker from player positions each simulation step. Returns (stop, how).
function ZonesRoblox.start(tracker: any, options: Options, _env: any): (() -> (), string)
	local removing = options.players.PlayerRemoving:Connect(function(player: any)
		tracker:remove(player.UserId)
	end)
	local unbind, how = AuthorityRoblox.bindStep(options.runService, function()
		local events = tracker:step(ZonesRoblox.positions(options.players))
		local courseEvents = if options.course then options.course:observe(events) else {}
		if options.onEvents and (#events > 0 or #courseEvents > 0) then
			options.onEvents(events, courseEvents)
		end
	end, { allowFallback = options.allowFallback })
	if unbind == nil then
		removing:Disconnect()
		error("ZonesRoblox.start: " .. how, 2)
	end
	local release = unbind :: () -> ()
	return function()
		release()
		removing:Disconnect()
	end, how
end

return ZonesRoblox
