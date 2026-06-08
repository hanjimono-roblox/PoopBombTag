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
	return setmetatable(self, MapManager)
end

function MapManager:SelectRandomMap(): string
	local mapsFolder = ServerStorage:FindFirstChild("Maps")
	if not mapsFolder then
		return GameConfig.Maps.DefaultMapName
	end

	local maps = mapsFolder:GetChildren()
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

function MapManager:BeginMapVote()
	-- TODO: Publish voting options through remotes and collect server-validated votes.
end

return MapManager
