--!strict

export type EquippedItems = {
	[string]: string,  -- Slot name → ItemId (e.g. "Trail" → "GoldenTrail")
}

export type PlayerState = {
	Alive: boolean,
	Spectating: boolean,
	InRound: boolean,
	Poop: number,
	EquippedItems: EquippedItems,
	OwnedItems: { [string]: boolean },
	-- New fields for shop system
	ItemLevels: { [string]: number },       -- ItemId → current level (for Level upgrades)
	ConsumableCounts: { [string]: number },  -- ItemId → quantity owned (for Consumables)
	-- Track one-time purchase flags
	OneTimePurchases: { [string]: boolean },
}

return {}
