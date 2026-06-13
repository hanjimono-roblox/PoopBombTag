--!strict

-- ReplicationService (Server, Bridge)
-- The single bridge between server-side authority events and the
-- client-facing RemoteEvent. The contract enforced by this
-- service is:
--
--   * BombManager and InteractionService NEVER fire RemoteEvents
--     directly. They only fire internal events on EventManager.
--   * ReplicationService is the ONLY server-side service that
--     touches the BombReplication RemoteEvent.
--   * Clients NEVER listen to EventManager for bomb state. They
--     listen to BombReplication.OnClientEvent.
--
-- This indirection is what makes the system work even when
-- EventManager is disabled or unavailable on the client: the
-- internal bus is server-only, so disabling it on the client
-- does not break UI.
--
-- Payload contract (server -> client):
--   BombReplication:
--     type = "Assigned"   : (type, holder: Player, duration: number)
--     type = "Transferred": (type, from: Player, to: Player)
--     type = "Exploded"   : (type, holder: Player)
--     type = "Cleared"    : (type)
--   RoundReplication:
--     type = "RoundStarted"     : (type, mode: string, players: { Player })
--     type = "RoundEnded"       : (type, reason: string, winners: { Player })
--     type = "PlayerWon"        : (type, player: Player)
--     type = "PlayersWon"       : (type, winners: { Player })
--     type = "PlayerReturnedToLobby": (type, player: Player)
--     type = "RoundPlayerLeft"  : (type, player: Player)
--   AnnouncementEvent:
--     (message: string)
--   PlayerAction (client -> server):
--     action = "ReturnToLobby" : (action: string)
--   MapVote (server -> client):
--     type = "MapVoteStarted"  : (type, options: {string}, durationSeconds: number)
--     type = "MapVoteUpdated"  : (type, votes: {[string]: number})
--     type = "MapVoteEnded"    : (type, winner: string, votes: {[string]: number})
--   MapVote (client -> server):
--     action = "CastVote"      : (action: string, mapName: string)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)

local ReplicationService = {}
ReplicationService.__index = ReplicationService
setmetatable(ReplicationService, { __index = BaseService })

local BOMB_REPLICATION_NAME = "BombReplication"
local ROUND_REPLICATION_NAME = "RoundReplication"
local ANNOUNCEMENT_EVENT_NAME = "AnnouncementEvent"
local PLAYER_ACTION_NAME = "PlayerAction"
local MOVEMENT_ACTION_NAME = "MovementAction"
local MOVEMENT_STATE_NAME = "MovementStateReplication"
local MAP_VOTE_NAME = "MapVote"

function ReplicationService.new()
	local self: any = BaseService.new("ReplicationService")
	self._bombRemote = nil :: RemoteEvent?
	self._roundRemote = nil :: RemoteEvent?
	self._announcementRemote = nil :: RemoteEvent?
	self._playerActionRemote = nil :: RemoteEvent?
	self._movementActionRemote = nil :: RemoteEvent?
	self._movementStateRemote = nil :: RemoteEvent?
	self._mapVoteRemote = nil :: RemoteEvent?
	self._started = false
	self._connectionCount = 0
	return setmetatable(self, ReplicationService)
end

