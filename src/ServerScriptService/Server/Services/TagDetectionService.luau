--!strict

-- TagDetectionService (Server, Sensor)
-- Pure physics snapshot. The only public API is a single
-- read-only function: get the list of players currently in tag
-- range of a given holder. No events, no state, no cooldowns,
-- no decisions.
--
-- Determinism contract:
--   * Two calls with the same world state and the same holder
--     return the same list of players.
--   * The list order is stable: it is the iteration order of
--     Players:GetPlayers() filtered to in-range candidates. The
--     resolver layer applies its own deterministic ordering on
--     top of this list.
--
-- This service MUST NOT:
--   * Emit events.
--   * Maintain cooldown / lock / edge state.
--   * Rank or select targets (no "nearest", no ordering beyond
--     the natural GetPlayers() order).
--   * Call BombManager or any mutator.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local TagDetectionService = {}
TagDetectionService.__index = TagDetectionService
setmetatable(TagDetectionService, { __index = BaseService })

function TagDetectionService.new()
	local self: any = BaseService.new("TagDetectionService")
	return setmetatable(self, TagDetectionService)
end

-- Public API. Returns a fresh table of every Player that is
-- currently in tag range of `holder`. The result is owned by
-- the caller; the sensor holds no reference to it.
--
-- Does NOT exclude the holder.
-- Does NOT validate that the holder or contacts are "alive" or
-- "in round" -- that is the resolver's job.
-- Does NOT exclude the holder itself if the holder somehow
-- appears in Players:GetPlayers() with itself (it is filtered
-- out as a defense-in-depth check, but under normal Roblox
-- semantics a player never lists themselves).
function TagDetectionService:GetContacts(holder: Player): { Player }
	local bombManager = self.Services:Get("BombManager")
	local holderRoot = bombManager:GetRootPart(holder)
	if not holderRoot then
		return {}
	end

	local maxRange = GameConfig.Bomb.TagDistanceStuds
	local contacts = {}

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= holder and other.Parent then
			local otherRoot = bombManager:GetRootPart(other)
			if otherRoot then
				local distance = (holderRoot.Position - otherRoot.Position).Magnitude
				if distance <= maxRange then
					table.insert(contacts, other)
				end
			end
		end
	end

	return contacts
end

return TagDetectionService
