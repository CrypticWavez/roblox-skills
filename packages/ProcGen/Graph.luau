--!strict
-- Undirected layout graph plus the analyses the validators need:
-- BFS distances, components, bridges (non-redundant edges), dead ends and cycle rank.
local Graph = {}
Graph.__index = Graph

export type Node = { id: string, kind: string?, tags: { [string]: any }? }
export type Graph = typeof(setmetatable(
	{} :: {
		nodes: { [string]: Node },
		order: { string },
		adjacency: { [string]: { string } },
		edgeCount: number,
	},
	Graph
))

function Graph.new(): Graph
	return setmetatable({ nodes = {}, order = {}, adjacency = {}, edgeCount = 0 }, Graph)
end

function Graph.addNode(self: Graph, id: string, kind: string?, tags: { [string]: any }?): Node
	assert(self.nodes[id] == nil, "duplicate node " .. id)
	local node = { id = id, kind = kind, tags = tags or {} }
	self.nodes[id] = node
	table.insert(self.order, id)
	self.adjacency[id] = {}
	return node
end

function Graph.hasEdge(self: Graph, a: string, b: string): boolean
	for _, other in self.adjacency[a] or {} do
		if other == b then
			return true
		end
	end
	return false
end

function Graph.addEdge(self: Graph, a: string, b: string)
	assert(self.nodes[a] and self.nodes[b], "edge references unknown node")
	assert(a ~= b, "self loop")
	if self:hasEdge(a, b) then
		return
	end
	table.insert(self.adjacency[a], b)
	table.insert(self.adjacency[b], a)
	self.edgeCount += 1
end

function Graph.degree(self: Graph, id: string): number
	return #self.adjacency[id]
end

-- Hop distances from `start`; unreachable nodes are absent.
function Graph.distances(self: Graph, start: string): { [string]: number }
	local dist = { [start] = 0 }
	local queue, head = { start }, 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, other in self.adjacency[current] do
			if dist[other] == nil then
				dist[other] = dist[current] + 1
				table.insert(queue, other)
			end
		end
	end
	return dist
end

function Graph.shortestPath(self: Graph, from: string, to: string): { string }?
	local previous: { [string]: string } = {}
	local seen = { [from] = true }
	local queue, head = { from }, 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		if current == to then
			local path = { to }
			while path[1] ~= from do
				table.insert(path, 1, previous[path[1]])
			end
			return path
		end
		for _, other in self.adjacency[current] do
			if not seen[other] then
				seen[other] = true
				previous[other] = current
				table.insert(queue, other)
			end
		end
	end
	return nil
end

function Graph.components(self: Graph): { { string } }
	local seen: { [string]: boolean } = {}
	local result = {}
	for _, id in self.order do
		if not seen[id] then
			local component = {}
			for other in self:distances(id) do
				seen[other] = true
				table.insert(component, other)
			end
			table.sort(component)
			table.insert(result, component)
		end
	end
	return result
end

-- Bridges are edges whose removal disconnects the graph: paths without redundancy.
function Graph.bridges(self: Graph): { { string } }
	local index, low = {}, {}
	local counter = 0
	local result = {}
	local function visit(node: string, parent: string?)
		counter += 1
		index[node], low[node] = counter, counter
		for _, other in self.adjacency[node] do
			if index[other] == nil then
				visit(other, node)
				low[node] = math.min(low[node], low[other])
				if low[other] > index[node] then
					local pair = { node, other }
					table.sort(pair)
					table.insert(result, pair)
				end
			elseif other ~= parent then
				low[node] = math.min(low[node], index[other])
			end
		end
	end
	for _, id in self.order do
		if index[id] == nil then
			visit(id, nil)
		end
	end
	table.sort(result, function(a, b)
		return a[1] .. "|" .. a[2] < b[1] .. "|" .. b[2]
	end)
	return result
end

function Graph.deadEnds(self: Graph): { string }
	local result = {}
	for _, id in self.order do
		if #self.adjacency[id] == 1 then
			table.insert(result, id)
		end
	end
	return result
end

-- Independent cycles (loops) = E - V + C.
function Graph.cycleRank(self: Graph): number
	return self.edgeCount - #self.order + #self:components()
end

function Graph.toTable(self: Graph): { nodes: { Node }, edges: { { string } } }
	local nodes, edges = {}, {}
	for _, id in self.order do
		table.insert(nodes, self.nodes[id])
		for _, other in self.adjacency[id] do
			if id < other then
				table.insert(edges, { id, other })
			end
		end
	end
	return { nodes = nodes, edges = edges }
end

return Graph
