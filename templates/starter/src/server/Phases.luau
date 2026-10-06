--!strict
-- @tier T3
-- Server boot phases (Boot.SIDES.server): config, kits, data, remotes, telemetry. Each phase is a
-- hook with no game content. Wire kit modules here as the game adopts them (names from the factory's
-- docs/runtime-kits.md: GameKit/PlayerData for data, GameKit/RemoteGuard for remotes, GameKit/Telemetry
-- for telemetry). Until then a phase whose Config switch is TBD reports what it skipped, and a switch
-- set to true without wiring fails the boot on purpose. Services come in through `deps`, so the phases
-- can run against fakes; the real run is release item S07 (BOOT_REPORT lines in Play Solo).
local Phases = {}

export type Deps = {
	config: any, -- src/shared/Config
	kitLoader: any, -- src/shared/KitLoader
	kitsRoot: any, -- ReplicatedStorage.Kits (nil when no kit is installed)
	loader: (any) -> any, -- require
	replicatedStorage: any,
	newFolder: (name: string, parent: any) -> any,
}

function Phases.server(deps: Deps): { [string]: (ctx: { [string]: any }) -> any }
	local Config = deps.config
	return {
		config = function(ctx)
			local problems = Config.validate()
			if #problems > 0 then
				error("config: " .. table.concat(problems, "; "), 0)
			end
			ctx.config = Config
			return `{Config.undecided()} config fields TBD`
		end,

		kits = deps.kitLoader.phase({ config = Config, root = deps.kitsRoot, loader = deps.loader }),

		data = function(_ctx)
			if Config.get("data.enabled", false) ~= true then
				return "no data layer: Config.data.enabled is TBD"
			end
			-- Wire the data layer here: start GameKit/PlayerData with the ProfileStore module from
			-- ServerStorage.ServerPackages (it opens a session per joining player and saves on leave and
			-- shutdown) and put the service on ctx.data for later phases.
			error("Config.data.enabled is true but no data layer is wired in src/server/Phases.luau", 0)
		end,

		remotes = function(ctx)
			local folder = deps.replicatedStorage:FindFirstChild("Remotes")
				or deps.newFolder("Remotes", deps.replicatedStorage)
			ctx.remotes = folder
			-- Register each remote through GameKit/RemoteGuard (release check A02), or generate it with Blink.
			return "Remotes folder ready"
		end,

		telemetry = function(ctx)
			ctx.events = {
				emit = function(_self, _event)
					return false, "no_sink"
				end,
			}
			if Config.get("telemetry.enabled", false) ~= true then
				return "events go to a null sink: Config.telemetry.enabled is TBD"
			end
			-- Wire the events sink here (GameKit/Telemetry with the catalog in src/shared/telemetry.json).
			error("Config.telemetry.enabled is true but no sink is wired in src/server/Phases.luau", 0)
		end,
	}
end

return Phases
