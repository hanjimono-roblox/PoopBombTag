--!strict

export type MovementModifier = {
	WallGrip: number?,
	JumpForce: number?,
	TagRange: number?,
	Speed: number?,
}

export type MovementState = {
	Mode: string,
	Modifiers: MovementModifier,
}

return {}
