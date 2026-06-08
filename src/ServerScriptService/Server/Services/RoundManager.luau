--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local RoundModes = require(ReplicatedStorage.Shared.Constants.RoundModes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local RoundManager = {}
RoundManager.__index = RoundManager
setmetatable(RoundManager, { __index = BaseService })

function RoundManager.new()
	local self: any = BaseService.new("RoundManager")
	self._active = false
	self._mode = GameConfig.Round.DefaultMode
	self._eliminatedPlayers = {} :: { Player }
	return setmetatable(self, RoundManager)
end

function RoundManager:Start()
	BaseService.Start(self)

	EventManager:Connect(EventNames.PlayerEliminated, function(player: Player, reason: string)
		self:EliminatePlayer(player, reason)
	end)
end

function RoundManager:StartRound(mode: string?): boolean
	local selfAny = self :: any
	if selfAny._active then
		return false
	end

	local allPlayers = Players:GetPlayers()
	if #allPlayers < GameConfig.Round.MinimumPlayers then
		return false
	end

	local selfAny = self :: any
	selfAny._active = true
	selfAny._mode = mode or GameConfig.Round.DefaultMode
	table.clear(selfAny._eliminatedPlayers)

	local mapManager = self.Services:Get("MapManager")
	mapManager:LoadMap()

	local playerManager = self.Services:Get("PlayerManager")
	for _, player in ipairs(allPlayers) do
		playerManager:SetInRound(player, true)
	end

	self:SpawnPlayers()

	local alivePlayers = self:GetAlivePlayers()
	local bombHolder = alivePlayers[math.random(1, #alivePlayers)]
	self.Services:Get("BombManager"):AssignBomb(bombHolder)

	EventManager:Fire(EventNames.RoundStarted, selfAny._mode, alivePlayers)
	return true
end

function RoundManager:EndRound(reason: string?, winners: { Player }?): boolean
	local selfAny = self :: any
	if not selfAny._active then
		return false
	end

	local resolvedWinners = winners or self:DetermineWinners()
	selfAny._active = false
	self.Services:Get("BombManager"):ClearBomb()

	for _, winner in ipairs(resolvedWinners) do
		EventManager:Fire(EventNames.PlayerWon, winner)
	end
	EventManager:Fire(EventNames.PlayersWon, resolvedWinners)

	self:AwardWinners(resolvedWinners)

	local playerManager = self.Services:Get("PlayerManager")
	for _, player in ipairs(playerManager:GetRoundPlayers()) do
		playerManager:SetInRound(player, false)
	end

	self.Services:Get("MapManager"):UnloadMap()
	EventManager:Fire(EventNames.RoundEnded, reason or "Completed", resolvedWinners)
	return true
end

function RoundManager:IsActive(): boolean
	local selfAny = self :: any
	return selfAny._active
end

function RoundManager:GetAlivePlayers(): { Player }
	return self.Services:Get("PlayerManager"):GetAlivePlayers()
end

function RoundManager:EliminatePlayer(player: Player, reason: string)
	local selfAny = self :: any
	if not selfAny._active then
		return
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state or not state.Alive then
		return
	end

	playerManager:SetAlive(player, false)
	table.insert(selfAny._eliminatedPlayers, player)

	local alivePlayers = self:GetAlivePlayers()
	local mode = selfAny._mode

	if mode == RoundModes.FirstElimination then
		self:EndRound(reason, alivePlayers)
		return
	end

	if #alivePlayers <= 1 then
		self:EndRound("LastPlayerStanding", alivePlayers)
		return
	end

	self.Services:Get("BombManager"):AssignBomb(alivePlayers[math.random(1, #alivePlayers)])
end

function RoundManager:ReturnPlayerToLobby(player: Player): boolean
	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state or not state.InRound then
		return false
	end

	-- TODO: Add penalty and cooldown policy object before charging coins.
	self.Services:Get("PlayerManager"):SetInRound(player, false)
	self:TeleportToLobby(player)
	EventManager:Fire(EventNames.PlayerReturnedToLobby, player)
	return true
end

function RoundManager:DetermineWinners(): { Player }
	local selfAny = self :: any
	if selfAny._mode == RoundModes.FirstElimination then
		return self:GetAlivePlayers()
	end

	return self:GetAlivePlayers()
end

function RoundManager:AwardWinners(winners: { Player })
	local selfAny = self :: any
	local reward = if selfAny._mode == RoundModes.FirstElimination
		then GameConfig.Rewards.FirstEliminationWinnerPoop
		else GameConfig.Rewards.LastManStandingWinnerPoop

	for _, winner in ipairs(winners) do
		self.Services:Get("CurrencyManager"):AddPoop(winner, reward)
	end
end

function RoundManager:SpawnPlayers()
	local spawnPoints = self.Services:Get("MapManager"):GetSpawnPoints()
	local roundPlayers = self.Services:Get("PlayerManager"):GetRoundPlayers()

	for index, player in ipairs(roundPlayers) do
		local spawnPoint = spawnPoints[((index - 1) % math.max(#spawnPoints, 1)) + 1]
		if player.Character and spawnPoint then
			player.Character:PivotTo(spawnPoint.CFrame + Vector3.new(0, 3, 0))
		end
	end
end

function RoundManager:TeleportToLobby(player: Player)
	local lobbySpawn = workspace:FindFirstChild(GameConfig.Maps.LobbySpawnName, true)
	if player.Character and lobbySpawn and lobbySpawn:IsA("BasePart") then
		player.Character:PivotTo(lobbySpawn.CFrame + Vector3.new(0, 3, 0))
	end
end

return RoundManager
