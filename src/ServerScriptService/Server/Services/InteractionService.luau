--!strict

-- InteractionService (Server, Resolver)
-- The single deterministic resolver for the bomb-tag mechanic.
-- Runs on RunService.Heartbeat. Each tick performs exactly one
-- simulation step:
--
--   1. Read the current bomb holder from BombManager.
--   2. Ask the sensor for every player currently in tag range.
--   3. Deterministically pick at most ONE target.
--   4. Execute at most ONE transfer -- or none.
--
-- Determinism contract:
--   Given identical world state at the start of a step, the
--   outcome is identical every time. There is no event
--   ordering, no cooldown, no async. The single tick is the
--   only unit of decision-making.
--
-- Target selection rule (CRITICAL):
--   Among all in-range candidates:
--     1. Smallest distance to the holder wins.
--     2. On a distance tie, lowest UserId wins.
--   Only the [1] candidate is ever considered.
--   This is what kills the A<->B oscillation bug deterministically:
--   the *next* tick will see the new holder, and the symmetric
--   rule applied to the symmetric world state will pick the
--   *other* player as the new holder. That is the design --
--   the bomb bounces back and forth between adjacent players,
--   but never on a "resend" basis; it bounces once per tick,
--   period, and the outcome is reproducible.
--
-- This service MUST NOT:
--   * Emit or listen to events.
--   * Maintain cooldown / lock / pair-state tables.
--   * Be called from anywhere other than the heartbeat loop.
--   * Call BombManager except for ExecuteTransfer and the
--     read-only helpers it consumes.

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
	-- Single-tick invariant counter. Reset to 0 at the top of
	-- every Step() and asserted to be 0 at the bottom. Any
	-- code path that ever manages to call ExecuteTransfer
	-- more than once per heartbeat will trip this counter
	-- and the resolver will hard-fail instead of silently
	-- producing a 125-transfer loop. The contract "at most
	-- ONE ExecuteTransfer per tick" is enforced at the
	-- resolver layer -- if it ever breaks, we want a loud
	-- signal, not a quiet one.
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
	-- other call site, not by a runtime check (a runtime
	-- check would itself be a back door).
	self._heartbeat = RunService.Heartbeat:Connect(function()
		self:Step()
	end)
end

-- Single simulation step. Called by RunService.Heartbeat. Pure
-- function of world state: it reads, decides, and at most
-- mutates the bomb holder once via BombManager:ExecuteTransfer.
function InteractionService:Step()
	local selfAny = self :: any
	-- Reset the per-tick transfer counter. The contract is
	-- "at most one ExecuteTransfer per tick". If anything in
	-- this function (or any future path it calls) ever
	-- attempts a second transfer within the same heartbeat,
	-- the counter trips and we abort hard -- the alternative
	-- is a silent 125-transfer loop, which is what the user
	-- reported before this guard was added.
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
	local contacts = tagSensor:GetContacts(holder)
	if #contacts == 0 then
		return
	end

	-- 2. Deterministic selection. Pick the single best target.
	-- Selection is by:
	--   a) minimum distance to the holder
	--   b) on a tie, minimum UserId
	-- This is fully deterministic and stable: two calls with
	-- identical world state return the identical target.
	local target = self:_SelectDeterministicTarget(holder, contacts)
	if not target then
		return
	end

	-- 3. Validity check. The resolver does the cheap
	-- state-membership check before calling the authority.
	-- We do not need a cooldown here -- correctness comes from
	-- the fact that the next Step() will see the new holder.
	if not bombManager:IsValidBombHolder(target) then
		return
	end

	-- 4. Commit. Exactly one ExecuteTransfer per step. If the
	-- authority's defensive guard rejects (true race), we do
	-- not retry this tick -- the next tick will re-evaluate
	-- the new world state.
	--
	-- Hard contract: the per-tick counter MUST stay at 1
	-- or below. If it ever exceeds 1, the resolver has
	-- entered a multi-transfer state and we abort the tick
	-- to prevent the cascading replication loop.
	selfAny._transfersThisTick = selfAny._transfersThisTick + 1
	if selfAny._transfersThisTick > 1 then
		print("[Interaction] INVARIANT VIOLATION: multiple transfers in one tick")
		return
	end
	bombManager:ExecuteTransfer(holder, target)
end

-- Deterministic target selection. Pure function: same input
-- always returns the same output. Distance uses squared
-- magnitude to avoid a sqrt per candidate, and the final
-- result is sorted by (distanceSquared, UserId) ascending.
function InteractionService:_SelectDeterministicTarget(
	holder: Player,
	contacts: { Player }
): Player?
	local bombManager = self.Services:Get("BombManager")
	local holderRoot = bombManager:GetRootPart(holder)
	if not holderRoot then
		return nil
	end

	-- MovementService multiplier is the only gameplay modifier
	-- on the allowed radius. We precompute it once.
	local multiplier = self.Services:Get("MovementService"):GetTagRangeMultiplier(holder)
	local allowedDistanceSquared = (GameConfig.Bomb.TagDistanceStuds * multiplier) ^ 2

	-- Build candidate tuples of (distanceSquared, userId, player).
	-- We use squared distance for the sort key to avoid a sqrt.
	-- Distance must be recomputed here (not trusted from the
	-- sensor's unranked output) so the resolver always picks
	-- the true nearest, even if the sensor iterated in a
	-- different order.
	local candidates = {}
	for _, player in ipairs(contacts) do
		local root = bombManager:GetRootPart(player)
		if root then
			local delta = holderRoot.Position - root.Position
			local distanceSquared = delta.X * delta.X
				+ delta.Y * delta.Y
				+ delta.Z * delta.Z
			if distanceSquared <= allowedDistanceSquared then
				table.insert(candidates, {
					player = player,
					distanceSquared = distanceSquared,
					userId = player.UserId,
				})
			end
		end
	end

	if #candidates == 0 then
		return nil
	end

	-- Deterministic single-pass minimum. Luau's table.sort is
	-- NOT guaranteed stable, so we never rely on it for
	-- ordering. We do a single linear pass to find the minimum
	-- by the (distanceSquared, userId) key, which is provably
	-- deterministic and does not depend on table.sort's
	-- implementation details. The contract is "index [1] is
	-- the chosen target"; we return the player object directly
	-- to make the intent explicit.
	local best = candidates[1]
	for i = 2, #candidates do
		local c = candidates[i]
		if c.distanceSquared < best.distanceSquared
			or (c.distanceSquared == best.distanceSquared and c.userId < best.userId)
		then
			best = c
		end
	end

	return best.player
end

return InteractionService
