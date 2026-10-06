-- The G7 probe registry (fixtures/kits/server/level_probes.luau) run in Lune against fakes: the
-- PathfindingService is FakePathfinding (a scripted route around the priced-out zone and through
-- the wall gap, straight lines elsewhere), Workspace is a stand-in whose Raycast tests the Lune
-- parts' oriented boxes, RaycastParams is a plain table, and SceneKit Apply gets a pivotTo
-- (Lune instances have no PivotTo). Every probe must report ok here; that proves the probe logic
-- and the registry contract, not the engine (the probes stay pending until a Studio run).
local roblox = require("@lune/roblox")
local FakeEnv = require("./fakes/FakeEnv")
local FakePathfinding = require("./fakes/FakePathfinding")
local Probe = require("../packages/GameKit/Probe")
local registry = require("../fixtures/kits/server/level_probes")

local cases = {}
local function test(name, fn)
	table.insert(cases, { name = name, fn = fn })
end

local Vector3 = roblox.Vector3

-- Lune's roblox library plus RaycastParams (missing in Lune).
local R = setmetatable({
	RaycastParams = {
		new = function()
			return { FilterDescendantsInstances = {}, FilterType = nil }
		end,
	},
}, { __index = roblox })

local function route(from, to)
	if from.X == -50 then
		-- Around the avoid zone (x -40..-20, z -10..10) and through the wall gap (z 16..26).
		local points = {}
		for _, p in { { -50, 0 }, { -45, 18 }, { -10, 21 }, { 0, 21 }, { 10, 21 }, { 45, 5 }, { 50, 0 } } do
			table.insert(points, { pos = Vector3.new(p[1], 3, p[2]) })
		end
		return points
	end
	local points = {}
	for i = 0, 20 do
		table.insert(points, { pos = from + (to - from) * (i / 20) })
	end
	return points
end

-- Workspace stand-in: Gravity, the real Lune Workspace as `instance`, and Raycast against the
-- oriented boxes of the BaseParts under the include list (Roblox ignores parts containing the
-- origin, and so does this).
local function workspaceStandIn(instance)
	local ws = { instance = instance, Gravity = 196.2 }
	function ws.Raycast(_, origin, direction, params)
		local best = nil
		for _, root in params.FilterDescendantsInstances do
			for _, part in root:GetDescendants() do
				if not part:IsA("BasePart") then
					continue
				end
				local cf, half = part.CFrame, part.Size / 2
				local o, d = cf:PointToObjectSpace(origin), cf:VectorToObjectSpace(direction)
				local tmin, tmax = 0, 1
				local inside = math.abs(o.X) < half.X and math.abs(o.Y) < half.Y and math.abs(o.Z) < half.Z
				for _, axis in { "X", "Y", "Z" } do
					local oa, da, ha = (o :: any)[axis], (d :: any)[axis], (half :: any)[axis]
					if math.abs(da) < 1e-12 then
						if math.abs(oa) > ha then
							tmin, tmax = 1, 0
						end
					else
						local t1, t2 = (-ha - oa) / da, (ha - oa) / da
						tmin = math.max(tmin, math.min(t1, t2))
						tmax = math.min(tmax, math.max(t1, t2))
					end
				end
				if not inside and tmin <= tmax and (best == nil or tmin < best.t) then
					best = { t = tmin, Instance = part, Position = origin + direction * tmin }
				end
			end
		end
		if best then
			best.Distance = direction.Magnitude * best.t
		end
		return best
	end
	return ws
end

local function loader(path)
	local module = (require :: any)("../packages/" .. path)
	if path == "SceneKit/Apply" then
		-- Lune has no PivotTo: move a BasePart piece by its CFrame.
		local shim = setmetatable({}, { __index = module })
		shim.swap = function(root, kit, options)
			local o = table.clone(options)
			o.pivotTo = o.pivotTo or function(instance, cframe)
				instance.CFrame = cframe
			end
			return module.swap(root, kit, o)
		end
		return shim
	end
	return module
end

