--!strict
--[[
	CosmeticService (Server)
	Unified data-driven cosmetic pipeline.

	Architecture:
	  * Single entry point: ApplyCosmetic(player, character, itemDef)
	  * Slot-based: each slot (Hat, Trail, Pet, BirdSkin, Aura, Emote)
	    can have at most one active cosmetic at a time.
	  * Cleanup: RemoveCosmetic finds descendants tagged with CosmeticSlot
	    attribute and destroys ONLY those instances. Core character parts
	    are NEVER tagged with CosmeticSlot.
	  * State: CosmeticState[player] = { [slot] = itemId }
	  * Respawn-safe: ReapplyAllOnSpawn restores cosmetics after character
	    respawns.

	CRITICAL RULES:
	  1. Humanoid is NEVER destroyed or reset.
	  2. HumanoidRootPart is NEVER replaced.
	  3. Only appearance layers (Shirt, Pants, Accessories, parts, particles)
	     are modified.
	  4. Body parts are NEVER tagged with CosmeticSlot.
	  5. RemoveCosmetic ONLY destroys instances created by this service.
	  6. BirdSkin applies via Humanoid:ApplyDescription() ONLY — never sets
	     body part colors directly (direct props override description restore).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BaseService = require(script.Parent.Parent.Framework.BaseService)

local CosmeticService = {}
CosmeticService.__index = CosmeticService
setmetatable(CosmeticService, { __index = BaseService })

-- Maps Player -> { [slot: string]: itemId: string }
-- Central registry of active cosmetics, persists across respawns.
local CosmeticState = {} :: { [Player]: { [string]: string } }

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------
function CosmeticService.new()
	local self: any = BaseService.new("CosmeticService")
	self._heartbeatConnections = {} :: { [Player]: RBXScriptConnection }
	return setmetatable(self, CosmeticService)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function CosmeticService:Start()
	BaseService.Start(self)

	-- Handle respawns: reapply cosmetics after character loads.
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			self:_OnCharacterAdded(player, character)
		end)

		if player.Character then
			self:_OnCharacterAdded(player, player.Character)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_CleanupPlayer(player)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function(character: Model)
			self:_OnCharacterAdded(player, character)
		end)
		if player.Character then
			self:_OnCharacterAdded(player, player.Character)
		end
	end

	print("[CosmeticService] Started")
end

-- ---------------------------------------------------------------------------
-- PUBLIC API
-- ---------------------------------------------------------------------------

function CosmeticService:ApplyCosmetic(player: Player, character: Model, itemDef: any)
	local slot = itemDef.Slot
	if not slot then
		return
	end

	local logging = self.Services:Get("LoggingService")

	self:RemoveCosmetic(character, slot)

	if slot == "Hat" then
		self:_ApplyHat(character, itemDef)
	elseif slot == "Trail" then
		self:_ApplyTrail(character, itemDef)
	elseif slot == "Pet" then
		self:_ApplyPet(player, character, itemDef)
	elseif slot == "BirdSkin" then
		self:_ApplyBirdSkin(character, itemDef)
	elseif slot == "Aura" then
		self:_ApplyAura(character, "Aura", itemDef)
	elseif slot == "TagEffect" then
		self:_ApplyAura(character, "TagEffect", itemDef)
	elseif slot == "Emote" then
		-- Emotes are triggered on demand via UI
	elseif slot == "DeathEffect" then
		-- Death effects are triggered on elimination
	end

	if not CosmeticState[player] then
		CosmeticState[player] = {}
	end
	CosmeticState[player][slot] = itemDef.Id
	character:SetAttribute(`ActiveCosmetic_{slot}`, itemDef.Id)

	if logging then
		logging:Info("COSMETIC", `Applied {slot} "{itemDef.Id}" to {player.Name}`)
	end
end

-- RemoveCosmetic(character, slot)
-- Finds ALL descendants tagged with CosmeticSlot == slot and destroys them.
-- NEVER touches Humanoid, HumanoidRootPart, or core body parts.
-- BirdSkin restore is NOT done here — ApplyDescription can reset the
-- HumanoidRootPart which orphans other cosmetics (Trail, etc).
-- Use UnequipBirdSkin() for full restore+cleanup.
function CosmeticService:RemoveCosmetic(character: Model, slot: string)
	local toDestroy: { Instance } = {}
	for _, desc in ipairs(character:GetDescendants()) do
		if desc:GetAttribute("CosmeticSlot") == slot then
			table.insert(toDestroy, desc)
		end
	end

	for _, instance in ipairs(toDestroy) do
		instance:Destroy()
	end
