--[[
	AI App Module

	Lets the AI in an editor (Claude Code, VS Code: anything that speaks MCP) read the game through OpenDex,
	write into its renames and notes, and run code in the game. A script in a game can only connect out,
	never listen, so OpenDex cannot be an MCP server itself: this connects out to a small relay program on
	the PC (mcp/opendex_mcp.py), which is the MCP server.

	  editor --MCP over HTTP--> relay <--WebSocket, opened here-- OpenDex

	The relay sends {type = "call", id, tool, args}; this runs the tool and answers {type = "result", id,
	ok, result | error}. The tools are registered by the modules that own the data (Agent.Register):
	ScriptViewer and RemoteSpy, and this file for the game itself (its objects, its output, what is in
	memory). A tool returns text or a table, or nil and why it could not. Most read, or write into
	OpenDex's own renames and notes. Two, coverage and trace, put the Script Viewer's hooks on functions of
	the game to count and log their calls. None of those fires a remote or turns a rule on. One more, run,
	runs what the agent wrote, in the game. The window lists every request.
]]

-- Common Locals
local Main,Lib,Settings -- Main Containers
local API,env,service,createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Settings = data.Settings

	API = data.API
	env = data.env
	service = data.service
	createSimple = data.createSimple
end

local function initAfterMain()
end

