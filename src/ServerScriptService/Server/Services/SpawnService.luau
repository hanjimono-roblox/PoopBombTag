--!strict
--[[
	SpawnService (Server)
	Isolated spawn logic for all player states.

	Responsibilities:
	  * Spawn players in the lobby when they first join
	  * Spawn players in the lobby after round reset
	  * Spawn spectators in the spectator area
	  * Handle character respawn cleanup

	This service MUST NOT:
	  * Determine who should be spawned where (defer to callers)
	  * Control round state
	  * Manage player state

	All spawn decisions are made by the caller. SpawnService just
	executes the teleport/spawn action.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local SpawnService = {}
SpawnService.__index = SpawnService
setmetatable(SpawnService, { __index = BaseService })

-- Default lobby spawn CFrames. Used as fallback when the lobby map
-- doesn't have explicit spawn locations.
local DEFAULT_LOBBY_POSITIONS = {
	CFrame.new(-30, 15, -30),
	CFrame.new(-20, 15, -30),
	CFrame.new(-10, 15, -30),
	CFrame.new(0, 15, -30),
	CFrame.new(10, 15, -30),
	CFrame.new(20, 15, -30),
	CFrame.new(30, 15, -30),
	CFrame.new(-30, 15, 0),
	CFrame.new(30, 15, 0),
}

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

function SpawnService.new()
	local self: any = BaseService.new("SpawnService")
	return setmetatable(self, SpawnService)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Spawns a single player in the lobby. Used when a player joins the
-- server or when all players are returned to lobby after a round.
function SpawnService:SpawnInLobby(player: Player): boolean
	local spawnPoint = self:_GetLobbySpawnPoint(player)
	if not spawnPoint then
		-- Fallback: use the default lobby spawn part or Roblox spawn.
		spawnPoint = self:_GetDefaultLobbyCFrame()
	end

	return self:_TeleportPlayer(player, spawnPoint)
end

-- Spawns all given players in the lobby. Each player gets a unique
-- spawn point when possible.
function SpawnService:SpawnAllInLobby(players: { Player })
	local lobbySpawns = self:_GetAllLobbySpawnPoints()
	local spawnIndex = 1

	for _, player in ipairs(players) do
		local spawnPoint: CFrame?
		if #lobbySpawns > 0 then
			spawnPoint = lobbySpawns[((spawnIndex - 1) % #lobbySpawns) + 1]
			spawnIndex = spawnIndex + 1
		end
		if not spawnPoint then
			spawnPoint = self:_GetDefaultLobbyCFrame()
		end
		self:_TeleportPlayer(player, spawnPoint)
	end
end

-- Spawns a player at a specific position in the arena. Used for
-- spectators who need to be placed in a viewing area.
function SpawnService:SpawnSpectator(player: Player): boolean
	local spectatorSpawns = self:_GetSpectatorSpawnPoints()
	local spawnPoint: CFrame?

	if #spectatorSpawns > 0 then
		-- Deterministic spawn: use UserId to pick a consistent spot.
		local index = (player.UserId % #spectatorSpawns) + 1
		spawnPoint = spectatorSpawns[index]
	else
		-- Fallback: spawn at the lobby overview position.
		spawnPoint = self:_GetDefaultLobbyCFrame()
	end

	return self:_TeleportPlayer(player, spawnPoint)
end

-- Spawns a player in the arena at a random arena spawn point.
-- Used by the round system for active participants at round start.
-- Note: under the arena-driven model, players are already in the
-- arena before the round starts. This method exists for admin
-- commands and edge cases (e.g., map reloading).
function SpawnService:SpawnInArena(player: Player): boolean
	local arenaSpawns = self:_GetArenaSpawnPoints()
	if #arenaSpawns == 0 then
		return false
	end

	local spawnPoint = arenaSpawns[math.random(1, #arenaSpawns)]
	return self:_TeleportPlayer(player, spawnPoint)
end

-- Teleports all active participants to arena spawn points. Used
-- at round start to distribute players across the map.
function SpawnService:DistributeParticipantsInArena(players: { Player })
	local arenaSpawns = self:_GetArenaSpawnPoints()
	if #arenaSpawns == 0 then
		return
	end

	for index, player in ipairs(players) do
		local spawnPoint = arenaSpawns[((index - 1) % #arenaSpawns) + 1]
		self:_TeleportPlayer(player, spawnPoint.CFrame + Vector3.new(0, 3, 0))
	end
end

-- ---------------------------------------------------------------------------
-- Spawn Point Discovery
-- ---------------------------------------------------------------------------

-- Returns the lobby spawn CFrame for a specific player.
-- Uses lobby spawn parts if available, otherwise falls back to defaults.
function SpawnService:_GetLobbySpawnPoint(_player: Player): CFrame?
	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then
		local spawnsFolder = lobby:FindFirstChild("Spawns")
		if spawnsFolder then
			local spawnParts = self:_CollectBaseParts(spawnsFolder)
			if #spawnParts > 0 then
				return spawnParts[math.random(1, #spawnParts)].CFrame + Vector3.new(0, 3, 0)
			end
		end
	end

	-- Check for a dedicated LobbySpawn part.
	local lobbySpawn = Workspace:FindFirstChild(GameConfig.Maps.LobbySpawnName, true)
	if lobbySpawn and lobbySpawn:IsA("BasePart") then
		return lobbySpawn.CFrame + Vector3.new(0, 3, 0)
	end

	return nil
end

-- Returns all lobby spawn CFrames.
function SpawnService:_GetAllLobbySpawnPoints(): { CFrame }
	local spawns: { CFrame } = {}

	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then
		local spawnsFolder = lobby:FindFirstChild("Spawns")
		if spawnsFolder then
			for _, part in ipairs(self:_CollectBaseParts(spawnsFolder)) do
				table.insert(spawns, part.CFrame + Vector3.new(0, 3, 0))
			end
		end
	end

	-- Also check for individual lobby spawn parts.
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("BasePart") and child.Name:find("LobbySpawn") == 1 then
			table.insert(spawns, child.CFrame + Vector3.new(0, 3, 0))
		end
	end

	return spawns
end

-- Returns all spectator spawn CFrames from the active map or lobby.
function SpawnService:_GetSpectatorSpawnPoints(): { CFrame }
	local spawns: { CFrame } = {}

	-- Check the lobby for spectator/overview spawns.
	local lobby = Workspace:FindFirstChild("Lobby")
	if lobby then
		local spectatorFolder = lobby:FindFirstChild("SpectatorSpawns")
		if spectatorFolder then
			for _, part in ipairs(self:_CollectBaseParts(spectatorFolder)) do
				table.insert(spawns, part.CFrame + Vector3.new(0, 3, 0))
			end
		end
	end

	-- Fallback: use lobby spawns.
	if #spawns == 0 then
		spawns = self:_GetAllLobbySpawnPoints()
	end

	return spawns
end

-- Returns all arena spawn CFrames from the active map.
function SpawnService:_GetArenaSpawnPoints(): { CFrame }
	local spawns: { CFrame } = {}

	local activeMap = Workspace:FindFirstChild(GameConfig.Maps.ActiveMapParentName)
	if activeMap then
		local spawnFolder = activeMap:FindFirstChild(GameConfig.Maps.RoundSpawnFolderName, true)
		if spawnFolder then
			for _, part in ipairs(self:_CollectBaseParts(spawnFolder)) do
				table.insert(spawns, part.CFrame + Vector3.new(0, 3, 0))
			end
		end
	end

	return spawns
end

-- Default lobby CFrame fallback. Distributes players across a line
-- of positions. Uses a deterministic offset based on player count.
function SpawnService:_GetDefaultLobbyCFrame(): CFrame
	local lobbyPlayerCount = #Players:GetPlayers()
	local index = (lobbyPlayerCount % #DEFAULT_LOBBY_POSITIONS) + 1
	return DEFAULT_LOBBY_POSITIONS[index]
end

-- Collects all BasePart children from an instance.
function SpawnService:_CollectBaseParts(parent: Instance): { BasePart }
	local parts: { BasePart } = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(parts, child)
		end
	end
	return parts
end

-- ---------------------------------------------------------------------------
-- Teleport
-- ---------------------------------------------------------------------------

-- Teleports a player to the given CFrame. Waits for the character
-- to exist, loads it if needed.
function SpawnService:_TeleportPlayer(player: Player, targetCFrame: CFrame): boolean
	if not player or not player.Parent then
		return false
	end

	-- Load character if needed.
	local character = player.Character
	if not character then
		player:LoadCharacter()
		-- Wait briefly for the character to spawn before teleporting.
		-- We use a short task.wait so the character has time to replicate.
		task.wait(0.1)
		character = player.Character
	end

	if not character then
		return false
	end

	-- Find the HumanoidRootPart for PivotTo.
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	character:PivotTo(targetCFrame)
	return true
end

return SpawnService