function ReplicationService:Start()
	if self._started then
		print(`[Replication] ERROR: Start() called more than once (already started). Refusing to re-subscribe.`)
		return
	end
	self._started = true

	BaseService.Start(self)

	print("[Replication] Start")

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		print("[Replication] error: Remotes folder missing")
		return
	end

	-- Resolve bomb remote
	local bombRemote = remotes:FindFirstChild(BOMB_REPLICATION_NAME)
	if not bombRemote or not bombRemote:IsA("RemoteEvent") then
		print("[Replication] error: BombReplication RemoteEvent missing")
		return
	end
	self._bombRemote = bombRemote

	-- Resolve round remote
	local roundRemote = remotes:FindFirstChild(ROUND_REPLICATION_NAME)
	if not roundRemote or not roundRemote:IsA("RemoteEvent") then
		print("[Replication] error: RoundReplication RemoteEvent missing")
		return
	end
	self._roundRemote = roundRemote

	-- Resolve announcement remote
	local announcementRemote = remotes:FindFirstChild(ANNOUNCEMENT_EVENT_NAME)
	if not announcementRemote or not announcementRemote:IsA("RemoteEvent") then
		print("[Replication] error: AnnouncementEvent RemoteEvent missing")
		return
	end
	self._announcementRemote = announcementRemote

	-- Resolve player action remote (client -> server)
	local playerActionRemote = remotes:FindFirstChild(PLAYER_ACTION_NAME)
	if not playerActionRemote or not playerActionRemote:IsA("RemoteEvent") then
		print("[Replication] error: PlayerAction RemoteEvent missing")
		return
	end
	self._playerActionRemote = playerActionRemote

	-- Resolve movement action remote (client -> server)
	local movementActionRemote = remotes:FindFirstChild(MOVEMENT_ACTION_NAME)
	if not movementActionRemote or not movementActionRemote:IsA("RemoteEvent") then
		print("[Replication] error: MovementAction RemoteEvent missing")
		return
	end
	self._movementActionRemote = movementActionRemote

	-- Resolve movement state remote (server -> client, push)
	local movementStateRemote = remotes:FindFirstChild(MOVEMENT_STATE_NAME)
	if not movementStateRemote or not movementStateRemote:IsA("RemoteEvent") then
		print("[Replication] error: MovementStateReplication RemoteEvent missing")
		return
	end
	self._movementStateRemote = movementStateRemote

	-- Resolve map vote remote (bidirectional)
	local mapVoteRemote = remotes:FindFirstChild(MAP_VOTE_NAME)
	if not mapVoteRemote or not mapVoteRemote:IsA("RemoteEvent") then
		print("[Replication] error: MapVote RemoteEvent missing")
		return
	end
	self._mapVoteRemote = mapVoteRemote

	-- GetMovementState: Client pulls current movement state (RemoteFunction)
	local getMovementState = remotes:FindFirstChild("GetMovementState")
	if getMovementState and getMovementState:IsA("RemoteFunction") then
		getMovementState.OnServerInvoke = function(player: Player)
			local movementService = self.Services:Get("MovementService")
			if movementService then
				return movementService:GetMovementState(player)
			end
			return nil
		end
	end

	-- ---- Bomb replication subscriptions ----

	EventManager:Connect(EventNames.BombAssignedInternal, function(holder: Player, duration: number)
		self:_FireBomb("Assigned", holder, duration)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.BombTransferredInternal, function(fromPlayer: Player, toPlayer: Player, duration: number)
		self:_FireBomb("Transferred", fromPlayer, toPlayer, duration)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.BombExplodedInternal, function(holder: Player)
		self:_FireBomb("Exploded", holder)
	end)
	self._connectionCount = self._connectionCount + 1

	-- ---- Round replication subscriptions ----

	EventManager:Connect(EventNames.RoundStarted, function(mode: string, players: { Player })
		self:_FireRound("RoundStarted", mode, players)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.RoundEnded, function(reason: string, winners: { Player })
		self:_FireRound("RoundEnded", reason, winners)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.PlayerWon, function(player: Player)
		self:_FireRound("PlayerWon", player)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.PlayersWon, function(winners: { Player })
		self:_FireRound("PlayersWon", winners)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.PlayerReturnedToLobby, function(player: Player)
		self:_FireRound("PlayerReturnedToLobby", player)
	end)
	self._connectionCount = self._connectionCount + 1

	EventManager:Connect(EventNames.RoundPlayerLeft, function(player: Player)
		self:_FireRound("RoundPlayerLeft", player)
	end)
	self._connectionCount = self._connectionCount + 1

	-- ---- Player action listener (client -> server) ----

	self._playerActionRemote.OnServerEvent:Connect(function(player: Player, action: string, ...)
		if action == "ReturnToLobby" then
			local roundManager = self.Services:Get("RoundManager")
			if roundManager then
				roundManager:ReturnPlayerToLobby(player)
			end
		end
	end)
	self._connectionCount = self._connectionCount + 1

	-- ---- Movement action listener (client -> server) ----

	self._movementActionRemote.OnServerEvent:Connect(function(player: Player, action: string)
		local movementService = self.Services:Get("MovementService")
		if not movementService then
			return
		end

		if action == "WallClimb" then
			movementService:SetMovementMode(player, "WallGrip")
		elseif action == "Default" then
			movementService:SetMovementMode(player, "Default")
		elseif action == "BeginSwing" then
			movementService:SetMovementMode(player, "Swinging")
		elseif action == "EndSwing" then
			movementService:SetMovementMode(player, "Default")
		end
	end)
	self._connectionCount = self._connectionCount + 1

	-- ---- Movement state replication (server -> client) ----
	-- Pushes modifier changes (ExtraJumps, Speed, etc.) to the owning client.

	EventManager:Connect(EventNames.MovementStateChanged, function(player: Player, state: any)
		if self._movementStateRemote then
			self._movementStateRemote:FireClient(player, state)
		end
	end)
	self._connectionCount = self._connectionCount + 1

	-- ---- MapVote replication subscriptions ----

	-- Bridge MapVoteStarted to clients.
	EventManager:Connect(EventNames.MapVoteStarted, function(options: { string }, durationSeconds: number)
		self:_FireMapVote("MapVoteStarted", options, durationSeconds)
	end)
	self._connectionCount = self._connectionCount + 1

	-- Bridge MapVoteUpdated to clients.
	EventManager:Connect(EventNames.MapVoteUpdated, function(votes: { [string]: number })
		self:_FireMapVote("MapVoteUpdated", votes)
	end)
	self._connectionCount = self._connectionCount + 1

	-- Bridge MapVoteEnded to clients.
	EventManager:Connect(EventNames.MapVoteEnded, function(winner: string, votes: { [string]: number })
		self:_FireMapVote("MapVoteEnded", winner, votes)
	end)
	self._connectionCount = self._connectionCount + 1

	-- Listen for client vote cast actions on the MapVote remote.
	self._mapVoteRemote.OnServerEvent:Connect(function(player: Player, action: string, mapName: string)
		if action == "CastVote" then
			local mapVoteService = self.Services:Get("MapVoteService")
			if mapVoteService then
				mapVoteService:CastVote(player, mapName)
			end
		end
	end)
	self._connectionCount = self._connectionCount + 1

	-- Re-fire current movement state for already-joined players. The
	-- ItemEffectService may have fired MovementStateChanged during its
	-- Start() loop before this bridge was connected. We wait 2 seconds
	-- to ensure clients have loaded their MovementController scripts
	-- and connected OnClientEvent listeners.
	task.wait(2)
	local movementService = self.Services:Get("MovementService")
	if movementService then
		local stateRemote = self._movementStateRemote
		if stateRemote then
			for _, player in ipairs(Players:GetPlayers()) do
				local state = movementService:GetMovementState(player)
				if state then
					stateRemote:FireClient(player, state)
				end
			end
		end
	end

	print(`[Replication] subscribed to all events ({self._connectionCount} total connections)`)
