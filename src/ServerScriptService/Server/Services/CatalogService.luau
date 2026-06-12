--!strict
--[[
	CatalogService (Server)
	Single source of truth for item definitions at runtime.
	Provides lookup, filtering, and validation of all shop items
	defined in ShopConfig.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
type ItemDefinition = ItemTypes.ItemDefinition
type ItemCategory = ItemTypes.ItemCategory
type ItemSlot = ItemTypes.ItemSlot

local CatalogService = {}
CatalogService.__index = CatalogService
setmetatable(CatalogService, { __index = BaseService })

function CatalogService.new()
	local self: any = BaseService.new("CatalogService")
	self._items = {} :: { [string]: ItemDefinition }
	self._itemsByCategory = {} :: { [ItemCategory]: { ItemDefinition } }
	self._itemsBySlot = {} :: { [ItemSlot]: { ItemDefinition } }
	self._initialized = false
	return setmetatable(self, CatalogService)
end

function CatalogService:Start()
	BaseService.Start(self)
	self:_BuildIndex()
end

-- Builds lookup indices from ShopConfig for O(1) access.
function CatalogService:_BuildIndex()
	local logging = self.Services:Get("LoggingService")

	for id, itemDef in ShopConfig.Items do
		assert(type(id) == "string" and id ~= "", `Item key must be a non-empty string, got {typeof(id)}`)
		assert(itemDef.Id == id, `Item key "{id}" must match its Id field "{itemDef.Id}"`)
		assert(itemDef.PricePoop or itemDef.PriceRobux, `Item "{id}" must have at least one price`)
		assert(itemDef.Category ~= "Cosmetic" or itemDef.Slot ~= nil, `Cosmetic item "{id}" must have a Slot`)

		self._items[id] = itemDef

		local category = itemDef.Category
		if not self._itemsByCategory[category] then
			self._itemsByCategory[category] = {}
		end
		table.insert(self._itemsByCategory[category], itemDef)

		if itemDef.Slot then
			if not self._itemsBySlot[itemDef.Slot] then
				self._itemsBySlot[itemDef.Slot] = {}
			end
			table.insert(self._itemsBySlot[itemDef.Slot], itemDef)
		end

		if logging then
			logging:Info("CATALOG", `Indexed item: {id} ({itemDef.Category})`)
		end
	end

	self._initialized = true
end

-- Returns a copy of the full catalog (safe to replicate to clients).
function CatalogService:GetCatalog(): { [string]: ItemDefinition }
	return self._items
end

-- Returns a safe-to-replicate copy of the catalog.
-- IMPORTANT: PriceRobux and ProductId are STRIPPED so the server
-- remains the single source of truth for Robux pricing.
function CatalogService:GetCatalogForReplication(): { [string]: ItemDefinition }
	local copy: { [string]: ItemDefinition } = {}
	for id, def in self._items do
		local defCopy: ItemDefinition = table.clone(def)
		defCopy.Effects = table.clone(def.Effects)
		-- Strip Robux pricing fields — server authoritatively provides
		-- Robux prices through ShopService's RobuxPrices table.
		defCopy.PriceRobux = nil
		defCopy.ProductId = nil
		copy[id] = defCopy
	end
	return copy
end

function CatalogService:GetItem(itemId: string): ItemDefinition?
	return self._items[itemId]
end

function CatalogService:GetItemsByCategory(category: string): { ItemDefinition }
	local results = self._itemsByCategory[category :: ItemCategory]
	if results then
		return results
	end
	return {}
end

function CatalogService:GetItemsBySlot(slot: string): { ItemDefinition }
	local results = self._itemsBySlot[slot :: ItemSlot]
	if results then
		return results
	end
	return {}
end

function CatalogService:GetCategories(): { string }
	return ShopConfig:GetCategories()
end

function CatalogService:ValidateItem(itemId: string): boolean
	local item = self._items[itemId]
	return item ~= nil
end

-- Returns true if the item can be purchased (exists, has a price).
function CatalogService:IsPurchasable(itemId: string): boolean
	local item = self._items[itemId]
	if not item then
		return false
	end
	return (item.PricePoop ~= nil and item.PricePoop > 0)
		or (item.PriceRobux ~= nil and item.PriceRobux > 0)
end

return CatalogService