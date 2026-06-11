--!strict
--[[
	ShopController (Client)
	Manages the shop UI lifecycle using a Roblox ProximityPrompt.

	SETUP IN STUDIO:
	  1. Place a Part in Workspace named "ShopStand"
	  2. Add a ProximityPrompt as a child of the ShopStand part
	  3. Set the ProximityPrompt properties:
		 - Name: "ShopPrompt" (optional, any name works)
		 - MaxActivationDistance: 10 (how close to stand)
		 - RequiresLineOfSight: false (so walls don't block it)
		 - HoldDuration: 0 (opens instantly on proximity)
		 - ClickablePrompt: true (shows "Press E")

	The ProximityPrompt is a Roblox built-in primitive with ZERO
	server CPU cost — proximity detection is handled by the engine.
	When the player enters range, the shop UI opens automatically.
	When they leave, it closes. The prompt also provides a "Press E
	to open shop" indicator that players already know.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local ShopController = {}
ShopController.__index = ShopController
setmetatable(ShopController, { __index = BaseController })

local CATEGORY_ORDER: { string } = { "All", "OneTime", "Level", "Consumable", "Cosmetic" }

-- Remote cache
local REMOTES = {} :: { [string]: RemoteFunction | RemoteEvent }
local function GetRemote(name: string): RemoteFunction | RemoteEvent
	if REMOTES[name] then
		return REMOTES[name]
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local shopEvents = remotes:WaitForChild("ShopEvents")
	local remote = shopEvents:WaitForChild(name)
	REMOTES[name] = remote
	return remote
end

function ShopController.new()
	local self: any = BaseController.new("ShopController")
	self._isOpen = false
	self._catalog = {} :: { [string]: any }
	self._inventory = {
		OwnedItems = {},
		EquippedItems = {},
		ItemLevels = {},
		ConsumableCounts = {},
		Poop = 0,
	}
	self._categories = {} :: { string }
	self._selectedItemId = nil :: string?
	self._selectedCategory = "All"
	self._shopGui = nil :: ScreenGui?
	self._proximityPrompt = nil :: ProximityPrompt?
	return setmetatable(self, ShopController)
end

function ShopController:Init()
	BaseController.Init(self)
end

function ShopController:Start()
	BaseController.Start(self)

	self:_ResolveGUI()
	self:_SetupRemotes()
	self:_FindProximityPrompt()
end

-- ---------------------------------------------------------------------------
-- GUI Resolution
-- ---------------------------------------------------------------------------

function ShopController:_ResolveGUI()
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end

	local gui = playerGui:FindFirstChild("ShopUI")
	if gui and gui:IsA("ScreenGui") then
		self._shopGui = gui
		-- Ensure it starts disabled
		gui.Enabled = false
		self:_SetupGUIBindings()
	end
end

-- Wire up static click handlers
function ShopController:_SetupGUIBindings()
	if not self._shopGui then
		return
	end

	local closeButton = self._shopGui:FindFirstChild("CloseButton", true)
	if closeButton and closeButton:IsA("ImageButton") then
		closeButton.MouseButton1Click:Connect(function()
			self:_CloseShop()
		end)
	end

	-- Category tabs
	local tabNames = {
		Tab_All = "All",
		Tab_OneTime = "OneTime",
		Tab_Level = "Level",
		Tab_Consumable = "Consumable",
		Tab_Cosmetic = "Cosmetic",
	}
	for tabName, category in tabNames do
		local tab = self._shopGui:FindFirstChild(tabName, true)
		if tab and tab:IsA("TextButton") then
			tab.MouseButton1Click:Connect(function()
				self._selectedCategory = category
				self:_RenderShop()
			end)
		end
	end
end

-- ---------------------------------------------------------------------------
-- ProximityPrompt Detection (Client-Side, Zero CPU)
-- ---------------------------------------------------------------------------
-- Scans Workspace for a ProximityPrompt. This is the most efficient
-- approach in 2026 because ProximityPrompt is a native Roblox engine
-- feature — it uses zero Lua CPU for distance checks.
--
-- The prompt fires:
--   PromptShown    → player entered range → open shop
--   PromptHidden   → player left range    → close shop
--
-- For a simpler "auto-open" feel where the shop opens without
-- pressing E, we use PromptShown/PromptHidden instead of
-- PromptTriggered. The prompt still shows "Press E" as a visual
-- indicator that they're near the shop.
--
-- If you want NO keypress and pure proximity auto-open, set the
-- ProximityPrompt's HoldDuration to 0 and use PromptTriggered.

function ShopController:_FindProximityPrompt()
	-- Handle players joining after the prompt already exists
	local function bindPrompt(prompt: ProximityPrompt)
		if self._proximityPrompt then
			-- Already connected to one, unbind first
			self._proximityPrompt = nil
		end
		self._proximityPrompt = prompt

		-- Open shop when player walks into range
		prompt.PromptShown:Connect(function()
			self:_OpenShop()
		end)

		-- Close shop when player walks away
		prompt.PromptHidden:Connect(function()
			self:_CloseShop()
		end)

		-- Open shop when player presses E (in case PromptShown didn't trigger)
		prompt.Triggered:Connect(function()
			self:_OpenShop()
		end)
	end

	-- Check for an existing prompt in Workspace
	self:_ScanForPrompt(bindPrompt)

	-- Also listen for new prompts being added (e.g. map loads)
	Workspace.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") then
			bindPrompt(descendant)
		end
	end)
end

-- Scans Workspace for existing ProximityPrompt instances
function ShopController:_ScanForPrompt(onFound: (ProximityPrompt) -> ())
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			onFound(descendant)
			return
		end
	end
end

-- ---------------------------------------------------------------------------
-- Remote Setup
-- ---------------------------------------------------------------------------

function ShopController:_SetupRemotes()
	-- InventoryUpdate (RemoteEvent): Server pushes inventory updates
	local inventoryUpdateEv = GetRemote("InventoryUpdate") :: RemoteEvent
	inventoryUpdateEv.OnClientEvent:Connect(function(data: { [string]: any })
		self:_OnInventoryUpdate(data)
	end)
end

-- ---------------------------------------------------------------------------
-- Inventory Update Handler
-- ---------------------------------------------------------------------------

function ShopController:_OnInventoryUpdate(data: { [string]: any })
	-- Full catalog bundle
	if data.Catalog ~= nil then
		self._catalog = data.Catalog or {}
		self._categories = data.Categories or CATEGORY_ORDER
		if data.Inventory then
			local inv = data.Inventory
			self._inventory.OwnedItems = inv.OwnedItems or {}
			self._inventory.EquippedItems = inv.EquippedItems or {}
			self._inventory.ItemLevels = inv.ItemLevels or {}
			self._inventory.ConsumableCounts = inv.ConsumableCounts or {}
			self._inventory.Poop = inv.Poop or 0
		end
		if self._isOpen then
			self:_RenderShop()
		end
		return
	end

	-- Incremental inventory update
	if data.OwnedItems ~= nil then self._inventory.OwnedItems = data.OwnedItems end
	if data.EquippedItems ~= nil then self._inventory.EquippedItems = data.EquippedItems end
	if data.ItemLevels ~= nil then self._inventory.ItemLevels = data.ItemLevels end
	if data.ConsumableCounts ~= nil then self._inventory.ConsumableCounts = data.ConsumableCounts end
	if data.Poop ~= nil then self._inventory.Poop = data.Poop end

	if self._isOpen then
		self:_RenderShop()
	end
end

-- ---------------------------------------------------------------------------
-- Open / Close Shop
-- ---------------------------------------------------------------------------

function ShopController:_OpenShop()
	if self._isOpen then
		return
	end

	-- Ensure GUI is resolved
	self:_ResolveGUI()
	if not self._shopGui then
		warn("[ShopController] ShopUI not found in PlayerGui")
		return
	end

	-- Fetch catalog from server
	self:_FetchCatalog()

	self._isOpen = true
	self._shopGui.Enabled = true
	self._selectedCategory = "All"
	self._selectedItemId = nil

	-- Force all child elements visible (overrides any manual Studio settings)
	self:_ForceChildrenVisible(self._shopGui, true)

	self:_RenderShop()
end

function ShopController:_CloseShop()
	if not self._isOpen then
		return
	end

	self._isOpen = false
	if self._shopGui then
		self._shopGui.Enabled = false
	end
end

-- Recursively sets Visible on all GUI children to ensure they render
-- when the ScreenGui is enabled, even if they were manually hidden in Studio.
function ShopController:_ForceChildrenVisible(instance: Instance, visible: boolean)
	for _, child in ipairs(instance:GetChildren()) do
		if child:IsA("GuiObject") then
			child.Visible = visible
		end
		self:_ForceChildrenVisible(child, visible)
	end
end

-- ---------------------------------------------------------------------------
-- Catalog & Inventory Fetch
-- ---------------------------------------------------------------------------

function ShopController:_FetchCatalog()
	print("[ShopController] Fetching catalog from server...")
	local getCatalogFn = GetRemote("GetCatalog") :: RemoteFunction
	local ok, result = pcall(function()
		return getCatalogFn:InvokeServer()
	end)

	if not ok then
		warn("[ShopController] GetCatalog remote FAILED:", result)
		return
	end

	if result then
		self._catalog = result.Catalog or {}
		self._inventory = result.Inventory or self._inventory
		self._categories = result.Categories or CATEGORY_ORDER
		local itemCount = 0
		for _ in pairs(self._catalog :: any) do itemCount += 1 end
		print("[ShopController] Catalog received:", itemCount, "items, categories:", #self._categories)


	else
		warn("[ShopController] GetCatalog returned nil")
	end
end

-- ---------------------------------------------------------------------------
-- Render Shop UI
-- ---------------------------------------------------------------------------

function ShopController:_RenderShop()
	if not self._shopGui then
		return
	end

	-- Update poop balance
	local balanceLabel = self._shopGui:FindFirstChild("PoopBalanceLabel", true)
	if balanceLabel and balanceLabel:IsA("TextLabel") then
		balanceLabel.Text = `💩 {self._inventory.Poop}`
	end

	-- Update item grid
	self:_RenderItemGrid()

	-- Update detail panel (or hide if nothing selected)
	local detailPanel = self._shopGui:FindFirstChild("ItemDetailPanel", true)
	if self._selectedItemId then
		self:_RenderDetail(self._selectedItemId)
		if detailPanel then
			detailPanel.Visible = true
		end
	elseif detailPanel then
		detailPanel.Visible = false
	end
end

function ShopController:_RenderItemGrid()
	local container = self._shopGui:FindFirstChild("ItemGrid", true)
	if not container or not container:IsA("ScrollingFrame") then
		warn("[ShopController] ItemGrid ScrollingFrame NOT found in GUI")
		return
	end

	-- Clear existing items
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("ImageButton") then
			child:Destroy()
		end
	end

	-- Get items for selected category
	local items = self:_GetItemsForCategory(self._selectedCategory)
	print("[ShopController] Rendering", #items, "items for category:", self._selectedCategory)

	-- Layout in grid (2 columns for 560px-wide scrolling frame)
	local GRID_COLUMNS = 2
	local ITEM_SIZE = UDim2.fromOffset(260, 195)
	local PADDING = 10
	local startX = PADDING
	local startY = PADDING

	for index, itemDef in ipairs(items) do
		local col = (index - 1) % GRID_COLUMNS
		local row = math.floor((index - 1) / GRID_COLUMNS)

		local button = Instance.new("ImageButton")
		button.Name = itemDef.Id
		button.Size = ITEM_SIZE
		local cellW = 260 + PADDING
		local cellH = 195 + PADDING
		button.Position = UDim2.fromOffset(startX + col * cellW, startY + row * cellH)
		button.BackgroundColor3 = self:_GetRarityColor(itemDef.Rarity)
		button.BackgroundTransparency = 0.3
		button.BorderSizePixel = 2
		button.BorderColor3 = self:_GetRarityColor(itemDef.Rarity)
		button.Parent = container

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Size = UDim2.fromOffset(100, 100)
		icon.Position = UDim2.fromOffset(20, 10)
		icon.BackgroundTransparency = 1
		icon.Image = itemDef.Icon
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 5
		icon.Parent = button

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Name"
		nameLabel.Size = UDim2.fromOffset(130, 25)
		nameLabel.Position = UDim2.fromOffset(5, 115)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = itemDef.Name
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLabel.TextScaled = true
		nameLabel.Font = Enum.Font.PermanentMarker
		nameLabel.Parent = button

		local priceLabel = Instance.new("TextLabel")
		priceLabel.Name = "Price"
		priceLabel.Size = UDim2.fromOffset(130, 20)
		priceLabel.Position = UDim2.fromOffset(5, 142)
		priceLabel.BackgroundTransparency = 1
		if itemDef.PricePoop then
			priceLabel.Text = `💩 {itemDef.PricePoop}`
		elseif itemDef.PriceRobux then
			priceLabel.Text = `💰 {itemDef.PriceRobux}`
		end
		priceLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
		priceLabel.TextScaled = true
		priceLabel.Font = Enum.Font.PermanentMarker
		priceLabel.Parent = button

		local statusLabel = Instance.new("TextLabel")
		statusLabel.Name = "Status"
		statusLabel.Size = UDim2.fromOffset(130, 15)
		statusLabel.Position = UDim2.fromOffset(5, 162)
		statusLabel.BackgroundTransparency = 1
		statusLabel.TextScaled = true
		statusLabel.Font = Enum.Font.PermanentMarker
		if self:_IsItemOwned(itemDef) then
			if itemDef.Category == "Level" then
				local level = self._inventory.ItemLevels[itemDef.Id] or 0
				statusLabel.Text = `Lvl {level}/{itemDef.MaxLevel}`
				statusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
			elseif itemDef.Category == "Consumable" then
				local count = self._inventory.ConsumableCounts[itemDef.Id] or 0
				statusLabel.Text = `x{count}`
				statusLabel.TextColor3 = Color3.fromRGB(100, 255, 255)
			elseif itemDef.Category == "Cosmetic" then
				local slot = itemDef.Slot or ""
				if self._inventory.EquippedItems[slot] == itemDef.Id then
					statusLabel.Text = "EQUIPPED"
					statusLabel.TextColor3 = Color3.fromRGB(255, 200, 0)
				else
					statusLabel.Text = "OWNED"
					statusLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
				end
			else
				statusLabel.Text = "OWNED"
				statusLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
			end
		else
			statusLabel.Text = ""
		end
		statusLabel.Parent = button

		button.MouseButton1Click:Connect(function()
			self:_OnItemSelected(itemDef.Id)
		end)
	end

	-- Canvas size: X must be at least the container width for items to render
	local totalRows = math.ceil(#items / GRID_COLUMNS)
	container.CanvasSize = UDim2.fromOffset(560, totalRows * (195 + PADDING) + PADDING)
end

function ShopController:_RenderDetail(itemId: string)
	local itemDef = self._catalog[itemId]
	if not itemDef then
		return
	end

	local panel = self._shopGui:FindFirstChild("ItemDetailPanel", true)
	if not panel then
		return
	end

	panel.Visible = true

	local icon = panel:FindFirstChild("ItemIcon_large", true)
	if icon and icon:IsA("ImageLabel") then
		icon.Image = itemDef.Icon
		icon.ScaleType = Enum.ScaleType.Fit
		icon.BorderColor3 = self:_GetRarityColor(itemDef.Rarity)
	end

	local nameLabel = panel:FindFirstChild("ItemName", true)
	if nameLabel then nameLabel.Text = itemDef.Name end

	local descLabel = panel:FindFirstChild("ItemDescription", true)
	if descLabel then descLabel.Text = itemDef.Description end

	local rarityLabel = panel:FindFirstChild("ItemRarityLabel", true)
	if rarityLabel then
		rarityLabel.Text = itemDef.Rarity
		rarityLabel.TextColor3 = self:_GetRarityColor(itemDef.Rarity)
	end

	local poopButton = panel:FindFirstChild("ItemPricePoop", true)
	if poopButton and poopButton:IsA("TextButton") then
		if itemDef.PricePoop and not self:_IsItemMaxed(itemDef) then
			poopButton.Visible = true
			poopButton.Text = `Buy {itemDef.PricePoop} 💩`
			poopButton.MouseButton1Click:Connect(function()
				self:_OnPurchaseItem(itemDef.Id, "Poop")
			end)
		else
			poopButton.Visible = false
		end
	end

	local robuxButton = panel:FindFirstChild("ItemPriceRobux", true)
	if robuxButton and robuxButton:IsA("TextButton") then
		if itemDef.PriceRobux and not self:_IsItemMaxed(itemDef) then
			robuxButton.Visible = true
			robuxButton.Text = `Buy {itemDef.PriceRobux} Robux`
			robuxButton.MouseButton1Click:Connect(function()
				self:_OnPurchaseItem(itemDef.Id, "Robux")
			end)
		else
			robuxButton.Visible = false
		end
	end

	local levelLabel = panel:FindFirstChild("ItemLevelLabel", true)
	if levelLabel then
		if itemDef.Category == "Level" then
			local level = self._inventory.ItemLevels[itemId] or 0
			levelLabel.Text = `Level {level} / {itemDef.MaxLevel}`
			levelLabel.Visible = true
		else
			levelLabel.Visible = false
		end
	end

	local ownedLabel = panel:FindFirstChild("ItemOwnedLabel", true)
	if ownedLabel then
		local owned = self:_IsItemOwned(itemDef)
		local isEquipped = false
		if itemDef.Category == "Cosmetic" and itemDef.Slot then
			isEquipped = self._inventory.EquippedItems[itemDef.Slot] == itemDef.Id
		end
		if owned and not isEquipped and itemDef.Category == "Cosmetic" then
			ownedLabel.Text = "OWNED"; ownedLabel.Visible = true
			ownedLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
		elseif isEquipped then
			ownedLabel.Text = "EQUIPPED"; ownedLabel.Visible = true
			ownedLabel.TextColor3 = Color3.fromRGB(255, 200, 0)
		elseif owned and itemDef.Category ~= "Cosmetic" then
			ownedLabel.Text = "OWNED"; ownedLabel.Visible = true
			ownedLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
		else
			ownedLabel.Visible = false
		end
	end

	local equipButton = panel:FindFirstChild("EquipButton", true)
	if equipButton and equipButton:IsA("TextButton") then
		if itemDef.Category == "Cosmetic" and self:_IsItemOwned(itemDef) then
			equipButton.Visible = true
			local isEquipped = itemDef.Slot and self._inventory.EquippedItems[itemDef.Slot] == itemDef.Id
			if isEquipped then
				equipButton.Text = "Unequip"
				equipButton.MouseButton1Click:Connect(function()
					self:_OnUnequipItem(itemDef.Slot :: string)
				end)
			else
				equipButton.Text = `Equip to {itemDef.Slot}`
				equipButton.MouseButton1Click:Connect(function()
					self:_OnEquipItem(itemDef.Id, itemDef.Slot :: string)
				end)
			end
		else
			equipButton.Visible = false
		end
	end

	local useButton = panel:FindFirstChild("UseButton", true)
	if useButton and useButton:IsA("TextButton") then
		local count = self._inventory.ConsumableCounts[itemId] or 0
		if itemDef.Category == "Consumable" and count > 0 then
			useButton.Visible = true
			useButton.Text = "Use"
			useButton.MouseButton1Click:Connect(function()
				self:_OnUseConsumable(itemDef.Id)
			end)
		else
			useButton.Visible = false
		end
	end
end

-- ---------------------------------------------------------------------------
-- Purchase / Equip / Use
-- ---------------------------------------------------------------------------

function ShopController:_OnItemSelected(itemId: string)
	self._selectedItemId = itemId
	self:_RenderDetail(itemId)
end

function ShopController:_OnPurchaseItem(itemId: string, currency: string)
	if currency == "Poop" then
		local purchaseRequestFn = GetRemote("PurchaseRequest") :: RemoteFunction
		local ok, results = pcall(function()
			return purchaseRequestFn:InvokeServer(itemId)
		end)
		if ok then
			local success = results[1]
			local errorMessage = results[2]
			if success then
				self:_ShowFeedback("Purchase successful!", Color3.fromRGB(100, 255, 100))
			else
				self:_ShowFeedback(errorMessage or "Purchase failed", Color3.fromRGB(255, 100, 100))
			end
		end
	elseif currency == "Robux" then
		local itemDef = self._catalog[itemId]
		if itemDef and itemDef.ProductId and itemDef.ProductId > 0 then
			MarketplaceService:PromptProductPurchase(Players.LocalPlayer, itemDef.ProductId)
		else
			self:_ShowFeedback("Robux not configured", Color3.fromRGB(255, 200, 100))
		end
	end
end

function ShopController:_OnEquipItem(itemId: string, slot: string)
	local equipItemFn = GetRemote("EquipItem") :: RemoteFunction
	local ok, results = pcall(function()
		return equipItemFn:InvokeServer(itemId, slot)
	end)
	if ok then
		local success = results[1]
		if not success then
			self:_ShowFeedback(results[2] or "Failed to equip", Color3.fromRGB(255, 100, 100))
		end
	end
end

function ShopController:_OnUnequipItem(slot: string)
	local unequipItemFn = GetRemote("UnequipItem") :: RemoteFunction
	local ok, results = pcall(function()
		return unequipItemFn:InvokeServer(slot)
	end)
	if ok then
		local success = results[1]
		if not success then
			self:_ShowFeedback("Failed to unequip", Color3.fromRGB(255, 100, 100))
		end
	end
end

function ShopController:_OnUseConsumable(itemId: string)
	local useConsumableFn = GetRemote("UseConsumable") :: RemoteFunction
	local ok, results = pcall(function()
		return useConsumableFn:InvokeServer(itemId)
	end)
	if ok then
		local success = results[1]
		if not success then
			self:_ShowFeedback("Failed to use", Color3.fromRGB(255, 100, 100))
		end
	end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function ShopController:_GetItemsForCategory(category: string): { any }
	local items: { any } = {}
	-- IMPORTANT: catalog is a dictionary with string keys (item ID → definition)
	-- Must use pairs() to iterate, NOT ipairs
	for _, itemDef in pairs(self._catalog) do
		if category == "All" or itemDef.Category == category then
			table.insert(items, itemDef)
		end
	end
	table.sort(items, function(a, b)
		local order = { Common = 0, Uncommon = 1, Rare = 2, Epic = 3, Legendary = 4 }
		return (order[a.Rarity] or 0) < (order[b.Rarity] or 0)
	end)
	return items
end

function ShopController:_IsItemOwned(itemDef: any): boolean
	if itemDef.Category == "OneTime" then
		return self._inventory.OwnedItems[itemDef.Id] == true
	elseif itemDef.Category == "Cosmetic" then
		return self._inventory.OwnedItems[itemDef.Id] == true
	elseif itemDef.Category == "Level" then
		return (self._inventory.ItemLevels[itemDef.Id] or 0) > 0
	elseif itemDef.Category == "Consumable" then
		return (self._inventory.ConsumableCounts[itemDef.Id] or 0) > 0
	end
	return false
end

function ShopController:_IsItemMaxed(itemDef: any): boolean
	if itemDef.Category == "Level" then
		local level = self._inventory.ItemLevels[itemDef.Id] or 0
		return level >= (itemDef.MaxLevel or 1)
	elseif itemDef.Category == "Consumable" then
		local count = self._inventory.ConsumableCounts[itemDef.Id] or 0
		return count >= (itemDef.MaxStack or 99)
	end
	return self:_IsItemOwned(itemDef) and itemDef.Category ~= "Consumable"
end

function ShopController:_GetRarityColor(rarity: string): Color3
	local colors = {
		Common = Color3.fromRGB(180, 180, 180),
		Uncommon = Color3.fromRGB(100, 200, 100),
		Rare = Color3.fromRGB(100, 150, 255),
		Epic = Color3.fromRGB(200, 100, 255),
		Legendary = Color3.fromRGB(255, 200, 50),
	}
	return colors[rarity] or Color3.fromRGB(255, 255, 255)
end

function ShopController:_ShowFeedback(message: string, color: Color3)
	local feedback = self._shopGui:FindFirstChild("FeedbackLabel", true)
	if not feedback then
		return
	end
	feedback.Text = message
	feedback.TextColor3 = color
	feedback.Visible = true
	feedback.TextTransparency = 0
	local tween = TweenService:Create(feedback, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextTransparency = 1 })
	tween:Play()
	task.wait(2)
	feedback.Visible = false
end

return ShopController