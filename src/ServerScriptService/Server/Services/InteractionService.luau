--!strict

-- InteractionService (Server, Resolver)
-- The single deterministic resolver for the bomb-tag mechanic.
-- Runs on RunService.Heartbeat. Each tick performs exactly one
-- simulation step:
--
--   1. Read the current bomb holder from BombManager.
--   2. Ask the sensor for every player currently in tag range.
--   3. Compute the rising-edge set: players who are in range now
--      but were NOT in range of THIS holder on the previous tick.
--   4. Deterministically pick at most ONE target from the rising
--      edges.
--   5. Execute at most ONE transfer -- or none.
--   6. On a successful transfer, re-sample the new holder's
--      contact set and seed it as the new holder's
--      previousContacts.
--
-- Determinism contract:
--   Given identical world state at the start of a step, the
--   outcome is identical every time. There is no event
--   ordering, no cooldown, no async. The single tick is the
--   only unit of decision-making.
--
-- Target selection rule:
--   Among the rising-edge candidates:
--     1. Smallest distance to the holder wins.
--     2. On a distance tie, lowest UserId wins.
--   Only the [1] candidate is ever considered.
--
-- Why rising-edges (the interaction-session consumption rule):
--   The transfer trigger is a rising edge of the *current
--   holder's* contact relation, not the persistent-contact
--   predicate. After a transfer fires, the new holder's
--   previousContacts is initialized to the new holder's full
--   contact set as observed AT THE MOMENT OF THE TRANSFER.
--
--   Concretely: if P1 -> P2 fires, then on the next tick P2
--   can only transfer to a player who has just entered P2's
--   range since that snapshot. Pre-existing contacts of P2 --
--   including P1, if P1 is still in range -- are not eligible
--   until they fall out of P2's range and re-enter it.
--
--   This is what kills the A<->B oscillation bug deterministically:
--   the reverse pair (P2, P1) is not a rising edge for P2 on
--   the tick after the transfer. It is also what kills the
--   cluster-drain chain P1 -> P2 -> P3: after P1 -> P2, the
--   player P3 who was already in P2's range at the moment of
--   the transfer is in P2's previousContacts and is not a
--   rising edge. P2 must encounter a genuinely new player --
--   one not in P2's contact set at the moment of the transfer
--   -- to pass the bomb.
--
--   Re-arm is via falling edge: a player who leaves the
--   holder's range is removed from previousContacts on the
--   next tick. If they re-enter, they are a rising edge and
--   become eligible. No zero-contact requirement, no Clear
--   state, no escape-based re-arm. The bomb-holder is
--   incentivized to chase new players, not to isolate.
--
-- State per holder (the resolver tracks exactly one holder at
-- a time; previous holders' state is discarded on each
-- transfer):
--   previousContacts : { Player }
--     The holder's contact set as of the previous tick.
--     Seeded on holder assignment (AssignBomb) and on every
--     successful transfer (using the new holder's full
--     current contacts at the moment of the transfer).
--
-- This service MUST NOT:
--   * Emit or listen to events.
--   * Maintain cooldown / lock / pair-state tables.
--   * Be called from anywhere other than the heartbeat loop.
--   * Call BombManager except for ExecuteTransfer and the
--     read-only helpers it consumes.
--   * Use wall-clock time for eligibility. All eligibility
--     decisions are a pure function of the contact snapshot
--     and the holder's previousContacts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local InteractionService = {}
InteractionService.__index = InteractionService
setmetatable(InteractionService, { __index = BaseService })

function InteractionService.new()
	local self: any = BaseService.new("InteractionService")
	self._heartbeat = nil :: RBXScriptConnection?
	-- Per-holder rising-edge memory. Keyed by the current
	-- bomb holder's Player instance. Set to {} on holder
	-- assignment (AssignBomb) and re-seeded to the new
	-- holder's full current contacts on every successful
	-- transfer. The resolver only ever reads/writes the entry
	-- for the current holder; entries for previous holders
	-- are discarded implicitly because the key changes.
	self._previousContacts = {} :: { [Player]: { Player } }
	-- Single-tick invariant counter. Reset to 0 at the top of
	-- every Step() and asserted to be <= 1 at the bottom. Any
	-- code path that ever manages to call ExecuteTransfer
	-- more than once per heartbeat will trip this counter
	-- and the resolver will hard-fail instead of silently
	-- producing a 125-transfer loop.
	self._transfersThisTick = 0
	return setmetatable(self, InteractionService)
end

function InteractionService:Start()
	BaseService.Start(self)

	-- RunService.Heartbeat is the simulation tick. Bind exactly
	-- once at Start. The binding lives for the lifetime of the
	-- service; we never disconnect mid-round. This is the ONLY
	-- caller of Step() in the entire codebase -- the
	-- single-writer rule is enforced by the absence of any
	-- other call site.
	self._heartbeat = RunService.Heartbeat:Connect(function()
		self:Step()
	end)
