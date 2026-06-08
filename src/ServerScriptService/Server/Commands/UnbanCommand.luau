--!strict

return {
	Name = "unban",
	Aliases = {},
	Permission = "Ban",
	Description = "Stubs an unban action for future persistent moderation.",
	Execute = function(context)
		-- TODO: Remove persisted ban records.
		context.Services:Get("LoggingService"):Info("ADMIN", `Unban requested for {context.Args[1] or "unknown"}`)
		return true
	end,
}
