--!strict

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal = {
	Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
	Once: (self: Signal, callback: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	local self: any = setmetatable({
		_connections = {},
	}, Signal)

	return self :: Signal
end

function Signal:Connect(callback: (...any) -> ()): Connection
	assert(type(callback) == "function", "Signal:Connect requires a function")

	local connection = {
		Connected = true,
	}

	function connection:Disconnect()
		if not self.Connected then
			return
		end

		self.Connected = false
	end

	local selfAny = self :: any
	table.insert(selfAny._connections, {
		Connection = connection,
		Callback = callback,
	})

	return connection :: Connection
end

function Signal:Once(callback: (...any) -> ()): Connection
	local connection: Connection?

	connection = self:Connect(function(...)
		if connection then
			connection:Disconnect()
		end

		callback(...)
	end)

	return connection
end

function Signal:Fire(...: any)
	local selfAny = self :: any
	for _, entry in ipairs(selfAny._connections) do
		if entry.Connection.Connected then
			task.spawn(entry.Callback, ...)
		end
	end
end

function Signal:DisconnectAll()
	local selfAny = self :: any
	for _, entry in ipairs(selfAny._connections) do
		entry.Connection:Disconnect()
	end

	table.clear(selfAny._connections)
end

return Signal
