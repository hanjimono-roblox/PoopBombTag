--!strict

export type ItemCategory = "OneTime" | "Level" | "Consumable" | "Cosmetic" | "BirdSkin"

export type ItemRarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type ItemSlot = "Pet" | "Trail" | "DeathEffect" | "TagEffect" | "Hat" | "Emote" | "BirdSkin" | "Aura"

export type ItemDefinition = {
	Id: string,
	Name: string,
	Description: string,
	Category: ItemCategory,
	Rarity: ItemRarity,
	PricePoop: number?,
	PriceRobux: number?,
	Icon: string,
	Slot: ItemSlot?,
	MaxLevel: number?,
	MaxStack: number?,
	Effects: { [string]: any },
	Tags: { string }?,
	ProductId: number?, -- Roblox Developer Product ID for Robux purchases
}

return {}