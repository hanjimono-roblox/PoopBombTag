--!strict
--[[
	InventoryManager (Server)
	Manages all player inventory operations: granting items, equipping/unequipping
	cosmetics, tracking item levels, and managing consumable counts.

	Item category behavior:
	  - OneTime:  Set OwnedItems[id] = true (idempotent, cannot re-purchase)
	  - Cosmetic: Set OwnedItems[id] = true + can be equipped to its Slot
	  - Level:    Increment ItemLevels[id] (capped at MaxLevel)
	  - Consumable: Increment ConsumableCounts[id] (capped at MaxStack)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
type ItemDefinition = ItemTypes.ItemDefinition
type ItemCategory = ItemTypes.ItemCategory
type ItemSlot = ItemTypes.ItemSlot

local InventoryManager = {}
InventoryManager.__index = InventoryManager
setmetatable(InventoryManager, { __index = BaseService })

function InventoryManager.new()
	return setmetatable(BaseService.new("InventoryManager"), InventoryManager)
end

-- ---------------------------------------------------------------------------
-- Grant Item
-- ---------------------------------------------------------------------------

-- Grants an item to the player based on its category.
-- Returns (success: boolean, errorMessage: string?)
function InventoryManager:GrantItem(player: Player, itemId: string): (boolean, string?)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return false, `Item "{itemId}" does not exist in catalog`
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false, "Player state not found"
	end

	local category = itemDef.Category

	if category == "OneTime" then
		return self:_GrantOneTime(player, state, itemId)
	elseif category == "Cosmetic" or category == "BirdSkin" then
		return self:_GrantCosmetic(player, state, itemId)
	elseif category == "Level" then
		return self:_GrantLevel(player, state, itemId, itemDef)
	elseif category == "Consumable" then
		return self:_GrantConsumable(player, state, itemId, itemDef)
	else
		return false, `Unknown item category: {category}`
	end
end

function InventoryManager:_GrantOneTime(player: Player, state: any, itemId: string): (boolean, string?)
	if state.OwnedItems[itemId] then
		return false, "You already own this item"
	end
	if state.OneTimePurchases[itemId] then
		return false, "You already own this item"
	end

	state.OwnedItems[itemId] = true
	state.OneTimePurchases[itemId] = true

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemPurchased, player, itemId)
	return true
end

function InventoryManager:_GrantCosmetic(player: Player, state: any, itemId: string): (boolean, string?)
	if state.OwnedItems[itemId] then
		return false, "You already own this cosmetic"
	end

	state.OwnedItems[itemId] = true

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemPurchased, player, itemId)
	return true
end

function InventoryManager:_GrantLevel(player: Player, state: any, itemId: string, itemDef: ItemDefinition): (boolean, string?)
	local currentLevel = state.ItemLevels[itemId] or 0
	local maxLevel = itemDef.MaxLevel or 1

	if currentLevel >= maxLevel then
		return false, `This upgrade is already at max level ({maxLevel})`
	end

	state.ItemLevels[itemId] = currentLevel + 1
	state.OwnedItems[itemId] = true

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemPurchased, player, itemId)
	return true
end

function InventoryManager:_GrantConsumable(player: Player, state: any, itemId: string, itemDef: ItemDefinition): (boolean, string?)
	local currentCount = state.ConsumableCounts[itemId] or 0
	local maxStack = itemDef.MaxStack or 99

	if currentCount >= maxStack then
		return false, `Consumable stack is full ({maxStack}/{maxStack})`
	end

	state.ConsumableCounts[itemId] = currentCount + 1
	state.OwnedItems[itemId] = true

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemPurchased, player, itemId)
	return true
end

-- ---------------------------------------------------------------------------
-- Equip / Unequip Cosmetics
-- ---------------------------------------------------------------------------

