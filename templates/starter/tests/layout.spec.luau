--!strict
-- Layout spec: builds the place with `rojo build default.project.json` (into build/layout-spec.rbxl),
-- deserialises it with @lune/roblox and checks that
--   * every package sits in its class's home (starter.json): authoring in ServerStorage.Authoring
--     (never replicated), kits in ReplicatedStorage.Kits with the leaf copies Kits/ProcGen/{Rng,Grid,Graph}
--     and Kits/SceneKit/{Vec,Lighting}, legacy in ReplicatedStorage.Legacy;
--   * the boot skeleton is where the entry scripts look for it;
--   * every require in every script resolves statically to a ModuleScript in the built place: string
--     requires ("./X", "../X", "@self/X", "@game/Service/X") and script chains (script.Parent.X,
--     script:WaitForChild("X")). Requires of other expressions are dynamic and only counted.
-- Wally folders (Packages, ServerPackages, DevPackages) hold generated linkers and are not scanned.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local PLACE = "build/layout-spec.rbxl"
local WALLY = { Packages = true, ServerPackages = true, DevPackages = true }
local HOMES = {
	authoring = { "ServerStorage", "Authoring" },
	kits = { "ReplicatedStorage", "Kits" },
	legacy = { "ReplicatedStorage", "Legacy" },
}
local LEAVES = { ProcGen = { "Rng", "Grid", "Graph" }, SceneKit = { "Vec", "Lighting" } }

local starter = serde.decode("json", fs.readFile("starter.json"))

local cases = {}
local function test(name: string, fn: (t: any) -> ())
	table.insert(cases, { name = name, fn = fn })
end

-- Build once, before any case runs; a build failure fails every case with rojo's message.
local game: any = nil
local buildError: string? = nil
do
	if not fs.isDir("build") then
		fs.writeDir("build")
	end
	local ok, result = pcall(process.exec, "rojo", { "build", "default.project.json", "-o", PLACE })
	if not ok then
		buildError = "rojo is not on PATH (rokit install): " .. tostring(result)
	elseif not result.ok then
		buildError = "rojo build failed: " .. result.stderr .. result.stdout
	else
		game = roblox.deserializePlace(fs.readFile(PLACE))
	end
end

local function place(t: any): any
	t.ok(game ~= nil, buildError or "no place")
	return game
end

local function child(parent: any, names: { string }): any
	local node = parent
	for _, name in names do
		if node == nil then
			return nil
		end
		node = node:FindFirstChild(name)
	end
	return node
end

-- Source with comments removed (strings kept), so commented-out requires are ignored.
local function stripComments(source: string): string
	local out = {}
	local index, length = 1, #source
	while index <= length do
		local char = string.sub(source, index, index)
		if char == "-" and string.sub(source, index, index + 1) == "--" then
			local level = string.match(source, "^%[(=*)%[", index + 2)
			local stop
			if level then
				local _, close = string.find(source, "]" .. level .. "]", index, true)
				stop = close or length
			else
				stop = (string.find(source, "\n", index, true) or (length + 1)) - 1
			end
			index = stop + 1
		elseif char == '"' or char == "'" or char == "`" then
			local stop = index + 1
			while stop <= length do
				local c = string.sub(source, stop, stop)
				if c == "\\" then
					stop += 2
				elseif c == char then
					break
				else
					stop += 1
				end
			end
			table.insert(out, string.sub(source, index, stop))
			index = stop + 1
		else
			table.insert(out, char)
			index += 1
		end
	end
	return table.concat(out)
end

-- (target instance?, why?) for one require argument relative to the requiring script.
local function resolve(script: any, argument: string): (any, string?)
	local text = string.match(argument, "^%s*(.-)%s*$") or argument
	local path = string.match(text, '^"(.*)"$') or string.match(text, "^'(.*)'$")
	if path then
		local node
		local rest
		if string.sub(path, 1, 6) == "@self/" then
			node, rest = script, string.sub(path, 7)
		elseif string.sub(path, 1, 6) == "@game/" then
			node, rest = game, string.sub(path, 7)
		elseif string.sub(path, 1, 2) == "./" then
			node, rest = script.Parent, string.sub(path, 3)
		elseif string.sub(path, 1, 3) == "../" then
			node, rest = script.Parent and script.Parent.Parent, string.sub(path, 4)
		else
			return nil, "unsupported require path " .. path
		end
		for part in string.gmatch(rest, "[^/]+") do
			if node == nil then
				break
			end
			if part == ".." then
				node = node.Parent
			elseif part ~= "." then
				node = node:FindFirstChild(part)
			end
		end
		return node, if node == nil then "missing " .. path else nil
	end
	if string.sub(text, 1, 6) ~= "script" then
		return nil, nil -- dynamic
	end
	local node, rest = script, string.sub(text, 7)
	while #rest > 0 do
		local name
		if string.sub(rest, 1, 7) == ".Parent" and not string.match(rest, "^%.Parent[%w_]") then
			node, rest = node and node.Parent, string.sub(rest, 8)
		else
			name = string.match(rest, "^%.([%a_][%w_]*)")
			local consumed = name and #name + 1
			if not name then
				local a, b = string.match(rest, '^:WaitForChild%(%s*"([^"]+)"[^)]*%)()')
				name, consumed = a, b and (b - 1)
			end
			if not name then
				local a, b = string.match(rest, '^:FindFirstChild%(%s*"([^"]+)"%s*%)()')
				name, consumed = a, b and (b - 1)
			end
			if not name then
				local a, b = string.match(rest, '^%[%s*"([^"]+)"%s*%]()')
				name, consumed = a, b and (b - 1)
			end
			if not name then
				return nil, nil -- dynamic part (a variable index or call)
			end
			node, rest = node and node:FindFirstChild(name), string.sub(rest, (consumed :: number) + 1)
		end
	end
	return node, if node == nil then "missing " .. text else nil
