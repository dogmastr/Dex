--[[
	AI App Module

	Lets the AI in an editor (Claude Code, VS Code: anything that speaks MCP) read what OpenDex shows and
	write into its renames and notes. A script in a game can only connect out, never listen, so OpenDex
	cannot be an MCP server itself: this connects out to a small relay program on the PC
	(mcp/opendex_mcp.py), which is the MCP server.

	  editor --MCP over HTTP--> relay <--WebSocket, opened here-- OpenDex

	The relay sends {type = "call", id, tool, args}; this runs the tool and answers {type = "result", id,
	ok, result | error}. The tools are registered by the modules that own the data (Agent.Register):
	ScriptViewer and RemoteSpy. A tool returns text or a table, or nil and why it could not. No tool runs
	anything the agent wrote, fires a remote or turns a rule on: the writes go to OpenDex's own renames and
	notes, and the window lists every request.
]]

-- Common Locals
local Main,Lib,Settings -- Main Containers
local env,service,createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Settings = data.Settings

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
	local MESSAGE_EVENTS = {"OnMessage", "Message", "MessageReceived"}
	local CLOSE_EVENTS = {"OnClose", "Closed"}

	local cfg = {enabled = false, port = DEFAULT_PORT, token = ""}
	local tools = {} -- name -> function(args) -> result | nil, why
	local entries = {} -- what was asked, newest last
	local status = {State = "off", Text = "Off"} -- State: off, connecting, connected
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

	reg("status", function()
		return {
			opendex = Main.Version, executor = Main.Executor, place = game.PlaceId,
			features = {
				decompile = env.isdecompile and env.isdecompile() or false,
				remoteHooks = env.hookmetamethod ~= nil and env.getnamecallmethod ~= nil,
				hookfunction = env.hookfunction ~= nil,
				getgc = env.getgc ~= nil,
				loadstring = env.loadstring ~= nil,
				filesystem = env.writefile ~= nil and env.readfile ~= nil,
				clipboard = env.setclipboard ~= nil,
			},
			requests = stats.Requests,
			tools = Agent.ToolNames(),
		}
	end)

	-- A short account of a request for the window
	local function summarize(args)
		local parts = {}
		for _, key in ipairs({"script", "remote", "query", "name", "line", "from", "to", "direction", "limit"}) do
			if args[key] ~= nil then parts[#parts+1] = key.."="..tostring(args[key]):sub(1, 40) end
		end
		if type(args.names) == "table" then parts[#parts+1] = "names="..#args.names end
		if type(args.text) == "string" then parts[#parts+1] = "text="..#args.text.." characters" end
		if type(args.when) == "string" then parts[#parts+1] = "when" end
		return table.concat(parts, " ")
	end

	local function record(entry)
		entries[#entries+1] = entry
		if #entries > LOG_KEEP then table.remove(entries, 1) end
		stats.Requests, stats.Last = stats.Requests + 1, os.clock()
		onChange()
	end

	local function jsonEncode(value)
		return service.HttpService:JSONEncode(value)
	end

	-- Runs one tool and answers the relay. (Its own thread: a tool may wait, to decompile say.)
	local function runCall(ws, msg)
		local id, name = msg.id, msg.tool
		local args = type(msg.args) == "table" and msg.args or {}
		local started = os.clock()
		local ok, result, why = false, nil, nil

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

		record({At = os.time(), Tool = tostring(name), Args = summarize(args), Ok = ok, Ms = math.floor((os.clock() - started) * 1000 + 0.5), Size = #text, Error = (not ok) and tostring(why) or nil})
	end
	Agent.RunCall = runCall

	----------------------------------------------------------------------------------------------
	-- The connection to the relay
	----------------------------------------------------------------------------------------------

	local function setStatus(state, text)
		status.State, status.Text = state, text
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

	-- One connection, from the hello to its end. Returns why it ended.
	local function session(ws, my)
		local closed, refused = false, nil
		local lastPong, lastPing = os.clock(), os.clock()
		local onMessage, onClose = eventOf(ws, MESSAGE_EVENTS), eventOf(ws, CLOSE_EVENTS)
		if not onMessage then
			pcall(function() ws:Close() end)
			return "this executor's WebSocket has no message event (looked for "..table.concat(MESSAGE_EVENTS, ", ")..")"
		end

		local connections = {}
		connections[1] = onMessage:Connect(function(raw)
			local ok, msg = pcall(function() return service.HttpService:JSONDecode(raw) end)
			if not (ok and type(msg) == "table") then return end
			lastPong = os.clock() -- anything from the relay shows it is there
			if msg.type == "call" then
				task.spawn(runCall, ws, msg)
			elseif msg.type == "welcome" then
				setStatus("connected", "Connected to the relay")
				Main.Notify("The AI relay is connected", "success")
			elseif msg.type == "error" then
				refused = tostring(msg.message or "the relay refused the connection")
			end
		end)
		if onClose then
			connections[2] = onClose:Connect(function() closed = true end)
		end

		socket = ws
		setStatus("connecting", "Reached the relay on 127.0.0.1:"..cfg.port..", waiting for it to accept the token")
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
		return refused or (closed and "the connection closed") or nil
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
			local reason
			if ok and ws then
				reason = session(ws, my)
				delay = 1
			else
				reason = "the relay is not running"
			end
			if loopId ~= my then return end
			setStatus("connecting", ("Not connected: %s (127.0.0.1:%d). Trying again.%s"):format(reason or "the connection ended", port, cfg.token == "" and " Paste the relay's token below." or ""))
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
		setStatus("off", "Off")
	end

	Agent.Start = function()
		local why = Agent.Unavailable()
		if why then
			setStatus("off", why)
			return false, why
		end
		loopId = loopId + 1
		closeSocket()
		task.spawn(runLoop, loopId)
		return true
	end

	-- The switch: remembered, and acted on
	local function save()
		if not env.writefile then return end
		local ok, json = pcall(jsonEncode, {enabled = cfg.enabled, port = cfg.port, token = cfg.token})
		if ok then pcall(env.writefile, CONFIG_FILE, json) end
	end

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
	-- The window
	----------------------------------------------------------------------------------------------

	Agent.Init = function()
		local theme = Settings.Theme
		local window = Lib.Window.new()
		window:SetTitle("AI")
		window:SetLayoutId("AI")
		window:Resize(360, 480)
		Agent.Window = window
		local content = window.GuiElems.Content
		local LOG_H, ROW_H = 170, 16

		loadConfig()

		local form = Lib.Form.new(content)
		form.Gui.Size = UDim2.new(1, 0, 1, -LOG_H)

		form:AddHeading("AI agents (MCP)")
		form:AddNote("Lets the AI in your editor (Claude Code, Codex, Cursor and others) read the scripts and remotes OpenDex shows, and name their variables. What it reads is sent to that AI. It reaches OpenDex through a small relay program on this PC.", 320)

		-- the state of the connection: a dot and a sentence
		form.Count = form.Count + 1
		local statusRow = createSimple("Frame", {BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = form.Count, Parent = form.Gui})
		local dot = createSimple("Frame", {BackgroundColor3 = theme.ReadOnlyText, BorderSizePixel = 0, Position = UDim2.new(0, 2, 0, 6), Size = UDim2.new(0, 10, 0, 10), Parent = statusRow})
		createSimple("UICorner", {CornerRadius = UDim.new(1, 0), Parent = dot})
		local statusLabel = createSimple("TextLabel", {BackgroundTransparency = 1, Position = UDim2.new(0, 20, 0, 0), Size = UDim2.new(1, -20, 1, 0), Font = Enum.Font.SourceSans, TextSize = 14,
			TextColor3 = theme.Text, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = "", Parent = statusRow})

		local switch = form:AddCheckbox("Connect to the relay", cfg.enabled, function(on)
			local ok, why = Agent.SetEnabled(on)
			if not ok then Main.Notify(why, "warn") end
		end, {Default = false, Description = "Connects to the relay program on this PC. Off by default; it is remembered between sessions."})
		form:AddNumber("Port", cfg.port, function(v)
			cfg.port = v
			save()
			reconnect()
		end, {Integer = true, Min = 1024, Max = 65535, Width = 70, Default = DEFAULT_PORT, Description = "The port the relay listens on (its --port option)."})
		form:AddInput("Token", cfg.token, function(v)
			cfg.token = v:gsub("^%s+", ""):gsub("%s+$", "")
			save()
			reconnect()
		end, {Width = 160, Description = "The relay prints a token when it starts. Paste it here; the editor needs the same one."})

		form:AddHeading("Set up")
		form:AddNote("1. Start the relay: python opendex_mcp.py, from the mcp folder of the OpenDex repository. Leave it open.\n2. Paste its token above and switch on Connect to the relay.\n3. Add OpenDex to your editor: pick it, copy its setup text and paste that where the notice says.", 320)
		local editorNames = {}
		for i, editor in ipairs(Agent.Editors) do editorNames[i] = editor.Name end
		local function copyFor(editor)
			env.setclipboard(Agent.SetupText(editor))
			Main.Notify("Copied. Paste it "..editor.Where, "success")
		end
		local editorChoice = form:AddDropdown("Editor", editorNames, editorNames[1], nil, {Width = 140, Description = "The editor whose AI should reach OpenDex."})
		form:AddButton("Copy its setup text", function()
			if not env.setclipboard then Main.Notify("Your executor has no setclipboard", "warn") return end
			if cfg.token == "" then Main.Notify("Paste the relay's token first: the text needs it", "warn") return end
			copyFor(Agent.Editors[table.find(editorNames, editorChoice.Get())])
		end, {Width = 200, Description = "Puts what the chosen editor needs on the clipboard, with the port and the token in it."})

		-- the requests, newest last
		local logFrame = createSimple("Frame", {BackgroundColor3 = theme.Main2, BorderColor3 = theme.Outline1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, LOG_H), Parent = content})
		createSimple("TextLabel", {BackgroundTransparency = 1, Position = UDim2.new(0, 8, 0, 2), Size = UDim2.new(1, -16, 0, 18), Font = Enum.Font.SourceSansBold, TextSize = 14, TextColor3 = theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left, Text = "What the AI asked", Parent = logFrame})
		local logList = createSimple("ScrollingFrame", {BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.new(0, 6, 0, 22), Size = UDim2.new(1, -12, 1, -26), CanvasSize = UDim2.new(0, 0, 0, 0),
			ScrollBarThickness = 8, ScrollBarImageColor3 = theme.Highlight, TopImage = "", BottomImage = "", Parent = logFrame})
		local logRows = {}

		local function ago(t)
			local s = math.floor(os.clock() - t)
			return s < 60 and (s.." s") or (math.floor(s / 60).." min")
		end

		local function size(n)
			return n < 1000 and (n.." B") or ("%.1f kB"):format(n / 1000)
		end

		local drawn = 0
		local function refresh()
			dot.BackgroundColor3 = status.State == "connected" and theme.Success or (status.State == "connecting" and theme.Warning or theme.ReadOnlyText)
			local text = status.Text
			if status.State == "connected" then
				text = text.."\n"..(stats.Requests == 0 and "Nothing has been asked yet." or ("%d request%s so far, the last %s ago."):format(stats.Requests, stats.Requests == 1 and "" or "s", ago(stats.Last)))
			end
			statusLabel.Text = text

			local count = #entries
			for i = 1, count do
				local entry = entries[i]
				local row = logRows[i]
				if not row then
					row = createSimple("TextLabel", {BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, (i - 1) * ROW_H), Size = UDim2.new(1, -4, 0, ROW_H), Font = Enum.Font.SourceSans, TextSize = 13,
						TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "", Parent = logList})
					logRows[i] = row
				end
				local outcome = entry.Ok and (size(entry.Size)..", "..entry.Ms.." ms") or ("failed: "..(entry.Error or "?"):gsub("%s+", " "))
				row.Text = ("%s  %s  %s  %s"):format(os.date("%H:%M:%S", entry.At), entry.Tool, entry.Args, outcome)
				row.TextColor3 = entry.Ok and theme.Text or theme.Danger
				row.Visible = true
			end
			for i = count + 1, #logRows do logRows[i].Visible = false end
			logList.CanvasSize = UDim2.new(0, 0, 0, count * ROW_H)
			if count ~= drawn then
				drawn = count
				logList.CanvasPosition = Vector2.new(0, math.max(0, count * ROW_H - logList.AbsoluteSize.Y))
			end
		end

		local dirty = true
		onChange = function() dirty = true end
		local sinceDrawn = 0
		Main.Track(service.RunService.Heartbeat:Connect(function(dt)
			sinceDrawn = sinceDrawn + dt
			if sinceDrawn < 0.5 or not window:IsContentVisible() then return end
			sinceDrawn = 0
			if dirty or status.State == "connected" then
				dirty = false
				refresh()
			end
		end))
		window.OnActivate:Connect(refresh)

		Main.AddCommands(function()
			local why = Agent.Unavailable()
			local commands = {
				{Name = cfg.enabled and "AI: disconnect from the relay" or "AI: connect to the relay", Category = "AI", Disabled = why or false, Run = function()
					local on = not cfg.enabled
					Agent.SetEnabled(on)
					switch.Set(on, true)
				end},
			}
			local noCopy = (cfg.token == "" and "Paste the relay's token in the AI window first") or (env.setclipboard == nil and "Your executor has no setclipboard") or false
			for _, editor in ipairs(Agent.Editors) do
				commands[#commands+1] = {Name = "AI: copy the setup text for "..editor.Name, Category = "AI", Disabled = noCopy, Run = function() copyFor(editor) end}
			end
			return commands
		end)

		refresh()
		if cfg.enabled then Agent.Start() end
	end

	return Agent
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
