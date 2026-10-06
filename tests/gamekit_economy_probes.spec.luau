--!strict
-- The G3 probe registry (fixtures/kits/server/economy_probes.luau) runs in Lune against FakeEnv
-- and tests/fakes/FakeEconomyEngine: every probe loads, its checks pass against the fakes, the
-- line protocol holds, and the two-client probe fails closed without two players. This proves
-- wiring only; the probes stay pending until a Studio run on the diagnostic place prints lines.
local Probe = require("../packages/GameKit/Probe")
local FakeEconomyEngine = require("./fakes/FakeEconomyEngine")

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- Kits are required up front: Lune's require can yield, and a probe thread parked inside it
-- would be resumed by Lune's scheduler instead of FakeEnv.
local KITS: { [string]: any } = {
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

local function runRegistry(players: { any }, only: { string }?): (any, { string }, any)
	local registry = REGISTRY
	local engine = FakeEconomyEngine.new()
	engine.players = players
	local env = FakeEconomyEngine.env(engine, { seed = "economy-probes" })
	local lines = {}
	local summary = nil
	env.spawn(function()
		summary = Probe.runAll(registry, {
			env = env,
			kit = kitLoader,
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
	return summary, lines, env
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
	local summary, lines, env =
		runRegistry({ { UserId = 1, Name = "Player1" }, { UserId = 2, Name = "Player2" } })
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

test("the two-client probe fails closed without two players", function(t)
	local summary, lines = runRegistry({ { UserId = 1, Name = "Player1" } }, { "economy_trade_two_client" })
	t.eq(summary.ok, false)
	t.eq(summary.failed, 1)
	t.ok(string.find(lines[1], '"check":"two_players"', 1, true) ~= nil, lines[1])
	t.ok(string.find(lines[1], "Server and Clients", 1, true) ~= nil)
end)

return cases
