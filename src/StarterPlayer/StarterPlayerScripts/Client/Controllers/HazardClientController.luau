--!strict

-- HazardClientController (Client)
-- Receives hazard events from the server and renders client-side effects.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local HazardClientController = {}
HazardClientController.__index = HazardClientController
setmetatable(HazardClientController, { __index = BaseController })

-- Tornado tuning
local TORNADO_MOVE_TWEEN_SPEED = 0.3  -- seconds to tween to new position

function HazardClientController.new()
	local self: any = BaseController.new("HazardClientController")
	self._isShaking = false
	self._shakeMagnitude = 0
	-- Tornado state
	self._tornadoAnchor = nil :: Part?
	self._tornadoEmitters = {} :: { ParticleEmitter }
	self._tornadoSounds = {} :: { Sound }
	-- Health bar state
	self._healthBarBillboard = nil :: BillboardGui?
	self._healthBarFill = nil :: Frame?
	self._healthBarLabel = nil :: TextLabel?
	self._healthBarHideThread = nil :: thread?
	return setmetatable(self, HazardClientController)
end

function HazardClientController:Start()
	BaseController.Start(self)
	print("HazardClientController started")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local hazardRemote = remotes:WaitForChild("HazardEvent")

	hazardRemote.OnClientEvent:Connect(function(action: string, ...)
		self:_OnHazardAction(action, ...)
	end)
end

function HazardClientController:_OnHazardAction(action: string, ...)
	if action == "EarthquakeStarted" then
		self:OnEarthquakeStarted(...)
	elseif action == "EarthquakeEnded" then
		self:OnEarthquakeEnded()
	elseif action == "LightningFlash" then
		self:OnLightningFlash(...)
	elseif action == "HazardDamaged" then
		local _player, _damageAmount, currentHealth, hazardName = ...
		self:OnHazardDamaged(currentHealth, hazardName)
	elseif action == "FireGeyserErupted" then
		self:OnFireGeyserErupted(...)
	elseif action == "TornadoStarted" then
		local position, radius, visualConfig = ...
		self:OnTornadoStarted(position, radius, visualConfig)
	elseif action == "TornadoMoved" then
		self:OnTornadoMoved(...)
	elseif action == "TornadoEnded" then
		self:OnTornadoEnded()
	elseif action == "FloodStarted" then
		self:OnFloodStarted(...)
	elseif action == "FloodHeightChanged" then
		self:OnFloodHeightChanged(...)
	end
end

-- ---------------------------------------------------------------------------
-- Earthquake (camera shake that follows player)
-- ---------------------------------------------------------------------------
function HazardClientController:OnEarthquakeStarted(magnitude: number, duration: number)
	self._isShaking = true
	local camera = workspace.CurrentCamera
	local elapsed = 0

	local connection = RunService.RenderStepped:Connect(function(dt)
		if not self._isShaking or elapsed >= duration then
			connection:Disconnect()
			return
		end
		local offset = Vector3.new(
			math.random(-100, 100) / 100 * magnitude,
			math.random(-100, 100) / 100 * magnitude,
			math.random(-50, 50) / 100 * magnitude
		)
		camera.CFrame = camera.CFrame * CFrame.new(offset)
		elapsed = elapsed + dt
	end)
end

function HazardClientController:OnEarthquakeEnded()
	self._isShaking = false
end

