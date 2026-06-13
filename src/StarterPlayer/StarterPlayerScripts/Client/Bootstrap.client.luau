--!strict

local Client = script.Parent
local ControllerRegistry = require(Client.Framework.ControllerRegistry)

local registry = ControllerRegistry.new()

local controllerModules = {
	"MovementController",
	"RoundController",
	"BombController",
	"UIController",
	"ShopController",
	"InventoryController",
	"MapVoteController",
	"HazardClientController",
	"AtmosphereClientController",
}

for _, controllerName in ipairs(controllerModules) do
	local moduleScript = Client.Controllers:FindFirstChild(controllerName)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), `Missing controller module: {controllerName}`)

	local controllerModule = require(moduleScript)
	registry:Register(controllerModule.new())
end

registry:InitAll()
registry:StartAll()
