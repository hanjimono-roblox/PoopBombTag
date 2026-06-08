--!strict

return {
	Name = "startround",
	Aliases = { "start" },
	Permission = "RoundControl",
	Description = "Starts a round.",
	Execute = function(context)
		return context.Services:Get("RoundManager"):StartRound(context.Args[1])
	end,
}