-- ---------------------------------------------------------------------------
-- Lightning Flash
-- ---------------------------------------------------------------------------
function HazardClientController:OnLightningFlash(_thunderVolume: number?)
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "LightningFlash"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	frame.BackgroundTransparency = 0.6
	frame.BorderSizePixel = 0
	frame.Parent = gui

	TweenService:Create(frame, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
	task.delay(0.5, function() gui:Destroy() end)
end

-- ---------------------------------------------------------------------------
-- Health Bar (head-attached BillboardGui, local player only)
-- ---------------------------------------------------------------------------

-- Max health value (match GameConfig.Player.DefaultHealth)
local MAX_HEALTH = 100

-- How long the health bar stays visible after the last damage event (seconds)
local HEALTHBAR_HIDE_DELAY = 3

-- Returns a Color3 for a given health ratio (0-1): green → yellow → red
local function _HealthColor(ratio: number): Color3
	if ratio > 0.6 then
		return Color3.new(1 - ratio, 1, 0)  -- green to yellow
	else
		return Color3.new(1, ratio * 1.6, 0)  -- yellow to red
	end
end

function HazardClientController:OnHazardDamaged(currentHealth: number?, _hazardName: string?)
	-- Keep the brief red screen flash for immediate feedback.
	self:_ShowDamageFlash()

	local health = math.clamp(currentHealth or MAX_HEALTH, 0, MAX_HEALTH)
	local ratio = health / MAX_HEALTH

	local character = Players.LocalPlayer.Character
	if not character then return end

	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then return end

	-- Find or create the BillboardGui on the head.
	if not self._healthBarBillboard or not self._healthBarBillboard.Parent then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "HazardHealthBar"
		billboard.Adornee = head
		billboard.Size = UDim2.fromOffset(80, 16)
		billboard.StudsOffset = Vector3.new(0, 3.5, 0)
		billboard.AlwaysOnTop = true
		billboard.MaxDistance = 100
		billboard.Enabled = true
		billboard.Parent = head

		-- Dark background frame
		local bg = Instance.new("Frame")
		bg.Name = "Background"
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		bg.BorderSizePixel = 0
		bg.Parent = billboard

		-- Colored fill frame
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(ratio, 1)
		fill.BackgroundColor3 = _HealthColor(ratio)
		fill.BorderSizePixel = 0
		fill.Parent = bg

		-- HP text label
		local label = Instance.new("TextLabel")
		label.Name = "HPText"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = `{health}/{MAX_HEALTH}`
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.BorderSizePixel = 0
		label.Parent = billboard

		self._healthBarBillboard = billboard
		self._healthBarFill = fill
		self._healthBarLabel = label
	else
		-- Update existing bar
		if self._healthBarFill then
			self._healthBarFill.Size = UDim2.fromScale(ratio, 1)
			self._healthBarFill.BackgroundColor3 = _HealthColor(ratio)
		end
		if self._healthBarLabel then
			self._healthBarLabel.Text = `{health}/{MAX_HEALTH}`
		end
	end

	-- Reset the hide timer.
	if self._healthBarHideThread then
		task.cancel(self._healthBarHideThread)
	end

	self._healthBarHideThread = task.spawn(function()
		task.wait(HEALTHBAR_HIDE_DELAY)
		if self._healthBarBillboard and self._healthBarBillboard.Parent then
			self._healthBarBillboard:Destroy()
		end
		self._healthBarBillboard = nil
		self._healthBarFill = nil
		self._healthBarLabel = nil
		self._healthBarHideThread = nil
	end)
end

-- Brief red overlay flash (kept from original)
function HazardClientController:_ShowDamageFlash()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local gui = Instance.new("ScreenGui")
	gui.Name = "DamageFlash"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 90
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	frame.BackgroundTransparency = 0.8
	frame.BorderSizePixel = 0
	frame.Parent = gui

	TweenService:Create(frame, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
	task.delay(0.4, function() gui:Destroy() end)
end

-- ---------------------------------------------------------------------------
-- Fire Geyser
-- ---------------------------------------------------------------------------
function HazardClientController:OnFireGeyserErupted(position: Vector3, height: number?, duration: number?)
	local firePart = Instance.new("Part")
	firePart.Name = "GeyserEruption"
	firePart.Anchored = true
	firePart.CanCollide = false
	firePart.Size = Vector3.new(3, height or 30, 3)
	firePart.Position = position
	firePart.Color = Color3.fromRGB(255, 100, 20)
	firePart.Material = Enum.Material.Neon
	firePart.Transparency = 0.3
	firePart.Parent = workspace

	local fire = Instance.new("Fire")
	fire.Heat = 15
	fire.Size = 8
	fire.Parent = firePart

	task.delay(duration or 2, function() firePart:Destroy() end)
end

-- ---------------------------------------------------------------------------
-- Tornado Visual (Particle-based Swirl)
-- ---------------------------------------------------------------------------
function HazardClientController:OnTornadoStarted(position: Vector3, _radius: number?, visualConfig: any?)
	self:_CleanupTornado()

	-- Read visual config from server (supplied in map config).
	local baseRadius = (visualConfig and visualConfig.BaseRadius) or 3
	local topRadius = (visualConfig and visualConfig.TopRadius) or 18
	local maxHeight = (visualConfig and visualConfig.MaxHeight) or 45
	local particleRate = (visualConfig and visualConfig.ParticleRate) or 100

	print(`[Tornado] Creating particle tornado: baseR={baseRadius} topR={topRadius} height={maxHeight} rate={particleRate}`)

	-- Unanchored anchor held in place by BodyPosition / BodyGyro.
	-- AngularVelocity spins it so all child emitters swirl.
	local anchor = Instance.new("Part")
	anchor.Name = "TornadoAnchor"
	anchor.Anchored = false
	anchor.CanCollide = false
	anchor.Massless = true
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = position
	anchor.Parent = workspace
	self._tornadoAnchor = anchor

	local bp = Instance.new("BodyPosition")
	bp.Position = position
	bp.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bp.D = 500
	bp.Parent = anchor

	local bg = Instance.new("BodyGyro")
	bg.CFrame = CFrame.new(position)
	bg.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	bg.D = 100
	bg.Parent = anchor

	local spin = Instance.new("AngularVelocity")
	spin.AngularVelocity = Vector3.new(0, 20, 0)
	spin.MaxTorque = Vector3.new(0, math.huge, 0)
	spin.Parent = anchor

	-- Funnel emitter: spreads wider toward the top (ZOffset simulates height).
	-- Size at ground level = baseRadius, size at max height = topRadius.
	local funnelSizeStart = baseRadius * 0.5
	local funnelSizeEnd = topRadius * 0.5
	local funnel = Instance.new("ParticleEmitter")
	funnel.Rate = particleRate
	funnel.Texture = "rbxasset://textures/particles/smoke_main.dds"
	funnel.VelocityInheritance = 0.6
	funnel.Lifetime = NumberRange.new(1.5, 3)
	funnel.RotSpeed = NumberRange.new(-120, 120)
	funnel.SpreadAngle = Vector2.new(3, 2)
	funnel.Speed = NumberRange.new(15, 35)
	funnel.Drag = 1
	funnel.Transparency = NumberSequence.new{ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(0.5, 0.3), NumberSequenceKeypoint.new(1, 0.95) }
	funnel.Color = ColorSequence.new(Color3.fromRGB(120, 110, 95))
	funnel.Size = NumberSequence.new{ NumberSequenceKeypoint.new(0, funnelSizeStart), NumberSequenceKeypoint.new(0.5, (funnelSizeStart + funnelSizeEnd) / 2), NumberSequenceKeypoint.new(1, funnelSizeEnd) }
	funnel.Acceleration = Vector3.new(0, 12, 0)
	funnel.ZOffset = -maxHeight * 0.5
	funnel.Enabled = true
	funnel.Parent = anchor
	table.insert(self._tornadoEmitters, funnel)

	-- Debris emitter: outward-flying, matches base width.
	local debris = Instance.new("ParticleEmitter")
	debris.Rate = particleRate * 0.5
	debris.Texture = "rbxasset://textures/particles/dust_01.dds"
	debris.VelocityInheritance = 0.4
	debris.Lifetime = NumberRange.new(1, 2.5)
	debris.RotSpeed = NumberRange.new(-180, 180)
	debris.SpreadAngle = Vector2.new(360, 20)
	debris.Speed = NumberRange.new(10, 35)
	debris.Drag = 4
	debris.Transparency = NumberSequence.new{ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 0.9) }
	debris.Color = ColorSequence.new(Color3.fromRGB(100, 90, 70))
	debris.Size = NumberSequence.new{ NumberSequenceKeypoint.new(0, funnelSizeStart * 0.3), NumberSequenceKeypoint.new(1, funnelSizeStart * 0.8) }
	debris.Acceleration = Vector3.new(0, -6, 0)
	debris.TangentialAcceleration = 8
	debris.Enabled = true
	debris.Parent = anchor
	table.insert(self._tornadoEmitters, debris)

	-- Ground dust emitter: slow horizontal spread at base.
	local dust = Instance.new("ParticleEmitter")
	dust.Rate = particleRate * 0.25
	dust.Texture = "rbxasset://textures/particles/sparkle_01.dds"
	dust.VelocityInheritance = 0.2
	dust.Lifetime = NumberRange.new(2, 4)
	dust.RotSpeed = NumberRange.new(-45, 45)
	dust.SpreadAngle = Vector2.new(360, 3)
	dust.Speed = NumberRange.new(3, 15)
	dust.Drag = 12
	dust.Transparency = NumberSequence.new{ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.95) }
	dust.Color = ColorSequence.new(Color3.fromRGB(160, 145, 120))
	dust.Size = NumberSequence.new{ NumberSequenceKeypoint.new(0, funnelSizeStart * 0.2), NumberSequenceKeypoint.new(1, funnelSizeStart * 1.5) }
	dust.Acceleration = Vector3.new(0, -2, 0)
	dust.TangentialAcceleration = 4
	dust.Enabled = true
	dust.Parent = anchor
	table.insert(self._tornadoEmitters, dust)

	-- Wind sound.
	local windSound = Instance.new("Sound")
	windSound.SoundId = "rbxasset://139095330035399"
	windSound.Volume = 0.5
	windSound.Looped = true
	windSound.Parent = anchor
	windSound:Play()
	table.insert(self._tornadoSounds, windSound)

	print("[Tornado] Config-driven tornado created")
