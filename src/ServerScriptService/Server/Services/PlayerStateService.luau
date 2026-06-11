--!strict
--[[
	PlayerStateService (Server, Authority)
	The single source of truth for player participation state.

	Every player must always have exactly ONE valid state: Lobby,
	ActiveParticipant, Eliminated, or Spectator.

	This service OWNS:
	  * State storage for every player
	  * State transition validation
	  * State queries (GetPlayersInState, IsParticipant, etc.)

	This service MUST NOT:
	  * Determine who enters the arena (defer to ArenaEntryService)
	  * Control round lifecycle (defer to RoundService)
	  * Spawn players (defer to SpawnService)
	  * Award currency or items (defer to CurrencyManager, etc.)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local PlayerStateType = require(ReplicatedStorage.Shared.Types.PlayerStateType)

type PlayerState = PlayerStateType.PlayerState
type OptionalPlayerState = PlayerStateType.OptionalPlayerState

local PlayerStateService = {}
PlayerStateService.__index = PlayerStateService
setmetatable(PlayerStateService, { __index = BaseService })

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function PlayerStateService.new()
	local self: any = BaseService.new("PlayerStateService")
	self._states = {} :: { [Player]: PlayerState }
	return setmetatable(self, PlayerStateService)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function PlayerStateService:Start()
	BaseService.Start(self)

	-- When a player joins, immediately set them to Lobby.
	Players.PlayerAdded:Connect(function(player: Player)
		self:SetState(player, "Lobby")
	end)

	-- Clean up state when player leaves.
	Players.PlayerRemoving:Connect(function(player: Player)
		local selfAny = self :: any
		selfAny._states[player] = nil
	end)

	-- Initialize all players already in the server.
	for _, player in ipairs(Players:GetPlayers()) do
		self:SetState(player, "Lobby")
	end
end

-- ---------------------------------------------------------------------------
-- State ownership API
-- ---------------------------------------------------------------------------

-- Returns the current state of a player. Returns nil only if the player
-- has not been initialized (should never happen after Start).
function PlayerStateService:GetState(player: Player): PlayerState?
	local selfAny = self :: any
	return selfAny._states[player]
end

-- Sets the state of a player. Validates the transition and fires the
-- PlayerStateChanged event. Returns true if the transition was applied,
-- false if it was rejected.
function PlayerStateService:SetState(player: Player, newState: PlayerState): boolean
	local selfAny = self :: any
	local currentState: OptionalPlayerState = selfAny._states[player]

	-- Validate the transition.
	if not PlayerStateType.IsValidTransition(currentState, newState) then
		local logging = self.Services:Get("LoggingService")
		if logging then
			logging:Warn("STATE", `Invalid transition for {player.Name}: {tostring(currentState)} → {newState}`)
		end
		return false
	end

	-- Apply the transition.
	selfAny._states[player] = newState

	-- Announce the state change. All services that care about state
	-- transitions listen to this event.
	EventManager:Fire(EventNames.PlayerStateChanged, player, newState, currentState)

	return true
end

-- ---------------------------------------------------------------------------
-- Query API
-- ---------------------------------------------------------------------------

-- Returns true if the player is an ActiveParticipant (i.e., counts toward
-- round start requirements and can influence gameplay).
function PlayerStateService:IsParticipant(player: Player): boolean
	local selfAny = self :: any
	return selfAny._states[player] == "ActiveParticipant"
end

-- Returns a fresh array of all players currently in the given state.
-- The caller owns the returned table.
function PlayerStateService:GetPlayersInState(state: PlayerState): { Player }
	local selfAny = self :: any
	local result = {}
	for player, s in pairs(selfAny._states) do
		if s == state then
			table.insert(result, player)
		end
	end
	return result
end

-- Returns the count of players in the given state. More efficient than
-- #GetPlayersInState for polling loops.
function PlayerStateService:GetCountInState(state: PlayerState): number
	local selfAny = self :: any
	local count = 0
	for _, s in pairs(selfAny._states) do
		if s == state then
			count += 1
		end
	end
	return count
end

-- Convenience: returns all ActiveParticipants.
function PlayerStateService:GetActiveParticipants(): { Player }
	return self:GetPlayersInState("ActiveParticipant")
end

-- Convenience: returns the count of ActiveParticipants.
function PlayerStateService:GetActiveParticipantCount(): number
	return self:GetCountInState("ActiveParticipant")
end

-- Convenience: returns all Lobby players.
function PlayerStateService:GetLobbyPlayers(): { Player }
	return self:GetPlayersInState("Lobby")
end

-- Convenience: returns all Spectators.
function PlayerStateService:GetSpectators(): { Player }
	return self:GetPlayersInState("Spectator")
end

-- Convenience: returns all Eliminated players.
function PlayerStateService:GetEliminatedPlayers(): { Player }
	return self:GetPlayersInState("Eliminated")
end

-- Returns all players whose state allows them to be in the arena
-- (ActiveParticipant, Spectator, or Eliminated). Used by the arena
-- entry detection and spawn systems.
function PlayerStateService:GetArenaPlayers(): { Player }
	local selfAny = self :: any
	local result = {}
	for player, s in pairs(selfAny._states) do
		if s == "ActiveParticipant" or s == "Spectator" or s == "Eliminated" then
			table.insert(result, player)
		end
	end
	return result
end

return PlayerStateService