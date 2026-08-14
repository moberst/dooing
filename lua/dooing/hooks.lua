-- Status-change hooks.
--
-- `state.lua` calls in here whenever a todo starts or stops being in progress.
-- The timewarrior integration is the first consumer; `config.options.hooks` lets
-- a user configuration listen to the very same events.
local vim = vim

local M = {}
local config = require("dooing.config")
local timewarrior = require("dooing.timewarrior")

-- Runs a user-supplied callback, keeping a broken config out of the todo
-- mutation path
local function user_hook(name, todo, context, reason)
	local hooks = config.options.hooks
	local fn = type(hooks) == "table" and hooks[name] or nil
	if type(fn) ~= "function" then
		return
	end

	local ok, err = pcall(fn, todo, context, reason)
	if not ok then
		vim.notify("dooing: `hooks." .. name .. "` failed: " .. tostring(err), vim.log.levels.ERROR)
	end
end

---A todo just became in progress
---@param todo table
---@param context table|nil `{ project = <string|nil> }`
function M.on_start(todo, context)
	timewarrior.start(todo, context)
	user_hook("on_start", todo, context, "start")
end

---A todo just stopped being in progress
---@param todo table
---@param context table|nil `{ project = <string|nil> }`
---@param reason string|nil "done" | "switch" | "delete"
function M.on_stop(todo, context, reason)
	timewarrior.stop(todo, context, reason)
	user_hook("on_stop", todo, context, reason or "done")
end

---Whether only one todo may be in progress at a time
---@return boolean
function M.single_active()
	return timewarrior.single_active()
end

---Re-reads anything the hooks cached about the environment. Called from
---`dooing.setup()`, so re-sourcing a configuration picks up a timewarrior that
---was installed after the first probe.
function M.reset()
	timewarrior.reset()
end

return M
