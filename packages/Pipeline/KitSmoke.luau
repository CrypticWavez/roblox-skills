--!strict
-- @tier T3
-- probe: kitsmoke_all
-- KitSmoke: finds every probe registry (`<prefix>_probes` ModuleScripts or files, docs/runtime-kits.md
-- section 7), merges them into one registry and runs it through the GameKit Probe runner, so a single
-- place run prints ENGINE_CHECK lines for every registered probe and one ENGINE_DONE line.
--   Studio  tests/engine/kitsmoke_all.luau (RunScript, shared + server registries) and the fixture
--           runners fixtures/kits/<server|client>/kitsmoke_Runner (play session, opt-in with
--           Workspace attribute SETUP_ONLY_KitFixture = "kitsmoke").
--   Lune    tools/lune/kit_smoke.luau and tests/pipeline_kitsmoke.spec.luau (fakes, golden kit-smoke).
-- The kit modules, Probe included, come through the caller's `kit` loader (KitSmoke.studioLoader in
-- Studio, a path loader in Lune), so Pipeline never requires a kit package itself. A registry that
-- fails to load, a probe name that is not a lower_snake label, a value that is not a function and a
-- name registered twice are problems: they are reported by the built-in probe kitsmoke_registries
-- (failed checks), never skipped silently. Read-only: it creates, changes and uploads nothing.
local KitSmoke = {}

KitSmoke.SIDES = table.freeze({ "shared", "server", "client" })
KitSmoke.BUILTIN = "kitsmoke_registries"
KitSmoke.REGISTRY_SUFFIX = "_probes"
local NAME_PATTERN = "^[a-z][a-z0-9_]+$"

export type Source = {
	side: string,
	name: string, -- registry name without extension, e.g. "foundation_probes"
	registry: any?,
	error: string?,
}
export type Entry = { side: string, name: string, probes: { string }, error: string? }
export type Options = {
	kit: (path: string) -> any,
	env: any?,
	emit: ((line: string) -> ())?,
	only: { string }?,
}

local function validName(name: any): boolean
	return type(name) == "string" and #name <= 64 and string.match(name, NAME_PATTERN) ~= nil
end

