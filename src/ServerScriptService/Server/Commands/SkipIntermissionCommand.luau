--!strict

return {
	Name = "skipintermission",
	Aliases = { "skip" },
	Permission = "RoundControl",
	Description = "Starts the next round immediately.",
	Execute = function(context)
		return context.Services:Get("RoundManager"):StartRound()
	end,
}
