--!strict

export type RoundMode = "FirstElimination" | "LastManStanding"

export type RoundResult = {
	Mode: RoundMode,
	Winners: { Player },
	EliminatedPlayers: { Player },
	Reason: string,
}

return {}
