--!strict

return table.freeze({
	RoundStarted = "RoundStarted",
	RoundEnded = "RoundEnded",
	BombAssigned = "BombAssigned",
	BombTransferred = "BombTransferred",
	BombExploded = "BombExploded",
	-- Internal server-side events fired by the authority layer
	-- (BombManager). These NEVER reach clients directly --
	-- ReplicationService is the single bridge that translates
	-- them into RemoteEvent payloads. Consumers that want to
	-- react to bomb state changes server-side should listen to
	-- these names.
	BombAssignedInternal = "BombAssignedInternal",
	BombTransferredInternal = "BombTransferredInternal",
	BombExplodedInternal = "BombExplodedInternal",
	PlayerEliminated = "PlayerEliminated",
	PlayerReturnedToLobby = "PlayerReturnedToLobby",
	PlayerWon = "PlayerWon",
	PlayersWon = "PlayersWon",
	PoopAwarded = "PoopAwarded",
	MapLoaded = "MapLoaded",
	MapUnloaded = "MapUnloaded",
	AdminCommandExecuted = "AdminCommandExecuted",
	PlayerStateChanged = "PlayerStateChanged",
	RoundPlayerJoined = "RoundPlayerJoined",
	RoundPlayerLeft = "RoundPlayerLeft",
	MovementStateChanged = "MovementStateChanged",
	DataLoaded = "DataLoaded",
	DataSaved = "DataSaved",

	-- Arena-driven participation events
	ArenaEntered = "ArenaEntered",

	-- Shop system events
	ItemPurchased = "ItemPurchased",
	ItemEquipped = "ItemEquipped",
	ItemUnequipped = "ItemUnequipped",
	ItemUsed = "ItemUsed",
	ShopOpened = "ShopOpened",
	ShopClosed = "ShopClosed",
	CatalogReplicated = "CatalogReplicated",
	InventoryUpdated = "InventoryUpdated",

	-- Coin pickup system
	CoinCollected = "CoinCollected",
	CoinSpawned = "CoinSpawned",
	CoinDespawned = "CoinDespawned",

	-- Map voting system
	MapVoteStarted = "MapVoteStarted",
	MapVoteEnded = "MapVoteEnded",
	MapVoteUpdated = "MapVoteUpdated",
	MapVoteCasted = "MapVoteCasted",

	-- Hazard system events
	HazardDamaged = "HazardDamaged",
	HazardEliminated = "HazardEliminated",
	EarthquakeStarted = "EarthquakeStarted",
	EarthquakeEnded = "EarthquakeEnded",
	FloodStarted = "FloodStarted",
	FloodHeightChanged = "FloodHeightChanged",
	FloodEnded = "FloodEnded",
	FireGeyserErupted = "FireGeyserErupted",
	TornadoStarted = "TornadoStarted",
	TornadoMoved = "TornadoMoved",
	TornadoEnded = "TornadoEnded",

	-- Atmosphere system events
	AtmosphereApplied = "AtmosphereApplied",
	AtmosphereCleared = "AtmosphereCleared",
	LightningFlashed = "LightningFlashed",
})
