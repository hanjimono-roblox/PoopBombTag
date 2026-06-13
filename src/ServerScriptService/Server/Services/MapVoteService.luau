--!strict
--[[
	MapVoteService (Server, Authority)

	Owns the map voting lifecycle:
	  1. Collect available maps (excluding Lobby) from ServerStorage/Maps
	  2. Present a subset to players as voting options
	  3. Open a timed voting window
	  4. Tally votes and determine the winning map
	  5. Fire an event with the result so GameManager/RoundManager can load it

	This service NEVER touches RemoteEvents directly. It fires internal
	EventManager events. ReplicationService bridges them to clients.

	Event contract:
	  EventNames.MapVoteStarted  -> (options: {string}, durationSeconds: number)
	  EventNames.MapVoteUpdated  -> (votes: {[string]: number})
	  EventNames.MapVoteEnded    -> (winner: string, votes: {[string]: number})
	  EventNames.MapVoteCasted   -> (player: Player, mapName: string)  [server internal]

	The vote is purely advisory — the server picks the winner and loads it.
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local MapVoteService = {}
MapVoteService.__index = MapVoteService
setmetatable(MapVoteService, { __index = BaseService })

function MapVoteService.new()
	local self: any = BaseService.new("MapVoteService")
	-- Whether a vote is currently in progress
	self._votingActive = false
	-- The map options being voted on
	self._options = {} :: { string }
	-- Vote tally: mapName -> vote count
	self._votes = {} :: { [string]: number }
	-- Players who have already cast a vote (prevent double-voting)
	self._voters = {} :: { [Player]: boolean }
	-- Timer thread for vote countdown
	self._voteTimer = nil :: thread?
	return setmetatable(self, MapVoteService)
end

function MapVoteService:Start()
	BaseService.Start(self)
	self.Services:Get("LoggingService"):Info("VOTE", "MapVoteService started")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns true if a vote is currently in progress.
function MapVoteService:IsVotingActive(): boolean
	local selfAny = self :: any
	return selfAny._votingActive
end

-- Returns the current vote state (options and tallies).
-- Returns nil if no vote is active.
function MapVoteService:GetVoteState(): { options: { string }, votes: { [string]: number } }?
	local selfAny = self :: any
	if not selfAny._votingActive then
		return nil
	end
	return {
		options = selfAny._options,
		votes = selfAny._votes,
	}
end

-- ---------------------------------------------------------------------------
-- Vote Lifecycle
-- ---------------------------------------------------------------------------

-- Starts a map vote. Collects eligible maps, selects options, and opens
-- the voting window. Returns true if voting started, false if conditions
-- are not met (not enough maps).
function MapVoteService:StartVote(): boolean
	local selfAny = self :: any
	if selfAny._votingActive then
		return false
	end

	-- Collect eligible maps (all maps in ServerStorage/Maps excluding Lobby).
	local eligibleMaps = self:_GetEligibleMaps()
	if #eligibleMaps < GameConfig.MapVote.MinimumMapsForVote then
		-- Not enough maps to vote on; skip voting entirely.
		self.Services:Get("LoggingService"):Info(
			"VOTE",
			`Not enough maps for vote ({#eligibleMaps} eligible, need {GameConfig.MapVote.MinimumMapsForVote}). Skipping.`
		)
		return false
	end

	-- Select a subset of maps as voting options.
	local options = self:_SelectOptions(eligibleMaps)

	-- Initialize state.
	selfAny._votingActive = true
	selfAny._options = options
	selfAny._votes = {}
	selfAny._voters = {}

	-- Initialize vote tallies to zero for each option.
	for _, mapName in ipairs(options) do
		selfAny._votes[mapName] = 0
	end

	local duration = GameConfig.MapVote.VoteDurationSeconds

	local optionsStr = table.concat(options, ", ")
	self.Services:Get("LoggingService"):Info(
		"VOTE",
		`Vote started: {optionsStr} (duration: {duration}s)`
	)

	-- Fire the vote-started event so ReplicationService bridges it to clients.
	EventManager:Fire(EventNames.MapVoteStarted, options, duration)

	-- Start the countdown timer.
	selfAny._voteTimer = task.spawn(function()
		task.wait(duration)
		self:EndVote()
	end)

	return true
end

-- Casts a player's vote for a map. Returns true if the vote was accepted,
-- false if the vote is invalid (not active, player already voted, invalid map).
function MapVoteService:CastVote(player: Player, mapName: string): boolean
	local selfAny = self :: any
	if not selfAny._votingActive then
		return false
	end

	-- Check if the player already voted.
	if selfAny._voters[player] then
		return false
	end

	-- Check if the map name is a valid option.
	local isValidOption = false
	for _, option in ipairs(selfAny._options) do
		if option == mapName then
			isValidOption = true
			break
		end
	end
	if not isValidOption then
		return false
	end

	-- Record the vote.
	selfAny._voters[player] = true
	selfAny._votes[mapName] = selfAny._votes[mapName] + 1

	local voteTotal = selfAny._votes[mapName]
	self.Services:Get("LoggingService"):Info(
		"VOTE",
		`{player.Name} voted for {mapName} (total: {voteTotal})`
	)

	-- Fire internal event for the vote cast.
	EventManager:Fire(EventNames.MapVoteCasted, player, mapName)

	-- Broadcast updated tallies to clients.
	EventManager:Fire(EventNames.MapVoteUpdated, selfAny._votes)

	return true
end

-- Ends the vote, tallies results, fires the result event, and cleans up.
-- Returns the winning map name.
function MapVoteService:EndVote(): string
	local selfAny = self :: any
	if not selfAny._votingActive then
		return ""
	end

	selfAny._votingActive = false

	-- Cancel the timer if it's still running.
	if selfAny._voteTimer then
		task.cancel(selfAny._voteTimer)
		selfAny._voteTimer = nil
	end

	-- Determine the winner (highest vote count; tie-break by random selection).
	local winner = self:_DetermineWinner(selfAny._options, selfAny._votes)

	self.Services:Get("LoggingService"):Info(
		"VOTE",
		`Vote ended. Winner: {winner}`
	)

	-- Broadcast the result.
	EventManager:Fire(EventNames.MapVoteEnded, winner, selfAny._votes)

	-- Clean up vote state.
	selfAny._options = {}
	selfAny._votes = {}
	selfAny._voters = {}

	return winner
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Returns a list of map names from ServerStorage/Maps, excluding Lobby.
function MapVoteService:_GetEligibleMaps(): { string }
	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	if not mapsFolder then
		return {}
	end

	local eligible = {}
	for _, child in ipairs(mapsFolder:GetChildren()) do
		if child.Name ~= "Lobby" then
			table.insert(eligible, child.Name)
		end
	end
	return eligible
end

-- Selects a random subset of eligible maps as voting options.
-- Returns up to MapVote.OptionsCount maps.
function MapVoteService:_SelectOptions(eligibleMaps: { string }): { string }
	local maxOptions = GameConfig.MapVote.OptionsCount
	local count = math.min(maxOptions, #eligibleMaps)

	-- Shuffle eligible maps and take the first `count`.
	local shuffled = {}
	local indices = {}
	for i = 1, #eligibleMaps do
		indices[i] = i
	end
	for i = #indices, 2, -1 do
		local j = math.random(1, i)
		indices[i], indices[j] = indices[j], indices[i]
	end
	for i = 1, count do
		table.insert(shuffled, eligibleMaps[indices[i]])
	end
	return shuffled
end

-- Determines the winning map from vote tallies.
-- The map with the highest vote count wins.
-- In case of a tie, one of the tied maps is selected at random.
function MapVoteService:_DetermineWinner(options: { string }, votes: { [string]: number }): string
	local highestCount = 0
	local tiedMaps = {} :: { string }

	for _, mapName in ipairs(options) do
		local count = votes[mapName] or 0
		if count > highestCount then
			highestCount = count
			tiedMaps = { mapName }
		elseif count == highestCount then
			table.insert(tiedMaps, mapName)
		end
	end

	-- If all votes are zero, pick randomly from options.
	if highestCount == 0 then
		return options[math.random(1, #options)]
	end

	-- Tie-break: pick randomly from tied maps.
	return tiedMaps[math.random(1, #tiedMaps)]
end

return MapVoteService