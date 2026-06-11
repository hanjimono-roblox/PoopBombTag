--!strict
--[[
	PlayerManager (Server)
	Manages persistent player data: profiles, Poop currency, inventory,
	leaderstats, and character spawning.

	This service OWNS:
	  * Data profiles and persistence
	  * Leaderstats creation and sync
	  * Poop currency storage
	  * Inventory/equipped items storage
	  * Character spawning on join (into the lobby)

	This service MUST NOT:
	  * Track participation state (defer to PlayerStateService)
	  * Determine who is in a round (defer to PlayerStateService)
	  * Track alive/spectating/inRound booleans (defer to PlayerStateService)

	The old PlayerState.Active, .Spectating, .InRound booleans are
	DEPRECATED. All participation state now flows through PlayerStateService.
	The PlayerState type retains data fields (Poop, inventory, etc.) but
	gameplay booleans are no longer used.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local PlayerTypes = require(ReplicatedStorage.Shared.Types.PlayerTypes)

type PlayerState = PlayerTypes.PlayerState

local PlayerManager = {}
PlayerManager.__index = PlayerManager
setmetatable(PlayerManager, { __index = BaseService })

function PlayerManager.new()
	local self: any = BaseService.new("PlayerManager")
	self._states = {} :: { [Player]: PlayerState }
	return setmetatable(self, PlayerManager)
end

function PlayerManager:Start()
	BaseService.Start(self)

	Players.PlayerAdded:Connect(function(player)
		self:CreateState(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		local selfAny = self :: any
		selfAny._states[player] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		self:CreateState(player)
	end
end

-- ---------------------------------------------------------------------------
-- State Creation & Data Loading
-- ---------------------------------------------------------------------------

function PlayerManager:CreateState(player: Player): PlayerState
	local dataManager = self.Services:Get("DataManager")
	local profile = dataManager:GetProfile(player) or dataManager:LoadProfile(player)

	-- LoadProfile can now legitimately return nil (DataStore failure or
	-- lost session lock race). In that case we keep the player on the
	-- character-select / loading screen, give the load a few retries
	-- with backoff, and only kick them if it really can't be salvaged.
	if not profile then
		self:_RetryLoadOrKick(player)
		-- Return a placeholder so callers that immediately read
		-- GetState(player) get something non-nil. The real state will
		-- overwrite this once the load succeeds.
		local placeholder: PlayerState = {
			-- DEPRECATED: these booleans are no longer the source of truth
			-- for gameplay state. Use PlayerStateService for participation.
			Alive = false,
			Spectating = false,
			InRound = false,
			Poop = 0,
			EquippedItems = {},
			OwnedItems = {},
			ItemLevels = {},
			ConsumableCounts = {},
			OneTimePurchases = {},
		}
		local selfAny = self :: any
		selfAny._states[player] = placeholder
		return placeholder
	end

	local state: PlayerState = {
		-- DEPRECATED: these booleans are no longer the source of truth
		-- for gameplay state. Use PlayerStateService for participation.
		Alive = false,
		Spectating = false,
		InRound = false,

		Poop = profile.Poop,
		EquippedItems = profile.EquippedItems,
		OwnedItems = profile.OwnedItems,
		ItemLevels = profile.ItemLevels or {},
		ConsumableCounts = profile.ConsumableCounts or {},
		OneTimePurchases = profile.OneTimePurchases or {},
	}

	local selfAny = self :: any
	selfAny._states[player] = state

	self:EnsureLeaderstats(player, state)
	EventManager:Fire(EventNames.PlayerStateChanged, player, state)

	-- Spawn the player in the lobby. The PlayerStateService will have
	-- already set their state to Lobby (it starts before us).
	-- We need to defer slightly so the character has time to load.
	task.delay(0.5, function()
		if player.Parent then
			local spawnService = self.Services:Get("SpawnService")
			if spawnService then
				spawnService:SpawnInLobby(player)
			end
		end
	end)

	return state
end

-- Backs the LoadProfile retry path.
function PlayerManager:_RetryLoadOrKick(player: Player)
	local dataManager = self.Services:Get("DataManager")
	local MAX_RETRIES = 3
	local RETRY_DELAY_SECONDS = 3

	task.spawn(function()
		for _ = 1, MAX_RETRIES do
			if not player or not player.Parent then
				return
			end

			task.wait(RETRY_DELAY_SECONDS)
			local profile = dataManager:LoadProfile(player)
			if profile then
				local state: PlayerState = {
					Alive = false,
					Spectating = false,
					InRound = false,
					Poop = profile.Poop,
					EquippedItems = profile.EquippedItems,
					OwnedItems = profile.OwnedItems,
					ItemLevels = profile.ItemLevels or {},
					ConsumableCounts = profile.ConsumableCounts or {},
					OneTimePurchases = profile.OneTimePurchases or {},
				}
				local selfAny = self :: any
				selfAny._states[player] = state
				self:EnsureLeaderstats(player, state)
				EventManager:Fire(EventNames.PlayerStateChanged, player, state)

				-- Spawn in lobby on successful retry.
				task.delay(0.5, function()
					if player.Parent then
						local spawnService = self.Services:Get("SpawnService")
						if spawnService then
							spawnService:SpawnInLobby(player)
						end
					end
				end)

				return
			end
		end

		if player and player.Parent then
			player:Kick("Your player data could not be loaded. Please rejoin.")
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Leaderstats
-- ---------------------------------------------------------------------------

function PlayerManager:EnsureLeaderstats(player: Player, state: PlayerState)
	if not player or not player.Parent then
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local poopValue = leaderstats:FindFirstChild("Poop")
	if not poopValue then
		poopValue = Instance.new("IntValue")
		poopValue.Name = "Poop"
		poopValue.Parent = leaderstats
	end

	poopValue.Value = math.max(0, math.floor(state.Poop or 0))
end

-- ---------------------------------------------------------------------------
-- State Access (Data Only)
-- ---------------------------------------------------------------------------

-- Returns the data state for a player (profile data, Poop, inventory).
-- Participation state (Lobby, ActiveParticipant, etc.) is in PlayerStateService.
function PlayerManager:GetState(player: Player): PlayerState?
	local selfAny = self :: any
	return selfAny._states[player]
end

-- DEPRECATED: Use PlayerStateService:SetState(player, state) instead.
-- These methods remain for backward compatibility with existing code
-- that may call them, but they now delegate to PlayerStateService.
function PlayerManager:SetInRound(player: Player, inRound: boolean)
	local state = self:GetState(player)
	if not state then
		return
	end

	state.InRound = inRound
	state.Alive = inRound
	state.Spectating = not inRound

	-- Delegate to PlayerStateService for authoritative state.
	local stateService = self.Services:Get("PlayerStateService")
	if inRound then
		stateService:SetState(player, "ActiveParticipant")
	else
		stateService:SetState(player, "Lobby")
	end
end

function PlayerManager:SetAlive(player: Player, alive: boolean)
	local state = self:GetState(player)
	if not state then
		return
	end

	state.Alive = alive
	state.Spectating = not alive and state.InRound

	if not alive and state.InRound then
		self.Services:Get("PlayerStateService"):SetState(player, "Eliminated")
	end
end

-- DEPRECATED: Use PlayerStateService:GetActiveParticipants() or
-- PlayerStateService:GetPlayersInState("ActiveParticipant").
function PlayerManager:GetRoundPlayers(): { Player }
	return self.Services:Get("PlayerStateService"):GetActiveParticipants()
end

-- DEPRECATED: Use PlayerStateService:GetActiveParticipants().
function PlayerManager:GetAlivePlayers(): { Player }
	return self.Services:Get("PlayerStateService"):GetActiveParticipants()
end

return PlayerManager