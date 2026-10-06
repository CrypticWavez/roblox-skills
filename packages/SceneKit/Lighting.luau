--!strict
-- Lighting schema 2: environment presets as plain data, named by function (inspection, time of
-- day, weather, interior, readability, performance), never by theme. A preset owns the Lighting
-- service properties, one Atmosphere and one Sky (no Skybox textures), Clouds (under Terrain),
-- Workspace.GlobalWind and persistent post-processing: Bloom, ColorCorrection, DepthOfField,
-- SunRays and an optional ColorGrading. Transient pulses (flashes, punches) belong to Feel/Screen
-- and cutscene focus to Cinematics, so every preset keeps DepthOfField off.
--
-- validate(preset) -> problems   documented ranges; "convention" ranges are factory choices
-- audit(preset, class?) -> warnings  readability floor, cost per device class, no-effect values
-- blend(a, b, t) -> preset        numbers and colours interpolate (ClockTime on the shortest arc),
--                                 booleans and enums switch at t >= 0.5, disabled blocks fade in
--                                 and out from zero-effect values; t = 0 and t = 1 return a and b
-- apply(lighting, preset, env?, options?) -> report  writes every field (missing ones take the
--                                 engine defaults), so apply(A) then apply(B) equals apply(B)
-- inspect(lighting, options?)     owned values, foreign instances, LightingStyle and
--                                 PrioritizeLightingQuality, and requires_ok
--
-- Ownership: apply creates children named SceneKit<Class> with attribute SceneKitOwned = true and
-- never edits other instances; it reports them (foreign). A non-owned Atmosphere, Sky, Clouds or
-- ColorGradingEffect is a conflict (only one applies: "only the most recently parented
-- [ColorGradingEffect] will be applied") unless options.adopt takes it over.
-- LightingStyle and PrioritizeLightingQuality are RobloxScriptSecurity to write: presets declare
-- what they expect under `requires`, inspect checks it, the owner sets them in Studio.
-- Leaf module: no requires (kits and the starter require it). Datatypes come from env (the
-- @lune/roblox library, a GameKit env with .roblox, or the Roblox globals when env is nil).
-- Sources: docs/research/visual-audio-assets-2026-10.md sections 3a-3c and 6.1.
local Lighting = {}

Lighting.SCHEMA = 2
Lighting.OWNED_ATTRIBUTE = "SceneKitOwned"
Lighting.PROFILE_ATTRIBUTE = "SceneKitLightingProfile"

type Field = { kind: string, min: number?, max: number?, choices: { string }?, convention: boolean? }
type Block = { [string]: Field }

local function num(min: number, max: number, convention: boolean?): Field
	return { kind = "number", min = min, max = max, convention = convention }
end
local COLOR: Field = { kind = "color" }
local BOOL: Field = { kind = "boolean" }
local function choice(...: string): Field
	return { kind = "enum", choices = { ... } }
end

-- Field schema per block. Ranges marked convention are not published by Roblox (UNVERIFIED);
-- the rest come from the class pages or creator-docs YAML.
local FIELDS: { [string]: Block } = {
	lighting = {
		ClockTime = num(0, 24),
		GeographicLatitude = num(-90, 90, true),
		Brightness = num(0, 10, true),
		ExposureCompensation = num(-5, 5),
		Ambient = COLOR,
		OutdoorAmbient = COLOR,
		EnvironmentDiffuseScale = num(0, 1),
		EnvironmentSpecularScale = num(0, 1),
		GlobalShadows = BOOL,
		ShadowSoftness = num(0, 1),
		ColorShift_Top = COLOR,
		ColorShift_Bottom = COLOR,
	},
	atmosphere = {
		Density = num(0, 1, true),
		Offset = num(0, 1, true),
		Haze = num(0, 10, true),
		Glare = num(0, 10, true),
		Color = COLOR,
		Decay = COLOR,
	},
	sky = {
		CelestialBodiesShown = BOOL,
		SunAngularSize = num(0, 60, true),
		MoonAngularSize = num(0, 60, true),
		StarCount = num(0, 5000, true),
	},
	clouds = { Enabled = BOOL, Cover = num(0, 1), Density = num(0, 1), Color = COLOR },
	bloom = {
		Enabled = BOOL,
		Intensity = num(0, 1, true),
		Size = num(0, 56, true),
		Threshold = num(0, 4, true),
	},
	colorCorrection = {
		Enabled = BOOL,
		Brightness = num(-1, 1, true),
		Contrast = num(-1, 1, true),
		Saturation = num(-1, 1, true),
		TintColor = COLOR,
	},
	depthOfField = {
		Enabled = BOOL,
		FocusDistance = num(0, 200, true),
		InFocusRadius = num(0, 50, true),
		NearIntensity = num(0, 1, true),
		FarIntensity = num(0, 1, true),
	},
	sunRays = { Enabled = BOOL, Intensity = num(0, 1), Spread = num(0, 1) },
	colorGrading = { Enabled = BOOL, TonemapperPreset = choice("Default", "Retro") },
}
Lighting.FIELDS = FIELDS

local POST = { "bloom", "colorCorrection", "depthOfField", "sunRays", "colorGrading" }
local CLASS = {
	atmosphere = "Atmosphere",
	sky = "Sky",
	clouds = "Clouds",
	bloom = "BloomEffect",
	colorCorrection = "ColorCorrectionEffect",
	depthOfField = "DepthOfFieldEffect",
	sunRays = "SunRaysEffect",
	colorGrading = "ColorGradingEffect",
}
Lighting.CLASS = CLASS
-- Only one of these applies at a time, so a non-owned one is a conflict, not a stack.
local SINGLETON = { atmosphere = true, sky = true, clouds = true, colorGrading = true }
local INTEGER = { StarCount = true }
local WIND_MAX = 100 -- studs/s per axis (convention)
local TOP_KEYS = {
	id = true,
	intent = true,
	tags = true,
	requires = true,
	lighting = true,
	atmosphere = true,
	sky = true,
	clouds = true,
	wind = true,
	post = true,
	blendOf = true,
}
local REQUIRES = { LightingStyle = { "Realistic", "Soft" } }

-- Engine defaults per block (Lune 0.10.5 reflection database 0.728; ClockTime has no stored
-- default there and uses 14). apply fills missing fields from these, so it is deterministic.
local DEFAULTS = {
	lighting = {
		ClockTime = 14,
		GeographicLatitude = 41.7333,
		Brightness = 2,
		ExposureCompensation = 0,
		Ambient = { 128, 128, 128 },
		OutdoorAmbient = { 128, 128, 128 },
		EnvironmentDiffuseScale = 0,
		EnvironmentSpecularScale = 0,
		GlobalShadows = false,
		ShadowSoftness = 0.5,
		ColorShift_Top = { 0, 0, 0 },
		ColorShift_Bottom = { 0, 0, 0 },
	},
	atmosphere = {
		Density = 0.395,
		Offset = 0,
		Haze = 0,
		Glare = 0,
		Color = { 200, 170, 108 },
		Decay = { 92, 60, 14 },
	},
	sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 3000 },
	clouds = { Enabled = true, Cover = 0.5, Density = 0.7, Color = { 255, 255, 255 } },
	bloom = { Enabled = true, Intensity = 0.4, Size = 24, Threshold = 0.95 },
	colorCorrection = {
		Enabled = true,
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = { 255, 255, 255 },
	},
	depthOfField = {
		Enabled = true,
		FocusDistance = 0.05,
		InFocusRadius = 10,
		NearIntensity = 0.75,
		FarIntensity = 0.75,
	},
	sunRays = { Enabled = true, Intensity = 0.25, Spread = 1 },
	colorGrading = { Enabled = true, TonemapperPreset = "Default" },
}
Lighting.DEFAULTS = DEFAULTS

