--!strict
-- Facade: one require gives the whole authoring namespace.
--   local SceneKit = require(path.to.SceneKit.SceneKit)
--   local scene = SceneKit.Scene.new({ name = "Fixture", seed = 1, style = "neutral-stone" })
--   SceneKit.Building.create(scene, { footprint = { x = 0, z = 0, w = 32, d = 24 } })
--   print(SceneKit.Validate.summary(SceneKit.Validate.scene(scene)).pass)
--   SceneKit.Apply.scene(scene, workspace)
--   SceneKit.Model.inspect(SceneKit.Model.selection()) -- existing instances (Studio selection)
return {
	Apply = require("./Apply"),
	Budgets = require("./Budgets"),
	Building = require("./Building"),
	Camera = require("./Camera"),
	Kit = require("./Kit"),
	Layout = require("./Layout"),
	Lighting = require("./Lighting"),
	Materials = require("./Materials"),
	Measure = require("./Measure"),
	Model = require("./Model"),
	Paths = require("./Paths"),
	Props = require("./Props"),
	Scene = require("./Scene"),
	Style = require("./Style"),
	Terrain = require("./Terrain"),
	Validate = require("./Validate"),
	Vec = require("./Vec"),
	Vegetation = require("./Vegetation"),
}
