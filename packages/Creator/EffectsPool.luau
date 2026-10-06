--!strict
-- Shim: the pool moved to packages/AVKit/Pool.luau (opened up: caller-defined field schemas and
-- recipes, keyed idle lists for template clones). This keeps Creator/Effects, the inherited
-- fixtures and tests/creator/effects.luau working unchanged. New code requires AVKit/Pool.
return require("../AVKit/Pool")
