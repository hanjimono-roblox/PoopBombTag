--!strict
--[[
	CoinPickupService (Server)
	Spawns collectible Poop coins at CoinSpawn parts placed by map builders.

	Map builders place Parts (or other BaseParts) inside their map folders in
	ServerStorage with the following attributes:

	  CoinSpawn = true          (REQUIRED — marks this part as a coin spawn point)
	  CoinValue = 25            (optional, defaults to GameConfig.Coins.DefaultValue)
	  CoinRespawnTime = 10      (optional, defaults to GameConfig.Coins.DefaultRespawnTime)

	When a map is loaded, the service scans Workspace.ActiveMap for all parts
	with CoinSpawn = true, spawns coin objects at those positions, and manages
	collection + respawn. Coins are cleaned up when the map unloads.

	Coin collection is server-authoritative via BasePart.Touched. The client
	can never claim a coin on its own.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

type CoinSpawnDef = {
	position: CFrame,
	value: number,
	respawnTime: number,
}

type ActiveCoin = {
	coinPart: BasePart,
	spawnDef: CoinSpawnDef,
	connection: RBXScriptConnection?,
}

-- ---------------------------------------------------------------------------
-- Service
-- ---------------------------------------------------------------------------

local CoinPickupService = {}
CoinPickupService.__index = CoinPickupService
setmetatable(CoinPickupService, { __index = BaseService })

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

function CoinPickupService.new()
	local self: any = BaseService.new("CoinPickupService")
	self._spawnDefs = {} :: { CoinSpawnDef }
	self._activeCoins = {} :: { ActiveCoin }
	self._cooldowns = {} :: { [number]: true } -- keys are spawn indexes on cooldown
	self._roundActive = false
	self._connections = {} :: { RBXScriptConnection }
	return setmetatable(self, CoinPickupService)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function CoinPickupService:Start()
	BaseService.Start(self)

	-- Track round state so coins only spawn during active rounds.
	local roundManager = self.Services:Get("RoundManager")
	if roundManager then
		table.insert(self._connections, EventManager:Connect(EventNames.RoundStarted, function()
			self._roundActive = true
			self:_SpawnCoinsForCurrentMap()
		end))

		table.insert(self._connections, EventManager:Connect(EventNames.RoundEnded, function()
			self._roundActive = false
			self:_DespawnAllCoins()
		end))
	end

	-- When a new map loads, scan it for CoinSpawn definitions.
	table.insert(self._connections, EventManager:Connect(EventNames.MapLoaded, function()
		self:_ClearAllState()
		self:_ScanCoinSpawns()
		if self._roundActive then
			self:_SpawnCoinsForCurrentMap()
		end
	end))

	-- Clean up everything when the map unloads.
	table.insert(self._connections, EventManager:Connect(EventNames.MapUnloaded, function()
		self:_ClearAllState()
	end))

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("COINS", "CoinPickupService started")
	end
end

-- ---------------------------------------------------------------------------
-- State Management
-- ---------------------------------------------------------------------------

-- Clears all coins, cooldowns, and spawn definitions (called on map change).
function CoinPickupService:_ClearAllState()
	self:_DespawnAllCoins()
	self._spawnDefs = {}
	self._cooldowns = {}
end

-- Scans the active map for CoinSpawn parts and builds spawn definitions.
function CoinPickupService:_ScanCoinSpawns()
	local activeMap = Workspace:FindFirstChild(GameConfig.Maps.ActiveMapParentName)
	if not activeMap then
		return
	end

	local definitions: { CoinSpawnDef } = {}
	local config = GameConfig.Coins

	-- Find every BasePart with CoinSpawn = true in the map hierarchy
	for _, descendant in ipairs(activeMap:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		if not descendant:GetAttribute("CoinSpawn") then
			continue
		end

		-- Read per-spawn overrides; fall back to GameConfig defaults.
		local value = descendant:GetAttribute("CoinValue")
		if type(value) ~= "number" or value <= 0 then
			value = config.DefaultValue
		end

		local respawnTime = descendant:GetAttribute("CoinRespawnTime")
		if type(respawnTime) ~= "number" or respawnTime <= 0 then
			respawnTime = config.DefaultRespawnTime
		end

		table.insert(definitions, {
			position = descendant.CFrame,
			value = value,
			respawnTime = respawnTime,
		})
	end

	self._spawnDefs = definitions

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("COINS", `Found {#definitions} CoinSpawn points`)
	end
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

-- Spawns coins up to the max active limit, selecting spawns that are not
-- currently on cooldown.
function CoinPickupService:_SpawnCoinsForCurrentMap()
	local config = GameConfig.Coins
	local maxActive = config.MaxActiveOnField

	-- If the active map has a CoinMaxActive attribute, use that instead.
	local activeMap = Workspace:FindFirstChild(GameConfig.Maps.ActiveMapParentName)
	if activeMap then
		local mapMax = activeMap:GetAttribute("CoinMaxActive")
		if type(mapMax) == "number" and mapMax > 0 then
			maxActive = mapMax
		end
	end

	local available: { number } = {}
	for idx = 1, #self._spawnDefs do
		if not self._cooldowns[idx] then
			table.insert(available, idx)
		end
	end

	-- Shuffle available indices so the coins appear at random spawns.
	for i = #available, 2, -1 do
		local j = math.random(1, i)
		available[i], available[j] = available[j], available[i]
	end

	local toSpawn = math.min(maxActive, #available)

	for i = 1, toSpawn do
		local spawnIdx = available[i]
		self:_CreateCoin(spawnIdx)
	end

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("COINS", `Spawned {toSpawn} coins ({#self._activeCoins} active, {#available - toSpawn} available but capped)`)
	end
end

-- Creates a visible coin Part at the given spawn index.
function CoinPickupService:_CreateCoin(spawnIdx: number)
	local spawnDef = self._spawnDefs[spawnIdx]
	if not spawnDef then
		return
	end

	-- Check if there's already an active coin at this spawn.
	for _, active in ipairs(self._activeCoins) do
		if active.spawnDef == spawnDef then
			return -- already has a coin
		end
	end

	local config = GameConfig.Coins

	local coinPart = Instance.new("Part")
	coinPart.Name = config.CoinPartName
	coinPart.Size = config.CoinSize
	coinPart.Color = config.CoinColor
	coinPart.Material = Enum.Material.Neon
	coinPart.Shape = Enum.PartType.Cylinder
	coinPart.Anchored = true
	coinPart.CanCollide = false
	coinPart.CanQuery = false
	coinPart.Transparency = 0.15
	coinPart.CFrame = spawnDef.position * CFrame.new(0, 1.5, 0) -- sit slightly above surface

	-- Tag so client-side scripts can detect it for animations/UI
	coinPart:SetAttribute("CoinValue", spawnDef.value)
	coinPart:SetAttribute("CoinSpawned", true)

	local activeCoin: ActiveCoin = {
		coinPart = coinPart,
		spawnDef = spawnDef,
		connection = nil,
	}

	-- Server-authoritative collection via Touched.
	activeCoin.connection = coinPart.Touched:Connect(function(hit: BasePart)
		self:_OnCoinTouched(coinPart, spawnIdx, hit)
	end)

	coinPart.Parent = Workspace

	table.insert(self._activeCoins, activeCoin)

	EventManager:Fire(EventNames.CoinSpawned, coinPart, spawnDef.value)
end

-- ---------------------------------------------------------------------------
-- Collection
-- ---------------------------------------------------------------------------

function CoinPickupService:_OnCoinTouched(coinPart: BasePart, spawnIdx: number, hit: BasePart)
	-- Validate that the coin is still active and the spawn isn't on cooldown.
	if self._cooldowns[spawnIdx] then
		return
	end

	-- Find the player whose character touched the coin.
	local character = hit:IsA("BasePart") and hit:FindFirstAncestorOfClass("Model")
	if not character then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player or not player.Parent then
		return
	end

	-- Validate the coin still exists and hasn't been collected.
	local coinFound = false
	local activeIndex = nil
	for i, active in ipairs(self._activeCoins) do
		if active.coinPart == coinPart then
			coinFound = true
			activeIndex = i
			break
		end
	end

	if not coinFound then
		return
	end

	-- Validate the player is eligible (in the round).
	-- Only ActiveParticipant or Eliminated players can collect coins.
	local playerStateService = self.Services:Get("PlayerStateService")
	if playerStateService then
		local state = playerStateService:GetState(player)
		if state ~= "ActiveParticipant" and state ~= "Eliminated" then
			return
		end
	end

	-- Validate distance (defense-in-depth against Touched hitting through walls).
	local spawnDef = self._spawnDefs[spawnIdx]
	if not spawnDef then
		return
	end

	local distance = (coinPart.Position - character:GetPivot().Position).Magnitude
	local maxCollectDist = GameConfig.Coins.CollectRadius
	if distance > maxCollectDist * 1.5 then
		return -- too far; likely a false touch
	end

	-- Award the coin.
	local currencyManager = self.Services:Get("CurrencyManager")
	if not currencyManager then
		return
	end

	currencyManager:AddPoop(player, spawnDef.value)

	-- Fire event for UI/other services.
	EventManager:Fire(EventNames.CoinCollected, player, spawnDef.value, coinPart)

	-- Remove the coin and start respawn cooldown.
	self:_RemoveActiveCoin(activeIndex)

	self:_StartRespawnCooldown(spawnIdx)

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("COINS", `{player.Name} collected {spawnDef.value} Poop (spawn {spawnIdx})`)
	end
end

-- ---------------------------------------------------------------------------
-- Respawn
-- ---------------------------------------------------------------------------

function CoinPickupService:_StartRespawnCooldown(spawnIdx: number)
	self._cooldowns[spawnIdx] = true

	local spawnDef = self._spawnDefs[spawnIdx]
	if not spawnDef then
		return
	end

	-- Add variance so all coins don't respawn at exactly the same time.
	local variance = GameConfig.Coins.RespawnVariance
	local delay = spawnDef.respawnTime + math.random() * variance * spawnDef.respawnTime

	task.delay(delay, function()
		if not self._roundActive then
			return -- round ended while waiting
		end
		self._cooldowns[spawnIdx] = nil
		-- Re-check max active before spawning.
		if #self._activeCoins < GameConfig.Coins.MaxActiveOnField then
			self:_CreateCoin(spawnIdx)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Removal / Cleanup
-- ---------------------------------------------------------------------------

function CoinPickupService:_RemoveActiveCoin(activeIndex: number?)
	if not activeIndex then
		return
	end

	local active = self._activeCoins[activeIndex]
	if not active then
		return
	end

	if active.connection then
		active.connection:Disconnect()
		active.connection = nil
	end

	active.coinPart:Destroy()

	EventManager:Fire(EventNames.CoinDespawned, active.coinPart)

	table.remove(self._activeCoins, activeIndex)
end

function CoinPickupService:_DespawnAllCoins()
	for _, active in ipairs(self._activeCoins) do
		if active.connection then
			active.connection:Disconnect()
			active.connection = nil
		end
		if active.coinPart and active.coinPart.Parent then
			active.coinPart:Destroy()
		end
	end
	self._activeCoins = {}
	self._cooldowns = {}
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

function CoinPickupService:Destroy()
	self:_DespawnAllCoins()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	self._connections = {}
	self._spawnDefs = {}
end

return CoinPickupService