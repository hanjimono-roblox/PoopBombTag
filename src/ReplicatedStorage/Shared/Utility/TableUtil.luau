--!strict

local TableUtil = {}

function TableUtil.ShallowCopy<T>(source: { [any]: T }): { [any]: T }
	local copy = {}

	for key, value in pairs(source) do
		copy[key] = value
	end

	return copy
end

-- Recursively deep-copies tables. Cycles are not handled (avoid cycles in
-- data you intend to snapshot). Metatables are intentionally not preserved
-- so the result is a plain table -- callers should not rely on identity.
function TableUtil.DeepCopy<T>(source: T): T
	if type(source) ~= "table" then
		return source
	end

	local copy = {}
	for key, value in pairs(source :: { [any]: any }) do
		copy[key] = TableUtil.DeepCopy(value)
	end
	return copy :: any
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
