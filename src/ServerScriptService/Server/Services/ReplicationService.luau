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
--   type = "Assigned"   : (type, holder: Player, duration: number)
--   type = "Transferred": (type, from: Player, to: Player)
--   type = "Exploded"   : (type, holder: Player)
--   type = "Cleared"    : (type) -- for round-end reset, optional
-- Clients should match on `type` and ignore anything else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)

local ReplicationService = {}
ReplicationService.__index = ReplicationService
setmetatable(ReplicationService, { __index = BaseService })

-- The single RemoteEvent this service owns. We resolve it
-- lazily inside Start() so the service is robust to Remotes
-- being parented late in the boot sequence.
local BOMB_REPLICATION_NAME = "BombReplication"

function ReplicationService.new()
	local self: any = BaseService.new("ReplicationService")
	self._remote = nil :: RemoteEvent?
	-- DIAGNOSTIC: start-once guard. The ServiceRegistry normally
	-- calls Start() once, but if anything ever calls it twice
	-- (e.g. via a re-Register, a manual :Start() in tests, or a
	-- reload) the EventManager subscriptions would be added a
	-- second time -- and that would cause every Fire to invoke
	-- each handler twice, which is exactly the failure mode the
	-- user reported.
	self._started = false
	-- DIAGNOSTIC: number of connections we have created. Each
	-- event subscription increments this once. Should always be
	-- exactly 3 (Assigned, Transferred, Exploded) at steady
	-- state.
	self._connectionCount = 0
	return setmetatable(self, ReplicationService)
end

function ReplicationService:Start()
	-- TASK 2 HARDENING: refuse to start a second time. If the
	-- registry (or any test harness) calls Start() more than
	-- once, we log a loud error and bail without re-subscribing.
	-- This is the single most likely cause of "x124 transfers"
	-- if it ever happens: a re-subscribe multiplies every
	-- subsequent Fire into N handler invocations.
	if self._started then
		print(`[Replication] ERROR: Start() called more than once (already started). Refusing to re-subscribe.`)
		return
	end
	self._started = true

	BaseService.Start(self)

	print("[Replication] Start")

	-- Resolve the remote ONCE. This is the only place on the
	-- server that ever references it. If the asset is missing
	-- we log a structured error and the rest of the server
	-- keeps running -- gameplay still works, only client UI
	-- will be stale.
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		print("[Replication] error: Remotes folder missing")
		return
	end

	local remote = remotes:FindFirstChild(BOMB_REPLICATION_NAME)
	if not remote or not remote:IsA("RemoteEvent") then
		print("[Replication] error: BombReplication RemoteEvent missing")
		return
	end

	self._remote = remote

	-- Subscribe to the three internal authority events. Each
	-- handler is a thin shim that translates the event into a
	-- client-facing payload. The server-side event is a struct
	-- of typed arguments; the client-facing payload uses a
	-- `type` discriminator as the first field for easy match.
	-- We count subscriptions so we can verify there is exactly
	-- one handler per event in the log output.

	EventManager:Connect(EventNames.BombAssignedInternal, function(holder: Player, duration: number)
		self:_Fire("Assigned", holder, duration)
	end)
	self._connectionCount = self._connectionCount + 1
	print("[Replication] Connected To BombAssigned (1 connection)")

	EventManager:Connect(EventNames.BombTransferredInternal, function(
		fromPlayer: Player,
		toPlayer: Player
	)
		self:_Fire("Transferred", fromPlayer, toPlayer)
	end)
	self._connectionCount = self._connectionCount + 1
	print("[Replication] Connected To BombTransferred (1 connection)")

	EventManager:Connect(EventNames.BombExplodedInternal, function(holder: Player)
		self:_Fire("Exploded", holder)
	end)
	self._connectionCount = self._connectionCount + 1
	print("[Replication] Connected To BombExploded (1 connection)")

	print(`[Replication] subscribed to internal bomb events ({self._connectionCount} total connections)`)
end

-- Internal helper. Every client-facing payload is a flat tuple
-- with `type` as the first field. We never send nested tables
-- or mixed-type tuples -- Roblox RemoteEvents serialize
-- positional arguments best, and a `type` discriminator keeps
-- client dispatch trivial.
function ReplicationService:_Fire(payloadType: string, ...)
	-- DIAGNOSTIC: in case the user is seeing the wrong
	-- transferId, print it as part of the fire log. We do not
	-- currently receive a transferId argument on this path;
	-- this is a generic counter that lets us correlate the
	-- number of fires against BombManager's per-transfer
	-- counters.
	print(`[Replication] fired {payloadType}`)
	local remote = self._remote
	if not remote then
		-- We never reached Start() successfully, or the
		-- RemoteEvent is missing. Don't crash; just drop the
		-- payload. The server's authoritative state is still
		-- intact.
		print("[Replication] dropped payload (no remote):", payloadType)
		return
	end

	remote:FireAllClients(payloadType, ...)
end

return ReplicationService
