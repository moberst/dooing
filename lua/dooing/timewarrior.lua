-- Timewarrior integration.
--
-- Mirrors taskwarrior's `on-modify.timewarrior` hook: dooing's
-- pending -> in_progress -> done cycle is translated into `timew start` /
-- `timew stop` calls, so time spent on a todo lands in the same timewarrior
-- database as everything else.
local vim = vim

local M = {}
local config = require("dooing.config")

-- Latched once the configured binary turns out to be missing, so the warning is
-- not repeated on every status toggle. `M.reset()` clears it, which is what
-- `dooing.setup()` calls — re-sourcing a config re-probes for the binary.
local unavailable = false

-- todo id -> `{ tags = <string[]>, started_at = <os.time()> }` for the interval
-- that was opened. Remembering the tags means a todo whose text (and therefore
-- tags) changed while the clock was running still stops the interval it actually
-- started; timewarrior refuses a `stop` whose tags do not match the open
-- interval and leaves that interval running.
local active = {}

local function opts()
	return config.options.timewarrior or {}
end

---Clears the "binary not found" latch so that a fresh `require("dooing").setup()`
---probes for the configured command again. Intervals opened in this session are
---kept, so re-sourcing a config while tracking still stops the right interval.
function M.reset()
	unavailable = false
end

local function command()
	local cmd = opts().command
	if type(cmd) == "string" and cmd ~= "" then
		return cmd
	end
	return "timew"
end

---Whether the integration should run at all
---@return boolean
function M.enabled()
	if not opts().enabled or unavailable then
		return false
	end

	if vim.fn.executable(command()) ~= 1 then
		unavailable = true
		vim.notify(
			"dooing: timewarrior integration is enabled but `" .. command() .. "` was not found in $PATH",
			vim.log.levels.WARN
		)
		return false
	end

	return true
end

---Whether at most one todo may be in progress at a time. Timewarrior keeps a
---single open interval, so a second `timew start` silently reassigns the clock
---unless dooing stops the previous todo itself.
---@return boolean
function M.single_active()
	return M.enabled() and opts().single_active ~= false
end

-- Pending timew invocations. They are serialized because `single_active` fires a
-- stop immediately followed by a start, and `vim.system` gives no ordering
-- guarantee between two calls in flight.
local queue = {}
local running = false

local function pump()
	if running then
		return
	end

	local job = table.remove(queue, 1)
	if not job then
		return
	end

	running = true

	-- Asynchronous on purpose: a blocking call here would stall the UI on every
	-- status toggle. The argv form means tags with spaces need no quoting.
	local ok, err = pcall(vim.system, job.cmd, { text = true }, function(result)
		-- The callback runs in a fast event context, where notify is not allowed
		vim.schedule(function()
			running = false

			if result.code ~= 0 then
				local output = vim.trim(result.stderr or "")
				if output == "" then
					output = vim.trim(result.stdout or "")
				end
				vim.notify("dooing: `" .. table.concat(job.cmd, " ") .. "` failed: " .. output, job.level)
			end

			pump()
		end)
	end)

	if not ok then
		running = false
		vim.notify("dooing: could not run `" .. command() .. "`: " .. tostring(err), vim.log.levels.ERROR)
		pump()
	end
end

local function run(args, level)
	local cmd = { command() }
	vim.list_extend(cmd, args)
	table.insert(queue, { cmd = cmd, level = level })
	pump()
end

-- The interval description: the todo text without its inline `#tags`, which are
-- passed as timewarrior tags of their own
local function describe(text)
	local stripped = text:gsub("#[%w_%-/]+", " ")
	stripped = vim.trim(stripped:gsub("%s+", " "))
	if stripped == "" then
		return vim.trim(text)
	end
	return stripped
end

---Builds the tag list for a todo. Like the taskwarrior hook, the description
---comes first so that `timew summary` reads as a list of tasks.
---@param todo table
---@param context table|nil `{ project = <string|nil> }`
---@return string[]
local function build_tags(todo, context)
	local o = opts()
	local tags = {}
	local seen = {}

	local function add(tag)
		if type(tag) ~= "string" then
			return
		end
		tag = vim.trim(tag)
		if tag == "" or seen[tag] then
			return
		end
		seen[tag] = true
		table.insert(tags, tag)
	end

	local text = todo.text or ""
	add(describe(text))

	-- `tags = false` disables the always-on tags entirely; an empty table cannot
	-- be used for that because `vim.tbl_deep_extend` merges lists by index
	if type(o.tags) == "table" then
		for _, tag in ipairs(o.tags) do
			add(tag)
		end
	end

	if o.include_project ~= false and context and context.project then
		add(context.project)
	end

	if o.include_hashtags ~= false then
		for tag in text:gmatch("#([%w_%-/]+)") do
			add(tag)
		end
	end

	if o.include_priorities and type(todo.priorities) == "table" then
		for _, priority in ipairs(todo.priorities) do
			add(priority)
		end
	end

	return tags
end

---Opens a timewarrior interval for `todo`
---@param todo table
---@param context table|nil `{ project = <string|nil> }`
function M.start(todo, context)
	if not M.enabled() or type(todo) ~= "table" then
		return
	end

	local tags = build_tags(todo, context)
	if #tags == 0 then
		return
	end

	if todo.id then
		active[todo.id] = { tags = tags, started_at = os.time() }
	end

	run(vim.list_extend({ "start" }, tags), vim.log.levels.ERROR)
end

---Closes the timewarrior interval belonging to `todo`
---@param todo table
---@param context table|nil `{ project = <string|nil> }`
---@param reason string|nil "done" | "switch" | "delete"
function M.stop(todo, context, reason)
	if not M.enabled() or type(todo) ~= "table" then
		return
	end

	if reason == "delete" and opts().stop_on_delete == false then
		return
	end

	local entry = todo.id and active[todo.id] or nil
	if todo.id then
		active[todo.id] = nil
	end

	-- Timewarrior rejects an interval whose start and end fall in the same
	-- second and leaves it open, so a todo toggled straight through
	-- in-progress would keep the clock running forever. Discard it instead:
	-- there is no time worth recording either way.
	if entry and entry.started_at and os.time() - entry.started_at < 1 then
		run({ "cancel" }, vim.log.levels.DEBUG)
		return
	end

	-- Nothing recorded for this todo: it was started in an earlier session (or
	-- loaded from disk already in progress), so fall back to its current tags
	local tags = entry and entry.tags or build_tags(todo, context)

	if #tags == 0 then
		return
	end

	-- Stopping tags that match no open interval is an ordinary outcome — the
	-- user may have stopped the clock from the shell — so it is reported at
	-- debug level rather than as an error
	run(vim.list_extend({ "stop" }, tags), vim.log.levels.DEBUG)
end

return M
