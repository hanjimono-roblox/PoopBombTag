--!strict
--[[
	ItemEffectService (Server)
	Bridges the gap between the inventory system and gameplay.

	When items are purchased, equipped, or used, this service reads the
	item's Effects table and applies them to the player's movement stats
	(via MovementService), currency bonuses, or character properties.

	COSMETIC items are forwarded to CosmeticService for safe, unified
	slot-based application.

	Watchers:
	  * ItemPurchased → applies passive effects for OneTime upgrades, Level
	    upgrades, and PoopMagnet
	  * ItemEquipped   → forwards to CosmeticService for visual effects
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

	-- DataLoaded: apply passive movement effects once player state is available.
	-- CosmeticService handles cosmetic reapplication independently.
	EventManager:Connect(EventNames.DataLoaded, function(player: Player)
    self:_ApplyMovementFromState(player)
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

	

	-- Recompute ALL passive movement effects whenever a character spawns.
	-- CosmeticService handles cosmetic reapplication independently via its
	-- own CharacterAdded listener — we only apply movement here to avoid
	-- duplicate cosmetic applications.
	Players.PlayerAdded:Connect(function(player: Player)
	local function apply()
		task.delay(0.1, function()
			self:_ApplyMovementFromState(player)
		end)
	end

	player.CharacterAdded:Connect(apply)

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
-- Cosmetic Equip / Unequip (FORWARDED to CosmeticService)
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

	-- Forward to CosmeticService for safe, unified application
	local cosmeticService = self.Services:Get("CosmeticService")
	if cosmeticService then
		cosmeticService:ApplyCosmetic(player, character, itemDef)
	end
end

-- Called when a player unequips a cosmetic.
function ItemEffectService:_OnItemUnequipped(player: Player, slot: string)
	local character = player.Character
	if not character then
		return
	end

	-- Forward to CosmeticService for safe removal.
	-- BirdSkin uses UnequipBirdSkin (restores appearance + destroys instances).
	-- All other slots use RemoveCosmetic (destroys tagged instances only).
	local cosmeticService = self.Services:Get("CosmeticService")
	if cosmeticService then
		if slot == "BirdSkin" then
			cosmeticService:UnequipBirdSkin(character)
		else
			cosmeticService:RemoveCosmetic(character, slot)
		end
	end

	-- Also clear the attribute on the character
	character:SetAttribute(`ActiveCosmetic_{slot}`, nil)
end

-- Re-applies all currently equipped cosmetics to the player's
-- character. Called on DataLoaded, character respawn, and startup.
-- Forwards to CosmeticService's ReapplyAllOnSpawn.
function ItemEffectService:_ApplyAllEquippedCosmetics(player: Player)
	local cosmeticService = self.Services:Get("CosmeticService")
	if cosmeticService then
		cosmeticService:ReapplyAllOnSpawn(player)
	end
end

return ItemEffectService