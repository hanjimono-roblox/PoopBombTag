--!strict

-- AtmosphereClientController (Client)
-- Receives atmosphere state from the server and renders visual effects:
--   - Fog (Lighting.Fog* properties)
--   - Rainstorm / Thunderstorm (particle environments + lightning)
--   - Sandstorm (fog + tint)
--   - Blizzard (snow particles + fog, reduced brightness)
--   - Aurora (Lighting.ColorShift animation + ambient tint)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local AtmosphereClientController = {}
AtmosphereClientController.__index = AtmosphereClientController
setmetatable(AtmosphereClientController, { __index = BaseController })

-- Guaranteed textures/sounds
local TEXTURE_SPARKLE = "rbxassetid://342107739"
local TEXTURE_DUST = "rbxassetid://4449491011"
local SOUND_WIND = "rbxassetid://139095330035399"
local SOUND_RAIN = "rbxassetid://138911277964858"
local SOUND_THUNDER = "rbxassetid://133858804746399"

-- Saved original lighting values
local DEFAULT_FOG_COLOR = Color3.fromRGB(128, 128, 128)
local DEFAULT_FOG_START = 0
local DEFAULT_FOG_END = 1000
local DEFAULT_BRIGHTNESS = 1
local DEFAULT_AMBIENT = Color3.fromRGB(128, 128, 128)

function AtmosphereClientController.new()
	local self: any = BaseController.new("AtmosphereClientController")
	self._originalFogColor = Lighting.FogColor
	self._originalFogStart = Lighting.FogStart
	self._originalFogEnd = Lighting.FogEnd
	self._originalBrightness = Lighting.Brightness
	self._originalAmbient = Lighting.Ambient
	self._originalOutdoorAmbient = Lighting.OutdoorAmbient
	self._originalColorShiftTop = Lighting.ColorShift_Top
	self._originalColorShiftBottom = Lighting.ColorShift_Bottom
	self._originalClockTime = Lighting.ClockTime
	self._activeAtmosphere = nil :: any?
	self._particleEmitters = {} :: { ParticleEmitter }
	self._sounds = {} :: { Sound }
	self._auroraConnection = nil :: RBXScriptConnection?
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

function AtmosphereClientController:_OnAtmosphereAction(action: string, ...)
	if action == "AtmosphereApplied" then
		self:OnAtmosphereApplied(...)
	elseif action == "AtmosphereCleared" then
		self:OnAtmosphereCleared()
	elseif action == "LightningFlashed" then
		self:OnLightningFlashed(...)
	end
end

function AtmosphereClientController:OnAtmosphereApplied(atmosphere: any)
	self:_ClearParticles()
	self._activeAtmosphere = atmosphere

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

function AtmosphereClientController:OnAtmosphereCleared()
	-- Restore original lighting.
	TweenService:Create(Lighting, TweenInfo.new(2), {
		FogColor = self._originalFogColor,
		FogStart = self._originalFogStart,
		FogEnd = self._originalFogEnd,
		Brightness = self._originalBrightness,
		Ambient = self._originalAmbient,
		OutdoorAmbient = self._originalOutdoorAmbient,
		ColorShift_Top = self._originalColorShiftTop,
		ColorShift_Bottom = self._originalColorShiftBottom,
		ClockTime = self._originalClockTime,
	}):Play()

	self:_ClearParticles()
	self._activeAtmosphere = nil
end

function AtmosphereClientController:_ClearParticles()
	if self._auroraConnection then
		self._auroraConnection:Disconnect()
		self._auroraConnection = nil
	end

	for _, emitter in ipairs(self._particleEmitters) do
		local parent = emitter.Parent
		if parent then
			emitter.Enabled = false
			emitter:Destroy()
		end
		if parent and parent:IsA("BasePart") then
			parent:Destroy()
		end
	end
	self._particleEmitters = {}

	for _, sound in ipairs(self._sounds) do
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end
	self._sounds = {}
end

