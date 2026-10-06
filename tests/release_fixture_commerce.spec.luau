--!strict
-- Release fixture against GameKit/Commerce: the paid random products the release checker accepts
-- (fixtures/release/good, item A05) are the ones Commerce.canPrompt holds to the PolicyGate feature
-- paidRandomItems. Both read one tag, Commerce.RANDOM_TAG, which the starter's release checker
-- (templates/starter/tools/release_check.py RANDOM_TAG) repeats. Release item A03 accepts the top-level
-- keys Catalog.define accepts (release_check.py CATALOG_KEYS). Reads repo files by relative path, so it
-- runs from the repo root like the rest of tests/run.luau. Synthetic ids only; nothing is prompted.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Catalog = require("../packages/GameKit/Catalog")
local Commerce = require("../packages/GameKit/Commerce")

local GOOD = "fixtures/release/good/"
local RELEASE_CHECK = "templates/starter/tools/release_check.py"

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

local function readJson(path: string): any
	return serde.decode("json", fs.readFile(path))
end

local function declaredRandomProducts(): { string }
	local out = {}
	for _, entry in readJson(GOOD .. "release/release.json").paid_random_items do
		table.insert(out, entry.product)
	end
	return out
end

local function allow(_feature: string): boolean
	return true
end

local function deny(_feature: string): boolean
	return false
end

test("the release checker tags paid random products with Commerce.RANDOM_TAG", function(t)
	local source = fs.readFile(RELEASE_CHECK)
	local tag = string.match(source, '\nRANDOM_TAG = "([^"]+)"')
	t.eq(tag, Commerce.RANDOM_TAG, "release_check.py RANDOM_TAG")
end)

test("every paid random product of the release fixture needs PolicyGate paidRandomItems", function(t)
	local catalog = Catalog.define(readJson(GOOD .. "src/shared/catalog.json"))
	local declared = declaredRandomProducts()
	t.ok(#declared > 0, "the good release fixture declares a paid random item")
	for _, key in declared do
		local product = Catalog.find(catalog, key)
		t.ok(product ~= nil, key .. " is in the fixture catalog")
		t.eq(Commerce.features(product :: any), { "paidRandomItems" }, key .. " features")
		-- fail closed: no policy, or a policy that restricts paid random items, refuses the prompt
		t.eq({ Commerce.canPrompt(catalog, key) }, { false, "policy_unknown", "paidRandomItems" }, key)
		t.eq(
			{ Commerce.canPrompt(catalog, key, { policy = deny }) },
			{ false, "policy_denied", "paidRandomItems" },
			key
		)
		t.eq(select(1, Commerce.canPrompt(catalog, key, { policy = allow })), true, key .. " with policy")
	end
end)

test("a product tagged with any other spelling is not gated as a paid random item", function(t)
	local data = readJson(GOOD .. "src/shared/catalog.json")
	local key = declaredRandomProducts()[1]
	for _, product in data.products do
		if product.key == key then
			product.tags = { "paid_random" } -- the release runbook's former tag
		end
	end
	local catalog = Catalog.define(data)
	t.eq(Commerce.features(Catalog.find(catalog, key) :: any), {}, "untagged features")
	t.eq(select(1, Commerce.canPrompt(catalog, key)), true, "prompts with no policy at all")
end)

test("Catalog.define rejects every top-level key the release checker's CATALOG_KEYS leaves out", function(t)
	local listed = string.match(fs.readFile(RELEASE_CHECK), "\nCATALOG_KEYS = (%b())")
	t.ok(listed ~= nil, "release_check.py CATALOG_KEYS")
	local allowed: { [string]: boolean } = {}
	for key in string.gmatch(listed or "", '"(%w+)"') do
		allowed[key] = true
	end
	local function unexpected(data: any): boolean
		for _, problem in Catalog.validate(data) do
			if string.find(problem, "unexpected key", 1, true) then
				return true
			end
		end
		return false
	end
	local good = readJson(GOOD .. "src/shared/catalog.json")
	t.ok(not unexpected(good), "the good fixture's top-level keys")
	for key in good do
		t.ok(allowed[key] == true, key .. " is in the fixture but not in CATALOG_KEYS")
	end
	for _, key in { "schema", "mode", "products", "note", "version", "currency" } do
		if good[key] == nil then
			local data = readJson(GOOD .. "src/shared/catalog.json")
			data[key] = "synthetic"
			t.eq(unexpected(data), not allowed[key], key .. ": Catalog.validate and CATALOG_KEYS agree")
			t.eq(pcall(Catalog.define, data), allowed[key] == true, key .. ": Catalog.define")
		end
	end
end)

return cases