end

-- UnequipBirdSkin(character)
-- Full BirdSkin removal: saves all other active cosmetics, resets the
-- character to default outfit via ApplyDescriptionAsync, waits for the
-- rig to rebuild, then reapplies other cosmetics. Only called on TRUE
-- unequip, not during skin switching.
function CosmeticService:UnequipBirdSkin(character: Model)
	self:_RestoreBirdSkinAppearance(character)
	self:RemoveCosmetic(character, "BirdSkin")
end

-- ReapplyAllOnSpawn(player)
-- Called when a character respawns. Reapplies all saved cosmetics
-- from CosmeticState (or seeds from profile if first load).
function CosmeticService:ReapplyAllOnSpawn(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	task.wait(0.5)

	local equipped = CosmeticState[player]
	
	if not equipped or next(equipped) == nil then
		local playerManager = self.Services:Get("PlayerManager")
		if playerManager then
			local profileState = playerManager:GetState(player)
			if profileState and profileState.EquippedItems then
				equipped = {}
				for slot, itemId in pairs(profileState.EquippedItems) do
					equipped[slot] = itemId
				end
				CosmeticState[player] = equipped
			end
		end
	end

	if not equipped or next(equipped) == nil then
		return
	end

	local catalog = self.Services:Get("CatalogService")
	for slot, itemId in pairs(equipped) do
		local itemDef = catalog and catalog:GetItem(itemId)
		if itemDef then
			self:ApplyCosmetic(player, character, itemDef)
		end
	end
end

function CosmeticService:GetActiveCosmeticId(player: Player, slot: string): string?
	local state = CosmeticState[player]
	if not state then
		return nil
	end
	return state[slot]
end

-- ---------------------------------------------------------------------------
-- HANDLER: Hat
-- ---------------------------------------------------------------------------
function CosmeticService:_ApplyHat(character: Model, itemDef: any)
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end

	local hatModel = Instance.new("Model")
	hatModel.Name = `Hat_{itemDef.Id}`
	hatModel:SetAttribute("CosmeticSlot", "Hat")
	hatModel.Parent = character

	local brown = BrickColor.new("Reddish brown")

	local function makeBall(size: number, offset: Vector3)
		local part = Instance.new("Part")
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(size, size, size)
		part.BrickColor = brown
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true
		part.CFrame = head.CFrame * CFrame.new(offset)
		part.Parent = hatModel
		return part
	end

	local base = makeBall(1.4, Vector3.new(0, 1.0, 0))
	makeBall(1.1, Vector3.new(0, 1.5, 0))
	makeBall(0.9, Vector3.new(0, 1.9, 0))
	makeBall(0.6, Vector3.new(0, 2.25, 0))

	local tip = Instance.new("Part")
	tip.Shape = Enum.PartType.Cylinder
	tip.Size = Vector3.new(0.35, 0.6, 0.35)
	tip.BrickColor = brown
	tip.Material = Enum.Material.SmoothPlastic
	tip.Anchored = false
	tip.CanCollide = false
	tip.CanTouch = false
	tip.CanQuery = false
	tip.Massless = true
	tip.Parent = hatModel
	tip.CFrame = head.CFrame * CFrame.new(0, 2.65, 0) * CFrame.Angles(0, 0, math.rad(90))

	local crownColor = BrickColor.new("New Yeller")
	local crownBase = Instance.new("Part")
	crownBase.Size = Vector3.new(0.5, 0.15, 0.5)
	crownBase.BrickColor = crownColor
	crownBase.Material = Enum.Material.Metal
	crownBase.Anchored = false
	crownBase.CanCollide = false
	crownBase.CanTouch = false
	crownBase.CanQuery = false
	crownBase.Massless = true
	crownBase.Parent = hatModel
	crownBase.CFrame = head.CFrame * CFrame.new(0, 2.95, 0)

	for i = -1, 1 do
		local spike = Instance.new("Part")
		spike.Size = Vector3.new(0.08, 0.22, 0.08)
		spike.BrickColor = crownColor
		spike.Material = Enum.Material.Metal
		spike.Anchored = false
		spike.CanCollide = false
		spike.CanTouch = false
		spike.CanQuery = false
		spike.Massless = true
		spike.Parent = hatModel
		spike.CFrame = head.CFrame * CFrame.new(i * 0.15, 3.12, 0)

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = crownBase
		weld.Part1 = spike
		weld.Parent = spike
	end

	for _, obj in ipairs(hatModel:GetChildren()) do
		if obj:IsA("BasePart") and obj ~= base then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = base
			weld.Part1 = obj
			weld.Parent = obj
		end
	end

	local headWeld = Instance.new("WeldConstraint")
	headWeld.Part0 = base
	headWeld.Part1 = head
	headWeld.Parent = base
end

-- ---------------------------------------------------------------------------
-- HANDLER: Trail
-- ---------------------------------------------------------------------------
function CosmeticService:_ApplyTrail(character: Model, itemDef: any)
	local effects = itemDef.Effects or {}

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local attachment0 = Instance.new("Attachment")
	attachment0.Name = `TrailAttachment0_{itemDef.Id}`
	attachment0:SetAttribute("CosmeticSlot", "Trail")
	attachment0.Position = effects.TrailAttachment == "HumanoidRootPart" and Vector3.new(0, -2, 0) or Vector3.zero
	attachment0.Parent = rootPart

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

	if effects.TrailTexture then
		trail.Texture = effects.TrailTexture
		trail.TextureMode = Enum.TextureMode.Wrap
		trail.TextureLength = effects.TextureLength or 2
	end

	local width = effects.TrailWidth or 0.5
	trail.MaxLength = width * 10
end

-- ---------------------------------------------------------------------------
-- HANDLER: Pet
-- ---------------------------------------------------------------------------
function CosmeticService:_ApplyPet(player: Player, character: Model, itemDef: any)
	local effects = itemDef.Effects or {}

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local petScale = effects.PetScale or 1

	local petModel = Instance.new("Model")
	petModel.Name = `Pet_{itemDef.Id}`
	petModel:SetAttribute("CosmeticSlot", "Pet")
	petModel.Parent = character

	local core = Instance.new("Part")
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(1.2, 1.0, 1.4) * petScale
	core.Material = Enum.Material.SmoothPlastic
	core.Color = Color3.fromRGB(10, 10, 10)
	core.Transparency = 0.25
	core.Anchored = true
	core.CanCollide = false
	core.CanTouch = false
	core.CanQuery = false
	core.Parent = petModel

	local aura = Instance.new("Part")
	aura.Shape = Enum.PartType.Ball
	aura.Size = core.Size * 1.6
	aura.Material = Enum.Material.Neon
	aura.Color = Color3.fromRGB(120, 40, 180)
	aura.Transparency = 0.75
	aura.Anchored = true
	aura.CanCollide = false
	aura.CanTouch = false
	aura.CanQuery = false
	aura.Parent = petModel

	local highlight = Instance.new("Highlight")
	highlight.Name = "PetHighlight"
	highlight.FillColor = Color3.fromRGB(25, 0, 45)
	highlight.OutlineColor = Color3.fromRGB(180, 80, 255)
	highlight.FillTransparency = 0.6
	highlight.OutlineTransparency = 0.2
	highlight.Parent = petModel

	local elapsed = 0
	local baseCoreSize = core.Size
	local followOffset = Vector3.new(-3, -1, -3)
	local followSpeed = 9
	local idleOrbitSpeed = 1.2
	local lastRootPos = rootPart.Position

	local connection: RBXScriptConnection?

	local function cleanup()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		if self._heartbeatConnections then
			self._heartbeatConnections[player] = nil
		end
	end

	petModel.Destroying:Connect(cleanup)

	connection = RunService.Heartbeat:Connect(function(dt)
		if not player.Parent then
			cleanup()
			return
		end
		if player.Character ~= character then
			cleanup()
			return
		end
		if not rootPart.Parent then
			cleanup()
			return
		end

		elapsed += dt

		local moveDelta = (rootPart.Position - lastRootPos).Magnitude
		lastRootPos = rootPart.Position
		local isMoving = moveDelta > 0.05

		local wobble = CFrame.new(
			math.sin(elapsed * 2.2) * 0.2,
			math.sin(elapsed * 3.0) * 0.25,
			math.cos(elapsed * 2.6) * 0.2
		)

		local orbit = CFrame.Angles(0, elapsed * (isMoving and 0.5 or idleOrbitSpeed), 0)
		local baseCF = rootPart.CFrame * CFrame.new(followOffset)
		local targetCF = if isMoving then baseCF * wobble else baseCF * orbit * wobble

		local alpha = 1 - math.exp(-followSpeed * dt)
		core.CFrame = core.CFrame:Lerp(targetCF, alpha)
		aura.CFrame = aura.CFrame:Lerp(targetCF, alpha * 0.55)

		local pulse = (math.sin(elapsed * 2.6) + 1) * 0.5
		core.Transparency = 0.25 + pulse * 0.15
		aura.Transparency = 0.72 + pulse * 0.18
		core.Size = baseCoreSize * (1 + pulse * 0.035)
		aura.Size = core.Size * (1.6 + pulse * 0.06)

		if highlight.Parent then
			highlight.FillTransparency = 0.55 + pulse * 0.25
			highlight.OutlineTransparency = 0.15 + pulse * 0.2
		end
	end)

	if connection then
		self._heartbeatConnections[player] = connection
	end
end

-- ---------------------------------------------------------------------------
-- HANDLER: BirdSkin — ApplyDescriptionAsync for both apply and restore
-- ---------------------------------------------------------------------------
--[[
	Direct part.Color assignments create permanent overrides that
	ApplyDescriptionAsync cannot undo. By using ApplyDescriptionAsync
	for BOTH apply and restore, each call cleanly replaces the
	previous — no permanent custom overrides remain.

	APPLY and RESTORE both use the same save→reset→reapply pattern
	to prevent orphaning other cosmetics during the rig reset:

	  1. Save all other active cosmetics (Hat, Trail, Pet, Aura, TagEffect)
	  2. Strip clothing/accessory instances
	  3. Build the target HumanoidDescription
	  4. humanoid:ApplyDescriptionAsync(description)
	  5. task.wait(0.5) — let the rig rebuild
	  6. Reapply saved cosmetics to the new character
	  7. (Apply only) Add bird-skin aura/particle effects
]]
function CosmeticService:_ApplyBirdSkin(character: Model, itemDef: any)
	local effects = itemDef.Effects or {}

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	-- 1. Save all other active cosmetics before the rig reset
	local savedCosmetics: { any } = {}
	local state = CosmeticState[player]
	if state then
		local catalog = self.Services:Get("CatalogService")
		for slot, itemId in pairs(state) do
			if slot ~= "BirdSkin" then
				local otherItemDef = catalog and catalog:GetItem(itemId)
				if otherItemDef then
					table.insert(savedCosmetics, otherItemDef)
				end
			end
		end
	end

	-- 2. Resolve bird skin config
	local birdSkinName = effects.BirdSkin
	if not birdSkinName then
		return
	end

	local cosmeticsFolder = ReplicatedStorage:FindFirstChild("Cosmetics")
	local skinsFolder = cosmeticsFolder and cosmeticsFolder:FindFirstChild("BirdSkins")
	local skinFolder = skinsFolder and skinsFolder:FindFirstChild(birdSkinName)

	if not skinFolder then
		warn("[CosmeticService] Missing bird skin folder:", birdSkinName)
		return
	end

	local config = require(skinFolder:WaitForChild("Config"))

	-- 3. Build the BirdSkin HumanoidDescription
	local birdDesc = Instance.new("HumanoidDescription")

	if config.BodyColors then
		if config.BodyColors["Head"] then birdDesc.HeadColor = config.BodyColors["Head"] end
		if config.BodyColors["UpperTorso"] or config.BodyColors["Torso"] then
			birdDesc.TorsoColor = config.BodyColors["UpperTorso"] or config.BodyColors["Torso"]
		end
		if config.BodyColors["LeftUpperArm"] or config.BodyColors["Left Arm"] then
			birdDesc.LeftArmColor = config.BodyColors["LeftUpperArm"] or config.BodyColors["Left Arm"]
		end
		if config.BodyColors["RightUpperArm"] or config.BodyColors["Right Arm"] then
			birdDesc.RightArmColor = config.BodyColors["RightUpperArm"] or config.BodyColors["Right Arm"]
		end
		if config.BodyColors["LeftUpperLeg"] or config.BodyColors["Left Leg"] then
			birdDesc.LeftLegColor = config.BodyColors["LeftUpperLeg"] or config.BodyColors["Left Leg"]
		end
		if config.BodyColors["RightUpperLeg"] or config.BodyColors["Right Leg"] then
			birdDesc.RightLegColor = config.BodyColors["RightUpperLeg"] or config.BodyColors["Right Leg"]
		end
	end

	-- Always clear clothing slots on the description so ApplyDescriptionAsync
	-- strips any existing shirt/pants. We apply feather textures afterward
	-- via direct Shirt/Pants instances (more reliable than description-based).
	birdDesc.Shirt = 0
	birdDesc.Pants = 0
	birdDesc.GraphicTShirt = 0

	-- 4. Apply the BirdSkin via ApplyDescriptionAsync (no permanent overrides)
	humanoid:ApplyDescriptionAsync(birdDesc)

	-- 5. Wait for rig rebuild
	task.wait(0.5)

	-- 6. Reapply all other cosmetics to the rebuilt character
	local newCharacter = player.Character
	if not newCharacter then
		return
	end

	for _, otherItemDef in ipairs(savedCosmetics) do
		self:ApplyCosmetic(player, newCharacter, otherItemDef)
	end

	-- 7. Create Shirt/Pants instances for feather textures (more reliable
	--    than ApplyDescriptionAsync for custom uploaded clothing).
	if config.ShirtAsset and config.ShirtAsset ~= 0 then
		local shirt = self:_FindOrCreateClothing(newCharacter, "Shirt", config.ShirtAsset)
		if shirt then
			shirt:SetAttribute("CosmeticSlot", "BirdSkin")
		end
	end
	if config.PantsAsset and config.PantsAsset ~= 0 then
		local pants = self:_FindOrCreateClothing(newCharacter, "Pants", config.PantsAsset)
		if pants then
			pants:SetAttribute("CosmeticSlot", "BirdSkin")
		end
	end

	-- 8. Add BirdSkin aura/particle effects to the new rig
	local rootPart = newCharacter:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	if effects.AuraColor then
		local attachment = Instance.new("Attachment")
		attachment.Name = "BirdSkinAura"
		attachment:SetAttribute("CosmeticSlot", "BirdSkin")
		attachment.Parent = rootPart

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxassetid://296874871"
		emitter.Color = ColorSequence.new(effects.AuraColor)
		emitter.LightEmission = 1
		emitter.Rate = 25
		emitter.Speed = NumberRange.new(0)
		emitter.Lifetime = NumberRange.new(1.2)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Parent = attachment
	end

	if effects.ParticleTexture then
		local attachment = Instance.new("Attachment")
		attachment.Name = "BirdSkinParticles"
		attachment:SetAttribute("CosmeticSlot", "BirdSkin")
		attachment.Parent = rootPart

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = effects.ParticleTexture
		emitter.Rate = effects.ParticleRate or 10
		emitter.Color = ColorSequence.new(effects.ParticleColor or Color3.new(1, 1, 1))
		emitter.LightEmission = 1
		emitter.Speed = NumberRange.new(1, 3)
		emitter.Lifetime = NumberRange.new(0.5, 1.5)
		emitter.Parent = attachment
	end
end

-- Restores the character to their default Roblox outfit.
-- Uses ApplyDescriptionAsync (2026 replacement for deprecated ApplyDescription).
-- To prevent orphaning other cosmetics during the rig reset:
--   1. Save all active cosmetics EXCEPT BirdSkin from CosmeticState
--   2. humanoid:ApplyDescriptionAsync(defaultDescription)
--   3. Wait for rig rebuild (task.wait)
--   4. Reapply all saved cosmetics to the new character rig
function CosmeticService:_RestoreBirdSkinAppearance(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	-- 1. Save all other active cosmetics before the rig reset
	local savedCosmetics: { any } = {}
	local state = CosmeticState[player]
	if state then
		local catalog = self.Services:Get("CatalogService")
		for slot, itemId in pairs(state) do
			if slot ~= "BirdSkin" then
				local itemDef = catalog and catalog:GetItem(itemId)
				if itemDef then
					table.insert(savedCosmetics, itemDef)
				end
			end
		end
	end

	-- 2. Get the player's default outfit
	local defaultDescription = Players:GetHumanoidDescriptionFromUserId(player.UserId)
	if not defaultDescription then
		return
	end

	-- 3. Reset character to default via ApplyDescriptionAsync
	humanoid:ApplyDescriptionAsync(defaultDescription)

	-- 4. Wait for the new rig to assemble (HumanoidRootPart, attachments, etc.)
	task.wait(0.5)

	-- 5. Reapply all other cosmetics to the rebuilt character
	local newCharacter = player.Character
	if not newCharacter then
		return
	end

	for _, itemDef in ipairs(savedCosmetics) do
		self:ApplyCosmetic(player, newCharacter, itemDef)
	end
end

-- ---------------------------------------------------------------------------
-- HANDLER: Aura (Generic particle/glow effect)
-- ---------------------------------------------------------------------------
function CosmeticService:_ApplyAura(character: Model, slotName: string, itemDef: any)
	local effects = itemDef.Effects or {}

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = `AuraAttachment_{itemDef.Id}`
	attachment:SetAttribute("CosmeticSlot", slotName)
	attachment.Parent = rootPart

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = `AuraParticles_{itemDef.Id}`
	emitter:SetAttribute("CosmeticSlot", slotName)

	emitter.Texture = effects.ParticleTexture or "rbxassetid://296874871"
	emitter.Color = ColorSequence.new(effects.AuraColor or Color3.new(1, 1, 1))
	emitter.LightEmission = effects.LightEmission or 1
	emitter.Rate = effects.ParticleRate or 20
	emitter.Speed = NumberRange.new(effects.ParticleSpeed or 0)
	emitter.Lifetime = NumberRange.new(effects.ParticleLifetime or 1.0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, effects.ParticleStartSize or 1),
		NumberSequenceKeypoint.new(1, effects.ParticleEndSize or 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, effects.ParticleStartTransparency or 0.4),
		NumberSequenceKeypoint.new(1, effects.ParticleEndTransparency or 1),
	})
	emitter.Parent = attachment
