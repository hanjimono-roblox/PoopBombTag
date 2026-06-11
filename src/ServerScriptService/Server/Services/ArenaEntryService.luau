--!strict
--[[
	ArenaEntryService (Server, Sensor)
	Detects when players physically enter the arena from the lobby.

	Uses a server-side Heartbeat-based proximity polling loop that
	compares every Lobby player's HumanoidRootPart.Position against
	the ArenaEntryZone bounding box (discovered from a workspace
	Part/Model named "ArenaEntryZone", or from GameConfig.Arena
	fallback bounds).

	Poll rate: ~10 Hz (every ~0.1 s). Detection is instant on the
	first tick where the player is inside the zone. No confirmation
	delay.

	Why NOT Part.Touched:
	  * Touched requires CanCollide = true on one of the parts,
	    blocking player movement. A trigger zone must be pass-through.
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

local POLL_INTERVAL_SECONDS = 0.1
local STARTUP_DELAY_SECONDS = 1.0

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function ArenaEntryService.new()
	print("[ArenaEntry] Constructing ArenaEntryService")
	local self: any = BaseService.new("ArenaEntryService")
	self._heartbeat = nil :: RBXScriptConnection?
	self._lastPollTime = 0
	self._evaluatedPlayers = {} :: { [Player]: boolean }
	self._zoneRegion = nil :: { Min: Vector3, Max: Vector3 }?
	self._zoneFound = false
	return setmetatable(self, ArenaEntryService)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function ArenaEntryService:Start()
	print("[ArenaEntry] Start() called")
	BaseService.Start(self)

	local selfAny = self :: any

	-- Subscribe to ArenaEntered for diagnostics (our own event, we log it).
	EventManager:Connect(EventNames.ArenaEntered, function(player: Player)
		print(`[ArenaEntry] EVENT CONSUMED: ArenaEntered for {player.Name}`)
		local logging = self.Services:Get("LoggingService")
		if logging then
			logging:Info("ARENA", `{player.Name} entered the arena`)
		end
	end)

	-- Listen for players returning to Lobby so they can re-enter.
	EventManager:Connect(EventNames.PlayerStateChanged, function(
		player: Player,
		newState: string
	)
		print(`[ArenaEntry] State changed: {player.Name} -> {newState}`)
		if newState == "Lobby" then
			print(`[ArenaEntry] Clearing evaluated flag for {player.Name}`)
			selfAny._evaluatedPlayers[player] = nil
		end
	end)

	-- Cache the zone region once at startup (it doesn't move).
	selfAny._zoneFound = false
	self:RefreshZone()

	-- Defer the heartbeat connection so every downstream service
	-- (especially RoundManager) has subscribed to ArenaEntered first.
	print("[ArenaEntry] Scheduling heartbeat startup in 1 second...")
	task.spawn(function()
		task.wait(STARTUP_DELAY_SECONDS)
		print("[ArenaEntry] Deferred startup: connecting heartbeat")

		self:RefreshZone()
		if not selfAny._zoneFound then
			print("[ArenaEntry] WARNING: Still no ArenaEntryZone found after defer!")
			print("[ArenaEntry] Searched in: ActiveMap, Workspace/Lobby, Workspace root")
			print("[ArenaEntry] Falling back to GameConfig.Arena bounds")
		end

		selfAny._heartbeat = RunService.Heartbeat:Connect(function(deltaTime: number)
			self:_OnHeartbeat(math.min(deltaTime or 0.016, 0.5))
		end)
	end)
end

-- ---------------------------------------------------------------------------
-- Zone Discovery
-- ---------------------------------------------------------------------------

function ArenaEntryService:RefreshZone()
	print("[ArenaEntry] Refreshing zone region...")
	local selfAny = self :: any
	selfAny._zoneRegion = self:FindZoneRegion()
	selfAny._zoneFound = selfAny._zoneRegion ~= nil

	if selfAny._zoneFound then
		local r = selfAny._zoneRegion
		print(string.format("[ArenaEntry] Zone found: Min(%s) Max(%s)",
			tostring(r.Min), tostring(r.Max)))
	else
		print("[ArenaEntry] Zone NOT found - will retry on heartbeat")
	end
end

function ArenaEntryService:FindZoneRegion(): { Min: Vector3, Max: Vector3 }?
	print("[ArenaEntry] Searching for ArenaEntryZone instance...")

	-- 1. ActiveMap (arena map, only present during a round)
	local activeMap = Workspace:FindFirstChild(GameConfig.Maps.ActiveMapParentName)
	if activeMap then
		print(`[ArenaEntry] Checking ActiveMap ({activeMap:GetFullName()})...`)
		local zone = activeMap:FindFirstChild("ArenaEntryZone", true)
		if zone then
			print(`[ArenaEntry] Found in ActiveMap: {zone:GetFullName()} ({zone.ClassName})`)
			return self:ComputeZoneBounds(zone)
		end
	end

	-- 2. Lobby map (persistent, cloned by MapManager on server start)
	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then
		print(`[ArenaEntry] Checking Lobby ({lobby:GetFullName()})...`)
		local zone = lobby:FindFirstChild("ArenaEntryZone", true)
		if zone then
			print(`[ArenaEntry] Found in Lobby: {zone:GetFullName()} ({zone.ClassName})`)
			return self:ComputeZoneBounds(zone)
		end
	else
		print("[ArenaEntry] No Lobby found in Workspace")
	end

	-- 3. Anywhere in Workspace
	print("[ArenaEntry] Checking entire Workspace...")
	local zone = Workspace:FindFirstChild("ArenaEntryZone", true)
	if zone then
		print(`[ArenaEntry] Found in Workspace: {zone:GetFullName()} ({zone.ClassName})`)
		return self:ComputeZoneBounds(zone)
	end

	-- 4. Fallback to GameConfig.Arena
	local cfg = GameConfig.Arena
	if cfg and cfg.EntryZoneMin and cfg.EntryZoneMax then
		print("[ArenaEntry] Using GameConfig.Arena fallback bounds")
		return {
			Min = cfg.EntryZoneMin,
			Max = cfg.EntryZoneMax,
		}
	end

	print("[ArenaEntry] No zone source available at all!")
	return nil
end

function ArenaEntryService:ComputeZoneBounds(instance: Instance): { Min: Vector3, Max: Vector3 }?
	local cframe: CFrame
	local size: Vector3

	if instance:IsA("BasePart") then
		print(`[ArenaEntry] ComputeZoneBounds: BasePart, Size={instance.Size}, Position={instance.Position}`)
		cframe = instance.CFrame
		size = instance.Size
	elseif instance:IsA("Model") then
		-- For Models, use the bounding box (GetExtentsSize) and the
		-- model's pivot (GetPivot). These give world-space values.
		local extentsSize = instance:GetExtentsSize()
		local pivot = instance:GetPivot()
		print(`[ArenaEntry] ComputeZoneBounds: Model, ExtentsSize={extentsSize}, PivotPos={pivot.Position}`)

		if extentsSize.Magnitude < 0.01 then
			-- Model is empty or newly cloned without children loaded.
			-- Try the primary part instead.
			local primaryPart = instance.PrimaryPart
			if primaryPart then
				print(`[ArenaEntry] Model extents are zero, using PrimaryPart ({primaryPart.Size}, {primaryPart.Position})`)
				cframe = primaryPart.CFrame
				size = primaryPart.Size
			else
				print("[ArenaEntry] Model has zero extents and no PrimaryPart - cannot compute bounds")
				return nil
			end
		else
			cframe = pivot
			size = extentsSize
		end
	else
		print(`[ArenaEntry] Unsupported instance type: {instance.ClassName}`)
		return nil
	end

	if size.Magnitude < 0.01 then
		print("[ArenaEntry] Zone size is zero - cannot compute bounds")
		return nil
	end

	local halfSize = size / 2
	local min = cframe.Position - halfSize
	local max = cframe.Position + halfSize
	print(string.format("[ArenaEntry] Computed zone: Min(%s) Max(%s)", tostring(min), tostring(max)))
	return { Min = min, Max = max }
end

-- ---------------------------------------------------------------------------
-- Heartbeat Polling Loop
-- ---------------------------------------------------------------------------

function ArenaEntryService:_OnHeartbeat(deltaTime: number)
	local selfAny = self :: any
	selfAny._lastPollTime = selfAny._lastPollTime + deltaTime

	if selfAny._lastPollTime < POLL_INTERVAL_SECONDS then
		return
	end
	selfAny._lastPollTime = 0

	-- If we don't have a zone yet, try refreshing (MapManager might have
	-- loaded the lobby after our first attempt).
	if not selfAny._zoneFound then
		self:RefreshZone()
		if not selfAny._zoneFound then
			-- Still nothing — skip this poll cycle.
			return
		end
	end

	local stateService = self.Services:Get("PlayerStateService")
	if not stateService then
		print("[ArenaEntry] ERROR: PlayerStateService not available")
		return
	end

	local lobbyPlayers = stateService:GetLobbyPlayers()
	if #lobbyPlayers > 0 then
		-- Uncomment for verbose polling diagnostics:
		-- print(`[ArenaEntry] Polling {#lobbyPlayers} Lobby players...`)
	end

	for _, player in ipairs(lobbyPlayers) do
		if selfAny._evaluatedPlayers[player] then
			continue
		end

		local inZone: boolean
		local ok = pcall(function()
			inZone = self:_IsPlayerCharacterInArenaZone(player)
		end)
		if not ok then
			print(`[ArenaEntry] ERROR in zone check for {player.Name}: {tostring(inZone)}`)
			continue
		end

		if inZone then
			print(`[ArenaEntry] DETECTED: {player.Name} is inside the zone`)
			selfAny._evaluatedPlayers[player] = true
			EventManager:Fire(EventNames.ArenaEntered, player)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Zone Detection
-- ---------------------------------------------------------------------------

function ArenaEntryService:_IsPlayerCharacterInArenaZone(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	local selfAny = self :: any
	local zone = selfAny._zoneRegion
	if not zone then
		return false
	end

	local pos = root.Position
	local inside = pos.X >= zone.Min.X
		and pos.X <= zone.Max.X
		and pos.Y >= zone.Min.Y
		and pos.Y <= zone.Max.Y
		and pos.Z >= zone.Min.Z
		and pos.Z <= zone.Max.Z

	return inside
end

return ArenaEntryService