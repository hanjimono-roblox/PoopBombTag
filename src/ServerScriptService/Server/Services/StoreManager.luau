--!strict

local BaseService = require(script.Parent.Parent.Framework.BaseService)

local StoreManager = {}
StoreManager.__index = StoreManager
setmetatable(StoreManager, { __index = BaseService })

function StoreManager.new()
	local self: any = BaseService.new("StoreManager")
	self._catalog = {
		TestCosmetic = {
			ItemId = "TestCosmetic",
			PriceCoins = 25,
		},
	}
	return setmetatable(self, StoreManager)
end

function StoreManager:GetCatalog()
	local selfAny = self :: any
	return selfAny._catalog
end

function StoreManager:PurchaseWithCoins(player: Player, itemId: string): boolean
	local selfAny = self :: any
	local item = selfAny._catalog[itemId]
	if not item then
		return false
	end

	local currencyManager = self.Services:Get("CurrencyManager")
	if not currencyManager:RemoveCoins(player, item.PriceCoins) then
		return false
	end

	return self.Services:Get("InventoryManager"):GrantItem(player, item.ItemId)
end

function StoreManager:PurchaseWithRobux(player: Player, productId: number): boolean
	-- TODO: Validate MarketplaceService receipts and grant through InventoryManager/CurrencyManager only.
	return false
end

return StoreManager
