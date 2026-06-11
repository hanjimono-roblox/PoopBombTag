--!strict
--[[
	PlayerStateType
	Single source of truth for player participation state.

	Every player must always have exactly ONE valid state.
	No duplicate state tracking across systems.
	No boolean combinations that can conflict.

	State flow:

		Player joins server
			→ Lobby

		Player enters arena (no round active)
			Lobby → ActiveParticipant

		Player enters arena (round active)
			Lobby → Spectator

		Participant is eliminated during round
			ActiveParticipant → Eliminated

		Round ends
			ActiveParticipant → Lobby
			Spectator         → Lobby
			Eliminated        → Lobby
]]

export type PlayerState = "Lobby"
	| "ActiveParticipant"
	| "Eliminated"
	| "Spectator"

-- Valid transitions. Any transition not listed here is invalid and
-- will be rejected by PlayerStateService.
local VALID_TRANSITIONS: { [PlayerState]: { [PlayerState]: boolean } } = {
	Lobby = {
		ActiveParticipant = true,
		Spectator = true,
	},
	ActiveParticipant = {
		Eliminated = true,
		Lobby = true,
	},
	Eliminated = {
		Lobby = true,
		Spectator = true,
	},
	Spectator = {
		Lobby = true,
	},
}

-- Nil state indicates player state not yet initialized.
-- Valid initial states for a player who has never been assigned a state.
export type OptionalPlayerState = PlayerState?

-- Returns true if the transition from `from` to `to` is valid.
-- A nil `from` means the player has no state yet (fresh join).
local function IsValidTransition(from: OptionalPlayerState, toState: PlayerState): boolean
	if from == nil then
		-- Fresh player can go to Lobby (normal join) or Spectator (edge case)
		return toState == "Lobby" or toState == "Spectator"
	end

	if from == toState then
		-- Idempotent set is always OK
		return true
	end

	local allowed = VALID_TRANSITIONS[from]
	return allowed ~= nil and allowed[toState] == true
end

return {
	IsValidTransition = IsValidTransition,
}