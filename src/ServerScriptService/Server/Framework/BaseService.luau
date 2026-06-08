--!strict

export type ServiceRegistry = {
	Get: (self: ServiceRegistry, serviceName: string) -> any,
}

export type BaseService = {
	Name: string,
	Services: ServiceRegistry?,
	Init: (self: BaseService) -> (),
	Start: (self: BaseService) -> (),
}

local BaseService = {}
BaseService.__index = BaseService

function BaseService.new(name: string)
	assert(type(name) == "string" and name ~= "", "Service name is required")

	return setmetatable({
		Name = name,
		Services = nil,
		_initialized = false,
		_started = false,
	}, BaseService)
end

function BaseService:Init()
	self._initialized = true
end

function BaseService:Start()
	self._started = true
end

return BaseService
