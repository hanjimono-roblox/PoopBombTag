--!strict

export type EquippedItems = {
	[string]: string,
}

export type PlayerState = {
	Alive: boolean,
	Spectating: boolean,
	InRound: boolean,
	Poop: number,
	EquippedItems: EquippedItems,
	OwnedItems: { [string]: boolean },
}

return {}
