--!strict
-- model.* operations on instances already in a place (imported meshes, kit pieces, SceneKit
-- output): inspect, scale, pivot, material, collision, optimize. Every operation takes a scope:
-- an Instance, a list of Instances, or Model.selection() (Studio's current selection; {} under
-- Lune). Mutating operations compute their whole change list first; options.dryRun returns it
-- without touching anything, otherwise it is applied inside one ChangeHistory recording
-- (Apply.withUndo), so one Studio undo reverts it, and Model.revert(result) restores the old values
-- anywhere. If a property set fails, the ones already set are restored before the error is raised.
-- Values are computed here (no GetPivot/ScaleTo/GetJoints) so Lune and Studio take the same path.
-- Pass options.env = require("@lune/roblox") in Lune, as with Apply.scene; Studio uses the globals.
-- Model.apply takes a hand-made change list under the same rules.
--   local SK = require(game.ReplicatedStorage.Workbench.SceneKit.SceneKit)
--   print(SK.Model.inspect(SK.Model.selection()).bounds)
--   SK.Model.pivot(SK.Model.selection(), "base_center")
local Apply = require("./Apply")

local Model = {}

export type Options = { dryRun: boolean?, env: any?, history: any? }
export type PlanItem = { instance: any, property: string, from: any, to: any }
export type Result = {
	op: string,
	dryRun: boolean,
	count: number,
	changes: { { path: string, property: string, from: any, to: any } }, -- JSON-friendly
	warnings: { string },
	plan: { PlanItem }, -- raw values, used by apply and Model.revert
	[string]: any,
}
export type Filter = ((part: any) -> boolean) | { material: string?, name: string?, className: string? }

local MAX_WARNINGS = 50
local FALLEN_PARTS_HEIGHT = -500 -- Workspace.FallenPartsDestroyHeight default

local function round(n: number): number
	return math.round(n * 1000) / 1000
end

-- JSON-friendly copy of a Roblox value for reports.
local function plain(value: any): any
	local kind = typeof(value)
	if kind == "Vector3" then
		return { x = round(value.X), y = round(value.Y), z = round(value.Z) }
	elseif kind == "CFrame" then
		local rx, ry, rz = value:ToOrientation()
		return {
			pos = plain(value.Position),
			rot = { x = round(math.deg(rx)), y = round(math.deg(ry)), z = round(math.deg(rz)) },
		}
	elseif kind == "Color3" then
		return { math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255) }
	elseif kind == "EnumItem" then
		return value.Name
	end
	return value
end
Model.plain = plain

local function rounded(v: { x: number, y: number, z: number })
	return { x = round(v.x), y = round(v.y), z = round(v.z) }
end

local function envOf(options: any?): any
	return options and options.env or Apply.defaultEnv()
end

local function warn(list: { string }, message: string)
	if #list < MAX_WARNINGS then
		table.insert(list, message)
	elseif #list == MAX_WARNINGS then
		table.insert(list, "... more warnings omitted")
	end
end

-- Studio's current selection; {} where there is no Selection service (Lune, a running game).
function Model.selection(): { any }
	local ok, list = pcall(function()
		return (game :: any):GetService("Selection"):Get()
	end)
	return if ok and type(list) == "table" then list else {}
end

local function roots(scope: any): { any }
	if typeof(scope) == "Instance" then
		return { scope }
	end
	assert(
		type(scope) == "table",
		"Model: scope must be an Instance, a list of Instances or Model.selection()"
	)
	for index, item in scope do
		assert(typeof(item) == "Instance", "Model: scope item " .. tostring(index) .. " is not an Instance")
	end
	return scope
end

-- BaseParts in scope (each root and its descendants), each once, in scope then tree order.
function Model.parts(scope: any): { any }
	local out, seen = {}, {}
	local function add(instance: any)
		if instance:IsA("BasePart") and not seen[instance] then
			seen[instance] = true
			table.insert(out, instance)
		end
	end
	for _, root in roots(scope) do
		add(root)
		for _, d in root:GetDescendants() do
			add(d)
		end
	end
	return out
