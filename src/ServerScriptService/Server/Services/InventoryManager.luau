--!strict

local BaseService = require(script.Parent.Parent.Framework.BaseService)

local InventoryManager = {}
InventoryManager.__index = InventoryManager
setmetatable(InventoryManager, { __index = BaseService })

function InventoryManager.new()
	return setmetatable(BaseService.new("InventoryManager"), InventoryManager)
end

function InventoryManager:GrantItem(player: Player, itemId: string): boolean
	assert(type(itemId) == "string" and itemId ~= "", "itemId is required")

	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state then
		return false
	end

	state.OwnedItems[itemId] = true
	return true
end

function InventoryManager:EquipItem(player: Player, itemId: string): boolean
	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state or not state.OwnedItems[itemId] then
		return false
	end

	-- TODO: Route item type through a catalog so slots are data-driven.
	state.EquippedItems.Cosmetic = itemId
	return true
end

return InventoryManager
