-- !strict
local GameConfig = {
    Round = {
        MinimumPlayers = 2,
        IntermissionDurationSeconds = 5,
        StartingDurationSeconds = 2,
        RoundEndDurationSeconds = 8,
        DefaultMode = "LastManStanding"
    },

    Bomb = {
        DurationSeconds = 15.0,
        TagDistanceStuds = 8.0,
        TransferCooldownSeconds = 0.75
    },

    Rewards = {
        LastManStandingWinnerPoop = 100,
        FirstEliminationWinnerPoop = 50,
        ParticipationPoop = 5
    },

    Maps = {
        DefaultMapName = "ArenaTemplate",
        ActiveMapParentName = "ActiveMap",
        LobbySpawnName = "LobbySpawn",
        RoundSpawnFolderName = "Spawns"
    },

    Movement = {
        DefaultMode = "Default",
        DefaultWalkSpeed = 40,
        DefaultJumpPower = 70,
        DefaultModifiers = {
            WallGrip = 1.0,
            JumpForce = 1.0,
            TagRange = 1.0,
            Speed = 1.0
        }
    },

    Shop = {
        ShopStandName = "ShopStand",
        ProximityRadiusStuds = 8.0,
        IconTemplateId = "rbxassetid://0000000000",
    },

    Data = {
        StoreName = "PoopBombTag_PlayerData_v1",
        AutosaveIntervalSeconds = 120
    }
}

return GameConfig
