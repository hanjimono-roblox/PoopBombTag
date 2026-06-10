--!strict

-- RoundController (Client)
-- Tracks the local player's round state by listening to the
-- RoundReplication RemoteEvent bridged by the server's ReplicationService.
--
-- This controller is the client-side mirror of round lifecycle events.
-- It does not drive UI directly — UIController handles all visuals.
-- Instead it provides a local state query API that other controllers
-- (MovementController, BombController) can check.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local RoundController = {}
RoundController.__index = RoundController
setmetatable(RoundController, { __index = BaseController })

function RoundController.new()
	local self: any = BaseController.new("RoundController")
	-- Whether a round is currently active on the server
	self._active = false
	-- The current round mode ("FirstElimination" or "LastManStanding")
	self._mode = ""
	-- Whether the local player is alive in the current round
	self._alive = false
	return setmetatable(self, RoundController)
end

function RoundController:Start()
	BaseController.Start(self)

	print("RoundController started")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local roundRemote = remotes:WaitForChild("RoundReplication")

	roundRemote.OnClientEvent:Connect(function(action: string, ...)
		self:_OnRoundAction(action, ...)
	end)
end

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------

function RoundController:_OnRoundAction(action: string, ...)
	if action == "RoundStarted" then
		local mode = ... :: string
		self._active = true
		self._mode = mode
		self._alive = true

	elseif action == "RoundEnded" then
		self._active = false
		self._mode = ""
		self._alive = false

	elseif action == "PlayerReturnedToLobby" then
		local player = ... :: Player
		if player == Players.LocalPlayer then
			self._active = false
			self._alive = false
		end

	elseif action == "RoundPlayerLeft" then
		local player = ... :: Player
		if player == Players.LocalPlayer then
			self._alive = false
		end
	end
end

-- ---------------------------------------------------------------------------
-- State query API
-- ---------------------------------------------------------------------------

-- Returns true if a round is currently active on the server.
function RoundController:IsRoundActive(): boolean
	return self._active
end

-- Returns the current round mode string (e.g. "LastManStanding").
function RoundController:GetRoundMode(): string
	return self._mode
end

-- Returns true if the local player is alive in the current round.
function RoundController:IsAlive(): boolean
	return self._alive
end

return RoundController