--!strict

-- BombManager (Server, Authority)
-- The single owner of bomb state. Assumes that every call into a
-- mutating method is already validated upstream by InteractionService.
--
-- This service is intentionally dumb about *who should* get the bomb --
-- that arbitration is InteractionService's job. BombManager only:
--   * Stores the current holder.
--   * Runs the fuse timer.
--   * Emits INTERNAL server-side events via EventManager.
--
-- It MUST NOT:
--   * Validate tag candidates.
--   * Track cooldowns.
--   * Be called from scanning / detection loops.
--   * Fire RemoteEvents directly. Client replication is the
--     responsibility of ReplicationService -- BombManager only
--     announces the state change to the in-process event bus.
--   * Refuse a transfer because "the call was too soon" -- if a
--     caller is invoking ExecuteTransfer, arbitration has already
--     passed. A refusal from this layer means an authority-level
--     invariant was violated (e.g. holder was reassigned under us)
--     and is treated as a defensive guard, not a normal flow path.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TimeUtil = require(ReplicatedStorage.Shared.Utility.TimeUtil)

local BombManager = {}
BombManager.__index = BombManager
setmetatable(BombManager, { __index = BaseService })

function BombManager.new()
	local self: any = BaseService.new("BombManager")
	self._holder = nil :: Player?
	self._timerEndTime = 0
	self._timerThread = nil :: thread?
	-- In-transfer re-entrancy guard. Set to true at the top of
	-- any mutating call and cleared at the bottom. The
	-- authority is the only layer that owns bomb state, so it
	-- is the only layer that can guarantee no other mutating
	-- call is in flight. Any future path that tries to call
	-- ExecuteTransfer while the previous call has not finished
	-- its synchronous body (e.g. via a callback re-entrancy)
	-- will be rejected with a defensive "transfer in progress"
	-- return. This is the inner-most anti-flip primitive.
	self._isTransferring = false
	-- DIAGNOSTIC: monotonically increasing transfer sequence
	-- number. Stamped onto every transfer so we can correlate
	-- logs across BombManager -> EventManager -> ReplicationService.
	self._nextTransferId = 0
	-- DIAGNOSTIC: total number of times ExecuteTransfer has
	-- been called (including defensive rejections). Used to
	-- identify re-entrancy.
	self._executeTransferCalls = 0
	return setmetatable(self, BombManager)
end

-- AssignBomb is the round-start path. It is called by RoundManager
-- (a trusted authority caller) and is therefore allowed to mutate
-- state directly. It does its own validity check because it is the
-- FIRST holder of a round and has no upstream arbitration to trust.
function BombManager:AssignBomb(player: Player): boolean
	if not self:IsValidBombHolder(player) then
		print("[Bomb] Assign rejected: invalid holder")
		return false
	end

	local selfAny = self :: any
	selfAny._holder = player
	self:ResetTimer()

	-- INTERNAL event only. ReplicationService is the sole consumer
	-- that translates this into a RemoteEvent payload for clients.
	EventManager:Fire(
		EventNames.BombAssignedInternal,
		player,
		GameConfig.Bomb.DurationSeconds
	)

	-- Seed the resolver's rising-edge state for the new
	-- holder. This is a direct in-process call between two
	-- services via the service registry -- NOT an event
	-- subscription. InteractionService does not listen to
	-- events; it is called synchronously here at the moment
	-- of the authority transition. The seed is "the new
	-- holder's full current contacts" so that on the very
	-- next tick, every pre-existing contact of the new
	-- holder is treated as a non-rising-edge and is not
	-- eligible as a transfer target. Only players who walk
	-- INTO the new holder's range AFTER this seed are
	-- eligible. This is what prevents the cluster-drain
	-- chain P1 -> P2 -> P3 at round start.
	self.Services:Get("InteractionService"):SeedPreviousContacts(player)

	return true
end

