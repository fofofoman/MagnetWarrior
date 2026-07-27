--!nonstrict
--[[
	Trove.luau
	Minimal cleanup container. Every per-player and per-run object graph in this
	project is owned by a Trove so that leaving mid-run, dying mid-cling or
	rebuilding a stage cannot leak connections or physics constraints.

		local trove = Trove.new()
		trove:Add(part.Touched:Connect(onTouched))
		trove:Add(attachment)
		trove:Add(function() print("bye") end)
		trove:Clean()
]]

local Trove = {}
Trove.__index = Trove

export type Trove = typeof(setmetatable(
	{} :: {
		_objects: { any },
		_cleaning: boolean,
	},
	Trove
))

function Trove.new(): Trove
	return setmetatable({
		_objects = {},
		_cleaning = false,
	}, Trove)
end

local function disposeOf(object: any)
	local kind = typeof(object)
	if kind == "function" then
		object()
	elseif kind == "RBXScriptConnection" then
		object:Disconnect()
	elseif kind == "Instance" then
		object:Destroy()
	elseif kind == "table" then
		if typeof(object.Destroy) == "function" then
			object:Destroy()
		elseif typeof(object.Clean) == "function" then
			object:Clean()
		elseif typeof(object.Disconnect) == "function" then
			object:Disconnect()
		end
	end
end

function Trove:Add<T>(object: T): T
	assert(not self._cleaning, "cannot add to a Trove while it is cleaning")
	table.insert(self._objects, object)
	return object
end

--- Removes an object without disposing of it.
function Trove:Remove(object: any): boolean
	local index = table.find(self._objects, object)
	if index then
		table.remove(self._objects, index)
		return true
	end
	return false
end

--- Disposes of a single tracked object early.
function Trove:Dispose(object: any)
	if self:Remove(object) then
		disposeOf(object)
	end
end

function Trove:Clean()
	if self._cleaning then
		return
	end
	self._cleaning = true

	-- Reverse order: things added later usually depend on things added earlier.
	for index = #self._objects, 1, -1 do
		local object = self._objects[index]
		self._objects[index] = nil
		local ok, err = pcall(disposeOf, object)
		if not ok then
			warn(`[Trove] cleanup error: {err}`)
		end
	end

	self._cleaning = false
end

Trove.Destroy = Trove.Clean

return Trove
