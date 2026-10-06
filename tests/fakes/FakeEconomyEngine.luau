--!strict
-- FakeEconomyEngine: a small Roblox-shaped engine for the G3 adapter specs and the economy probe
-- registry in Lune. It models only what FollowersRoblox, OutfitsRoblox and economy_probes touch:
-- Vector3, a yaw-only CFrame, Color3, Enum items, Instances with Parent/children, Parts whose
-- Position and CFrame stay linked, AlignPosition pulling its part (fraction responsiveness * dt
-- per simulated step), HumanoidDescription accessories, Humanoid apply and applied description,
-- RunService BindToSimulation / PreSimulation, Players and Workspace. It is not Roblox: passing
-- here proves the wiring, not engine behaviour (the probes stay pending until Studio runs them).
local FakeEnv = require("./FakeEnv")

local FakeEconomyEngine = {}

-- ------------------------------------------------------------------ Vector3

local Vector3 = {}
local V3 = {}

local function v3(x: number?, y: number?, z: number?): any
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
Vector3.new = v3

V3.__index = function(self: any, key: string): any
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	end
	return nil
end
V3.__add = function(a: any, b: any): any
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3.__sub = function(a: any, b: any): any
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3.__mul = function(a: any, b: any): any
	if type(a) == "number" then
		return v3(a * b.X, a * b.Y, a * b.Z)
	end
	return v3(a.X * b, a.Y * b, a.Z * b)
end
V3.__eq = function(a: any, b: any): boolean
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end

-- ------------------------------------------------------------------ CFrame (yaw only)

local CFrame = {}
local CF = {}

local function cf(position: any, yaw: number): any
	return setmetatable({ Position = position, _yaw = yaw }, CF)
end

CF.__index = function(self: any, key: string): any
	if key == "LookVector" then
		return v3(-math.sin(self._yaw), 0, -math.cos(self._yaw))
	elseif key == "X" then
		return self.Position.X
	elseif key == "Y" then
		return self.Position.Y
	elseif key == "Z" then
		return self.Position.Z
	end
	return nil
end

local function rotate(yaw: number, v: any): any
	local c, s = math.cos(yaw), math.sin(yaw)
	return v3(v.X * c + v.Z * s, v.Y, -v.X * s + v.Z * c)
end

CF.__mul = function(a: any, b: any): any
	if getmetatable(b) == V3 then
		return a.Position + rotate(a._yaw, b)
	end
	return cf(a.Position + rotate(a._yaw, b.Position), a._yaw + b._yaw)
end

function CFrame.new(x: any?, y: number?, z: number?): any
	if type(x) == "table" then
		return cf(v3(x.X, x.Y, x.Z), 0)
	end
	return cf(v3(x :: number?, y, z), 0)
end

function CFrame.Angles(rx: number, ry: number, rz: number): any
	assert(rx == 0 and rz == 0, "FakeEconomyEngine: CFrame.Angles supports yaw only")
	return cf(v3(), ry)
end

-- ------------------------------------------------------------------ Color3 and Enum

local Color3 = {}
function Color3.fromRGB(r: number, g: number, b: number): any
	return { R = r / 255, G = g / 255, B = b / 255 }
end
function Color3.new(r: number?, g: number?, b: number?): any
	return { R = r or 0, G = g or 0, B = b or 0 }
end

local ACCESSORY_TYPES = {
	"Unknown",
	"Hat",
	"Hair",
	"Face",
	"Neck",
	"Shoulder",
	"Front",
	"Back",
	"Waist",
	"TShirt",
	"Shirt",
	"Pants",
	"Jacket",
	"Sweater",
	"Shorts",
	"LeftShoe",
	"RightShoe",
	"DressSkirt",
	"Eyebrow",
	"Eyelash",
}

local function enumType(name: string, items: { string }?): any
	local cache = {}
	return setmetatable({}, {
		__index = function(_, item: string): any
			if items and not table.find(items, item) then
				error(string.format("%s is not a valid member of %s", tostring(item), name), 2)
			end
			cache[item] = cache[item] or table.freeze({ Name = item, EnumType = name })
			return cache[item]
		end,
	})
end

local Enum = setmetatable({ AccessoryType = enumType("AccessoryType", ACCESSORY_TYPES) }, {
	__index = function(self: any, name: string): any
		local made = enumType(name)
		rawset(self, name, made)
		return made
	end,
})

-- ------------------------------------------------------------------ Instances

