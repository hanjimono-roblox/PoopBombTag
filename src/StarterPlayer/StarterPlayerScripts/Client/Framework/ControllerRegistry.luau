--!strict

local ControllerRegistry = {}
ControllerRegistry.__index = ControllerRegistry

function ControllerRegistry.new()
	return setmetatable({
		_controllers = {},
		_order = {},
	}, ControllerRegistry)
end

function ControllerRegistry:Register(controller)
	assert(controller and type(controller.Name) == "string", "Controller must provide a Name")
	assert(self._controllers[controller.Name] == nil, `Controller already registered: {controller.Name}`)

	self._controllers[controller.Name] = controller
	table.insert(self._order, controller)
	controller.Controllers = self
end

function ControllerRegistry:Get(controllerName: string)
	local controller = self._controllers[controllerName]
	assert(controller ~= nil, `Unknown controller: {controllerName}`)
	return controller
end

function ControllerRegistry:InitAll()
	for _, controller in ipairs(self._order) do
		if type(controller.Init) == "function" then
			controller:Init()
		end
	end
end

function ControllerRegistry:StartAll()
	for _, controller in ipairs(self._order) do
		if type(controller.Start) == "function" then
			controller:Start()
		end
	end
end

return ControllerRegistry
