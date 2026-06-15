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

local function _GetIntervalWithVariance(baseInterval: number, variance: number): number
	-- Returns baseInterval +/- variance, clamped to minimum 1 second.
	local jitter = math.random(-variance * 100, variance * 100) / 100
	return math.max(1, baseInterval + jitter)
end

function HazardService:_StartEarthquakeLoop(config: any)
	-- Apply StartDelay if configured.
	local startDelay = config.StartDelay or 0
	if startDelay > 0 then
		task.delay(startDelay - 1, function()
			if self._roundActive then
				local replicationService = self.Services:Get("ReplicationService")
				if replicationService and replicationService.BroadcastAnnouncement then
					replicationService:BroadcastAnnouncement("⚠️ Earthquake incoming!")
				end
			end
		end)
		task.wait(startDelay)
	end

	local thread = task.spawn(function()
		while self._roundActive do
			local waitTime = config.IntervalSeconds and _GetIntervalWithVariance(config.IntervalSeconds, config.IntervalVariance or 0) or nil
			if waitTime then
				task.wait(waitTime)
			else
				-- No interval = runs once only (after start delay)
				break
			end

			if not self._roundActive then
				break
			end

			-- Broadcast warning each time.
			local replicationService = self.Services:Get("ReplicationService")
			if replicationService and replicationService.BroadcastAnnouncement then
				replicationService:BroadcastAnnouncement("🌍 Earthquake!")
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
		-- Broadcast flood warning.
		local replicationService = self.Services:Get("ReplicationService")
		if replicationService and replicationService.BroadcastAnnouncement then
			replicationService:BroadcastAnnouncement("🌊 Flood incoming! Seek high ground!")
		end

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

	-- Apply StartDelay if configured.
	local startDelay = config.StartDelay or 0
	task.wait(startDelay)

	local thread = task.spawn(function()
		while self._roundActive do
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

			-- Wait for next interval with variance.
			local waitTime = config.IntervalSeconds and _GetIntervalWithVariance(config.IntervalSeconds, config.IntervalVariance or 0) or nil
			if not waitTime then
				break  -- runs once only
			end
			task.wait(waitTime)
		end
	end)
	table.insert(self._threads, thread)

	self.Services:Get("LoggingService"):Info("HAZARD", "FireGeyser hazard active")
end

-- ---------------------------------------------------------------------------
-- Bezier curve helper for smooth tornado paths
-- ---------------------------------------------------------------------------

-- Catmull-Rom spline: given 4 control points, sample position at t (0-1).
local function _CatmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2 = t * t
	local t3 = t2 * t
	return 0.5 * (
		(2 * p1) +
		(-p0 + p2) * t +
		(2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
		(-p0 + 3 * p1 - 3 * p2 + p3) * t3
	)
end

-- Build a dense list of points along a smooth curve through the waypoints.
-- Uses Catmull-Rom interpolation with 20 samples per segment.
local function _BuildCurvePath(waypoints: { Vector3 }, samplesPerSegment: number?): { Vector3 }
	local count = samplesPerSegment or 20
	local path = {} :: { Vector3 }

	if #waypoints < 2 then
		return waypoints
	end

	-- Duplicate first and last points for boundary handling.
	local pts = {} :: { Vector3 }
	table.insert(pts, waypoints[1])
	for _, p in ipairs(waypoints) do
		table.insert(pts, p)
	end
	table.insert(pts, waypoints[#waypoints])

	for i = 2, #pts - 2 do
		local p0 = pts[i - 1]
		local p1 = pts[i]
		local p2 = pts[i + 1]
		local p3 = pts[i + 2]
		for j = 0, count - 1 do
			local t = j / count
			table.insert(path, _CatmullRom(p0, p1, p2, p3, t))
		end
	end
	-- Add final point.
	table.insert(path, waypoints[#waypoints])

	return path
end

-- ---------------------------------------------------------------------------
-- Tornado Hazard
-- ---------------------------------------------------------------------------

function HazardService:_StartTornadoLoop(config: any)
	if #self._tornadoPathParts == 0 then
		self.Services:Get("LoggingService"):Warn("HAZARD", "Tornado enabled but no TornadoPath waypoints found; using random path")
	end

	local thread = task.spawn(function()
		-- Apply start delay before first tornado.
		local startDelay = config.StartDelay or 0
		if startDelay > 0 then
			task.delay(startDelay - 1, function()
				if self._roundActive then
					local replicationService = self.Services:Get("ReplicationService")
					if replicationService and replicationService.BroadcastAnnouncement then
						replicationService:BroadcastAnnouncement("🌪️ Tornado coming! Watch out!")
					end
				end
			end)
			task.wait(startDelay)
		end

		while self._roundActive do
			if not self._roundActive then
				break
			end

			-- Broadcast tornado warning.
			local replicationService = self.Services:Get("ReplicationService")
			if replicationService and replicationService.BroadcastAnnouncement then
				replicationService:BroadcastAnnouncement("🌪️ Tornado approaching!")
			end

			-- Determine raw waypoints from parts or random.
			local rawWaypoints = {} :: { Vector3 }
			if #self._tornadoPathParts > 0 then
				for _, part in ipairs(self._tornadoPathParts) do
					table.insert(rawWaypoints, part.Position)
				end
			else
				for i = 1, 5 do
					table.insert(rawWaypoints, Vector3.new(
						math.random(-60, 60),
						5,
						math.random(-60, 60)
					))
				end
			end

			-- Build smooth curve path from waypoints.
			local curvePath = if #rawWaypoints >= 2 then _BuildCurvePath(rawWaypoints) else rawWaypoints

			-- If looping, extend the path to connect back to start smoothly.
			if config.PathLoop and #rawWaypoints >= 2 then
				local loopPoints = {} :: { Vector3 }
				for _, p in ipairs(rawWaypoints) do
					table.insert(loopPoints, p)
				end
				table.insert(loopPoints, rawWaypoints[1])
				curvePath = _BuildCurvePath(loopPoints)
			end

			local curveIndex = 1
			local tornadoPosition = curvePath[1]
			local tornadoVisual = Instance.new("Part")
			tornadoVisual.Name = "TornadoCenter"
			tornadoVisual.Anchored = true
			tornadoVisual.CanCollide = false
			tornadoVisual.Transparency = 1
			tornadoVisual.Size = Vector3.new(1, 1, 1)
			tornadoVisual.Position = tornadoPosition
			tornadoVisual.Parent = Workspace
			table.insert(self._spawnedInstances, tornadoVisual)

			-- Build visual config table to send to clients.
			local visualConfig = {
				BaseRadius = config.BaseRadius or 3,
				TopRadius = config.TopRadius or 18,
				MaxHeight = config.MaxHeight or 45,
				ParticleRate = config.ParticleRate or 100,
			}
			EventManager:Fire(EventNames.TornadoStarted, tornadoPosition, config.KillZoneRadius, visualConfig)

			local elapsed = 0
			while self._roundActive and elapsed < config.DurationSeconds do
				local targetIndex = curveIndex
				local target = curvePath[targetIndex]
				if not target then
					break
				end
				local direction = (target - tornadoPosition).Unit
				local distance = (target - tornadoPosition).Magnitude

				if distance < 2 then
					curveIndex = curveIndex + 1
					if curveIndex > #curvePath then
						-- Reached end of curve.
						break
					end
				else
					local moveStep = math.min(config.MoveSpeed, distance)
					tornadoPosition = tornadoPosition + direction * moveStep
				end

				if tornadoVisual then
					tornadoVisual.Position = tornadoPosition
				end

				EventManager:Fire(EventNames.TornadoMoved, tornadoPosition)

				local stateService = self.Services:Get("PlayerStateService")
				local participants = stateService:GetActiveParticipants()
				for _, player in ipairs(participants) do
					local character = player.Character
					if character then
						local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
						if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
							local dist = (humanoidRootPart.Position - tornadoPosition).Magnitude
							if dist <= config.KillZoneRadius then
								humanoidRootPart:ApplyImpulse(config.PullForce)
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

			-- Cleanup this tornado instance.
			if tornadoVisual and tornadoVisual.Parent then
				tornadoVisual:Destroy()
			end
			self._tornadoTargets = {}
			EventManager:Fire(EventNames.TornadoEnded)

			-- Wait for next interval with variance before respawning.
			local waitTime = config.IntervalSeconds and _GetIntervalWithVariance(config.IntervalSeconds, config.IntervalVariance or 0) or nil
			if not waitTime then
				break  -- runs once only
			end
			task.wait(waitTime)
		end
	end)
	table.insert(self._threads, thread)

	self.Services:Get("LoggingService"):Info("HAZARD", "Tornado hazard active")
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

function HazardService:_StopAllLoops()
	for _, thread in ipairs(self._threads) do
		local success, err = pcall(task.cancel, thread)
		if not success then
			-- Thread may have already finished; that's fine.
		end
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