end

-- ---------------------------------------------------------------------------
-- PRIVATE HELPERS
-- ---------------------------------------------------------------------------

-- _FindOrCreateClothing(character, className, assetId)
-- Finds existing Shirt or Pants instance on the character, or creates one.
-- Uses ShirtTemplate / PantsTemplate for custom uploaded clothing.
-- Returns the instance or nil.
function CosmeticService:_FindOrCreateClothing(character: Model, className: string, assetId: number)
	local existing = character:FindFirstChildOfClass(className)
	if existing and existing:IsA(className) then
		if className == "Shirt" then
			(existing :: Shirt).ShirtTemplate = `rbxassetid://{assetId}`
		elseif className == "Pants" then
			(existing :: Pants).PantsTemplate = `rbxassetid://{assetId}`
		end
		return existing
	end

	local clothing: Instance? = nil
	if className == "Shirt" then
		local shirt = Instance.new("Shirt")
		shirt.ShirtTemplate = `rbxassetid://{assetId}`
		clothing = shirt
	elseif className == "Pants" then
		local pants = Instance.new("Pants")
		pants.PantsTemplate = `rbxassetid://{assetId}`
		clothing = pants
	end

	if clothing then
		clothing.Name = `BirdSkin_{className}`
		clothing.Parent = character
	end

	return clothing
end

function CosmeticService:_OnCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	task.wait(0.5)

	local slotsToCheck = { "Hat", "Trail", "Pet", "BirdSkin", "Aura", "TagEffect", "DeathEffect", "Emote" }
	for _, slot in ipairs(slotsToCheck) do
		self:RemoveCosmetic(character, slot)
	end

	self:ReapplyAllOnSpawn(player)
end

function CosmeticService:_CleanupPlayer(player: Player)
	if self._heartbeatConnections then
		local conn = self._heartbeatConnections[player]
		if conn then
			conn:Disconnect()
			self._heartbeatConnections[player] = nil
		end
	end

	CosmeticState[player] = nil
end

return CosmeticService