-- ExecuteTransfer is the tag path. The contract is:
--   "If I am called, it is already valid."
-- InteractionService has already done:
--   * rising-edge eligibility check against the new
--     holder's previousContacts (the new holder can only
--     receive the bomb from a player who is a rising edge
--     of the new holder's contact set -- i.e. a player who
--     has just entered the new holder's range, not a
--     pre-existing contact)
--   * holder identity check
--   * validity check on the target
--   * live distance check
-- The only refusal paths that remain here are defensive guards
-- against a true race (e.g. the holder was reset to nil between
-- the arbitration decision and this call) -- not gameplay logic.
--
-- Note: there are no cooldowns, no global locks, no pair
-- locks, no timers, and no artificial delays in the
-- arbitration path. The rising-edge state is a pure
-- function of the contact snapshot and the holder's
-- previousContacts; it is not driven by wall-clock time.
function BombManager:ExecuteTransfer(fromPlayer: Player, toPlayer: Player): boolean
	local selfAny = self :: any

	-- DIAGNOSTIC: count every entry to ExecuteTransfer, before
	-- any guard. This is the single number that reveals whether
	-- the resolver is re-entering or not.
	selfAny._executeTransferCalls = selfAny._executeTransferCalls + 1
	print(
		`[Bomb] ExecuteTransfer Call #{selfAny._executeTransferCalls} `
		.. `from={fromPlayer.Name} to={toPlayer.Name}`
	)

	-- GUARD 1: in-transfer re-entrancy. If a previous call into
	-- a mutating method is still on the call stack (e.g. a
	-- callback fired another transfer synchronously), refuse
	-- the new call. This is the inner-most anti-flip primitive
	-- and defends against any future path that might chain
	-- transfers without yielding the scheduler.
	if selfAny._isTransferring then
		print("[Bomb] Transfer rejected: re-entrant call (in-transfer)")
		return false
	end
	selfAny._isTransferring = true

	-- Allocate the per-transfer id ONLY for calls that pass
	-- the in-transfer guard. Stamped onto the log lines that
	-- follow so we can correlate the same logical transfer
	-- across the pipeline.
	local transferId = selfAny._nextTransferId
	selfAny._nextTransferId = transferId + 1
	print(`[Transfer #{transferId}] ExecuteTransfer ENTRY from={fromPlayer.Name} to={toPlayer.Name}`)

	-- GUARD 2: holder-mismatch. The caller identified
	-- `fromPlayer` as the expected current holder, but the
	-- authority has moved on. This is a true race: the
	-- arbitration decision is stale by the time we got here.
	if selfAny._holder ~= fromPlayer then
		print(`[Transfer #{transferId}] REJECTED: holder mismatch`)
		selfAny._isTransferring = false
		return false
	end

	-- GUARD 3: identity-state safety. If the requested target
	-- is already the holder, the state is already applied --
	-- do nothing. This protects against any future call site
	-- (e.g. a buggy client intent, a misbehaving admin tool)
	-- that asks for a "transfer" to the current holder.
	if selfAny._holder == toPlayer then
		print(`[Transfer #{transferId}] REJECTED: target == holder (idempotent no-op)`)
		selfAny._isTransferring = false
		return false
	end

	-- Commit. We do NOT re-check IsValidBombHolder on the
	-- target here -- the arbitration layer just did, and a
	-- target that became invalid in the microseconds since is
	-- not our problem to fix; it will surface on the next
	-- assignment.
	selfAny._holder = toPlayer
	self:ResetTimer()

	-- INTERNAL event only. ReplicationService is the sole
	-- consumer that translates this into a RemoteEvent payload
	-- for clients. It must NEVER call back into gameplay
	-- services -- it is pure output.
	print(`[Transfer #{transferId}] Event Fired`)
	EventManager:Fire(EventNames.BombTransferredInternal, fromPlayer, toPlayer, GameConfig.Bomb.DurationSeconds)

	print(`[Transfer #{transferId}] ExecuteTransfer SUCCESS`)
	selfAny._isTransferring = false
	return true
end

function BombManager:ResetTimer()
	local selfAny = self :: any
	selfAny._timerEndTime = TimeUtil.Now() + GameConfig.Bomb.DurationSeconds

	local existingThread = selfAny._timerThread
	if existingThread then
		task.cancel(existingThread)
	end

	selfAny._timerThread = task.spawn(function()
		while TimeUtil.Now() < selfAny._timerEndTime do
			task.wait(0.03)
		end

		self:ExplodeBomb()
	end)
end

function BombManager:ExplodeBomb(): boolean
	local selfAny = self :: any
	local holder = selfAny._holder
	if not holder then
		return false
	end

	selfAny._holder = nil
	selfAny._timerThread = nil

	-- Clear the resolver's rising-edge state for the holder
	-- that just ceased to be the bomb holder. There is no
	-- successor holder in this path (the round either ends
	-- or RoundManager assigns a new holder via AssignBomb,
	-- which will re-seed). Keeping the entry would be
	-- harmless (the resolver only reads entries for the
	-- current holder) but the cleanup keeps the state map
	-- from accumulating dead entries across rounds.
	self.Services:Get("InteractionService"):ClearPreviousContacts(holder)

	-- INTERNAL event only. Note that PlayerEliminated is also
	-- fired on this authority transition because the bomb
	-- exploding is what eliminates the holder in a normal round.
	EventManager:Fire(EventNames.BombExplodedInternal, holder)
	EventManager:Fire(EventNames.PlayerEliminated, holder, "BombExploded")
	return true
end

function BombManager:ClearBomb()
	local selfAny = self :: any
	local existingThread = selfAny._timerThread
	if existingThread then
		task.cancel(existingThread)
	end

	-- Capture the previous holder BEFORE clearing the
	-- authority state, so the resolver cleanup call below
	-- knows whose rising-edge state to drop.
	local previousHolder = selfAny._holder

	selfAny._holder = nil
	selfAny._timerEndTime = 0
	selfAny._timerThread = nil

	-- Clear the resolver's rising-edge state for the holder
	-- that just ceased to be the bomb holder. There is no
	-- successor holder in this path (the round has ended);
	-- any subsequent round will re-seed via AssignBomb.
	if previousHolder then
		self.Services:Get("InteractionService"):ClearPreviousContacts(previousHolder)
	end
end

function BombManager:GetBombHolder(): Player?
	local selfAny = self :: any
	return selfAny._holder
end

function BombManager:GetRemainingTime(): number
	local selfAny = self :: any
	return TimeUtil.SecondsRemaining(selfAny._timerEndTime)
end

-- Read-only helpers used by InteractionService during arbitration.
-- These do not mutate state and are safe to call from any layer.
-- Uses PlayerStateService: only ActiveParticipants are valid holders.
function BombManager:IsValidBombHolder(player: Player): boolean
	return self.Services:Get("PlayerStateService"):IsParticipant(player)
end

function BombManager:GetRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

return BombManager
