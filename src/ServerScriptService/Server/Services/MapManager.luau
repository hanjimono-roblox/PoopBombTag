--!strict

local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local MapManager = {}
MapManager.__index = MapManager
setmetatable(MapManager, { __index = BaseService })

function MapManager.new()
	local self: any = BaseService.new("MapManager")
	self._activeMap = nil :: Instance?
	self._lobbyMap = nil :: Instance?
	return setmetatable(self, MapManager)
end

function MapManager:Start()
	BaseService.Start(self)

	-- Load the lobby into the workspace on server start so players
	-- have somewhere to spawn and the ArenaEntryZone is detectable.
	self:LoadLobby()
end

-- Loads the lobby map from ServerStorage into Workspace. The lobby
-- is persistent across rounds and is only unloaded on server shutdown.
-- Players spawn here when they join and are returned here after rounds.
function MapManager:LoadLobby(): Instance?
	local selfAny = self :: any
	if selfAny._lobbyMap and selfAny._lobbyMap.Parent then
		return selfAny._lobbyMap
	end

	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	local lobbySource = mapsFolder and mapsFolder:FindFirstChild("Lobby")
	if not lobbySource then
		self.Services:Get("LoggingService"):Warn("MAP", "Missing lobby map in ServerStorage/Maps/Lobby")
		return nil
	end

	local lobby = lobbySource:Clone()
	lobby.Name = "Lobby"
	lobby.Parent = Workspace
	selfAny._lobbyMap = lobby

	self.Services:Get("LoggingService"):Info("MAP", "Lobby loaded into Workspace")
	return lobby
end

function MapManager:SelectRandomMap(): string
	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	if not mapsFolder then
		return GameConfig.Maps.DefaultMapName
	end

	-- Filter out the Lobby map so it can never be selected as a playable arena.
	local maps = {}
	for _, child in ipairs(mapsFolder:GetChildren()) do
		if child.Name ~= "Lobby" then
			table.insert(maps, child)
		end
	end
	if #maps == 0 then
		return GameConfig.Maps.DefaultMapName
	end

	return maps[math.random(1, #maps)].Name
end

function MapManager:LoadMap(mapName: string?): Instance?
	self:UnloadMap()

	local selectedName = mapName or self:SelectRandomMap()
	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	local source = mapsFolder and mapsFolder:FindFirstChild(selectedName)
	if not source then
		self.Services:Get("LoggingService"):Warn("MAP", `Missing map: {selectedName}`)
		return nil
	end

	local activeMap = source:Clone()
	activeMap.Name = GameConfig.Maps.ActiveMapParentName
	activeMap.Parent = Workspace
	local selfAny = self :: any
	selfAny._activeMap = activeMap

	EventManager:Fire(EventNames.MapLoaded, selectedName, activeMap)
	return activeMap
end

function MapManager:UnloadMap()
	local selfAny = self :: any
	local activeMap = selfAny._activeMap
	if activeMap then
		activeMap:Destroy()
		selfAny._activeMap = nil
		EventManager:Fire(EventNames.MapUnloaded)
	end
end

function MapManager:GetSpawnPoints(): { BasePart }
	local selfAny = self :: any
	local activeMap = selfAny._activeMap
	if not activeMap then
		return {}
	end

	local spawnFolder = activeMap:FindFirstChild(GameConfig.Maps.RoundSpawnFolderName, true)
	if not spawnFolder then
		return {}
	end

	local spawns = {}
	for _, child in ipairs(spawnFolder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(spawns, child)
		end
	end

	return spawns
end

-- Map voting has been moved to MapVoteService.
-- Deprecated. Kept as a no-op for compatibility with any existing callers.
function MapManager:BeginMapVote()
	-- No-op; use MapVoteService:StartVote() instead.
end

return MapManager
