--!strict

local Signal = require(script.Parent.Utility.Signal)

type SignalType = Signal.Signal
type Connection = Signal.Connection

local EventManager = {
	_events = {} :: { [string]: SignalType },
}

local function getSignal(eventName: string): SignalType
	assert(type(eventName) == "string" and eventName ~= "", "Event name must be a non-empty string")

	local existing = EventManager._events[eventName]
	if existing then
		return existing
	end

	local created = Signal.new()
	EventManager._events[eventName] = created
	return created
end

function EventManager:Connect(eventName: string, callback: (...any) -> ()): Connection
	return getSignal(eventName):Connect(callback)
end

function EventManager:Once(eventName: string, callback: (...any) -> ()): Connection
	return getSignal(eventName):Once(callback)
end

function EventManager:Fire(eventName: string, ...: any)
	getSignal(eventName):Fire(...)
end

function EventManager:Clear(eventName: string)
	local signal = self._events[eventName]
	if signal then
		signal:DisconnectAll()
		self._events[eventName] = nil
	end
end

return EventManager
