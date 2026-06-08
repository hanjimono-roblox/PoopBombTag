--!strict

local BaseController = {}
BaseController.__index = BaseController

function BaseController.new(name: string)
	assert(type(name) == "string" and name ~= "", "Controller name is required")

	return setmetatable({
		Name = name,
		Controllers = nil,
		_initialized = false,
		_started = false,
	}, BaseController)
end

function BaseController:Init()
	self._initialized = true
end

function BaseController:Start()
	self._started = true
end

return BaseController
