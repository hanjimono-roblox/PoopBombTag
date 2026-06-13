--!strict

-- HazardClientController (Client)
-- Receives hazard events from the server and renders client-side effects:
--   - Camera shake during earthquakes
--   - Screen flash / overlay effects
--   - Health bar overlay when taking damage
--
-- This controller listens to the HazardEvent RemoteEvent for sync events
-- (earthquake start/end, lightning flash, etc.).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local HazardClientController = {}
HazardClientController.__index = HazardClientController
setmetatable(HazardClientController, { __index = BaseController })

function HazardClientController.new()
	local self: any = BaseController.new("HazardClientController")
	-- Whether the camera is currently shaking from an earthquake
	self._isShaking = false
	-- Earthquake shake magnitude
	self._shakeMagnitude = 0
	-- A ScreenGui for damage overlay / health bar
	self._damageGui = nil :: ScreenGui?
	self._damageFrame = nil :: Frame?
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

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

function HazardClientController:_OnHazardAction(action: string, ...)
	if action == "EarthquakeStarted" then
		local magnitude, duration = ... :: number, ... :: number
		self:OnEarthquakeStarted(magnitude, duration)

	elseif action == "EarthquakeEnded" then
		self:OnEarthquakeEnded()

	elseif action == "LightningFlash" then
		local thunderVolume = ... :: number
		self:OnLightningFlash(thunderVolume)

	elseif action == "HazardDamaged" then
		local _, _, currentHealth, hazardName = ... :: Player, ... :: number, ... :: number, ... :: string
		self:OnHazardDamaged(currentHealth, hazardName)

	elseif action == "FireGeyserErupted" then
		local position, height, duration = ... :: Vector3, ... :: number, ... :: number
		self:OnFireGeyserErupted(position, height, duration)

	elseif action == "TornadoStarted" then
		local position, radius = ... :: Vector3, ... :: number
		self:OnTornadoStarted(position, radius)

	elseif action == "TornadoMoved" then
		local position = ... :: Vector3
		self:OnTornadoMoved(position)

	elseif action == "TornadoEnded" then
		self:OnTornadoEnded()

	elseif action == "FloodStarted" then
		local startHeight, maxHeight = ... :: number, ... :: number
		self:OnFloodStarted(startHeight, maxHeight)

	elseif action == "FloodHeightChanged" then
		local height = ... :: number
		self:OnFloodHeightChanged(height)
	end
end

-- ---------------------------------------------------------------------------
-- Earthquake
-- ---------------------------------------------------------------------------

function HazardClientController:OnEarthquakeStarted(magnitude: number, duration: number)
	self._isShaking = true
	self._shakeMagnitude = magnitude

	-- Run camera shake on RenderStepped for the duration.
	local camera = workspace.CurrentCamera
	local originalCFrame = camera.CFrame

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
		camera.CFrame = originalCFrame * CFrame.new(offset)

		elapsed = elapsed + dt
	end)

	-- Ensure camera returns to original after duration.
	task.delay(duration, function()
		camera.CFrame = originalCFrame
	end)
end

function HazardClientController:OnEarthquakeEnded()
	self._isShaking = false
end

-- ---------------------------------------------------------------------------
-- Lightning Flash
-- ---------------------------------------------------------------------------

function HazardClientController:OnLightningFlash(thunderVolume: number)
	-- Flash the screen white briefly.
	self:_ShowScreenFlash()
end

function HazardClientController:_ShowScreenFlash()
	-- Create a temporary ScreenGui with a white frame.
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

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

	-- Fade out and destroy.
	local tween = TweenService:Create(
		frame,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Wait()

	gui:Destroy()
end

-- ---------------------------------------------------------------------------
-- Hazard Damage Feedback
-- ---------------------------------------------------------------------------

function HazardClientController:OnHazardDamaged(currentHealth: number, hazardName: string)
	-- Show a brief red overlay / flash to indicate damage.
	self:_ShowDamageFlash()

	-- TODO: Update a health bar UI element.
end

function HazardClientController:_ShowDamageFlash()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

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

	local tween = TweenService:Create(
		frame,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()
	tween.Completed:Wait()

	gui:Destroy()
end

-- ---------------------------------------------------------------------------
-- Fire Geyser Visual
-- ---------------------------------------------------------------------------

function HazardClientController:OnFireGeyserErupted(position: Vector3, height: number, duration: number)
	-- Spawn a fire beam/column at the position (visual only).
	-- This creates a temporary part as a visual placeholder.
	local firePart = Instance.new("Part")
	firePart.Name = "GeyserEruption"
	firePart.Anchored = true
	firePart.CanCollide = false
	firePart.Size = Vector3.new(3, 1, 3)
	firePart.Position = position
	firePart.BrickColor = BrickColor.new("Bright red")
	firePart.Material = Enum.Material.Neon
	firePart.Transparency = 0.3
	firePart.Parent = workspace

	local fire = Instance.new("Fire")
	fire.Heat = 15
	fire.Size = 8
	fire.Parent = firePart

	-- Fade out and destroy after eruption duration.
	task.delay(duration, function()
		local tween = TweenService:Create(
			firePart,
			TweenInfo.new(0.3),
			{ Transparency = 1 }
		)
		tween:Play()
		tween.Completed:Wait()
		firePart:Destroy()
	end)
end

-- ---------------------------------------------------------------------------
-- Tornado Visual
-- ---------------------------------------------------------------------------

function HazardClientController:OnTornadoStarted(_position: Vector3, _radius: number)
	-- Client-side can spawn a visual tornado indicator.
	-- For now, this is a placeholder -- a full particle tornado would be
	-- created with ParticleEmitters in a more detailed implementation.
	print("Tornado started")
end

function HazardClientController:OnTornadoMoved(_position: Vector3)
	-- Update tornado visual position if we had one.
end

function HazardClientController:OnTornadoEnded()
	print("Tornado ended")
end

-- ---------------------------------------------------------------------------
-- Flood Visual
-- ---------------------------------------------------------------------------

function HazardClientController:OnFloodStarted(_startHeight: number, _maxHeight: number)
	print("Flood started")
end

function HazardClientController:OnFloodHeightChanged(_height: number)
	-- The server creates the water plane; clients see it via replication.
	-- This could trigger audio or visual cues.
end

return HazardClientController