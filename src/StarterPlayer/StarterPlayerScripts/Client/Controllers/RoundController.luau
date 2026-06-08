--!strict

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local RoundController = {}
RoundController.__index = RoundController
setmetatable(RoundController, { __index = BaseController })

function RoundController.new()
	return setmetatable(BaseController.new("RoundController"), RoundController)
end

function RoundController:Start()
	BaseController.Start(self)
	-- TODO: Subscribe to server round remotes once UI messaging is introduced.
end

return RoundController