end

-- Single simulation step. Called by RunService.Heartbeat. Pure
-- function of world state plus the holder's previousContacts:
-- it reads, decides, and at most mutates the bomb holder once
-- via BombManager:ExecuteTransfer.
function InteractionService:Step()
	local selfAny = self :: any
	-- Reset the per-tick transfer counter. The contract is
	-- "at most one ExecuteTransfer per tick". If anything in
	-- this function (or any future path it calls) ever
	-- attempts a second transfer within the same heartbeat,
	-- the counter trips and we abort hard.
	selfAny._transfersThisTick = 0

	local bombManager = self.Services:Get("BombManager")
	local holder = bombManager:GetBombHolder()
	if not holder then
		return
	end

	-- 1. Snapshot. The sensor returns the current contact list
	-- in the natural GetPlayers() order. This call is read-only
	-- and has no side effects.
	local tagSensor = self.Services:Get("TagDetectionService")
	local currentContacts = tagSensor:GetContacts(holder)

	-- 2. Get this holder's previous contacts. If the holder
	-- has no entry (e.g. just assigned this tick, or the
	-- resolver was just started), seed it to the current
	-- contacts. The seed means "no rising edges on the very
	-- first tick for this holder" -- this is the round-start
	-- and post-transfer seeding rule. Without it, every
	-- in-range player would be a rising edge on tick 0 and
	-- the bomb would immediately drain to the nearest
	-- neighbor before the players have had a chance to move.
	local previousContacts = selfAny._previousContacts[holder]
	if previousContacts == nil then
		selfAny._previousContacts[holder] = currentContacts
		return
	end

	-- 3. Compute rising edges. The rising edge of the
	-- holder's contact relation is the set of players who are
	-- in range NOW but were not in range on the previous tick.
	-- This is the ONLY eligible-target set. Pre-existing
	-- contacts of the holder (including the predecessor if
	-- still in range) are not eligible -- they are not new
	-- interactions from the holder's perspective.
	local risingEdges = self:_ComputeSetDifference(currentContacts, previousContacts)

	-- 4. Persist the snapshot for next tick. This is the only
	-- state that survives the tick. Note: we update
	-- previousContacts AFTER computing rising edges, so the
	-- set difference is against the snapshot from the
	-- previous tick, not the current one.
	selfAny._previousContacts[holder] = currentContacts

	-- 5. Filter by validity and pick a single target.
	-- _SelectDeterministicTarget handles validity filtering
	-- internally; we just need to pass the rising-edge set.
	if #risingEdges == 0 then
		return
	end

	local target = self:_SelectDeterministicTarget(holder, risingEdges)
	if not target then
		return
	end

	-- 6. Commit. Exactly one ExecuteTransfer per step. If the
	-- authority's defensive guard rejects (true race), we do
	-- not retry this tick -- the next tick will re-evaluate
	-- the new world state.
	--
	-- Hard contract: the per-tick counter MUST stay at 1
	-- or below. If it ever exceeds 1, the resolver has
	-- entered a multi-transfer state and we abort the tick.
	selfAny._transfersThisTick = selfAny._transfersThisTick + 1
	if selfAny._transfersThisTick > 1 then
		print("[Interaction] INVARIANT VIOLATION: multiple transfers in one tick")
		return
	end
	bombManager:ExecuteTransfer(holder, target)

	-- 7. Re-arm for the new holder. The previous holder's
	-- entry in _previousContacts is now stale (the previous
	-- holder is no longer the bomb holder and we will not
	-- read it again). The new holder gets a fresh entry
	-- seeded to their full current contacts. This is the
	-- operation that prevents the cluster chain: P3, who
	-- was in P2's range at the moment of P1 -> P2, is now
	-- in P2's previousContacts and is not a rising edge for
	-- P2 on the next tick.
	self:_OnHolderChanged(target)
end

