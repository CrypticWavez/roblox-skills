--!strict
-- @tier T3
-- probe: import_appearance
-- Studio RunScript entry for probe import_appearance (G6). Pending T3: gap rows B06 (colours) and
-- B02 (PBR maps) stay BLOCKED_EXTERNAL until the owner runs it after a manual import. Setup, in the
-- unpublished diagnostic place built from fixtures/kits.project.json:
--   1. `python3 tools/blender/factory.py template <kind> build/blender` (or `roundtrip build/roundtrip`);
--   2. import `<kind>.fbx` or `.glb` with the 3D Importer (Scale Unit = Studs) into Workspace, keep
--      the model named `<kind>` (or the marker's asset name);
--   3. paste `<kind>_expectation.json` (or `roblox_expectation_vN.json`) into a StringValue named like
--      the model under ReplicatedStorage.ImportExpectations;
--   4. run this script in a play session; it prints ENGINE_CHECK lines and one ENGINE_DONE.
-- Each model is inspected with Pipeline/ImportInspector: scale, pivot, facing, side, triangles and
-- the appearance route the expectation names (colour map and PBR maps, vertex colours, library).
-- In Lune (no `game`) the file returns { registry = fn(cases) } for tests/import_inspector.spec.luau.
local Probes = {}

export type Case = { asset: string, expectation: any, root: any?, options: any? }

function Probes.registry(cases: { Case }): { [string]: (ctx: any) -> () }
	return {
		import_appearance = function(ctx: any)
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
				local report = Inspector.inspect(case.root, case.expectation, case.options)
				for _, c in report.checks do
					ctx.check(
						case.asset .. ":" .. c.name,
						c.pass,
						{ value = c.value, expected = c.expected, detail = c.detail, checked = c.checked }
					)
				end
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

local Probe = kit("GameKit/Probe")
local EnvRoblox = kit("GameKit/EnvRoblox")
local cases: { Case } = {}
local folder = ReplicatedStorage:FindFirstChild("ImportExpectations")
if folder then
	for _, value in folder:GetChildren() do
		if value:IsA("StringValue") then
			table.insert(cases, {
				asset = value.Name,
				expectation = HttpService:JSONDecode(value.Value),
				root = (workspace :: any):FindFirstChild(value.Name),
			})
		end
	end
end
Probe.runAll(Probes.registry(cases), { env = EnvRoblox.studio(), kit = kit, only = { "import_appearance" } })
return Probes
