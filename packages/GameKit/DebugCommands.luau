--!strict
-- @tier T0
-- DebugCommands: a registry of developer commands that is active only on the unpublished
-- diagnostic place: Env.check(env.place) must pass (Studio, GameId 0, PlaceId 0), checked when
-- the registry is made and again on every run. Anywhere else (a published game or place, a live
-- server, a missing place) the registry is inert: commands may be registered, but run() refuses
-- with "inactive:<reason>" and nothing executes. The starter's release check (A17) calls
-- DebugCommands.status(env) on the release env and requires active = false.
--   local commands = DebugCommands.new(env)
--   commands:register("set_value", { description = "...", args = { { name = "amount", kind = "number", min = 0 } },
--       run = function(ctx, args) return args.amount end })
--   commands:run("set_value 5")            --> true, 5   (or false, "inactive:published_game")
-- Arguments are parsed from a line (whitespace separated, "double quotes" group words) or given as a
-- list of strings, then checked against each spec (number with min/max, integer, boolean, string
-- with maxLength, enum with choices). A command that raises returns (false, "error: ...") and
-- reports through env.report. The last 32 runs are kept in history(). No Roblox globals: a chat or
-- console adapter feeds lines in.
local Env = require("./Env")

local DebugCommands = {}

DebugCommands.HISTORY = 32
DebugCommands.MAX_COMMANDS = 128
DebugCommands.MAX_ARGS = 16
DebugCommands.MAX_LINE = 512

local KINDS = { number = true, integer = true, boolean = true, string = true, enum = true }
local LABEL = "^[a-z][a-z0-9_]*$"

export type ArgSpec = {
	name: string,
	kind: string,
	optional: boolean?,
	min: number?,
	max: number?,
	maxLength: number?,
	choices: { string }?,
}
export type Command = {
	description: string?,
	args: { ArgSpec }?,
	run: (ctx: any, args: { [string]: any }) -> any,
}

local function isLabel(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, LABEL) ~= nil
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

-- { active, reason }: whether a registry made with this env would run commands.
function DebugCommands.status(env: any): { active: boolean, reason: string? }
	local place = if type(env) == "table" then env.place else nil
	local ok, reason = Env.check(place)
	return { active = ok, reason = reason }
end

