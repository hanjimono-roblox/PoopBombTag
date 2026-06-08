--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

type Profile = {
	Coins: number,
	OwnedItems: { [string]: boolean },
	EquippedItems: { [string]: string },
}

local DataManager = {}
DataManager.__index = DataManager
setmetatable(DataManager, { __index = BaseService })

function DataManager.new()
	local self: any = BaseService.new("DataManager")
	self._profiles = {} :: { [Player]: Profile }
	self._autosaveThread = nil :: thread?
	return setmetatable(self, DataManager)
end

function DataManager:Start()
	BaseService.Start(self)

	Players.PlayerRemoving:Connect(function(player)
		self:SaveProfile(player)
		local selfAny = self :: any
		selfAny._profiles[player] = nil
	end)

	local selfAny = self :: any
	selfAny._autosaveThread = task.spawn(function()
		while true do
			task.wait(GameConfig.Data.AutosaveIntervalSeconds)
			for _, player in ipairs(Players:GetPlayers()) do
				self:SaveProfile(player)
			end
		end
	end)
end

function DataManager:LoadProfile(player: Player): Profile
	local profile = {
		Coins = 0,
		OwnedItems = {},
		EquippedItems = {},
	}

	-- TODO: Replace stub with ProfileService/DataStore-backed loading and reconciliation.
	local selfAny = self :: any
	selfAny._profiles[player] = profile
	EventManager:Fire(EventNames.DataLoaded, player, profile)
	return profile
end

function DataManager:GetProfile(player: Player): Profile?
	local selfAny = self :: any
	return selfAny._profiles[player]
end

function DataManager:SaveProfile(player: Player)
	local profile = self:GetProfile(player)
	if not profile then
		return
	end

	-- TODO: Persist through DataStore with retry, session lock, and shutdown save handling.
	EventManager:Fire(EventNames.DataSaved, player, profile)
end

return DataManager