function AtmosphereClientController:_CreateEmitterPart(name: string, position: Vector3, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Size = size
	part.Position = position
	part.Parent = workspace
	return part
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
	local rainPart = self:_CreateEmitterPart("RainstormEmitter", Vector3.new(0, 80, 0), Vector3.new(200, 1, 200))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = config.Intensity * 5
	emitter.Texture = TEXTURE_SPARKLE
	emitter.VelocityInheritance = 0
	emitter.Lifetime = NumberRange.new(3, 5)
	emitter.SpreadAngle = Vector2.new(5, 5)
	emitter.Speed = NumberRange.new(40, 60)
	emitter.Drag = 5
	emitter.Transparency = NumberSequence.new(0.3)
	emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 220))
	emitter.Enabled = true
	emitter.Parent = rainPart
	table.insert(self._particleEmitters, emitter)

	local targetBrightness = math.max(0.3, Lighting.Brightness * 0.5)
	TweenService:Create(Lighting, TweenInfo.new(2), {
		Brightness = targetBrightness,
		FogStart = math.max(5, Lighting.FogStart),
		FogEnd = math.max(30, Lighting.FogEnd),
	}):Play()

	local rainSound = Instance.new("Sound")
	rainSound.SoundId = SOUND_RAIN
	rainSound.Volume = 0.3
	rainSound.Looped = true
	rainSound.Parent = rainPart
	rainSound:Play()
	table.insert(self._sounds, rainSound)
end

-- ---------------------------------------------------------------------------
-- Sandstorm
-- ---------------------------------------------------------------------------
function AtmosphereClientController:_ApplySandstorm(config: any)
	TweenService:Create(Lighting, TweenInfo.new(2), {
		FogColor = config.FogColor,
		FogStart = config.FogStart,
		FogEnd = config.FogEnd,
		Brightness = math.max(0.2, Lighting.Brightness * (config.SkyDarkening or 0.5)),
	}):Play()

	local sandPart = self:_CreateEmitterPart("SandstormEmitter", Vector3.new(0, 50, 0), Vector3.new(200, 1, 200))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = config.ParticleIntensity * 3
	emitter.Texture = TEXTURE_DUST
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

	local windSound = Instance.new("Sound")
	windSound.SoundId = SOUND_WIND
	windSound.Volume = 0.4
	windSound.Looped = true
	windSound.Parent = sandPart
	windSound:Play()
	table.insert(self._sounds, windSound)
end

-- ---------------------------------------------------------------------------
-- Blizzard
-- ---------------------------------------------------------------------------
function AtmosphereClientController:_ApplyBlizzard(config: any)
	TweenService:Create(Lighting, TweenInfo.new(2), {
		FogColor = config.FogColor,
		FogStart = config.FogStart,
		FogEnd = config.FogEnd,
		Brightness = math.max(0.25, Lighting.Brightness * 0.55),
		Ambient = config.SkyTint or Color3.fromRGB(180, 190, 210),
		ClockTime = 14,
	}):Play()

	local snowPart = self:_CreateEmitterPart("BlizzardEmitter", Vector3.new(0, 80, 0), Vector3.new(250, 1, 250))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = config.ParticleIntensity * 4
	emitter.Texture = TEXTURE_SPARKLE
	emitter.VelocityInheritance = 0
	emitter.Lifetime = NumberRange.new(4, 7)
	emitter.SpreadAngle = Vector2.new(15, 15)
	emitter.Speed = NumberRange.new(5, 15)
	emitter.Drag = 2
	emitter.Transparency = NumberSequence.new(0.15)
	emitter.Color = ColorSequence.new(Color3.fromRGB(230, 240, 255))
	emitter.Size = NumberSequence.new{NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0.8)}
	emitter.Enabled = true
	emitter.Parent = snowPart
	table.insert(self._particleEmitters, emitter)

	local driftPart = self:_CreateEmitterPart("BlizzardDrift", Vector3.new(-100, 20, 0), Vector3.new(10, 1, 200))
	local drift = Instance.new("ParticleEmitter")
	drift.Rate = config.ParticleIntensity * 2
	drift.Texture = TEXTURE_SPARKLE
	drift.VelocityInheritance = 0
	drift.Lifetime = NumberRange.new(2, 5)
	drift.SpreadAngle = Vector2.new(1, 10)
	drift.Speed = NumberRange.new(20, 40)
	drift.Drag = 3
	drift.Transparency = NumberSequence.new(0.2)
	drift.Color = ColorSequence.new(Color3.fromRGB(200, 210, 220))
	drift.Size = NumberSequence.new{NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.5)}
	drift.Enabled = true
	drift.Parent = driftPart
	table.insert(self._particleEmitters, drift)

	local windSound = Instance.new("Sound")
	windSound.SoundId = SOUND_WIND
	windSound.Volume = 0.35
	windSound.Looped = true
	windSound.Parent = snowPart
	windSound:Play()
	table.insert(self._sounds, windSound)