end

function HazardClientController:OnTornadoMoved(position: Vector3)
	local anchor = self._tornadoAnchor
	if not anchor then return end

	-- Move BodyPosition target so anchor glides to new position.
	local bp = anchor:FindFirstChildOfClass("BodyPosition")
	if bp then
		bp.Position = position
	end
	local bg = anchor:FindFirstChildOfClass("BodyGyro")
	if bg then
		bg.CFrame = CFrame.new(position)
	end
end

function HazardClientController:OnTornadoEnded()
	-- Fade out emitters, then cleanup.
	for _, emitter in ipairs(self._tornadoEmitters) do
		if emitter.Parent then
			emitter.Enabled = false
		end
	end
	task.delay(1, function() self:_CleanupTornado() end)
end

function HazardClientController:_CleanupTornado()
	if self._tornadoAnchor and self._tornadoAnchor.Parent then
		self._tornadoAnchor:Destroy()
	end
	self._tornadoAnchor = nil

	for _, emitter in ipairs(self._tornadoEmitters) do
		if emitter.Parent then
			emitter.Parent:Destroy()
		end
	end
	self._tornadoEmitters = {}

	for _, sound in ipairs(self._tornadoSounds) do
		if sound.Parent then
			sound:Stop()
			sound:Destroy()
		end
	end
	self._tornadoSounds = {}
end

-- ---------------------------------------------------------------------------
-- Flood Visual
-- ---------------------------------------------------------------------------
function HazardClientController:OnFloodStarted(_startHeight: number?, _maxHeight: number?)
	print("Flood started")
end

function HazardClientController:OnFloodHeightChanged(height: number?)
	print(`Flood height: {height}`)
end

return HazardClientController