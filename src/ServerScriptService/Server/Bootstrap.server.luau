--!strict

local Server = script.Parent
local ServiceRegistry = require(Server.Framework.ServiceRegistry)

local registry = ServiceRegistry.new()

local serviceModules = {
	"LoggingService",
	"DataManager",
	"CatalogService",
	"MapManager",
	"PlayerStateService",
	"PlayerManager",
	"SpawnService",
	"ArenaEntryService",
	"MovementService",
	"CurrencyManager",
	"InventoryManager",
	"StoreManager",
	"ItemEffectService",
	"CosmeticService",
	"AdminService",
	"CommandService",
	"BombManager",
	"BombAttachmentService",
	"InteractionService",
	"ReplicationService",
	"TagDetectionService",
	"CoinPickupService",
	"RoundManager",
	"GameManager",
	"ShopService",
}

for _, serviceName in ipairs(serviceModules) do
	local moduleScript = Server.Services:FindFirstChild(serviceName)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), `Missing service module: {serviceName}`)

	local serviceModule = require(moduleScript)
	registry:Register(serviceModule.new())
end

registry:InitAll()
registry:StartAll()