end

-- ---------------------------------------------------------------------------
-- Aurora (Lighting.ColorShift + Ambient animation, no GUI overlay)
-- ---------------------------------------------------------------------------
function AtmosphereClientController:_ApplyAurora(config: any)
	local primary = config.PrimaryColor or Color3.fromRGB(0, 200, 100)
	local secondary = config.SecondaryColor or Color3.fromRGB(100, 0, 200)
	local intensity = config.Intensity or 0.6
	local speed = config.Speed or 0.3

	-- Initial color push.
	Lighting.ColorShift_Top = primary
	Lighting.ColorShift_Bottom = secondary:Lerp(Color3.fromRGB(10, 10, 30), 0.5)

	-- Animate the sky colors on RenderStepped.
	self._auroraConnection = RunService.RenderStepped:Connect(function()
		if not Lighting then
			if self._auroraConnection then
				self._auroraConnection:Disconnect()
				self._auroraConnection = nil
			end
			return
		end

		local t = tick() * speed

		-- Blend primary and secondary in a wave pattern.
		local blend = 0.5 + 0.5 * math.sin(t * 0.5)
		local topColor = primary:Lerp(secondary, blend)
		-- Blend the top color toward dark for the bottom.
		local bottomColor = topColor:Lerp(Color3.new(0.05, 0.05, 0.15), 0.3 + 0.4 * math.sin(t * 0.3 + 1.0))

		-- Apply with intensity multiplier (transparency-like effect by lerping toward neutral).
		local neutralTop = Color3.new(0.4, 0.5, 0.6)
		local neutralBottom = Color3.new(0.1, 0.1, 0.15)

		Lighting.ColorShift_Top = topColor:Lerp(neutralTop, 1 - intensity)
		Lighting.ColorShift_Bottom = bottomColor:Lerp(neutralBottom, 1 - intensity * 0.7)
	end)

	-- Adjust ambient to complement.
	TweenService:Create(Lighting, TweenInfo.new(3), {
		Ambient = primary:Lerp(Color3.fromRGB(40, 40, 60), 0.5),
		OutdoorAmbient = secondary:Lerp(Color3.fromRGB(40, 40, 60), 0.5),
		Brightness = math.max(0.4, Lighting.Brightness * 0.8),
	}):Play()
end

-- ---------------------------------------------------------------------------
-- Lightning Flash
-- ---------------------------------------------------------------------------
function AtmosphereClientController:OnLightningFlashed(thunderVolume: number)
	local originalBrightness = Lighting.Brightness
	Lighting.Brightness = 3

	task.delay(0.08, function()
		TweenService:Create(Lighting, TweenInfo.new(0.2), {
			Brightness = originalBrightness,
		}):Play()
	end)

	local thunder = Instance.new("Sound")
	thunder.SoundId = SOUND_THUNDER
	thunder.Volume = thunderVolume or 0.5
	thunder.Parent = workspace
	thunder:Play()
	Debris:AddItem(thunder, 5)
end

return AtmosphereClientController