--!strict

return {
	Name = "announce",
	Aliases = { "say" },
	Permission = "Announcement",
	Description = "Logs an announcement placeholder for future UI broadcast.",
	Execute = function(context)
		local message = table.concat(context.Args, " ")
		if message == "" then
			return false
		end

		-- TODO: Broadcast through a server-owned RemoteEvent to a UI controller.
		context.Services:Get("LoggingService"):Info("ANNOUNCE", message)
		return true
	end,
}
