--!strict
--[[
	RoundManager (Server, Authority)
	Refactored for arena-driven participation.

	This service OWNS:
	  * Round lifecycle (waiting → intermission → starting → playing → roundEnd)
	  * Win condition evaluation
	  * Elimination processing
	  * Participant validation (via PlayerStateService)

	This service MUST NOT:
	  * Infer participation from workspace position
	  * Auto-enroll all server players
	  * Teleport players into the arena to start rounds
	  * Track player state directly (defer to PlayerStateService)
	  * Spawn players directly (defer to SpawnService)

	Participation model:
	  Only players in the "ActiveParticipant" state (as tracked by
	  PlayerStateService) count toward round requirements and can
	  participate in gameplay. Lobby players, Spectators, and
	  Eliminated players are excluded.

	Round start:
	  When minimum ActiveParticipants are present (from GameConfig),
	  the round begins. Players are already physically in the arena
	  because they voluntarily entered via the ArenaEntryService.

	Elimination:
	  ActiveParticipant → Eliminated (via PlayerStateService)

	Round end:
	  All gameplay-related players (ActiveParticipant, Spectator,
	  Eliminated) are returned to Lobby via PlayerStateService.
]]

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

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function RoundManager.new()
	local self: any = BaseService.new("RoundManager")
	self._active = false
	self._mode = GameConfig.Round.DefaultMode
	-- Track the round's participant roster for eligibility checks.
	-- These are the players who were ActiveParticipants at round start.
	self._roundParticipants = {} :: { Player }
	return setmetatable(self, RoundManager)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function RoundManager:Start()
	BaseService.Start(self)

	-- When a player is eliminated (via BombManager explosion), process it.
	EventManager:Connect(EventNames.PlayerEliminated, function(player: Player, reason: string)
		self:EliminatePlayer(player, reason)
	end)

	-- Listen for arena entry to log transitions.
	EventManager:Connect(EventNames.ArenaEntered, function(player: Player)
		local stateService = self.Services:Get("PlayerStateService")
		local roundActive = self:IsActive()

		if not roundActive then
			-- No round active: player becomes ActiveParticipant.
			stateService:SetState(player, "ActiveParticipant")
		else
			-- Round is active: player becomes Spectator (no late joins).
			stateService:SetState(player, "Spectator")
			-- Spawn them as a spectator.
			self.Services:Get("SpawnService"):SpawnSpectator(player)
		end
	end)

	-- When player state changes, check round end conditions if active.
	EventManager:Connect(EventNames.PlayerStateChanged, function(
		player: Player,
		newState: string,
		_oldState: string?
	)
		self:_OnPlayerStateChanged(player, newState)
	end)

	-- Handle player leaving the server mid-round.
	Players.PlayerRemoving:Connect(function(player: Player)
		self:_OnPlayerLeaving(player)
	end)
end

-- ---------------------------------------------------------------------------
-- Round Lifecycle API
-- ---------------------------------------------------------------------------

-- Returns true if a round is currently active.
function RoundManager:IsActive(): boolean
	local selfAny = self :: any
	return selfAny._active
end

-- Returns the current round mode ("FirstElimination" or "LastManStanding").
function RoundManager:GetMode(): string
	local selfAny = self :: any
	return selfAny._mode
end

