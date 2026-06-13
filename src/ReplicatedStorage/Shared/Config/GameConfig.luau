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

    -- Arena-driven participation: the entry zone that separates the
    -- lobby from the arena. Players physically enter this zone to
    -- signal intent. The server authoritatively decides state.
    Arena = {
        -- Bounding box for the arena entry zone. When the Lobby map
        -- or active arena map has an "ArenaEntryZone" part or model,
        -- those world-space bounds take priority over these defaults.
        EntryZoneMin = Vector3.new(-50, -20, -50),
        EntryZoneMax = Vector3.new(50, 50, 50),
    },

    Data = {
        StoreName = "PoopBombTag_PlayerData_v1",
        AutosaveIntervalSeconds = 120
    },

    Coins = {
        DefaultValue = 10,
        DefaultRespawnTime = 15,
        MaxActiveOnField = 5,
        CoinPartName = "PoopCoin",
        CoinColor = Color3.fromRGB(255, 215, 0),
        CoinSize = Vector3.new(2, 2, 1),
        CollectRadius = 4.0,
        RespawnVariance = 0.3,
    },

    MapVote = {
        -- Number of map options presented to players during voting
        OptionsCount = 3,
        -- Duration in seconds that the voting window stays open
        VoteDurationSeconds = 10,
        -- Minimum number of maps required (excluding Lobby) to trigger voting.
        -- If fewer maps are available, the default map is used directly.
        MinimumMapsForVote = 2,
    },

    Player = {
        -- Default health pool; hazards reduce this. When 0, player is eliminated.
        DefaultHealth = 100,
    },
}

return GameConfig