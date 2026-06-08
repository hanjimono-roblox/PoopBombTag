--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)

local CurrencyManager = {}
CurrencyManager.__index = CurrencyManager
setmetatable(CurrencyManager, { __index = BaseService })

function CurrencyManager.new()
	return setmetatable(BaseService.new("CurrencyManager"), CurrencyManager)
end

function CurrencyManager:AddCoins(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false
	end

	state.Coins += math.floor(amount)
	local profile = self.Services:Get("DataManager"):GetProfile(player)
	if profile then
		profile.Coins = state.Coins
	end

	EventManager:Fire(EventNames.CoinsAwarded, player, amount)
	return true
end

function CurrencyManager:RemoveCoins(player: Player, amount: number): boolean
	if amount <= 0 or not self:CanAfford(player, amount) then
		return false
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	state.Coins -= math.floor(amount)

	local profile = self.Services:Get("DataManager"):GetProfile(player)
	if profile then
		profile.Coins = state.Coins
	end

	return true
end

function CurrencyManager:CanAfford(player: Player, amount: number): boolean
	local state = self.Services:Get("PlayerManager"):GetState(player)
	return state ~= nil and state.Coins >= amount
end

return CurrencyManager
