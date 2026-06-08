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

	local state: PlayerState = {
		Alive = false,
		Spectating = false,
		InRound = false,
		Coins = profile.Coins,
		EquippedItems = profile.EquippedItems,
		OwnedItems = profile.OwnedItems,
	}

	local selfAny = self :: any
	selfAny._states[player] = state
	EventManager:Fire(EventNames.PlayerStateChanged, player, state)
	return state
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
