--!strict
--[[
	/weather command — Admin-only test command for atmosphere effects.

	Usage:
	  /weather <type> <on|off>

	Types:
	  fog, rain, sandstorm, blizzard, aurora, all

	Examples:
	  /weather fog on      → enables fog
	  /weather all on      → enables all atmosphere types
	  /weather all off     → clears all atmosphere effects
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

return {
	Name = "weather",
	Aliases = {},
	Permission = "MapControl",
	Description = "Toggles atmosphere effects for testing. Usage: /weather <fog|rain|sandstorm|blizzard|aurora|all> <on|off>",

	Arguments = {
		{
			Name = "weathertype",
			Type = "string",
			Required = true,
		},
		{
			Name = "weatherstate",
			Type = "string",
			Required = true,
		},
	},

	Execute = function(ctx)
		local atmosType = (ctx.weathertype or ""):lower()
		local state = (ctx.weatherstate or ""):lower()

		if state ~= "on" and state ~= "off" then
			ctx.Services:Get("LoggingService"):Warn("WEATHER", "Invalid state. Use 'on' or 'off'.")
			return false
		end

		local enable = state == "on"
		local atmosService = ctx.Services:Get("AtmosphereService")

		if not enable then
			-- Turning off: clear all atmosphere.
			atmosService:ClearAtmosphereNow()
			ctx.Services:Get("LoggingService"):Info("WEATHER", "Atmosphere cleared")
			return true
		end

		-- Build a new atmosphere config table with the requested type enabled.
		local defaultConfig = {
			Atmosphere = {
				Fog = {
					Enabled = atmosType == "fog" or atmosType == "all",
					Color = Color3.fromRGB(200, 200, 200),
					Start = 20,
					End = 80,
				},
				Rainstorm = {
					Enabled = atmosType == "rain" or atmosType == "all",
					Intensity = 50,
					HasLightning = true,
					LightningIntervalMin = 5,
					LightningIntervalMax = 15,
					ThunderVolume = 0.5,
				},
				Sandstorm = {
					Enabled = atmosType == "sandstorm" or atmosType == "all",
					ParticleIntensity = 40,
					FogColor = Color3.fromRGB(180, 140, 80),
					FogStart = 5,
					FogEnd = 35,
					SkyDarkening = 0.5,
				},
				Blizzard = {
					Enabled = atmosType == "blizzard" or atmosType == "all",
					ParticleIntensity = 60,
					FogColor = Color3.fromRGB(220, 230, 240),
					FogStart = 8,
					FogEnd = 45,
					SkyTint = Color3.fromRGB(180, 190, 210),
				},
				Aurora = {
					Enabled = atmosType == "aurora" or atmosType == "all",
					Intensity = 0.6,
					PrimaryColor = Color3.fromRGB(0, 200, 100),
					SecondaryColor = Color3.fromRGB(100, 0, 200),
					Speed = 0.3,
				},
			},
		}

		atmosService:ApplyAtmosphereNow(defaultConfig.Atmosphere)
		ctx.Services:Get("LoggingService"):Info("WEATHER", `Atmosphere '{atmosType}' enabled`)
		return true
	end,
}