--!strict
--[[
	ItemEffectService (Server)
	Bridges the gap between the inventory system and gameplay.

	When items are purchased, equipped, or used, this service reads the
	item's Effects table and applies them to the player's movement stats
	(via MovementService), currency bonuses, or character properties.

	Watchers:
	  * ItemPurchased → applies passive effects for OneTime upgrades, Level
	    upgrades, and PoopMagnet
	  * ItemEquipped   → marks cosmetic ownership (visual effects handled client-side)
	  * ItemUsed       → applies temporary consumable effects

	This service is stateless: all passive modifiers are derived from
	PlayerManager:GetState on every call. No cached per-player state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseService = require(script.Parent.Parent.Framework.BaseService)
local EventManager = require(ReplicatedStorage.Shared.EventManager)
local EventNames = require(ReplicatedStorage.Shared.Constants.EventNames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local ItemEffectService = {}
ItemEffectService.__index = ItemEffectService
setmetatable(ItemEffectService, { __index = BaseService })

function ItemEffectService.new()
	local self: any = BaseService.new("ItemEffectService")
	return setmetatable(self, ItemEffectService)
end

function ItemEffectService:Start()
	BaseService.Start(self)

	-- Also listen for DataLoaded in case character spawns before
		-- player state is available (race condition).
		EventManager:Connect(EventNames.DataLoaded, function(player: Player)
    self:_ApplyMovementFromState(player)
    self:_ApplyAllEquippedCosmetics(player)
end)

	-- Watch shop/inventory events
	EventManager:Connect(EventNames.ItemPurchased, function(player: Player, itemId: string)
		self:_OnItemPurchased(player, itemId)
	end)

	EventManager:Connect(EventNames.ItemEquipped, function(player: Player, itemId: string, slot: string)
		self:_OnItemEquipped(player, itemId, slot)
	end)

	EventManager:Connect(EventNames.ItemUnequipped, function(player: Player, slot: string, _itemId: string)
		self:_OnItemUnequipped(player, slot)
	end)

	EventManager:Connect(EventNames.ItemUsed, function(player: Player, itemId: string)
		self:_OnItemUsed(player, itemId)
	end)

	

	-- Recompute ALL passive effects + apply cosmetics whenever a
	-- character spawns. This handles returning players, first join,
	-- and respawns.
	Players.PlayerAdded:Connect(function(player: Player)
	local function apply()
		task.delay(0.1, function()
			self:_ApplyMovementFromState(player)
			self:_ApplyAllEquippedCosmetics(player)
		end)
	end

	player.CharacterAdded:Connect(apply)

	-- immediate apply if character already exists
	if player.Character then
		apply()
	end
end)

	Players.PlayerRemoving:Connect(function(_player)
end)

	-- Handle players already in-game at the time this service starts
	-- (e.g. hot-reload in Studio). Character may or may not exist yet.
	for _, player in ipairs(Players:GetPlayers()) do
		local function apply()
			task.delay(0.1, function()
				self:_ApplyMovementFromState(player)
				self:_ApplyAllEquippedCosmetics(player)
			end)
		end

		player.CharacterAdded:Connect(apply)

		local playerManager = self.Services:Get("PlayerManager")
		local state = playerManager and playerManager:GetState(player)

		if state and (next(state.OwnedItems) ~= nil or next(state.ItemLevels) ~= nil) then
			apply()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Item Purchased
-- ---------------------------------------------------------------------------

function ItemEffectService:_OnItemPurchased(player: Player, itemId: string)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return
	end

	local effects = itemDef.Effects
	if not effects or next(effects) == nil then
		return
	end

	local category = itemDef.Category
	local logging = self.Services:Get("LoggingService")

	if category == "OneTime" or category == "Level" then
		self:_ApplyMovementFromState(player)
	elseif category == "Consumable" then
		-- Consumable effects are applied when USED, not when purchased.
		-- The only exception is consumable purchase itself — no instant effect.
	elseif category == "Cosmetic" then
		-- Cosmetic purchase just grants ownership; equipping triggers visuals.
	end

	if logging then
		logging:Info("EFFECTS", `Applied effects for {player.Name}: {itemId} ({category})`)
	end
end

-- ---------------------------------------------------------------------------
-- Item Used (Consumable)
-- ---------------------------------------------------------------------------

function ItemEffectService:_OnItemUsed(player: Player, itemId: string)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef or not itemDef.Effects then
		return
	end

	local effects = itemDef.Effects
	local logging = self.Services:Get("LoggingService")

	-- For consumable items, apply temporary effects.
	-- We use MovementService to apply a temporary modifier, then
	-- remove it after the duration expires.

	local tempModifiers: { [string]: number } = {}

	if effects.SpeedMultiplier then
		tempModifiers.Speed = effects.SpeedMultiplier
	end

	if effects.JumpMultiplier then
		tempModifiers.Jump = effects.JumpMultiplier
	end

	if effects.Transparency then
		-- Invisibility: handled via ReplicationService (transparency on character)
		self:_ApplyInvisibility(player, effects)
		return -- Invisibility doesn't use MovementService
	end

	if effects.DecoyDuration then
		self:_ApplyDecoy(player, effects)
		return
	end

	if effects.BlocksExplosion then
		-- BombShield: this is consumed on explosion, applied by BombManager
		-- No immediate movement effect needed
		return
	end

	if next(tempModifiers) == nil then
		return
	end

	local duration = effects.Duration or 5.0

	-- Apply temporary modifier
	local movementService = self.Services:Get("MovementService")
	local baseModifiers = self:_ComputeModifiers(player)

	-- Combine temporary with permanent
	local combined = table.clone(baseModifiers)

for key, value in pairs(tempModifiers) do
	local base = combined[key] or 1.0
	combined[key] = base * value
end

movementService:SetMovementModifier(player, combined)

	-- Schedule removal
	task.delay(duration, function()
		if not player or not player.Parent then
			return
		end
		-- Revert to permanent modifiers only
		self:_ApplyMovementFromState(player)
	end)

	if logging then
		logging:Info("EFFECTS", `Applied consumable {itemId} to {player.Name} for {duration}s`)
	end
end

-- ---------------------------------------------------------------------------
-- Invisibility Effect
-- ---------------------------------------------------------------------------

function ItemEffectService:_ApplyInvisibility(player: Player, effects: { [string]: any })
	local transparency = effects.Transparency or 0.7
	local duration = effects.Duration or 6.0
	local breakOnTag = effects.BreakOnTag
	local breakOnTagged = effects.BreakOnTagged

	local character = player.Character
	if not character then
		return
	end

	-- Set transparency on all character parts
	local parts: { BasePart } = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	for _, part in parts do
		part.Transparency = transparency
	end

	local connection = nil
	local cleanup = function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		for _, part in parts do
			if part and part.Parent then
				part.Transparency = 0
			end
		end
	end

	-- Break on tag/tagged if configured
	if breakOnTag or breakOnTagged then
		connection = EventManager:Connect(EventNames.BombTransferredInternal, function(_fromPlayer, toPlayer)
			if breakOnTag and toPlayer == player then
				cleanup()
			elseif breakOnTagged and _fromPlayer == player then
				cleanup()
			end
		end)
	end

	-- Auto-cleanup after duration
	task.delay(duration, function()
		if player and player.Parent then
			cleanup()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Decoy Effect
-- ---------------------------------------------------------------------------

function ItemEffectService:_ApplyDecoy(player: Player, effects: { [string]: any })
	-- DecoyBomb is more of a visual trick. The actual decoy placement
	-- would be coordinated with BombManager. For now, we just log it.
	local logging = self.Services:Get("LoggingService")
	if logging then
		logging:Info("EFFECTS", `Decoy used by {player.Name} (duration={effects.DecoyDuration}, radius={effects.DecoyRadius})`)
	end
end

-- ---------------------------------------------------------------------------
-- Push modifiers to MovementService
-- ---------------------------------------------------------------------------

function ItemEffectService:_PushToMovementService(player: Player, modifiers: { [string]: number })
	local movementService = self.Services:Get("MovementService")
if not movementService then return end

	-- Build a MovementModifier from our modifier map
	local movementModifier: { [string]: number } = {}

	for key, value in modifiers do
		-- Map our keys to MovementService keys
		if key == "Speed" then
			movementModifier.Speed = value
		elseif key == "Jump" then
			movementModifier.JumpForce = value
		elseif key == "TagRange" then
			movementModifier.TagRange = value
		elseif key == "WallGrip" then
			movementModifier.WallGrip = value
		elseif key == "ExtraJumps" then
			movementModifier.ExtraJumps = value
		elseif key == "DashDistance" then
			movementModifier.DashDistance = value
		elseif key == "DashCooldown" then
			movementModifier.DashCooldown = value
		elseif key == "MagnetRadius" then
			movementModifier.MagnetRadius = value
		elseif key == "BonusPoopPerRound" then
			movementModifier.BonusPoopPerRound = value
		end
	end

	-- Mirror client-needed active abilities onto Player attributes.
	-- Attributes replicate reliably and can be read immediately by
	-- StarterPlayerScripts without depending on RemoteEvent timing.
	player:SetAttribute("ExtraJumps", movementModifier.ExtraJumps or 0)

	if next(movementModifier) ~= nil and movementService then
		movementService:SetMovementModifier(player, movementModifier)
	end

	-- Directly apply modifiers to the character's Humanoid.
	-- This is what makes effects actually visible/usable in-game.
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local defaultWalkSpeed = GameConfig.Movement.DefaultWalkSpeed or 40
	local defaultJumpPower = GameConfig.Movement.DefaultJumpPower or 70

	if modifiers.Speed then
		humanoid.WalkSpeed = defaultWalkSpeed * modifiers.Speed
	end

	if modifiers.Jump then
		humanoid.JumpPower = defaultJumpPower * modifiers.Jump
	end
end

-- ---------------------------------------------------------------------------
-- Compute all passive modifiers from PlayerManager state.
-- This is the ONLY function that knows how item effects translate to
-- modifier values. It is deterministic: given the same state, it always
-- returns the same result.
-- ---------------------------------------------------------------------------

function ItemEffectService:_ComputeModifiers(player: Player): { [string]: number }
	local catalog = self.Services:Get("CatalogService")
	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return {}
	end

	local modifiers: { [string]: number } = {}

	-- Level items
	for itemId, level in pairs(state.ItemLevels) do
		if level > 0 then
			local itemDef = catalog:GetItem(itemId)
			if itemDef and itemDef.Effects then
				local eff = itemDef.Effects
				if eff.SpeedMultiplier then
					modifiers.Speed = (modifiers.Speed or 1.0) + eff.SpeedMultiplier * level
				end
				if eff.JumpMultiplier then
					modifiers.Jump = (modifiers.Jump or 1.0) + eff.JumpMultiplier * level
				end
				if eff.RangeMultiplier then
					modifiers.TagRange = (modifiers.TagRange or 1.0) + eff.RangeMultiplier * level
				end
				if eff.ExtraFuseSeconds then
					modifiers.ExtraFuseSeconds = (modifiers.ExtraFuseSeconds or 0) + eff.ExtraFuseSeconds * level
				end
				if eff.ExtraShieldSeconds then
					modifiers.ExtraShieldSeconds = (modifiers.ExtraShieldSeconds or 0) + eff.ExtraShieldSeconds * level
				end
			end
		end
	end

	-- OneTime items
	for itemId, _ in pairs(state.OwnedItems) do
		local itemDef = catalog:GetItem(itemId)
		if itemDef and itemDef.Category == "OneTime" and itemDef.Effects then
			local eff = itemDef.Effects
			if eff.ExtraJumps and not modifiers.ExtraJumps then
				modifiers.ExtraJumps = eff.ExtraJumps
			end
			if eff.WallGripDuration and not modifiers.WallGrip then
				modifiers.WallGrip = eff.WallGripDuration
			end
			if eff.MagnetRadius and not modifiers.MagnetRadius then
				modifiers.MagnetRadius = eff.MagnetRadius
			end
			if eff.DashDistance and not modifiers.DashDistance then
				modifiers.DashDistance = eff.DashDistance
				modifiers.DashCooldown = eff.DashCooldown or 5.0
			end
			if eff.BonusPoopPerRound and not modifiers.BonusPoopPerRound then
				modifiers.BonusPoopPerRound = eff.BonusPoopPerRound
			end
		end
	end

	return modifiers
end

-- ---------------------------------------------------------------------------
-- Apply computed modifiers to MovementService and Humanoid.
-- This is the canonical entry point for applying passive movement effects.
-- ---------------------------------------------------------------------------

function ItemEffectService:_ApplyMovementFromState(player: Player)
	self:_PushToMovementService(player, self:_ComputeModifiers(player))
end

-- ---------------------------------------------------------------------------
-- Cosmetic Equip / Unequip
-- ---------------------------------------------------------------------------

-- Called when a player equips a cosmetic via the shop UI.
function ItemEffectService:_OnItemEquipped(player: Player, itemId: string, slot: string)
	local catalog = self.Services:Get("CatalogService")
	local itemDef = catalog:GetItem(itemId)
	if not itemDef then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	self:_ApplyCosmeticEffect(player, character, itemDef, slot)
end

-- Called when a player unequips a cosmetic.
function ItemEffectService:_OnItemUnequipped(player: Player, slot: string)
	local character = player.Character
	if not character then
		return
	end
	self:_RemoveCosmeticEffect(character, slot)
end

-- Re-applies all currently equipped cosmetics to the player's
-- character. Called on DataLoaded, character respawn, and startup.
function ItemEffectService:_ApplyAllEquippedCosmetics(player: Player)
	local catalog = self.Services:Get("CatalogService")
	local playerManager = self.Services:Get("PlayerManager")
	local state = playerManager:GetState(player)
	if not state then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	for slot, itemId in pairs(state.EquippedItems) do
		local itemDef = catalog:GetItem(itemId)
		if itemDef then
			self:_ApplyCosmeticEffect(player, character, itemDef, slot)
		end
	end
end

-- Applies a single cosmetic effect to the character based on its Slot.
function ItemEffectService:_ApplyCosmeticEffect(
	player: Player,
	character: Model,
	itemDef: any,
	slot: string
)
	local effects = itemDef.Effects
	local logging = self.Services:Get("LoggingService")

	-- Remove any existing effect in this slot first
	self:_RemoveCosmeticEffect(character, slot)

	if slot == "Trail" then
		self:_CreateTrail(character, itemDef, effects)
	elseif slot == "TagEffect" then
		self:_CreateTagEffect(character, itemDef, effects)
	elseif slot == "DeathEffect" then
		-- Death effect is triggered on death, not applied continuously.
		-- We store the itemId reference so the death handler can look it up.
	elseif slot == "Hat" then
		self:_CreateHat(character, itemDef, effects)
	elseif slot == "Pet" then
		self:_SpawnPet(player, character, itemDef, effects)
	elseif slot == "Emote" then
		-- Emotes are triggered via UI action, not continuous.
	end

	if logging then
		logging:Info("COSMETIC", `Applied {slot} "{itemDef.Id}" to {player.Name}`)
	end
end

-- Removes the cosmetic object(s) for a given slot from the character.
function ItemEffectService:_RemoveCosmeticEffect(character: Model, slot: string)
	for _, d in ipairs(character:GetDescendants()) do
		if d:GetAttribute("CosmeticSlot") == slot then
			d:Destroy()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Trail Cosmetics (GoldenTrail, ElectricTrail)
-- ---------------------------------------------------------------------------

function ItemEffectService:_CreateTrail(character: Model, itemDef: any, effects: { [string]: any })
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	-- Attachment0: base attachment (feet/root, trails between this and attachment1)
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = `TrailAttachment0_{itemDef.Id}`
	attachment0:SetAttribute("CosmeticSlot", "Trail")
	attachment0.Position = effects.TrailAttachment == "HumanoidRootPart" and Vector3.new(0, -2, 0) or Vector3.zero
	attachment0.Parent = rootPart

	-- Attachment1: secondary attachment on lower leg so the trail actually renders.
	-- Roblox Trails require TWO attachments to draw between.
	local leftFoot = character:FindFirstChild("LeftFoot") or character:FindFirstChild("LeftLowerLeg")
	local rightFoot = character:FindFirstChild("RightFoot") or character:FindFirstChild("RightLowerLeg")
	local secondaryParent = (leftFoot and leftFoot:IsA("BasePart") and leftFoot) or (rightFoot and rightFoot:IsA("BasePart") and rightFoot) or rootPart

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = `TrailAttachment1_{itemDef.Id}`
	attachment1:SetAttribute("CosmeticSlot", "Trail")
	attachment1.Position = Vector3.zero
	attachment1.Parent = secondaryParent

	local trail = Instance.new("Trail")
	trail.Name = `Trail_{itemDef.Id}`
	trail:SetAttribute("CosmeticSlot", "Trail")
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Lifetime = effects.TrailLifetime or 0.8
	trail.MinLength = 0.1
	trail.Enabled = true
	trail.Parent = rootPart

	if effects.TrailColor then
		trail.Color = ColorSequence.new(effects.TrailColor)
	end

	local width = effects.TrailWidth or 0.5
	trail.MaxLength = width * 10
end

-- ---------------------------------------------------------------------------
-- Tag Effect (RainbowTagAura) — aura around bomb holder
-- ---------------------------------------------------------------------------

function ItemEffectService:_CreateTagEffect(character: Model, itemDef: any, effects: { [string]: any })
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = `TagAuraAttachment_{itemDef.Id}`
	attachment:SetAttribute("CosmeticSlot", "TagEffect")
	attachment.Parent = rootPart

	local particle = Instance.new("ParticleEmitter")
	particle.Name = `TagAura_{itemDef.Id}`
	particle:SetAttribute("CosmeticSlot", "TagEffect")
	particle.Texture = "rbxassetid://0000000000"
	particle.Rate = 20
	particle.Lifetime = NumberRange.new(0.5, 1.0)
	particle.SpreadAngle = Vector2.new(0, 360)
	particle.Speed = NumberRange.new(1)
	particle.Color = ColorSequence.new(Color3.fromRGB(255, 0, 0), Color3.fromRGB(0, 255, 0), Color3.fromRGB(0, 0, 255))
	particle.Enabled = true
	particle.Parent = attachment
end

-- ---------------------------------------------------------------------------
-- Hat Cosmetic (CrownOfPoop)
-- ---------------------------------------------------------------------------

function ItemEffectService:_CreateHat(character: Model, itemDef: any, effects: { [string]: any })
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = `HatAttachment_{itemDef.Id}`
	attachment:SetAttribute("CosmeticSlot", "Hat")
	attachment.Position = Vector3.new(0, 0.5, 0)
	attachment.Parent = head

	-- Spawn a simple part as a placeholder hat
	local hatPart = Instance.new("Part")
	hatPart.Name = `Hat_{itemDef.Id}`
	hatPart:SetAttribute("CosmeticSlot", "Hat")
	hatPart.Size = Vector3.new(1.2, 0.6, 1.2)
	hatPart.Shape = Enum.PartType.Cylinder
	hatPart.BrickColor = BrickColor.new("Brown")
	hatPart.Anchored = false
	hatPart.CanCollide = false
	hatPart.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hatPart
	weld.Part1 = head
	weld.Parent = hatPart

	hatPart.Parent = character
end

-- ---------------------------------------------------------------------------
-- Pet Cosmetic (ShadowPet)
-- ---------------------------------------------------------------------------

function ItemEffectService:_SpawnPet(player: Player, character: Model, itemDef: any, effects: { [string]: any })
	local petScale = effects.PetScale or 1.0

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local petPart = Instance.new("Part")
	petPart.Name = `Pet_{itemDef.Id}`
	petPart:SetAttribute("CosmeticSlot", "Pet")
	petPart.Size = Vector3.new(1.5, 1.5, 1.5) * petScale
	petPart.Color = Color3.fromRGB(80, 20, 120) -- dark purple, visible
	petPart.Anchored = false
	petPart.CanCollide = false
	petPart.Massless = true
	petPart.Transparency = 0.2
	petPart.Parent = character

	-- Glow effect to make the pet noticeable
	local highlight = Instance.new("Highlight")
	highlight.Name = "PetHighlight"
	highlight:SetAttribute("CosmeticSlot", "Pet")
	highlight.FillColor = Color3.fromRGB(80, 20, 120)
	highlight.OutlineColor = Color3.fromRGB(180, 80, 255)
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0.3
	highlight.Parent = petPart

	-- Simple follow behavior
	task.spawn(function()
		while petPart and petPart.Parent do
			if not player or not player.Parent then break end
			local char = player.Character
			if char ~= character then break end -- new character, cleanup
			local rp = char and char:FindFirstChild("HumanoidRootPart")
			if rp and rp:IsA("BasePart") then
				petPart.CFrame = rp.CFrame * CFrame.new(-3, -1, -3)
			end
			task.wait(0.08)
		end
		-- Cleanup: destroy pet if player left or character changed
		if petPart and petPart.Parent then
			petPart:Destroy()
		end
	end)
end

return ItemEffectService