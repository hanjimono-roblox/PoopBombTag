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

function CurrencyManager:AddPoop(player: Player, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false
	end

	state.Poop += math.floor(amount)
	local dataManager = self.Services:Get("DataManager")
	local profile = dataManager:GetProfile(player)
	if profile then
		profile.Poop = state.Poop
		-- Mark the profile dirty so the autosave loop knows there's
		-- a pending write. PlayerRemoving still does a final save
		-- regardless of the dirty flag, so this is purely a
		-- performance hint to avoid redundant UpdateAsync calls.
		dataManager:MarkDirty(player)
	end

	self:SyncLeaderstats(player, state.Poop)
	EventManager:Fire(EventNames.PoopAwarded, player, amount)
	return true
end

function CurrencyManager:RemovePoop(player: Player, amount: number): boolean
	if amount <= 0 or not self:CanAfford(player, amount) then
		return false
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	state.Poop -= math.floor(amount)

	local dataManager = self.Services:Get("DataManager")
	local profile = dataManager:GetProfile(player)
	if profile then
		profile.Poop = state.Poop
		dataManager:MarkDirty(player)
	end

	self:SyncLeaderstats(player, state.Poop)
	return true
end

-- Pushes the authoritative `Poop` value onto the player's leaderstats
-- IntValue so the in-game leaderboard reflects state changes from any
-- source (admin commands, round rewards, store purchases, etc.).
function CurrencyManager:SyncLeaderstats(player: Player, amount: number)
	if not player or not player.Parent then
		return
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end

	local poopValue = leaderstats:FindFirstChild("Poop")
	if poopValue and poopValue:IsA("IntValue") then
		poopValue.Value = math.max(0, math.floor(amount))
	end
end

function CurrencyManager:CanAfford(player: Player, amount: number): boolean
	local state = self.Services:Get("PlayerManager"):GetState(player)
	return state ~= nil and state.Poop >= amount
end

return CurrencyManager
