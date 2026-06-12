--!strict

export type MovementModifier = {
	WallGrip: number?,
	JumpForce: number?,
	TagRange: number?,
	Speed: number?,
	ExtraJumps: number?,
	DashDistance: number?,
	DashCooldown: number?,
	MagnetRadius: number?,
	BonusPoopPerRound: number?,
}

export type MovementState = {
	Mode: string,
	Modifiers: MovementModifier,
}

return {}