-- Splits a command line into words; "double quoted" text is one word (\" inside quotes is a quote).
-- Returns (words) or (nil, reason).
function DebugCommands.parse(line: string): ({ string }?, string?)
	if type(line) ~= "string" then
		return nil, "line must be a string"
	end
	if #line > DebugCommands.MAX_LINE then
		return nil, "line is longer than " .. DebugCommands.MAX_LINE .. " characters"
	end
	local words: { string } = {}
	local index, length = 1, #line
	while index <= length do
		local char = string.sub(line, index, index)
		if string.match(char, "%s") then
			index += 1
		elseif char == '"' then
			local parts: { string } = {}
			local position = index + 1
			local closed = false
			while position <= length do
				local c = string.sub(line, position, position)
				if c == "\\" and string.sub(line, position + 1, position + 1) == '"' then
					table.insert(parts, '"')
					position += 2
				elseif c == '"' then
					closed = true
					break
				else
					table.insert(parts, c)
					position += 1
				end
			end
			if not closed then
				return nil, "unclosed quote"
			end
			table.insert(words, table.concat(parts))
			index = position + 1
		else
			local stop = string.find(line, '[%s"]', index) or (length + 1)
			table.insert(words, string.sub(line, index, stop - 1))
			index = stop
		end
	end
	return words, nil
end

local function specProblems(name: string, command: any): { string }
	local problems = {}
	if not isLabel(name) then
		table.insert(problems, "command name must be a lower_snake label")
	end
	if type(command) ~= "table" or type(command.run) ~= "function" then
		table.insert(problems, "command needs a run function")
		return problems
	end
	if
		command.description ~= nil and (type(command.description) ~= "string" or #command.description > 200)
	then
		table.insert(problems, "description must be a string of at most 200 characters")
	end
	local args = command.args or {}
	if type(args) ~= "table" or #args > DebugCommands.MAX_ARGS then
		table.insert(problems, "args must be a list of at most " .. DebugCommands.MAX_ARGS .. " specs")
		return problems
	end
	local seen, optionalSeen = {}, false
	for index, spec in args do
		local where = "args[" .. index .. "]"
		if type(spec) ~= "table" or not isLabel(spec.name) then
			table.insert(problems, where .. " needs a label name")
			continue
		end
		if seen[spec.name] then
			table.insert(problems, where .. " duplicates " .. spec.name)
		end
		seen[spec.name] = true
		if not KINDS[spec.kind] then
			table.insert(problems, where .. " kind must be number, integer, boolean, string or enum")
		end
		if spec.kind == "enum" and (type(spec.choices) ~= "table" or #spec.choices == 0) then
			table.insert(problems, where .. " enum needs choices")
		end
		for _, key in { "min", "max" } do
			if spec[key] ~= nil and not finite(spec[key]) then
				table.insert(problems, where .. " " .. key .. " must be finite")
			end
		end
		if finite(spec.min) and finite(spec.max) and spec.min > spec.max then
			table.insert(problems, where .. " min is above max")
		end
		if spec.optional then
			optionalSeen = true
		elseif optionalSeen then
			table.insert(problems, where .. " is required after an optional argument")
		end
	end
	return problems
end

local function convert(spec: ArgSpec, raw: string): (any, string?)
	if spec.kind == "number" or spec.kind == "integer" then
		local value = tonumber(raw)
		if not finite(value) then
			return nil, spec.name .. " must be a number"
		end
		if spec.kind == "integer" and (value :: number) % 1 ~= 0 then
			return nil, spec.name .. " must be a whole number"
		end
		if spec.min ~= nil and (value :: number) < spec.min then
			return nil, spec.name .. " must be at least " .. tostring(spec.min)
		end
		if spec.max ~= nil and (value :: number) > spec.max then
			return nil, spec.name .. " must be at most " .. tostring(spec.max)
		end
		return value, nil
	elseif spec.kind == "boolean" then
		local lowered = string.lower(raw)
		if lowered == "true" or lowered == "on" or lowered == "1" then
			return true, nil
		elseif lowered == "false" or lowered == "off" or lowered == "0" then
			return false, nil
		end
		return nil, spec.name .. " must be true or false"
	elseif spec.kind == "enum" then
		if table.find(spec.choices :: { string }, raw) then
			return raw, nil
		end
		return nil, spec.name .. " must be one of " .. table.concat(spec.choices :: { string }, ", ")
	end
	if #raw > (spec.maxLength or 128) then
		return nil, spec.name .. " is longer than " .. tostring(spec.maxLength or 128) .. " characters"
	end
	return raw, nil
end

function DebugCommands.new(env: any, options: { allow: ((caller: any) -> boolean)? }?): any
	assert(type(env) == "table", "DebugCommands.new: env must be a table")
	local commands: { [string]: Command } = {}
	local count = 0
	local history: { any } = {}
	local allow = options and options.allow
	local registry: any = {}

	local function record(entry: any)
		table.insert(history, entry)
		if #history > DebugCommands.HISTORY then
			table.remove(history, 1)
		end
	end

	-- (active, reason) right now.
	function registry.active(_: any): (boolean, string?)
		return Env.check(env.place)
	end

	function registry.register(_: any, name: string, command: Command)
		local problems = specProblems(name, command)
		if commands[name] then
			table.insert(problems, "command " .. tostring(name) .. " is already registered")
		end
		if count >= DebugCommands.MAX_COMMANDS and not commands[name] then
			table.insert(problems, "more than " .. DebugCommands.MAX_COMMANDS .. " commands")
		end
		if #problems > 0 then
			error("DebugCommands.register: " .. table.concat(problems, "; "), 2)
		end
		commands[name] = {
			description = command.description,
			args = table.clone(command.args or {}),
			run = command.run,
		}
		count += 1
	end

	-- Sorted { { name, description, args } } for a help listing.
	function registry.list(_: any): { any }
		local out = {}
		for name, command in commands do
			table.insert(out, { name = name, description = command.description, args = command.args })
		end
		table.sort(out, function(a, b)
			return a.name < b.name
		end)
		return out
	end

	function registry.history(_: any): { any }
		return table.clone(history)
	end

	-- run(line) or run(name, { "arg", ... }); returns (true, result) or (false, reason).
	function registry.run(_: any, nameOrLine: string, rawArgs: { string }?, caller: any?): (boolean, any)
		local ok, reason = Env.check(env.place)
		if not ok then
			return false, "inactive:" .. tostring(reason)
		end
		if allow and not allow(caller) then
			return false, "caller_not_allowed"
		end
		local name, words = nameOrLine, rawArgs
		if words == nil then
			local parsed, why = DebugCommands.parse(nameOrLine)
			if parsed == nil then
				return false, "bad_line: " .. tostring(why)
			end
			if #parsed == 0 then
				return false, "empty_line"
			end
			name = table.remove(parsed, 1) :: string
			words = parsed
		end
		local command = commands[name]
		if command == nil then
			return false, "unknown_command: " .. tostring(name)
		end
		local specs = command.args or {}
		local given = words :: { string }
		if #given > #specs then
			return false, string.format("too_many_args: %s takes at most %d", name, #specs)
		end
		local args: { [string]: any } = {}
		for index, spec in specs do
			local raw = given[index]
			if raw == nil then
				if not spec.optional then
					return false, "missing_arg: " .. spec.name
				end
				continue
			end
			local value, problem = convert(spec, raw)
			if problem then
				return false, "bad_arg: " .. problem
			end
			args[spec.name] = value
		end
		local clock = env.clock
		local started = if type(clock) == "function" then clock() else nil
		local ran, result = pcall(command.run, { env = env, name = name, caller = caller }, args)
		record({ name = name, ok = ran, t = started })
		if not ran then
			local message = "error: " .. tostring(result)
			if type(env.report) == "function" then
				env.report("DebugCommands." .. name .. " " .. message)
			end
			return false, message
		end
		return true, result
	end

	return registry
end

return DebugCommands
