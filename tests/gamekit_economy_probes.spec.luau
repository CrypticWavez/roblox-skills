--!strict
-- The G3 probe registry (fixtures/kits/server/economy_probes.luau) runs in Lune against FakeEnv
-- and tests/fakes/FakeEconomyEngine: every probe loads, its checks pass against the fakes, the
-- line protocol holds, the two-client probe fails closed without two players, every probe
-- refuses a place that is not diagnostic before it builds anything, a probe that raises still
-- removes what it built, and the world is staged at y = 800. This proves wiring only; the probes
-- stay pending until a Studio run on the diagnostic place prints lines.
local Probe = require("../packages/GameKit/Probe")
local FakeEconomyEngine = require("./fakes/FakeEconomyEngine")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- Kits are required up front: Lune's require can yield, and a probe thread parked inside it
-- would be resumed by Lune's scheduler instead of FakeEnv.
local KITS: { [string]: any } = {
	["GameKit/Env"] = require("../packages/GameKit/Env"),
	["GameKit/Followers"] = require("../packages/GameKit/Followers"),
	["GameKit/FollowersRoblox"] = require("../packages/GameKit/FollowersRoblox"),
	["GameKit/Outfits"] = require("../packages/GameKit/Outfits"),
	["GameKit/OutfitsRoblox"] = require("../packages/GameKit/OutfitsRoblox"),
	["GameKit/Plots"] = require("../packages/GameKit/Plots"),
	["GameKit/ItemDefs"] = require("../packages/GameKit/ItemDefs"),
	["GameKit/Inventory"] = require("../packages/GameKit/Inventory"),
	["GameKit/Wallet"] = require("../packages/GameKit/Wallet"),
	["GameKit/Trade"] = require("../packages/GameKit/Trade"),
}
local REGISTRY = require("../fixtures/kits/server/economy_probes")

local function kitLoader(path: string): any
	return KITS[path] or error("economy probes spec: preload kit " .. path, 2)
end

local PROBES = {
	"economy_followers_formation",
	"economy_outfits_apply",
	"economy_plots_claim_race",
	"economy_trade_two_client",
}

-- options.place replaces FakeEnv's diagnostic place; options.kits replaces kit modules by path.
type RunOptions = { place: any?, kits: { [string]: any }? }

local function runRegistry(
	players: { any },
	only: { string }?,
	options: RunOptions?
): (any, { string }, any, any)
	local registry = REGISTRY
	local opts: RunOptions = options or {}
	local engine = FakeEconomyEngine.new()
	engine.players = players
	local env = FakeEconomyEngine.env(engine, { seed = "economy-probes", place = opts.place })
	local lines = {}
	local summary = nil
	local overrides = opts.kits or {}
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = function(path: string): any
				return overrides[path] or kitLoader(path)
			end,
			only = only,
			emit = function(line: string)
				table.insert(lines, line)
			end,
		})
	end)
	for _ = 1, 40 do
		if summary ~= nil then
			break
		end
		FakeEconomyEngine.run(engine, env, 0.5)
	end
	return summary, lines, env, engine
end

local TWO_PLAYERS = { { UserId = 1, Name = "Player1" }, { UserId = 2, Name = "Player2" } }

local function errorLines(lines: { string }): { string }
	local out = {}
	for _, line in lines do
		if string.find(line, '"check":"error"', 1, true) then
			table.insert(out, line)
		end
	end
	return out
end

test("the registry holds the four economy probes and nothing else", function(t)
	local registry = REGISTRY
	local names = {}
	for name in registry do
		t.ok(Probe.validName(name) and string.sub(name, 1, 8) == "economy_", name)
		table.insert(names, name)
	end
	table.sort(names)
	t.eq(names, PROBES)
end)

