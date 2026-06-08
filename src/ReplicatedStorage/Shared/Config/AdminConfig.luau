--!strict

local AdminConfig = {
	RankHierarchy = {
		Player = 0,
		Tester = 10,
		Moderator = 50,
		Developer = 90,
		Owner = 100,
	},

	UserRanks = {
		-- [123456789] = "Owner",
	},

	Permissions = {
		Kick = 50,
		Ban = 50,
		Coins = 90,
		Inventory = 90,
		RoundControl = 90,
		BombControl = 90,
		MapControl = 90,
		Announcement = 50,
	},
}

return AdminConfig