local function main()
	local Agent = {}

	local CONFIG_FILE = "dex/agent.json" -- the switch, the port and the token (not in OpenDexSettings.json: that file gets shared)
	local DEFAULT_PORT = 38211
	local MAX_REPLY = 400000 -- characters in one reply; the tools cut their own results long before this
	local LOG_KEEP = 100
	local ANSWER_KEEP = 8000 -- characters of an answer that are kept, for the window to show it again
	local MESSAGE_EVENTS = {"OnMessage", "Message", "MessageReceived"}
	local CLOSE_EVENTS = {"OnClose", "Closed"}

	-- used: an editor has reached OpenDex before (the set-up is over); editor: the one last picked in the window
	local cfg = {enabled = false, port = DEFAULT_PORT, token = "", used = false, editor = nil}
	local tools = {} -- name -> function(args) -> result | nil, why
	local entries = {} -- what was asked, newest last
	-- State: off, connecting, connected. Stage says how far the connecting got: off, looking (for the
	-- relay), norelay, reached (the relay has the token to check), refused, closed, connected. Reason:
	-- why the last try ended.
	local status = {State = "off", Text = "Off", Stage = "off"}
	local stats = {Requests = 0, Last = nil}
	local loopId, socket = 0, nil -- loopId is bumped to stop the loop that runs; socket is the open connection
	local onChange = function() end -- the window sets it
	Agent.Config, Agent.Status, Agent.Stats, Agent.Entries = cfg, status, stats, entries

	-- Nothing is offered without a WebSocket, and a reason is better than a button that does nothing
	Agent.Unavailable = function()
		return (env.websocket == nil and "Your executor has no WebSocket") or nil
	end

	----------------------------------------------------------------------------------------------
	-- Scripts get ids (s17): a path is not unique in Roblox, and a script can be parented to nil
	----------------------------------------------------------------------------------------------

	local idOf = setmetatable({}, {__mode = "k"})
	local byId = setmetatable({}, {__mode = "v"})
	local lastId = 0

	Agent.IdOf = function(inst)
		local id = idOf[inst]
		if not id then
			lastId = lastId + 1
			id = "s"..lastId
			idOf[inst], byId[id] = id, inst
		end
		return id
	end

	Agent.Lookup = function(id)
		return byId[id]
	end

	----------------------------------------------------------------------------------------------
	-- Making a result fit in JSON: valid text, no Instances or functions, no loops, a limit on size
	----------------------------------------------------------------------------------------------

	local function validText(s)
		if utf8.len(s) then return s end
		local out, i = {}, 1
		while i <= #s do
			local ok, bad = utf8.len(s, i)
			if ok then
				out[#out+1] = s:sub(i)
				break
			end
			out[#out+1] = s:sub(i, bad - 1)
			out[#out+1] = "\u{FFFD}"
			i = bad + 1
		end
		return table.concat(out)
	end
	Agent.ValidText = validText

	local function clean(v, depth, seen, budget)
		local kind = type(v)
		if kind == "string" then
			return validText(v)
		elseif kind == "number" then
			if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
			return v
		elseif kind == "boolean" or kind == "nil" then
			return v
		elseif kind == "table" then
			if depth > 8 or seen[v] then return "..." end
			seen[v] = true
			local out = {}
			if #v > 0 then
				for i = 1, #v do
					budget.n = budget.n + 1
					if budget.n > 20000 then break end
					out[i] = clean(v[i], depth + 1, seen, budget)
				end
			else
				for k, value in pairs(v) do
					budget.n = budget.n + 1
					if budget.n > 20000 then break end
					out[validText(tostring(k))] = clean(value, depth + 1, seen, budget)
				end
			end
			seen[v] = nil
			return out
		elseif typeof(v) == "Instance" then
			local ok, name = pcall(v.GetFullName, v)
			return ok and validText(name) or tostring(v)
		end
		return validText(tostring(v))
	end

	Agent.Clean = function(value)
		return clean(value, 0, {}, {n = 0})
	end

	----------------------------------------------------------------------------------------------
	-- The tools
	----------------------------------------------------------------------------------------------

	-- run(args) returns a string or a table, or nil and why it could not. error(text, 0) works too.
	Agent.Register = function(name, run)
		tools[name] = run
	end

	Agent.ToolNames = function()
		local names = {}
		for name in pairs(tools) do names[#names+1] = name end
		table.sort(names)
		return names
	end

	local reg = Agent.Register

	----------------------------------------------------------------------------------------------
	-- The game itself: its objects, its output, what is in memory, and code the agent wrote. (The
	-- scripts are the Script Viewer's to answer for, the remotes the Remote Spy's.)
	----------------------------------------------------------------------------------------------

	local function clip(text, max)
		return #text > max and (text:sub(1, max).."... ("..(#text - max).." more characters)") or text
	end

	-- A property, or nil where it can't be read
	local function read(inst, prop)
		local ok, value = pcall(function() return inst[prop] end)
		if ok then return value end
		return nil
	end

	local function classOf(inst)
		return inst.ClassName
	end

	local function fullName(inst)
		if inst == game then return "game" end
		local ok, name = pcall(inst.GetFullName, inst)
		return ok and name or tostring(inst)
	end

	-- A function as debug.info has it, with the id of its script when it belongs to one
	local function functionInfo(f)
		local ok, source, line, name = pcall(debug.info, f, "sln")
		local info = {name = (ok and name ~= "" and name) or "anonymous", source = ok and source or nil, runtimeLine = ok and line or nil}
		local okScript, scr = pcall(function() return getfenv(f).script end)
		if okScript and typeof(scr) == "Instance" then info.script = Agent.IdOf(scr) end
		return info
	end

	-- A value as Luau code, cut at max characters
	local function show(value, max)
		if type(value) == "function" then
			local info = functionInfo(value)
			return ("function %s (%s:%s)"):format(info.name, tostring(info.source), tostring(info.runtimeLine))
		end
		local ok, code = pcall(Lib.ToLua, value)
		return clip(ok and code or tostring(value), max)
	end
	Agent.Show = show

	-- The object a path names: Workspace.Map.Door, as the tools print paths (game. in front and
	-- game:GetService("Workspace") are understood too). A part of the path may be a property that holds
	-- an object (Players.LocalPlayer.Character), and a name with a dot in it is found as its parts joined.
	local function instanceAt(path)
		if type(path) ~= "string" or path == "" then error("path is needed, for example Workspace.Map.Door", 0) end
		local parts = path:gsub(':GetService%(%s*"([^"]+)"%s*%)', ".%1"):split(".")
		if parts[1] == "game" then table.remove(parts, 1) end
		if parts[1] == "workspace" then parts[1] = "Workspace" end
		local at, i = game, 1
		while i <= #parts do
			local found
			for j = i, #parts do
				local name = table.concat(parts, ".", i, j)
				local ok, child = pcall(at.FindFirstChild, at, name)
				found = ok and child or nil
				if not found and j == i then
					local value = read(at, name)
					if typeof(value) == "Instance" then found = value end
				end
				if not found and j == i and at == game then
					local okService, serv = pcall(game.FindService, game, name)
					found = okService and serv or nil
				end
				if found then
					i = j + 1
					break
				end
			end
			if not found then error(("nothing is at '%s': %s has nothing called '%s'"):format(path, fullName(at), parts[i]), 0) end
			at = found
		end
		return at
	end

	local function playerInfo()
		local player = service.Players.LocalPlayer
		local out = {name = player.Name, displayName = read(player, "DisplayName"), userId = read(player, "UserId"), path = fullName(player)}
		local character = read(player, "Character")
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local rootPart = character:FindFirstChild("HumanoidRootPart")
			out.character = {path = fullName(character), health = humanoid and humanoid.Health, maxHealth = humanoid and humanoid.MaxHealth, position = rootPart and show(rootPart.Position, 100)}
		end
		return out
	end

	local SCRIPTS = {LocalScript = true, ModuleScript = true, Script = true}
	local REMOTES = {RemoteEvent = true, UnreliableRemoteEvent = true, RemoteFunction = true}
	local function countObjects()
		local out = {objects = 0, scripts = 0, remotes = 0, players = #service.Players:GetPlayers()}
		for _, inst in ipairs(game:GetDescendants()) do
			local ok, class = pcall(classOf, inst)
			out.objects = out.objects + 1
			if ok and SCRIPTS[class] then
				out.scripts = out.scripts + 1
			elseif ok and REMOTES[class] then
				out.remotes = out.remotes + 1
			end
		end
		return out
	end

	reg("status", function()
		local okPlayer, player = pcall(playerInfo)
		local okCounts, counts = pcall(countObjects)
		return {
			opendex = Main.Version, executor = Main.Executor, place = game.PlaceId, gameId = read(game, "GameId"), server = read(game, "JobId"),
			player = okPlayer and player or nil,
			counts = okCounts and counts or nil,
			features = {
				decompile = env.isdecompile and env.isdecompile() or false,
				remoteHooks = env.hookmetamethod ~= nil and env.getnamecallmethod ~= nil,
				hookfunction = env.hookfunction ~= nil,
				getgc = env.getgc ~= nil,
				getconnections = env.getconnections ~= nil,
				loadstring = env.loadstring ~= nil,
				filesystem = env.writefile ~= nil and env.readfile ~= nil,
				clipboard = env.setclipboard ~= nil,
			},
			requests = stats.Requests,
			tools = Agent.ToolNames(),
		}
	end)

	reg("instances", function(args)
		local root = args.path ~= nil and instanceAt(args.path) or game
		local limit = math.clamp(math.floor(tonumber(args.limit) or 50), 1, 200)
		local query = type(args.query) == "string" and args.query ~= "" and args.query:lower() or nil
		local class = type(args.class) == "string" and args.class ~= "" and args.class or nil

		-- a search under the object
		if query or class then
			local function matches(inst)
				return (not class or inst:IsA(class)) and (not query or inst.Name:lower():find(query, 1, true) ~= nil)
			end
			local out, total = {}, 0
			for _, inst in ipairs(root:GetDescendants()) do
				local ok, hit = pcall(matches, inst)
				if ok and hit then
					total = total + 1
					if #out < limit then
						out[#out+1] = {path = fullName(inst), class = inst.ClassName, script = inst:IsA("LuaSourceContainer") and Agent.IdOf(inst) or nil}
					end
				end
			end
			return {under = fullName(root), total = total, shown = #out, objects = out}
		end

		-- the object itself: what the Properties window shows of it, and its children
		local lines = {("%s (%s)%s"):format(fullName(root), root.ClassName, root:IsA("LuaSourceContainer") and (", script "..Agent.IdOf(root)) or "")}
		local function list(title, rows)
			if #rows == 0 then return end
			table.sort(rows)
			lines[#lines+1] = title
			for _, row in ipairs(rows) do lines[#lines+1] = "  "..row end
		end

		local props, cls = {}, API.Classes[root.ClassName]
		while cls do
			for _, prop in ipairs(cls.Properties) do
				if not (prop.Tags.Deprecated or prop.Tags.Hidden) then
					local ok, value = pcall(function() return root[prop.Name] end)
					if ok then props[#props+1] = prop.Name.." = "..show(value, 300) end
				end
			end
			cls = cls.Superclass
		end
		list("Properties:", props)

		local attributes = {}
		local okAttributes, found = pcall(root.GetAttributes, root)
		for name, value in pairs(okAttributes and found or {}) do attributes[#attributes+1] = tostring(name).." = "..show(value, 300) end
		list("Attributes:", attributes)

		local okTags, tags = pcall(root.GetTags, root)
		if okTags and #tags > 0 then lines[#lines+1] = "Tags: "..table.concat(tags, ", ") end

		local children = root:GetChildren()
		if #children > 0 then
			lines[#lines+1] = #children > limit and ("Children (the first %d of %d):"):format(limit, #children) or ("Children (%d):"):format(#children)
			for i = 1, math.min(#children, limit) do
				local child = children[i]
				local inside = #child:GetChildren()
				lines[#lines+1] = ("  %s (%s%s)"):format(child.Name, child.ClassName, inside > 0 and (", "..inside.." inside") or "")
			end
		end
		return table.concat(lines, "\n")
	end)

	local LEVELS = {MessageOutput = "output", MessageInfo = "info", MessageWarning = "warn", MessageError = "error"}

	reg("console", function(args)
		local ok, history = pcall(function() return service.LogService:GetLogHistory() end)
		if not ok or type(history) ~= "table" then error("the game's output could not be read", 0) end
		local limit = math.clamp(math.floor(tonumber(args.limit) or 50), 1, 200)
		local query = type(args.query) == "string" and args.query ~= "" and args.query:lower() or nil
		local lines, total = {}, 0
		for i = #history, 1, -1 do
			local entry = history[i]
			local level = LEVELS[entry.messageType.Name] or "output"
			local message = tostring(entry.message)
			if (args.level == nil or args.level == level) and (not query or message:lower():find(query, 1, true)) then
				total = total + 1
				if #lines < limit then lines[#lines+1] = ("%s [%s] %s"):format(os.date("%H:%M:%S", entry.timestamp), level, clip(message, 500)) end
			end
		end
		-- (gathered newest first; listed oldest first, as the Console has them)
		for i = 1, math.floor(#lines / 2) do lines[i], lines[#lines - i + 1] = lines[#lines - i + 1], lines[i] end
		return ("%d of %d messages, oldest first\n%s"):format(#lines, total, table.concat(lines, "\n"))
	end)

	-- What listens to an object's events: the events that have listeners, or one event's listeners
	local function connections(inst, signalName, limit)
		if not env.getconnections then error("Your executor has no getconnections", 0) end
		if signalName == nil then
			local events, cls = {}, API.Classes[inst.ClassName]
			while cls do
				for _, event in ipairs(cls.Events) do
					local ok, conns = pcall(function() return env.getconnections(inst[event.Name]) end)
					if ok and #conns > 0 then events[#events+1] = {signal = event.Name, connections = #conns} end
				end
				cls = cls.Superclass
			end
			table.sort(events, function(a, b) return a.signal < b.signal end)
			return {path = fullName(inst), events = events}
		end

		local signal = read(inst, signalName)
		if typeof(signal) ~= "RBXScriptSignal" then error(("%s has no event called '%s'"):format(fullName(inst), tostring(signalName)), 0) end
		local conns = env.getconnections(signal)
		local out = {}
		for i = 1, math.min(#conns, limit) do
			local f = read(conns[i], "Function")
			-- (no function to read: the listener is in an Actor, or is not Luau)
			local entry = type(f) == "function" and functionInfo(f) or {foreign = true}
			entry.enabled = read(conns[i], "Enabled")
			if type(f) == "function" and env.isexecutorclosure then
				local ok, own = pcall(env.isexecutorclosure, f)
				entry.executor = (ok and own == true) or nil
			end
			out[i] = entry
		end
		return {path = fullName(inst), signal = signalName, total = #conns, connections = out}
	end

	-- A table in memory is shown one level deep: writing it out in full would call into the game's own
	-- metamethods, for a table nobody asked about
	local function brief(value)
		return type(value) == "table" and "a table" or show(value, 80)
	end

	-- The garbage collector's functions whose name or script has the text, and its tables that have a
	-- key with it. A few thousand objects at a time, so the game keeps drawing.
	local function searchMemory(query, kind, limit)
		if not env.getgc then error("Your executor has no getgc", 0) end
		local want = query:lower()
		local out, total, seen, slice = {}, 0, 0, os.clock()
		for _, v in pairs(env.getgc(true)) do
			local t = type(v)
			if t == "function" and kind ~= "table" then
				local ok, source, name = pcall(debug.info, v, "sn")
				if ok and source ~= "[C]" and (name:lower():find(want, 1, true) or tostring(source):lower():find(want, 1, true)) then
					local okOwn, own = pcall(env.isexecutorclosure or error, v)
					if not (okOwn and own == true) then -- (the executor's and OpenDex's own are left out)
						total = total + 1
						if #out < limit then
							local info = functionInfo(v)
							info.kind = "function"
							out[#out+1] = info
						end
					end
				end
			elseif t == "table" and kind ~= "function" then
				-- ponytail: the first 300 keys of a table are looked at; raise it if a key of a huge table is missed
				local hits, looked = nil, 0
				for k in next, v do
					looked = looked + 1
					if looked > 300 then break end
					if type(k) == "string" and k:lower():find(want, 1, true) then
						hits = hits or {}
						if #hits < 8 then hits[#hits+1] = k end
					end
				end
				if hits then
					total = total + 1
					if #out < limit then
						for i, k in ipairs(hits) do hits[i] = clip(k, 60).." = "..brief(rawget(v, k)) end
						out[#out+1] = {kind = "table", keys = hits}
					end
				end
			end
			seen = seen + 1
			if seen % 2000 == 0 and os.clock() - slice > 0.01 then
				task.wait()
				slice = os.clock()
			end
		end
		return {query = query, total = total, shown = #out, objects = out}
	end

	reg("memory", function(args)
		local limit = math.clamp(math.floor(tonumber(args.limit) or 30), 1, 100)
		if args.path ~= nil then return connections(instanceAt(args.path), args.signal, limit) end
		if type(args.query) ~= "string" or args.query == "" then error("give a query to search the memory for, or a path for an object's connections", 0) end
		return searchMemory(args.query, args.kind, limit)
	end)

	-- Code the agent wrote, run in the game like a line typed into the Console. What it prints is kept
	-- for the answer as well as printed.
	reg("run", function(args)
		if not env.loadstring then error("Your executor has no loadstring", 0) end
		local code = args.code
		if type(code) ~= "string" or not code:find("%S") then error("code is needed", 0) end
		local timeout = math.clamp(math.floor(tonumber(args.timeout) or 10), 1, 100)

		local fn, why = env.loadstring("return "..code, "=AI") -- (an expression: its value is the answer)
		if not fn then fn, why = env.loadstring(code, "=AI") end
		if not fn then error("it does not compile: "..tostring(why), 0) end

		local printed = {}
		local function keep(real)
			return function(...)
				local parts = table.pack(...)
				for i = 1, parts.n do parts[i] = tostring(parts[i]) end
				if #printed < 200 then printed[#printed+1] = table.concat(parts, " ", 1, parts.n) end
				return real(...)
			end
		end
		local globals = getfenv(fn)
		setfenv(fn, setmetatable({print = keep(print), warn = keep(warn)}, {__index = globals, __newindex = globals}))

		local done, results = false, nil
		local thread = task.spawn(function()
			results = table.pack(xpcall(fn, function(err) return debug.traceback(tostring(err), 2) end))
			done = true
		end)
		-- (Disconnect bumps loopId: cutting the AI off also stops what it is still running)
		local started, mine = os.clock(), loopId
		while not done and loopId == mine and os.clock() - started < timeout do task.wait(0.05) end

		local output = #printed > 0 and ("\nPrinted:\n"..clip(table.concat(printed, "\n"), 20000)) or ""
		if not done then
			pcall(task.cancel, thread)
			local how = loopId ~= mine and "it was stopped, because OpenDex was disconnected" or ("it was still running after %d seconds and was stopped"):format(timeout)
			error(how.." (what it started with task.spawn runs on)"..clip(output, 400), 0)
		end
		if not results[1] then error(clip(tostring(results[2]), 1500)..clip(output, 400), 0) end

		local count = results.n - 1
		local lines = {count == 0 and "It ran and returned nothing." or ("It returned %d value%s:"):format(count, count == 1 and "" or "s")}
		for i = 1, count do
			local value = results[i + 1]
			lines[#lines+1] = ("%d (%s): %s"):format(i, typeof(value), show(value, 20000))
		end
		return clip(table.concat(lines, "\n"), 60000)..output
	end)

	-- A short account of a request for the window
	local function summarize(args)
		local parts = {}
		for _, key in ipairs({"action", "script", "remote", "path", "query", "mode", "class", "signal", "level", "kind", "name", "member", "line", "from", "to", "direction", "has", "sort", "unused", "limit"}) do
			if args[key] ~= nil then parts[#parts+1] = key.."="..tostring(args[key]):sub(1, 40) end
		end
		if type(args.names) == "table" then parts[#parts+1] = "names="..#args.names end
		if type(args.text) == "string" then parts[#parts+1] = "text="..#args.text.." characters" end
		if type(args.when) == "string" then parts[#parts+1] = "when" end
		if type(args.code) == "string" then parts[#parts+1] = args.code:gsub("%s+", " "):gsub("^ ", ""):sub(1, 120) end -- (run: the start of the code, on one line)
		return table.concat(parts, " ")
	end

	-- The tools that change something: the window marks them and can list them alone. (tests/agent.lua
	-- holds this to the tools that mcp/tools.json does not call readOnly.)
	local CHANGES = {run = true, apply_names = true, note = true, open = true, suggest_rule = true, coverage = true, trace = true}
	Agent.Changes = CHANGES

	local function jsonEncode(value)
		return service.HttpService:JSONEncode(value)
	end

	-- The switch, the port and the token, and what the window remembers
	local function save()
		if not env.writefile then return end
		local ok, json = pcall(jsonEncode, {enabled = cfg.enabled, port = cfg.port, token = cfg.token, used = cfg.used, editor = cfg.editor})
		if ok then pcall(env.writefile, CONFIG_FILE, json) end
	end

	local function record(entry)
		entries[#entries+1] = entry
		if #entries > LOG_KEEP then table.remove(entries, 1) end
		stats.Requests, stats.Last = stats.Requests + 1, os.clock()
		if not cfg.used then
			cfg.used = true
			save()
		end
		onChange()
	end

	-- Runs one tool and answers the relay. (Its own thread: a tool may wait, to decompile say.) The
	-- request is listed from its start, so that code that runs for a while is seen running.
	local function runCall(ws, msg)
		local id, name = msg.id, msg.tool
		local args = type(msg.args) == "table" and msg.args or {}
		local started = os.clock()
		local ok, result, why = false, nil, nil
		local entry = {At = os.time(), Started = started, Tool = tostring(name), Args = summarize(args), Request = args, Pending = true,
			Kind = (name == "run" and "run") or (CHANGES[name] and "write") or "read"}
		record(entry)

		local run = type(name) == "string" and tools[name]
		if not run then
			why = "OpenDex has no tool called "..tostring(name)
		else
			local success, a, b = pcall(run, args)
			if not success then
				why = tostring(a)
			elseif a == nil then
				why = b or "the tool had nothing to return"
			else
				ok, result = true, a
			end
		end

		local reply = {type = "result", id = id, ok = ok}
		if ok then
			reply.result = Agent.Clean(result)
		else
			reply.error = validText(tostring(why)):sub(1, 2000)
		end
		local good, text = pcall(jsonEncode, reply)
		if good and #text > MAX_REPLY then
			ok, why = false, ("the result is too large (%d characters): ask for less"):format(#text)
		elseif not good then
			ok, why = false, "the result could not be written as JSON: "..tostring(text)
		end
		if not ok then
			text = jsonEncode({type = "result", id = id, ok = false, error = validText(tostring(why)):sub(1, 2000)})
		end
		pcall(function() ws:Send(text) end)

		entry.Pending, entry.Ok, entry.Ms, entry.Size, entry.Error = nil, ok, math.floor((os.clock() - started) * 1000 + 0.5), #text, (not ok) and tostring(why) or nil
		-- (the answer is kept while it is short, a long text as its start)
		if ok and #text <= ANSWER_KEEP then
			entry.Answer = reply.result
		elseif ok and type(reply.result) == "string" then
			entry.Answer = clip(reply.result, ANSWER_KEEP)
		end
		onChange()
	end
	Agent.RunCall = runCall

	----------------------------------------------------------------------------------------------
	-- A request as the window shows it in full
	----------------------------------------------------------------------------------------------

	local function bytes(n)
		return n < 1000 and (n.." B") or ("%.1f kB"):format(n / 1000)
	end

	-- What was asked, as Luau: run's code as it is, another tool as a call with its arguments
	Agent.RequestText = function(entry)
		local args = entry.Request
		if entry.Tool == "run" and type(args.code) == "string" then
			return (args.timeout ~= nil and ("-- timeout: "..tostring(args.timeout).." seconds\n") or "")..args.code
		end
		local ok, written = pcall(Lib.ToLua, args)
		return entry.Tool.." "..(ok and written or "{}")
	end

	-- What came back: the text a tool gave, a table as Luau, or why there is nothing
	Agent.AnswerText = function(entry)
		if entry.Pending then return "Still running." end
		if not entry.Ok then return tostring(entry.Error) end
		local answer = entry.Answer
		if answer == nil then return ("The answer was %s: too long to keep here."):format(bytes(entry.Size)) end
		if type(answer) == "string" then return answer end
		local ok, written = pcall(Lib.ToLua, answer)
		return ok and written or "?"
	end

	-- Both, for the code frame: the request as code, and the answer in comments under it
	Agent.FullText = function(entry)
		local how = entry.Pending and "running" or ((entry.Ok and "" or "failed, ")..entry.Ms.." ms, "..bytes(entry.Size))
		local says = (entry.Pending and "" or (entry.Ok and "Answer:\n" or "Failed:\n"))..Agent.AnswerText(entry)
		return ("-- %s   %s   %s\n%s\n\n-- %s"):format(os.date("%H:%M:%S", entry.At), entry.Tool, how, Agent.RequestText(entry), (says:gsub("\n", "\n-- ")))
	end

	----------------------------------------------------------------------------------------------
	-- The connection to the relay
	----------------------------------------------------------------------------------------------

	-- (a stage or a reason that is not given stays: the next try for a relay that is not there does not
	-- take back what the last one found)
	local function setStatus(state, text, stage, reason)
		status.State, status.Text, status.Stage, status.Reason = state, text, stage or status.Stage, reason or status.Reason
		onChange()
	end

	-- The first of an object's events that is there (executors name them alike, not the same)
	local function eventOf(ws, names)
		for _, name in ipairs(names) do
			local ok, event = pcall(function() return ws[name] end)
			if ok and event ~= nil and type(event) ~= "function" then
				local hasConnect, connect = pcall(function() return event.Connect end)
				if hasConnect and connect then return event end
			end
		end
		return nil
	end

	local function closeSocket()
		local ws = socket
		socket = nil
		if ws then pcall(function() ws:Close() end) end
	end

	-- One connection, from the hello to its end. Returns why it ended, and the stage that is.
	local function session(ws, my)
		local closed, refused = false, nil
		local lastPong, lastPing = os.clock(), os.clock()
		local onMessage, onClose = eventOf(ws, MESSAGE_EVENTS), eventOf(ws, CLOSE_EVENTS)
		if not onMessage then
			pcall(function() ws:Close() end)
			return "this executor's WebSocket has no message event (looked for "..table.concat(MESSAGE_EVENTS, ", ")..")", "closed"
		end

		local connections = {}
		connections[1] = onMessage:Connect(function(raw)
			local ok, msg = pcall(function() return service.HttpService:JSONDecode(raw) end)
			if not (ok and type(msg) == "table") then return end
			lastPong = os.clock() -- anything from the relay shows it is there
			if msg.type == "call" then
				task.spawn(runCall, ws, msg)
			elseif msg.type == "welcome" then
				setStatus("connected", "Connected to the relay", "connected")
				Main.Notify("The AI relay is connected", "success")
			elseif msg.type == "error" then
				refused = tostring(msg.message or "the relay refused the connection")
			end
		end)
		if onClose then
			connections[2] = onClose:Connect(function() closed = true end)
		end

		socket = ws
		-- (a token that was refused stays refused while it is tried again, until the relay takes it)
		setStatus("connecting", "Reached the relay on 127.0.0.1:"..cfg.port..", waiting for it to accept the token", status.Stage ~= "refused" and "reached" or nil)
		local sent = pcall(function()
			ws:Send(jsonEncode({type = "hello", token = cfg.token, version = Main.Version, executor = Main.Executor or "unknown", place = game.PlaceId, tools = Agent.ToolNames()}))
		end)
		if not sent then closed = true end

		while loopId == my and not closed and not refused do
			task.wait(0.5)
			local t = os.clock()
			if t - lastPing >= 20 then
				lastPing = t
				pcall(function() ws:Send(jsonEncode({type = "ping"})) end)
			end
			if t - lastPong > 50 then
				closed = true -- no word from the relay for a long while: it is gone
			end
		end

		for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
		if socket == ws then socket = nil end
		pcall(function() ws:Close() end)
		if status.State == "connected" and loopId == my then Main.Notify("The AI relay disconnected", "info") end
		return refused or (closed and "the connection closed") or nil, refused and "refused" or "closed"
	end

	local function runLoop(my)
		local delay = 1
		while loopId == my do
			local port = cfg.port
			setStatus("connecting", "Looking for the relay on 127.0.0.1:"..port)
			local ok, ws = pcall(env.websocket, "ws://127.0.0.1:"..port.."/game")
			if loopId ~= my then
				if ok and ws then pcall(function() ws:Close() end) end
				return
			end
			local reason, stage
			if ok and ws then
				reason, stage = session(ws, my)
				delay = 1
			else
				reason, stage = "the relay is not running", "norelay"
			end
			if loopId ~= my then return end
			reason = reason or "the connection ended"
			setStatus("connecting", ("Not connected: %s (127.0.0.1:%d). Trying again.%s"):format(reason, port, cfg.token == "" and " Paste the relay's token below." or ""), stage, reason)
			local waited = 0
			while loopId == my and waited < delay do
				task.wait(0.5)
				waited = waited + 0.5
			end
			delay = math.min(delay * 2, 15)
		end
	end

	Agent.Stop = function()
		loopId = loopId + 1
		closeSocket()
		setStatus("off", "Off", "off")
	end

	Agent.Start = function()
		local why = Agent.Unavailable()
		if why then
			setStatus("off", why, "off")
			return false, why
		end
		loopId = loopId + 1
		closeSocket()
		status.Stage, status.Reason = "looking", nil
		task.spawn(runLoop, loopId)
		return true
	end

	-- The switch: remembered, and acted on
	Agent.SetEnabled = function(on)
		cfg.enabled = on and true or false
		save()
		if cfg.enabled then return Agent.Start() end
		Agent.Stop()
		return true
	end

	-- A change of port or token while connected: connect again with it
	local function reconnect()
		if cfg.enabled then Agent.Start() end
	end

	local function loadConfig()
		local raw = Lib.ReadFile(CONFIG_FILE)
		if not raw then return end
		local ok, data = pcall(function() return service.HttpService:JSONDecode(raw) end)
		if not (ok and type(data) == "table") then return end
		if type(data.enabled) == "boolean" then cfg.enabled = data.enabled end
		if type(data.port) == "number" and data.port >= 1024 and data.port <= 65535 then cfg.port = math.floor(data.port) end
		if type(data.token) == "string" then cfg.token = data.token end
		cfg.used = data.used == true
		if type(data.editor) == "string" then cfg.editor = data.editor end
	end

	-- OpenDex is being reloaded: the connection closes (the next OpenDex opens its own)
	Agent.Unload = function()
		loopId = loopId + 1
		closeSocket()
	end

	----------------------------------------------------------------------------------------------
	-- What to give an editor
	----------------------------------------------------------------------------------------------

	Agent.Url = function()
		return "http://127.0.0.1:"..cfg.port.."/mcp"
	end

	-- Every editor wants the URL and the token, each in its own words: Text takes them in that order.
	-- The relay's banner (mcp/opendex_mcp.py) and mcp/README.md give the same texts.
	Agent.Editors = {
		{Name = "Claude Code", Where = "into a terminal (VS Code's terminal works)", Text = 'claude mcp add --scope user --transport http opendex %s --header "Authorization: Bearer %s"'},
		{Name = "VS Code (Copilot)", Where = "into .vscode/mcp.json", Text = '{"servers": {"opendex": {"type": "http", "url": "%s", "headers": {"Authorization": "Bearer %s"}}}}'},
		-- (the line break at each end keeps the block apart from what the file has already, whether or not its last line is ended)
		{Name = "Codex", Where = "at the end of ~/.codex/config.toml", Text = '\n[mcp_servers.opendex]\nurl = "%s"\nhttp_headers = { "Authorization" = "Bearer %s" }\n'},
		{Name = "Cursor", Where = "into ~/.cursor/mcp.json", Text = '{"mcpServers": {"opendex": {"url": "%s", "headers": {"Authorization": "Bearer %s"}}}}'},
		{Name = "Antigravity", Where = "into ~/.gemini/config/mcp_config.json", Text = '{"mcpServers": {"opendex": {"serverUrl": "%s", "headers": {"Authorization": "Bearer %s"}}}}'},
		{Name = "opencode", Where = "into ~/.config/opencode/opencode.json", Text = '{"mcp": {"opendex": {"type": "remote", "url": "%s", "oauth": false, "headers": {"Authorization": "Bearer %s"}}}}'},
	}

	Agent.SetupText = function(editor)
		return editor.Text:format(Agent.Url(), cfg.token ~= "" and cfg.token or "TOKEN")
	end

	----------------------------------------------------------------------------------------------
	-- The window. At the top, always: whether the AI can reach OpenDex, in a word and a line, and the
	-- one switch. Under it two pages. Activity is what the AI asked, newest first, with the request
	-- that is picked in full: this is where the user reads what was run in their game. Set up is the
	-- three steps, each saying by itself whether it is done.
	----------------------------------------------------------------------------------------------

	Agent.Init = function()
		local theme = Settings.Theme
		local ROW_H, TOP, INDENT = 20, 74, 26 -- a row of the list; where the pages start, under the status and the tabs; what belongs to a step sits this far in
		local window = Lib.Window.new()
		window:SetTitle("AI")
		window:SetLayoutId("AI")
		window:Resize(440, 480)
		window.MinX = 300 -- (a side panel's width: it still fits docked)
		Agent.Window = window
		local content = window.GuiElems.Content

		loadConfig()
		-- (an editor that has reached OpenDex before needs no setting up: the window opens on what the AI does)
		local tab = (cfg.enabled and cfg.used) and "Activity" or "Set up"
		local filter, picked, hovered = "All", nil, nil -- the chip that is on, the request shown in full, the row under the mouse
		local drawn, drawnPending = false, nil -- what the code frame holds
		local rows, steps, pages, tabs = {}, {}, {}, {}
		local dirty, sinceDrawn = true, 0
		local render

		local function label(parent, text, position, size, color)
			return createSimple("TextLabel", {
				BackgroundTransparency = 1,
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = color,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = text,
				Position = position,
				Size = size,
				Parent = parent,
			})
		end

		local function button(parent, text, tip, position, size, onClick)
			local btn = Lib.Button.new()
			btn.Text = text
			btn.Position = position
			btn.Size = size
			btn.Gui.Parent = parent
			btn.OnClick:Connect(onClick)
			Lib.Tooltip.attach(btn.Gui, tip)
			return btn
		end

		-- A button that is a tab is lit while its page shows
		local function lit(btn, on)
			btn.Anim.StartColor = on and theme.ListSelection or theme.Button
			btn.BackgroundColor3 = btn.Anim.StartColor
		end

		local function ago(t)
			local s = math.floor(os.clock() - t)
			return s < 60 and (s.." s") or (math.floor(s / 60).." min")
		end

		local function copy(what, text)
			if not env.setclipboard then
				Main.Notify("Your executor has no setclipboard", "warn")
				return
			end
			env.setclipboard(text)
			Main.Notify("Copied "..what, "success")
		end

		-- The status: a dot, the state in a word, under it what to do about it or what the AI is doing, and the switch
		local dot = createSimple("Frame", {Name = "Dot", BackgroundColor3 = theme.ReadOnlyText, BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 10), Size = UDim2.new(0, 10, 0, 10), Parent = content})
		createSimple("UICorner", {CornerRadius = UDim.new(1, 0), Parent = dot})
		local headline = label(content, "", UDim2.new(0, 28, 0, 4), UDim2.new(1, -134, 0, 20), theme.Text)
		headline.Name, headline.Font, headline.TextSize = "Headline", Enum.Font.SourceSansBold, 15
		local detail = label(content, "", UDim2.new(0, 28, 0, 23), UDim2.new(1, -134, 0, 18), theme.ReadOnlyText)
		detail.Name, detail.TextSize = "Detail", 13
		Lib.Tooltip.attach(detail, function() return detail.Text end)
		local connect = button(content, "", function()
			return Agent.Unavailable() or (cfg.enabled and "Stops the AI in your editor from reaching OpenDex" or "Connects to the relay program on this PC. It is remembered between sessions.")
		end, UDim2.new(1, -98, 0, 9), UDim2.new(0, 90, 0, 24), function()
			local ok, why = Agent.SetEnabled(not cfg.enabled)
			if not ok then Main.Notify(why, "warn") end
			render()
		end)
		connect.Gui.Name = "Connect"

		for i, name in ipairs({"Activity", "Set up"}) do
			tabs[name] = button(content, name, name == "Activity" and "What the AI asked, and any request in full" or "The three steps that let your editor's AI reach this game", UDim2.new(0, 8 + (i - 1) * 100, 0, 44), UDim2.new(0, 96, 0, 22), function()
				tab = name
				render()
			end)
		end
		createSimple("Frame", {BackgroundColor3 = theme.Outline2, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, 69), Size = UDim2.new(1, 0, 0, 1), Parent = content})

		----------------------------------------------------------------------------------------------
		-- Activity: the chips, the list they narrow, and under it the request that is picked
		----------------------------------------------------------------------------------------------

		local activity = createSimple("Frame", {Name = "Activity", BackgroundTransparency = 1, Position = UDim2.new(0, 6, 0, TOP), Size = UDim2.new(1, -12, 1, -(TOP + 6)), Parent = content})
		pages["Activity"] = activity

		local FILTERS = {
			{Name = "All", Has = function() return true end, Tip = "Every request"},
			{Name = "Changes", Has = function(entry) return entry.Kind ~= "read" end, None = "The AI has changed nothing.", Tip = "Only what ran code, wrote something or hooked the game's functions: run, apply_names, note, open, suggest_rule, coverage and trace"},
			{Name = "Failed", Has = function(entry) return entry.Ok == false end, None = "Nothing has failed.", Tip = "Only the requests that failed"},
		}
		local chipBar = createSimple("Frame", {Name = "Chips", BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.new(1, -52, 0, 18), Parent = activity})
		createSimple("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = chipBar})
		for i, state in ipairs(FILTERS) do
			state.Chip = createSimple("TextButton", {
				Name = state.Name,
				AutoButtonColor = false,
				AutomaticSize = Enum.AutomaticSize.X,
				BorderSizePixel = 0,
				Font = Enum.Font.SourceSans,
				TextSize = 13,
				TextColor3 = theme.Text,
				Text = state.Name,
				Size = UDim2.new(0, 0, 1, 0),
				LayoutOrder = i,
				Parent = chipBar,
			})
			createSimple("UICorner", {CornerRadius = UDim.new(0, 3), Parent = state.Chip})
			createSimple("UIPadding", {PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = state.Chip})
			state.Chip.MouseButton1Click:Connect(function()
				filter = state.Name
				render()
			end)
			Lib.Tooltip.attach(state.Chip, state.Tip)
		end
		button(activity, "Clear", "Empties this list. Nothing else changes.", UDim2.new(1, -46, 0, -1), UDim2.new(0, 46, 0, 20), function()
			table.clear(entries)
			picked = nil
			render()
		end)

		local logList = createSimple("ScrollingFrame", {Name = "Requests", Active = true, BackgroundColor3 = theme.Main2, BorderSizePixel = 0, CanvasSize = UDim2.new(0, 0, 0, 0),
			ScrollBarThickness = 6, ScrollBarImageColor3 = theme.Highlight, Position = UDim2.new(0, 0, 0, 24), Size = UDim2.new(1, 0, 0.45, -24), Parent = activity})
		createSimple("UIStroke", {Color = theme.Outline1, Parent = logList})
		local hint = label(activity, "", UDim2.new(0, 6, 0, 28), UDim2.new(1, -12, 0, 60), theme.ReadOnlyText) -- why the list is empty
		hint.Name = "Hint"
		hint.TextWrapped = true
		hint.TextTruncate = Enum.TextTruncate.None
		hint.TextYAlignment = Enum.TextYAlignment.Top

		local code = Lib.CodeFrame.new()
		code.Frame.Position = UDim2.new(0, 0, 0.45, 6)
		code.Frame.Size = UDim2.new(1, 0, 0.55, -34)
		code.Frame.Parent = activity
		local copyRequest = button(activity, "Copy request", "Copies what was asked: the code of a run, or the tool with its arguments", UDim2.new(1, -196, 1, -22), UDim2.new(0, 96, 0, 22), function()
			copy("the request", Agent.RequestText(picked))
		end)
		local copyAnswer = button(activity, "Copy answer", "Copies what OpenDex answered, or why the request failed", UDim2.new(1, -96, 1, -22), UDim2.new(0, 96, 0, 22), function()
			copy("the answer", Agent.AnswerText(picked))
		end)

		-- A row's background: the selection colour, a tint under the mouse, or none
		local function back(gui, selected)
			gui.BackgroundColor3 = selected and theme.ListSelection or theme.Button
			gui.BackgroundTransparency = (selected or hovered == gui) and 0 or 1
		end

		-- The rows are made once and show whichever requests are listed now, the newest at the top
		local function requestRow(i)
			local gui = createSimple("TextButton", {
				Name = "Request",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Text = "",
				Position = UDim2.new(0, 0, 0, (i - 1) * ROW_H),
				Size = UDim2.new(1, 0, 0, ROW_H),
				Parent = logList,
			})
			local row = {Gui = gui}
			row.Time = label(gui, "", UDim2.new(0, 5, 0, 0), UDim2.new(0, 52, 1, 0), theme.ReadOnlyText)
			row.Tool = label(gui, "", UDim2.new(0, 60, 0, 0), UDim2.new(0, 80, 1, 0), theme.Text)
			row.Text = label(gui, "", UDim2.new(0, 144, 0, 0), UDim2.new(1, -212, 1, 0), theme.Text)
			row.Outcome = label(gui, "", UDim2.new(1, -66, 0, 0), UDim2.new(0, 56, 1, 0), theme.ReadOnlyText)
			row.Outcome.TextXAlignment = Enum.TextXAlignment.Right
			for _, part in pairs({row.Time, row.Tool, row.Text, row.Outcome}) do part.TextSize = 13 end
			gui.MouseEnter:Connect(function()
				hovered = gui
				back(gui, row.Entry == picked)
			end)
			gui.MouseLeave:Connect(function()
				if hovered == gui then hovered = nil end
				back(gui, row.Entry == picked)
			end)
			gui.MouseButton1Click:Connect(function()
				picked = row.Entry
				render()
			end)
			Lib.Tooltip.attach(gui, function() return row.Entry and (row.Entry.Error or row.Entry.Args):sub(1, 300) end)
			rows[i] = row
			return row
		end

		local function emptyNote(chosen)
			if #entries > 0 then return chosen.None end
			if status.Stage ~= "connected" then return "Not connected. Set up has the three steps." end
			return 'Nothing asked yet. In your editor, ask the AI about this game, for example: "what does the function I\'m looking at do?"'
		end

		local function renderActivity()
			local chosen, counts, listed = FILTERS[1], {}, {}
			for _, state in ipairs(FILTERS) do
				if state.Name == filter then chosen = state end
			end
			for i = #entries, 1, -1 do
				local entry = entries[i]
				for _, state in ipairs(FILTERS) do
					if state.Has(entry) then counts[state.Name] = (counts[state.Name] or 0) + 1 end
				end
				if chosen.Has(entry) then listed[#listed+1] = entry end
			end
			for _, state in ipairs(FILTERS) do
				local count = state.Name ~= "All" and counts[state.Name]
				state.Chip.Text = state.Name..(count and (" "..count) or "")
				state.Chip.BackgroundColor3 = state == chosen and theme.ListSelection or theme.Button
			end

			for i, entry in ipairs(listed) do
				local row = rows[i] or requestRow(i)
				row.Entry = entry
				row.Time.Text = os.date("%H:%M:%S", entry.At)
				row.Tool.Text = entry.Tool
				row.Tool.TextColor3 = entry.Kind == "read" and theme.Text or theme.Warning -- amber: it runs code or writes
				row.Text.Text = entry.Args
				if entry.Pending then
					row.Outcome.Text, row.Outcome.TextColor3 = "running", theme.Warning
				elseif not entry.Ok then
					row.Outcome.Text, row.Outcome.TextColor3 = "failed", theme.Danger
				else
					row.Outcome.Text, row.Outcome.TextColor3 = entry.Ms < 1000 and (entry.Ms.." ms") or ("%.1f s"):format(entry.Ms / 1000), theme.ReadOnlyText
				end
				row.Gui.Visible = true
				back(row.Gui, entry == picked)
			end
			for i = #listed + 1, #rows do rows[i].Gui.Visible = false end
			logList.CanvasSize = UDim2.new(0, 0, 0, #listed * ROW_H)
			hint.Text = #listed == 0 and emptyNote(chosen) or ""

			-- the request that is picked, in full (one that was cleared away, or pushed out by newer ones, is let go)
			if picked and not table.find(entries, picked) then picked = nil end
			local pending = picked and picked.Pending or nil
			if picked ~= drawn or pending ~= drawnPending then
				drawn, drawnPending = picked, pending
				local ok, text = true, "-- Pick a request to see it in full: what was asked, and the answer"
				if picked then ok, text = pcall(Agent.FullText, picked) end
				code:SetText(ok and text or "-- This request could not be shown")
			end
			copyRequest:SetDisabled(picked == nil)
			copyAnswer:SetDisabled(picked == nil or picked.Pending == true)
		end

		----------------------------------------------------------------------------------------------
		-- Set up: what this is, the three steps with what each needs under it, and the port
		----------------------------------------------------------------------------------------------

		local setup = createSimple("Frame", {Name = "SetUp", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, TOP - 4), Size = UDim2.new(1, 0, 1, -(TOP - 4)), Parent = content})
		pages["Set up"] = setup
		local form = Lib.Form.new(setup)

		-- A line of text that wraps, as tall as its text at whatever width the window has
		local function note(text, indent)
			form.Count = form.Count + 1
			local gui = createSimple("TextLabel", {BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), Font = Enum.Font.SourceSans, TextSize = 13,
				TextColor3 = theme.ReadOnlyText, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = text, LayoutOrder = form.Count, Parent = form.Gui})
			createSimple("UIPadding", {PaddingLeft = UDim.new(0, indent or 0), PaddingBottom = UDim.new(0, 2), Parent = gui})
			return gui
		end

		-- A step: its number in a badge that takes the colour of its state, its title, the state in a word, and under them what to do
		local function step(number, title)
			form.Count = form.Count + 1
			local row = createSimple("Frame", {Name = "Step"..number, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = form.Count, Parent = form.Gui})
			local badge = createSimple("TextLabel", {BackgroundColor3 = theme.Button, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, 8), Size = UDim2.new(0, 18, 0, 18), Font = Enum.Font.SourceSansBold, TextSize = 13,
				TextColor3 = theme.Text, Text = tostring(number), Parent = row})
			createSimple("UICorner", {CornerRadius = UDim.new(1, 0), Parent = badge})
			local name = label(row, title, UDim2.new(0, INDENT, 0, 6), UDim2.new(1, -(INDENT + 76), 0, 22), theme.Text)
			name.Font = Enum.Font.SourceSansBold
			local word = label(row, "", UDim2.new(1, -72, 0, 6), UDim2.new(0, 72, 0, 22), theme.ReadOnlyText)
			word.Name = "State"
			word.TextXAlignment = Enum.TextXAlignment.Right
			steps[number] = {Badge = badge, Word = word, Note = note("", INDENT)}
		end

		-- A row of the form, moved in under its step's title
		local function under(row)
			createSimple("UIPadding", {PaddingLeft = UDim.new(0, INDENT), Parent = row.Gui})
			return row
		end

		note("Your editor's AI (Claude Code, Codex, Cursor and others) reaches this game through a small relay program on this PC. It can read the game's scripts, objects, remotes and output, name variables, and run code in the game. What it reads is sent to that AI.")

		step(1, "Start the relay")

		step(2, "Connect with its token")
		under(form:AddInput("Token", cfg.token, function(v)
			cfg.token = v:gsub("^%s+", ""):gsub("%s+$", "")
			save()
			reconnect()
			render()
		end, {Width = 190, Description = "The relay prints a token when it starts. The editor needs the same one: its setup text carries it."}))

		step(3, "Add OpenDex to your editor")
		local editorNames = {}
		for i, editor in ipairs(Agent.Editors) do editorNames[i] = editor.Name end
		local function copyFor(editor)
			env.setclipboard(Agent.SetupText(editor))
			Main.Notify("Copied. Paste it "..editor.Where, "success")
		end
		local editorChoice = under(form:AddDropdown("Editor", editorNames, table.find(editorNames, cfg.editor) and cfg.editor or editorNames[1], function(name)
			cfg.editor = name
			save()
			render()
		end, {Width = 150, Description = "The editor whose AI should reach OpenDex."}))
		local function chosenEditor()
			return Agent.Editors[table.find(editorNames, editorChoice.Get())]
		end
		-- (the setup text carries the token, and leaves through the clipboard)
		local function noCopy()
			return (cfg.token == "" and "Paste the relay's token first, in step 2: the text carries it") or (env.setclipboard == nil and "Your executor has no setclipboard") or nil
		end
		local copySetup = under(form:AddButton("Copy its setup text", function() copyFor(chosenEditor()) end, {Width = 150}))
		Lib.Tooltip.attach(copySetup.Button.Gui, function()
			return noCopy() or "Puts what the chosen editor needs on the clipboard, with the port and the token in it."
		end)

		form.Count = form.Count + 1
		createSimple("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 6), LayoutOrder = form.Count, Parent = form.Gui})
		form:AddHeading("Options")
		form:AddNumber("Relay port", cfg.port, function(v)
			cfg.port = v
			save()
			reconnect()
			render()
		end, {Integer = true, Min = 1024, Max = 65535, Width = 70, Default = DEFAULT_PORT, Description = "The port the relay listens on (its --port option)."})

		local WORDS = {todo = "To do", busy = "Checking", problem = "Problem", done = "Done"}
		local function paint(number, state, text)
			local s = steps[number]
			local color = (state == "done" and theme.Success) or (state == "busy" and theme.Warning) or (state == "problem" and theme.Danger) or nil
			s.Badge.BackgroundColor3 = color or theme.Button
			s.Badge.TextColor3 = color and theme.Outline1 or theme.Text
			s.Word.Text, s.Word.TextColor3 = WORDS[state], color or theme.ReadOnlyText
			s.Note.Text = text
		end

		-- Each step says where it stands, from what the connection last found
		local function renderSetup()
			local stage, at = status.Stage, "127.0.0.1:"..cfg.port
			local start = "On this PC, open a terminal in the mcp folder of OpenDex (it is on GitHub: dogmastr/OpenDex) and run: python opendex_mcp.py. Leave it open."
			if stage == "norelay" then
				paint(1, "problem", "Nothing answers on "..at..". "..start.." If the relay uses another port, set it under Options.")
			elseif stage == "reached" or stage == "refused" or stage == "connected" then
				paint(1, "done", "It answers on "..at..".")
			else
				paint(1, stage == "off" and "todo" or "busy", start)
			end

			if stage == "connected" then
				paint(2, "done", "The relay took the token.")
			elseif stage == "refused" then
				paint(2, "problem", "The relay refused this token. Paste the one it printed when it started (it is also in the file mcp/.token).")
			elseif stage == "reached" then
				paint(2, "busy", "The relay is checking the token.")
			else
				paint(2, "todo", "The relay prints a token when it starts. Paste it here, then press Connect, at the top.")
			end

			local where = chosenEditor().Where
			if cfg.used then
				paint(3, "done", "Your editor's AI has reached OpenDex. For another editor: pick it, copy its setup text and paste it "..where..".")
			else
				paint(3, "todo", "Pick your editor and copy its setup text. Paste it "..where..", start a new conversation there and ask about this game.")
			end
			copySetup.Button:SetDisabled(noCopy() ~= nil)
		end

		----------------------------------------------------------------------------------------------
		-- Drawing it
		----------------------------------------------------------------------------------------------

		local HEADLINES = {off = "Off", looking = "Looking for the relay", norelay = "The relay is not running", reached = "Checking the token",
			refused = "The relay refused the token", closed = "The connection closed", connected = "Connected"}
		local COLORS = {off = theme.ReadOnlyText, norelay = theme.Danger, refused = theme.Danger, connected = theme.Success} -- (the others are on their way: amber)

		-- The line under the state: what to do about it, or what the AI is doing
		local function statusLine()
			local stage = status.Stage
			if stage == "connected" then
				for i = #entries, 1, -1 do
					local entry = entries[i]
					if entry.Pending and os.clock() - entry.Started >= 1 then return ("Running %s for %s"):format(entry.Tool, ago(entry.Started)) end
				end
				if stats.Requests == 0 then return "Nothing asked yet. Try it from your editor." end
				return ("%d request%s, the last %s ago"):format(stats.Requests, stats.Requests == 1 and "" or "s", ago(stats.Last))
			elseif stage == "off" then
				return Agent.Unavailable() or "Press Connect once the relay is running."
			elseif stage == "norelay" then
				return "Start it: Set up has the steps. Trying again."
			elseif stage == "refused" then
				return "Paste the relay's token in step 2 of Set up."
			elseif stage == "closed" then
				local reason = status.Reason
				return ((reason and reason ~= "the connection closed") and (reason:sub(1, 1):upper()..reason:sub(2)..". ") or "").."Trying again."
			end
			return "On 127.0.0.1:"..cfg.port
		end

		render = function()
			dirty, sinceDrawn = false, 0
			local stage, why = status.Stage, Agent.Unavailable()
			dot.BackgroundColor3 = COLORS[stage] or theme.Warning
			headline.Text = (why and stage == "off" and "Not available here") or HEADLINES[stage] or status.Text
			detail.Text = statusLine()
			connect.Text = cfg.enabled and "Disconnect" or "Connect"
			connect:SetDisabled(why ~= nil)
			for name, btn in pairs(tabs) do
				btn.Text = (name == "Activity" and #entries > 0) and ("Activity "..#entries) or name
				lit(btn, name == tab)
				pages[name].Visible = name == tab
			end
			if tab == "Activity" then renderActivity() else renderSetup() end
		end

		onChange = function() dirty = true end
		Main.Track(service.RunService.Heartbeat:Connect(function(dt)
			sinceDrawn = sinceDrawn + dt
			if sinceDrawn < 0.5 or not window:IsContentVisible() then return end
			sinceDrawn = 0
			-- (while it is connected the status counts the seconds since the last request)
			if dirty or status.State == "connected" then render() end
		end))
		window.OnActivate:Connect(render)
		window.OnRestore:Connect(render)

		Main.AddCommands(function()
			local why = Agent.Unavailable()
			local commands = {
				{Name = cfg.enabled and "AI: disconnect from the relay" or "AI: connect to the relay", Category = "AI", Disabled = why or false, Run = function()
					Agent.SetEnabled(not cfg.enabled)
					render()
				end},
			}
			local cannot = (cfg.token == "" and "Paste the relay's token in the AI window first") or (env.setclipboard == nil and "Your executor has no setclipboard") or false
			for _, editor in ipairs(Agent.Editors) do
				commands[#commands+1] = {Name = "AI: copy the setup text for "..editor.Name, Category = "AI", Disabled = cannot, Run = function() copyFor(editor) end}
			end
			return commands
		end)

		render()
		if cfg.enabled then Agent.Start() end
	end

	return Agent
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