end

local function descendantsOf(list: { any }): { any }
	local out, seen = {}, {}
	local function add(instance: any)
		if not seen[instance] then
			seen[instance] = true
			table.insert(out, instance)
		end
	end
	for _, root in list do
		add(root)
		for _, d in root:GetDescendants() do
			add(d)
		end
	end
	return out
end

-- World bounds of parts from CFrame + Size (rotated boxes), as plain {x, y, z} tables.
function Model.bounds(parts: { any })
	if #parts == 0 then
		return nil
	end
	local min = { x = math.huge, y = math.huge, z = math.huge }
	local max = { x = -math.huge, y = -math.huge, z = -math.huge }
	for _, part in parts do
		local cf, size = part.CFrame, part.Size
		local ax, ay, az = cf.XVector, cf.YVector, cf.ZVector
		local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
		local ex = math.abs(ax.X) * hx + math.abs(ay.X) * hy + math.abs(az.X) * hz
		local ey = math.abs(ax.Y) * hx + math.abs(ay.Y) * hy + math.abs(az.Y) * hz
		local ez = math.abs(ax.Z) * hx + math.abs(ay.Z) * hy + math.abs(az.Z) * hz
		local p = cf.Position
		min = { x = math.min(min.x, p.X - ex), y = math.min(min.y, p.Y - ey), z = math.min(min.z, p.Z - ez) }
		max = { x = math.max(max.x, p.X + ex), y = math.max(max.y, p.Y + ey), z = math.max(max.z, p.Z + ez) }
	end
	local center = { x = (min.x + max.x) / 2, y = (min.y + max.y) / 2, z = (min.z + max.z) / 2 }
	return {
		min = min,
		max = max,
		size = { x = max.x - min.x, y = max.y - min.y, z = max.z - min.z },
		center = center,
		baseCenter = { x = center.x, y = min.y, z = center.z },
	}
end

