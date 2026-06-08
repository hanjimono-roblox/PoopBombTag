--!strict

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local BombController = {}
BombController.__index = BombController
setmetatable(BombController, { __index = BaseController })

function BombController.new()
	return setmetatable(BaseController.new("BombController"), BombController)
end

function BombController:Start()
	BaseController.Start(self)
	-- TODO: Render bomb visuals, ticking audio, timer UI, and transfer effects from server events.
end

return BombController
