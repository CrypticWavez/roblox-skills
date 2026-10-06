--!strict
-- @tier T3
-- Client boot phases (Boot.SIDES.client): config, kits, remotes, ui, input. Hooks with no game content:
-- the ui phase mounts an empty root ScreenGui and records the player's motion and flash preferences
-- (settings/1 through GameKit/Settings when installed, else the system reduced-motion setting); the
-- game's first screen (UIKit after merge) mounts under ctx.ui.root. The input phase is where
-- GameKit/InputMap creates the Input Action System contexts once Config.input.contexts is decided.
local Phases = {}

export type Deps = {
	config: any, -- src/shared/Config
	kitLoader: any, -- src/shared/KitLoader
	kitsRoot: any, -- ReplicatedStorage.Kits (nil when no kit is installed)
	loader: (any) -> any, -- require
	replicatedStorage: any,
	playerGui: any,
	systemReducedMotion: () -> boolean, -- GuiService.ReducedMotionEnabled
	newScreenGui: (name: string, parent: any) -> any,
}

-- Motion and flash preferences every client module reads (settings/1 field names).
function Phases.motion(
	settingsModule: any,
	systemReducedMotion: boolean
): { reducedMotion: boolean, allowFlashes: boolean }
	if settingsModule ~= nil and type(settingsModule.effective) == "function" then
		-- The player's saved values replace defaults() once a settings store (GameKit/SettingsStore) is wired.
		local ok, effective = pcall(function()
			return settingsModule.effective(
				settingsModule.defaults(),
				{ reducedMotion = systemReducedMotion }
			)
		end)
		if ok and type(effective) == "table" then
			return {
				reducedMotion = effective.reducedMotion == true,
				allowFlashes = effective.allowFlashes ~= false,
			}
		end
	end
	local reduceFlashing = false -- settings/1 default for reduceFlashing
	return { reducedMotion = systemReducedMotion, allowFlashes = not reduceFlashing }
end

function Phases.client(deps: Deps): { [string]: (ctx: { [string]: any }) -> any }
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

		kits = deps.kitLoader.phase({
			config = Config,
			root = deps.kitsRoot,
			loader = deps.loader,
			extra = { "GameKit/Settings" },
		}),

		remotes = function(ctx)
			-- Created by the server's remotes phase; a failed server boot shows up here as a timeout.
			local folder = deps.replicatedStorage:WaitForChild("Remotes")
			ctx.remotes = folder
			return "Remotes folder found"
		end,

		ui = function(ctx)
			ctx.motion = Phases.motion(ctx.kits and ctx.kits.Settings, deps.systemReducedMotion())
			local root = deps.playerGui:FindFirstChild("GameRoot")
				or deps.newScreenGui("GameRoot", deps.playerGui)
			ctx.ui = { root = root, motion = ctx.motion }
			local first = Config.get("ui.root", nil)
			if first == nil then
				return "empty UI root: Config.ui.root is TBD"
			end
			-- Mount the first screen here (a UIKit screen once installed), passing ctx.motion so transitions
			-- respect reducedMotion and allowFlashes.
			error(`Config.ui.root is {first} but no screen is wired in src/client/Phases.luau`, 0)
		end,

		input = function(_ctx)
			local contexts = Config.get("input.contexts", nil)
			if contexts == nil then
				return "no input contexts: Config.input.contexts is TBD"
			end
			-- Create the Input Action System contexts here (GameKit/InputMap).
			error("Config.input.contexts is set but no InputMap is wired in src/client/Phases.luau", 0)
		end,
	}
end

return Phases