test("every probe passes against the fakes with two players", function(t)
	local summary, lines, env = runRegistry(TWO_PLAYERS)
	t.ok(summary ~= nil, "the run finished")
	local failed = {}
	for _, line in lines do
		if string.sub(line, 1, #Probe.CHECK_PREFIX) == Probe.CHECK_PREFIX then
			if string.find(line, '"ok":false', 1, true) then
				table.insert(failed, line)
			end
		end
	end
	t.eq(failed, {})
	t.eq(env.errors, {})
	t.eq(summary.probes, PROBES)
	t.eq(summary.failed, 0)
	t.eq(summary.errors, 0)
	t.ok(summary.ok and summary.checks >= 15, "checks: " .. tostring(summary.checks))
	t.eq(string.sub(lines[#lines], 1, #Probe.DONE_PREFIX), Probe.DONE_PREFIX)
end)

test("every economy probe refuses a published place before it builds anything", function(t)
	local published = { isStudio = true, gameId = 4242, placeId = 99 }
	local summary, lines, _, engine = runRegistry(TWO_PLAYERS, nil, { place = published })
	t.ok(summary ~= nil, "the run finished")
	t.eq(summary.ok, false)
	t.eq(summary.errors, 4, table.concat(lines, "\n"))
	t.eq(summary.passed, 0, "no check ran on a published place")
	local errors = errorLines(lines)
	t.eq(#errors, 4)
	for _, line in errors do
		t.ok(string.find(line, "diagnostic places only", 1, true) ~= nil, line)
	end
	t.eq(#engine.services.Workspace:GetChildren(), 0, "nothing staged")
	t.eq(#engine.created, 1, "no instance made besides the fake Workspace")
	-- a live (non-Studio) place is refused the same way
	local live = runRegistry(TWO_PLAYERS, { "economy_plots_claim_race" }, {
		place = { isStudio = false, gameId = 0, placeId = 0 },
	})
	t.eq({ live.errors, live.passed }, { 1, 0 })
end)

test("an economy probe that raises still stops its followers and removes its staging", function(t)
	local FollowersRoblox = KITS["GameKit/FollowersRoblox"]
	local OutfitsRoblox = KITS["GameKit/OutfitsRoblox"]
	local stopped = 0
	local summary, lines, _, engine = runRegistry(
		TWO_PLAYERS,
		{ "economy_followers_formation", "economy_outfits_apply" },
		{
			kits = {
				["GameKit/FollowersRoblox"] = {
					attach = FollowersRoblox.attach,
					start = function(...: any): () -> ()
						local stop = FollowersRoblox.start(...)
						return function()
							stopped += 1
							stop()
						end
					end,
					leaderFrom = function(): any
						error("followers exploded")
					end,
				},
				["GameKit/OutfitsRoblox"] = {
					toInstance = OutfitsRoblox.toInstance,
					apply = function(): any
						error("outfits exploded")
					end,
				},
			},
		}
	)
	t.ok(summary ~= nil, "the run finished")
	t.eq(summary.errors, 2, table.concat(lines, "\n"))
	local errors = table.concat(errorLines(lines), "\n")
	t.ok(string.find(errors, "followers exploded", 1, true) ~= nil, errors)
	t.ok(string.find(errors, "outfits exploded", 1, true) ~= nil, errors)
	t.eq(stopped, 1, "the simulation binding was stopped")
	t.eq(#engine.services.Workspace:GetChildren(), 0, "staging removed")
end)

test("the followers and the outfit rig are staged far above the place's content", function(t)
	local staged = {}
	local FollowersRoblox = KITS["GameKit/FollowersRoblox"]
	local summary, lines, _, engine = runRegistry(
		TWO_PLAYERS,
		{ "economy_followers_formation", "economy_outfits_apply" },
		{
			kits = {
				["GameKit/FollowersRoblox"] = {
					attach = function(part: any, options: any, env: any): any
						table.insert(staged, part.Position.Y)
						return FollowersRoblox.attach(part, options, env)
					end,
					start = FollowersRoblox.start,
					leaderFrom = FollowersRoblox.leaderFrom,
				},
			},
		}
	)
	t.ok(summary ~= nil and summary.ok, table.concat(lines, "\n"))
	t.eq(staged, { 800, 800, 800 })
	local rigs = 0
	for _, instance in engine.created do
		if instance.ClassName == "Model" then
			rigs += 1
			t.eq(instance.CFrame.Position.Y, 800, "the rig is pivoted up")
			t.eq(instance.PrimaryPart.Anchored, true, "the rig does not fall")
		end
	end
	t.eq(rigs, 1)
end)

test("the two-client probe fails closed without two players", function(t)
	local summary, lines = runRegistry({ { UserId = 1, Name = "Player1" } }, { "economy_trade_two_client" })
	t.eq(summary.ok, false)
	t.eq(summary.failed, 1)
	t.ok(string.find(lines[1], '"check":"two_players"', 1, true) ~= nil, lines[1])
	t.ok(string.find(lines[1], "Server and Clients", 1, true) ~= nil)
end)

return cases
