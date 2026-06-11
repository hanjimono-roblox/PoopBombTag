--!strict

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
	return state
end

-- Backs the LoadProfile retry path. We give the load a small number of
-- attempts (so transient DataStore hiccups don't kick paying players)
-- and only kick as a last resort. The kick message tells the player
-- they can rejoin -- a single failed load is not a ban.
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
				-- Success: replace the placeholder state with the real one
				-- and refresh the leaderstats so the player sees their
				-- real balance.
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
				return
			end
		end

		-- All retries exhausted. Kick with a friendly message; the player
		-- can rejoin and try again.
		if player and player.Parent then
			player:Kick("Your player data could not be loaded. Please rejoin.")
		end
	end)
end

-- Creates the standard Roblox `leaderstats` folder on the player (so the
-- in-game leaderboard shows up) and attaches a `Poop` IntValue that is kept
-- in sync with the authoritative PlayerState. Re-creating it on a subsequent
-- state creation (e.g. after a profile reload) is safe: the existing folder
-- is reused and only the value is refreshed.
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

function PlayerManager:GetState(player: Player): PlayerState?
	local selfAny = self :: any
	return selfAny._states[player]
end

function PlayerManager:SetInRound(player: Player, inRound: boolean)
	local state = self:GetState(player)
	if not state then
		return
	end

	state.InRound = inRound
	state.Alive = inRound
	state.Spectating = not inRound
	EventManager:Fire(EventNames.PlayerStateChanged, player, state)
end

function PlayerManager:SetAlive(player: Player, alive: boolean)
	local state = self:GetState(player)
	if not state then
		return
	end

	state.Alive = alive
	state.Spectating = not alive and state.InRound
	EventManager:Fire(EventNames.PlayerStateChanged, player, state)
end

function PlayerManager:GetRoundPlayers(): { Player }
	local players = {}

	local selfAny = self :: any
	for player, state in pairs(selfAny._states) do
		if state.InRound then
			table.insert(players, player)
		end
	end

	return players
end

function PlayerManager:GetAlivePlayers(): { Player }
	local alivePlayers = {}

	local selfAny = self :: any
	for player, state in pairs(selfAny._states) do
		if state.InRound and state.Alive then
			table.insert(alivePlayers, player)
		end
	end

	return alivePlayers
end

return PlayerManager
