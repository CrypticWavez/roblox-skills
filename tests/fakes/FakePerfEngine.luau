--!strict
-- FakePerfEngine (G9b): the engine surface Diagnostics/PerfProbeRoblox reads, for Lune specs.
--   stats(options)      a Stats-like service: GetTotalMemoryUsageMb, GetMemoryUsageMbForTag(tag),
--                       InstanceCount, SceneTriangleCount (each may be left out or made to raise)
--   tag(name)           a DeveloperMemoryTag-like item ({ Name = name })
--   instance(class, props, ancestors?)  an Instance-like table whose IsA knows the class chain
--   folder(children)    a root with GetDescendants
--   runService(options?) RunService-like with a Heartbeat signal; fire(dt) runs its handlers;
--                       IsRunning() is options.running (default true: a play session)
-- Values are plain data so a spec states exactly what the engine "reported".
local FakePerfEngine = {}

local CHAINS: { [string]: { string } } = {
	Part = { "Part", "BasePart" },
	MeshPart = { "MeshPart", "BasePart" },
	PointLight = { "PointLight", "Light" },
	SpotLight = { "SpotLight", "Light" },
	ParticleEmitter = { "ParticleEmitter" },
	Sound = { "Sound" },
	AudioPlayer = { "AudioPlayer" },
	Highlight = { "Highlight" },
	Folder = { "Folder" },
}

function FakePerfEngine.tag(name: string): any
	return { Name = name }
end

function FakePerfEngine.stats(options: { [string]: any }): any
	local stats: any = {}
	local byTag = options.byTag or {}
	if options.total ~= nil then
		function stats.GetTotalMemoryUsageMb(_: any): number
			if options.total == "raise" then
				error("not available")
			end
			return options.total
		end
	end
	function stats.GetMemoryUsageMbForTag(_: any, tag: any): number
		local value = byTag[tag.Name]
		if value == "raise" then
			error("tag not available")
		end
		return value
	end
	stats.InstanceCount = options.instances
	stats.SceneTriangleCount = options.triangles
	return stats
end

function FakePerfEngine.instance(className: string, props: { [string]: any }?): any
	local chain = CHAINS[className] or { className }
	local object: any = table.clone(props or {})
	object.ClassName = className
	function object.IsA(_: any, name: string): boolean
		return table.find(chain, name) ~= nil
	end
	return object
end

function FakePerfEngine.folder(children: { any }): any
	return {
		GetDescendants = function(_: any): { any }
			return table.clone(children)
		end,
	}
end

function FakePerfEngine.runService(options: { running: boolean? }?): any
	local running = not (options and options.running == false)
	local handlers: { (number) -> () } = {}
	local heartbeat: any = {}
	function heartbeat.Connect(_: any, fn: (number) -> ()): any
		table.insert(handlers, fn)
		local connection: any = { Connected = true }
		function connection.Disconnect(_: any)
			connection.Connected = false
			local index = table.find(handlers, fn)
			if index then
				table.remove(handlers, index)
			end
		end
		return connection
	end
	local service: any = { Heartbeat = heartbeat }
	function service.fire(_: any, dt: number)
		for _, fn in table.clone(handlers) do
			fn(dt)
		end
	end
	function service.listeners(_: any): number
		return #handlers
	end
	function service.IsRunning(_: any): boolean
		return running
	end
	return service
end

return FakePerfEngine
