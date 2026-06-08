--!strict

return {
	Name = "announce",
	Aliases = { "say" },
	Permission = "Announcement",
	Description = "Logs an announcement placeholder for future UI broadcast.",

	Arguments = {
		{
			Name = "message",
			Type = "string",
			Required = true,
		},
	},

	Execute = function(ctx)
		if ctx.Message == nil or ctx.Message == "" then
			return false
		end

		-- TODO: Broadcast through a server-owned RemoteEvent to a UI controller.
		ctx.Services:Get("LoggingService"):Info("ANNOUNCE", ctx.Message)
		return true
	end,
}