local function isRegistryName(name: any): boolean
	return type(name) == "string"
		and #name > #KitSmoke.REGISTRY_SUFFIX
		and string.sub(name, -#KitSmoke.REGISTRY_SUFFIX) == KitSmoke.REGISTRY_SUFFIX
end

local function sortedSources(sources: { Source }): { Source }
	local list = table.clone(sources)
	table.sort(list, function(a: Source, b: Source): boolean
		local sideA, sideB =
			table.find(KitSmoke.SIDES, a.side) or 99, table.find(KitSmoke.SIDES, b.side) or 99
		if sideA ~= sideB then
			return sideA < sideB
		end
		return a.name < b.name
	end)
	return list
end

-- Merges sources into one { [probe] = fn }. Returns (registry, problems, inventory), where the
-- inventory lists every source with the probe names it contributed, in side then name order.
function KitSmoke.merge(sources: { Source }): ({ [string]: any }, { string }, { Entry })
	local registry: { [string]: any } = {}
	local owners: { [string]: string } = { [KitSmoke.BUILTIN] = "KitSmoke" }
	local problems: { string } = {}
	local inventory: { Entry } = {}
	for _, source in sortedSources(sources) do
		local label = tostring(source.side) .. "/" .. tostring(source.name)
		local entry: Entry = { side = source.side, name = source.name, probes = {} }
		table.insert(inventory, entry)
		if not table.find(KitSmoke.SIDES, source.side) then
			table.insert(problems, label .. ": side must be shared, server or client")
		end
		if not isRegistryName(source.name) then
			table.insert(problems, label .. ": registry names end in " .. KitSmoke.REGISTRY_SUFFIX)
		end
		if source.error ~= nil then
			entry.error = "load_failed"
			table.insert(problems, label .. ": failed to load")
			continue
		end
		if type(source.registry) ~= "table" then
			entry.error = "not_a_table"
			table.insert(problems, label .. ": a registry returns { [probeName] = function }")
			continue
		end
		local names = {}
		for name in source.registry do
			table.insert(names, name)
		end
		table.sort(names, function(a: any, b: any): boolean
			return tostring(a) < tostring(b)
		end)
		for _, name in names do
			local fn = source.registry[name]
			if not validName(name) then
				table.insert(problems, label .. ": invalid probe name " .. tostring(name))
			elseif type(fn) ~= "function" then
				table.insert(problems, label .. ": probe " .. name .. " is not a function")
			elseif owners[name] ~= nil then
				table.insert(
					problems,
					string.format("%s: probe %s is already registered by %s", label, name, owners[name])
				)
			else
				registry[name] = fn
				owners[name] = label
				table.insert(entry.probes, name)
			end
		end
	end
	return registry, problems, inventory
end

-- Runs the merged registry plus the built-in kitsmoke_registries probe through GameKit/Probe and
-- returns (summary, problems, inventory). `only` limits the run to those probe names.
function KitSmoke.run(sources: { Source }, opts: Options): (any, { string }, { Entry })
	assert(type(opts) == "table" and type(opts.kit) == "function", "KitSmoke.run: opts.kit loader required")
	local Probe = opts.kit("GameKit/Probe")
	local registry, problems, inventory = KitSmoke.merge(sources)
	registry[KitSmoke.BUILTIN] = function(ctx: any)
		for _, entry in inventory do
			ctx.check(
				"loaded " .. entry.side .. "/" .. entry.name,
				entry.error == nil,
				if entry.error then { error = entry.error } else { probes = #entry.probes }
			)
		end
		ctx.check("registries_found", #inventory > 0, { registries = #inventory })
		ctx.check("no_problems", #problems == 0, if #problems > 0 then problems else nil)
	end
	local summary =
		Probe.runAll(registry, { emit = opts.emit, env = opts.env, kit = opts.kit, only = opts.only })
	return summary, problems, inventory
end

-- ---------------------------------------------------------------- Studio

-- A kit loader over the place's ReplicatedStorage.Workbench (fixtures/kits.project.json):
-- kit("GameKit/Signal") requires Workbench.GameKit.Signal, waiting up to `timeout` seconds per step.
function KitSmoke.studioLoader(workbench: any, requireFn: ((any) -> any)?, timeout: number?): (string) -> any
	local load = requireFn or (require :: any)
	return function(path: string): any
		local node = workbench
		for _, part in string.split(path, "/") do
			local child = node:WaitForChild(part, timeout or 10)
			if child == nil then
				error("KitSmoke: Workbench has no " .. path, 2)
			end
			node = child
		end
		return load(node)
	end
end

-- Registries in Studio folders: { { side, folder } }. Every ModuleScript under a folder whose name
-- ends in _probes is required (pcall); a failure becomes a source with an error.
function KitSmoke.collect(folders: { { side: string, folder: any } }, requireFn: ((any) -> any)?): { Source }
	local load = requireFn or (require :: any)
	local sources: { Source } = {}
	for _, where in folders do
		if where.folder == nil then
			continue
		end
		for _, child in where.folder:GetDescendants() do
			if child:IsA("ModuleScript") and isRegistryName(child.Name) then
				local ok, result = pcall(load, child)
				table.insert(sources, {
					side = where.side,
					name = child.Name,
					registry = if ok then result else nil,
					error = if ok then nil else tostring(result),
				})
			end
		end
	end
	return sources
end

-- ---------------------------------------------------------------- Lune

export type Files = {
	readDir: (path: string) -> { string },
	isDir: (path: string) -> boolean,
	isFile: (path: string) -> boolean,
}

local function walk(files: Files, dir: string, rel: string, out: { string })
	local names = files.readDir(dir)
	table.sort(names)
	for _, name in names do
		local path = dir .. "/" .. name
		local relPath = if rel == "" then name else rel .. "/" .. name
		if files.isDir(path) then
			walk(files, path, relPath, out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, relPath)
		end
	end
end

-- Registries on disk under <root>/fixtures/kits/<side>/. `load(path)` gets the repository-relative
-- path without extension ("fixtures/kits/shared/foundation_probes") and returns the registry.
function KitSmoke.fromFiles(
	files: Files,
	root: string,
	load: (path: string) -> any,
	sides: { string }?
): { Source }
	local sources: { Source } = {}
	local sideList: { string } = sides or KitSmoke.SIDES
	for _, side in sideList do
		local dir = root .. "/fixtures/kits/" .. side
		if not files.isDir(dir) then
			continue
		end
		local found = {}
		walk(files, dir, "", found)
		for _, rel in found do
			local name = string.match(rel, "([^/]+)%.luau$") :: string
			if not isRegistryName(name) then
				continue
			end
			local path = "fixtures/kits/" .. side .. "/" .. string.gsub(rel, "%.luau$", "")
			local ok, result = pcall(load, path)
			table.insert(sources, {
				side = side,
				name = name,
				registry = if ok then result else nil,
				error = if ok then nil else tostring(result),
			})
		end
	end
	return sources
end

return KitSmoke
