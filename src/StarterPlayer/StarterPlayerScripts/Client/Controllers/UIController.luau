--!strict

local BaseController = require(script.Parent.Parent.Framework.BaseController)

local UIController = {}
UIController.__index = UIController
setmetatable(UIController, { __index = BaseController })

function UIController.new()
	return setmetatable(BaseController.new("UIController"), UIController)
end

function UIController:Start()
	BaseController.Start(self)
	-- TODO: Create round HUD, return-to-lobby button, shop UI, inventory UI, and admin GUI entry points.
end

return UIController
