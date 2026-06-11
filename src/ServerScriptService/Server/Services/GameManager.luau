--!strict
--[[
	GameManager (Server)
	Refactored for arena-driven participation.

	The GameManager drives the round lifecycle. It no longer counts
	server players directly -- it polls PlayerStateService for
	ActiveParticipants and only starts rounds when the minimum
	ActiveParticipant count is met.

	The lifecycle is:
	  Waiting → Intermission → Starting → Playing → RoundEnd → Waiting...

	In Waiting, only ActiveParticipants matter. Lobby players,
	Spectators, and Eliminated players are excluded from the count.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameStates = require(ReplicatedStorage.Shared.Constants.GameStates)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local GameManager = {}
GameManager.__index = GameManager
setmetatable(GameManager, { __index = BaseService })

function GameManager.new()
	local self: any = BaseService.new("GameManager")
	self._state = GameStates.Lobby
	self._loopThread = nil :: thread?
	return setmetatable(self, GameManager)
end

function GameManager:Start()
	BaseService.Start(self)

	-- When a round ends, transition to Intermission.
	EventManager:Connect(EventNames.RoundEnded, function()
		self:SetState(GameStates.Intermission)
	end)

	-- Begin the lifecycle loop.
	local selfAny = self :: any
	selfAny._loopThread = task.spawn(function()
		self:RunLifecycle()
	end)
end

function GameManager:SetState(state: string)
	local selfAny = self :: any
	selfAny._state = state
	self.Services:Get("LoggingService"):Info("GAME", `State changed to {state}`)
end

function GameManager:GetState(): string
	local selfAny = self :: any
	return selfAny._state
end

function GameManager:RunLifecycle()
	while true do
		-- Only count ActiveParticipants. Lobby players, Spectators, and
		-- Eliminated players are excluded from round start requirements.
		local playerStateService = self.Services:Get("PlayerStateService")
		local participantCount = playerStateService:GetActiveParticipantCount()

		if participantCount >= GameConfig.Round.MinimumPlayers then
			-- Enough ActiveParticipants: start the round sequence.
			self:SetState(GameStates.Intermission)
			task.wait(GameConfig.Round.IntermissionDurationSeconds)

			self:SetState(GameStates.Starting)
			task.wait(GameConfig.Round.StartingDurationSeconds)

			self:SetState(GameStates.Playing)
			local started = self.Services:Get("RoundManager"):StartRound()
			if not started then
				-- Round failed to start (map missing, etc.). Return to Lobby.
				self:SetState(GameStates.Lobby)
			else
				-- Wait for the round to finish.
				while self.Services:Get("RoundManager"):IsActive() do
					task.wait(1)
				end
			end
		else
			-- Not enough ActiveParticipants: stay in Lobby and wait.
			self:SetState(GameStates.Lobby)
			task.wait(2)
		end
	end
end

return GameManager