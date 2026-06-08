--!strict

local TableUtil = {}

function TableUtil.ShallowCopy<T>(source: { [any]: T }): { [any]: T }
	local copy = {}

	for key, value in pairs(source) do
		copy[key] = value
	end

	return copy
end

function TableUtil.Count(source: { [any]: any }): number
	local count = 0

	for _ in pairs(source) do
		count += 1
	end

	return count
end

function TableUtil.Values<T>(source: { [any]: T }): { T }
	local values = {}

	for _, value in pairs(source) do
		table.insert(values, value)
	end

	return values
end

return TableUtil
