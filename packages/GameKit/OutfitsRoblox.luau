--!strict
-- @tier T3
-- probe: economy_outfits_apply
-- OutfitsRoblox: applies GameKit/Outfits plans to Humanoids. toInstance(plan, env, base?) builds a
-- HumanoidDescription (cloned from base when given, so a partial outfit patches it): plain
-- properties are assigned, colors become Color3.fromRGB, and a plan's accessory list goes through
-- SetAccessories(list, true) (rigid and layered together). apply(humanoid, outfit, rules, env)
-- validates, patches humanoid:GetAppliedDescription() and applies it with ApplyDescriptionAsync
-- where the engine has it, else ApplyDescription; both yield, so call apply from a thread that may
-- yield, on the server for player characters. snapshot()/read() map a description back to an
-- outfit. Which apply method the engine offers is checked by the probe (UNVERIFIED until run).
local Outfits = require("./Outfits")

local OutfitsRoblox = {}

local function roblox(env: any): any
	assert(env and env.roblox, "OutfitsRoblox needs env.roblox (EnvRoblox.studio())")
	return env.roblox
end

-- A HumanoidDescription for plan (a fresh one, or a clone of base).
function OutfitsRoblox.toInstance(plan: Outfits.Plan, env: any, base: any?): any
	local r = roblox(env)
	local description = if base ~= nil then base:Clone() else r.Instance.new("HumanoidDescription")
	for property, value in plan.properties do
		if type(value) == "table" then
			description[property] = r.Color3.fromRGB(value.r, value.g, value.b)
		else
			description[property] = value
		end
	end
	if plan.accessories ~= nil then
		local list = {}
		for _, accessory in plan.accessories do
			table.insert(list, {
				AccessoryType = r.Enum.AccessoryType[accessory.AccessoryType],
				AssetId = accessory.AssetId,
				IsLayered = accessory.IsLayered,
				Order = accessory.Order,
				Puffiness = accessory.Puffiness,
			})
		end
		description:SetAccessories(list, true)
	end
	return description
end

local function channel(value: number): number
	return math.clamp(math.round(value * 255), 0, 255)
end

-- A plain snapshot { properties, accessories } of a HumanoidDescription for Outfits.fromDescription.
function OutfitsRoblox.snapshot(description: any): any
	local properties = {}
	for _, key in Outfits.BODY do
		properties[key] = description[key]
	end
	for _, key in Outfits.CLOTHING do
		properties[key] = description[key]
	end
	for _, key in Outfits.ANIMATIONS do
		properties[key .. "Animation"] = description[key .. "Animation"]
	end
	for _, property in Outfits.COLORS do
		local color = description[property]
		properties[property] = { r = channel(color.R), g = channel(color.G), b = channel(color.B) }
	end
	for _, property in Outfits.SCALES do
		properties[property] = description[property]
	end
	local accessories = {}
	for _, accessory in description:GetAccessories(true) do
		table.insert(accessories, {
			AccessoryType = accessory.AccessoryType.Name,
			AssetId = accessory.AssetId,
			IsLayered = accessory.IsLayered,
			Order = accessory.Order,
			Puffiness = accessory.Puffiness,
		})
	end
	return { properties = properties, accessories = accessories }
end

-- The outfit a humanoid wears now.
function OutfitsRoblox.read(humanoid: any): Outfits.Outfit
	return Outfits.fromDescription(OutfitsRoblox.snapshot(humanoid:GetAppliedDescription()))
end

-- Validates outfit and applies it over the humanoid's current description. Yields.
-- (true, method) with "ApplyDescriptionAsync" or "ApplyDescription", or (false, reason) with
-- invalid_outfit (problems in the third value) or apply_failed (the engine error).
function OutfitsRoblox.apply(
	humanoid: any,
	outfit: Outfits.Outfit,
	rules: Outfits.Rules?,
	env: any
): (boolean, string, any)
	local problems = Outfits.validate(outfit, rules)
	if #problems > 0 then
		return false, "invalid_outfit", problems
	end
	local plan = Outfits.toDescription(outfit, rules)
	local description = OutfitsRoblox.toInstance(plan, env, humanoid:GetAppliedDescription())
	-- Indexing a member the engine lacks raises, so probe it inside pcall.
	local indexed, async = pcall(function(): any
		return humanoid.ApplyDescriptionAsync
	end)
	local method = if indexed and async ~= nil then "ApplyDescriptionAsync" else "ApplyDescription"
	local ok, err = pcall(function()
		humanoid[method](humanoid, description)
	end)
	if not ok then
		return false, "apply_failed", err
	end
	return true, method, nil
end

return OutfitsRoblox
