--!strict
--[[
	StoreManager (Server)
	Handles all purchase transactions for the shop system.

	Supports two currency paths:
	  1. Poop (in-game currency) — validated via CurrencyManager:CanAfford + RemovePoop
	  2. Robux (premium currency) — validated via MarketplaceService.ProcessReceipt

	Both paths delegate to InventoryManager:GrantItem for the actual item delivery.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
type ItemDefinition = ItemTypes.ItemDefinition

local StoreManager = {}
StoreManager.__index = StoreManager
setmetatable(StoreManager, { __index = BaseService })

-- Map of ProductId → ItemId for Robux purchase processing.
-- Populated at startup from ShopConfig.
local PRODUCT_TO_ITEM: { [number]: string } = {}

function StoreManager.new()
	return setmetatable(BaseService.new("StoreManager"), StoreManager)
end

function StoreManager:Start()
	BaseService.Start(self)

	-- Build ProductId → ItemId lookup
	local catalog = self.Services:Get("CatalogService"):GetCatalog()
	for itemId, itemDef in catalog do
		if itemDef.ProductId and itemDef.ProductId > 0 then
			PRODUCT_TO_ITEM[itemDef.ProductId] = itemId
		end
	end

	-- Register the ProcessReceipt handler for Robux purchases
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return self:_OnProcessReceipt(receiptInfo)
	end
end

-- ---------------------------------------------------------------------------
-- Poop Purchase
-- ---------------------------------------------------------------------------

-- Attempts to purchase an item using Poop currency.
-- Returns (success: boolean, errorMessage: string?)
function StoreManager:PurchaseWithPoop(player: Player, itemId: string): (boolean, string?)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return false, "Item not found"
	end

	if not itemDef.PricePoop or itemDef.PricePoop <= 0 then
		return false, "This item cannot be purchased with Poop"
	end

	-- Check if player can already purchase/own the item
	local canPurchase, reason = self:_ValidatePurchase(player, itemId)
	if not canPurchase then
		return false, reason
	end

	-- Deduct Poop
	local currencyManager = self.Services:Get("CurrencyManager")
	if not currencyManager:CanAfford(player, itemDef.PricePoop) then
		return false, `Not enough Poop! You need {itemDef.PricePoop} 💩`
	end

	currencyManager:RemovePoop(player, itemDef.PricePoop)

	-- Grant item
	local inventoryManager = self.Services:Get("InventoryManager")
	local granted, grantError = inventoryManager:GrantItem(player, itemId)
	if not granted then
		-- Refund on failure (shouldn't happen, but be safe)
		currencyManager:AddPoop(player, itemDef.PricePoop)
		return false, grantError or "Failed to grant item"
	end

	return true
end

-- ---------------------------------------------------------------------------
-- Robux Purchase (via Developer Products)
-- ---------------------------------------------------------------------------

-- Validates and processes a Robux purchase receipt.
-- Called by MarketplaceService.ProcessReceipt.
function StoreManager:_OnProcessReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	local logging = self.Services:Get("LoggingService")

	local productId = receiptInfo.ProductId
	local playerId = receiptInfo.PlayerId

	local itemId = PRODUCT_TO_ITEM[productId]
	if not itemId then
		if logging then
			logging:Warn("STORE", `Unknown ProductId {productId} from PlayerId {playerId}`)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		if logging then
			logging:Warn("STORE", `Item "{itemId}" not found for ProductId {productId}`)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Look up the Player object
	local player = Players:GetPlayerByUserId(playerId)
	if not player then
		-- Player may not be in the server yet; we process when they join
		-- via PurchaseWithRobux instead.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Check if they already own this (for one-time/cosmetic items)
	local canPurchase, reason = self:_ValidatePurchase(player, itemId)
	if not canPurchase then
		if logging then
			logging:Info("STORE", `Purchase blocked for {player.Name}: {reason}`)
		end
		-- Already owned — still grant purchase record as processed (no double-charge)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- Grant the item (Robux already deducted by Roblox)
	local inventoryManager = self.Services:Get("InventoryManager")
	local granted, grantError = inventoryManager:GrantItem(player, itemId)
	if not granted then
		if logging then
			logging:Warn("STORE", `Grant failed for {player.Name} item {itemId}: {grantError}`)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if logging then
		logging:Info("STORE", `Robux purchase complete: {player.Name} bought {itemId} (ProductId {productId})`)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Called when the client initiates a Robux purchase via RemoteFunction.
-- Returns the ProductId so the client can prompt MarketplaceService:PromptProductPurchase.
function StoreManager:GetRobuxProductId(itemId: string): (number, string?)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return 0, "Item not found"
	end

	if not itemDef.PriceRobux or itemDef.PriceRobux <= 0 then
		return 0, "This item cannot be purchased with Robux"
	end

	if not itemDef.ProductId or itemDef.ProductId <= 0 then
		return 0, "No Developer Product configured for this item"
	end

	return itemDef.ProductId
end

-- ---------------------------------------------------------------------------
-- Purchase Validation
-- ---------------------------------------------------------------------------

-- Validates whether a player is allowed to purchase a given item.
-- Returns (canPurchase: boolean, reason: string?)
function StoreManager:_ValidatePurchase(player: Player, itemId: string): (boolean, string?)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return false, "Item not found"
	end

	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return false, "Player state not found"
	end

	local category = itemDef.Category

	if category == "OneTime" then
		if state.OwnedItems[itemId] then
			return false, "You already own this item"
		end

	elseif category == "Cosmetic" then
		if state.OwnedItems[itemId] then
			return false, "You already own this cosmetic"
		end

	elseif category == "Level" then
		local currentLevel = state.ItemLevels[itemId] or 0
		local maxLevel = itemDef.MaxLevel or 1
		if currentLevel >= maxLevel then
			return false, `This upgrade is already at max level ({maxLevel})`
		end

	elseif category == "Consumable" then
		local currentCount = state.ConsumableCounts[itemId] or 0
		local maxStack = itemDef.MaxStack or 99
		if currentCount >= maxStack then
			return false, `Consumable stack is full ({maxStack}/{maxStack})`
		end
	end

	return true
end

return StoreManager