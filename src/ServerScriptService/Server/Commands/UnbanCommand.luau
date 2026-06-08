--!strict

return {
	Name = "unban",
	Aliases = {},
	Permission = "Ban",
	Description = "Stubs an unban action for future persistent moderation.",

	Arguments = {
		{
			Name = "target",
			Type = "player",
			Required = true,
		},
	},

	Execute = function(ctx)
		-- TODO: Remove persisted ban records.
		ctx.Services:Get("LoggingService"):Info("ADMIN", `Unban requested for {ctx.Target.Name}`)
		return true
	end,
}
