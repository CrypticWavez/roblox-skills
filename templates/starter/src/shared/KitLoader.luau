--!strict
-- @tier T0
-- KitLoader: finds optional kit modules ("GameKit/Signal", "UIKit/Components/Button") under a root
-- such as ReplicatedStorage.Kits, so the boot works whether or not a kit is installed. A missing kit
-- is reported as absent, never raised; a module that errors while loading is reported with its error.
-- Pure: the root is anything with FindFirstChild (an Instance, or a table in tests) and the loader is
-- passed in (`require` in Roblox).
local KitLoader = {}

-- The Stage 0 GameKit modules the starter's phases use when present (docs/runtime-kits.md section 4).
KitLoader.STAGE0 =
	table.freeze({ "GameKit/Check", "GameKit/Signal", "GameKit/Scope", "GameKit/Fsm", "GameKit/Env" })

export type Collected = {
	modules: { [string]: any },
	present: { string },
	absent: { string },
	errors: { [string]: string },
}

-- (module?, reason?) for one path; reason is "absent", "no_root", "not_a_module" or "load_error: ...".
function KitLoader.find(root: any, path: string, loader: (any) -> any): (any, string?)
	if root == nil then
		return nil, "no_root"
	end
	local node = root
	for part in string.gmatch(path, "[^/]+") do
		local child = node:FindFirstChild(part)
		if child == nil then
			return nil, "absent"
		end
		node = child
	end
	local className = node.ClassName
	if className ~= nil and className ~= "ModuleScript" then
		return nil, "not_a_module"
	end
	local ok, result = pcall(loader, node)
	if not ok then
		return nil, "load_error: " .. tostring(result)
	end
	return result, nil
end

-- Loads every path; modules are keyed by their last path part ("Signal").
function KitLoader.collect(root: any, paths: { string }, loader: (any) -> any): Collected
	local out: Collected = { modules = {}, present = {}, absent = {}, errors = {} }
	for _, path in paths do
		local module, reason = KitLoader.find(root, path, loader)
		if module ~= nil then
			local short = string.match(path, "([^/]+)$") or path
			out.modules[short] = module
			table.insert(out.present, path)
		elseif reason == "absent" or reason == "no_root" then
			table.insert(out.absent, path)
		else
			out.errors[path] = reason or "unknown"
		end
	end
	return out
end

-- Problems for kits the game requires (Config.kits.required) that did not load.
function KitLoader.missing(collected: Collected, required: { string }): { string }
	local problems = {}
	for _, path in required do
		if table.find(collected.present, path) == nil then
			local why = collected.errors[path] or "absent"
			table.insert(problems, `{path}: {why}`)
		end
	end
	return problems
end

-- The "kits" boot phase both sides run: loads STAGE0 plus Config.kits.required (and options.extra),
-- puts the modules on ctx.kits and the details on ctx.kitStatus, and fails when a required kit is
-- missing or an installed kit module errors while loading. Absent optional kits are fine.
function KitLoader.phase(options: { config: any, root: any, loader: (any) -> any, extra: { string }? })
	return function(ctx: { [string]: any }): string
		local required = options.config.get("kits.required", {})
		local paths = table.clone(KitLoader.STAGE0)
		for _, list in { options.extra or {}, required } do
			for _, path in list do
				if table.find(paths, path) == nil then
					table.insert(paths, path)
				end
			end
		end
		local collected = KitLoader.collect(options.root, paths, options.loader)
		ctx.kits = collected.modules
		ctx.kitStatus = collected
		local problems = KitLoader.missing(collected, required)
		for path, why in collected.errors do
			if table.find(required, path) == nil then
				table.insert(problems, `{path}: {why}`)
			end
		end
		if #problems > 0 then
			table.sort(problems)
			error("kits: " .. table.concat(problems, "; "), 0)
		end
		return `{#collected.present} of {#paths} kit modules present`
	end
end

return table.freeze(KitLoader)
