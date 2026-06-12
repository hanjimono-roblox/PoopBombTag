--!strict
--[[
	InventoryController (Client)
	Manages the consumable hotbar UI and visual equipment display.
	Consumable slots are shown at the bottom of the screen during rounds.
	Cosmetic equipment is applied visually to the player's character.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local InventoryController = {}
InventoryController.__index = InventoryController
setmetatable(InventoryController, { __index = BaseController })

-- Number of hotbar slots
local HOTBAR_SLOTS = 5

function InventoryController.new()
	local self: any = BaseController.new("InventoryController")
	self._inventoryGui = nil :: ScreenGui?
	self._hotbarSlots = {} :: { ImageButton }
	self._slotBindings = {} :: { [number]: string } -- slot index → itemId
	self._equipSlots = {} :: { [string]: Instance }
	self._inventoryData = {
		ConsumableCounts = {},
		EquippedItems = {},
	}
	self._catalog = {} :: { [string]: any } -- itemId → itemDef for icon lookup
	return setmetatable(self, InventoryController)
end

function InventoryController:Init()
	BaseController.Init(self)
end

function InventoryController:Start()
	BaseController.Start(self)

	self:_ResolveGUI()
	self:_SetupBindings()
	self:_ListenForUpdates()
end

-- Listens for server InventoryUpdate events AND pulls initial inventory
-- state. The pull ensures data arrives even if the server fired before
-- we connected our listener (eliminates timing race conditions).
function InventoryController:_ListenForUpdates()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local shopEvents = remotes:WaitForChild("ShopEvents")
	local inventoryUpdate = shopEvents:WaitForChild("InventoryUpdate") :: RemoteEvent
	inventoryUpdate.OnClientEvent:Connect(function(data: { [string]: any })
		self:UpdateInventory(data)
	end)

	-- Pull current inventory from server after listener is connected.
	-- This guarantees we get data regardless of push timing.
	task.defer(function()
		local getInventory = shopEvents:WaitForChild("GetInventory") :: RemoteFunction
		local ok, result = pcall(function()
			return getInventory:InvokeServer()
		end)
		if ok and result then
			self:UpdateInventory(result)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- GUI Resolution
-- ---------------------------------------------------------------------------

function InventoryController:_ResolveGUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("InventoryUI")
	if gui and gui:IsA("ScreenGui") then
		self._inventoryGui = gui
		-- Enable the ScreenGui (starts disabled in Studio)
		gui.Enabled = true
		self:_CacheSlots()
	end
end

function InventoryController:_CacheSlots()
	if not self._inventoryGui then
		return
	end

	-- Find or create the consumable hotbar container
	local hotbarFrame = self._inventoryGui:FindFirstChild("ConsumableHotbar", true)
	if not hotbarFrame then
		return
	end

	-- Cache or create hotbar slots
	for i = 1, HOTBAR_SLOTS do
		local slot = hotbarFrame:FindFirstChild(`ConsumableSlot_{i}`)
		if not slot or not slot:IsA("ImageButton") then
			slot = self:_CreateHotbarSlot(hotbarFrame, i)
		end
		self._hotbarSlots[i] = slot
	end

	-- Cache equip slots
	local equipFrame = self._inventoryGui:FindFirstChild("EquipSlots", true)
	if equipFrame then
		for _, child in ipairs(equipFrame:GetChildren()) do
			if child:IsA("ImageButton") then
				self._equipSlots[child.Name] = child
			end
		end
	end
end

-- Creates a single hotbar slot button with Count and Keybind labels.
function InventoryController:_CreateHotbarSlot(parent: Instance, index: number): ImageButton
	local button = Instance.new("ImageButton")
	button.Name = `ConsumableSlot_{index}`
	button.Size = UDim2.fromOffset(60, 60)
	button.Position = UDim2.fromOffset(10 + (index - 1) * 72, 5)
	button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	button.BackgroundTransparency = 0.3
	button.BorderSizePixel = 1
	button.BorderColor3 = Color3.fromRGB(100, 100, 100)
	button.Image = "rbxassetid://0000000000"
	button.Visible = true
	button.Parent = parent

	local countLabel = Instance.new("TextLabel")
	countLabel.Name = "Count"
	countLabel.Size = UDim2.fromOffset(50, 20)
	countLabel.Position = UDim2.fromOffset(5, 35)
	countLabel.BackgroundTransparency = 1
	countLabel.Text = ""
	countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	countLabel.TextScaled = true
	countLabel.Font = Enum.Font.PermanentMarker
	countLabel.Visible = true
	countLabel.Parent = button

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Keybind"
	keyLabel.Size = UDim2.fromOffset(30, 20)
	keyLabel.Position = UDim2.fromOffset(15, 0)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Text = tostring(index)
	keyLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
	keyLabel.TextScaled = true
	keyLabel.Font = Enum.Font.PermanentMarker
	keyLabel.Visible = true
	keyLabel.Parent = button

	return button
end

-- ---------------------------------------------------------------------------
-- Keybind Setup (number keys 1-5 for hotbar)
-- ---------------------------------------------------------------------------

function InventoryController:_SetupBindings()
	local userInputService = game:GetService("UserInputService")
	userInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end

		if input.UserInputType == Enum.UserInputType.Keyboard then
			local keyCode = input.KeyCode
			local keyMap = {
				[Enum.KeyCode.One] = 1,
				[Enum.KeyCode.Two] = 2,
				[Enum.KeyCode.Three] = 3,
				[Enum.KeyCode.Four] = 4,
				[Enum.KeyCode.Five] = 5,
			}

			local slotIndex = keyMap[keyCode]
			if slotIndex then
				self:_OnHotbarKeyPress(slotIndex)
			end
		end
	end)
end

function InventoryController:_OnHotbarKeyPress(slotIndex: number)
	local itemId = self._slotBindings[slotIndex]
	if not itemId then
		return
	end

	-- Use the consumable via remote
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local shopEvents = remotes:WaitForChild("ShopEvents")
	local useConsumable = shopEvents:WaitForChild("UseConsumable") :: RemoteFunction

	local ok, results = pcall(function()
		return useConsumable:InvokeServer(itemId)
	end)

	if ok then
		local success = results[1]
		if success then
			-- Visual feedback: flash the slot
			local slot = self._hotbarSlots[slotIndex]
			if slot then
				slot.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
				task.delay(0.3, function()
					slot.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
				end)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Inventory Update (called from ShopController or via event)
-- ---------------------------------------------------------------------------

function InventoryController:UpdateInventory(inventoryData: { [string]: any })
	if inventoryData.ConsumableCounts then
		self._inventoryData.ConsumableCounts = inventoryData.ConsumableCounts
	end
	if inventoryData.EquippedItems then
		self._inventoryData.EquippedItems = inventoryData.EquippedItems
	end
	-- If catalog data is included, store it for icon lookups
	if inventoryData.Catalog then
		self._catalog = inventoryData.Catalog
	end

	self:_RenderHotbar()
	self:_RenderEquipSlots()
end

-- ---------------------------------------------------------------------------
-- Render Hotbar
-- ---------------------------------------------------------------------------

function InventoryController:_RenderHotbar()
	-- Clear current bindings
	self._slotBindings = {}

	-- Collect all consumables the player has
	local consumables: { [string]: number } = {}
	for itemId, count in self._inventoryData.ConsumableCounts do
		if count > 0 then
			consumables[itemId] = count
		end
	end

	local consumableIds = {}
	for itemId, _ in consumables do
		table.insert(consumableIds, itemId)
	end

	-- Sort by name for consistency
	table.sort(consumableIds)

	-- Assign to hotbar slots (up to 5)
	for i = 1, HOTBAR_SLOTS do
		local slot = self._hotbarSlots[i]
		if not slot then
			continue
		end

		if i <= #consumableIds then
			local itemId = consumableIds[i]
			self._slotBindings[i] = itemId

			slot.Visible = true
			-- Look up the item icon from the catalog
			local itemDef = self._catalog[itemId]
			slot.Image = (itemDef and itemDef.Icon) or "rbxassetid://0000000000"
			slot.BackgroundTransparency = 0.5

			-- Set count label
			local countLabel = slot:FindFirstChild("Count")
			if countLabel and countLabel:IsA("TextLabel") then
				countLabel.Text = tostring(consumables[itemId])
				countLabel.Visible = true
			end

			-- Set keybind label
			local keyLabel = slot:FindFirstChild("Keybind")
			if keyLabel and keyLabel:IsA("TextLabel") then
				keyLabel.Text = tostring(i)
				keyLabel.Visible = true
			end
		else
			slot.Visible = false
			self._slotBindings[i] = nil
		end
	end
end

-- ---------------------------------------------------------------------------
-- Render Equip Slots
-- ---------------------------------------------------------------------------

function InventoryController:_RenderEquipSlots()
	for slotName, itemId in self._inventoryData.EquippedItems do
		local slotButton = self._equipSlots[slotName]
		if not slotButton then
			continue
		end

		-- Show equipped indicator
		slotButton.BorderColor3 = Color3.fromRGB(255, 200, 0)
		slotButton.BorderSizePixel = 2

		-- Set tooltip or label
		local nameLabel = slotButton:FindFirstChild("ItemName")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = itemId
			nameLabel.Visible = true
		end
	end

	-- Clear slots that are no longer equipped
	for slotName, slotButton in self._equipSlots do
		if not self._inventoryData.EquippedItems[slotName] then
			slotButton.BorderSizePixel = 0
			local nameLabel = slotButton:FindFirstChild("ItemName")
			if nameLabel then
				nameLabel.Visible = false
			end
		end
	end
end

return InventoryController