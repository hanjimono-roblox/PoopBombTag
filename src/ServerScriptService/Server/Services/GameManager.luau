--!strict

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

	EventManager:Connect(EventNames.RoundEnded, function()
		self:SetState(GameStates.Intermission)
	end)

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
		if #Players:GetPlayers() >= GameConfig.Round.MinimumPlayers then
			self:SetState(GameStates.Intermission)
			task.wait(GameConfig.Round.IntermissionDurationSeconds)

			self:SetState(GameStates.Starting)
			task.wait(GameConfig.Round.StartingDurationSeconds)

			self:SetState(GameStates.Playing)
			local started = self.Services:Get("RoundManager"):StartRound()
			if not started then
				self:SetState(GameStates.Lobby)
			else
				while self.Services:Get("RoundManager"):IsActive() do
					task.wait(1)
				end
			end
		else
			self:SetState(GameStates.Lobby)
			task.wait(5)
		end
	end
end

return GameManager