local DESCRIPTION_DEFAULTS: { [string]: any } = {
	HeightScale = 1,
	WidthScale = 1,
	DepthScale = 1,
	HeadScale = 1,
	BodyTypeScale = 0,
	ProportionScale = 0,
}
for _, key in
	{
		"Head",
		"Torso",
		"LeftArm",
		"RightArm",
		"LeftLeg",
		"RightLeg",
		"Face",
		"Shirt",
		"Pants",
		"GraphicTShirt",
	}
do
	DESCRIPTION_DEFAULTS[key] = 0
end
for _, key in { "Idle", "Walk", "Run", "Jump", "Fall", "Climb", "Swim", "Mood" } do
	DESCRIPTION_DEFAULTS[key .. "Animation"] = 0
end

export type Engine = {
	Instance: any,
	Vector3: any,
	CFrame: any,
	Color3: any,
	Enum: any,
	services: { [string]: any },
	created: { any },
	players: { any },
	applied: { string },
	simulate: (self: Engine, dt: number) -> (),
}

-- A fresh engine. options.applyAsync = false removes Humanoid.ApplyDescriptionAsync;
-- options.bindToSimulation = false removes RunService.BindToSimulation.
function FakeEconomyEngine.new(options: { applyAsync: boolean?, bindToSimulation: boolean? }?): Engine
	local opts = options or {}
	local engine: any = { created = {}, players = {}, applied = {} }
	local newInstance

	local function children(self: any): { any }
		return rawget(self, "_children")
	end

	local methods: { [string]: any } = {}
	function methods.IsA(self: any, class: string): boolean
		local own = self.ClassName
		return own == class or (class == "BasePart" and own == "Part") or class == "Instance"
	end
	function methods.GetChildren(self: any): { any }
		return table.clone(children(self))
	end
	function methods.FindFirstChild(self: any, name: string): any
		for _, child in children(self) do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	function methods.FindFirstChildOfClass(self: any, class: string): any
		for _, child in children(self) do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end
	function methods.Destroy(self: any)
		for _, child in table.clone(children(self)) do
			child:Destroy()
		end
		self.Parent = nil
		rawget(self, "_props").Destroyed = true
	end
	function methods.Clone(self: any): any
		local copy = newInstance(self.ClassName)
		for key, value in rawget(self, "_props") do
			if key ~= "Parent" then
				rawget(copy, "_props")[key] = value
			end
		end
		local accessories = rawget(self, "_accessories")
		if accessories then
			rawset(copy, "_accessories", table.clone(accessories))
		end
		return copy
	end
	function methods.PivotTo(self: any, frame: any)
		self.CFrame = frame
	end
	function methods.SetAccessories(self: any, list: { any }, includeRigid: boolean)
		assert(self.ClassName == "HumanoidDescription", "SetAccessories is a HumanoidDescription method")
		assert(includeRigid == true, "FakeEconomyEngine models SetAccessories(list, true) only")
		local copy = {}
		for _, accessory in list do
			assert(type(accessory.AccessoryType) == "table", "AccessoryType must be an Enum item")
			assert(type(accessory.AssetId) == "number", "AssetId must be a number")
			table.insert(copy, table.clone(accessory))
		end
		rawset(self, "_accessories", copy)
	end
	function methods.GetAccessories(self: any, _includeRigid: boolean): { any }
		local out = {}
		for _, accessory in rawget(self, "_accessories") or {} do
			table.insert(out, table.clone(accessory))
		end
		return out
	end
	function methods.ApplyDescription(self: any, description: any)
		assert(self.ClassName == "Humanoid", "ApplyDescription is a Humanoid method")
		assert(description.ClassName == "HumanoidDescription", "ApplyDescription needs a HumanoidDescription")
		rawset(self, "_applied", description:Clone())
		table.insert(engine.applied, "ApplyDescription")
	end
	function methods.ApplyDescriptionAsync(self: any, description: any)
		methods.ApplyDescription(self, description)
		engine.applied[#engine.applied] = "ApplyDescriptionAsync"
	end
	function methods.GetAppliedDescription(self: any): any
		local applied = rawget(self, "_applied")
		return if applied then applied:Clone() else newInstance("HumanoidDescription")
	end

	local function setParent(self: any, parent: any)
		local props = rawget(self, "_props")
		local old = props.Parent
		if old then
			local list = children(old)
			local at = table.find(list, self)
			if at then
				table.remove(list, at)
			end
		end
		props.Parent = parent
		if parent then
			table.insert(children(parent), self)
		end
	end

	local InstanceMeta = {
		__index = function(self: any, key: string): any
			local props = rawget(self, "_props")
			if
				key == "ApplyDescriptionAsync"
				and props.ClassName == "Humanoid"
				and opts.applyAsync == false
			then
				error("ApplyDescriptionAsync is not a valid member of Humanoid", 2)
			end
			if methods[key] then
				return methods[key]
			end
			local value = props[key]
			if value == nil and props.ClassName == "HumanoidDescription" then
				if DESCRIPTION_DEFAULTS[key] ~= nil then
					return DESCRIPTION_DEFAULTS[key]
				elseif string.match(key, "Color$") then
					return Color3.new(0.5, 0.5, 0.5)
				end
			end
			return value
		end,
		__newindex = function(self: any, key: string, value: any)
			local props = rawget(self, "_props")
			if key == "Parent" then
				setParent(self, value)
			elseif key == "Position" and props.CFrame ~= nil then
				props.Position = value
				props.CFrame = cf(value, props.CFrame._yaw)
			elseif key == "CFrame" and (props.ClassName == "Part" or props.ClassName == "Model") then
				props.CFrame = value
				props.Position = value.Position
			else
				props[key] = value
			end
		end,
	}

	function newInstance(className: string): any
		local props: { [string]: any } = { ClassName = className, Name = className }
		if className == "Part" then
			props.CFrame = cf(v3(), 0)
			props.Position = v3()
			props.Size = v3(4, 1, 2)
			props.Anchored = false
		end
		local instance = setmetatable({ _props = props, _children = {} }, InstanceMeta)
		table.insert(engine.created, instance)
		return instance
	end

	engine.Instance = { new = newInstance }
	engine.Vector3 = Vector3
	engine.CFrame = CFrame
	engine.Color3 = Color3
	engine.Enum = Enum

	local workspace = newInstance("Workspace")
	workspace.Name = "Workspace"

	local stepCallbacks: { { fn: any, live: boolean } } = {}
	local function connect(fn: any): any
		local entry = { fn = fn, live = true }
		table.insert(stepCallbacks, entry)
		return {
			Disconnect = function()
				entry.live = false
			end,
		}
	end
	local runService: any =
		{ PreSimulation = {
			Connect = function(_, fn: any): any
				return connect(fn)
			end,
		} }
	if opts.bindToSimulation ~= false then
		function runService.BindToSimulation(_self: any, fn: any): any
			return connect(fn)
		end
	end

	local players: any = {}
	function players.GetPlayers(_self: any): { any }
		return table.clone(engine.players)
	end
	function players.CreateHumanoidModelFromDescription(_self: any, description: any, _rigType: any): any
		local model = newInstance("Model")
		model.Name = "Rig"
		local root = newInstance("Part")
		root.Name = "HumanoidRootPart"
		root.Parent = model
		model.PrimaryPart = root
		local humanoid = newInstance("Humanoid")
		humanoid.Parent = model
		humanoid:ApplyDescription(description)
		table.remove(engine.applied)
		return model
	end

	engine.services = { Workspace = workspace, RunService = runService, Players = players }

	-- One simulation step: bound callbacks run with dt, then each AlignPosition pulls its part.
	function engine.simulate(_self: any, dt: number)
		for _, entry in table.clone(stepCallbacks) do
			if entry.live then
				entry.fn(dt)
			end
		end
		for _, instance in engine.created do
			local props = rawget(instance, "_props")
			if
				props.ClassName == "AlignPosition"
				and props.Parent
				and props.Position
				and not props.Destroyed
			then
				local part = props.Parent
				local pull = math.min(1, (props.Responsiveness or 10) * dt)
				part.Position = part.Position + (props.Position - part.Position) * pull
			end
		end
	end

	return engine
end

-- A FakeEnv wired to engine: env.roblox and env.services come from it.
function FakeEconomyEngine.env(engine: Engine, options: FakeEnv.Options?): any
	local merged: any = table.clone(options or {})
	merged.roblox = {
		Instance = engine.Instance,
		Vector3 = engine.Vector3,
		CFrame = engine.CFrame,
		Color3 = engine.Color3,
		Enum = engine.Enum,
	}
	merged.services = engine.services
	return FakeEnv.new(merged)
end

-- Runs the engine and env together for seconds at hz: simulate, advance, flush.
function FakeEconomyEngine.run(engine: Engine, env: any, seconds: number, hz: number?)
	local dt = 1 / (hz or 60)
	local steps = math.ceil(seconds / dt - 1e-9)
	for _ = 1, steps do
		engine:simulate(dt)
		env:advance(dt)
		env:flush()
	end
end

return FakeEconomyEngine
