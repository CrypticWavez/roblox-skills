--!strict
-- @tier T3
-- probe: import_clips
-- Studio RunScript entry for probe import_clips (G6). Pending T3: gap row B07 (animation import)
-- stays BLOCKED_EXTERNAL until the owner runs it after a manual import. Setup, in the unpublished
-- diagnostic place built from fixtures/kits.project.json:
--   1. `python3 tools/blender/factory.py template pet_follower build/blender`;
--   2. import `pet_follower_clips.glb` (all clips) or a `pet_follower_<clip>.fbx` with the 3D Importer
--      into Workspace, keep the model named `pet_follower`;
--   3. paste `pet_follower_clips.json` (clips/1) into a StringValue named `pet_follower` under
--      ReplicatedStorage.ImportClips;
--   4. run this script in a play session; it prints ENGINE_CHECK lines and one ENGINE_DONE.
-- Records where the importer put the animations (classes and names: UNVERIFIED until this runs),
-- then Pipeline/ImportInspector.inspectClips: every clip present, lengths within half a frame,
-- markers, and the play plan (looping, priority, marker times) AnimSet applies from the sidecar.
-- In Lune (no `game`) the file returns { registry = fn(cases) } for tests/import_inspector.spec.luau.
local Probes = {}

export type Case = { asset: string, sidecar: any, root: any? }

function Probes.registry(cases: { Case }): { [string]: (ctx: any) -> () }
	return {
		import_clips = function(ctx: any)
			local Inspector = ctx.kit("Pipeline/ImportInspector")
			ctx.check("cases_present", #cases > 0, { cases = #cases })
			for _, case in cases do
				if case.root == nil then
					ctx.check(
						case.asset .. ":model_present",
						false,
						"import the file into Workspace as " .. case.asset
					)
					continue
				end
				local observed = Inspector.studioClips(case.root)
				local found = {}
				for _, o in observed do
					table.insert(found, {
						name = o.name,
						path = o.path,
						length = o.length,
						markers = o.markers and #o.markers or 0,
					})
				end
				ctx.check(case.asset .. ":animations_found", #observed > 0, found)
				local report = Inspector.inspectClips(case.sidecar, observed)
				for _, c in report.checks do
					ctx.check(
						case.asset .. ":" .. c.name,
						c.pass,
						{ value = c.value, expected = c.expected, detail = c.detail, checked = c.checked }
					)
				end
				ctx.check(
					case.asset .. ":plan",
					#report.plan > 0,
					{ plan = report.plan, extra = report.extra }
				)
			end
		end,
	}
end

if (game :: any) == nil then
	return Probes
end

local ReplicatedStorage = (game :: any):GetService("ReplicatedStorage")
local HttpService = (game :: any):GetService("HttpService")
local workbench = ReplicatedStorage:WaitForChild("Workbench", 10)

local function kit(path: string): any
	local node = workbench
	for _, part in string.split(path, "/") do
		node = node:WaitForChild(part, 10)
	end
	return (require :: any)(node)
end

local ServerStorage = (game :: any):GetService("ServerStorage")

-- Searches the imported model and ServerStorage.RBX_ANIMSAVES (where the Animation Clip Editor
-- saves; the 3D Importer's location is UNVERIFIED). nil when neither exists.
local function rootFor(model: any): any?
	local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	if model == nil and saves == nil then
		return nil
	end
	return {
		GetDescendants = function(_self: any): { any }
			local all = {}
			for _, holder in { model, saves } do
				if holder ~= nil then
					for _, d in holder:GetDescendants() do
						table.insert(all, d)
					end
				end
			end
			return all
		end,
	}
end

local Probe = kit("GameKit/Probe")
local EnvRoblox = kit("GameKit/EnvRoblox")
local cases: { Case } = {}
local folder = ReplicatedStorage:FindFirstChild("ImportClips")
if folder then
	for _, value in folder:GetChildren() do
		if value:IsA("StringValue") then
			table.insert(cases, {
				asset = value.Name,
				sidecar = HttpService:JSONDecode(value.Value),
				root = rootFor((workspace :: any):FindFirstChild(value.Name)),
			})
		end
	end
end
Probe.runAll(Probes.registry(cases), { env = EnvRoblox.studio(), kit = kit, only = { "import_clips" } })
return Probes
