--!strict

return {
	Name = "kick",
	Aliases = {},
	Permission = "Kick",
	Description = "Kicks a player from the server.",

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
		ctx.Target:Kick(ctx.Reason or "Removed by an administrator.")
		return true
	end,
}
