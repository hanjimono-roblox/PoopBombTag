--!strict

return {
	Name = "loadmap",
	Aliases = {},
	Permission = "MapControl",
	Description = "Loads a map by name.",
	Execute = function(context)
		return context.Services:Get("MapManager"):LoadMap(context.Args[1]) ~= nil
	end,
}