-- Attempts to start a round. Returns true if the round was started,
-- false if conditions are not met.
--
-- Prerequisites:
--   1. No round currently active.
--   2. Enough ActiveParticipants (from PlayerStateService).
--   3. Map can be loaded.
function RoundManager:StartRound(mode: string?): boolean
	local selfAny = self :: any
	if selfAny._active then
		return false
	end

	local stateService = self.Services:Get("PlayerStateService")
	local participants = stateService:GetActiveParticipants()

	if #participants < GameConfig.Round.MinimumPlayers then
		return false
	end

	local resolvedMode = mode or GameConfig.Round.DefaultMode

	-- Load the arena map.
	local mapManager = self.Services:Get("MapManager")
	local map = mapManager:LoadMap()
	if not map then
		return false
	end

	-- Lock the round state.
	selfAny._active = true
	selfAny._mode = resolvedMode

	-- Build the round roster from ActiveParticipants.
	-- This is a snapshot; players who enter the arena after this
	-- point become Spectators, not participants.
	table.clear(selfAny._roundParticipants)
	for _, player in ipairs(participants) do
		table.insert(selfAny._roundParticipants, player)
	end

	-- Distribute participants across arena spawn points.
	-- They are already inside the arena because they chose to jump in.
	-- This step ensures they're at valid spawn positions within the map.
	self.Services:Get("SpawnService"):DistributeParticipantsInArena(participants)

	-- Select the starting bomb holder.
	local bombHolder = participants[math.random(1, #participants)]
	self.Services:Get("BombManager"):AssignBomb(bombHolder)

	-- Announce the round start.
	EventManager:Fire(EventNames.RoundStarted, resolvedMode, participants)

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("ROUND", `Round started with {#participants} participants (mode: {resolvedMode})`)
	end

	return true
end

-- Ends the active round. Returns true if the round was ended,
-- false if no round was active.
function RoundManager:EndRound(reason: string?, winners: { Player }?): boolean
	local selfAny = self :: any
	if not selfAny._active then
		return false
	end

	local resolvedWinners = winners or self:DetermineWinners()
	selfAny._active = false

	-- Clear bomb state.
	self.Services:Get("BombManager"):ClearBomb()

	-- Fire winner events.
	for _, winner in ipairs(resolvedWinners) do
		EventManager:Fire(EventNames.PlayerWon, winner)
	end
	EventManager:Fire(EventNames.PlayersWon, resolvedWinners)

	-- Award currency.
	self:AwardWinners(resolvedWinners)

	-- Return all gameplay-related players to Lobby.
	self:_ResetAllPlayersToLobby()

	-- Unload the map.
	self.Services:Get("MapManager"):UnloadMap()

	-- Clear round roster.
	table.clear(selfAny._roundParticipants)

	EventManager:Fire(EventNames.RoundEnded, reason or "Completed", resolvedWinners)

	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("ROUND", `Round ended: {reason or "Completed"} (winners: {#resolvedWinners})`)
	end

	return true
end

-- ---------------------------------------------------------------------------
-- Elimination
-- ---------------------------------------------------------------------------

-- Eliminates a player from the active round. Called when
-- PlayerEliminated event fires (typically from BombManager explosion).
function RoundManager:EliminatePlayer(player: Player, reason: string)
	local selfAny = self :: any
	if not selfAny._active then
		return
	end

	local stateService = self.Services:Get("PlayerStateService")
	local currentState = stateService:GetState(player)

	-- Only ActiveParticipants can be eliminated.
	if currentState ~= "ActiveParticipant" then
		return
	end

	-- Transition: ActiveParticipant → Eliminated.
	stateService:SetState(player, "Eliminated")

	local activeParticipants = stateService:GetActiveParticipants()
	local mode = selfAny._mode

	-- Check win conditions.
	if mode == RoundModes.FirstElimination then
		-- In FirstElimination, first person eliminated → everyone else wins.
		self:EndRound(reason, activeParticipants)
		return
	end

	if #activeParticipants <= 1 then
		-- Last person standing wins.
		self:EndRound("LastPlayerStanding", activeParticipants)
		return
	end

	-- Assign bomb to a new holder if round continues.
	local bombManager = self.Services:Get("BombManager")
	if bombManager:GetBombHolder() == nil then
		if #activeParticipants > 0 then
			bombManager:AssignBomb(activeParticipants[math.random(1, #activeParticipants)])
		end
	end
end

-- ---------------------------------------------------------------------------
-- Win Determination
-- ---------------------------------------------------------------------------

-- Returns the list of winners for the current round based on the mode.
function RoundManager:DetermineWinners(): { Player }
	local stateService = self.Services:Get("PlayerStateService")
	return stateService:GetActiveParticipants()
end

-- Awards currency to winners based on the round mode.
function RoundManager:AwardWinners(winners: { Player })
	local selfAny = self :: any
	local reward = if selfAny._mode == RoundModes.FirstElimination
		then GameConfig.Rewards.FirstEliminationWinnerPoop
		else GameConfig.Rewards.LastManStandingWinnerPoop

	local currencyManager = self.Services:Get("CurrencyManager")
	for _, winner in ipairs(winners) do
		currencyManager:AddPoop(winner, reward)
		EventManager:Fire(EventNames.PoopAwarded, winner, reward)
	end
end

-- ---------------------------------------------------------------------------
-- Player Return to Lobby (Voluntary)
-- ---------------------------------------------------------------------------

-- Allows a player to voluntarily return to the lobby during an active round.
-- The player forfeits their participation.
function RoundManager:ReturnPlayerToLobby(player: Player): boolean
	local stateService = self.Services:Get("PlayerStateService")
	local currentState = stateService:GetState(player)

	if currentState ~= "ActiveParticipant" then
		return false
	end

	-- Transition: ActiveParticipant → Lobby.
	stateService:SetState(player, "Lobby")

	-- Teleport them back to the lobby.
	self.Services:Get("SpawnService"):SpawnInLobby(player)

	-- Check if the round should end because of this departure.
	local selfAny = self :: any
	if selfAny._active then
		local activeParticipants = stateService:GetActiveParticipants()
		local mode = selfAny._mode

		if #activeParticipants <= 1 then
			self:EndRound("LastPlayerStanding", activeParticipants)
		elseif #activeParticipants == 0 then
			self:EndRound("AllReturned", {})
		end
	end

	EventManager:Fire(EventNames.PlayerReturnedToLobby, player)
	return true
end

-- ---------------------------------------------------------------------------
-- Internal Handlers
-- ---------------------------------------------------------------------------

-- Called when a player's state changes. Checks round end conditions.
function RoundManager:_OnPlayerStateChanged(player: Player, newState: string)
	local selfAny = self :: any
	if not selfAny._active then
		return
	end

	-- If an ActiveParticipant transitions to Eliminated, check win conditions.
	-- The actual elimination logic is in EliminatePlayer; this is a
	-- secondary check for state changes triggered from other paths.
	if newState == "Eliminated" then
		local stateService = self.Services:Get("PlayerStateService")
		local activeParticipants = stateService:GetActiveParticipants()

		if #activeParticipants <= 1 then
			self:EndRound("LastPlayerStanding", activeParticipants)
		end
	end
end

-- Called when a player leaves the server. If they were an ActiveParticipant
-- and a round is active, treat it as an elimination.
function RoundManager:_OnPlayerLeaving(player: Player)
	local selfAny = self :: any
	if not selfAny._active then
		return
	end

	local stateService = self.Services:Get("PlayerStateService")
	local currentState = stateService:GetState(player)

	if currentState == "ActiveParticipant" then
		-- Treat server leave as elimination.
		stateService:SetState(player, "Eliminated")

		local activeParticipants = stateService:GetActiveParticipants()

		if #activeParticipants <= 1 then
			self:EndRound("PlayerLeft", activeParticipants)
		end
	end
end

-- Resets all gameplay-related players back to Lobby.
-- Called at round end.
function RoundManager:_ResetAllPlayersToLobby()
	local stateService = self.Services:Get("PlayerStateService")
	local spawnService = self.Services:Get("SpawnService")

	-- Collect players who need to be returned to lobby.
	local playersToReset: { Player } = {}

	for _, player in ipairs(stateService:GetActiveParticipants()) do
		table.insert(playersToReset, player)
	end
	for _, player in ipairs(stateService:GetEliminatedPlayers()) do
		table.insert(playersToReset, player)
	end
	for _, player in ipairs(stateService:GetSpectators()) do
		table.insert(playersToReset, player)
	end

	-- Transition all to Lobby.
	for _, player in ipairs(playersToReset) do
		stateService:SetState(player, "Lobby")
	end

	-- Spawn them all in the lobby.
	spawnService:SpawnAllInLobby(playersToReset)
end

-- ---------------------------------------------------------------------------
-- Query Helpers
-- ---------------------------------------------------------------------------

-- Returns the current round participants (ActiveParticipants at round start).
function RoundManager:GetRoundParticipants(): { Player }
	local selfAny = self :: any
	local copy = {}
	for _, p in ipairs(selfAny._roundParticipants) do
		table.insert(copy, p)
	end
	return copy
end

-- Returns the currently alive participants (ActiveParticipants).
function RoundManager:GetAlivePlayers(): { Player }
	return self.Services:Get("PlayerStateService"):GetActiveParticipants()
end

return RoundManager