-- options.place replaces FakeEnv's diagnostic place; options.prepare(env) edits the fakes.
local function run(only, options)
	local opts = options or {}
	local game = roblox.Instance.new("DataModel")
	local starter = game:GetService("StarterPlayer")
	starter.CharacterUseJumpPower = false -- the default for new places (Lune's reflection says true)
	local env = FakeEnv.new({ roblox = R, place = opts.place })
	env:register("Workspace", workspaceStandIn(game:GetService("Workspace")))
	env:register("StarterPlayer", starter)
	env:register("PathfindingService", FakePathfinding.new({ roblox = roblox, route = route }))
	if opts.prepare then
		opts.prepare(env)
	end
	local lines = {}
	local summary = Probe.runAll(registry, {
		env = env,
		kit = loader,
		only = only,
		emit = function(line)
			table.insert(lines, line)
		end,
	})
	return summary, lines, game
end

test("every level probe is registered under an owner prefix", function(t)
	local names = {}
	for name in registry do
		table.insert(names, name)
		t.ok(Probe.validName(name) and string.sub(name, 1, 4) == "lvl_", name)
	end
	table.sort(names)
	t.eq(names, { "lvl_course_run", "lvl_kit_swap", "lvl_navagent_door", "lvl_pathfinding_probe" })
end)

for _, name in { "lvl_pathfinding_probe", "lvl_navagent_door", "lvl_kit_swap", "lvl_course_run" } do
	test(name .. " holds against fakes and cleans up", function(t)
		local summary, lines, game = run({ name })
		local failed = {}
		for _, line in lines do
			if string.find(line, '"ok":false', 1, true) then
				table.insert(failed, line)
			end
		end
		t.eq(failed, {}, name)
		t.ok(summary.ok and summary.checks >= 3, name .. " checks")
		t.ok(string.find(lines[#lines], "ENGINE_DONE ", 1, true) == 1)
		t.eq(game:GetService("Workspace"):FindFirstChild("SETUP_ONLY_LevelProbe"), nil, "staging removed")
	end)
end

local function errorLines(lines)
	local out = {}
	for _, line in lines do
		if string.find(line, '"check":"error"', 1, true) then
			table.insert(out, line)
		end
	end
	return out
end

test("every level probe refuses a published place before it builds anything", function(t)
	local published = { isStudio = true, gameId = 4242, placeId = 99 }
	local summary, lines, game = run(nil, { place = published })
	t.eq(summary.ok, false)
	t.eq(summary.errors, 4, table.concat(lines, "\n"))
	t.eq(summary.passed, 0, "no check ran on a published place")
	local errors = errorLines(lines)
	t.eq(#errors, 4)
	for _, line in errors do
		t.ok(string.find(line, "diagnostic places only", 1, true) ~= nil, line)
	end
	t.eq(#game:GetService("Workspace"):GetChildren(), 0, "nothing staged")
	-- a live (non-Studio) place is refused the same way
	local live = run({ "lvl_kit_swap" }, { place = { isStudio = false, gameId = 0, placeId = 0 } })
	t.eq({ live.errors, live.passed }, { 1, 0 })
end)

test("a level probe that raises still removes its staging", function(t)
	local summary, lines, game = run({ "lvl_pathfinding_probe", "lvl_course_run" }, {
		prepare = function(env)
			env:register("PathfindingService", {
				CreatePath = function()
					error("pathfinding exploded")
				end,
			})
			env.services.Workspace.Raycast = function()
				error("raycast exploded")
			end
		end,
	})
	t.eq(summary.errors, 2, table.concat(lines, "\n"))
	local errors = table.concat(errorLines(lines), "\n")
	t.ok(string.find(errors, "pathfinding exploded", 1, true) ~= nil, errors)
	t.ok(string.find(errors, "raycast exploded", 1, true) ~= nil, errors)
	t.eq(game:GetService("Workspace"):FindFirstChild("SETUP_ONLY_LevelProbe"), nil, "staging removed")
end)

test("a mismatched engine fails lvl_course_run's physics checks", function(t)
	local game = roblox.Instance.new("DataModel")
	local starter = game:GetService("StarterPlayer")
	starter.CharacterUseJumpPower = true -- JumpPower 50 -> 6.37 studs, not Measure's 7.2
	local env = FakeEnv.new({ roblox = R })
	env:register("Workspace", workspaceStandIn(game:GetService("Workspace")))
	env:register("StarterPlayer", starter)
	local lines = {}
	local summary = Probe.runAll(registry, {
		env = env,
		kit = loader,
		only = { "lvl_course_run" },
		emit = function(line)
			table.insert(lines, line)
		end,
	})
	t.eq(summary.ok, false)
	local jump = nil
	for _, line in lines do
		if string.find(line, '"check":"jump_height_matches"', 1, true) then
			jump = line
		end
	end
	t.ok(jump and string.find(jump, '"ok":false', 1, true), jump)
end)

return cases