-- Equips a cosmetic to its associated slot. Validates ownership and slot match.
function InventoryManager:EquipItem(player: Player, itemId: string, slot: string): (boolean, string?)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return false, `Item "{itemId}" not found in catalog`
	end

	if itemDef.Category ~= "Cosmetic" and itemDef.Category ~= "BirdSkin" then
		return false, "Only cosmetic items can be equipped"
	end

	if itemDef.Slot ~= (slot :: ItemSlot) then
		return false, `Item "{itemId}" does not fit slot "{slot}"`
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false, "Player state not found"
	end

	if not state.OwnedItems[itemId] then
		return false, "You do not own this item"
	end

	-- Clear the slot silently during a switch — don't fire ItemUnequipped.
	-- The equip handler in ItemEffectService already manages CosmeticService
	-- cleanup/reapply. Firing ItemUnequipped here would trigger a parallel
	-- _RestoreBirdSkinAppearance that races with _ApplyBirdSkin.
	if state.EquippedItems[slot] then
		state.EquippedItems[slot] = nil
	end

	state.EquippedItems[slot] = itemId

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemEquipped, player, itemId, slot)
	return true
end

-- Unequips whatever is in the given slot.
function InventoryManager:UnequipItem(player: Player, slot: string): (boolean, string?)
	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false, "Player state not found"
	end

	local equippedItemId = state.EquippedItems[slot]
	if not equippedItemId then
		return false, "Nothing equipped in this slot"
	end

	state.EquippedItems[slot] = nil

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemUnequipped, player, slot, equippedItemId)
	return true
end

-- ---------------------------------------------------------------------------
-- Consumable Usage
-- ---------------------------------------------------------------------------

-- Uses one charge of a consumable item. Returns false if the player has none.
function InventoryManager:UseConsumable(player: Player, itemId: string): (boolean, string?)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return false, `Item "{itemId}" not found in catalog`
	end

	if itemDef.Category ~= "Consumable" then
		return false, "Only consumable items can be used"
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false, "Player state not found"
	end

	local currentCount = state.ConsumableCounts[itemId] or 0
	if currentCount <= 0 then
		return false, "No charges remaining"
	end

	state.ConsumableCounts[itemId] = currentCount - 1
	if state.ConsumableCounts[itemId] <= 0 then
		state.ConsumableCounts[itemId] = nil
	end

	self:_SyncToProfile(player, state)
	EventManager:Fire(EventNames.ItemUsed, player, itemId)
	return true, itemDef
end

-- ---------------------------------------------------------------------------
-- Query Helpers
-- ---------------------------------------------------------------------------

function InventoryManager:GetOwnedItems(player: Player): { [string]: boolean }
	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state then
		return {}
	end
	return state.OwnedItems
end

function InventoryManager:GetEquippedItems(player: Player): { [string]: string }
	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state then
		return {}
	end
	return state.EquippedItems
end

function InventoryManager:GetConsumableCount(player: Player, itemId: string): number
	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state then
		return 0
	end
	return state.ConsumableCounts[itemId] or 0
end

function InventoryManager:GetItemLevel(player: Player, itemId: string): number
	local state = self.Services:Get("PlayerManager"):GetState(player)
	if not state then
		return 0
	end
	return state.ItemLevels[itemId] or 0
end

-- ---------------------------------------------------------------------------
-- Internal Helpers
-- ---------------------------------------------------------------------------

-- Syncs the in-memory state to the DataManager profile and marks it dirty.
function InventoryManager:_SyncToProfile(player: Player, state: any)
	local dataManager = self.Services:Get("DataManager")
	local profile = dataManager:GetProfile(player)
	if profile then
		profile.OwnedItems = state.OwnedItems
		profile.EquippedItems = state.EquippedItems
		profile.ItemLevels = state.ItemLevels
		profile.ConsumableCounts = state.ConsumableCounts
		profile.OneTimePurchases = state.OneTimePurchases
		dataManager:MarkDirty(player)
	end
end

return InventoryManager