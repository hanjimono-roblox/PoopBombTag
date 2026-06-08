--!strict

local GameConfig = {
	Round = {
		MinimumPlayers = 2,
		IntermissionDurationSeconds = 20,
		StartingDurationSeconds = 5,
		RoundEndDurationSeconds = 8,
		DefaultMode = "LastManStanding",
	},

	Bomb = {
		DurationSeconds = 15.0,
		TagDistanceStuds = 8.0,
		TransferCooldownSeconds = 0.75,
	},

	Rewards = {
		LastManStandingWinnerPoop = 100,
		FirstEliminationWinnerPoop = 50,
		ParticipationPoop = 5,
	},

	Maps = {
		DefaultMapName = "ArenaTemplate",
		ActiveMapParentName = "ActiveMap",
		LobbySpawnName = "LobbySpawn",
		RoundSpawnFolderName = "Spawns",
	},

	Movement = {
		DefaultMode = "Default",
		DefaultWalkSpeed = 16,
		DefaultJumpPower = 50,
		DefaultModifiers = {
			WallGrip = 1.0,
			JumpForce = 1.0,
			TagRange = 1.0,
			Speed = 1.0,
		},
	},

	Data = {
		StoreName = "PoopBombTag_PlayerData_v1",
		AutosaveIntervalSeconds = 120,
	},
}

return GameConfig
