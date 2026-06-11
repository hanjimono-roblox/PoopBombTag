--!strict
--[[
	ShopConfig.luau
	Single source of truth for all purchasable items in Poop Bomb Tag.

	To add a new item:
	  1. Add an entry to the Items table with a unique Id.
	  2. Set the icon path.
	  3. If it's a Robux item, set ProductId (matching your Developer Product
	     in the Creator Dashboard).
	  4. If it's a Cosmetic, set Slot to one of the ItemSlot types.
	  5. No code changes needed elsewhere.

	Item categories are loaded dynamically from the Items table so there is
	no separate "Categories" list to maintain.
]]

local ItemTypes = require(script.Parent.Parent.Types.ItemTypes)
type ItemDefinition = ItemTypes.ItemDefinition

-- Utility: creates an ItemDefinition with strict type safety while keeping
-- the config file concise.
local function item(config: ItemDefinition): ItemDefinition
	return config
end

local ShopConfig = {
	Items = {
		-- ====================================================================
		-- CONSUMABLES (purchased in stacks, one-time use per round)
		-- ====================================================================

		NitroCan = item({
			Id = "NitroCan",
			Name = "Nitro Can",
			Description = "Grants a massive speed boost for 8 seconds.",
			Category = "Consumable",
			Rarity = "Uncommon",
			PricePoop = 100,
			Icon = "rbxassetid://71631135863396",
			MaxStack = 10,
			Tags = { "speed", "mobility" },
			Effects = {
				SpeedMultiplier = 1.6,
				Duration = 8.0,
			},
		}),

		BombShield = item({
			Id = "BombShield",
			Name = "Bomb Shield",
			Description = "Survive one bomb explosion. Consumed on detonation.",
			Category = "Consumable",
			Rarity = "Epic",
			PricePoop = 150,
			PriceRobux = 10,
			Icon = "rbxassetid://77001021805256",
			MaxStack = 5,
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "defense", "survival" },
			Effects = {
				BlocksExplosion = true,
			},
		}),

		AdrenalineShot = item({
			Id = "AdrenalineShot",
			Name = "Adrenaline Shot",
			Description = "Instant burst of speed + jump boost for 5 seconds.",
			Category = "Consumable",
			Rarity = "Rare",
			PricePoop = 200,
			PriceRobux = 15,
			Icon = "rbxassetid://119245603709690",
			MaxStack = 3,
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "speed", "mobility", "burst" },
			Effects = {
				SpeedMultiplier = 2.0,
				JumpMultiplier = 1.5,
				Duration = 5.0,
			},
		}),

		InvisibilityCloak = item({
			Id = "InvisibilityCloak",
			Name = "Invisibility Cloak",
			Description = "Turn semi-transparent for 6 seconds. Tagging or being tagged breaks the effect.",
			Category = "Consumable",
			Rarity = "Legendary",
			PricePoop = 300,
			PriceRobux = 25,
			Icon = "rbxassetid://100532945467417",
			MaxStack = 3,
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "stealth", "evasion" },
			Effects = {
				Transparency = 0.7,
				Duration = 6.0,
				BreakOnTag = true,
				BreakOnTagged = true,
			},
		}),

		DecoyBomb = item({
			Id = "DecoyBomb",
			Name = "Decoy Bomb",
			Description = "Drop a fake bomb effect to confuse chasers.",
			Category = "Consumable",
			Rarity = "Rare",
			PricePoop = 120,
			Icon = "rbxassetid://79944797640240",
			MaxStack = 5,
			Tags = { "trick", "evasion" },
			Effects = {
				DecoyDuration = 3.0,
				DecoyRadius = 10.0,
			},
		}),

		-- ====================================================================
		-- LEVEL UPGRADES (purchased repeatedly, each level increases effect)
		-- ====================================================================

		SpeedBoost = item({
			Id = "SpeedBoost",
			Name = "Speed Boost",
			Description = "Permanently increase your movement speed by 4% per level.",
			Category = "Level",
			Rarity = "Common",
			PricePoop = 200,
			Icon = "rbxassetid://124917816664912",
			MaxLevel = 5,
			Tags = { "movement", "passive" },
			Effects = {
				SpeedMultiplier = 0.04,
			},
		}),

		TagRange = item({
			Id = "TagRange",
			Name = "Extend-O-Tag",
			Description = "Tag players from 12% farther per level.",
			Category = "Level",
			Rarity = "Rare",
			PricePoop = 350,
			PriceRobux = 30,
			Icon = "rbxassetid://111332736797776",
			MaxLevel = 3,
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "offense", "range" },
			Effects = {
				RangeMultiplier = 0.12,
			},
		}),

		JumpPower = item({
			Id = "JumpPower",
			Name = "Jump Power",
			Description = "Jump 5% higher per level.",
			Category = "Level",
			Rarity = "Common",
			PricePoop = 250,
			Icon = "rbxassetid://126487310666544",
			MaxLevel = 5,
			Tags = { "movement", "jump" },
			Effects = {
				JumpMultiplier = 0.05,
			},
		}),

		BombTimer = item({
			Id = "BombTimer",
			Name = "Bomb Timer",
			Description = "Increase bomb fuse time by 1 second per level.",
			Category = "Level",
			Rarity = "Epic",
			PricePoop = 400,
			PriceRobux = 30,
			Icon = "rbxassetid://83335552454901",
			MaxLevel = 3,
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "defense", "time" },
			Effects = {
				ExtraFuseSeconds = 1.0,
			},
		}),

		ShieldDuration = item({
			Id = "ShieldDuration",
			Name = "Shield Duration",
			Description = "Bomb Shield lasts 2 extra seconds after pickup per level.",
			Category = "Level",
			Rarity = "Uncommon",
			PricePoop = 300,
			Icon = "rbxassetid://77001021805256",
			MaxLevel = 3,
			Tags = { "defense", "shield" },
			Effects = {
				ExtraShieldSeconds = 2.0,
			},
		}),

		-- ====================================================================
		-- ONE-TIME PURCHASES (unlocked permanently)
		-- ====================================================================

		DoubleJump = item({
			Id = "DoubleJump",
			Name = "Double Jump",
			Description = "Grants the ability to jump once while airborne.",
			Category = "OneTime",
			Rarity = "Rare",
			PricePoop = 500,
			PriceRobux = 50,
			Icon = "rbxassetid://107347228542212",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "movement", "mobility" },
			Effects = {
				ExtraJumps = 1,
			},
		}),

		WallGrip = item({
			Id = "WallGrip",
			Name = "Wall Grip",
			Description = "Briefly cling to walls when jumping near them.",
			Category = "OneTime",
			Rarity = "Epic",
			PricePoop = 800,
			Icon = "rbxassetid://81916527137977",
			Tags = { "movement", "parkour" },
			Effects = {
				WallGripDuration = 1.5,
			},
		}),

		MagnetBoots = item({
			Id = "MagnetBoots",
			Name = "Magnet Boots",
			Description = "Auto-collect poop drops within a short radius.",
			Category = "OneTime",
			Rarity = "Epic",
			PricePoop = 600,
			Icon = "rbxassetid://93402236664457",
			Tags = { "currency", "utility" },
			Effects = {
				MagnetRadius = 15.0,
			},
		}),

		Dash = item({
			Id = "Dash",
			Name = "Dash",
			Description = "Press shift to dash forward a short distance. 5 second cooldown.",
			Category = "OneTime",
			Rarity = "Legendary",
			PricePoop = 1500,
			PriceRobux = 100,
			Icon = "rbxassetid://108004946685273",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "movement", "mobility", "active" },
			Effects = {
				DashDistance = 20.0,
				DashCooldown = 5.0,
			},
		}),

		PoopMagnet = item({
			Id = "PoopMagnet",
			Name = "Poop Magnet",
			Description = "Start each round with +10 bonus poop.",
			Category = "OneTime",
			Rarity = "Uncommon",
			PricePoop = 400,
			Icon = "rbxassetid://82079075026007",
			Tags = { "currency", "economy" },
			Effects = {
				BonusPoopPerRound = 10,
			},
		}),

		-- ====================================================================
		-- COSMETICS (visual only, equipped to slots)
		-- ====================================================================

		GoldenTrail = item({
			Id = "GoldenTrail",
			Name = "Golden Trail",
			Description = "Leave a shimmering trail of gold as you run.",
			Category = "Cosmetic",
			Rarity = "Legendary",
			Slot = "Trail",
			PricePoop = 1500,
			PriceRobux = 100,
			Icon = "rbxassetid://82179195276896",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "trail", "premium" },
			Effects = {
				TrailAttachment = "HumanoidRootPart",
				TrailColor = Color3.fromRGB(255, 215, 0),
				TrailLifetime = 0.8,
				TrailWidth = 0.5,
			},
		}),

		RainbowTagAura = item({
			Id = "RainbowTagAura",
			Name = "Rainbow Tag Aura",
			Description = "Cycle through rainbow colors while holding the bomb.",
			Category = "Cosmetic",
			Rarity = "Rare",
			Slot = "TagEffect",
			PricePoop = 800,
			PriceRobux = 40,
			Icon = "rbxassetid://121128682920033",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "aura", "bomb" },
			Effects = {
				CycleSpeed = 1.0,
			},
		}),

		DeathStardust = item({
			Id = "DeathStardust",
			Name = "Death Stardust",
			Description = "Erupt in a shower of stardust when eliminated.",
			Category = "Cosmetic",
			Rarity = "Epic",
			Slot = "DeathEffect",
			PricePoop = 1200,
			PriceRobux = 75,
			Icon = "rbxassetid://77344897824934",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "death", "particles" },
			Effects = {
				ParticleTexture = "rbxassetid://0000000000",
				ParticleCount = 50,
				ParticleLifetime = 2.0,
			},
		}),

		CrownOfPoop = item({
			Id = "CrownOfPoop",
			Name = "Crown of Poop",
			Description = "A majestic crown. It's made of poop.",
			Category = "Cosmetic",
			Rarity = "Legendary",
			Slot = "Hat",
			PricePoop = 2000,
			PriceRobux = 150,
			Icon = "rbxassetid://106913965277928",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "hat", "premium", "funny" },
			Effects = {},
		}),

		ShadowPet = item({
			Id = "ShadowPet",
			Name = "Shadow Pet",
			Description = "A shadowy companion follows you everywhere.",
			Category = "Cosmetic",
			Rarity = "Legendary",
			Slot = "Pet",
			PricePoop = 2500,
			PriceRobux = 200,
			Icon = "rbxassetid://73343593730795",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "pet", "premium", "shadow" },
			Effects = {
				PetModel = "ShadowCreature",
				PetScale = 0.8,
			},
		}),

		VictoryDance = item({
			Id = "VictoryDance",
			Name = "Victory Dance",
			Description = "Celebrate your win with a special emote.",
			Category = "Cosmetic",
			Rarity = "Rare",
			Slot = "Emote",
			PricePoop = 1000,
			PriceRobux = 60,
			Icon = "rbxassetid://123819850639775",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "emote", "victory" },
			Effects = {
				AnimationId = "rbxassetid://0000000000",
			},
		}),

		ElectricTrail = item({
			Id = "ElectricTrail",
			Name = "Electric Trail",
			Description = "Crackling electric bolts follow your movement.",
			Category = "Cosmetic",
			Rarity = "Epic",
			Slot = "Trail",
			PricePoop = 1800,
			PriceRobux = 120,
			Icon = "rbxassetid://97359507028622",
			ProductId = 0, -- TODO: Set Developer Product ID
			Tags = { "trail", "electric", "premium" },
			Effects = {
				TrailAttachment = "HumanoidRootPart",
				TrailColor = Color3.fromRGB(0, 255, 255),
				TrailLifetime = 0.6,
				TrailWidth = 0.4,
				TrailTexture = "rbxassetid://97359507028622",
			},
		}),
	},

	-- Categories derived automatically from items. This is a cached list
	-- that gets populated on first access. Manual override is provided if
	-- you want a custom ordering.
	_Categories = nil :: { string }?,
}

-- Returns dynamically-generated category list from the item definitions,
-- ordered: All, OneTime, Level, Consumable, Cosmetic.
function ShopConfig:GetCategories(): { string }
	if self._Categories then
		return self._Categories
	end

	local seen: { [string]: boolean } = {}
	local ordered: { string } = { "All" }
	for _, itemDef in pairs(self.Items) do
		local cat = itemDef.Category :: string
		if not seen[cat] then
			table.insert(ordered, cat)
			seen[cat] = true
		end
	end
	self._Categories = ordered
	return ordered
end

return ShopConfig