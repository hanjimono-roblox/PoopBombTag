--!strict
--[[
	ArenaEntryService (Server, Sensor)
	Detects when players physically enter the arena from the lobby.

	Design Decision: Zone-Based Polling with Touch Acceleration
	----------------------------------------------------------
	The PRIMARY detection mechanism is a server-side Heartbeat-based
	polling loop that checks every Lobby player's character position
	against the configured arena entry zone.

	Why this approach over Part.Touched:
	  * Touched events can fire multiple times, miss fast-moving
	    characters, fire for non-character parts, or fail during
	    character respawns.
	  * A server-side polling loop is immune to client exploits
	    because position is read from the server-authoritative
	    character model.
	  * Zone-based detection can use a configurable bounding region
	    rather than depending on a specific part being in the
	    workspace hierarchy.

	Touch events are used as an acceleration layer: they can trigger
	an immediate re-check but the authoritative decision is always
	made by the polling loop.

	This service MUST:
	  * Detect when a Lobby player's character enters the arena zone
	  * Notify PlayerStateService to evaluate participation
	  * Debounce per player to prevent multiple evaluations

	This service MUST NOT:
	  * Determine participation state directly
	  * Control rounds
	  * Assign winners
	  * Spawn players
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local ArenaEntryService = {}
ArenaEntryService.__index = ArenaEntryService
setmetatable(ArenaEntryService, { __index = BaseService })

-- How many seconds must a player be continuously inside the arena zone
-- before we consider them "entered"? Prevents flicker from lag/bouncy physics.
local ENTRY_CONFIRMATION_SECONDS = 0.3

-- How often (in seconds) do we poll all Lobby players' positions?
local POLL_INTERVAL_SECONDS = 0.25

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function ArenaEntryService.new()
	local self: any = BaseService.new("ArenaEntryService")
	-- _heartbeat: the RunService.Heartbeat connection for polling.
	self._heartbeat = nil :: RBXScriptConnection?
	-- _lastPollTime: tracks when we last ran the full poll.
	self._lastPollTime = 0
	-- _entryProgress: { [Player]: number } -- seconds the player has been
	-- continuously detected inside the arena zone. Resets to 0 when they
	-- leave. When it reaches ENTRY_CONFIRMATION_SECONDS, we fire the entry.
	self._entryProgress = {} :: { [Player]: number }
	-- _evaluatedPlayers: set of players who have already had their arena
	-- entry evaluated. Prevents double-evaluation after state transition.
	-- Cleared when state resets to Lobby.
	self._evaluatedPlayers = {} :: { [Player]: boolean }
	return setmetatable(self, ArenaEntryService)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function ArenaEntryService:Start()
	BaseService.Start(self)

	-- Listen for state changes to clean up internal tracking.
	EventManager:Connect(EventNames.PlayerStateChanged, function(
		player: Player,
		newState: string,
		_oldState: string?
	)
		self:_OnPlayerStateChanged(player, newState)
	end)

	-- Fire the arena entry event so listeners (RoundService) can react.
	-- We also listen to our own event for logging.
	EventManager:Connect(EventNames.ArenaEntered, function(player: Player)
		local logging = self.Services:Get("LoggingService")
		if logging then
			logging:Info("ARENA", `{player.Name} entered the arena`)
		end
	end)

	-- Begin the polling loop.
	local selfAny = self :: any
	selfAny._heartbeat = RunService.Heartbeat:Connect(function(deltaTime: number)
		self:_OnHeartbeat(math.min(deltaTime, 0.5))
	end)

	-- Also listen to the arena entry touch zone for acceleration.
	self:_SetupTouchAcceleration()
end

-- ---------------------------------------------------------------------------
-- Touch Acceleration
-- ---------------------------------------------------------------------------

-- Attempts to wire up Touched events on the arena entry zone parts.
-- This is NOT the authoritative mechanism -- it simply triggers an
-- immediate re-check in the polling loop.
function ArenaEntryService:_SetupTouchAcceleration()
	local arenaEntryZone = self:_FindArenaEntryZone()
	if not arenaEntryZone then
		return
	end

	-- Collect all BaseParts in the entry zone folder/model.
	local parts: { BasePart } = {}
	if arenaEntryZone:IsA("BasePart") then
		table.insert(parts, arenaEntryZone)
	end
	for _, child in ipairs(arenaEntryZone:GetDescendants()) do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end

	for _, part in ipairs(parts) do
		part.Touched:Connect(function(hit: BasePart)
			self:_OnTouchAcceleration(hit)
		end)
	end
end

-- Called when any part touches the arena entry zone. We find the
-- player from the character model and force an immediate poll check.
function ArenaEntryService:_OnTouchAcceleration(hit: BasePart)
	-- Trace up to the character model.
	local character = hit:FindFirstAncestorWhichIsA("Model")
	if not character then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	-- Only process Lobby players. The polling loop will do the
	-- authoritative check.
	local playerStateService = self.Services:Get("PlayerStateService")
	local state = playerStateService:GetState(player)
	if state ~= "Lobby" then
		return
	end

	-- Force an immediate poll of this specific player.
	self:_PollPlayerEntry(player, ENTRY_CONFIRMATION_SECONDS)
end

-- ---------------------------------------------------------------------------
-- Heartbeat Polling Loop
-- ---------------------------------------------------------------------------

function ArenaEntryService:_OnHeartbeat(deltaTime: number)
	local selfAny = self :: any
	selfAny._lastPollTime = selfAny._lastPollTime + deltaTime

	-- Only run the full poll at the configured interval.
	if selfAny._lastPollTime < POLL_INTERVAL_SECONDS then
		return
	end
	selfAny._lastPollTime = 0

	local playerStateService = self.Services:Get("PlayerStateService")

	-- Poll every Lobby player.
	local lobbyPlayers = playerStateService:GetLobbyPlayers()
	for _, player in ipairs(lobbyPlayers) do
		self:_PollPlayerEntry(player, deltaTime)
	end

	-- Clean up tracking for players who left.
	for player, _ in pairs(selfAny._entryProgress) do
		if not player.Parent then
			selfAny._entryProgress[player] = nil
			selfAny._evaluatedPlayers[player] = nil
		end
	end
end

-- Checks a single Lobby player to see if they have entered the arena.
-- Accumulates entry progress and fires ArenaEntered when confirmed.
function ArenaEntryService:_PollPlayerEntry(player: Player, deltaTime: number)
	local selfAny = self :: any

	-- Skip players already evaluated (until their state resets to Lobby).
	if selfAny._evaluatedPlayers[player] then
		return
	end

	local isInArena = self:_IsPlayerCharacterInArenaZone(player)

	if isInArena then
		local progress = (selfAny._entryProgress[player] or 0) + deltaTime
		selfAny._entryProgress[player] = progress

		if progress >= ENTRY_CONFIRMATION_SECONDS then
			-- Confirmed entry! Mark as evaluated and fire the event.
			selfAny._evaluatedPlayers[player] = true
			selfAny._entryProgress[player] = nil
			EventManager:Fire(EventNames.ArenaEntered, player)
		end
	else
		-- Player left the zone before confirmation: reset progress.
		selfAny._entryProgress[player] = nil
	end
end

-- ---------------------------------------------------------------------------
-- Zone Detection
-- ---------------------------------------------------------------------------

-- Returns true if the player's character root part is inside the
-- configured arena entry zone.
function ArenaEntryService:_IsPlayerCharacterInArenaZone(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	local zone = self:_GetArenaZoneRegion()
	if not zone then
		return false
	end

	local pos = root.Position
	return pos.X >= zone.Min.X and pos.X <= zone.Max.X
		and pos.Y >= zone.Min.Y and pos.Y <= zone.Max.Y
		and pos.Z >= zone.Min.Z and pos.Z <= zone.Max.Z
end

-- Returns the arena zone bounding region. The primary source is the
-- ArenaEntryZone part/model in the active map or lobby. Falls back to
-- config-defined bounds.
function ArenaEntryService:_GetArenaZoneRegion(): { Min: Vector3, Max: Vector3 }?
	-- First try the ArenaEntryZone instance.
	local entryZone = self:_FindArenaEntryZone()
	if entryZone then
		local cframe: CFrame
		local size: Vector3

		if entryZone:IsA("BasePart") then
			cframe = entryZone.CFrame
			size = entryZone.Size
		else
			local primaryPart = entryZone:FindFirstChildWhichIsA("BasePart")
			if not primaryPart then
				return nil
			end
			-- Use the model's bounding box as a rough approximation.
			local modelSize = entryZone:GetExtentsSize()
			cframe = entryZone:GetPivot()
			size = modelSize
		end

		local halfSize = size / 2
		return {
			Min = cframe.Position - halfSize,
			Max = cframe.Position + halfSize,
		}
	end

	-- Fall back to config-defined zone.
	local cfg = GameConfig.Arena
	if not cfg or not cfg.EntryZoneMin or not cfg.EntryZoneMax then
		return nil
	end

	return {
		Min = cfg.EntryZoneMin,
		Max = cfg.EntryZoneMax,
	}
end

-- Finds the ArenaEntryZone instance in the workspace. Looks in the
-- active map first, then in the lobby, then anywhere in workspace.
function ArenaEntryService:_FindArenaEntryZone(): Instance?
	-- Check the active map first.
	local activeMap = Workspace:FindFirstChild(GameConfig.Maps.ActiveMapParentName)
	if activeMap then
		local zone = activeMap:FindFirstChild("ArenaEntryZone", true)
		if zone and (zone:IsA("BasePart") or zone:IsA("Model")) then
			return zone
		end
	end

	-- Check the lobby.
	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then
		local zone = lobby:FindFirstChild("ArenaEntryZone", true)
		if zone and (zone:IsA("BasePart") or zone:IsA("Model")) then
			return zone
		end
	end

	-- Fallback: search entire workspace.
	local zone = Workspace:FindFirstChild("ArenaEntryZone", true)
	if zone and (zone:IsA("BasePart") or zone:IsA("Model")) then
		return zone
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- State Change Handler
-- ---------------------------------------------------------------------------

-- Reset tracking when a player returns to Lobby so they can enter again.
function ArenaEntryService:_OnPlayerStateChanged(player: Player, newState: string)
	local selfAny = self :: any
	if newState == "Lobby" then
		-- Player is back in the lobby; they can enter the arena again.
		selfAny._evaluatedPlayers[player] = nil
		selfAny._entryProgress[player] = nil
	end
end

return ArenaEntryService