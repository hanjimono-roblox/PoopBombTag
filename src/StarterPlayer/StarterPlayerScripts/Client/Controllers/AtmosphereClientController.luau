--!strict

-- AtmosphereClientController (Client)
-- Receives atmosphere state from the server and renders visual effects:
--   - Fog (Lighting.Fog* properties)
--   - Rainstorm / Thunderstorm (particle environments + lightning)
--   - Sandstorm (fog + tint)
--   - Blizzard (snow particles + fog)
--   - Aurora (sky color overlay)
--
-- This controller listens to the AtmosphereState RemoteEvent.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local AtmosphereClientController = {}
AtmosphereClientController.__index = AtmosphereClientController
setmetatable(AtmosphereClientController, { __index = BaseController })

-- Saved original lighting values so we can restore them when atmosphere clears.
local DEFAULT_FOG_COLOR = Color3.fromRGB(128, 128, 128)
local DEFAULT_FOG_START = 0
local DEFAULT_FOG_END = 1000
local DEFAULT_BRIGHTNESS = 1
local DEFAULT_AMBIENT = Color3.fromRGB(128, 128, 128)

function AtmosphereClientController.new()
	local self: any = BaseController.new("AtmosphereClientController")
	-- Saved original lighting properties
	self._originalFogColor = Lighting.FogColor
	self._originalFogStart = Lighting.FogStart
	self._originalFogEnd = Lighting.FogEnd
	self._originalBrightness = Lighting.Brightness
	self._originalAmbient = Lighting.Ambient
	self._originalOutdoorAmbient = Lighting.OutdoorAmbient
	self._originalClockTime = Lighting.ClockTime
	self._originalGeographicLatitude = Lighting.GeographicLatitude
	-- Track active atmosphere
	self._activeAtmosphere = nil :: any?
	-- Particle emitters we've spawned
	self._particleEmitters = {} :: { ParticleEmitter }
	-- Sound effects
	self._sounds = {} :: { Sound }
	return setmetatable(self, AtmosphereClientController)
end

function AtmosphereClientController:Start()
	BaseController.Start(self)

	print("AtmosphereClientController started")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local atmosphereRemote = remotes:WaitForChild("AtmosphereState")

	atmosphereRemote.OnClientEvent:Connect(function(action: string, ...)
		self:_OnAtmosphereAction(action, ...)
	end)
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

function AtmosphereClientController:_OnAtmosphereAction(action: string, ...)
	if action == "AtmosphereApplied" then
		local atmosphereData = ... :: any
		self:OnAtmosphereApplied(atmosphereData)

	elseif action == "AtmosphereCleared" then
		self:OnAtmosphereCleared()

	elseif action == "LightningFlashed" then
		local thunderVolume = ... :: number
		self:OnLightningFlashed(thunderVolume)
	end
end

-- ---------------------------------------------------------------------------
-- Atmosphere Applied
-- ---------------------------------------------------------------------------

function AtmosphereClientController:OnAtmosphereApplied(atmosphere: any)
	self._activeAtmosphere = atmosphere

	-- Apply each enabled atmosphere type.
	if atmosphere.Fog and atmosphere.Fog.Enabled then
		self:_ApplyFog(atmosphere.Fog)
	end

	if atmosphere.Rainstorm and atmosphere.Rainstorm.Enabled then
		self:_ApplyRainstorm(atmosphere.Rainstorm)
	end

	if atmosphere.Sandstorm and atmosphere.Sandstorm.Enabled then
		self:_ApplySandstorm(atmosphere.Sandstorm)
	end

	if atmosphere.Blizzard and atmosphere.Blizzard.Enabled then
		self:_ApplyBlizzard(atmosphere.Blizzard)
	end

	if atmosphere.Aurora and atmosphere.Aurora.Enabled then
		self:_ApplyAurora(atmosphere.Aurora)
	end
end

-- ---------------------------------------------------------------------------
-- Atmosphere Cleared
-- ---------------------------------------------------------------------------

function AtmosphereClientController:OnAtmosphereCleared()
	-- Restore original lighting.
	TweenService:Create(Lighting, TweenInfo.new(1), {
		FogColor = self._originalFogColor,
		FogStart = self._originalFogStart,
		FogEnd = self._originalFogEnd,
		Brightness = self._originalBrightness,
		Ambient = self._originalAmbient,
		OutdoorAmbient = self._originalOutdoorAmbient,
	}):Play()

	-- Clean up particle emitters.
	for _, emitter in ipairs(self._particleEmitters) do
		emitter.Enabled = false
		emitter:Destroy()
	end
	self._particleEmitters = {}

	-- Clean up sounds.
	for _, sound in ipairs(self._sounds) do
		sound:Stop()
		sound:Destroy()
	end
	self._sounds = {}

	self._activeAtmosphere = nil
