--!strict
--[[
	AtmosphereService (Server, Authority)

	Manages visual/ambient atmosphere conditions that are pushed to clients.
	Each map can define atmosphere settings in its config (MapConfigs/<MapName>Config.luau).

	This service:
	  - Reads the atmosphere config when a map is loaded.
	  - Pushes the full atmosphere state to all clients via EventManager.
	  - Manages server-side lightning timers (thunderstorm).
	  - Clears atmosphere when the round ends or map unloads.

	Atmosphere types (all optional, can be combined):
	  - Fog: Sets Lighting.Fog* properties on clients.
	  - Rainstorm: Particles + optional lightning/thunder.
	  - Sandstorm: Orange/brown fog + particles + sky darkening.
	  - Blizzard: White fog + snow particles + cold tint.
	  - Aurora: Sky color gradient overlay.

	Clients are responsible for the actual visual rendering (particles, skybox,
	lighting changes). This service only pushes the data.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)

local AtmosphereService = {}
AtmosphereService.__index = AtmosphereService
setmetatable(AtmosphereService, { __index = BaseService })

function AtmosphereService.new()
	local self: any = BaseService.new("AtmosphereService")
	-- The current atmosphere state to push to clients
	self._currentAtmosphere = nil :: any?
	-- Active threads (lightning timer)
	self._threads = {} :: { thread }
	-- Whether a round is active
	self._roundActive = false
	return setmetatable(self, AtmosphereService)
end

function AtmosphereService:Start()
	BaseService.Start(self)

	-- When a map is loaded, read atmosphere config.
	EventManager:Connect(EventNames.MapLoaded, function(mapName: string, _mapInstance: Instance)
		self:_OnMapLoaded(mapName)
	end)

	-- When a round starts, push atmosphere to clients.
	EventManager:Connect(EventNames.RoundStarted, function()
		self:_OnRoundStarted()
	end)

	-- When a round ends, clear atmosphere.
	EventManager:Connect(EventNames.RoundEnded, function()
		self:_OnRoundEnded()
	end)

	-- When map is unloaded, clean up.
	EventManager:Connect(EventNames.MapUnloaded, function()
		self:_Cleanup()
	end)

	self.Services:Get("LoggingService"):Info("ATMOSPHERE", "AtmosphereService started")
end

-- ---------------------------------------------------------------------------
-- Map Loading
-- ---------------------------------------------------------------------------

function AtmosphereService:_OnMapLoaded(mapName: string)
	local configsFolder = ServerStorage:FindFirstChild("MapConfigs")
	if not configsFolder then
		return
	end

	local configModule = configsFolder:FindFirstChild(mapName .. "Config")
	if not configModule or not configModule:IsA("ModuleScript") then
		self.Services:Get("LoggingService"):Warn("ATMOSPHERE", `No config found for map: {mapName}`)
		return
	end

	local config = require(configModule)
	self._currentAtmosphere = config.Atmosphere or {}

	local logging = self.Services:Get("LoggingService")
	local enabledCount = 0
	for name, atm in pairs(self._currentAtmosphere) do
		if atm.Enabled then
			enabledCount = enabledCount + 1
		end
	end
	logging:Info("ATMOSPHERE", `Map {mapName}: {enabledCount} atmosphere types enabled`)
end

-- ---------------------------------------------------------------------------
-- Round Lifecycle
-- ---------------------------------------------------------------------------

function AtmosphereService:_OnRoundStarted()
	self._roundActive = true

	if not self._currentAtmosphere then
		return
	end

	-- Push the atmosphere state to clients.
	EventManager:Fire(EventNames.AtmosphereApplied, self._currentAtmosphere)

	-- Start lightning timer if thunderstorm is enabled.
	local rainstorm = self._currentAtmosphere.Rainstorm
	if rainstorm and rainstorm.Enabled and rainstorm.HasLightning then
		self:_StartLightningTimer(rainstorm)
	end

	-- Note: Aurora animation is handled client-side.
	local hasActive = false
	for _, atm in pairs(self._currentAtmosphere) do
		if atm.Enabled then
			hasActive = true
			break
		end
	end
	if hasActive then
		self.Services:Get("LoggingService"):Info("ATMOSPHERE", "Atmosphere pushed to clients")
	end
end

function AtmosphereService:_OnRoundEnded()
	self._roundActive = false

	-- Stop all threads.
	for _, thread in ipairs(self._threads) do
		task.cancel(thread)
	end
	self._threads = {}

	-- Clear atmosphere on clients.
	EventManager:Fire(EventNames.AtmosphereCleared)
end

-- ---------------------------------------------------------------------------
-- Lightning Timer
-- ---------------------------------------------------------------------------

function AtmosphereService:_StartLightningTimer(config: any)
	local thread = task.spawn(function()
		while self._roundActive do
			-- Random interval between flashes.
			local minVal = config.LightningIntervalMin or 5
			local maxVal = config.LightningIntervalMax or 15
			local interval = math.random(minVal, maxVal)
			task.wait(interval)

			if not self._roundActive then
				break
			end

			-- Fire lightning flash event to clients.
			EventManager:Fire(EventNames.LightningFlashed, config.ThunderVolume or 0.5)
		end
	end)
	table.insert(self._threads, thread)
end

-- ---------------------------------------------------------------------------
-- Public API (used by admin commands for testing)
-- ---------------------------------------------------------------------------

-- Applies a custom atmosphere state immediately, bypassing round lifecycle.
-- Used by the /weather admin command for testing.
function AtmosphereService:ApplyAtmosphereNow(atmosphere: any)
	self._currentAtmosphere = atmosphere
	self._roundActive = true
	EventManager:Fire(EventNames.AtmosphereApplied, atmosphere)

	-- Start lightning if thunderstorm is enabled.
	if atmosphere.Rainstorm and atmosphere.Rainstorm.Enabled and atmosphere.Rainstorm.HasLightning then
		self:_StartLightningTimer(atmosphere.Rainstorm)
	end

	self.Services:Get("LoggingService"):Info("ATMOSPHERE", "Atmosphere applied via command")
end

-- Clears atmosphere immediately, bypassing round lifecycle.
function AtmosphereService:ClearAtmosphereNow()
	self:_OnRoundEnded()
	self._currentAtmosphere = nil
end

-- ---------------------------------------------------------------------------
-- Cleanup

function AtmosphereService:_Cleanup()
	for _, thread in ipairs(self._threads) do
		task.cancel(thread)
	end
	self._threads = {}
	self._currentAtmosphere = nil
	self._roundActive = false
end

return AtmosphereService