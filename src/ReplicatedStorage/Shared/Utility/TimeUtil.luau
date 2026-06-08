--!strict

local TimeUtil = {}

function TimeUtil.Now(): number
	return os.clock()
end

function TimeUtil.UtcTimestamp(): string
	return DateTime.now():ToIsoDate()
end

function TimeUtil.SecondsRemaining(endTime: number): number
	return math.max(0, endTime - TimeUtil.Now())
end

return TimeUtil
