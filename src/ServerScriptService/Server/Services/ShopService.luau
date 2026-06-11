--!strict
--[[
	ShopService (Server)
	Handles all server-side remote connections for the shop system.

	SHOP STAND: Place a part named "ShopStand" in the lobby Workspace.
	Add a ProximityPrompt as a child of it (set MaxActivationDistance to ~8).
	Do NOT add a ClickDetector - the prompt handles all detection natively.

	The client detects proximity to the ShopStand via its ProximityPrompt
	and opens/closes the shop UI. When the player clicks/presses E on the
	prompt, the server handles purchase/equip/use requests via RemoteFunctions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local ShopService = {}
ShopService.__index = ShopService
setmetatable(ShopService, { __index = BaseService })

function ShopService.new()
	return setmetatable(BaseService.new("ShopService"), ShopService)
end

function ShopService:Start()
	BaseService.Start(self)
	self:_SetupRemotes()
end

-- ---------------------------------------------------------------------------
-- Remote Connections
-- ---------------------------------------------------------------------------

function ShopService:_SetupRemotes()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local shopEvents = remotes:WaitForChild("ShopEvents")

	-- GetCatalog: Client requests catalog data (RemoteFunction)
	local getCatalog = shopEvents:WaitForChild("GetCatalog")
	getCatalog.OnServerInvoke = function(player: Player)
		return self:_SendCatalog(player)
	end

	-- PurchaseRequest: Client wants to buy an item with Poop (RemoteFunction)
	local purchaseRequest = shopEvents:WaitForChild("PurchaseRequest")
	purchaseRequest.OnServerInvoke = function(player: Player, itemId: string): (boolean, string?)
		return self:_OnPurchaseRequest(player, itemId)
	end

	-- EquipItem: Client wants to equip a cosmetic (RemoteFunction)
	local equipItem = shopEvents:WaitForChild("EquipItem")
	equipItem.OnServerInvoke = function(player: Player, itemId: string, slot: string): (boolean, string?)
		return self:_OnEquipRequest(player, itemId, slot)
	end

	-- UnequipItem: Client wants to unequip a slot (RemoteFunction)
	local unequipItem = shopEvents:WaitForChild("UnequipItem")
	unequipItem.OnServerInvoke = function(player: Player, slot: string): (boolean, string?)
		return self:_OnUnequipRequest(player, slot)
	end

	-- UseConsumable: Client wants to use a consumable (RemoteFunction)
	local useConsumable = shopEvents:WaitForChild("UseConsumable")
	useConsumable.OnServerInvoke = function(player: Player, itemId: string): (boolean, any)
		return self:_OnUseConsumableRequest(player, itemId)
	end
end

-- ---------------------------------------------------------------------------
-- Catalog + Inventory Response
-- ---------------------------------------------------------------------------

function ShopService:_SendCatalog(player: Player): { [string]: any }
	local catalogService = self.Services:Get("CatalogService")
	if not catalogService then
		warn("[ShopService/_SendCatalog] CatalogService not available")
		return { Catalog = {}, Inventory = {}, Categories = {} }
	end
	local catalog = catalogService:GetCatalogForReplication()
	local catalogCount = 0
	for _ in pairs(catalog :: any) do catalogCount += 1 end
	print("[ShopService/_SendCatalog] Sending", catalogCount, "items to", player.Name)

	local inventoryManager = self.Services:Get("InventoryManager")
	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)

	local inventoryData = {
		OwnedItems = inventoryManager:GetOwnedItems(player),
		EquippedItems = inventoryManager:GetEquippedItems(player),
		ItemLevels = (state and state.ItemLevels) or {},
		ConsumableCounts = (state and state.ConsumableCounts) or {},
		Poop = (state and state.Poop) or 0,
	}

	return {
		Catalog = catalog,
		Inventory = inventoryData,
		Categories = catalogService:GetCategories(),
	}
end

-- ---------------------------------------------------------------------------
-- Purchase / Equip / Use Handlers
-- ---------------------------------------------------------------------------

function ShopService:_OnPurchaseRequest(player: Player, itemId: string): (boolean, string?)
	local logging = self.Services:Get("LoggingService")
	if not player or not player.Parent then
		return false, "Player not found"
	end

	local success, errorMessage = self.Services:Get("StoreManager"):PurchaseWithPoop(player, itemId)
	if success then
		self:_PushInventoryUpdate(player)
		if logging then
			logging:Info("SHOP", `{player.Name} purchased {itemId} with Poop`)
		end
	end
	return success, errorMessage
end

function ShopService:_OnEquipRequest(player: Player, itemId: string, slot: string): (boolean, string?)
	local success, errorMessage = self.Services:Get("InventoryManager"):EquipItem(player, itemId, slot)
	if success then
		self:_PushInventoryUpdate(player)
	end
	return success, errorMessage
end

function ShopService:_OnUnequipRequest(player: Player, slot: string): (boolean, string?)
	local success, errorMessage = self.Services:Get("InventoryManager"):UnequipItem(player, slot)
	if success then
		self:_PushInventoryUpdate(player)
	end
	return success, errorMessage
end

function ShopService:_OnUseConsumableRequest(player: Player, itemId: string): (boolean, any)
	local inventoryManager = self.Services:Get("InventoryManager")
	local success, itemDef = inventoryManager:UseConsumable(player, itemId)
	if success then
		self:_PushInventoryUpdate(player)
	end
	return success, itemDef
end

-- ---------------------------------------------------------------------------
-- Inventory Push (Server → Client)
-- ---------------------------------------------------------------------------

function ShopService:_PushInventoryUpdate(player: Player)
	local inventoryManager = self.Services:Get("InventoryManager")
	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)

	local inventoryData = {
		OwnedItems = inventoryManager:GetOwnedItems(player),
		EquippedItems = inventoryManager:GetEquippedItems(player),
		ItemLevels = (state and state.ItemLevels) or {},
		ConsumableCounts = (state and state.ConsumableCounts) or {},
		Poop = (state and state.Poop) or 0,
	}

	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then return end
	local shopEvents = remotes:FindFirstChild("ShopEvents")
	if not shopEvents then return end
	local inventoryUpdate = shopEvents:FindFirstChild("InventoryUpdate")
	if not inventoryUpdate or not inventoryUpdate:IsA("RemoteEvent") then return end

	inventoryUpdate:FireClient(player, inventoryData)
end

return ShopService