end

-- ---- Fire helpers ----

function ReplicationService:_FireBomb(payloadType: string, ...)
	print(`[Replication] bomb fired {payloadType}`)
	local remote = self._bombRemote
	if not remote then
		print("[Replication] dropped bomb payload (no remote):", payloadType)
		return
	end
	remote:FireAllClients(payloadType, ...)
end

function ReplicationService:_FireRound(payloadType: string, ...)
	print(`[Replication] round fired {payloadType}`)
	local remote = self._roundRemote
	if not remote then
		print("[Replication] dropped round payload (no remote):", payloadType)
		return
	end
	remote:FireAllClients(payloadType, ...)
end

function ReplicationService:_FireMapVote(payloadType: string, ...)
	print(`[Replication] mapvote fired {payloadType}`)
	local remote = self._mapVoteRemote
	if not remote then
		print("[Replication] dropped map vote payload (no remote):", payloadType)
		return
	end
	remote:FireAllClients(payloadType, ...)
end

-- Exposed so other services can broadcast announcements through the
-- single ReplicationService bridge rather than touching RemoteEvents directly.
function ReplicationService:BroadcastAnnouncement(message: string)
	local remote = self._announcementRemote
	if not remote then
		print("[Replication] dropped announcement (no remote)")
		return
	end
	remote:FireAllClients(message)
end

return ReplicationService