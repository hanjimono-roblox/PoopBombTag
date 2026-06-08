--!strict

return {
	Name = "loadmap",
	Aliases = {},
	Permission = "MapControl",
	Description = "Loads a map by name.",

	Arguments = {
		{
			Name = "mapId",
			Type = "string",
			Required = true,
		},
	},

	Execute = function(ctx)
		return ctx.Services:Get("MapManager"):LoadMap(ctx.mapId) ~= nil
	end,
}