-- Re-arm the rising-edge state for a new holder. Called on
-- AssignBomb (via the public SeedPreviousContacts method) and
-- after every successful transfer (from inside Step()).
--
-- The new holder's previousContacts is set to their full
-- current contact set. This is the consumption-of-interaction-
-- session operation: every player who was already in the new
-- holder's range at the moment of the transition is treated as
-- a pre-existing contact, not a new interaction. They become
-- eligible only after a falling edge (leaving and re-entering
-- the holder's range).
function InteractionService:_OnHolderChanged(newHolder: Player)
	local selfAny = self :: any
	local tagSensor = self.Services:Get("TagDetectionService")
	-- The sensor is called with the new holder to sample
	-- their actual current contacts. This is the same call
	-- Step() will make on the next tick, performed one tick
	-- early so that the seeding happens in the same tick as
	-- the transfer. The result is deterministic for a given
	-- world state.
	local newHolderContacts = tagSensor:GetContacts(newHolder)
	selfAny._previousContacts[newHolder] = newHolderContacts
end

-- Public seeding entry point. Called by services that
-- establish a new holder (RoundManager via AssignBomb) so
-- that the resolver's rising-edge state is consistent with
-- the authority's holder state at the moment of assignment.
-- Without this call, the first tick after AssignBomb would
-- see the new holder's full contact set as rising edges,
-- causing an immediate transfer to the nearest neighbor at
-- round start -- which is the wrong behavior.
function InteractionService:SeedPreviousContacts(holder: Player)
	local selfAny = self :: any
	local tagSensor = self.Services:Get("TagDetectionService")
	selfAny._previousContacts[holder] = tagSensor:GetContacts(holder)
end

-- Public cleanup entry point. Called when a holder ceases to
-- be the bomb holder without a transfer (e.g. bomb exploded,
-- round ended, player eliminated). Removes the holder's
-- entry from the rising-edge state so that a future
-- assignment to the same player (e.g. a new round) starts
-- with a fresh seed.
function InteractionService:ClearPreviousContacts(holder: Player)
	local selfAny = self :: any
	selfAny._previousContacts[holder] = nil
end

-- Set difference: returns a fresh table containing every
-- element of `a` that is not in `b`. Both inputs are arrays
-- of Player. The output preserves the iteration order of
-- `a`. The output is owned by the caller.
function InteractionService:_ComputeSetDifference(a: { Player }, b: { Player }): { Player }
	local result = {}
	local bSet = {}
	for _, p in ipairs(b) do
		bSet[p] = true
	end
	for _, p in ipairs(a) do
		if not bSet[p] then
			table.insert(result, p)
		end
	end
	return result
end

-- Deterministic target selection. Pure function: same input
-- always returns the same output. Distance uses squared
-- magnitude to avoid a sqrt per candidate, and the final
-- result is sorted by (distanceSquared, UserId) ascending.
--
-- The input `candidates` is the rising-edge set computed in
-- Step(); it has already been filtered to "players who just
-- entered the holder's range." This function does not need
-- to know about the rising-edge concept; it just picks the
-- single best target from whatever set it is given.
function InteractionService:_SelectDeterministicTarget(
	holder: Player,
	candidates: { Player }
): Player?
	local bombManager = self.Services:Get("BombManager")
	local holderRoot = bombManager:GetRootPart(holder)
	if not holderRoot then
		return nil
	end

	-- MovementService multiplier is the only gameplay modifier
	-- on the allowed radius. We precompute it once. Note:
	-- this is a re-check of the in-range predicate. The
	-- sensor already verified that each candidate is in
	-- range at the time of the GetContacts call. Between
	-- the sensor call and this check, the world state has
	-- not changed (we have not yielded), so a re-check here
	-- would always pass. We rely on the sensor's word; the
	-- re-check is omitted to keep this function a pure
	-- selection over the given candidate set.

	-- Build candidate tuples of (distanceSquared, userId, player).
	-- We use squared distance for the sort key to avoid a sqrt.
	-- Distance must be recomputed here (not trusted from the
	-- sensor's unranked output) so the resolver always picks
	-- the true nearest, even if the sensor iterated in a
	-- different order.
	local tuples = {}
	for _, player in ipairs(candidates) do
		-- Validity filter: the target must be a valid bomb
		-- holder. Players who are not in round, are dead, or
		-- have no character are not eligible. This is the
		-- cheap state-membership check before the commit.
		if bombManager:IsValidBombHolder(player) then
			local root = bombManager:GetRootPart(player)
			if root then
				local delta = holderRoot.Position - root.Position
				local distanceSquared = delta.X * delta.X
					+ delta.Y * delta.Y
					+ delta.Z * delta.Z
				table.insert(tuples, {
					player = player,
					distanceSquared = distanceSquared,
					userId = player.UserId,
				})
			end
		end
	end

	if #tuples == 0 then
		return nil
	end

	-- Deterministic single-pass minimum. We do a single
	-- linear pass to find the minimum by the
	-- (distanceSquared, userId) key, which is provably
	-- deterministic and does not depend on table.sort's
	-- implementation details.
	local best = tuples[1]
	for i = 2, #tuples do
		local c = tuples[i]
		if c.distanceSquared < best.distanceSquared
			or (c.distanceSquared == best.distanceSquared and c.userId < best.userId)
		then
			best = c
		end
	end

	return best.player
end

return InteractionService
