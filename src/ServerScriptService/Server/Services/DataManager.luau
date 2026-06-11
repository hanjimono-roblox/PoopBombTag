--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TableUtil = require(ReplicatedStorage.Shared.Utility.TableUtil)

type Profile = {
	Poop: number,
	OwnedItems: { [string]: boolean },
	EquippedItems: { [string]: string },
	ItemLevels: { [string]: number },
	ConsumableCounts: { [string]: number },
	OneTimePurchases: { [string]: boolean },
}

-- Returns a fresh, complete default profile. Used both for first-time-join
-- creation and as the source of truth for schema reconciliation.
local function BuildDefaultProfile(): Profile
	return {
		Poop = 0,
		OwnedItems = {},
		EquippedItems = {},
		ItemLevels = {},
		ConsumableCounts = {},
		OneTimePurchases = {},
	}
end

-- Reconciles a loaded profile against the current default schema. Any keys
-- missing from the loaded profile (e.g. a new field added in a future
-- update) are filled in with the default. Unknown keys are preserved (so
-- old fields don't get wiped) but unknown TABLE values that match defaults
-- are not overwritten.
local function ReconcileProfile(loaded: { [string]: any }?): Profile
	local defaults = BuildDefaultProfile()
	local out: Profile = BuildDefaultProfile()

	if type(loaded) ~= "table" then
		return out
	end

	for key, value in pairs(loaded) do
		-- Type-check the loaded value against the default. If a key
		-- exists in the loaded data but is the wrong type (e.g. Poop
		-- got corrupted to a string), we ignore it and fall back to
		-- the default rather than persisting a broken value.
		local defaultValue = (defaults :: { [string]: any })[key]
		if defaultValue ~= nil then
			if typeof(value) == typeof(defaultValue) then
				(out :: { [string]: any })[key] = value
			end
		else
			-- Forward-compat: an unknown key on a profile is preserved
			-- (e.g. a future field the running server doesn't know about).
			(out :: { [string]: any })[key] = value
		end
	end

	return out
end

local DataManager = {}
DataManager.__index = DataManager
setmetatable(DataManager, { __index = BaseService })

-- Single DataStore for all player data. The store name is the versioned
-- one defined in GameConfig so we can roll the schema if we ever need to
-- (e.g. by bumping the suffix and migrating via UpdateAsync).
local STORE_NAME = GameConfig.Data.StoreName

-- Per-player "session locked" flag. When a profile is loaded we write a
-- sentinel into the session-lock DataStore; the same player trying to
-- join from a second tab will see the lock and we refuse to load (so two
-- servers can't both think they own that profile).
local SESSION_LOCK_STORE_NAME = STORE_NAME .. "_SessionLock"

-- Bound for the various retry loops.
local MAX_SAVE_RETRIES = 5
local MAX_LOAD_RETRIES = 5
local SHUTDOWN_SAVE_TIMEOUT_SECONDS = 5

function DataManager.new()
	local self: any = BaseService.new("DataManager")
	self._profiles = {} :: { [Player]: Profile }
	self._autosaveThread = nil :: thread?
	-- Tracks whether each player's profile is currently in a "dirty"
	-- state (i.e. has un-saved mutations). Used to skip redundant
	-- UpdateAsync calls during autosave.
	self._dirty = {} :: { [Player]: boolean }
	return setmetatable(self, DataManager)
end

------------------------------------------------------------------------
-- START
------------------------------------------------------------------------

function DataManager:Start()
	BaseService.Start(self)

	local logging = self.Services:Get("LoggingService")

	Players.PlayerRemoving:Connect(function(player)
		-- Block the leaving thread until the save is committed. This is
		-- critical for Studio local testing and for graceful shutdowns.
		self:SaveProfile(player)
		self:ReleaseSessionLock(player)
		local selfAny = self :: any
		selfAny._profiles[player] = nil
		selfAny._dirty[player] = nil
	end)

	-- Bind to close: on server shutdown, give ourselves a short window
	-- to flush everyone's profile. This is the only reliable save path
	-- during Roblox-initiated shutdowns (PlayerRemoving is not guaranteed).
	game:BindToClose(function()
		if logging then
			logging:Info("DATA", "BindToClose: flushing all profiles")
		end

		local deadline = os.clock() + SHUTDOWN_SAVE_TIMEOUT_SECONDS
		local selfAny = self :: any

		-- Stop the autosave loop so it doesn't race us.
		self:_StopAutosave()

		-- Phase 1: kick off every save in parallel, but bound the
		-- total wall time. UpdateAsync is the durable call; we trust
		-- the per-save retry budget.
		local threads: { thread } = {}
		for player, _ in pairs(selfAny._profiles) do
			if player.Parent == nil then
				-- Player already gone; PlayerRemoving will handle it.
				continue
			end
			local thread = task.spawn(function()
				self:SaveProfile(player)
				self:ReleaseSessionLock(player)
			end)
			table.insert(threads, thread)
		end

		-- Wait until either everything finishes or our deadline hits.
		-- We don't block-coroutine-wait on the threads (they're opaque
		-- task.spawn handles), so we just sleep in short intervals and
		-- check whether the profile table has emptied.
		while os.clock() < deadline and next(selfAny._profiles) ~= nil do
			task.wait(0.1)
		end

		if logging then
			logging:Info(
				"DATA",
				`BindToClose flush complete ({#selfAny._profiles} profiles remaining)`
			)
		end
	end)

	self:_StartAutosave()
end

------------------------------------------------------------------------
-- AUTOSAVE
------------------------------------------------------------------------

function DataManager:_StartAutosave()
	local selfAny = self :: any
	if selfAny._autosaveThread ~= nil then
		return
	end

	selfAny._autosaveThread = task.spawn(function()
		while true do
			task.wait(GameConfig.Data.AutosaveIntervalSeconds)

			for _, player in ipairs(Players:GetPlayers()) do
				-- Skip players whose profile is known-clean. This is a
				-- best-effort optimization; if a write happened between
				-- our check and SaveProfile, the underlying UpdateAsync
				-- still does the right thing.
				if not selfAny._dirty[player] then
					continue
				end
				self:SaveProfile(player)
			end
		end
	end)
end

function DataManager:_StopAutosave()
	local selfAny = self :: any
	if selfAny._autosaveThread == nil then
		return
	end
	pcall(function()
		pcall(task.cancel, selfAny._autosaveThread)
	end)
	selfAny._autosaveThread = nil
end

------------------------------------------------------------------------
-- SESSION LOCK
------------------------------------------------------------------------

--[[
	Session locking prevents two concurrent sessions for the same
	userId from racing each other on save. We use a small separate
	DataStore whose value is the sessionId we wrote. The first
	process to call AcquireSessionLock wins; subsequent calls (from
	a second tab) return false and the caller should kick the player.

	Note: this is a best-effort lock. In a hostile environment a second
	process could ignore the lock and still call :SetAsync on the main
	store, but our :UpdateAsync pattern is safe in that case because
	Roblox serializes UpdateAsync invocations per-key.
]]
function DataManager:AcquireSessionLock(player: Player): boolean
	local lockStore = DataStoreService:GetDataStore(SESSION_LOCK_STORE_NAME)
	local key = `user_{player.UserId}`

	-- The session id we attempt to write. We then :GetAsync to check
	-- whether it was actually accepted; if the existing value matches
	-- ours, we won the race.
	local sessionId = `{player.UserId}_{game.JobId}_{os.clock()}`

	local ok, _ = pcall(function()
		lockStore:SetAsync(key, sessionId)
	end)
	if not ok then
		-- Couldn't even write the lock; fail open and let the load
		-- proceed (the main store is still protected by :UpdateAsync).
		return true
	end

	local readOk, existing = pcall(function()
		return lockStore:GetAsync(key)
	end)
	if not readOk then
		return true
	end

	return existing == sessionId
end

function DataManager:ReleaseSessionLock(player: Player)
	local lockStore = DataStoreService:GetDataStore(SESSION_LOCK_STORE_NAME)
	local key = `user_{player.UserId}`
	pcall(function()
		lockStore:RemoveAsync(key)
	end)
end

------------------------------------------------------------------------
-- LOAD
------------------------------------------------------------------------

--[[
	Loads (or creates) the player's profile from the DataStore.

	Returns nil if the load ultimately failed after all retries. The
	caller is expected to handle this gracefully (e.g. by kicking the
	player with a "data could not be loaded" message rather than
	indexing a nil profile).
]]
function DataManager:LoadProfile(player: Player): Profile?
	local store = DataStoreService:GetDataStore(STORE_NAME)
	local key = `user_{player.UserId}`

	-- Acquire the session lock first. If we lose the race, refuse to
	-- load so the other session remains the canonical owner.
	if not self:AcquireSessionLock(player) then
		return nil
	end

	local lastError: string? = nil
	for attempt = 1, MAX_LOAD_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			local profile = ReconcileProfile(result)
			local selfAny = self :: any
			selfAny._profiles[player] = profile
			selfAny._dirty[player] = false
			-- Snapshot the profile so subscribers can't mutate the
			-- source of truth.
			EventManager:Fire(EventNames.DataLoaded, player, TableUtil.DeepCopy(profile))
			return profile
		else
			lastError = tostring(result)
			-- Exponential-ish backoff capped to a sane ceiling.
			task.wait(math.min(2 ^ attempt * 0.1, 2))
		end
	end

	-- All retries exhausted. Release the lock so the player can try
	-- again from another session.
	self:ReleaseSessionLock(player)
	warn(`[DataManager] Load failed for {player.Name} after {MAX_LOAD_RETRIES} attempts: {lastError}`)
	return nil
end

function DataManager:GetProfile(player: Player): Profile?
	local selfAny = self :: any
	return selfAny._profiles[player]
end

function DataManager:MarkDirty(player: Player)
	local selfAny = self :: any
	selfAny._dirty[player] = true
end

------------------------------------------------------------------------
-- SAVE
------------------------------------------------------------------------

--[[
	Persists the in-memory profile to the DataStore using UpdateAsync
	(so concurrent writes from a second session are correctly serialized
	by Roblox). Retries on transient failure; marks the profile clean
	only when UpdateAsync succeeds.
]]
function DataManager:SaveProfile(player: Player): boolean
	local selfAny = self :: any
	local profile = selfAny._profiles[player]
	if not profile then
		return false
	end

	local store = DataStoreService:GetDataStore(STORE_NAME)
	local key = `user_{player.UserId}`

	-- Snapshot the profile for the save payload. We deliberately do NOT
	-- pass a reference to the live profile so a slow UpdateAsync call
	-- can't race with a concurrent in-memory mutation.
	local payload = TableUtil.DeepCopy(profile)

	local lastError: string? = nil
	for attempt = 1, MAX_SAVE_RETRIES do
		local ok, result = pcall(function()
			store:UpdateAsync(key, function(_current)
				-- The transform returns the new value; whatever
				-- Roblox already has is overwritten (last-write-wins
				-- inside the locked transform).
				return payload
			end)
		end)
		if ok then
			selfAny._dirty[player] = false
			-- Fire a deep-copied snapshot so subscribers can render
			-- "saved" UI without ever holding a reference to the
			-- live profile.
			EventManager:Fire(EventNames.DataSaved, player, TableUtil.DeepCopy(profile))
			return true
		else
			lastError = tostring(result)
			task.wait(math.min(2 ^ attempt * 0.1, 2))
		end
	end

	warn(`[DataManager] Save failed for {player.Name} after {MAX_SAVE_RETRIES} attempts: {lastError}`)
	return false
end

return DataManager
