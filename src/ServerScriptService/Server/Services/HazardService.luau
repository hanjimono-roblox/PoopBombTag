--!strict
--[[
	HazardService (Server, Authority)

	Owns all mechanical hazard systems that damage players and affect
	the game environment. Works in tandem with per-map configs defined
	in ServerStorage/MapConfigs.

	Architecture:
	  - Listens to MapLoaded event to read the active map's hazard config.
	  - Scans the loaded map for parts tagged with Attribute("HazardType", ...).
	  - Manages per-player health (default 100). When health hits 0,
	    calls RoundManager:EliminatePlayer.
	  - Stops all loops on MapUnloaded / RoundEnded.

	Hazards implemented:
	  - Lava:   Touched-based DOT on tagged parts.
	  - Earthquake: Periodic camera shake + impulse to all players.
	  - Flood:  Rising water plane with submersion damage.
	  - FireGeyser: Timed eruption at tagged locations.
	  - Tornado: Wandering vortex that pulls and damages players.

	Health system:
	  - _playerHealth: {[Player]: number} — reset to GameConfig.Player.DefaultHealth
	    at round start for all ActiveParticipants.
	  - Health is NOT synced to clients by this service. Client receives
	    damage events via ReplicationService for UI feedback.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local HazardService = {}
HazardService.__index = HazardService
setmetatable(HazardService, { __index = BaseService })

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local HAZARD_ATTRIBUTE = "HazardType"
local HEALTH_KEY = "DefaultHealth"
local DEFAULT_HEALTH = GameConfig.Player.DefaultHealth

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function HazardService.new()
	local self: any = BaseService.new("HazardService")
	-- Per-player health pool
	self._playerHealth = {} :: { [Player]: number }
	-- Active hazard config (from loaded map's config)
	self._hazardConfig = nil :: any?
	-- Track all spawned instances (water plane, etc.) for cleanup
	self._spawnedInstances = {} :: { Instance }
	-- Active threads for cleanup
	self._threads = {} :: { thread }
	-- Cached tagged parts from the current map
	self._lavaParts = {} :: { BasePart }
	self._fireGeyserParts = {} :: { BasePart }
	self._waterSourcePart = nil :: BasePart?
	self._tornadoPathParts = {} :: { BasePart }
	self._shakeableParts = {} :: { BasePart }
	-- Tracks players currently in lava (for DOT tick cooldown)
	self._lavaTouching = {} :: { [Player]: number }
	-- Tracks players currently in tornado zone
	self._tornadoTargets = {} :: { [Player]: boolean }
	-- Whether a round is active (we listen to RoundStarted/RoundEnded)
	self._roundActive = false
	return setmetatable(self, HazardService)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function HazardService:Start()
	BaseService.Start(self)

	-- When a map is loaded, read its hazard config and scan for tagged parts.
	EventManager:Connect(EventNames.MapLoaded, function(mapName: string, mapInstance: Instance)
		self:_OnMapLoaded(mapName, mapInstance)
	end)

	-- When a round starts, initialize player health and start hazard loops.
	EventManager:Connect(EventNames.RoundStarted, function()
		self:_OnRoundStarted()
	end)

	-- When a round ends, stop all hazards and clear health.
	EventManager:Connect(EventNames.RoundEnded, function()
		self:_OnRoundEnded()
	end)

	-- When a map is unloaded, clean up everything.
	EventManager:Connect(EventNames.MapUnloaded, function()
		self:_CleanupAll()
	end)

	self.Services:Get("LoggingService"):Info("HAZARD", "HazardService started")
end

-- ---------------------------------------------------------------------------
-- Map Loading
-- ---------------------------------------------------------------------------

function HazardService:_OnMapLoaded(mapName: string, mapInstance: Instance)
	-- Read the config from ServerStorage/MapConfigs.
	local configsFolder = game:GetService("ServerStorage"):FindFirstChild("MapConfigs")
	if not configsFolder then
		return
	end

	local configModule = configsFolder:FindFirstChild(mapName .. "Config")
	if not configModule or not configModule:IsA("ModuleScript") then
		self.Services:Get("LoggingService"):Warn("HAZARD", `No config found for map: {mapName}`)
		return
	end

	local config = require(configModule)
	self._hazardConfig = config.Hazards or {}

	-- Scan the loaded map instance for tagged parts.
	self:_ScanMapForHazardParts(mapInstance)
end

function HazardService:_ScanMapForHazardParts(mapInstance: Instance)
	self._lavaParts = {}
	self._fireGeyserParts = {}
	self._waterSourcePart = nil
	self._tornadoPathParts = {}
	self._shakeableParts = {}

	-- Descend into the entire map and collect parts by their HazardType attribute.
	for _, part in ipairs(mapInstance:GetDescendants()) do
		if part:IsA("BasePart") then
			local hazardType = part:GetAttribute(HAZARD_ATTRIBUTE)
			if hazardType then
				if hazardType == "Lava" then
					table.insert(self._lavaParts, part)
				elseif hazardType == "FireGeyser" then
					table.insert(self._fireGeyserParts, part)
				elseif hazardType == "WaterSource" then
					self._waterSourcePart = part
				elseif hazardType == "TornadoPath" then
					table.insert(self._tornadoPathParts, part)
				end
			end

			-- Check for shakeable attribute for earthquakes.
			if part:GetAttribute("Shakeable") == true then
				table.insert(self._shakeableParts, part)
			end
		end
	end

	local logging = self.Services:Get("LoggingService")
	logging:Info("HAZARD",
		`Scanned map: {#self._lavaParts} lava, {#self._fireGeyserParts} geyser, ` ..
		`{if self._waterSourcePart then "1" else "0"} water, ` ..
		`{#self._tornadoPathParts} tornado waypoints, {#self._shakeableParts} shakeable`
	)
end

-- ---------------------------------------------------------------------------
-- Round Lifecycle
-- ---------------------------------------------------------------------------

function HazardService:_OnRoundStarted()
	self._roundActive = true

	-- Initialize health for all ActiveParticipants.
	local stateService = self.Services:Get("PlayerStateService")
	local participants = stateService:GetActiveParticipants()
	for _, player in ipairs(participants) do
		self._playerHealth[player] = DEFAULT_HEALTH
	end

	-- Also listen for new participants during the round (arena entries).
	-- They start with full health.
	EventManager:Connect(EventNames.ArenaEntered, function(player: Player)
		if self._roundActive and self._playerHealth[player] == nil then
			self._playerHealth[player] = DEFAULT_HEALTH
		end
	end)

	-- Start hazard loops based on config.
	local config = self._hazardConfig
	if not config then
		return
	end

	if config.Lava and config.Lava.Enabled then
		self:_StartLavaLoop(config.Lava)
	end

	if config.Earthquake and config.Earthquake.Enabled then
		self:_StartEarthquakeLoop(config.Earthquake)
	end

	if config.Flood and config.Flood.Enabled then
		self:_StartFloodLoop(config.Flood)
	end

	if config.FireGeyser and config.FireGeyser.Enabled then
		self:_StartFireGeyserLoop(config.FireGeyser)
	end

	if config.Tornado and config.Tornado.Enabled then
		self:_StartTornadoLoop(config.Tornado)
	end
end

function HazardService:_OnRoundEnded()
	self._roundActive = false
	self:_StopAllLoops()

	-- Clear health.
	self._playerHealth = {}
	self._lavaTouching = {}
	self._tornadoTargets = {}
end

-- ---------------------------------------------------------------------------
-- Health System
-- ---------------------------------------------------------------------------

function HazardService:GetPlayerHealth(player: Player): number
	return self._playerHealth[player] or DEFAULT_HEALTH
end

-- Deals damage to a player from a hazard source. If health reaches 0,
-- eliminates the player via RoundManager.
function HazardService:_DamagePlayer(player: Player, damageAmount: number, hazardName: string)
	if not self._roundActive then
		return
	end
	if not self._playerHealth[player] then
		return
	end

	self._playerHealth[player] = math.max(0, self._playerHealth[player] - damageAmount)

	local currentHealth = self._playerHealth[player]

	-- Fire damage event for client UI feedback.
	EventManager:Fire(EventNames.HazardDamaged, player, damageAmount, currentHealth, hazardName)

	if currentHealth <= 0 then
		-- Eliminate the player.
		self._playerHealth[player] = nil
		EventManager:Fire(EventNames.HazardEliminated, player, hazardName)
		self.Services:Get("RoundManager"):EliminatePlayer(player, `Killed by {hazardName}`)
	end
end

-- ---------------------------------------------------------------------------
-- Lava Hazard
-- ---------------------------------------------------------------------------

function HazardService:_StartLavaLoop(config: any)
	if #self._lavaParts == 0 then
		self.Services:Get("LoggingService"):Warn("HAZARD", "Lava enabled but no Lava-tagged parts found")
		return
	end

	-- Connect Touched events to each lava part.
	for _, lavaPart in ipairs(self._lavaParts) do
		lavaPart.Touched:Connect(function(hit: BasePart)
			self:_OnLavaTouched(lavaPart, hit, config)
		end)
	end

	self.Services:Get("LoggingService"):Info("HAZARD", "Lava hazard active")
end

function HazardService:_OnLavaTouched(lavaPart: BasePart, hit: BasePart, config: any)
	if not self._roundActive then
		return
	end

	local character = hit.Parent
	if not character then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player or not self._playerHealth[player] then
		return
	end

	-- Cooldown check to prevent rapid-fire damage ticks.
	local now = tick()
	local lastTick = self._lavaTouching[player] or 0
	if now - lastTick < config.TickCooldown then
		return
	end
	self._lavaTouching[player] = now

	self:_DamagePlayer(player, config.DamagePerSecond * config.TickCooldown, "Lava")
end

-- ---------------------------------------------------------------------------
-- Earthquake Hazard
-- ---------------------------------------------------------------------------

function HazardService:_StartEarthquakeLoop(config: any)
	local thread = task.spawn(function()
		while self._roundActive do
			task.wait(config.IntervalSeconds)

			if not self._roundActive then
				break
			end

			-- Fire the earthquake started event (client handles camera shake).
			EventManager:Fire(EventNames.EarthquakeStarted, config.ShakeMagnitude, config.DurationSeconds)

			-- Apply knockback impulse to all participants.
			local stateService = self.Services:Get("PlayerStateService")
			local participants = stateService:GetActiveParticipants()
			for _, player in ipairs(participants) do
				local character = player.Character
				if character then
					local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
					if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
						-- Random horizontal direction + upward force.
						local dir = Vector3.new(
							math.random(-100, 100) / 100,
							1,
							math.random(-100, 100) / 100
						).Unit
						local impulse = dir * config.KnockbackForce.Magnitude
						humanoidRootPart:ApplyImpulse(impulse)
					end
				end
			end

			-- Shake loose parts with Attribute("Shakeable", true).
			for _, shakePart in ipairs(self._shakeableParts) do
				if shakePart.Parent then
					local randomForce = Vector3.new(
						math.random(-200, 200) / 100,
						math.random(0, 300) / 100,
						math.random(-200, 200) / 100
					) * 50
					shakePart:ApplyImpulse(randomForce)
				end
			end

			task.wait(config.DurationSeconds)

			if self._roundActive then
				EventManager:Fire(EventNames.EarthquakeEnded)
			end
		end
	end)
	table.insert(self._threads, thread)

	self.Services:Get("LoggingService"):Info("HAZARD", "Earthquake hazard active")
end

-- ---------------------------------------------------------------------------
-- Flood Hazard
-- ---------------------------------------------------------------------------

function HazardService:_StartFloodLoop(config: any)
	if not self._waterSourcePart then
		self.Services:Get("LoggingService"):Warn("HAZARD", "Flood enabled but no WaterSource-tagged part found")
		return
	end

	local thread = task.spawn(function()
		-- Wait the start delay before flood begins.
		task.wait(config.StartDelay)

		if not self._roundActive then
			return
		end

		-- Create the rising water plane.
		local water = Instance.new("Part")
		water.Name = "FloodWater"
		water.Anchored = true
		water.CanCollide = false
		water.Transparency = 0.5
		water.Size = Vector3.new(500, 1, 500)
		water.BrickColor = BrickColor.new("Deep blue")
		water.Material = Enum.Material.Glass
		water.Parent = Workspace
		table.insert(self._spawnedInstances, water)

		-- Determine start position from the water source part.
		local startHeight = self._waterSourcePart.Position.Y
		local maxHeight = startHeight + config.MaxHeight
		local riseRate = config.RiseRate

		EventManager:Fire(EventNames.FloodStarted, startHeight, maxHeight)

		-- Rise loop.
		while self._roundActive and water.Parent do
			local currentY = water.Position.Y
			if currentY >= maxHeight then
				break
			end

			local newY = math.min(currentY + riseRate, maxHeight)
			water.Position = Vector3.new(water.Position.X, newY, water.Position.Z)
			water.Size = Vector3.new(500, 1, 500)

			EventManager:Fire(EventNames.FloodHeightChanged, newY)

			-- Check for submerged players (head below water).
			local stateService = self.Services:Get("PlayerStateService")
			local participants = stateService:GetActiveParticipants()
			for _, player in ipairs(participants) do
				local character = player.Character
				if character then
					local head = character:FindFirstChild("Head")
					if head and head:IsA("BasePart") then
						if head.Position.Y < newY then
							self:_DamagePlayer(player, config.DrownDamagePerSecond, "Flood")
						end
					end
				end
			end

			task.wait(1)
		end

		-- Cleanup.
		if water.Parent then
			water:Destroy()
		end
		EventManager:Fire(EventNames.FloodEnded)
	end)
	table.insert(self._threads, thread)

	self.Services:Get("LoggingService"):Info("HAZARD", "Flood hazard active")
end

-- ---------------------------------------------------------------------------
-- Fire Geyser Hazard
-- ---------------------------------------------------------------------------

function HazardService:_StartFireGeyserLoop(config: any)
	if #self._fireGeyserParts == 0 then
		self.Services:Get("LoggingService"):Warn("HAZARD", "FireGeyser enabled but no FireGeyser-tagged parts found")
		return
	end

	local thread = task.spawn(function()
		while self._roundActive do
			task.wait(config.IntervalSeconds)

			if not self._roundActive then
				break
			end

			-- Erupt at each geyser point.
			for _, geyserPart in ipairs(self._fireGeyserParts) do
				if not geyserPart.Parent then
					continue
				end

				local position = geyserPart.Position
				local killRadius = config.KillZoneRadius

				-- Fire event to client for visual eruption.
				EventManager:Fire(EventNames.FireGeyserErupted, position, config.EruptionHeight, config.DurationSeconds)

				-- Damage/eliminate players in the kill zone during eruption.
				local stateService = self.Services:Get("PlayerStateService")
				local participants = stateService:GetActiveParticipants()
				for _, player in ipairs(participants) do
					local character = player.Character
					if character then
						local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
						if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
							local dist = (humanoidRootPart.Position - position).Magnitude
							if dist <= killRadius then
								self:_DamagePlayer(player, config.DamageOnContact, "FireGeyser")
							end
						end
					end
				end
			end

			task.wait(config.DurationSeconds)
		end
	end)
	table.insert(self._threads, thread)

	self.Services:Get("LoggingService"):Info("HAZARD", "FireGeyser hazard active")
end

-- ---------------------------------------------------------------------------
-- Tornado Hazard
-- ---------------------------------------------------------------------------

function HazardService:_StartTornadoLoop(config: any)
	if #self._tornadoPathParts == 0 and #self._lavaParts == 0 then
		self.Services:Get("LoggingService"):Warn("HAZARD", "Tornado enabled but no TornadoPath waypoints found")
		-- Still start the tornado, but it will hover around a random position.
	end

	local thread = task.spawn(function()
		-- Determine path: use waypoints if available, otherwise random points.
		local waypoints = {}
		if #self._tornadoPathParts > 0 then
			for _, part in ipairs(self._tornadoPathParts) do
				table.insert(waypoints, part.Position)
			end
		else
			-- Create a few random waypoints around the map center.
			for i = 1, 5 do
				table.insert(waypoints, Vector3.new(
					math.random(-60, 60),
					5,
					math.random(-60, 60)
				))
			end
		end

		local waypointIndex = 1
		local tornadoPosition = waypoints[1]
		local tornadoVisual = nil :: Part?

		-- Create a visual tornado indicator (server-side; client renders particles).
		tornadoVisual = Instance.new("Part")
		tornadoVisual.Name = "TornadoCenter"
		tornadoVisual.Anchored = true
		tornadoVisual.CanCollide = false
		tornadoVisual.Transparency = 1
		tornadoVisual.Size = Vector3.new(1, 1, 1)
		tornadoVisual.Position = tornadoPosition
		tornadoVisual.Parent = Workspace
		table.insert(self._spawnedInstances, tornadoVisual)

		EventManager:Fire(EventNames.TornadoStarted, tornadoPosition, config.KillZoneRadius)

		local elapsed = 0
		while self._roundActive and elapsed < config.DurationSeconds do
			-- Move toward the current waypoint.
			local target = waypoints[waypointIndex]
			local direction = (target - tornadoPosition).Unit
			local distance = (target - tornadoPosition).Magnitude

			if distance < 2 then
				-- Reached waypoint; pick next.
				waypointIndex = waypointIndex + 1
				if waypointIndex > #waypoints then
					if config.PathLoop then
						waypointIndex = 1
					else
						break
					end
				end
			else
				local moveStep = math.min(config.MoveSpeed, distance)
				tornadoPosition = tornadoPosition + direction * moveStep
			end

			if tornadoVisual then
				tornadoVisual.Position = tornadoPosition
			end

			-- Update tornado position to clients.
			EventManager:Fire(EventNames.TornadoMoved, tornadoPosition)

			-- Pull and damage players in the kill zone.
			local stateService = self.Services:Get("PlayerStateService")
			local participants = stateService:GetActiveParticipants()
			for _, player in ipairs(participants) do
				local character = player.Character
				if character then
					local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
					if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
						local dist = (humanoidRootPart.Position - tornadoPosition).Magnitude
						if dist <= config.KillZoneRadius then
							-- Pull upward.
							humanoidRootPart:ApplyImpulse(config.PullForce)

							-- Damage (once per second).
							if not self._tornadoTargets[player] then
								self._tornadoTargets[player] = true
								self:_DamagePlayer(player, config.DamagePerSecond, "Tornado")
							end
						else
							self._tornadoTargets[player] = nil
						end
					end
				end
			end

			elapsed = elapsed + 0.5
			task.wait(0.5)
		end

		-- Cleanup tornado.
		if tornadoVisual and tornadoVisual.Parent then
			tornadoVisual:Destroy()
		end
		EventManager:Fire(EventNames.TornadoEnded)
	end)
	table.insert(self._threads, thread)

	self.Services:Get("LoggingService"):Info("HAZARD", "Tornado hazard active")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

function HazardService:_StopAllLoops()
	for _, thread in ipairs(self._threads) do
		task.cancel(thread)
	end
	self._threads = {}
end

function HazardService:_CleanupAll()
	self:_StopAllLoops()
	self._roundActive = false

	-- Destroy any spawned instances.
	for _, instance in ipairs(self._spawnedInstances) do
		if instance.Parent then
			instance:Destroy()
		end
	end
	self._spawnedInstances = {}

	-- Clear cached references.
	self._lavaParts = {}
	self._fireGeyserParts = {}
	self._waterSourcePart = nil
	self._tornadoPathParts = {}
	self._shakeableParts = {}
	self._lavaTouching = {}
	self._tornadoTargets = {}
	self._playerHealth = {}
	self._hazardConfig = nil
end

return HazardService