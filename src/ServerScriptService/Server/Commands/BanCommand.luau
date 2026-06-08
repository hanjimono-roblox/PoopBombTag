--!strict

return {
	Name = "ban",
	Aliases = {},
	Permission = "Ban",
	Description = "Stubs a ban action for future persistent moderation.",
	Execute = function(context)
		-- TODO: Persist bans through DataManager/moderation store.
		context.Services:Get("LoggingService"):Info("ADMIN", `Ban requested for {context.Args[1] or "unknown"}`)
		return true
	end,
}