-- Zero-effect values a disabled or missing block blends from (an effect fades in from nothing).
local NEUTRAL = {
	atmosphere = {
		Density = 0,
		Offset = 0,
		Haze = 0,
		Glare = 0,
		Color = { 200, 170, 108 },
		Decay = { 92, 60, 14 },
	},
	sky = DEFAULTS.sky,
	clouds = { Enabled = false, Cover = 0, Density = 0, Color = { 255, 255, 255 } },
	bloom = { Enabled = false, Intensity = 0, Size = 24, Threshold = 0.95 },
	colorCorrection = {
		Enabled = false,
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = { 255, 255, 255 },
	},
	depthOfField = {
		Enabled = false,
		FocusDistance = 0.05,
		InFocusRadius = 50,
		NearIntensity = 0,
		FarIntensity = 0,
	},
	sunRays = { Enabled = false, Intensity = 0, Spread = 1 },
	colorGrading = { Enabled = false, TonemapperPreset = "Default" },
}

-- ---------------------------------------------------------------- presets

local OFF_DOF = { Enabled = false }
local REALISTIC = { LightingStyle = "Realistic", PrioritizeLightingQuality = true }

local PRESETS: { [string]: any } = {
	lookdev_neutral = {
		intent = "Asset look-dev: even afternoon daylight with mild shadows and no grading, so materials and colours read as authored (the former neutral-day).",
		tags = { "inspection", "outdoor", "day" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 14,
			GeographicLatitude = 41.7333,
			Brightness = 2,
			ExposureCompensation = 0,
			Ambient = { 70, 70, 70 },
			OutdoorAmbient = { 128, 128, 128 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 1,
			GlobalShadows = true,
			ShadowSoftness = 0.2,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.3,
			Offset = 0.25,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 3000 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = { Enabled = false },
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	lookdev_contrast = {
		intent = "Form and silhouette check: low key fill, crisp shadows from a lower sun and a little contrast, so weak shapes and flat materials show up.",
		tags = { "inspection", "outdoor", "day" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 15.75,
			GeographicLatitude = 41.7333,
			Brightness = 3,
			ExposureCompensation = 0,
			Ambient = { 30, 30, 32 },
			OutdoorAmbient = { 90, 90, 95 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 1,
			GlobalShadows = true,
			ShadowSoftness = 0.08,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.25,
			Offset = 0.2,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 3000 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.12,
				Saturation = -0.05,
				TintColor = { 255, 255, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	bright_noon = {
		intent = "Clear midday play space: high sun, short soft shadows, light blue air and scattered clouds; colours stay saturated and far objects stay legible.",
		tags = { "outdoor", "day", "clear" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 12.5,
			GeographicLatitude = 30,
			Brightness = 3,
			ExposureCompensation = 0,
			Ambient = { 40, 40, 45 },
			OutdoorAmbient = { 135, 135, 140 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 1,
			GlobalShadows = true,
			ShadowSoftness = 0.2,
			ColorShift_Top = { 10, 8, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.28,
			Offset = 0.25,
			Haze = 0.3,
			Glare = 0.2,
			Color = { 200, 212, 228 },
			Decay = { 110, 122, 140 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 18, MoonAngularSize = 11, StarCount = 3000 },
		clouds = { Enabled = true, Cover = 0.45, Density = 0.4, Color = { 255, 255, 255 } },
		wind = { x = 3, y = 0, z = 1 },
		post = {
			bloom = { Enabled = true, Intensity = 0.35, Size = 24, Threshold = 1.2 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.03,
				Saturation = 0.08,
				TintColor = { 255, 255, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = true, Intensity = 0.06, Spread = 0.5 },
		},
	},
	overcast = {
		intent = "Diffuse grey daylight: no hard shadows, low saturation, full cloud cover; neutral for long play sessions and for judging shape without sun direction.",
		tags = { "outdoor", "day", "weather" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 13,
			GeographicLatitude = 41.7333,
			Brightness = 1.2,
			ExposureCompensation = 0.2,
			Ambient = { 90, 90, 95 },
			OutdoorAmbient = { 140, 140, 145 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0.5,
			GlobalShadows = true,
			ShadowSoftness = 0.6,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.45,
			Offset = 0.1,
			Haze = 2,
			Glare = 0,
			Color = { 190, 195, 200 },
			Decay = { 120, 125, 135 },
		},
		sky = { CelestialBodiesShown = false, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 0 },
		clouds = { Enabled = true, Cover = 0.9, Density = 0.75, Color = { 200, 200, 205 } },
		wind = { x = 5, y = 0, z = 2 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0,
				Saturation = -0.1,
				TintColor = { 235, 240, 245 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	golden_hour = {
		intent = "Low warm sun before sunset: long shadows, warm key against cool fill, light haze and gentle bloom; the reward or arrival mood without hiding geometry.",
		tags = { "outdoor", "evening", "clear" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 17.6,
			GeographicLatitude = 41.7333,
			Brightness = 2.5,
			ExposureCompensation = 0,
			Ambient = { 60, 50, 45 },
			OutdoorAmbient = { 140, 115, 95 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 1,
			GlobalShadows = true,
			ShadowSoftness = 0.25,
			ColorShift_Top = { 40, 22, 0 },
			ColorShift_Bottom = { 0, 0, 10 },
		},
		atmosphere = {
			Density = 0.35,
			Offset = 0.2,
			Haze = 1.5,
			Glare = 0.4,
			Color = { 230, 190, 160 },
			Decay = { 110, 85, 95 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 24, MoonAngularSize = 11, StarCount = 500 },
		clouds = { Enabled = true, Cover = 0.35, Density = 0.5, Color = { 255, 215, 185 } },
		wind = { x = 2, y = 0, z = 1 },
		post = {
			bloom = { Enabled = true, Intensity = 0.45, Size = 28, Threshold = 1.1 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.05,
				Saturation = 0.1,
				TintColor = { 255, 242, 230 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = true, Intensity = 0.1, Spread = 0.6 },
		},
	},
	blue_hour = {
		intent = "Twilight just after sunset: cool even fill, first stars, lit windows and lamps start to glow; transition phase between day and night presets.",
		tags = { "outdoor", "evening", "clear" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 18.4,
			GeographicLatitude = 41.7333,
			Brightness = 1.2,
			ExposureCompensation = 0.4,
			Ambient = { 40, 45, 70 },
			OutdoorAmbient = { 70, 80, 120 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0.8,
			GlobalShadows = true,
			ShadowSoftness = 0.4,
			ColorShift_Top = { 0, 10, 30 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.38,
			Offset = 0.15,
			Haze = 1.2,
			Glare = 0.2,
			Color = { 150, 165, 210 },
			Decay = { 70, 70, 120 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 12, StarCount = 1500 },
		clouds = { Enabled = true, Cover = 0.3, Density = 0.4, Color = { 150, 160, 200 } },
		wind = { x = 2, y = 0, z = 1 },
		post = {
			bloom = { Enabled = true, Intensity = 0.55, Size = 30, Threshold = 1 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.05,
				Saturation = -0.05,
				TintColor = { 230, 235, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	night_clear = {
		intent = "Readable night: moonlit blue fill keeps silhouettes and paths visible without local lights, stars on, emissive and lights bloom (the former night).",
		tags = { "outdoor", "night", "clear" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 0,
			GeographicLatitude = 41.7333,
			Brightness = 0.5,
			ExposureCompensation = 0.5,
			Ambient = { 25, 25, 40 },
			OutdoorAmbient = { 50, 50, 75 },
			EnvironmentDiffuseScale = 0.5,
			EnvironmentSpecularScale = 0.5,
			GlobalShadows = true,
			ShadowSoftness = 0.3,
			ColorShift_Top = { 0, 5, 20 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.35,
			Offset = 0,
			Haze = 0.5,
			Glare = 0,
			Color = { 90, 100, 140 },
			Decay = { 40, 45, 80 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 14, StarCount = 5000 },
		clouds = { Enabled = true, Cover = 0.2, Density = 0.3, Color = { 110, 120, 150 } },
		wind = { x = 1, y = 0, z = 1 },
		post = {
			bloom = { Enabled = true, Intensity = 0.6, Size = 32, Threshold = 0.95 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.05,
				Saturation = -0.15,
				TintColor = { 215, 225, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	low_light = {
		intent = "Scenes lit by their own lights (caves, basements, closed rooms at night): a dim floor of ambient so nothing is pitch black, everything else from local lights.",
		tags = { "interior", "night", "local_lights" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 0,
			GeographicLatitude = 41.7333,
			Brightness = 0.2,
			ExposureCompensation = 0.3,
			Ambient = { 14, 14, 18 },
			OutdoorAmbient = { 22, 22, 30 },
			EnvironmentDiffuseScale = 0.4,
			EnvironmentSpecularScale = 0.6,
			GlobalShadows = true,
			ShadowSoftness = 0.3,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.5,
			Offset = 0,
			Haze = 1,
			Glare = 0,
			Color = { 40, 40, 50 },
			Decay = { 20, 20, 30 },
		},
		sky = { CelestialBodiesShown = false, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 0 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = true, Intensity = 0.7, Size = 30, Threshold = 0.9 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.1,
				Saturation = -0.2,
				TintColor = { 255, 255, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	dense_fog = {
		intent = "Short sight lines: thick bright fog swallows the distance (hides pop-in, limits view range, isolates the play space) while the near field stays readable.",
		tags = { "outdoor", "day", "weather" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 10,
			GeographicLatitude = 41.7333,
			Brightness = 1,
			ExposureCompensation = 0.3,
			Ambient = { 110, 110, 115 },
			OutdoorAmbient = { 150, 150, 155 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0.3,
			GlobalShadows = true,
			ShadowSoftness = 0.8,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.75,
			Offset = 0,
			Haze = 3,
			Glare = 0,
			Color = { 200, 205, 210 },
			Decay = { 160, 165, 175 },
		},
		sky = { CelestialBodiesShown = false, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 0 },
		clouds = { Enabled = true, Cover = 1, Density = 0.9, Color = { 215, 215, 220 } },
		wind = { x = 1, y = 0, z = 1 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = -0.05,
				Saturation = -0.25,
				TintColor = { 240, 243, 245 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	storm_dim = {
		intent = "Heavy weather: dark low clouds, strong wind (moves grass, clouds and wind-affected particles), desaturated cool light; tension without losing the play space.",
		tags = { "outdoor", "day", "weather" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 15,
			GeographicLatitude = 41.7333,
			Brightness = 0.8,
			ExposureCompensation = 0.2,
			Ambient = { 55, 58, 65 },
			OutdoorAmbient = { 85, 90, 100 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0.6,
			GlobalShadows = true,
			ShadowSoftness = 0.7,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.55,
			Offset = 0.05,
			Haze = 2.5,
			Glare = 0,
			Color = { 120, 128, 140 },
			Decay = { 80, 85, 100 },
		},
		sky = { CelestialBodiesShown = false, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 0 },
		clouds = { Enabled = true, Cover = 0.95, Density = 1, Color = { 90, 95, 105 } },
		wind = { x = 14, y = 0, z = 6 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.08,
				Saturation = -0.3,
				TintColor = { 225, 232, 240 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	interior_warm = {
		intent = "Enclosed rooms lit by warm practical lights: no aerial haze indoors, warm ambient fill, gentle bloom on lamps; homes, shops, hubs.",
		tags = { "interior", "local_lights" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 14,
			GeographicLatitude = 41.7333,
			Brightness = 1,
			ExposureCompensation = 0.2,
			Ambient = { 70, 58, 48 },
			OutdoorAmbient = { 90, 78, 65 },
			EnvironmentDiffuseScale = 0.6,
			EnvironmentSpecularScale = 0.6,
			GlobalShadows = true,
			ShadowSoftness = 0.35,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.1,
			Offset = 0,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 3000 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = true, Intensity = 0.45, Size = 24, Threshold = 1.2 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.03,
				Saturation = 0.05,
				TintColor = { 255, 244, 232 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	interior_cool = {
		intent = "Enclosed rooms under cool neutral lights: clean, slightly desaturated fill for labs, offices, stations, menus-in-world.",
		tags = { "interior", "local_lights" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 14,
			GeographicLatitude = 41.7333,
			Brightness = 1,
			ExposureCompensation = 0.2,
			Ambient = { 60, 66, 75 },
			OutdoorAmbient = { 85, 92, 100 },
			EnvironmentDiffuseScale = 0.6,
			EnvironmentSpecularScale = 0.8,
			GlobalShadows = true,
			ShadowSoftness = 0.3,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.1,
			Offset = 0,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 3000 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = true, Intensity = 0.35, Size = 24, Threshold = 1.4 },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.04,
				Saturation = -0.05,
				TintColor = { 238, 245, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	readability_max = {
		intent = "Competitive and accessibility baseline: high ambient fill so nothing hides in shadow, long clear view distance, no glare, bloom or haze.",
		tags = { "outdoor", "day", "accessibility" },
		requires = REALISTIC,
		lighting = {
			ClockTime = 13,
			GeographicLatitude = 41.7333,
			Brightness = 2.5,
			ExposureCompensation = 0,
			Ambient = { 100, 100, 105 },
			OutdoorAmbient = { 150, 150, 155 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0.5,
			GlobalShadows = true,
			ShadowSoftness = 0.4,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.2,
			Offset = 0.3,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 3000 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = {
				Enabled = true,
				Brightness = 0,
				Contrast = 0.08,
				Saturation = 0.05,
				TintColor = { 255, 255, 255 },
			},
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	perf_low = {
		intent = "Low-end device fallback: Soft lighting with view distance prioritised, no clouds and no post-processing; the look stays neutral daylight.",
		tags = { "outdoor", "day", "performance" },
		requires = { LightingStyle = "Soft", PrioritizeLightingQuality = false },
		lighting = {
			ClockTime = 14,
			GeographicLatitude = 41.7333,
			Brightness = 2,
			ExposureCompensation = 0,
			Ambient = { 80, 80, 85 },
			OutdoorAmbient = { 130, 130, 135 },
			EnvironmentDiffuseScale = 1,
			EnvironmentSpecularScale = 0,
			GlobalShadows = true,
			ShadowSoftness = 0.2,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0.3,
			Offset = 0.25,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = true, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 1000 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = { Enabled = false },
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
	flat_capture = {
		intent = "Geometry capture: shadowless flat light, no sky bodies, no fog and no grading, so screenshots compare shapes and gaps (the former inspection-flat).",
		tags = { "inspection" },
		requires = {},
		lighting = {
			ClockTime = 12,
			GeographicLatitude = 41.7333,
			Brightness = 1,
			ExposureCompensation = 0,
			Ambient = { 150, 150, 150 },
			OutdoorAmbient = { 150, 150, 150 },
			EnvironmentDiffuseScale = 0,
			EnvironmentSpecularScale = 0,
			GlobalShadows = false,
			ShadowSoftness = 0.2,
			ColorShift_Top = { 0, 0, 0 },
			ColorShift_Bottom = { 0, 0, 0 },
		},
		atmosphere = {
			Density = 0,
			Offset = 0,
			Haze = 0,
			Glare = 0,
			Color = { 199, 199, 199 },
			Decay = { 106, 112, 125 },
		},
		sky = { CelestialBodiesShown = false, SunAngularSize = 21, MoonAngularSize = 11, StarCount = 0 },
		clouds = { Enabled = false },
		wind = { x = 0, y = 0, z = 0 },
		post = {
			bloom = { Enabled = false },
			colorCorrection = { Enabled = false },
			depthOfField = OFF_DOF,
			sunRays = { Enabled = false },
		},
	},
}

-- Schema 1 ids (captures and skills cite them) resolve to their schema 2 presets, whose Lighting
-- and Atmosphere numbers are unchanged.
Lighting.LEGACY = table.freeze({
	["neutral-day"] = "lookdev_neutral",
	overcast = "overcast",
	["golden-hour"] = "golden_hour",
	night = "night_clear",
	["inspection-flat"] = "flat_capture",
})

-- ---------------------------------------------------------------- helpers

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, child in value do
		out[key] = copy(child)
	end
	return out
end

local function freeze(value: any): any
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			freeze(child)
		end
		table.freeze(value)
	end
	return value
end

for id, preset in PRESETS do
	preset.id = id
	freeze(preset)
end
freeze(FIELDS)
freeze(DEFAULTS)
freeze(NEUTRAL)

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isColor(value: any): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for key, channel in value do
		if type(key) ~= "number" or not finite(channel) or channel < 0 or channel > 255 then
			return false
		end
	end
	return true
end

local function sortedKeys(map: { [any]: any }): { string }
	local keys = {}
	for key in map do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)
	return keys
end

local function label(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

-- ---------------------------------------------------------------- lookup

function Lighting.resolve(id: string): string?
	if PRESETS[id] then
		return id
	end
	return Lighting.LEGACY[id]
end

-- The frozen preset for an id (schema 1 ids resolve through LEGACY). Raises on an unknown id.
function Lighting.get(id: string): any
	local canonical = Lighting.resolve(id)
	local preset = canonical and PRESETS[canonical]
	assert(preset, "unknown lighting profile " .. tostring(id))
	return preset
end

-- A mutable deep copy of a preset, for games that tune one.
function Lighting.copy(id: string): any
	return copy(Lighting.get(id))
end

-- Canonical preset ids, sorted.
function Lighting.list(): { string }
	return sortedKeys(PRESETS)
end

local function presetOf(value: any): any
	if type(value) == "string" then
		return Lighting.get(value)
	end
	return value
end

-- ---------------------------------------------------------------- validate

local function validateBlock(name: string, block: any, problems: { string })
	local fields = FIELDS[name]
	if type(block) ~= "table" then
		table.insert(problems, name .. " must be a table")
		return
	end
	for _, key in sortedKeys(block) do
		local value = block[key]
		local field = fields[key]
		local where = name .. "." .. key
		if field == nil then
			table.insert(problems, where .. " is not a " .. name .. " field")
		elseif field.kind == "number" then
			if not finite(value) then
				table.insert(problems, where .. " must be a finite number")
			elseif value < (field.min :: number) or value > (field.max :: number) then
				table.insert(
					problems,
					string.format(
						"%s %s outside %s..%s%s",
						where,
						tostring(value),
						tostring(field.min),
						tostring(field.max),
						if field.convention then " (convention)" else ""
					)
				)
			elseif key == "ClockTime" and value >= 24 then
				table.insert(problems, where .. " must be below 24")
			elseif INTEGER[key] and value % 1 ~= 0 then
				table.insert(problems, where .. " must be a whole number")
			end
		elseif field.kind == "color" then
			if not isColor(value) then
				table.insert(problems, where .. " must be { r, g, b } with channels 0..255")
			end
		elseif field.kind == "boolean" then
			if type(value) ~= "boolean" then
				table.insert(problems, where .. " must be a boolean")
			end
		elseif field.kind == "enum" then
			if not table.find(field.choices :: { string }, value) then
				table.insert(
					problems,
					where .. " must be one of " .. table.concat(field.choices :: { string }, ", ")
				)
			end
		end
	end
end

-- Problems with a preset (empty when valid).
function Lighting.validate(preset: any): { string }
	if type(preset) ~= "table" then
		return { "preset must be a table" }
	end
	local problems = {}
	for _, key in sortedKeys(preset) do
		if not TOP_KEYS[key] then
			table.insert(problems, key .. " is not a preset key")
		end
	end
	if preset.intent ~= nil and (type(preset.intent) ~= "string" or #preset.intent == 0) then
		table.insert(problems, "intent must be a non-empty string")
	end
	if preset.tags ~= nil then
		if type(preset.tags) ~= "table" then
			table.insert(problems, "tags must be a list of labels")
		else
			for _, tag in preset.tags do
				if not label(tag) then
					table.insert(problems, "tag " .. tostring(tag) .. " is not a label")
				end
			end
		end
	end
	if preset.requires ~= nil then
		if type(preset.requires) ~= "table" then
			table.insert(problems, "requires must be a table")
		else
			for _, key in sortedKeys(preset.requires) do
				local value = preset.requires[key]
				if key == "LightingStyle" then
					if not table.find(REQUIRES.LightingStyle, value) then
						table.insert(problems, "requires.LightingStyle must be Realistic or Soft")
					end
				elseif key == "PrioritizeLightingQuality" then
					if type(value) ~= "boolean" then
						table.insert(problems, "requires.PrioritizeLightingQuality must be a boolean")
					end
				else
					table.insert(problems, "requires." .. key .. " is not a checked Lighting setting")
				end
			end
		end
	end
	for _, name in { "lighting", "atmosphere", "sky", "clouds" } do
		if preset[name] ~= nil then
			validateBlock(name, preset[name], problems)
		end
	end
	if preset.wind ~= nil then
		local wind = preset.wind
		if type(wind) ~= "table" then
			table.insert(problems, "wind must be { x, y, z }")
		else
			for _, key in sortedKeys(wind) do
				local value = wind[key]
				if key ~= "x" and key ~= "y" and key ~= "z" then
					table.insert(problems, "wind." .. key .. " is not x, y or z")
				elseif not finite(value) or math.abs(value) > WIND_MAX then
					table.insert(
						problems,
						string.format("wind.%s must be finite within +-%d (convention)", key, WIND_MAX)
					)
				end
			end
		end
	end
	if preset.post ~= nil then
		if type(preset.post) ~= "table" then
			table.insert(problems, "post must be a table")
		else
			for _, key in sortedKeys(preset.post) do
				if not table.find(POST, key) then
					table.insert(problems, "post." .. key .. " is not a post-processing block")
				else
					validateBlock(key, preset.post[key], problems)
				end
			end
		end
	end
	return problems
end

-- ---------------------------------------------------------------- audit

local function luminance(color: { number }): number
	return 0.2126 * color[1] + 0.7152 * color[2] + 0.0722 * color[3]
end

local function blockOf(preset: any, name: string): any
	if CLASS[name] and table.find(POST, name) then
		return preset.post and preset.post[name]
	end
	return preset[name]
end

local function enabled(name: string, block: any): boolean
	if block == nil then
		return false
	end
	if name == "atmosphere" or name == "sky" then
		return true
	end
	return block.Enabled ~= false
end

-- Cost summary used by audit and the per-device budget: enabled post effects, clouds, shadows.
function Lighting.cost(
	value: any
): { postEffects: number, clouds: boolean, shadows: boolean, depthOfField: boolean }
	local preset = presetOf(value)
	local post = 0
	for _, name in POST do
		if enabled(name, blockOf(preset, name)) then
			post += 1
		end
	end
	return {
		postEffects = post,
		clouds = enabled("clouds", preset.clouds),
		shadows = preset.lighting == nil or preset.lighting.GlobalShadows ~= false,
		depthOfField = enabled("depthOfField", blockOf(preset, "depthOfField")),
	}
end

-- Convention warnings (never failures): readability floor, values the docs say have no effect,
-- persistent depth of field, aggressive bloom or sun rays, and the post-effect budget of a
-- device class (`postEffects` = the class's post_effects limit, from SceneKit/Budgets).
function Lighting.audit(value: any, limits: { postEffects: number? }?): { string }
	local preset = presetOf(value)
	local warnings = {}
	local tags = preset.tags or {}
	local lighting = preset.lighting or {}
	local outdoor = lighting.OutdoorAmbient or DEFAULTS.lighting.OutdoorAmbient
	local ambient = lighting.Ambient or DEFAULTS.lighting.Ambient
	if not table.find(tags, "local_lights") and luminance(outdoor) < 40 and luminance(ambient) < 20 then
		table.insert(
			warnings,
			"ambient below the readability floor (convention: OutdoorAmbient luminance 40) without the local_lights tag"
		)
	end
	for index = 1, 3 do
		if outdoor[index] < ambient[index] then
			table.insert(
				warnings,
				"OutdoorAmbient below Ambient in a channel: the engine clamps it up to Ambient"
			)
			break
		end
	end
	local exposure = lighting.ExposureCompensation or 0
	if math.abs(exposure) > 1.5 then
		table.insert(
			warnings,
			"ExposureCompensation beyond +-1.5 (convention): check UI-like surfaces and skies"
		)
	end
	local atmosphere = preset.atmosphere
	-- "Glare needs Haze > 0" (docs environment/atmosphere).
	if atmosphere and (atmosphere.Glare or 0) > 0 and (atmosphere.Haze or 0) <= 0 then
		table.insert(warnings, "Atmosphere.Glare has no effect without Haze")
	end
	local bloom = blockOf(preset, "bloom")
	if enabled("bloom", bloom) and (bloom.Threshold or DEFAULTS.bloom.Threshold) < 0.8 then
		table.insert(warnings, "Bloom.Threshold below 0.8 blooms mid-tones (convention)")
	end
	local sunRays = blockOf(preset, "sunRays")
	if enabled("sunRays", sunRays) and (sunRays.Intensity or DEFAULTS.sunRays.Intensity) > 0.25 then
		table.insert(warnings, "SunRays.Intensity above 0.25 washes out the sky side (convention)")
	end
	local cost = Lighting.cost(preset)
	if cost.depthOfField then
		table.insert(warnings, "DepthOfField enabled in a persistent preset: blur belongs to Cinematics/Feel")
	end
	if limits and limits.postEffects and cost.postEffects > limits.postEffects then
		table.insert(
			warnings,
			string.format(
				"%d post effects over the device budget of %d (convention)",
				cost.postEffects,
				limits.postEffects
			)
		)
	end
	return warnings
end

-- ---------------------------------------------------------------- blend

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function blendField(key: string, field: Field, a: any, b: any, t: number): any
	if field.kind == "number" then
		if key == "ClockTime" then
			local delta = ((b - a + 12) % 24) - 12
			return (a + delta * t) % 24
		end
		local value = lerp(a, b, t)
		return if INTEGER[key] then math.round(value) else value
	elseif field.kind == "color" then
		return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t) }
	end
	return if t < 0.5 then a else b
end

-- Fields a side contributes: its own values over the engine defaults, or the zero-effect values
-- when the block is disabled or missing.
local function filled(name: string, block: any): { [string]: any }
	local base = if enabled(name, block) then DEFAULTS[name] else (NEUTRAL :: any)[name] or DEFAULTS[name]
	local out = copy(base)
	if enabled(name, block) then
		for key, value in block do
			out[key] = copy(value)
		end
	end
	return out
end

local function blendBlock(name: string, a: any, b: any, t: number): any
	if a == nil and b == nil then
		return nil
	end
	local fa, fb = filled(name, a), filled(name, b)
	local out = {}
	for key, field in FIELDS[name] do
		if key == "Enabled" then
			out.Enabled = enabled(name, a) or enabled(name, b)
		else
			out[key] = blendField(key, field, fa[key], fb[key], t)
		end
	end
	return out
end

-- Pure interpolation between two presets (ids or tables); t is clamped to 0..1. At t = 0 and
-- t = 1 the result is a deep copy of a or b. In between, `blendOf` records the endpoints.
function Lighting.blend(a: any, b: any, t: number): any
	assert(finite(t), "Lighting.blend: t must be a finite number")
	local pa, pb = presetOf(a), presetOf(b)
	for _, preset in { pa, pb } do
		local problems = Lighting.validate(preset)
		assert(#problems == 0, "Lighting.blend: " .. table.concat(problems, "; "))
	end
	if t <= 0 then
		return copy(pa)
	elseif t >= 1 then
		return copy(pb)
	end
	local out: any = {
		intent = "blend",
		tags = copy(if t < 0.5 then pa.tags else pb.tags),
		requires = copy(if t < 0.5 then pa.requires else pb.requires),
		blendOf = { from = pa.id or "custom", to = pb.id or "custom", t = t },
	}
	out.lighting = {}
	local la, lb = filled("lighting", pa.lighting or {}), filled("lighting", pb.lighting or {})
	for key, field in FIELDS.lighting do
		out.lighting[key] = blendField(key, field, la[key], lb[key], t)
	end
	for _, name in { "atmosphere", "sky", "clouds" } do
		out[name] = blendBlock(name, pa[name], pb[name], t)
	end
	local wa = pa.wind or { x = 0, y = 0, z = 0 }
	local wb = pb.wind or { x = 0, y = 0, z = 0 }
	out.wind = {
		x = lerp(wa.x or 0, wb.x or 0, t),
		y = lerp(wa.y or 0, wb.y or 0, t),
		z = lerp(wa.z or 0, wb.z or 0, t),
	}
	local post = {}
	for _, name in POST do
		post[name] = blendBlock(name, pa.post and pa.post[name], pb.post and pb.post[name], t)
	end
	out.post = post
	return out
end

-- ---------------------------------------------------------------- apply and inspect

local function library(env: any): any
	if env == nil then
		return { Color3 = Color3, Instance = Instance, Vector3 = Vector3, Enum = Enum } :: any
	end
	if env.roblox ~= nil then
		return env.roblox
	end
	return env
end

local function toRoblox(lib: any, field: Field, key: string, value: any): any
	if field.kind == "color" then
		return lib.Color3.fromRGB(value[1], value[2], value[3])
	elseif field.kind == "enum" then
		local enum = if key == "TonemapperPreset" then lib.Enum.TonemapperPreset else nil
		assert(enum, "no enum for " .. key)
		return (enum :: any)[value]
	end
	return value
end

local function fromRoblox(value: any): any
	local kind = typeof(value)
	if kind == "Color3" then
		return { math.round(value.R * 255), math.round(value.G * 255), math.round(value.B * 255) }
	elseif kind == "EnumItem" then
		return value.Name
	elseif kind == "Vector3" then
		return { x = value.X, y = value.Y, z = value.Z }
	elseif type(value) == "number" then
		return math.round(value * 1e4) / 1e4
	end
	return value
end

local function read(instance: any, key: string): any
	local ok, value = pcall(function()
		return instance[key]
	end)
	return if ok then fromRoblox(value) else nil
end

local function isOwned(child: any): boolean
	return child:GetAttribute(Lighting.OWNED_ATTRIBUTE) == true
end

local function split(parent: any, class: string): (any?, { any })
	local owned, foreign = nil, {}
	if parent == nil then
		return nil, foreign
	end
	for _, child in parent:GetChildren() do
		if child.ClassName == class then
			if isOwned(child) and owned == nil then
				owned = child
			elseif not isOwned(child) then
				table.insert(foreign, child)
			end
		end
	end
	return owned, foreign
end

export type ApplyOptions = {
	workspace: any?, -- for GlobalWind and Terrain (default: lighting.Parent's Workspace)
	terrain: any?, -- Clouds parent (default: the Workspace's Terrain)
	adopt: boolean?, -- take over a non-owned Atmosphere/Sky/Clouds/effect instead of reporting it
}

export type ApplyReport = {
	preset: string,
	created: { string },
	updated: { string },
	adopted: { string },
	removed: { string },
	conflicts: { string },
	stacked: { string },
	skipped: { string },
	requires: { [string]: any },
}

local function applyBlock(
	lib: any,
	parent: any,
	name: string,
	block: any,
	options: ApplyOptions,
	report: ApplyReport
)
	local class = CLASS[name]
	local owned, foreign = split(parent, class)
	if not enabled(name, block) then
		if owned then
			owned:Destroy()
			table.insert(report.removed, class)
		end
		return
	end
	local target = owned
	if target == nil and #foreign > 0 and options.adopt then
		target = table.remove(foreign, 1)
		target:SetAttribute(Lighting.OWNED_ATTRIBUTE, true)
		table.insert(report.adopted, class .. " " .. target.Name)
	elseif target == nil and #foreign > 0 and SINGLETON[name] then
		table.insert(
			report.conflicts,
			string.format(
				"%s: non-owned %s present (remove it or apply with adopt = true)",
				class,
				foreign[1].Name
			)
		)
		return
	end
	for _, other in foreign do
		table.insert(report.stacked, class .. " " .. other.Name)
	end
	local fields = filled(name, block)
	local created = target == nil
	local instance = target or lib.Instance.new(class)
	for _, key in sortedKeys(FIELDS[name]) do
		if key ~= "Enabled" or name == "clouds" or table.find(POST, name) then
			local value = if key == "Enabled" then true else fields[key]
			instance[key] = toRoblox(lib, FIELDS[name][key], key, value)
		end
	end
	if created then
		instance.Name = "SceneKit" .. class
		instance:SetAttribute(Lighting.OWNED_ATTRIBUTE, true)
		instance.Parent = parent
		table.insert(report.created, class)
	else
		table.insert(report.updated, class)
	end
end

local function findWorkspace(lighting: any, options: ApplyOptions): any?
	if options.workspace then
		return options.workspace
	end
	local root = lighting.Parent
	return if root then root:FindFirstChildOfClass("Workspace") else nil
end

-- Writes a preset (id or table) onto the Lighting service and its owned instances. Every field
-- is written (missing ones take DEFAULTS), so the result does not depend on what ran before.
-- Clouds need a Terrain and wind a Workspace; without them those parts are listed in skipped.
-- Raises when the preset does not validate.
function Lighting.apply(lighting: any, value: any, env: any?, options: ApplyOptions?): ApplyReport
	local preset = presetOf(value)
	local problems = Lighting.validate(preset)
	assert(#problems == 0, "Lighting.apply: " .. table.concat(problems, "; "))
	local opts: ApplyOptions = options or {}
	local lib = library(env)
	local report: ApplyReport = {
		preset = preset.id or "custom",
		created = {},
		updated = {},
		adopted = {},
		removed = {},
		conflicts = {},
		stacked = {},
		skipped = {},
		requires = copy(preset.requires or {}),
	}
	local fields = filled("lighting", preset.lighting or {})
	for _, key in sortedKeys(FIELDS.lighting) do
		lighting[key] = toRoblox(lib, FIELDS.lighting[key], key, fields[key])
	end
	for _, name in { "atmosphere", "sky" } do
		applyBlock(lib, lighting, name, preset[name], opts, report)
	end
	for _, name in POST do
		applyBlock(lib, lighting, name, preset.post and preset.post[name], opts, report)
	end
	local workspace = findWorkspace(lighting, opts)
	local terrain = opts.terrain or (workspace and workspace:FindFirstChildOfClass("Terrain"))
	if terrain then
		applyBlock(lib, terrain, "clouds", preset.clouds, opts, report)
	elseif enabled("clouds", preset.clouds) then
		table.insert(report.skipped, "clouds (no Terrain)")
	end
	local wind = preset.wind or { x = 0, y = 0, z = 0 }
	if workspace then
		workspace.GlobalWind = lib.Vector3.new(wind.x or 0, wind.y or 0, wind.z or 0)
	else
		table.insert(report.skipped, "wind (no Workspace)")
	end
	lighting:SetAttribute(Lighting.PROFILE_ATTRIBUTE, report.preset)
	lighting:SetAttribute(
		"SceneKitLightingBlend",
		if preset.blendOf
			then string.format("%s>%s@%.3f", preset.blendOf.from, preset.blendOf.to, preset.blendOf.t)
			else nil
	)
	local requires = preset.requires or {}
	lighting:SetAttribute("SceneKitLightingStyle", requires.LightingStyle)
	lighting:SetAttribute("SceneKitLightingQuality", requires.PrioritizeLightingQuality)
	return report
end

local function readBlock(instance: any, name: string): { [string]: any }
	local out = {}
	for key in FIELDS[name] do
		out[key] = read(instance, key)
	end
	return out
end

-- Owned values, foreign instances and the unscriptable settings. requires_ok is nil when the last
-- applied preset declared no requirement, else whether LightingStyle and PrioritizeLightingQuality
-- match it. Colours are { r, g, b } integers, numbers rounded to 1e-4, enums their names.
function Lighting.inspect(lighting: any, options: ApplyOptions?): { [string]: any }
	local opts: ApplyOptions = options or {}
	local result: { [string]: any } = {
		profile = lighting:GetAttribute(Lighting.PROFILE_ATTRIBUTE),
		blend = lighting:GetAttribute("SceneKitLightingBlend"),
		lighting = {},
		post = {},
		owned = {},
		foreign = {},
	}
	for key in FIELDS.lighting do
		result.lighting[key] = read(lighting, key)
	end
	local actual = {
		LightingStyle = read(lighting, "LightingStyle"),
		PrioritizeLightingQuality = read(lighting, "PrioritizeLightingQuality"),
	}
	local expected = {
		LightingStyle = lighting:GetAttribute("SceneKitLightingStyle"),
		PrioritizeLightingQuality = lighting:GetAttribute("SceneKitLightingQuality"),
	}
	result.requires = { expected = expected, actual = actual }
	if expected.LightingStyle == nil and expected.PrioritizeLightingQuality == nil then
		result.requires_ok = nil
	else
		result.requires_ok = (expected.LightingStyle == nil or expected.LightingStyle == actual.LightingStyle)
			and (
				expected.PrioritizeLightingQuality == nil
				or expected.PrioritizeLightingQuality == actual.PrioritizeLightingQuality
			)
	end
	local workspace = findWorkspace(lighting, opts)
	local terrain = opts.terrain or (workspace and workspace:FindFirstChildOfClass("Terrain"))
	local parents = { atmosphere = lighting, sky = lighting, clouds = terrain }
	for _, name in POST do
		parents[name] = lighting
	end
	for _, name in sortedKeys(CLASS) do
		local owned, foreign = split(parents[name], CLASS[name])
		if owned then
			table.insert(result.owned, CLASS[name])
			local values = readBlock(owned, name)
			if table.find(POST, name) then
				result.post[name] = values
			else
				result[name] = values
			end
		end
		for _, other in foreign do
			table.insert(result.foreign, CLASS[name] .. " " .. other.Name)
		end
	end
	if workspace then
		result.wind = read(workspace, "GlobalWind")
	end
	table.sort(result.owned)
	table.sort(result.foreign)
	return result
end

-- ---------------------------------------------------------------- preview hints

-- Approximate direction toward the sun in Roblox axes (+Y up, -Z north) for a ClockTime and
-- latitude, with no seasonal declination. Renderer-neutral hint for offline previews only: the
-- engine's exact sun model is not documented (UNVERIFIED).
function Lighting.sunDirection(clockTime: number, latitude: number): { x: number, y: number, z: number }
	local hour = (clockTime - 12) / 24 * 2 * math.pi
	local lat = math.rad(latitude)
	-- Sun on the celestial equator: rotate the noon direction about the east-west axis by hour.
	local east = math.sin(hour)
	local up = math.cos(hour) * math.cos(lat)
	local south = math.cos(hour) * math.sin(lat)
	local length = math.sqrt(east * east + up * up + south * south)
	return { x = east / length, y = up / length, z = south / length }
end

-- Renderer-neutral lighting hints for an offline preview (Blender): sun direction, colour and
-- strength, sky/ambient colour, fog density and exposure. An approximation for before/after
-- comparisons of presets, never a claim about how Studio renders them.
function Lighting.preview(value: any): { [string]: any }
	local preset = presetOf(value)
	local lighting = filled("lighting", preset.lighting or {})
	local atmosphere = filled("atmosphere", preset.atmosphere)
	local sun = Lighting.sunDirection(lighting.ClockTime, lighting.GeographicLatitude)
	local elevation = math.max(sun.y, 0)
	local warm = 1 - math.min(elevation * 2.5, 1)
	local shift = lighting.ColorShift_Top
	local sunColor = {
		math.min(255, 255 + shift[1] * 0.5),
		math.min(255, 255 - 60 * warm + shift[2] * 0.5),
		math.min(255, 255 - 130 * warm + shift[3] * 0.5),
	}
	return {
		sun = {
			direction = sun,
			color = sunColor,
			strength = if elevation > 0 then lighting.Brightness * (0.35 + 0.65 * elevation) else 0,
			shadows = lighting.GlobalShadows,
			softness = lighting.ShadowSoftness,
		},
		ambient = { color = lighting.OutdoorAmbient, floor = lighting.Ambient },
		fog = {
			density = if enabled("atmosphere", preset.atmosphere) then atmosphere.Density else 0,
			haze = atmosphere.Haze,
			color = atmosphere.Color,
		},
		exposure = lighting.ExposureCompensation,
	}
end

return Lighting
