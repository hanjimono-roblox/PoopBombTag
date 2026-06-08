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
		[10975513326] = "Owner",
	},

	Permissions = {
		Kick = 50,
		Ban = 50,
		Poop = 90,
		Inventory = 90,
		RoundControl = 90,
		BombControl = 90,
		MapControl = 90,
		Announcement = 50,
	},
}

return AdminConfig
