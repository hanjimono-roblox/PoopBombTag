--!strict

return {
	Name = "ban",
	Aliases = {},
	Permission = "Ban",
	Description = "Stubs a ban action for future persistent moderation.",

	Arguments = {
		{
			Name = "target",
			Type = "player",
			Required = true,
		},
		{
			Name = "reason",
			Type = "string",
			Required = false,
		},
	},

	Execute = function(ctx)
		-- TODO: Persist bans through DataManager/moderation store.
		ctx.Services:Get("LoggingService"):Info(
			"ADMIN",
			`Ban requested for {ctx.Target.Name}{if ctx.Reason then ` ({ctx.Reason})` else ""}`
		)
		return true
	end,
}
