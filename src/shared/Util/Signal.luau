--!nonstrict
--[[
	Signal.luau
	Lightweight event object so server systems can talk to each other without
	requiring each other directly (RunSession fires Finished, Records and
	Leaderboards listen). Handlers run on fresh threads, so one erroring listener
	cannot stop the others or block the firing system.
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self._connected then
		return
	end
	self._connected = false

	local handlers = self._signal._handlers
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
end

Connection.Destroy = Connection.Disconnect

export type Signal = typeof(setmetatable({} :: { _handlers: { any } }, Signal))

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler: (...any) -> ())
	local connection = setmetatable({
		_signal = self,
		_handler = handler,
		_connected = true,
	}, Connection)

	table.insert(self._handlers, connection)
	return connection
end

function Signal:Once(handler: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal:Fire(...: any)
	-- Iterate a snapshot: a handler is allowed to disconnect itself or others.
	local snapshot = table.clone(self._handlers)
	for _, connection in snapshot do
		if connection._connected then
			task.spawn(connection._handler, ...)
		end
	end
end

function Signal:DisconnectAll()
	for _, connection in table.clone(self._handlers) do
		connection:Disconnect()
	end
end

Signal.Destroy = Signal.DisconnectAll

return Signal
