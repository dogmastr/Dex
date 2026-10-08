	--[[
	Remote Spy App Module

	The game's remote calls as they happen. Outgoing: what its scripts send to the server (FireServer and
	InvokeServer, and Fire and Invoke of bindables when those are switched on). Incoming: what the server
	fires at the client (OnClientEvent). A call is kept with its arguments and the script, function and
	line that made it, and is written out as the code that makes it again. A remote can be blocked from
	firing, or left out of the list.

	What the game sends is caught by a hook on __namecall and by hooks on the fire methods themselves (a
	script can write remote.FireServer(remote) as well). A hook only puts the call in a queue; it is filed
	and drawn from Heartbeat. What the server sends comes from a listener of our own beside the game's.
]]

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer, ScriptViewer, Analysis -- Major Apps
local env,service,createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	env = data.env
	service = data.service
	createSimple = data.createSimple
end

local function initAfterMain()
	Explorer = Apps.Explorer
	ScriptViewer = Apps.ScriptViewer
	Analysis = Apps.ScriptAnalysis
end

local function main()
	local RemoteSpy = {}

	local KEEP = 200 -- calls kept per remote: the newest
	local SHOWN = 100 -- how many of them the list has rows for
	local MAX_REMOTES = 500 -- remotes listed per direction: past it, the one seen first makes room
	local QUEUE_MAX = 2000 -- calls waiting to be filed: if OpenDex never comes back from Apply Now, nothing files them
	local BATCH = 40 -- the most remotes asked in one frame whether the game listens to them

	-- class -> the method that fires it; class -> the event the server fires at the client
	local FIRE = {RemoteEvent = "FireServer", UnreliableRemoteEvent = "FireServer", RemoteFunction = "InvokeServer", BindableEvent = "Fire", BindableFunction = "Invoke"}
	local LISTEN = {RemoteEvent = "OnClientEvent", UnreliableRemoteEvent = "OnClientEvent"}
	local CALLBACK = {RemoteFunction = "OnClientInvoke"} -- class -> the callback the server invokes on the client
	local BINDABLE = {BindableEvent = true, BindableFunction = true} -- (these stay inside the client: listed only when asked for)
	-- what __namecall is called with -> the method (a small first letter works too)
	local METHOD = {FireServer = "FireServer", fireServer = "FireServer", InvokeServer = "InvokeServer", invokeServer = "InvokeServer", Fire = "Fire", fire = "Fire", Invoke = "Invoke", invoke = "Invoke"}
	local RETURNS = {InvokeServer = true, Invoke = true, OnClientInvoke = true} -- (what they return is kept with the call)

	local isDescendantOf, getFullName = game.IsDescendantOf, game.GetFullName

	-- What the hooks read hangs off Main, so it outlives Apply Now: they can't be taken out again, and a
	-- reloaded OpenDex must still unblock what the one before it blocked. Block and Ignore: remote -> true.
	-- Rules: remote -> {When, Args (functions of the call's arguments), WhenText, ArgsText}. Old: class ->
	-- its fire method as it was before the hook.
	local spy = Main.RemoteHook or {Hooked = false, On = false, Bindables = false}
	Main.RemoteHook = spy
	-- (the table may come from an OpenDex of an earlier build, run before this one in the same game: Own is
	-- the files whose functions are ours on a call stack)
	for _, field in ipairs({"Block", "Ignore", "Rules", "Old", "Pending", "Own"}) do spy[field] = spy[field] or {} end

	----------------------------------------------------------------------------------------------
	-- The calls that were caught: per direction, the remotes in the order they were first seen
	----------------------------------------------------------------------------------------------

	local logs = {Out = {}, In = {}} -- a log: {Remote, Dir, Name, Path, Lower, Calls (oldest first), Count, Row}
	local logOf = {Out = {}, In = {}} -- remote -> its log (false for one of Roblox's own)
	local current, shown -- the remote and the call that are selected
	local awaited -- the call that is showing, while its InvokeServer has not returned
	local window, render -- made by Init
	local dirty, sinceDrawn = false, 0
	RemoteSpy.Logs = logs

	-- Roblox's own remotes (the chat, the menu) are not listed
	local internal = {}
	for _, name in ipairs({"RobloxReplicatedStorage", "CoreGui", "CorePackages"}) do
		local ok, container = pcall(function() return service[name] end)
		if ok then internal[#internal+1] = container end
	end
	local function isInternal(inst)
		for _, container in ipairs(internal) do
			if isDescendantOf(inst, container) then return true end
		end
		return false
	end

	-- Takes a remote's calls out of the list, and the remote with them. A blocked one stays, empty: the
	-- list is where it is unblocked.
	local function clear(log)
		log.Calls, log.Count = {}, 0
		if log.Dir == "Out" and spy.Block[log.Remote] then return end
		Lib.FindAndRemove(logs[log.Dir], log)
		logOf[log.Dir][log.Remote] = nil
		if log.Row then log.Row.Gui:Destroy() end
		if current == log then current, shown = nil, nil end
	end

	local function logFor(remote, dir)
		local log = logOf[dir][remote]
		if log == nil then
			log = false
			if not isInternal(remote) then
				local name = remote.Name
				local ok, path = pcall(getFullName, remote)
				log = {Remote = remote, Dir = dir, Name = name, Path = ok and path or name, Calls = {}, Count = 0}
				log.Lower = (name.." "..log.Path):lower()

				local list = logs[dir]
				list[#list+1] = log
				if #list > MAX_REMOTES then
					for _, old in ipairs(list) do
						if old ~= log and old ~= current and not spy.Block[old.Remote] then
							clear(old)
							break
						end
					end
				end
			end
			logOf[dir][remote] = log
		end
		return log
	end
	for remote in pairs(spy.Block) do logFor(remote, "Out") end -- what an OpenDex before this one blocked is listed from the start

	----------------------------------------------------------------------------------------------
	-- Catching what the game sends. What is between here and hook() runs inside the hooks: it may
	-- not wait, and may not call a method of an Instance with a colon before the real call is made
	-- (that goes through __namecall itself, and the name of the method being called is lost).
	----------------------------------------------------------------------------------------------

	local getCaller, isExecutor, getMethod = env.getcallingscript, env.checkcaller, env.getnamecallmethod
	spy.Own[debug.info(1, "s")] = true -- this file, as the call stack names it

	local function queue(remote, method, dir, ...)
		local pending = spy.Pending
		if #pending >= QUEUE_MAX then return nil end
		local call = {Remote = remote, Method = method, Dir = dir, Args = table.pack(...)}
		pending[#pending+1] = call
		return call
	end

	-- Who made the call: the script, and the first function up the stack that is neither ours nor the executor's
	local function whoCalled(call)
		if getCaller then
			local ok, scr = pcall(getCaller)
			if ok and typeof(scr) == "Instance" then call.Script = scr end
		end
		if isExecutor then
			local ok, own = pcall(isExecutor)
			if ok and own == true then call.Executor = true end
		end
		for level = 2, 16 do
			local source, line, name = debug.info(level, "sln")
			if not source then break end
			if source ~= "[C]" and not spy.Own[source] then
				call.Source, call.Line, call.Function = source, line, name
				break
			end
		end
	end

	local function result(call, ...)
		if call and RETURNS[call.Method] then call.Returned = table.pack(...) end
		return ...
	end

	-- One call of a fire method, from either hook. real is what makes the call.
	local function outgoing(real, remote, method, ...)
		local blocked, rule, sent, failed = spy.Block[remote], spy.Rules[remote], nil, nil
		if rule then
			local args = table.pack(...)
			if rule.When and not blocked then
				local ok, hit = pcall(rule.When, args)
				if ok then blocked = hit and true or nil else failed = tostring(hit) end
			end
			if rule.Args and not blocked then
				local got = table.pack(pcall(rule.Args, args))
				if got[1] then sent = table.pack(table.unpack(got, 2, got.n)) else failed = tostring(got[2]) end
			end
			if failed then rule.Error = failed end -- (a rule that breaks lets the call through as it was; the window says so)
			-- (a rule may have called a method of an Instance by name: the call is made on the method itself)
			real = spy.Old[remote.ClassName] or remote[method]
		end

		local call
		if spy.On and not spy.Ignore[remote] and (spy.Bindables or not BINDABLE[remote.ClassName]) then
			call = queue(remote, method, "Out", ...)
			if call then
				call.Blocked, call.Sent, call.RuleError = blocked, sent, failed
				whoCalled(call)
			end
		end
		if blocked then return end
		if sent then return result(call, real(remote, table.unpack(sent, 1, sent.n))) end
		return result(call, real(remote, ...))
	end

	-- Why what the game sends can't be caught on this executor, or nil. (The Explorer greys its entries with it.)
	RemoteSpy.Unavailable = (env.hookmetamethod == nil and "Your executor has no hookmetamethod") or (env.getnamecallmethod == nil and "Your executor has no getnamecallmethod") or nil

	-- What a hook does with a call is kept in the table the hooks read, not in the hooks: they are made
	-- once and can't be taken out, and the OpenDex that starts next (a reload, or the build run again)
	-- puts its own here. old is what makes the real call.
	spy.Namecall = function(old, self, ...)
		local method = METHOD[getMethod()]
		if method and typeof(self) == "Instance" and FIRE[self.ClassName] == method then
			return outgoing(old, self, method, ...)
		end
		return old(self, ...)
	end
	spy.Direct = function(old, class, method, self, ...)
		if typeof(self) == "Instance" and self.ClassName == class then
			return outgoing(old, self, method, ...)
		end
		return old(self, ...)
	end

	-- Makes the hooks, the first time they are needed in a session. true when they are in place.
	local function hook()
		if spy.Hooked or RemoteSpy.Unavailable then return spy.Hooked end
		local wrap = env.newcclosure or function(fn) return fn end

		local ok, err = pcall(function()
			local old
			old = env.hookmetamethod((oldgame or game), "__namecall", wrap(function(...)
				return spy.Namecall(old, ...)
			end))
		end)
		if not ok then
			Main.Notify("The hook for remote calls could not be made: "..tostring(err), "error")
			return false
		end
		spy.Hooked = true

		-- remote.FireServer(remote) does not go through __namecall: the methods themselves are hooked as well
		if env.hookfunction then
			for class, method in pairs(FIRE) do
				pcall(function()
					local old
					old = env.hookfunction(Instance.new(class)[method], wrap(function(...)
						return spy.Direct(old, class, method, ...)
					end))
					spy.Old[class] = old
				end)
			end
		end
		return true
	end

	-- Files what the hooks and the listeners queued.
	-- ponytail: the arguments are kept as they were passed, so a table the game changes afterwards shows
	-- its new contents. Copy them here if that turns out to matter.
	local function drain()
		local pending = spy.Pending
		if #pending == 0 then return end
		spy.Pending = {}
		local at = os.date("%H:%M:%S")
		for _, call in ipairs(pending) do
			local log = logFor(call.Remote, call.Dir)
			if log then
				call.At = at
				local calls = log.Calls
				calls[#calls+1] = call
				if #calls > KEEP then table.remove(calls, 1) end
				log.Count = log.Count + 1
			end
		end
		dirty = true
	end

	----------------------------------------------------------------------------------------------
	-- What the server sends: a listener of our own on the remote's event, beside the game's. It is
	-- there only while a function of the game's listens too. A remote keeps what the server sends
	-- while nothing listens and hands it to the next listener: that must never be ours. (So what a
	-- script only waits for, with :Wait(), is not listed.)
	----------------------------------------------------------------------------------------------

	-- watched: {remote, our connection, our listener}, or for a RemoteFunction {remote, our callback, the game's}
	local watched, seen, turn, addedCon = {}, {}, 0, nil

	local function consider(inst)
		local class = inst.ClassName
		if ((LISTEN[class] and env.getconnections) or (CALLBACK[class] and env.getcallbackvalue)) and not seen[inst] and not isInternal(inst) then
			seen[inst] = true
			watched[#watched+1] = {inst}
		end
	end

	-- How many functions listen to an event, ours not counted (a listener in an Actor counts: its function can't be read)
	local function heardBy(signal, ours)
		local count = 0
		for _, conn in ipairs(env.getconnections(signal)) do
			if conn.ForeignState then
				count = count + 1
			else
				local fn = conn.Function
				if type(fn) == "function" and fn ~= ours then count = count + 1 end
			end
		end
		return count
	end

	local function unlisten(entry)
		entry[2]:Disconnect()
		entry[2], entry[3] = nil, nil
	end

	local function listen(entry, signal)
		local remote, event = entry[1], LISTEN[entry[1].ClassName]
		local function ours(...)
			-- (the game stopped listening since it was last looked at: no more are taken)
			local ok, heard = pcall(heardBy, signal, ours)
			if not (ok and heard > 0) and entry[2] then unlisten(entry) end
			if not spy.Ignore[remote] then queue(remote, event, "In", ...) end
		end
		entry[2], entry[3] = signal:Connect(ours), ours
	end

	-- An event: one the game listens to gets our listener, one it no longer listens to loses it. True when
	-- the remote can be let go (nowhere and unheard, as a destroyed one is).
	local function tendEvent(entry)
		local remote = entry[1]
		local signal = remote[LISTEN[remote.ClassName]]
		local ok, heard = pcall(heardBy, signal, entry[3])
		heard = ok and heard > 0
		if entry[2] and not heard then
			unlisten(entry)
		elseif not entry[2] and heard then
			listen(entry, signal)
		elseif not entry[2] then
			return remote.Parent == nil
		end
		return false
	end

	-- Sets a RemoteFunction's callback the way the game's code would: what sets a callback decides what it runs as
	local function setCallback(remote, fn)
		local was = env.getthreadidentity and env.getthreadidentity()
		if was and env.setthreadidentity then env.setthreadidentity(2) end
		local ok = pcall(function() remote.OnClientInvoke = fn end)
		if was and env.setthreadidentity then env.setthreadidentity(was) end
		return ok
	end

	-- A RemoteFunction the server invokes: the game's callback is called through one of ours, which lists
	-- the call and what the game answered. Looked at again each turn, since the game may set another
	-- callback. One with no callback is left alone: the server's invoke has to wait for the game's.
	local function tendCallback(entry)
		local remote = entry[1]
		local ok, theirs = pcall(env.getcallbackvalue, remote, "OnClientInvoke")
		if not ok or type(theirs) ~= "function" then
			entry[2], entry[3] = nil, nil
			return remote.Parent == nil
		end
		-- ponytail: six times at most. An executor that hands back a copy of our own callback would have
		-- it wrapped again every turn; count the game's real changes apart if a game sets more than that.
		if theirs ~= entry[2] and (entry[4] or 0) < 6 then
			local function ours(...)
				if spy.Ignore[remote] then return theirs(...) end
				return result(queue(remote, "OnClientInvoke", "In", ...), theirs(...))
			end
			if setCallback(remote, ours) then entry[2], entry[3], entry[4] = ours, theirs, (entry[4] or 0) + 1 end
		end
		return false
	end

	-- Looks at a few of the watched remotes, in turn (each about twice a second)
	local function tend(dt)
		for _ = 1, math.min(BATCH, math.ceil(#watched * dt * 2)) do
			if #watched == 0 then break end
			turn = turn % #watched + 1
			local entry = watched[turn]
			if (CALLBACK[entry[1].ClassName] and tendCallback or tendEvent)(entry) then
				seen[entry[1]] = nil
				watched[turn] = watched[#watched]
				watched[#watched] = nil
				turn = turn - 1
			end
		end
	end

	local function stop()
		spy.On = false
		if addedCon then addedCon:Disconnect() end
		for _, entry in ipairs(watched) do
			local remote = entry[1]
			if entry[2] and CALLBACK[remote.ClassName] then
				-- the game's callback goes back, unless the game has set another since
				local ok, now = pcall(env.getcallbackvalue, remote, "OnClientInvoke")
				if ok and now == entry[2] then setCallback(remote, entry[3]) end
			elseif entry[2] then
				entry[2]:Disconnect()
			end
		end
		watched, seen, turn, addedCon = {}, {}, 0, nil
		dirty = true
	end

	-- Starts listing calls: the hooks for what the game sends (made the first time), the listeners for what
	-- the server sends. Stays off, and says why, on an executor that can do neither.
	local function start()
		if spy.On then return end
		local receives = env.getconnections or env.getcallbackvalue
		if not hook() and not receives then
			if RemoteSpy.Unavailable then
				Main.Notify("The Remote Spy can't list calls here: "..RemoteSpy.Unavailable.." (nor getconnections, for what the server sends)", "warn")
			end
			return
		end
		spy.On = true
		if receives then
			for _, inst in ipairs(game:GetDescendants()) do pcall(consider, inst) end
			local ok, orphans = pcall(env.getnilinstances or error)
			for _, inst in ipairs(ok and type(orphans) == "table" and orphans or {}) do pcall(consider, inst) end
			addedCon = game.DescendantAdded:Connect(function(inst) pcall(consider, inst) end)
		end
		dirty = true
	end

	----------------------------------------------------------------------------------------------
	-- A call as text: a few characters for the list, and the code that makes it again
	----------------------------------------------------------------------------------------------

	local function short(v)
		local kind = typeof(v)
		if kind == "string" then
			return '"'..(#v > 24 and (v:sub(1,24).."...") or v):gsub("%c", " ")..'"'
		elseif kind == "number" or kind == "boolean" or kind == "nil" then
			return tostring(v)
		elseif kind == "Instance" then
			return v.Name
		elseif kind == "table" then
			return next(v) == nil and "{}" or "{...}"
		end
		return kind
	end

	-- The row of a call: its first arguments, and where it came from
	local function describe(call)
		local args, parts = call.Args, {}
		for i = 1, math.min(args.n, 6) do parts[i] = short(args[i]) end
		if args.n > 6 then parts[#parts+1] = "..." end
		local text = #parts > 0 and table.concat(parts, ", ") or "(no arguments)"

		if call.Dir == "In" then return text, "" end
		if call.Executor then return text, "executor" end
		local line = (call.Line and call.Line > 0) and (":"..call.Line) or ""
		if call.Script then return text, call.Script.Name..line end
		return text, call.Source and ((tostring(call.Source):match("[^%.]+$") or "?")..line) or "?"
	end

	local function argList(args)
		local parts = {}
		for i = 1, args.n do parts[i] = (Lib.ToLua(args[i])) end
		return table.concat(parts, ", ")
	end

	-- A text that can stand in a line comment (the name of a script may hold a line break)
	local function plain(text)
		return (tostring(text):gsub("%c", " "))
	end

	-- What loadstring says of a rule's text, or a rule says when it breaks, without the chunk name put in
	-- front of it ([string "local args = ..."]:2:)
	local function plainError(err)
		return (plain(err):gsub('^%[string ".-"%]:%d+:%s*', ""))
	end

	-- "local remote = " and its path (one that is not in the game: the path starts with the function that
	-- finds it among the nil instances)
	local function remoteLine(remote)
		local path = Explorer.GetInstancePath(remote)
		local finder, rest = path:match("^(local getNil = .-)\n\n(.*)$")
		return finder and (finder.."\nlocal remote = "..rest) or ("local remote = "..path)
	end

	-- What a call returned, as a comment
	local function returned(call, who)
		local got = call.Returned and argList(call.Returned):gsub("\n", "\n-- ")
		return (not got and "-- It has not returned yet.") or (got == "" and ("-- "..who.." returned nothing.")) or ("-- "..who.." returned: "..got)
	end

	local function codeFor(call)
		local remote, out = call.Remote, {}
		if call.Dir == "Out" then
			local from = "an unknown script"
			if call.Script then
				local ok, name = pcall(getFullName, call.Script)
				from = ok and name or tostring(call.Script)
			elseif call.Executor then
				from = "the executor"
			elseif call.Source then
				from = call.Source
			end
			local where = {}
			if call.Function and call.Function ~= "" then where[#where+1] = "function "..call.Function end
			if call.Line and call.Line > 0 then where[#where+1] = "line "..call.Line end
			out[#out+1] = plain(("-- Sent at %s, from %s%s"):format(call.At, from, #where > 0 and (" ("..table.concat(where, ", ")..")") or ""))
			if call.RuleError then out[#out+1] = "-- The remote's rule broke on this call, so it went out as it was: "..plainError(call.RuleError) end
			if call.Blocked then
				out[#out+1] = "-- It was blocked: the call did not go out."
			else
				if call.Sent then out[#out+1] = "-- A rule sent this instead: ("..argList(call.Sent):gsub("\n", "\n-- ")..")" end
				if RETURNS[call.Method] then out[#out+1] = returned(call, "It") end
			end
		elseif CALLBACK[remote.ClassName] then
			out[#out+1] = ("-- Received at %s: the server invoked this on the client."):format(call.At)
			out[#out+1] = returned(call, "The game")
		else
			out[#out+1] = ("-- Received at %s: the server fired this at the client."):format(call.At)
		end
		out[#out+1] = remoteLine(remote)

		local args = argList(call.Args)
		if call.Dir == "Out" then
			out[#out+1] = ("remote:%s(%s)"):format(call.Method, args)
		elseif CALLBACK[remote.ClassName] then
			out[#out+1] = ('getcallbackvalue(remote, "%s")(%s)'):format(call.Method, args)
		else
			out[#out+1] = ("firesignal(remote.%s%s)"):format(call.Method, args ~= "" and (", "..args) or "")
		end
		return table.concat(out, "\n")
	end

	-- Code that catches a remote's calls outside OpenDex, where they can be read, changed or stopped
	local function hookCode(log)
		local remote = log.Remote
		local body
		if log.Dir == "Out" then
			body = [[
local old
old = hookmetamethod(game, "__namecall", function(self, ...)
	if self == remote and getnamecallmethod() == "METHOD" then
		print("METHOD", ...)
		-- "return old(self, 1, 2, 3)" to send other arguments; "return" to block the call
	end
	return old(self, ...)
end)]]
		elseif CALLBACK[remote.ClassName] then
			body = [[
local old = getcallbackvalue(remote, "METHOD")
remote.METHOD = function(...)
	print("METHOD", ...)
	return old(...) -- what is returned here goes back to the server
end]]
		else
			body = [[
remote.METHOD:Connect(function(...)
	print("METHOD", ...)
end)]]
		end
		local method = log.Dir == "Out" and FIRE[remote.ClassName] or CALLBACK[remote.ClassName] or LISTEN[remote.ClassName]
		return remoteLine(remote).."\n"..body:gsub("METHOD", method)
	end

	-- Makes a call again. What the game sent goes out through the method as it was before the hook: it is
	-- sent even when the remote is blocked, and is not listed.
	local function runAgain(call)
		local remote, args = call.Remote, call.Args
		local ok, err
		if call.Dir == "Out" then
			ok, err = pcall(task.spawn, spy.Old[remote.ClassName] or remote[call.Method], remote, table.unpack(args, 1, args.n))
		elseif CALLBACK[remote.ClassName] then
			ok, err = pcall(task.spawn, env.getcallbackvalue(remote, call.Method), table.unpack(args, 1, args.n))
		else
			ok, err = pcall(env.firesignal, remote[call.Method], table.unpack(args, 1, args.n))
		end
		if ok then
			Main.Notify(call.Dir == "Out" and "Sent it again" or "Gave it to the game again", "success")
		else
			Main.Notify("The call could not be made again: "..tostring(err), "error")
		end
	end

	----------------------------------------------------------------------------------------------
	-- For the other apps
	----------------------------------------------------------------------------------------------

	RemoteSpy.Blocked = spy.Block -- remote -> true while it is blocked from firing

	-- Blocks a remote from firing, or lets it fire again. false when it can't be done.
	RemoteSpy.SetBlocked = function(remote, on)
		if not FIRE[remote.ClassName] or (on and not hook()) then return false end
		spy.Block[remote] = on or nil
		if on then logFor(remote, "Out") end -- (it is listed from now on, calls or not)
		dirty = true
		if Explorer.Window:IsVisible() then Explorer.Refresh() end -- its name is red in the tree while it is blocked
		return true
	end

	-- The text of a rule as a function of args (the arguments of a call, packed), or nil and why it isn't one
	RemoteSpy.Compile = function(text)
		if not env.loadstring then return nil, "Your executor has no loadstring" end
		local fn, err = env.loadstring("local args = ...\nreturn "..text)
		if not fn then return nil, plainError(err) end
		return fn
	end

	-- What a rule (from Compile) would do with this call, in words, without doing it. The second value is
	-- true when that is bad news: the rule breaks on the call, and the call would go out as it is. part is
	-- "When" or "Args".
	RemoteSpy.Try = function(part, fn, call)
		local got = table.pack(pcall(fn, call.Args))
		if not got[1] then return "Breaks on this call ("..plainError(got[2]).."), so the call would go out as it is.", true end
		if part == "When" then return got[2] and "Would block this call." or "Would let this call through." end
		return "Would send: ("..plain(argList(table.pack(table.unpack(got, 2, got.n))))..")"
	end

	-- A condition that is true for the calls with the same text, numbers and true/false values as this one
	-- (the other arguments are left out), or nil when it has none of those
	RemoteSpy.LikeCall = function(call)
		local parts = {}
		for i = 1, call.Args.n do
			local v = call.Args[i]
			local kind = type(v)
			if (kind == "string" and #v <= 200) or kind == "boolean" or (kind == "number" and v == v and v ~= math.huge and v ~= -math.huge) then
				parts[#parts+1] = ("args[%d] == %s"):format(i, (Lib.ToLua(v)))
			end
		end
		return #parts > 0 and table.concat(parts, " and ") or nil
	end

	-- Gives a remote its rules, typed as Luau with args for a call's arguments: when a call is blocked, and
	-- what is sent in place of its arguments. An empty text takes that rule off. False and the reason when
	-- it can't be done.
	RemoteSpy.SetRule = function(remote, when, args)
		local texts = {When = when ~= "" and when or nil, Args = args ~= "" and args or nil}
		if not FIRE[remote.ClassName] then return false, "That is not a remote" end
		local rule = {WhenText = texts.When, ArgsText = texts.Args}
		for key, text in pairs(texts) do
			local fn, why = RemoteSpy.Compile(text)
			if not fn then return false, why end
			rule[key] = fn
		end
		if next(texts) and not hook() then return false, RemoteSpy.Unavailable or "The hook could not be made" end
		spy.Rules[remote] = next(texts) and rule or nil
		if next(texts) then logFor(remote, "Out") end
		dirty = true
		return true
	end

	RemoteSpy.Start, RemoteSpy.Stop = start, stop

	-- Called by Main.Uninit (Reload OpenDex): the listeners go and nothing more is listed. The hooks stay,
	-- for what is blocked and for the OpenDex that starts next.
	RemoteSpy.Unload = stop

	Main.Track(service.RunService.Heartbeat:Connect(function(dt)
		drain()
		if #watched > 0 then tend(dt) end
		sinceDrawn = sinceDrawn + dt
		if (dirty or (awaited and awaited.Returned)) and sinceDrawn >= 0.25 and window and window:IsContentVisible() then render() end
	end))

	-- The window. One row of tools; under it the remotes at the left (a search and a filter over the list),
	-- and at the right the remote that is picked: what can be done with it, its calls, and under them the
	-- call that is picked, with what can be done with that.
	RemoteSpy.Init = function()
		local theme = Settings.Theme
		local ROW_H, TOP, FROM_W, LEFT = 20, 28, 130, 0.36
		local tab, needle, filter = "Out", "", "All" -- the direction listed, the search box in small letters, the chip that is on
		local hovered, drawn = nil, false -- the row under the mouse; the call the code is of (false: none drawn yet)
		local callRows, order = {}, 0
		local rules = {} -- the Rules window: its parts, the remote it is for, and what it last tried

		window = Lib.Window.new()
		window:SetTitle("Remote Spy")
		window:SetLayoutId("RemoteSpy")
		window:Resize(640,420)
		window.MinX = 430
		RemoteSpy.Window = window
		local content = window.GuiElems.Content

		-- (the Local events switch is kept with the window layout)
		local saved = Main.Layout.Extra("RemoteSpy")
		if type(saved) == "table" then spy.Bindables = saved.bindables == true end
		Main.Layout.Providers.RemoteSpy = function()
			return {bindables = spy.Bindables}
		end

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

		-- A button that is a switch is lit while it is on
		local function lit(btn, on)
			btn.Anim.StartColor = on and theme.ListSelection or theme.Button
			btn.BackgroundColor3 = btn.Anim.StartColor
		end

		local function list(name, parent, position, size)
			local frame = createSimple("ScrollingFrame", {
				Name = name,
				Active = true,
				BackgroundColor3 = theme.Main2,
				BorderSizePixel = 0,
				CanvasSize = UDim2.new(0,0,0,0),
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = theme.Highlight,
				Position = position,
				Size = size,
				Parent = parent,
			})
			createSimple("UIStroke", {Color = theme.Outline1, Parent = frame})
			return frame
		end

		-- A row's background: the selection colour, a tint under the mouse, or none
		local function back(gui, selected)
			gui.BackgroundColor3 = selected and theme.ListSelection or theme.Button
			gui.BackgroundTransparency = (selected or hovered == gui) and 0 or 1
		end

		local function pick(log)
			current, shown = log, log and log.Calls[#log.Calls]
			render()
		end

		local function showCall(call)
			shown = call
			render()
		end

		-- The states a remote can be in: the word its row says, and what the chips over the list filter by
		local STATES = {
			{Name = "All", Has = function(log) return not spy.Ignore[log.Remote] end, None = "No remote matches the search."},
			{Name = "Blocked", Word = "blocked", Has = function(log) return log.Dir == "Out" and spy.Block[log.Remote] ~= nil end, None = "No remote is blocked."},
			{Name = "Rules", Word = "rule", Has = function(log) return log.Dir == "Out" and spy.Rules[log.Remote] ~= nil end, None = "No remote has rules."},
			{Name = "Hidden", Word = "hidden", Has = function(log) return spy.Ignore[log.Remote] ~= nil end, None = "No remote is hidden."},
		}

		-- The toolbar: the switch, the two directions, and at the right Clear and what is rarely needed
		local spyButton = button(content, "", "Lists the game's remote calls while it is on", UDim2.new(0,4,0,3), UDim2.new(0,56,0,22), function()
			if spy.On then stop() else start() end
			render()
		end)
		local tabs = {}
		for i, dir in ipairs({"Out", "In"}) do
			tabs[dir] = button(content, "", dir == "Out" and "What the game's scripts send to the server" or "What the server fires at the client or invokes on it", UDim2.new(0,i == 1 and 66 or 132,0,3), UDim2.new(0,i == 1 and 66 or 92,0,22), function()
				if tab == dir then return end
				tab = dir
				pick(nil)
			end)
		end
		button(content, "Clear", "Forget the calls listed so far (a blocked remote stays in the list)", UDim2.new(1,-80,0,3), UDim2.new(0,44,0,22), function()
			for _, logList in pairs(logs) do
				for i = #logList, 1, -1 do clear(logList[i]) end
			end
			render()
		end)

		local more = Lib.ContextMenu.new()
		more.Iconless = true
		more.Width = 170
		local moreButton
		moreButton = button(content, "...", "More: local events, and taking every block, rule or hide off at once", UDim2.new(1,-32,0,3), UDim2.new(0,28,0,22), function()
			-- one of the three tables the hooks read, emptied (they keep reading the same table)
			local function all(name, field, none)
				more:Add({Name = name, Disabled = next(spy[field]) == nil, Reason = none, OnClick = function()
					local remotes = {}
					for remote in pairs(spy[field]) do remotes[#remotes+1] = remote end
					for _, remote in ipairs(remotes) do
						if field == "Block" then RemoteSpy.SetBlocked(remote, false) else spy[field][remote] = nil end
					end
					render()
				end})
			end
			more:Clear()
			more:Add({Name = spy.Bindables and "Local events: on" or "Local events: off", Tooltip = "List Fire and Invoke of BindableEvents and BindableFunctions too (they stay inside the client)", OnClick = function()
				spy.Bindables = not spy.Bindables
				render()
			end})
			more:AddDivider()
			all("Unblock all", "Block", "No remote is blocked")
			all("Remove all rules", "Rules", "No remote has rules")
			all("Show all hidden", "Ignore", "No remote is hidden")
			local at = moreButton.Gui.AbsolutePosition
			more:Show(at.X, at.Y + 24)
		end)

		-- At the left: a search and the chips, over the list they narrow
		local body = createSimple("Frame", {Name = "Body", BackgroundTransparency = 1, Position = UDim2.new(0,4,0,TOP), Size = UDim2.new(1,-8,1,-(TOP + 4)), Parent = content})
		local search = Lib.ViewportTextBox.new()
		search.Position = UDim2.new(0,0,0,0)
		search.Size = UDim2.new(LEFT,-3,0,22)
		search.TextBox.PlaceholderText = "Search remotes"
		search.TextBox.PlaceholderColor3 = theme.PlaceholderText
		search.Gui.Parent = body
		search.TextBox:GetPropertyChangedSignal("Text"):Connect(function()
			needle = search.TextBox.Text:lower()
			render()
		end)

		local chipBar = createSimple("Frame", {Name = "Chips", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.new(0,0,0,26), Size = UDim2.new(LEFT,-3,0,18), Parent = body})
		createSimple("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0,4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = chipBar})
		for i, state in ipairs(STATES) do
			state.Chip = createSimple("TextButton", {
				Name = state.Name,
				AutoButtonColor = false,
				AutomaticSize = Enum.AutomaticSize.X,
				BorderSizePixel = 0,
				Font = Enum.Font.SourceSans,
				TextSize = 13,
				TextColor3 = theme.Text,
				Text = state.Name,
				Size = UDim2.new(0,0,1,0),
				LayoutOrder = i,
				Parent = chipBar,
			})
			createSimple("UICorner", {CornerRadius = UDim.new(0,3), Parent = state.Chip})
			createSimple("UIPadding", {PaddingLeft = UDim.new(0,6), PaddingRight = UDim.new(0,6), Parent = state.Chip})
			state.Chip.MouseButton1Click:Connect(function()
				filter = state.Name
				render()
			end)
		end

		local remoteList = list("Remotes", body, UDim2.new(0,0,0,48), UDim2.new(LEFT,-3,1,-48))
		remoteList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		createSimple("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = remoteList})
		local hint = label(body, "", UDim2.new(0,6,0,52), UDim2.new(LEFT,-15,0,120), theme.ReadOnlyText) -- why the list is empty
		hint.Name = "Hint"
		hint.TextWrapped = true
		hint.TextTruncate = Enum.TextTruncate.None
		hint.TextYAlignment = Enum.TextYAlignment.Top

		-- At the right: a line of help until a remote is picked, then that remote
		local right = createSimple("Frame", {Name = "Right", BackgroundTransparency = 1, Position = UDim2.new(LEFT,3,0,0), Size = UDim2.new(1 - LEFT,-3,1,0), Parent = body})
		local help = label(right, "Pick a remote on the left to see its calls.", UDim2.new(0,6,0,4), UDim2.new(1,-12,0,40), theme.ReadOnlyText)
		help.Name = "Help"
		help.TextWrapped = true
		help.TextTruncate = Enum.TextTruncate.None
		help.TextYAlignment = Enum.TextYAlignment.Top
		local detail = createSimple("Frame", {Name = "Detail", BackgroundTransparency = 1, Size = UDim2.new(1,0,1,0), Visible = false, Parent = right})

		-- its name, where it is and how often it was called; under them its buttons and what its rules say
		local head = {}
		head.Name = label(detail, "", UDim2.new(0,2,0,0), UDim2.new(0.4,-2,0,20), theme.Text)
		head.Name.Font = Enum.Font.SourceSansBold
		head.Path = label(detail, "", UDim2.new(0.4,4,0,0), UDim2.new(0.6,-60,0,20), theme.ReadOnlyText)
		head.Count = label(detail, "", UDim2.new(1,-54,0,0), UDim2.new(0,52,0,20), theme.ReadOnlyText)
		head.Count.TextXAlignment = Enum.TextXAlignment.Right
		head.Rule = label(detail, "", UDim2.new(0,202,0,22), UDim2.new(1,-230,0,22), theme.Warning)
		head.Clear = button(detail, "x", "Take this remote's rules off", UDim2.new(1,-24,0,22), UDim2.new(0,22,0,22), function()
			RemoteSpy.SetRule(current.Remote, "", "")
			render()
		end)
		Lib.Tooltip.attach(head.Path, function() return current and current.Path end)
		Lib.Tooltip.attach(head.Rule, function() return head.Rule.Text end)

		local lower = createSimple("Frame", {Name = "Calls", BackgroundTransparency = 1, Position = UDim2.new(0,0,0,48), Size = UDim2.new(1,0,1,-48), Parent = detail})
		local callList = list("List", lower, UDim2.new(0,0,0,0), UDim2.new(1,0,0.42,-3))
		local code = Lib.CodeFrame.new()
		code.Frame.Position = UDim2.new(0,0,0.42,28)
		code.Frame.Size = UDim2.new(1,0,0.58,-28)
		code.Frame.Parent = lower

		-- The Rules window, in a window of its own, for one remote and made when it is first opened. Over it,
		-- the call that is picked with its arguments to click; under them two boxes of Luau (when a call is
		-- blocked, and what is sent in place of its arguments) with what each would do with that call; and
		-- Save, which is what turns a rule on. It goes to the remote that is picked.
		local ARGS = 8 -- arguments shown
		local argRows = {}
		local function trim(text) return text:match("^%s*(.-)%s*$") end

		-- the call that is picked, when it is one of the remote the window is for
		local function sample()
			return current and current.Remote == rules.For and shown or nil
		end

		local function argRow(i)
			local gui = createSimple("TextButton", {
				Name = "Arg",
				AutoButtonColor = false,
				BackgroundColor3 = theme.Button,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Text = "",
				Position = UDim2.new(0,0,0,(i - 1) * 18),
				Size = UDim2.new(1,0,0,18),
				Parent = rules.List,
			})
			local row = {Gui = gui}
			label(gui, "args["..i.."]", UDim2.new(0,5,0,0), UDim2.new(0,52,1,0), theme.Text)
			row.Value = label(gui, "", UDim2.new(0,62,0,0), UDim2.new(1,-140,1,0), theme.Text)
			row.Kind = label(gui, "", UDim2.new(1,-74,0,0), UDim2.new(0,68,1,0), theme.ReadOnlyText)
			row.Kind.TextXAlignment = Enum.TextXAlignment.Right
			gui.MouseEnter:Connect(function() gui.BackgroundTransparency = 0 end)
			gui.MouseLeave:Connect(function() gui.BackgroundTransparency = 1 end)
			gui.MouseButton1Click:Connect(function() rules.Insert("args["..i.."]") end)
			Lib.Tooltip.attach(gui, "Click to add args["..i.."] to the box you were typing in")
			argRows[i] = row
			return row
		end

		local function buildRules()
			local win = Lib.Window.new()
			win.Alignable = false
			win:Resize(480,360)
			rules.Window = win
			local pane = win.GuiElems.Content

			local intro = label(pane, "Rules act on the calls the game sends through this remote (the Block button stops all of them). In a box, args[1] is a call's first argument and args[2] its second. Click an argument below to use it, or press Use example.", UDim2.new(0,8,0,4), UDim2.new(1,-16,0,48), theme.ReadOnlyText)
			intro.TextSize = 13
			intro.TextWrapped = true
			intro.TextTruncate = Enum.TextTruncate.None
			intro.TextYAlignment = Enum.TextYAlignment.Top

			rules.Heading = label(pane, "", UDim2.new(0,8,0,56), UDim2.new(1,-160,0,20), theme.Text)
			rules.LikeButton = button(pane, "Block calls like this", "Fill the first box with a condition that matches the calls with the same text, numbers and true/false values as this one", UDim2.new(1,-148,0,56), UDim2.new(0,140,0,20), function() rules.Like(sample()) end)
			rules.List = list("Arguments", pane, UDim2.new(0,8,0,80), UDim2.new(1,-16,0,72))

			-- the two rules: a title and its example, the box, and under them the line of what it would do
			rules.Parts = {
				{Key = "When", Title = "Block a call when...", Example = 'args[1] == "Sword"', Tag = "Block when: ", Empty = "nothing is blocked."},
				{Key = "Args", Title = "Change what is sent to...", Example = "args[1], 999", Tag = "Change: ", Empty = "calls are sent as they are."},
			}
			for i, spec in ipairs(rules.Parts) do
				local y = 158 + (i - 1) * 46
				label(pane, spec.Title, UDim2.new(0,8,0,y), UDim2.new(1,-100,0,20), theme.Text)
				local box = createSimple("TextBox", {
					Name = spec.Key,
					BackgroundColor3 = theme.TextBox,
					BorderColor3 = theme.Outline3,
					ClearTextOnFocus = false,
					Font = Enum.Font.SourceSans,
					PlaceholderColor3 = theme.PlaceholderText,
					PlaceholderText = "e.g. "..spec.Example,
					Text = "",
					TextColor3 = theme.Text,
					TextSize = 14,
					TextXAlignment = Enum.TextXAlignment.Left,
					Position = UDim2.new(0,8,0,y + 20),
					Size = UDim2.new(1,-16,0,22),
					Parent = pane,
				})
				createSimple("UIPadding", {PaddingLeft = UDim.new(0,4), PaddingRight = UDim.new(0,4), Parent = box})
				spec.Box = box
				spec.Line = label(pane, "", UDim2.new(0,8,0,250 + (i - 1) * 16), UDim2.new(1,-16,0,16), theme.ReadOnlyText)
				button(pane, "Use example", "Put "..spec.Example.." in the box", UDim2.new(1,-92,0,y), UDim2.new(0,84,0,20), function()
					box.Text = spec.Example
					rules.Refresh(true)
				end)
				box.Focused:Connect(function() rules.Last = box end)
				box.FocusLost:Connect(function(enter)
					if enter then rules.Save() else rules.Refresh(true) end
				end)
				box:GetPropertyChangedSignal("Text"):Connect(function() rules.Refresh(false) end)
			end
			rules.Last = rules.Parts[1].Box
			rules.Status = label(pane, "", UDim2.new(0,8,0,288), UDim2.new(1,-16,0,16), theme.ReadOnlyText)
			button(pane, "Save", "Turn the rule on for this remote's calls from now on", UDim2.new(0,8,0,312), UDim2.new(0,90,0,22), function() rules.Save() end)
			button(pane, "Remove rule", "Empty both boxes and take this remote's rule off", UDim2.new(0,104,0,312), UDim2.new(0,100,0,22), function() rules.Remove() end)
			rules.Listed, rules.Sample, rules.Seen = false, false, false

			-- Draws what the window shows: the boxes (when the rule changed from elsewhere), the arguments of the
			-- picked call, what each rule would do with it, and whether it is saved. A rule is run on the call
			-- when test is true, or the call is another one, and not on every key: it is the user's code.
			rules.Refresh = function(test)
				local remote = rules.For
				local rule = spy.Rules[remote]
				if rule ~= rules.Seen then
					rules.Seen = rule
					rules.Parts[1].Box.Text = rule and rule.WhenText or ""
					rules.Parts[2].Box.Text = rule and rule.ArgsText or ""
				end

				local call = sample()
				test = test or call ~= rules.Sample
				rules.Sample = call
				if call ~= rules.Listed then
					rules.Listed = call
					local args = call and call.Args
					local count = args and math.min(args.n, ARGS) or 0
					for i = 1, count do
						local row = argRows[i] or argRow(i)
						local v = args[i]
						row.Value.Text = plain((Lib.ToLua(v)))
						row.Kind.Text = typeof(v) == "Instance" and v.ClassName or typeof(v)
						row.Gui.Visible = true
					end
					for i = count + 1, #argRows do argRows[i].Gui.Visible = false end
					rules.List.CanvasSize = UDim2.new(0,0,0,count * 18)
					rules.Heading.Text = (not call and "Pick a call of this remote, in the Remote Spy window, to see its arguments.") or (args.n == 0 and "The call you picked has no arguments.") or "The call you picked (click an argument to use it):"
					rules.LikeButton:SetDisabled(call == nil)
				end

				local texts = {}
				for i, spec in ipairs(rules.Parts) do
					local text = trim(spec.Box.Text)
					texts[i] = text
					local line, color = spec.Tag.."empty, so "..spec.Empty, theme.ReadOnlyText
					if text ~= "" then
						local fn, why = RemoteSpy.Compile(text)
						if not fn then
							line, color = spec.Tag.."not valid Luau: "..why, theme.Danger
						elseif not call then
							line = spec.Tag.."pick a call of this remote to try it on."
						elseif test or (spec.Ran == text and spec.RanCall == call) then
							spec.Ran, spec.RanCall = text, call
							local words, bad = RemoteSpy.Try(spec.Key, fn, call)
							line, color = spec.Tag..words, bad and theme.Danger or theme.Text
						else
							line = spec.Tag.."press Enter, or click outside the box, to try it on this call."
						end
					end
					spec.Line.Text, spec.Line.TextColor3 = line, color
				end

				local status, color = "No rule on this remote.", theme.ReadOnlyText
				if (rule and rule.WhenText or "") ~= texts[1] or (rule and rule.ArgsText or "") ~= texts[2] then
					status, color = "Not saved yet: press Save, or Enter in a box, to turn it on.", theme.Warning
				elseif rule and rule.Error then
					status, color = "Saved, but it broke on a call ("..plainError(rule.Error).."). That call went out as it was.", theme.Danger
				elseif rule and spy.Block[remote] then
					status, color = "Saved, but this remote is blocked, so no call gets as far as the rule.", theme.Warning
				elseif rule then
					status, color = "Saved: the rule is on.", theme.Text
				end
				rules.Status.Text, rules.Status.TextColor3 = status, color
			end

			rules.Load = function(log)
				rules.For, rules.Seen = log.Remote, false
				win:SetTitle("Rules: "..log.Name)
				rules.Refresh(true)
			end

			rules.Save = function()
				local ok, why = RemoteSpy.SetRule(rules.For, trim(rules.Parts[1].Box.Text), trim(rules.Parts[2].Box.Text))
				if ok then rules.Seen = spy.Rules[rules.For] else Main.Notify("The rule was not set: "..tostring(why), "warn") end
				rules.Refresh(true)
				render()
			end

			rules.Remove = function()
				RemoteSpy.SetRule(rules.For, "", "")
				rules.Seen = false -- (so the boxes are emptied, saved or not)
				rules.Refresh(true)
				render()
			end

			-- Puts an argument in the box that was typed in last
			rules.Insert = function(text)
				local box = rules.Last
				local old = box.Text
				box.Text = old..((old == "" or old:find("%s$")) and "" or " ")..text
				box:CaptureFocus()
			end

			-- Fills the first box from a call
			rules.Like = function(call)
				local text = call and RemoteSpy.LikeCall(call)
				if not text then
					Main.Notify(call and "That call has no text, number or true/false argument to compare. Write the condition yourself." or "Pick a call first", "warn")
					return
				end
				rules.Parts[1].Box.Text = text
				rules.Refresh(true)
			end
		end

		local function showRules(log)
			if not rules.Window then buildRules() end
			rules.Load(log)
			rules.Window:Show()
		end

		-- What can be done with the remote and the call that are picked. One with a Bar is a button: beside
		-- the remote's name, or over the call's code. The others are in the right-click menu of a row, by
		-- Group. Why gives the reason one can't be done now.
		local function lacks(fn, name)
			return fn == nil and ("Your executor has no "..name) or nil
		end
		local function noCaller(_, call)
			if not call then return "Pick a call first" end
			if not call.Script then return call.Dir == "In" and "The server made this call" or "The script that made the call is not known" end
			return nil
		end
		local function noRules(log)
			return (log.Dir == "In" and "Rules are for what the game sends") or RemoteSpy.Unavailable or lacks(env.loadstring, "loadstring")
		end
		local actions = {
			{Name = function(log) return log and spy.Block[log.Remote] and "Unblock" or "Block" end, Bar = "remote", Tip = "Stop the game's scripts from firing this remote", Why = function(log)
				return (log.Dir == "In" and "Only what the game sends can be blocked") or RemoteSpy.Unavailable
			end, Run = function(log)
				RemoteSpy.SetBlocked(log.Remote, not spy.Block[log.Remote])
			end},
			{Name = "Rules", Bar = "remote", Tip = "Block only some of this remote's calls, or change what they send", Why = noRules, Run = function(log) showRules(log) end},
			{Name = function(log) return log and spy.Ignore[log.Remote] and "Show" or "Hide" end, Bar = "remote", Tip = "Stop listing this remote and its calls, or list them again (hidden remotes are under the Hidden chip)", Run = function(log)
				spy.Ignore[log.Remote] = not spy.Ignore[log.Remote] or nil
			end},
			{Name = "Copy code", Bar = "call", Tip = "Copy this call as the code that makes it again", Why = function(_, call)
				return (not call and "Pick a call first") or lacks(env.setclipboard, "setclipboard")
			end, Run = function(_, call)
				env.setclipboard(codeFor(call))
				Main.Notify("Copied the call as code", "success")
			end},
			{Name = "Resend", Bar = "call", Tip = "Make this call again. It is sent even when the remote is blocked", Why = function(_, call)
				return (not call and "Pick a call first") or (call.Dir == "In" and LISTEN[call.Remote.ClassName] and lacks(env.firesignal, "firesignal")) or nil
			end, Run = function(_, call) runAgain(call) end},
			{Name = "Go to call", Bar = "call", Tip = "Open the script that made this call, at the call", Why = noCaller, Run = function(log, call)
				ScriptViewer.ViewCall(call.Script, log.Remote, call.Method, call.Function)
			end},
			{Name = "Block calls like this", Group = "Remote", Why = function(log, call)
				return (not call and "Pick a call first") or noRules(log)
			end, Run = function(log, call)
				showRules(log)
				rules.Like(call)
			end},
			{Name = "Copy hook code", Group = "Remote", Why = function() return lacks(env.setclipboard, "setclipboard") end, Run = function(log)
				env.setclipboard(hookCode(log))
				Main.Notify("Copied code that catches this remote's calls", "success")
			end},
			{Name = "Copy path", Group = "Remote", Why = function() return lacks(env.setclipboard, "setclipboard") end, Run = function(log)
				env.setclipboard(Explorer.GetInstancePath(log.Remote))
			end},
			{Name = "Clear calls", Group = "Remote", Run = function(log) clear(log) end},
			{Name = "Find remote in Explorer", Group = "Find", Run = function(log)
				Explorer.SelectObj(log.Remote)
			end},
			{Name = "Find script in Explorer", Group = "Find", Why = noCaller, Run = function(_, call)
				Explorer.SelectObj(call.Script)
			end},
			{Name = "Where is it used?", Group = "Find", Why = function() return not env.isdecompile() and "Your executor has no decompiler" or nil end, Run = function(log)
				ScriptViewer.WhereUsed(log.Remote)
			end},
			{Name = "Who listens?", Group = "Find", Why = function() return lacks(env.getconnections, "getconnections") end, Run = function(log)
				ScriptViewer.ViewConnections(log.Remote)
			end},
		}
		local function whyNot(action)
			if not current then return "Pick a remote first" end
			return action.Why and action.Why(current, shown) or nil
		end

		-- Runs an action on what is picked, and draws what it changed
		local function run(action)
			if whyNot(action) then return end
			local ok, err = pcall(action.Run, current, shown)
			if not ok then Main.Notify(tostring(err), "error") end
			render()
		end

		-- the remote's buttons go under its name, the call's between the calls and the code
		local placed = {remote = 0, call = 0}
		for _, action in ipairs(actions) do
			local bar = action.Bar
			if bar then
				local parent, scale, y, width = detail, 0, 22, 62
				if bar == "call" then parent, scale, y, width = lower, 0.42, 3, 90 end
				action.Button = button(parent, "", function()
					return whyNot(action) or action.Tip
				end, UDim2.new(0,placed[bar] * (width + 4),scale,y), UDim2.new(0,width,0,22), function() run(action) end)
				placed[bar] = placed[bar] + 1
			end
		end

		local menu = Lib.ContextMenu.new()
		menu.Iconless = true
		menu.Width = 180
		local function showMenu()
			if not current then return end
			menu:Clear()
			for _, group in ipairs({"Remote", "Find"}) do
				menu:AddDivider(group)
				for _, action in ipairs(actions) do
					if action.Group == group then
						local why = whyNot(action)
						menu:Add({Name = action.Name, Disabled = why ~= nil, Reason = why, OnClick = function() run(action) end})
					end
				end
			end
			menu:Show(Main.Mouse.X, Main.Mouse.Y)
		end

		-- A row: the tint under the mouse, and what a click and a right click on it pick
		local function wire(gui, isPicked, onPick)
			gui.MouseEnter:Connect(function()
				hovered = gui
				back(gui, isPicked())
			end)
			gui.MouseLeave:Connect(function()
				if hovered == gui then hovered = nil end
				back(gui, isPicked())
			end)
			gui.MouseButton1Click:Connect(onPick)
			gui.MouseButton2Click:Connect(function()
				onPick()
				showMenu()
			end)
		end

		local function remoteRow(log)
			order = order + 1
			local gui = createSimple("TextButton", {
				Name = "Remote",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Text = "",
				Size = UDim2.new(1,0,0,ROW_H),
				LayoutOrder = order,
				Parent = remoteList,
			})
			local icon = createSimple("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0,3,0,2), Size = UDim2.new(0,16,0,16), Parent = gui})
			Main.MiscIcons:DisplayExplorerIcons(icon, log.Remote.ClassName)
			local row = {Gui = gui}
			row.Name = label(gui, log.Name, UDim2.new(0,23,0,0), UDim2.new(1,-72,1,0), theme.Text)
			row.Count = label(gui, "", UDim2.new(1,-114,0,0), UDim2.new(0,108,1,0), theme.ReadOnlyText) -- its state in a word, and its count
			row.Count.TextXAlignment = Enum.TextXAlignment.Right
			wire(gui, function() return log == current end, function() pick(log) end)
			Lib.Tooltip.attach(gui, log.Path)
			log.Row = row
			return row
		end

		-- The rows of the calls are made once and show whichever calls are listed now, the newest at the top
		local function callRow(i)
			local gui = createSimple("TextButton", {
				Name = "Call",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Text = "",
				Position = UDim2.new(0,0,0,(i - 1) * ROW_H),
				Size = UDim2.new(1,0,0,ROW_H),
				Parent = callList,
			})
			local row = {Gui = gui}
			row.Text = label(gui, "", UDim2.new(0,5,0,0), UDim2.new(1,-(FROM_W + 16),1,0), theme.Text)
			row.From = label(gui, "", UDim2.new(1,-(FROM_W + 8),0,0), UDim2.new(0,FROM_W,1,0), theme.ReadOnlyText)
			row.From.TextXAlignment = Enum.TextXAlignment.Right
			wire(gui, function() return row.Call == shown end, function() showCall(row.Call) end)
			Lib.Tooltip.attach(gui, function() return row.Call and ("At "..row.Call.At) end)
			callRows[i] = row
			return row
		end

		local function emptyNote(state)
			if state.Name ~= "All" then return state.None end
			if tab == "Out" and RemoteSpy.Unavailable then return RemoteSpy.Unavailable..": what the game sends can't be listed." end
			if tab == "In" and not (env.getconnections or env.getcallbackvalue) then return "Your executor has no getconnections: what the server sends can't be listed." end
			if #logs[tab] > 0 then return state.None end
			if not spy.On then return "Paused. Press Paused, above, to list the calls." end
			return tab == "Out" and "Waiting for the game to fire a remote." or "Waiting for the server to fire a remote at the client."
		end

		render = function()
			dirty, sinceDrawn = false, 0

			spyButton.Text = spy.On and "Spying" or "Paused"
			lit(spyButton, spy.On)
			for dir, btn in pairs(tabs) do
				btn.Text = (dir == "Out" and "Sent " or "Received ")..#logs[dir]
				lit(btn, dir == tab)
			end

			-- the remotes: the ones of this direction that the chip and the search leave
			local listed, counts, chosen = 0, {}, STATES[1]
			for _, state in ipairs(STATES) do
				if state.Name == filter then chosen = state end
			end
			for dir, logList in pairs(logs) do
				for _, log in ipairs(logList) do
					local row = log.Row or (dir == tab and remoteRow(log))
					local word
					for _, state in ipairs(STATES) do
						if dir == tab and state.Has(log) then
							counts[state.Name] = (counts[state.Name] or 0) + 1
							word = word or state.Word
						end
					end
					if row then
						local remote = log.Remote
						local visible = dir == tab and chosen.Has(log) and (needle == "" or log.Lower:find(needle, 1, true) ~= nil)
						if visible then listed = listed + 1 end
						row.Gui.Visible = visible
						row.Count.Text = (word and (word.."  ") or "")..(log.Count > 0 and ("x"..log.Count) or "")
						row.Name.Size = UDim2.new(1,word and -136 or -72,1,0)
						-- red: blocked; amber: it has rules; dim: its calls are hidden
						row.Name.TextColor3 = (dir == "Out" and ((spy.Block[remote] and theme.Danger) or (spy.Rules[remote] and theme.Warning))) or (spy.Ignore[remote] and theme.ReadOnlyText) or theme.Text
						back(row.Gui, log == current)
					end
				end
			end
			for _, state in ipairs(STATES) do
				local count = state.Name ~= "All" and counts[state.Name]
				state.Chip.Text = state.Name..(count and (" "..count) or "")
				state.Chip.BackgroundColor3 = state == chosen and theme.ListSelection or theme.Button
			end
			hint.Text = listed == 0 and emptyNote(chosen) or ""

			-- the remote that is picked
			help.Visible = current == nil
			detail.Visible = current ~= nil
			if current then
				local rule, says = current.Dir == "Out" and spy.Rules[current.Remote] or nil, {}
				if rule and rule.Error then
					says[1] = "The rule broke: "..plainError(rule.Error)
				elseif rule then
					if rule.WhenText then says[#says+1] = "Blocks when "..rule.WhenText end
					if rule.ArgsText then says[#says+1] = "Sends "..rule.ArgsText.." instead" end
				end
				head.Name.Text = current.Name
				head.Path.Text = current.Path
				head.Count.Text = "x"..current.Count
				head.Rule.Text = table.concat(says, "; ")
				head.Rule.TextColor3 = rule and rule.Error and theme.Danger or theme.Warning
				head.Clear.Gui.Visible = rule ~= nil
			end

			-- its calls (a remote picked before it had any shows its first when it comes)
			local calls = current and current.Calls or {}
			if current and not shown then shown = calls[#calls] end
			local count = math.min(#calls, SHOWN)
			for i = 1, count do
				local call = calls[#calls - i + 1]
				local row = callRows[i] or callRow(i)
				if not call.Brief then
					local ok, text, from = pcall(describe, call)
					call.Brief, call.From = ok and text or "?", ok and from or "?"
				end
				row.Call = call
				row.Text.Text = call.Brief
				row.Text.TextColor3 = (call.Blocked and theme.Danger) or (call.Sent and theme.Warning) or theme.Text
				row.From.Text = call.From
				row.Gui.Visible = true
				back(row.Gui, call == shown)
			end
			for i = count + 1, #callRows do callRows[i].Gui.Visible = false end
			callList.CanvasSize = UDim2.new(0,0,0,count * ROW_H)

			-- the call that is picked, as code
			if shown ~= drawn or (awaited and awaited.Returned) then
				drawn = shown
				awaited = shown and RETURNS[shown.Method] and not shown.Returned and not shown.Blocked and shown or nil
				local ok, text = true, "-- Pick a call to see it as code"
				if shown then ok, text = pcall(codeFor, shown) end
				code:SetText(ok and text or ("-- This call could not be written as code: "..plain(text)))
			end

			for _, action in ipairs(actions) do
				if action.Button then
					action.Button.Text = type(action.Name) == "function" and action.Name(current) or action.Name
					action.Button:SetDisabled(whyNot(action) ~= nil)
				end
			end

			-- the Rules window goes to the remote that is picked, and shows what its rule does with the picked call
			if rules.Window and rules.Window:IsVisible() then
				if current and current.Dir == "Out" and current.Remote ~= rules.For then rules.Load(current) end
				rules.Refresh()
			end
		end

		-- Explorer: "View in Remote Spy" on a remote. Opens the window on it and lists its calls from now on.
		RemoteSpy.View = function(remote)
			window:Show()
			if BINDABLE[remote.ClassName] then spy.Bindables = true end
			spy.Ignore[remote] = nil
			start()
			local log = logFor(remote, "Out")
			if not log then
				Main.Notify("Roblox's own remotes are not listed", "warn")
				return
			end
			tab, filter = "Out", "All"
			search:SetText("") -- (so that its row is in sight)
			pick(log)
		end

		-- The AI window (Agent.lua; what the agent is told is in mcp/tools.json): the calls that were caught,
		-- and a rule put in the Rules window for the user to read and save
		if Apps.Agent then
			local Agent = Apps.Agent
			local reg = Agent.Register

			local function clip(text, max)
				return #text > max and (text:sub(1, max).."... ("..(#text - max).." more characters)") or text
			end

			-- the remote a path or name stands for, among those seen in one direction
			local function logNamed(dir, ref)
				if type(ref) ~= "string" or ref == "" then error("remote is needed: its path or name, as remote_log lists them", 0) end
				local want = ref:lower():gsub("^game%.", "")
				local exact, partial = {}, {}
				for _, log in ipairs(logs[dir]) do
					if log.Path:lower() == want or log.Name:lower() == want then
						exact[#exact+1] = log
					elseif log.Lower:find(want, 1, true) then
						partial[#partial+1] = log
					end
				end
				local matches = #exact > 0 and exact or partial
				if #matches == 1 then return matches[1] end
				if #matches == 0 then
					error(("no remote called '%s' has been seen (%s): remote_log without a remote lists them"):format(ref, dir == "Out" and "sent by the game" or "sent by the server"), 0)
				end
				local names = {}
				for i = 1, math.min(#matches, 5) do names[i] = matches[i].Path end
				error(("%d remotes match '%s': %s. Use the full path"):format(#matches, ref, table.concat(names, ", ")), 0)
			end

			local function text(args)
				local ok, written = pcall(argList, args)
				return clip(ok and written or "?", 600)
			end

			reg("remote_log", function(args)
				local dir = args.direction == "In" and "In" or "Out"
				if args.remote == nil then
					local out = {}
					for _, log in ipairs(logs[dir]) do
						out[#out+1] = {remote = log.Path, class = log.Remote.ClassName, calls = log.Count,
							blocked = (dir == "Out" and spy.Block[log.Remote]) and true or nil, rule = (dir == "Out" and spy.Rules[log.Remote]) and true or nil}
					end
					table.sort(out, function(a, b) return a.calls > b.calls end)
					local total = #out
					for i = 101, total do out[i] = nil end
					return {direction = dir, spyRunning = spy.On and true or false, total = total, remotes = out}
				end

				local log = logNamed(dir, args.remote)
				local limit = math.clamp(math.floor(tonumber(args.limit) or 5), 1, 20)
				local calls = {}
				for i = #log.Calls, math.max(1, #log.Calls - limit + 1), -1 do
					local call = log.Calls[i]
					local entry = {at = call.At, method = call.Method, args = text(call.Args), blocked = call.Blocked and true or nil}
					if call.Returned then entry.returned = text(call.Returned) end
					if call.Sent then entry.sentInstead = text(call.Sent) end
					if call.Script then
						local ok, path = pcall(getFullName, call.Script)
						entry.script, entry.scriptPath = Agent.IdOf(call.Script), ok and path or nil
					end
					if call.Function and call.Function ~= "" then entry["function"] = call.Function end
					if call.Line and call.Line > 0 then entry.runtimeLine = call.Line end -- (a line of the running script, not of the decompile)
					calls[#calls+1] = entry
				end
				local rule = dir == "Out" and spy.Rules[log.Remote]
				return {remote = log.Path, class = log.Remote.ClassName, direction = dir, calls = log.Count, blocked = (dir == "Out" and spy.Block[log.Remote]) and true or nil,
					rule = rule and {when = rule.WhenText, args = rule.ArgsText} or nil, newest = calls}
			end)

			-- every remote there is, used or not: the game's objects, and those parented to nothing
			reg("remotes", function(args)
				local limit = math.clamp(math.floor(tonumber(args.limit) or 100), 1, 500)
				local query = type(args.query) == "string" and args.query ~= "" and args.query:lower() or nil
				local out, total = {}, 0
				local function add(inst, orphan)
					local class = inst.ClassName
					if not FIRE[class] or (BINDABLE[class] and args.bindables ~= true) or isInternal(inst) then return end
					local ok, path = pcall(getFullName, inst)
					path = ok and path or inst.Name
					if query and not path:lower():find(query, 1, true) then return end
					total = total + 1
					if #out >= limit then return end
					local sent, received = logOf.Out[inst], logOf.In[inst]
					out[#out+1] = {remote = path, class = class, sent = sent and sent.Count or 0, received = received and received.Count or 0,
						blocked = spy.Block[inst] and true or nil, notInGame = orphan}
				end
				for _, inst in ipairs(game:GetDescendants()) do pcall(add, inst) end
				local ok, orphans = pcall(env.getnilinstances or error)
				for _, inst in ipairs(ok and type(orphans) == "table" and orphans or {}) do pcall(add, inst, true) end
				return {spyRunning = spy.On and true or false, total = total, shown = #out, remotes = out}
			end)

			reg("suggest_rule", function(args)
				if RemoteSpy.Unavailable then error(RemoteSpy.Unavailable, 0) end
				if not env.loadstring then error("Your executor has no loadstring, which rules need", 0) end
				local when = type(args.when) == "string" and trim(args.when) or ""
				local replace = type(args.args) == "string" and trim(args.args) or ""
				if when == "" and replace == "" then error("give when, args or both", 0) end
				for _, part in ipairs({{"when", when}, {"args", replace}}) do
					if part[2] ~= "" then
						local problem = Analysis.RuleProblem(part[2])
						if problem then error(("%s was not accepted: %s"):format(part[1], problem), 0) end
						local fn, why = RemoteSpy.Compile(part[2])
						if not fn then error(("%s is not valid Luau: %s"):format(part[1], why), 0) end
					end
				end
				local log = logNamed("Out", args.remote)
				showRules(log)
				if when ~= "" then rules.Parts[1].Box.Text = when end
				if replace ~= "" then rules.Parts[2].Box.Text = replace end
				rules.Refresh(true)
				return {remote = log.Path, when = when ~= "" and when or nil, args = replace ~= "" and replace or nil,
					note = "The Rules window shows it. Nothing is on until the user presses Save."}
			end)
		end

		-- The first time the window opens, the spy starts by itself
		local begun = false
		window.OnActivate:Connect(function()
			if not begun then
				begun = true
				start()
			end
			render()
		end)
		window.OnRestore:Connect(render)
		render()
	end

	return RemoteSpy
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