end

local function scripts(root: any): { any }
	local out = {}
	local function walk(node: any)
		if WALLY[node.Name] and node.Parent ~= nil and node.Parent.Parent == root then
			return
		end
		if node:IsA("LuaSourceContainer") then
			table.insert(out, node)
		end
		for _, item in node:GetChildren() do
			walk(item)
		end
	end
	for _, service in root:GetChildren() do
		walk(service)
	end
	return out
end

local function fullName(node: any): string
	local parts = {}
	while node ~= nil and node.Parent ~= nil do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, ".")
end

test("every package sits in its class's home and authoring code never replicates", function(t)
	local root = place(t)
	local count = 0
	for name, record in starter.packages do
		local home = HOMES[record.class]
		t.ok(home ~= nil, name .. ": unknown class " .. tostring(record.class))
		local folder = child(root, { home[1], home[2], name })
		t.ok(folder ~= nil, `{name} missing from {home[1]}.{home[2]}`)
		if record.class == "authoring" then
			t.ok(
				child(root, { "ReplicatedStorage", "Workbench", name }) == nil,
				name .. " replicates via Workbench"
			)
		end
		count += 1
	end
	t.ok(count > 0, "starter.json lists no packages")
end)

test("kits get the leaf copies they require", function(t)
	local root = place(t)
	local hasKit = false
	for _, record in starter.packages do
		hasKit = hasKit or record.class == "kits"
	end
	local kits = child(root, { "ReplicatedStorage", "Kits" })
	if not hasKit then
		t.ok(kits == nil, "Kits folder without kits")
		return
	end
	for pkg, modules in LEAVES do
		if starter.packages[pkg] then
			for _, module in modules do
				if fs.isFile(`packages/{pkg}/{module}.luau`) then
					local leaf = child(kits, { pkg, module })
					t.ok(leaf ~= nil and leaf:IsA("ModuleScript"), `Kits/{pkg}/{module} missing`)
				end
			end
		end
	end
end)

test("the boot skeleton is where the entry scripts look for it", function(t)
	local root = place(t)
	for _, module in { "Boot", "Config", "KitLoader" } do
		local found = child(root, { "ReplicatedStorage", "Shared", module })
		t.ok(found ~= nil and found:IsA("ModuleScript"), "ReplicatedStorage.Shared." .. module)
	end
	local server = child(root, { "ServerScriptService", "Server" })
	t.ok(server ~= nil and server.ClassName == "Script", "ServerScriptService.Server is a Script")
	t.ok(child(server, { "Phases" }) ~= nil, "server Phases")
	local client = child(root, { "StarterPlayer", "StarterPlayerScripts", "Client" })
	t.ok(client ~= nil and client.ClassName == "LocalScript", "StarterPlayerScripts.Client is a LocalScript")
	t.ok(child(client, { "Phases" }) ~= nil, "client Phases")
	local loading = child(root, { "ReplicatedFirst", "Loading", "Loading" })
	t.ok(loading ~= nil and loading.ClassName == "LocalScript", "ReplicatedFirst.Loading.Loading")
	t.ok(child(root, { "StarterGui" }) ~= nil, "StarterGui")
	t.ok(child(root, { "ServerStorage", "Assets" }) ~= nil, "ServerStorage.Assets")
end)

test("every static require in the place resolves to a ModuleScript", function(t)
	local root = place(t)
	local problems, resolved, dynamic = {}, 0, 0
	for _, script in scripts(root) do
		local source = stripComments(script.Source)
		for argument in string.gmatch(source, "require%s*(%b())") do
			local inner = string.sub(argument, 2, -2)
			local target, why = resolve(script, inner)
			if target == nil and why == nil then
				dynamic += 1
			elseif target == nil then
				table.insert(problems, `{fullName(script)}: {why}`)
			elseif not target:IsA("ModuleScript") then
				table.insert(problems, `{fullName(script)}: {inner} is a {target.ClassName}`)
			else
				resolved += 1
			end
		end
	end
	table.sort(problems)
	t.ok(#problems == 0, table.concat(problems, "\n"))
	t.ok(resolved > 0, "no static require found")
end)

test("the resolver itself catches broken requires", function(t)
	local root = place(t)
	local boot = child(root, { "ReplicatedStorage", "Shared", "Boot" })
	t.ok(select(1, resolve(boot, '"./Config"')) ~= nil, "sibling")
	t.eq(select(2, resolve(boot, '"./Nope"')), "missing ./Nope", "missing sibling")
	t.eq(select(2, resolve(boot, '"@lune/fs"')), "unsupported require path @lune/fs", "alias")
	t.ok(select(1, resolve(boot, "script.Parent.KitLoader")) ~= nil, "script chain")
	t.eq(
		select(2, resolve(boot, 'script.Parent:WaitForChild("Nope")')),
		'missing script.Parent:WaitForChild("Nope")',
		"chain"
	)
	t.eq({ resolve(boot, "someVariable") }, {}, "dynamic")
	t.eq(stripComments('a -- require("x")\nb --[[ require("y") ]] "--keep"'), 'a \nb  "--keep"', "comments")
end)

return cases