-- Pivot as Studio defines it (PrimaryPart pivot, else WorldPivot; a part's CFrame * PivotOffset).
-- nil when unknown (Lune leaves WorldPivot unset until it is written).
function Model.pivotOf(instance: any): any?
	if instance:IsA("BasePart") then
		return instance.CFrame * instance.PivotOffset
	elseif instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary then
			return primary.CFrame * primary.PivotOffset
		end
		local ok, pivot = pcall(function()
			return instance.WorldPivot
		end)
		return if ok then pivot else nil
	end
	return nil
end

-- Parts held by joints or constraints inside the scope, plus parts of Humanoid models.
local function jointedParts(list: { any }, parts: { any }): { [any]: boolean }
	local set = {}
	for _, d in descendantsOf(list) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			for _, key in { "Part0", "Part1" } do
				local part = d[key]
				if part then
					set[part] = true
				end
			end
		elseif d:IsA("Constraint") then
			for _, key in { "Attachment0", "Attachment1" } do
				local attachment = d[key]
				if attachment and attachment.Parent then
					set[attachment.Parent] = true
				end
			end
		end
	end
	for _, part in parts do
		local ancestor = part.Parent
		while ancestor and not set[part] do
			if ancestor:IsA("Model") and ancestor:FindFirstChildWhichIsA("Humanoid") then
				set[part] = true
			end
			ancestor = ancestor.Parent
		end
	end
	return set
end

local function matches(part: any, filter: Filter?): boolean
	if filter == nil then
		return true
	elseif type(filter) == "function" then
		return filter(part)
	end
	local f = filter :: any
	return (f.material == nil or part.Material.Name == f.material)
		and (f.name == nil or string.find(part.Name, f.name) ~= nil)
		and (f.className == nil or part:IsA(f.className))
end

-- Set every planned value in order; if one set fails, restore the ones already set and re-raise.
local function setAll(plan: { PlanItem })
	local done = 0
	local ok, err = pcall(function()
		for index, item in plan do
			item.instance[item.property] = item.to
			done = index
		end
	end)
	if not ok then
		for index = done, 1, -1 do
			local item = plan[index]
			pcall(function()
				item.instance[item.property] = item.from
			end)
		end
		error(err, 0)
	end
end

local function finish(op: string, plan: { PlanItem }, warnings: { string }, options: any?): Result
	local changes = {}
	for _, item in plan do
		table.insert(changes, {
			path = item.instance:GetFullName(),
			property = item.property,
			from = plain(item.from),
			to = plain(item.to),
		})
	end
	local dryRun = options ~= nil and options.dryRun == true
	if not dryRun and #plan > 0 then
		Apply.withUndo("SceneKit Model." .. op, function()
			setAll(plan)
		end, { history = options and options.history, env = options and options.env })
	end
	return { op = op, dryRun = dryRun, count = #plan, changes = changes, warnings = warnings, plan = plan }
end

local function change(plan: { PlanItem }, instance: any, property: string, to: any)
	local ok, from = pcall(function()
		return instance[property]
	end)
	local current = if ok then from else nil
	if current ~= to then
		table.insert(plan, { instance = instance, property = property, from = current, to = to })
	end
end

-- Read-only report: part, mesh and light counts, classes, materials, anchored/collision summary,
-- bounds (min/max/size/center/baseCenter), pivot and its offset from the base centre (single
-- Model or BasePart scope), and warnings (unanchored and unjointed, invisible but collidable,
-- below FallenPartsDestroyHeight).
function Model.inspect(scope: any)
	local list = roots(scope)
	local parts = Model.parts(list)
	local jointed = jointedParts(list, parts)
	local report = {
		roots = #list,
		parts = #parts,
		meshes = 0,
		lights = 0,
		classes = {},
		materials = {},
		anchored = 0,
		unanchored = 0,
		canCollide = 0,
		canQuery = 0,
		canTouch = 0,
		bounds = nil :: any,
		pivot = nil :: any,
		warnings = {},
	}
	for _, d in descendantsOf(list) do
		if d:IsA("Light") then
			report.lights += 1
		elseif d:IsA("DataModelMesh") then
			report.meshes += 1
		end
	end
	for _, part in parts do
		local path = part:GetFullName()
		report.classes[part.ClassName] = (report.classes[part.ClassName] or 0) + 1
		report.materials[part.Material.Name] = (report.materials[part.Material.Name] or 0) + 1
		if part:IsA("MeshPart") then
			report.meshes += 1
		end
		if part.Anchored then
			report.anchored += 1
		else
			report.unanchored += 1
			if not jointed[part] then
				warn(report.warnings, path .. ": unanchored and not jointed (falls in play)")
			end
		end
		report.canCollide += if part.CanCollide then 1 else 0
		report.canQuery += if part.CanQuery then 1 else 0
		report.canTouch += if part.CanTouch then 1 else 0
		if part.Transparency >= 0.99 and part.CanCollide then
			warn(report.warnings, path .. ": invisible but collidable")
		end
	end
	local b = Model.bounds(parts)
	if b then
		report.bounds = {
			min = rounded(b.min),
			max = rounded(b.max),
			size = rounded(b.size),
			center = rounded(b.center),
			baseCenter = rounded(b.baseCenter),
		}
		if b.min.y < FALLEN_PARTS_HEIGHT then
			warn(
				report.warnings,
				"bounds reach below FallenPartsDestroyHeight (" .. FALLEN_PARTS_HEIGHT .. ")"
			)
		end
		local pivot = if #list == 1 then Model.pivotOf(list[1]) else nil
		if pivot then
			local p = pivot.Position
			report.pivot = {
				position = plain(p),
				offsetFromBase = {
					x = round(p.X - b.baseCenter.x),
					y = round(p.Y - b.baseCenter.y),
					z = round(p.Z - b.baseCenter.z),
				},
			}
		end
	end
	return report
end

-- Vector3 from a Vector3, a CFrame's position or a plain {x, y, z} table.
function Model.vector(env: any, v: any): any
	if typeof(v) == "Vector3" then
		return v
	elseif typeof(v) == "CFrame" then
		return v.Position
	end
	return env.Vector3.new(v.x or v.X, v.y or v.Y, v.z or v.Z)
end

-- Uniform scale about a centre: options.about (Vector3, CFrame or {x, y, z}), else the pivot of
-- a single Model/BasePart scope, else the scope's base centre. Scales part sizes and positions,
-- PivotOffsets, Model WorldPivots, Attachment offsets and FileMesh scales; rotations stay. Joint
-- offsets (C0/C1) are not scaled: rigs and welded assemblies are reported in warnings (use Studio's
-- Model:ScaleTo for those).
function Model.scale(scope: any, factor: number, options: (Options & { about: any? })?): Result
	assert(
		type(factor) == "number" and factor > 0 and factor < math.huge,
		"Model.scale: factor must be a positive number"
	)
	local env = envOf(options)
	local list = roots(scope)
	local parts = Model.parts(list)
	local warnings, plan = {}, {}
	local b = Model.bounds(parts)
	if b == nil then
		warn(warnings, "no parts in scope")
		return finish("scale", plan, warnings, options)
	end
	local about = options and options.about
	local centre
	if about ~= nil then
		centre = Model.vector(env, about)
	else
		local pivot = if #list == 1 then Model.pivotOf(list[1]) else nil
		centre = if pivot then pivot.Position else Model.vector(env, b.baseCenter)
	end
	local jointed = jointedParts(list, parts)
	local jointedCount = 0
	for _, part in parts do
		if jointed[part] then
			jointedCount += 1
		end
		local cf = part.CFrame
		local pos = cf.Position
		change(plan, part, "Size", part.Size * factor)
		change(plan, part, "CFrame", cf + (centre + (pos - centre) * factor - pos))
		local offset = part.PivotOffset
		if offset.Position.Magnitude > 0 then
			change(plan, part, "PivotOffset", offset.Rotation + offset.Position * factor)
		end
	end
	for _, d in descendantsOf(list) do
		if d:IsA("Model") and d.PrimaryPart == nil then
			local ok, pivot = pcall(function()
				return d.WorldPivot
			end)
			if ok and pivot then
				change(plan, d, "WorldPivot", pivot.Rotation + (centre + (pivot.Position - centre) * factor))
			end
		elseif d:IsA("Attachment") then
			local cf = d.CFrame
			change(plan, d, "CFrame", cf.Rotation + cf.Position * factor)
		elseif d:IsA("SpecialMesh") and d.MeshType == env.Enum.MeshType.FileMesh then
			change(plan, d, "Scale", d.Scale * factor)
		end
	end
	if jointedCount > 0 then
		warn(
			warnings,
			jointedCount .. " jointed parts: joint offsets (C0/C1) are not scaled; use Model:ScaleTo for rigs"
		)
	end
	return finish("scale", plan, warnings, options)
end

-- Move the pivot of every Model/BasePart root in scope to its own "base_center" (bottom centre of
-- its bounds) or "center", keeping the pivot's rotation, or to a given CFrame. Sets the
-- PrimaryPart's PivotOffset when the model has one, else Model.WorldPivot; a part's PivotOffset.
function Model.pivot(scope: any, mode: any, options: Options?): Result
	assert(
		mode == "base_center" or mode == "center" or typeof(mode) == "CFrame",
		'Model.pivot: mode must be "base_center", "center" or a CFrame'
	)
	local env = envOf(options)
	local warnings, plan = {}, {}
	for _, root in roots(scope) do
		if not (root:IsA("Model") or root:IsA("BasePart")) then
			warn(warnings, root:GetFullName() .. ": not a Model or BasePart, skipped")
			continue
		end
		local b = Model.bounds(Model.parts(root))
		if b == nil then
			warn(warnings, root:GetFullName() .. ": no parts, skipped")
			continue
		end
		local current = Model.pivotOf(root)
		local target
		if typeof(mode) == "CFrame" then
			target = mode
		else
			local p = if mode == "base_center" then b.baseCenter else b.center
			local pos = env.Vector3.new(p.x, p.y, p.z)
			target = if current then current.Rotation + pos else env.CFrame.new(p.x, p.y, p.z)
		end
		if root:IsA("BasePart") then
			change(plan, root, "PivotOffset", root.CFrame:Inverse() * target)
		elseif root.PrimaryPart then
			change(plan, root.PrimaryPart, "PivotOffset", root.PrimaryPart.CFrame:Inverse() * target)
		else
			change(plan, root, "WorldPivot", target)
		end
	end
	return finish("pivot", plan, warnings, options)
end

-- Set Material (an Enum.Material name or item) and/or Color ({r, g, b} 0..255 or Color3) on the
-- parts in scope that pass `filter` (a predicate or { material = name, name = pattern,
-- className = class }).
function Model.material(
	scope: any,
	options: Options & { material: any?, color: any?, filter: Filter? }
): Result
	assert(options.material ~= nil or options.color ~= nil, "Model.material: give material and/or color")
	local env = envOf(options)
	local material = options.material
	if material ~= nil and typeof(material) ~= "EnumItem" then
		local ok, item = pcall(function()
			return env.Enum.Material[material]
		end)
		assert(ok and item ~= nil, "Model.material: unknown material " .. tostring(material))
		material = item
	end
	local color = options.color
	if color ~= nil and typeof(color) ~= "Color3" then
		color = env.Color3.fromRGB(color[1], color[2], color[3])
	end
	local plan = {}
	for _, part in Model.parts(scope) do
		if matches(part, options.filter) then
			if material ~= nil then
				change(plan, part, "Material", material)
			end
			if color ~= nil then
				change(plan, part, "Color", color)
			end
		end
	end
	return finish("material", plan, {}, options)
end

-- Collision settings on the parts in scope that pass `filter`: canCollide, canQuery, canTouch,
-- collisionGroup (register the group first in Studio) and collisionFidelity (MeshParts and
-- unions only; other parts are skipped with a warning).
function Model.collision(
	scope: any,
	options: Options & {
		canCollide: boolean?,
		canQuery: boolean?,
		canTouch: boolean?,
		collisionGroup: string?,
		collisionFidelity: string?,
		filter: Filter?,
	}
): Result
	local o = options :: any
	assert(
		o.canCollide ~= nil
			or o.canQuery ~= nil
			or o.canTouch ~= nil
			or o.collisionGroup ~= nil
			or o.collisionFidelity ~= nil,
		"Model.collision: give at least one of canCollide, canQuery, canTouch, collisionGroup, collisionFidelity"
	)
	assert(
		o.collisionGroup == nil or type(o.collisionGroup) == "string",
		"Model.collision: collisionGroup must be a string"
	)
	local env = envOf(options)
	local fidelity = nil
	if o.collisionFidelity ~= nil then
		local ok, item = pcall(function()
			return env.Enum.CollisionFidelity[o.collisionFidelity]
		end)
		assert(
			ok and item ~= nil,
			"Model.collision: unknown collisionFidelity " .. tostring(o.collisionFidelity)
		)
		fidelity = item
	end
	local plan, warnings = {}, {}
	local skippedFidelity, queryIgnored = 0, 0
	for _, part in Model.parts(scope) do
		if matches(part, o.filter) then
			for _, pair in
				{
					{ "CanCollide", o.canCollide },
					{ "CanQuery", o.canQuery },
					{ "CanTouch", o.canTouch },
					{ "CollisionGroup", o.collisionGroup },
				}
			do
				if pair[2] ~= nil then
					change(plan, part, pair[1], pair[2])
				end
			end
			if fidelity ~= nil then
				if part:IsA("TriangleMeshPart") then
					change(plan, part, "CollisionFidelity", fidelity)
				else
					skippedFidelity += 1
				end
			end
			local collides = if o.canCollide == nil then part.CanCollide else o.canCollide
			if o.canQuery == false and collides then
				queryIgnored += 1
			end
		end
	end
	if skippedFidelity > 0 then
		warn(warnings, skippedFidelity .. " parts are not MeshParts or unions: CollisionFidelity skipped")
	end
	if queryIgnored > 0 then
		warn(warnings, queryIgnored .. " parts keep CanCollide = true, so CanQuery = false has no effect")
	end
	return finish("collision", plan, warnings, options)
end

-- Cheap wins in scope. Always reports findings; options.apply = true also applies the safe fixes
-- (anchor parts that are unanchored and not held by any joint/constraint or Humanoid model, turn
-- CastShadow off on parts smaller than tinySize on every axis), unless options.dryRun. Report-only:
-- invisible-but-collidable parts, PreciseConvexDecomposition collision, part count over budget.
function Model.optimize(
	scope: any,
	options: (Options & { apply: boolean?, tinySize: number?, partBudget: number? })?
): Result
	local o: any = options or {}
	local list = roots(scope)
	local parts = Model.parts(list)
	local jointed = jointedParts(list, parts)
	local tiny = o.tinySize or 1
	local budget = o.partBudget or 2000
	local findings, plan = {}, {}
	for _, part in parts do
		local path = part:GetFullName()
		if not part.Anchored and not jointed[part] then
			table.insert(findings, { kind = "unanchored_static", path = path, fix = "Anchored = true" })
			change(plan, part, "Anchored", true)
		end
		local size = part.Size
		if part.CastShadow and math.max(size.X, size.Y, size.Z) < tiny then
			table.insert(findings, { kind = "tiny_shadow", path = path, fix = "CastShadow = false" })
			change(plan, part, "CastShadow", false)
		end
		if part.Transparency >= 0.99 and part.CanCollide then
			table.insert(findings, { kind = "invisible_collidable", path = path })
		end
		if part:IsA("TriangleMeshPart") then
			local ok, value = pcall(function()
				return part.CollisionFidelity
			end)
			if ok and value and value.Name == "PreciseConvexDecomposition" then
				table.insert(findings, { kind = "precise_collision", path = path })
			end
		end
	end
	if #parts > budget then
		table.insert(findings, { kind = "part_budget", path = "scope", value = #parts, limit = budget })
	end
	local applying = o.apply == true and o.dryRun ~= true
	local result = finish("optimize", plan, {}, {
		dryRun = not applying,
		env = o.env,
		history = o.history,
	})
	result.findings = findings
	result.applied = applying
	return result
end

-- Apply a hand-made change list ({ instance, property, to }) with the same dry-run, undo and
-- rollback rules as the operations above; `from` is read from each instance.
function Model.apply(changes: { { instance: any, property: string, to: any } }, options: Options?): Result
	local plan = {}
	for index, item in changes do
		assert(typeof(item.instance) == "Instance", "Model.apply: change " .. index .. " has no instance")
		change(plan, item.instance, item.property, item.to)
	end
	return finish("apply", plan, {}, options)
end

-- Restore the `from` values of an applied result (reverse order, one ChangeHistory recording).
function Model.revert(result: Result, options: Options?): Result
	assert(type(result) == "table" and result.plan, "Model.revert needs a result from a Model operation")
	assert(not result.dryRun, "Model.revert: the result is a dry run, nothing was applied")
	local plan = {}
	for index = #result.plan, 1, -1 do
		local item = result.plan[index]
		table.insert(
			plan,
			{ instance = item.instance, property = item.property, from = item.to, to = item.from }
		)
	end
	return finish("revert", plan, {}, options)
end

return Model
