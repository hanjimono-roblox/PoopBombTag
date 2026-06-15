--!strict

-- ArenaTemplateConfig
-- Each hazard type supports:
--   Enabled: bool
--   StartDelay: number (seconds before first occurrence; default 0)
--   IntervalSeconds: number (seconds between repeats; omit/nil = runs once)
--   IntervalVariance: number (random +/- seconds added to interval; default 0)

local ArenaTemplateConfig = {
	Name = "ArenaTemplate",
	DisplayName = "Arena Template",
	SpawnFolderName = "Spawns",
	Modifiers = {},

	-- ---------------------------------------------------------------------------
	-- Hazards: Mechanical threats that damage players via a health pool (default 100 HP).
	-- When health reaches 0, the player is eliminated via RoundManager:EliminatePlayer.
	-- Each hazard type checks for specific parts in the map tagged with:
	--   Attribute("HazardType", "<HazardName>")
	-- ---------------------------------------------------------------------------
	Hazards = {
		-- Active while the player touches tagged parts. Deals damage per second.
		-- Requires: Part(s) with Attribute("HazardType", "Lava")
		Lava = {
			Enabled = false,
			DamagePerSecond = 25,
			TickCooldown = 1.0,
		},

		-- Periodic earthquake events. Camera shake + random impulse to all players.
		-- Also pushes loose map parts (parts with Attribute("Shakeable", true)).
		Earthquake = {
			Enabled = false,
			StartDelay = 10,
			IntervalSeconds = 15,
			IntervalVariance = 3,
			DurationSeconds = 4,
			ShakeMagnitude = 3,
			KnockbackForce = Vector3.new(0, 50, 0),
		},

		-- Rising water plane over time. Players whose head is submerged take drown damage.
		-- Requires: Part with Attribute("HazardType", "WaterSource") for start height.
		Flood = {
			Enabled = false,
			StartDelay = 25,
			RiseRate = 0.5,
			MaxHeight = 40,
			DrownDamagePerSecond = 20,
		},

		-- Periodic eruption at tagged geyser points. High damage to anyone in the zone.
		-- Requires: Part(s) with Attribute("HazardType", "FireGeyser")
		FireGeyser = {
			Enabled = false,
			StartDelay = 10,
			IntervalSeconds = 8,
			IntervalVariance = 2,
			DurationSeconds = 2,
			EruptionHeight = 30,
			DamageOnContact = 100,
			KillZoneRadius = 6,
		},

		-- A wandering tornado that moves along waypoint parts or toward players.
		-- Pulls players upward and deals continuous damage.
		-- Requires: Part chain with Attribute("HazardType", "TornadoPath") waypoints
		-- OR a single TornadoCenter part referencing the path.
		Tornado = {
			Enabled = true,
			StartDelay = 15,
			IntervalSeconds = 30,
			IntervalVariance = 5,
			MoveSpeed = 12,
			PullForce = Vector3.new(0, 60, 0),
			DamagePerSecond = 35,
			KillZoneRadius = 8,
			DurationSeconds = 20,
			PathLoop = true,

			-- Visual config (sent to clients for particle rendering)
			BaseRadius = 3,
			TopRadius = 50,
			MaxHeight = 45,
			ParticleRate = 100,
		},
	},

	-- ---------------------------------------------------------------------------
	-- Atmosphere: Visual/ambient conditions replicated to clients.
	-- Each type can be combined (e.g. fog + thunderstorm).
	-- ---------------------------------------------------------------------------
	Atmosphere = {
		-- Classic fog. Affects visibility for hiding/tagging.
		Fog = {
			Enabled = false,
			Color = Color3.fromRGB(200, 200, 200),
			Start = 20,
			End = 80,
		},

		-- Heavy rain with optional lightning and thunder.
		Rainstorm = {
			Enabled = false,
			Intensity = 50,         -- particles per second
			HasLightning = true,
			LightningIntervalMin = 5,
			LightningIntervalMax = 15,
			ThunderVolume = 0.5,
		},

		-- Dry storm with sand particles, orange/brown fog, wind.
		Sandstorm = {
			Enabled = false,
			ParticleIntensity = 40,
			FogColor = Color3.fromRGB(180, 140, 80),
			FogStart = 5,
			FogEnd = 35,
			SkyDarkening = 0.5,
		},

		-- Snow storm. White fog, snow particles, cold tint.
		Blizzard = {
			Enabled = false,
			ParticleIntensity = 60,
			FogColor = Color3.fromRGB(220, 230, 240),
			FogStart = 8,
			FogEnd = 45,
			SkyTint = Color3.fromRGB(180, 190, 210),
		},

		-- Colorful sky lights. Animated gradient overlay on skybox.
		Aurora = {
			Enabled = false,
			Intensity = 0.6,        -- 0-1 brightness
			PrimaryColor = Color3.fromRGB(0, 200, 100),
			SecondaryColor = Color3.fromRGB(100, 0, 200),
			Speed = 0.3,            -- animation speed
		},
	},
}

return ArenaTemplateConfig