end

-- ---------------------------------------------------------------------------
-- Fog
-- ---------------------------------------------------------------------------

function AtmosphereClientController:_ApplyFog(config: any)
	TweenService:Create(Lighting, TweenInfo.new(2), {
		FogColor = config.Color,
		FogStart = config.Start,
		FogEnd = config.End,
	}):Play()
end

-- ---------------------------------------------------------------------------
-- Rainstorm
-- ---------------------------------------------------------------------------

function AtmosphereClientController:_ApplyRainstorm(config: any)
	-- Create rain particle emitter in the sky.
	local rainPart = Instance.new("Part")
	rainPart.Name = "RainEmitter"
	rainPart.Anchored = true
	rainPart.CanCollide = false
	rainPart.Transparency = 1
	rainPart.Size = Vector3.new(200, 1, 200)
	rainPart.Position = Vector3.new(0, 80, 0)
	rainPart.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = config.Intensity * 5
	emitter.Texture = "rbxasset://textures/particles/raindrop_01.dds"
	emitter.VelocityInheritance = 0
	emitter.Lifetime = NumberRange.new(3, 5)
	emitter.SpreadAngle = Vector2.new(5, 5)
	emitter.Speed = NumberRange.new(40, 60)
	emitter.Drag = 5
	emitter.Enabled = true
	emitter.Parent = rainPart

	table.insert(self._particleEmitters, emitter)

	-- Darken sky.
	local targetBrightness = math.max(0.3, Lighting.Brightness * 0.6)
	TweenService:Create(Lighting, TweenInfo.new(2), {
		Brightness = targetBrightness,
		FogStart = math.max(5, Lighting.FogStart),
		FogEnd = math.max(30, Lighting.FogEnd),
	}):Play()

	-- Add rain sound.
	local rainSound = Instance.new("Sound")
	rainSound.SoundId = "rbxasset://sounds/rain.wav"
	rainSound.Volume = 0.3
	rainSound.Looped = true
	rainSound.Parent = workspace
	rainSound:Play()
	table.insert(self._sounds, rainSound)
end

-- ---------------------------------------------------------------------------
-- Sandstorm
-- ---------------------------------------------------------------------------

function AtmosphereClientController:_ApplySandstorm(config: any)
	-- Apply sandstorm fog.
	TweenService:Create(Lighting, TweenInfo.new(2), {
		FogColor = config.FogColor,
		FogStart = config.FogStart,
		FogEnd = config.FogEnd,
		Brightness = math.max(0.3, Lighting.Brightness * config.SkyDarkening),
	}):Play()

	-- Create sand particle emitter.
	local sandPart = Instance.new("Part")
	sandPart.Name = "SandEmitter"
	sandPart.Anchored = true
	sandPart.CanCollide = false
	sandPart.Transparency = 1
	sandPart.Size = Vector3.new(200, 1, 200)
	sandPart.Position = Vector3.new(0, 50, 0)
	sandPart.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = config.ParticleIntensity * 3
	emitter.Texture = "rbxasset://textures/particles/sparkle_01.dds"
	emitter.VelocityInheritance = 0
	emitter.Lifetime = NumberRange.new(2, 4)
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.Speed = NumberRange.new(10, 30)
	emitter.Drag = 3
	emitter.Transparency = NumberSequence.new(0.3)
	emitter.Color = ColorSequence.new(config.FogColor)
	emitter.Enabled = true
	emitter.Parent = sandPart

	table.insert(self._particleEmitters, emitter)

	-- Wind sound.
	local windSound = Instance.new("Sound")
	windSound.SoundId = "rbxasset://sounds/wind.wav"
	windSound.Volume = 0.4
	windSound.Looped = true
	windSound.Parent = workspace
	windSound:Play()
	table.insert(self._sounds, windSound)
end

-- ---------------------------------------------------------------------------
-- Blizzard
-- ---------------------------------------------------------------------------

