--!strict

local ServiceRegistry = {}
ServiceRegistry.__index = ServiceRegistry

function ServiceRegistry.new()
	return setmetatable({
		_services = {},
		_order = {},
	}, ServiceRegistry)
end

function ServiceRegistry:Register(service)
	assert(service and type(service.Name) == "string", "Service must provide a Name")
	assert(self._services[service.Name] == nil, `Service already registered: {service.Name}`)

	self._services[service.Name] = service
	table.insert(self._order, service)
	service.Services = self
end

function ServiceRegistry:Get(serviceName: string)
	local service = self._services[serviceName]
	assert(service ~= nil, `Unknown service: {serviceName}`)
	return service
end

function ServiceRegistry:InitAll()
	for _, service in ipairs(self._order) do
		if type(service.Init) == "function" then
			service:Init()
		end
	end
end

function ServiceRegistry:StartAll()
	for _, service in ipairs(self._order) do
		if type(service.Start) == "function" then
			service:Start()
		end
	end
end

return ServiceRegistry
