--!strict

export type MaidTask = RBXScriptConnection | thread | (() -> ()) | { Destroy: (any) -> () } | { Disconnect: (any) -> () }

local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({
		_tasks = {},
	}, Maid)
end

function Maid:GiveTask(taskItem: MaidTask): MaidTask
	table.insert(self._tasks, taskItem)
	return taskItem
end

function Maid:DoCleaning()
	for _, taskItem in ipairs(self._tasks) do
		if typeof(taskItem) == "RBXScriptConnection" then
			taskItem:Disconnect()
		elseif type(taskItem) == "thread" then
			task.cancel(taskItem)
		elseif type(taskItem) == "function" then
			taskItem()
		elseif type(taskItem) == "table" then
			local taskTable = taskItem :: any
			if type(taskTable.Destroy) == "function" then
				taskTable:Destroy()
			elseif type(taskTable.Disconnect) == "function" then
				taskTable:Disconnect()
			end
		end
	end

	table.clear(self._tasks)
end

return Maid