function AtmosphereClientController:_ApplyBlizzard(config: any)
	-- Apply blizzard fog.
	TweenService:Create(Lighting, TweenInfo.new(2), {
		FogColor = config.FogColor,
		FogStart = config.FogStart,
		FogEnd = config.FogEnd,
		Ambient = config.SkyTint or Color3.fromRGB(180, 190, 210),
	}):Play()

	-- Snow particle emitter.
	local snowPart = Instance.new("Part")
	snowPart.Name = "SnowEmitter"
	snowPart.Anchored = true
	snowPart.CanCollide = false
	snowPart.Transparency = 1
	snowPart.Size = Vector3.new(200, 1, 200)
	snowPart.Position = Vector3.new(0, 80, 0)
	snowPart.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = config.ParticleIntensity * 4
	emitter.Texture = "rbxasset://textures/particles/snowflake_01.dds"
	emitter.VelocityInheritance = 0
	emitter.Lifetime = NumberRange.new(4, 7)
	emitter.SpreadAngle = Vector2.new(15, 15)
	emitter.Speed = NumberRange.new(5, 15)
	emitter.Drag = 2
	emitter.Transparency = NumberSequence.new(0.2)
	emitter.Color = ColorSequence.new(Color3.fromRGB(230, 240, 255))
	emitter.Enabled = true
	emitter.Parent = snowPart

	table.insert(self._particleEmitters, emitter)

	-- Wind sound (softer for blizzard).
	local windSound = Instance.new("Sound")
	windSound.SoundId = "rbxasset://sounds/wind.wav"
	windSound.Volume = 0.25
	windSound.Looped = true
	windSound.Parent = workspace
	windSound:Play()
	table.insert(self._sounds, windSound)
end

-- ---------------------------------------------------------------------------
-- Aurora
-- ---------------------------------------------------------------------------

function AtmosphereClientController:_ApplyAurora(config: any)
	-- Create an aurora beam overlay in the sky.
	-- Uses a BillboardGui with gradient frames that animate.
	local auroraPart = Instance.new("Part")
	auroraPart.Name = "AuroraEffect"
	auroraPart.Anchored = true
	auroraPart.CanCollide = false
	auroraPart.Transparency = 1
	auroraPart.Size = Vector3.new(1, 1, 1)
	auroraPart.Position = Vector3.new(0, 100, 0)
	auroraPart.Parent = workspace

	-- Create a surface gui on the part to display the aurora gradient.
	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Face = Enum.NormalId.Bottom
	surfaceGui.CanvasSize = Vector2.new(400, 100)
	surfaceGui.AlwaysOnTop = true
	surfaceGui.Parent = auroraPart

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = config.PrimaryColor or Color3.fromRGB(0, 200, 100)
	frame.BackgroundTransparency = 1 - config.Intensity
	frame.BorderSizePixel = 0
	frame.Parent = surfaceGui

	-- Animate the aurora (color shift).
	local connection
	connection = game:GetService("RunService").RenderStepped:Connect(function()
		if not frame.Parent then
			connection:Disconnect()
			return
		end
		local t = tick() * config.Speed
		local r = 0.5 + 0.5 * math.sin(t)
		local g = 0.5 + 0.5 * math.sin(t + 2.094)
		local b = 0.5 + 0.5 * math.sin(t + 4.188)
		frame.BackgroundColor3 = Color3.new(r, g, b)
	end)

	-- Adjust lighting for aurora (slightly dimmer, more colorful ambient).
	TweenService:Create(Lighting, TweenInfo.new(2), {
		Ambient = config.PrimaryColor:Lerp(Color3.fromRGB(128, 128, 128), 0.7),
		OutdoorAmbient = config.SecondaryColor:Lerp(Color3.fromRGB(128, 128, 128), 0.7),
	}):Play()
end

-- ---------------------------------------------------------------------------
-- Lightning Flash
-- ---------------------------------------------------------------------------

function AtmosphereClientController:OnLightningFlashed(thunderVolume: number)
	-- Flash the sky white briefly.
	local originalBrightness = Lighting.Brightness
	Lighting.Brightness = 2.5

	task.delay(0.1, function()
		TweenService:Create(Lighting, TweenInfo.new(0.3), {
			Brightness = originalBrightness,
		}):Play()
	end)

	-- Play thunder sound.
	local thunder = Instance.new("Sound")
	thunder.SoundId = "rbxasset://sounds/thunder.wav"
	thunder.Volume = thunderVolume
	thunder.Parent = workspace
	thunder:Play()

	-- Cleanup after sound finishes.
	game:GetService("Debris"):AddItem(thunder, 5)
end

return AtmosphereClientController