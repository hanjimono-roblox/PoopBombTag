--!strict

-- TagDetectionService (Server)
-- The single authoritative tag-detection system for bomb transfers.
-- Polls all alive round players on a short interval, finds the current
-- bomb holder from BombManager, and checks every other alive player
-- for proximity. When two players are within tag range the service
-- calls BombManager:TryTag() which validates the transfer authoritatively.
--
-- This is the ONLY system that calls TryTag. If you need a different
-- trigger (e.g. an item powerup that forces a tag), expose a method
-- here and keep BombManager as the gatekeeper.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local TagDetectionService = {}
TagDetectionService.__index = TagDetectionService
setmetatable(TagDetectionService, { __index = BaseService })

-- How often (in seconds) the service scans for nearby players.
-- 0.15s feels responsive without burning CPU on a large server.
local SCAN_INTERVAL_SECONDS = 0.15

-- Per-pair debounce window. Even if the holder and target stay inside
-- tag range for several ticks, we only fire TryTag once per this many
-- seconds. BombManager has its own cooldown, but this prevents us from
-- flooding the service with redundant calls each frame.
local PAIR_DEBOUNCE_SECONDS = 0.25

function TagDetectionService.new()
	local self: any = BaseService.new("TagDetectionService")
	self._scanThread = nil :: thread?
	-- _lastAttemptAt[playerA][playerB] = os.clock() of last TryTag call.
	self._lastAttemptAt = {} :: { [Player]: { [Player]: number } }
	return setmetatable(self, TagDetectionService)
end

function TagDetectionService:Start()
	BaseService.Start(self)

	print("[TagDetection] starting scan loop")

	local selfAny = self :: any
	selfAny._scanThread = task.spawn(function()
		while true do
			self:_ScanOnce()
			task.wait(SCAN_INTERVAL_SECONDS)
		end
	end)
end

-- Single pass: find the current bomb holder, then for every other alive
-- round player within GameConfig.Bomb.TagDistanceStuds, call TryTag.
function TagDetectionService:_ScanOnce()
	local bombManager = self.Services:Get("BombManager")
	local holder = bombManager:GetBombHolder()
	if not holder then
		return
	end

	-- Drop debounce entries for players that have left to keep the table small.
	self:_PruneDebounce()

	print("[TagDetection] scanning... holder =", holder and holder.Name)

	-- Use BombManager's own helper so we get the same root-part fallback
	-- path as the rest of the codebase.
	local holderRoot = bombManager:GetRootPart(holder)
	if not holderRoot then
		return
	end

	-- Iterate over all players in the server (not just alive) so the
	-- authoritative validation in BombManager:ValidateTag can reject
	-- spectators / dead players via IsValidBombHolder.
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= holder then
			self:_TryTagPair(holder, other, holderRoot, bombManager)
		end
	end
end

function TagDetectionService:_TryTagPair(
	holder: Player,
	target: Player,
	holderRoot: BasePart,
	bombManager: any
)
	if not target or not target.Parent then
		return
	end

	-- Cheap pre-filter using straight distance against the same config
	-- constant. BombManager:ValidateTag will re-check with the per-player
	-- MovementService multiplier, so this is just a quick reject to
	-- avoid unnecessary method calls / table writes.
	local targetRoot = bombManager:GetRootPart(target)
	if not targetRoot then
		return
	end

	local distance = (holderRoot.Position - targetRoot.Position).Magnitude
	if distance > GameConfig.Bomb.TagDistanceStuds then
		return
	end

	-- Per-pair debounce.
	local now = os.clock()
	if self:_ShouldDebounce(holder, target, now) then
		return
	end
	self:_MarkAttempted(holder, target, now)

	bombManager:TryTag(holder, target)
end

function TagDetectionService:_ShouldDebounce(a: Player, b: Player, now: number): boolean
	local selfAny = self :: any
	local pairTable = selfAny._lastAttemptAt[a]
	if not pairTable then
		return false
	end
	local last = pairTable[b]
	if not last then
		return false
	end
	return (now - last) < PAIR_DEBOUNCE_SECONDS
end

function TagDetectionService:_MarkAttempted(a: Player, b: Player, now: number)
	local selfAny = self :: any
	local pairTable = selfAny._lastAttemptAt[a]
	if not pairTable then
		pairTable = {}
		selfAny._lastAttemptAt[a] = pairTable
	end
	pairTable[b] = now
end

-- Drop debounce rows for players that have left so the table does not
-- grow without bound over a long server lifetime.
function TagDetectionService:_PruneDebounce()
	local selfAny = self :: any
	for player in pairs(selfAny._lastAttemptAt) do
		if not player.Parent then
			selfAny._lastAttemptAt[player] = nil
		end
	end
end

return TagDetectionService
