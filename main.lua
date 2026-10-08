-- Main vars
local Main, Explorer, Properties, ScriptViewer, Console, RemoteSpy, SaveInstance, ModelViewer, SettingsWindow, CommandPalette, Agent, DefaultSettings, Lib
local API, RMD

-- Default Settings
DefaultSettings = (function()
	local rgb = Color3.fromRGB	
	
	return {
		Explorer = {
			_Recurse = true,
			Sorting = true,
			ClickToRename = true,
			AutoUpdateSearch = true,
			PartSelectionBox = true,
			GuiSelectionBox = true,
			CopyPathUseGetChildren = true,
			UseNameWidth = false
		},
		Properties = {
			_Recurse = true,
			MaxConflictCheck = 50,
			ShowDeprecated = true,
			ShowHidden = false,
			ClearOnFocus = false,
			NumberRounding = 3,
			ShowAttributes = true,
			MaxAttributes = 50,
			ScaleType = 0 -- 0 Full Name Shown, 1 Equal Halves
		},
		Theme = {
			_Recurse = true,
			Main1 = rgb(52,52,52),
			Main2 = rgb(45,45,45),
			Outline1 = rgb(33,33,33), -- Mainly frames
			Outline2 = rgb(55,55,55), -- Mainly button
			Outline3 = rgb(30,30,30), -- Mainly textbox
			TextBox = rgb(38,38,38),
			Menu = rgb(32,32,32),
			ListSelection = rgb(11,90,175),
			Button = rgb(60,60,60),
			ButtonHover = rgb(68,68,68),
			ButtonPress = rgb(40,40,40),
			Highlight = rgb(75,75,75),
			Text = rgb(255,255,255),
			PlaceholderText = rgb(100,100,100),
			ReadOnlyText = rgb(160,160,160), -- read-only values and hints: dim, but readable (4.5:1 on the window colours)
			Important = rgb(255,0,0),
			Info = rgb(70,150,255), -- toasts and status colours
			Success = rgb(70,190,100),
			Warning = rgb(240,160,50),
			Danger = rgb(230,80,80),
			Syntax = {
				Text = rgb(204,204,204),
				Background = rgb(36,36,36),
				Selection = rgb(255,255,255),
				SelectionBack = rgb(11,90,175),
				Operator = rgb(204,204,204),
				Number = rgb(255,198,0),
				String = rgb(173,241,149),
				Comment = rgb(140,140,140),
				Note = rgb(229,192,123), -- the Notepad's notes, which sit in comments
				Keyword = rgb(248,109,124),
				BuiltIn = rgb(132,214,247),
				LocalMethod = rgb(253,251,172),
				LocalProperty = rgb(97,161,241),
				Nil = rgb(255,198,0),
				Bool = rgb(255,198,0),
				Function = rgb(248,109,124),
				Local = rgb(248,109,124),
				Self = rgb(248,109,124),
				FunctionName = rgb(253,251,172),
				Bracket = rgb(204,204,204)
			},
		},
		ScriptViewer = {
			_Recurse = true,
			ShowMoreInfo = true;
		},
		Window = {
			_Recurse = true,
			TitleOnMiddle = false,
			Transparency = 0
		},
		Decompiler = {
			_Recurse = true,
			DecompilerFallback = "Konstant", --Konstant, AdvancedDecompiler
			PreferDecompilerFallback = false,
		},
		
		ClassIcon = "NewDark",
		SettingsVersion = 2, -- bumped when a default colour or value changes (see Main.MigrateSettings)
		
		-- What available icons:
		-- > Vanilla3
		-- > NewDark
	}
end)()

-- Vars
local function deepCopy(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = type(v) == "table" and deepCopy(v) or v
	end
	return copy
end
local Settings = deepCopy(DefaultSettings)
local Apps = {}
local env = {}

local service = setmetatable({},{__index = function(self,name)
	local serv = cloneref(game:GetService(name))
	self[name] = serv
	return serv
end})
local plr = service.Players.LocalPlayer or service.Players.PlayerAdded:wait()

local create = function(data)
	local insts = {}
	for i,v in pairs(data) do insts[v[1]] = Instance.new(v[2]) end

	for _,v in pairs(data) do
		for prop,val in pairs(v[3]) do
			if type(val) == "table" then
				insts[v[1]][prop] = insts[val[1]]
			else
				insts[v[1]][prop] = val
			end
		end
	end

	return insts[1]
end

local createSimple = function(class,props)
	local inst = Instance.new(class)
	for i,v in next,props do
		inst[i] = v
	end
	return inst
end

Main = (function()
	local Main = {}

	Main.ModuleList = {"Explorer","Properties","ScriptAnalysis","Flowchart","ScriptViewer","Console","RemoteSpy","SaveInstance","ModelViewer","SettingsWindow","CommandPalette","Agent"}
	Main.Elevated = false
	Main.Version = "4.2"
	Main.DefaultSettings = DefaultSettings -- what Reset buttons in the settings go back to
	Main.Mouse = plr:GetMouse()
	Main.AppControls = {}
	Main.Apps = Apps
	Main.MenuApps = {}
	Main.MenuAppOrder = {} -- names in the order the menu tiles were made
	Main.DisplayOrders = {
		SideWindow = 8,
		Window = 10,
		Menu = 100000,
		Palette = 100500,
		Core = 101000,
		Toast = 101800,
		Tooltip = 102000
	}
	
	Main.Plugins = {}

	Main.Connections = {}
	Main.Track = function(conn)
		table.insert(Main.Connections, conn)
		return conn
	end

	-- Main.Notify(text, kind, opts) shows a toast (kind: "info", "success", "warn" or "error"). This is the
	-- stand-in until the library is loaded; Main.Init then swaps in the real one (Lib.Notify.show).
	Main.Notify = function(text, kind)
		if kind == "error" or kind == "warn" then warn("[OpenDex] "..tostring(text)) end
	end

	----------------------------------------------------------------------------------------------
	-- Commands: what the command palette lists. A provider is a function returning a list of
	-- {Name, Category, Run, Disabled (true, or the reason as a string)}; it runs each time the
	-- palette opens, so it can look at the selection, the open script and so on.
	----------------------------------------------------------------------------------------------

	Main.CommandProviders = {}
	Main.AddCommands = function(provider)
		table.insert(Main.CommandProviders, provider)
	end

	----------------------------------------------------------------------------------------------
	-- Layout: which windows are open and where, written to dex/layout.json as it changes
	----------------------------------------------------------------------------------------------

	local LAYOUT_FILE = "dex/layout.json"
	Main.Layout = {Providers = {}, ResetHandlers = {}}

	local dockedRight = {
		Explorer = {open = true, side = "right", pos = 1, h = 0.5},
		Properties = {open = true, side = "right", pos = 2, h = 0.5},
	}
	local function preset(extra)
		local windows = {}
		for id, st in pairs(dockedRight) do windows[id] = st end
		for id, st in pairs(extra or {}) do windows[id] = st end
		return {windows = windows, sides = {right = {hidden = false}}}
	end

	-- Explore: Explorer and Properties docked on the right, nothing else. Scripts: the same with the full-screen Script Viewer.
	Main.LayoutPresets = {
		Explore = preset(),
		Scripts = preset({Notepad = {open = true}}),
	}

	Main.Layout.Load = function()
		Main.Layout.Saved = nil
		local raw = Lib.ReadFile(LAYOUT_FILE)
		if not raw then return end
		local ok, data = pcall(service.HttpService.JSONDecode, service.HttpService, raw)
		if ok and type(data) == "table" then Main.Layout.Saved = data end
	end

	-- What a module keeps in the saved layout besides window positions (its own panes and sizes).
	-- Modules add a function to Main.Layout.Providers[name] that returns it, and read it back here.
	Main.Layout.Extra = function(name)
		local saved = Main.Layout.Saved
		return saved and type(saved.extras) == "table" and saved.extras[name] or nil
	end

	local function collectLayout()
		local layout = Lib.Window.GetLayout()
		layout.v = 1
		layout.extras = {}
		for name, provider in pairs(Main.Layout.Providers) do
			local ok, state = pcall(provider)
			if ok and state ~= nil then layout.extras[name] = state end
		end
		return layout
	end

	local lastLayoutJson
	local function encodeLayout()
		local ok, json = pcall(service.HttpService.JSONEncode, service.HttpService, collectLayout())
		return ok and json or nil
	end

	local function writeLayout(json)
		if not env.writefile then return end
		pcall(env.writefile, LAYOUT_FILE, json)
		lastLayoutJson = json
	end

	-- Writes the layout now, if it changed since it was last written (before a restart, say).
	Main.Layout.Flush = function()
		if not (Lib and Lib.Window and Lib.Window.GetLayout) then return end
		local json = encodeLayout()
		if json and json ~= lastLayoutJson then writeLayout(json) end
	end

	-- Once a second looks at the layout; once it has stopped changing, writes it. The settings are
	-- checked on the same tick.
	Main.Layout.StartAutosave = function()
		local pending, acc = nil, 0
		Main.Track(service.RunService.Heartbeat:Connect(function(dt)
			acc = acc + dt
			if acc < 1 then return end
			acc = 0
			Main.AutosaveSettings()
			local json = encodeLayout()
			if not json then return end
			if json ~= pending then
				pending = json
			elseif json ~= lastLayoutJson then
				writeLayout(json)
			end
		end))
	end

	-- Applies a layout from a thread of its own, because closing a floating window waits for its animation.
	Main.Layout.Apply = function(layout)
		task.spawn(Lib.Window.ApplyLayout, layout)
	end

	-- Opens the windows: the Explore layout, except when OpenDex is run again in the same game, which keeps
	-- the windows where the run before left them. What was open on an earlier visit is not remembered.
	Main.Layout.Restore = function()
		local layout = Main.Reloaded and Main.Layout.Saved
		if type(layout) ~= "table" or type(layout.windows) ~= "table" then layout = Main.LayoutPresets.Explore end

		-- the right panel slides in a moment after the windows are set up, as it always did
		local sides = layout.sides or {}
		local right = sides.right or {}
		Lib.Window.ApplyLayout({windows = layout.windows, sides = {left = sides.left, right = {w = right.w, hidden = true}}})
		if not right.hidden then
			Lib.FastWait()
			Lib.Window.SetSideVisible("right", true)
		end
	end

	Main.ApplyPreset = function(name)
		local layout = Main.LayoutPresets[name]
		if not layout then return end
		Main.Layout.Apply(layout)
		Main.Notify(name.." layout", "info")
	end

	Main.ResetLayout = function()
		Lib.Window.ResetPlacement()
		for _, handler in ipairs(Main.Layout.ResetHandlers) do pcall(handler) end
		Main.Layout.Apply(Main.LayoutPresets.Explore)
		Main.Notify("Window layout reset", "success")
	end

	
	Main.GetRandomString = function()
		local output = ""
		for i = 2, 25 do
			output = output .. string.char(math.random(1,250))
		end
		
		return output
	end
	
	Main.GetSecureContainer = function()
		return
			gethui and gethui() or
			((syn and syn.protect_gui or protect_gui or protectgui or Main.Elevated) and service.CoreGui) or
			service.Players.LocalPlayer:WaitForChild("PlayerGui")
	end
	
	-- Names a gui so Main.Uninit can find it and puts it where the game's scripts can't see it (gethui, or
	-- CoreGui after the executor's protect function when it has one).
	Main.SecureGui = function(gui)
		gui.Name = "_ODX_".. Main.GetRandomString()
		local protect = not gethui and ((syn and syn.protect_gui) or protect_gui or protectgui)
		if protect then protect(gui) end
		gui.Parent = Main.GetSecureContainer()
	end

	Main.GetInitDeps = function()
		return {
			Main = Main,
			Lib = Lib,
			Apps = Apps,
			Settings = Settings,

			API = API,
			RMD = RMD,
			env = env,
			service = service,
			plr = plr,
			create = create,
			createSimple = createSimple
		}
	end

	Main.Error = function(str)
		if rconsoleprint then
			rconsoleprint("DEX ERROR: "..tostring(str).."\n")
		end
		error(str)
	end

	Main.LoadModule = function(name)
		local control = EmbeddedModules and EmbeddedModules[name] and EmbeddedModules[name]() -- build.py puts every module in out.lua
		if not control then Main.Error("Missing Embedded Module: "..name) end

		Main.AppControls[name] = control
		control.InitDeps(Main.GetInitDeps())

		local moduleData = control.Main()
		Apps[name] = moduleData
		return moduleData
	end
	
	Main.LoadPluginFile = function(pluginDir)
		if env.readfile then
			if not env.isfile or env.isfile(pluginDir) then -- (a folder in dex/plugins is not a plugin)
				local preloadedPlugin, syntaxError = loadstring(env.readfile(pluginDir), "="..tostring(pluginDir))
				if not preloadedPlugin then error("it does not compile: "..tostring(syntaxError), 0) end
				local loadedPlugin = preloadedPlugin()

				local control = loadedPlugin
				control.InitDeps(Main.GetInitDeps())

				local moduleData = control.Main()
				Apps[pluginDir] = moduleData
				Main.AppControls[pluginDir] = control
				
				moduleData.PluginData = control.PluginData
				
				return moduleData
			else
				Main.Error("CANNOT FIND FILE MODULE "..pluginDir)
			end
		end
	end

	Main.LoadModules = function()
		for i,v in pairs(Main.ModuleList) do
			local s,e = pcall(Main.LoadModule,v)
			if not s then
				Main.Error("FAILED LOADING " .. v .. " CAUSE " .. e)
			end
		end

		-- Init Major Apps and define them in modules
		Explorer = Apps.Explorer
		Properties = Apps.Properties
		ScriptViewer = Apps.ScriptViewer
		Console = Apps.Console
		RemoteSpy = Apps.RemoteSpy
		SaveInstance = Apps.SaveInstance
		ModelViewer = Apps.ModelViewer
		SettingsWindow = Apps.SettingsWindow
		CommandPalette = Apps.CommandPalette
		Agent = Apps.Agent
		
		
		local appTable = {
			Explorer = Explorer,
			Properties = Properties,
			ScriptViewer = ScriptViewer,
			Console = Console,
			RemoteSpy = RemoteSpy,
			SaveInstance = SaveInstance,
			ModelViewer = ModelViewer,
			SettingsWindow = SettingsWindow
		}
		
		

		Main.AppControls.Lib.InitAfterMain(appTable)
		for i,v in pairs(Main.ModuleList) do
			local control = Main.AppControls[v]
			if control then
				control.InitAfterMain(appTable)
			end
		end
	end

	Main.InitEnv = function()

		env.isonmobile = game:GetService("UserInputService").TouchEnabled
		
		env.loadstring = pcall(loadstring,"local a = 1") and loadstring or nil

		-- file
		env.isfile = isfile
		env.readfile = readfile
		env.writefile = writefile
		env.makefolder = makefolder
		env.listfiles = listfiles
		env.delfile = delfile
		-- An executor with no saveinstance of its own gets UniversalSynSaveInstance. It is downloaded the first
		-- time something is saved, and kept on Main so that a reload does not fetch it again.
		env.saveinstance = saveinstance or function(obj, filepath, options)
			if not Main.SynSaveInstance then
				local ok, saver = pcall(function()
					return loadstring(oldgame:HttpGet("https://raw.githubusercontent.com/luau/SynSaveInstance/main/saveinstance.luau", true), "saveinstance")()
				end)
				if not ok or type(saver) ~= "function" then
					error("the saver (UniversalSynSaveInstance) could not be downloaded: "..tostring(saver), 0)
				end
				Main.SynSaveInstance = saver
			end

			local opts = table.clone(options or {}) -- the caller's table is its settings: leave it as it is
			opts.FilePath = filepath
			opts.Object = obj
			return Main.SynSaveInstance(opts)
		end

		env.parsefile = function(name)
			return tostring(name):gsub("[*\\?:<>|/\"]+", ""):sub(1, 175)
		end

		-- debug
		env.getupvalues = debug.getupvalues or getupvalues or getupvals
		env.getconstants = debug.getconstants or getconstants or getconsts
		env.setupvalue = debug.setupvalue or setupvalue
		env.setconstant = debug.setconstant or setconstant
		env.getgc = getgc
		env.getconnections = getconnections
		env.getcallingscript = getcallingscript
		env.isexecutorclosure = isexecutorclosure
		
		-- hooks
		env.hookfunction = hookfunction
		env.hookmetamethod = hookmetamethod
		env.restorefunction = restorefunction
		env.getnamecallmethod = getnamecallmethod
		env.newcclosure = newcclosure
		env.checkcaller = checkcaller
		env.firesignal = firesignal
		env.getcallbackvalue = getcallbackvalue
		env.getthreadidentity = getthreadidentity or getidentity
		env.setthreadidentity = setthreadidentity or setidentity

		-- other
		env.getscriptbytecode = getscriptbytecode
		env.setclipboard = setclipboard
		env.getnilinstances = getnilinstances or get_nil_instances
		env.getloadedmodules = getloadedmodules
		env.getscripts = getscripts
		env.getscripthash = getscripthash
		
		env.isViableDecompileScript = function(obj)
			if obj:IsA("ModuleScript") then
				return true
			elseif obj:IsA("LocalScript") and (obj.RunContext == Enum.RunContext.Client or obj.RunContext == Enum.RunContext.Legacy) then
				return true
			elseif obj:IsA("Script") and obj.RunContext == Enum.RunContext.Client then
				return true
			end
			return false
		end
		env.request = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
		env.websocket = (WebSocket and WebSocket.connect) or (syn and syn.websocket and syn.websocket.connect) or nil
		
		env.isdecompile = function()
			return typeof(decompile) == "function" or typeof(getscriptbytecode) == "function" or false
		end
		
		-- DECOMPILERS

		-- Advanced Decompiler is downloaded the first time it is asked to decompile something, and kept on Main
		-- so that a reload does not fetch it again. A download that failed is tried again half a minute later.
		local adTriedAt
		local function ADDec(...)
			if not Main.AdvancedDecompiler and (not adTriedAt or os.clock() - adTriedAt > 30) then
				adTriedAt = os.clock()
				local ok, result = pcall(function()
					return loadstring(game:HttpGet("https://raw.githubusercontent.com/AZYsGithub/Advanced-Decompiler-V3/refs/heads/main/init.lua"))()
				end)
				if ok and type(result) == "function" then Main.AdvancedDecompiler = result end
			end
			if Main.AdvancedDecompiler then return Main.AdvancedDecompiler(...) end
			return nil, "Advanced Decompiler could not be downloaded"
		end

		local konstant_last_call = 0

		-- The fallback decompilers return the source, or nil and why there is none (a failure is not a
		-- decompile: it is not kept in the decompile cache, and the viewer says the reason).
		local function KonstantDec(...)
			-- by lovrewe
			local API = "http://api.plusgiant5.com"

			local function call(konstantType, scriptPath)
				local success, bytecode = pcall(env.getscriptbytecode, scriptPath)

				if (not success) then
					return nil, "getscriptbytecode failed: "..tostring(bytecode)
				end

				local time_elapsed = os.clock() - konstant_last_call
				if time_elapsed <= .5 then
					task.wait(.5 - time_elapsed)
				end

				local httpResult = env.request({
					Url = API .. konstantType,
					Body = bytecode,
					Method = "POST",
					Headers = {
						["Content-Type"] = "text/plain"
					}
				})

				konstant_last_call = os.clock()

				if (httpResult.StatusCode ~= 200) then
					return nil, "the Konstant API answered "..tostring(httpResult.StatusCode)..": "..tostring(httpResult.Body)
				else
					return httpResult.Body
				end
			end

			local function konstantDecompile(scriptPath)
				return call("/konstant/decompile", scriptPath)
			end

			return konstantDecompile(...)
		end

		env.decompile = function(...)
			if typeof(decompile) == "function" and Settings.Decompiler.PreferDecompilerFallback == false then
				return decompile(...)
			elseif typeof(getscriptbytecode) == "function" then
				local fallbackMode = Settings.Decompiler.DecompilerFallback
				
				if fallbackMode == "Konstant" then
					return KonstantDec(...)
				elseif fallbackMode == "AdvancedDecompiler" then
					return ADDec(...)
				end
			end
		end
		
		-- every usable decompiler by name, for the viewer's "Decompile with" and diff menus
		env.decompilers = {}
		if typeof(decompile) == "function" then env.decompilers.Builtin = decompile end
		if typeof(getscriptbytecode) == "function" then
			env.decompilers.Konstant = KonstantDec
			env.decompilers.AdvancedDecompiler = ADDec
		end

		if identifyexecutor then
			Main.Executor = identifyexecutor()
		end
	end

	local function serialize(val)
		if typeof(val) == "Color3" then
			local serializedColor = {}
			serializedColor.R = val.R
			serializedColor.G = val.G
			serializedColor.B = val.B
			return serializedColor
		else
			return val
		end
	end
	
	local function deserialize(val)
		if typeof(val) == "table" then
			if val.R and val.G and val.B then
				return Color3.new(val.R, val.G, val.B)
			else
				return val
			end
		else
			return val
		end
	end
	
	local savedSettingsJson -- the settings as last read or written: what Main.AutosaveSettings compares against

	Main.ExportSettings = function()
		local rawData = Settings or DefaultSettings

		local function recur(tbl)
			local newTbl = {}
			for i, v in pairs(tbl) do
				if typeof(v) == "table" then
					newTbl[i] = recur(v)
				else
					newTbl[i] = serialize(v)
				end
			end
			return newTbl
		end

		-- serialize color3 sebelum encode
		local serializedData = recur(rawData)

		local s, json = pcall(service.HttpService.JSONEncode, service.HttpService, serializedData)
		if s and json then
			return json
		end
	end

	-- A saved settings file pins every value it was written with, so a changed default never reaches
	-- anyone who has saved. This moves values that still equal an old default to the new one and
	-- leaves anything that was changed on purpose.
	Main.MigrateSettings = function(fromVersion)
		if fromVersion >= DefaultSettings.SettingsVersion then return end

		local function close(a, b)
			return typeof(a) == "Color3" and math.abs(a.R - b.R) < 0.003 and math.abs(a.G - b.G) < 0.003 and math.abs(a.B - b.B) < 0.003
		end

		local syntax = Settings.Theme.Syntax
		if close(syntax.Comment, Color3.fromRGB(102,102,102)) then syntax.Comment = Color3.fromRGB(140,140,140) end -- comments were 2.7:1
		if Settings.Window.Transparency == 0.2 then Settings.Window.Transparency = 0 end -- windows used to be see-through
	end

	Main.LoadSettings = function()
		Main.ResetSettings() -- start from a full, current set of defaults
		local s, data = pcall(env.readfile or error, "OpenDexSettings.json")
		if s and data and data ~= "" then

			local s, decoded = pcall(service.HttpService.JSONDecode, service.HttpService, data)
			if s and decoded then

				local function recur(tbl)
					local newTbl = {}
					for i, v in pairs(tbl) do
						if typeof(v) == "table" then
							newTbl[i] = deserialize(recur(v))
						else
							newTbl[i] = deserialize(v)
						end
					end
					return newTbl
				end

				local function merge(dst, src)
					for k, v in pairs(src) do
						if type(v) == "table" and type(dst[k]) == "table" then
							merge(dst[k], v)
						else
							dst[k] = v
						end
					end
				end

				local deserializedData = recur(decoded)
				merge(Settings, deserializedData)
				if Settings.Decompiler.DecompilerFallback == "Shiny" then Settings.Decompiler.DecompilerFallback = "Konstant" end -- Shiny is gone
				Main.MigrateSettings(tonumber(decoded.SettingsVersion) or 1)
			else
				warn("failed to decode settings json")
			end
		end
		savedSettingsJson = Main.ExportSettings() -- nothing is written until a setting changes from here
	end

	
	

	Main.ResetSettings = function()
		local function recur(t,res)
			for set,val in pairs(t) do
				if type(val) == "table" and val._Recurse then
					if type(res[set]) ~= "table" then
						res[set] = {}
					end
					recur(val,res[set])
				else
					res[set] = val
				end
			end
			return res
		end
		recur(DefaultSettings,Settings)
	end

	-- The saved copy of a downloaded file, if the saved version still matches the client's (else marks the saved set stale).
	Main.ReadCachedDep = function(path)
		if not Main.LocalDepsUpToDate() then return nil end
		local saved = Lib.ReadFile(path)
		if not saved then Main.DepsVersionData[1] = "" end
		return saved
	end

	-- The API dump: the saved copy if it is of this client's version, else downloaded (several megabytes;
	-- onSlow is called when that has taken ten seconds).
	Main.FetchAPI = function(onSlow)
		local downloaded = false
		local rawAPI = Main.ReadCachedDep("dex/rbx_api.dat")
		if not rawAPI then
			task.delay(10,function()
				if not downloaded and onSlow then onSlow() end
			end)
			rawAPI = game:HttpGet("http://setup.roblox.com/"..Main.RobloxVersion.."-API-Dump.json")
		end
		downloaded = true

		Main.RawAPI = rawAPI
		local api = service.HttpService:JSONDecode(rawAPI)

		local classes,enums = {},{}
		local categoryOrder,seenCategories = {},{}

		local function insertAbove(t,item,aboveItem)
			local findPos = table.find(t,item)
			if not findPos then return end
			table.remove(t,findPos)

			local pos = table.find(t,aboveItem)
			if not pos then return end
			table.insert(t,pos,item)
		end

		for _,class in pairs(api.Classes) do
			local newClass = {}
			newClass.Name = class.Name
			newClass.Superclass = class.Superclass
			newClass.Properties = {}
			newClass.Functions = {}
			newClass.Events = {}
			newClass.Callbacks = {}
			newClass.Tags = {}

			if class.Tags then for c,tag in pairs(class.Tags) do newClass.Tags[tag] = true end end
			for __,member in pairs(class.Members) do
				local newMember = {}
				newMember.Name = member.Name
				newMember.Class = class.Name
				newMember.Security = member.Security
				newMember.Tags ={}
				if member.Tags then for c,tag in pairs(member.Tags) do newMember.Tags[tag] = true end end

				local mType = member.MemberType
				if mType == "Property" then
					local propCategory = member.Category or "Other"
					propCategory = propCategory:match("^%s*(.-)%s*$")
					if not seenCategories[propCategory] then
						categoryOrder[#categoryOrder+1] = propCategory
						seenCategories[propCategory] = true
					end
					newMember.ValueType = member.ValueType
					newMember.Category = propCategory
					newMember.Serialization = member.Serialization
					table.insert(newClass.Properties,newMember)
				elseif mType == "Function" then
					newMember.Parameters = {}
					local returns = member.ReturnType
					if returns.Name then returns = {returns} end -- (a list when the function returns several values)
					local returnNames = {}
					for i,ret in ipairs(returns) do returnNames[i] = ret.Name end
					newMember.ReturnType = table.concat(returnNames,", ")
					for c,param in pairs(member.Parameters) do
						table.insert(newMember.Parameters,{Name = param.Name, Type = param.Type.Name})
					end
					table.insert(newClass.Functions,newMember)
				elseif mType == "Event" then
					newMember.Parameters = {}
					for c,param in pairs(member.Parameters) do
						table.insert(newMember.Parameters,{Name = param.Name, Type = param.Type.Name})
					end
					table.insert(newClass.Events,newMember)
				end
			end

			classes[class.Name] = newClass
		end

		for _,class in pairs(classes) do
			class.Superclass = classes[class.Superclass]
		end

		for _,enum in pairs(api.Enums) do
			local newEnum = {}
			newEnum.Name = enum.Name
			newEnum.Items = {}
			newEnum.Tags = {}

			if enum.Tags then for c,tag in pairs(enum.Tags) do newEnum.Tags[tag] = true end end
			for __,item in pairs(enum.Items) do
				local newItem = {}
				newItem.Name = item.Name
				newItem.Value = item.Value
				table.insert(newEnum.Items,newItem)
			end

			enums[enum.Name] = newEnum
		end

		insertAbove(categoryOrder,"Behavior","Tuning")
		insertAbove(categoryOrder,"Appearance","Data")
		insertAbove(categoryOrder,"Attachments","Axes")
		insertAbove(categoryOrder,"Cylinder","Slider")
		insertAbove(categoryOrder,"Localization","Jump Settings")
		insertAbove(categoryOrder,"Surface","Motion")
		insertAbove(categoryOrder,"Surface Inputs","Surface")
		insertAbove(categoryOrder,"Part","Surface Inputs")
		insertAbove(categoryOrder,"Assembly","Surface Inputs")
		insertAbove(categoryOrder,"Character","Controls")
		categoryOrder[#categoryOrder+1] = "Unscriptable"
		categoryOrder[#categoryOrder+1] = "Attributes"

		local categoryOrderMap = {}
		for i = 1,#categoryOrder do
			categoryOrderMap[categoryOrder[i]] = i
		end

		return {
			Classes = classes,
			Enums = enums,
			CategoryOrder = categoryOrderMap
		}
	end

	Main.FetchRMD = function()
		local rawXML = Main.ReadCachedDep("dex/rbx_rmd.dat") or game:HttpGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-Client-Tracker/roblox/ReflectionMetadata.xml")
		Main.RawRMD = rawXML
		local parsed = Lib.ParseXML(rawXML)
		local classList = parsed.children[1].children[1].children
		local enumList = parsed.children[1].children[2].children
		local propertyOrders = {}

		-- copies a list of property nodes into data, with the first letter of each name capitalised
		local function readProps(nodes, data)
			for _,prop in pairs(nodes) do
				if prop.attrs then
					local name = prop.attrs.name
					data[name:sub(1,1):upper()..name:sub(2)] = prop.children[1].text
				end
			end
		end

		local classes,enums = {},{}

		-- the members listed under a class (kind is "Properties" or "Functions"), by name; a property's order is noted
		local function readMembers(child, className, kind)
			for _,member in pairs(child.children) do
				if member.attrs.class == "ReflectionMetadataMember" and member.children[1].tag == "Properties" then
					local data = {}
					readProps(member.children[1].children, data)
					if kind == "Properties" and data.PropertyOrder then
						local orders = propertyOrders[className]
						if not orders then orders = {} propertyOrders[className] = orders end
						orders[data.Name] = tonumber(data.PropertyOrder)
					end
					classes[className][kind][data.Name] = data
				end
			end
		end

		for _,class in pairs(classList) do
			local className = ""
			for _,child in pairs(class.children) do
				if child.tag == "Properties" then
					local data = {Properties = {}, Functions = {}}
					local props = child.children
					readProps(props, data)
					className = data.Name
					classes[className] = data
				elseif child.attrs.class == "ReflectionMetadataProperties" then
					readMembers(child, className, "Properties")
				elseif child.attrs.class == "ReflectionMetadataFunctions" then
					readMembers(child, className, "Functions")
				end
			end
		end

		for _,enum in pairs(enumList) do
			local enumName = ""
			for _,child in pairs(enum.children) do
				if child.tag == "Properties" then
					local data = {Items = {}}
					local props = child.children
					readProps(props, data)
					enumName = data.Name
					enums[enumName] = data
				elseif child.attrs.class == "ReflectionMetadataEnumItem" then
					local data = {}
					if child.children[1].tag == "Properties" then
						local props = child.children[1].children
						readProps(props, data)
						enums[enumName].Items[data.Name] = data
					end
				end
			end
		end

		return {Classes = classes, Enums = enums, PropertyOrders = propertyOrders}
	end

	Main.CreateIntro = function(initStatus)
		local gui = create({
			{1,"ScreenGui",{Name="Intro",}},
			{2,"Frame",{Active=true,BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Name="Main",Parent={1},Position=UDim2.new(0.5,-175,0.5,-100),Size=UDim2.new(0,350,0,200),}},
			{3,"Frame",{BackgroundColor3=Color3.new(0.17647059261799,0.17647059261799,0.17647059261799),BorderSizePixel=0,ClipsDescendants=true,Name="Holder",Parent={2},Size=UDim2.new(1,0,1,0),}},
			{4,"UIGradient",{Parent={3},Rotation=30,Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{5,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=4,Name="Title",Parent={3},Position=UDim2.new(0,-190,0,15),Size=UDim2.new(0,100,0,50),Text="OpenDex",TextColor3=Color3.new(1,1,1),TextSize=50,TextTransparency=1,}},
			{6,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Desc",Parent={3},Position=UDim2.new(0,-230,0,60),Size=UDim2.new(0,180,0,25),Text="Ultimate Debugging Suite",TextColor3=Color3.new(1,1,1),TextSize=18,TextTransparency=1,}},
			{7,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="StatusText",Parent={3},Position=UDim2.new(0,20,0,110),Size=UDim2.new(0,180,0,25),Text="Fetching API",TextColor3=Color3.new(1,1,1),TextSize=14,TextTransparency=1,}},
			{8,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Name="ProgressBar",Parent={3},Position=UDim2.new(0,110,0,145),Size=UDim2.new(0,0,0,4),}},
			{9,"Frame",{BackgroundColor3=Color3.new(0.2392156869173,0.56078433990479,0.86274510622025),BorderSizePixel=0,Name="Bar",Parent={8},Size=UDim2.new(0,0,1,0),}},
			{10,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://2764171053",ImageColor3=Color3.new(0.17647059261799,0.17647059261799,0.17647059261799),Parent={8},ScaleType=1,Size=UDim2.new(1,0,1,0),SliceCenter=Rect.new(2,2,254,254),}},
			{11,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Creator",Parent={2},Position=UDim2.new(1,-110,1,-20),Size=UDim2.new(0,105,0,20),Text="Open-source",TextColor3=Color3.new(1,1,1),TextSize=14,TextXAlignment=1,}},
			{12,"UIGradient",{Parent={11},Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{13,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Version",Parent={2},Position=UDim2.new(1,-110,1,-35),Size=UDim2.new(0,105,0,20),Text=Main.Version,TextColor3=Color3.new(1,1,1),TextSize=14,TextXAlignment=1,}},
			{14,"UIGradient",{Parent={13},Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{15,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,BorderSizePixel=0,Image="rbxassetid://1427967925",Name="Outlines",Parent={2},Position=UDim2.new(0,-5,0,-5),ScaleType=1,Size=UDim2.new(1,10,1,10),SliceCenter=Rect.new(6,6,25,25),TileSize=UDim2.new(0,20,0,20),}},
			{16,"UIGradient",{Parent={15},Rotation=-30,Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{17,"UIGradient",{Parent={2},Rotation=-30,Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1,0),NumberSequenceKeypoint.new(1,1,0),}),}},
			{18,"UIDragDetector", {Parent={2}}}
		})
		Main.SecureGui(gui)
		local backGradient = gui.Main.UIGradient
		local outlinesGradient = gui.Main.Outlines.UIGradient
		local holderGradient = gui.Main.Holder.UIGradient
		local titleText = gui.Main.Holder.Title
		local descText = gui.Main.Holder.Desc
		local versionText = gui.Main.Version
		local versionGradient = versionText.UIGradient
		local creatorText = gui.Main.Creator
		local creatorGradient = creatorText.UIGradient
		local statusText = gui.Main.Holder.StatusText
		local progressBar = gui.Main.Holder.ProgressBar
		local tweenS = service.TweenService

		local renderStepped = service.RunService.RenderStepped
		local signalWait = renderStepped.wait
		local fastwait = function(s)
			if not s then return signalWait(renderStepped) end
			local start = tick()
			while tick() - start < s do signalWait(renderStepped) end
		end

		statusText.Text = initStatus

		local function tweenNumber(n,ti,func)
			local tweenVal = Instance.new("IntValue")
			tweenVal.Value = 0
			tweenVal.Changed:Connect(func)
			local tween = tweenS:Create(tweenVal,ti,{Value = n})
			tween:Play()
			tween.Completed:Connect(function()
				tweenVal:Destroy()
			end)
		end

		local ti = TweenInfo.new(0.4,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)
		local progressTI = TweenInfo.new(0.25,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)

		-- The window opens with an animation of a second and a half. It runs beside the loading, which does
		-- not wait for it (opened says when it is over).
		local opened = false
		task.spawn(function()
			tweenNumber(100,ti,function(val)
				val = val/200
				local start = NumberSequenceKeypoint.new(0,0)
				local a1 = NumberSequenceKeypoint.new(val,0)
				local a2 = NumberSequenceKeypoint.new(math.min(0.5,val+math.min(0.05,val)),1)
				if a1.Time == a2.Time then a2 = a1 end
				local b1 = NumberSequenceKeypoint.new(1-val,0)
				local b2 = NumberSequenceKeypoint.new(math.max(0.5,1-val-math.min(0.05,val)),1)
				if b1.Time == b2.Time then b2 = b1 end
				local goal = NumberSequenceKeypoint.new(1,0)
				backGradient.Transparency = NumberSequence.new({start,a1,a2,b2,b1,goal})
				outlinesGradient.Transparency = NumberSequence.new({start,a1,a2,b2,b1,goal})
			end)

			fastwait(0.4)

			tweenNumber(100,ti,function(val)
				val = val/166.66
				local start = NumberSequenceKeypoint.new(0,0)
				local a1 = NumberSequenceKeypoint.new(val,0)
				local a2 = NumberSequenceKeypoint.new(val+0.01,1)
				local goal = NumberSequenceKeypoint.new(1,1)
				holderGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
			end)

			tweenS:Create(titleText,ti,{Position = UDim2.new(0,60,0,15), TextTransparency = 0}):Play()
			tweenS:Create(descText,ti,{Position = UDim2.new(0,20,0,60), TextTransparency = 0}):Play()

			local function rightTextTransparency(obj)
				tweenNumber(100,ti,function(val)
					val = val/100
					local a1 = NumberSequenceKeypoint.new(1-val,0)
					local a2 = NumberSequenceKeypoint.new(math.max(0,1-val-0.01),1)
					if a1.Time == a2.Time then a2 = a1 end
					local start = NumberSequenceKeypoint.new(0,a1 == a2 and 0 or 1)
					local goal = NumberSequenceKeypoint.new(1,0)
					obj.Transparency = NumberSequence.new({start,a2,a1,goal})
				end)
			end
			rightTextTransparency(versionGradient)
			rightTextTransparency(creatorGradient)

			fastwait(0.9)

			tweenS:Create(statusText,progressTI,{Position = UDim2.new(0,20,0,120), TextTransparency = 0}):Play()
			tweenS:Create(progressBar,progressTI,{Position = UDim2.new(0,60,0,145), Size = UDim2.new(0,100,0,4)}):Play()

			fastwait(0.25)
			opened = true
		end)

		local failed = false
		local function setProgress(text,n)
			if failed then return end -- the reason it failed stays up
			statusText.Text = text
			tweenS:Create(progressBar.Bar,progressTI,{Size = UDim2.new(n,0,1,0)}):Play()
		end

		-- A start-up step failed: says why, and stays until it is closed
		local function fail(message)
			failed = true
			while not opened do fastwait() end -- the opening animation still moves the status line: after it
			progressBar.Visible = false
			statusText.Position = UDim2.new(0,20,0,92)
			statusText.Size = UDim2.new(1,-40,0,70)
			statusText.TextWrapped = true
			statusText.TextXAlignment = Enum.TextXAlignment.Left
			statusText.TextYAlignment = Enum.TextYAlignment.Top
			statusText.TextTruncate = Enum.TextTruncate.AtEnd
			statusText.TextColor3 = Settings.Theme.Danger
			statusText.Text = "OpenDex couldn't start: "..tostring(message)

			local closeButton = createSimple("TextButton",{
				BackgroundColor3 = Settings.Theme.Button,
				BorderSizePixel = 0,
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = Settings.Theme.Text,
				Text = "Close",
				Position = UDim2.new(0,20,1,-30),
				Size = UDim2.new(0,70,0,22),
				ZIndex = 2,
				Parent = gui.Main,
			})
			closeButton.MouseButton1Click:Connect(function() gui:Destroy() end)
		end

		local function close()
			while not opened do fastwait() end -- (a start from the saved API can be done before the window has opened)
			tweenS:Create(titleText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(descText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(versionText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(creatorText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(statusText,progressTI,{TextTransparency = 1}):Play()
			tweenS:Create(progressBar,progressTI,{BackgroundTransparency = 1}):Play()
			tweenS:Create(progressBar.Bar,progressTI,{BackgroundTransparency = 1}):Play()
			tweenS:Create(progressBar.ImageLabel,progressTI,{ImageTransparency = 1}):Play()

			tweenNumber(100,TweenInfo.new(0.4,Enum.EasingStyle.Back,Enum.EasingDirection.In),function(val)
				val = val/250
				local start = NumberSequenceKeypoint.new(0,0)
				local a1 = NumberSequenceKeypoint.new(0.6+val,0)
				local a2 = NumberSequenceKeypoint.new(math.min(1,0.601+val),1)
				if a1.Time == a2.Time then a2 = a1 end
				local goal = NumberSequenceKeypoint.new(1,a1 == a2 and 0 or 1)
				holderGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
			end)

			fastwait(0.5)
			gui.Main.BackgroundTransparency = 1
			outlinesGradient.Rotation = 30

			tweenNumber(100,ti,function(val)
				val = val/100
				local start = NumberSequenceKeypoint.new(0,1)
				local a1 = NumberSequenceKeypoint.new(val,1)
				local a2 = NumberSequenceKeypoint.new(math.min(1,val+math.min(0.05,val)),0)
				if a1.Time == a2.Time then a2 = a1 end
				local goal = NumberSequenceKeypoint.new(1,a1 == a2 and 1 or 0)
				outlinesGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
				holderGradient.Transparency = NumberSequence.new({start,a1,a2,goal})
			end)

			fastwait(0.45)
			gui:Destroy()
		end

		return {SetProgress = setProgress, Fail = fail, Close = close, Object = gui}
	end

	Main.CreateApp = function(data)
		if Main.MenuApps[data.Name] then return end -- TODO: Handle conflict
		local control = {}

		local app = Main.AppTemplate:Clone()

		local iconIndex = data.Icon
		if data.IconMap and iconIndex then
			if type(iconIndex) == "number" then
				data.IconMap:Display(app.Main.Icon,iconIndex)
			elseif type(iconIndex) == "string" then
				data.IconMap:DisplayByKey(app.Main.Icon,iconIndex)
			end
		elseif type(iconIndex) == "string" then
			app.Main.Icon.Image = iconIndex
		else
			app.Main.Icon.Image = ""
		end

		local function updateState()
			app.Main.BackgroundTransparency = data.Open and 0 or (Lib.CheckMouseInGui(app.Main) and 0 or 1)
			app.Main.Highlight.Visible = data.Open
		end

		local function enable(silent)
			if data.Open then return end
			data.Open = true
			updateState()
			if not silent then
				if data.Window then data.Window:Show() end
				if data.OnClick then data.OnClick(data.Open) end
			end
		end

		local function disable(silent)
			if not data.Open then return end
			data.Open = false
			updateState()
			if not silent then
				if data.Window then data.Window:Hide() end
				if data.OnClick then data.OnClick(data.Open) end
			end
		end

		updateState()

		local ySize = service.TextService:GetTextSize(data.Name,14,Enum.Font.SourceSans,Vector2.new(62,999999)).Y
		app.Main.Size = UDim2.new(1,0,0,math.clamp(46+ySize,60,74))
		app.Main.AppName.Text = data.Name

		app.Main.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				app.Main.BackgroundTransparency = 0
				app.Main.BackgroundColor3 = Settings.Theme.ButtonHover
			end
		end)
		

		app.Main.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				app.Main.BackgroundTransparency = data.Open and 0 or 1
				app.Main.BackgroundColor3 = Settings.Theme.Button
			end
		end)

		app.Main.MouseButton1Click:Connect(function()
			if data.Open then disable() else enable() end
		end)

		local window = data.Window
		if window then
			window.OnActivate:Connect(function() enable(true) end)
			window.OnDeactivate:Connect(function() disable(true) end)
		end

		app.Visible = true
		app.Parent = Main.AppsContainer
		Main.AppsFrame.CanvasSize = UDim2.new(0,0,0,Main.AppsContainerGrid.AbsoluteCellCount.Y*82 + 8)

		control.Enable = enable
		control.Disable = disable
		control.IsOpen = function() return data.Open and true or false end
		control.HasWindow = data.Window ~= nil -- a tile without one is a tool that switches on and off
		Main.MenuApps[data.Name] = control
		table.insert(Main.MenuAppOrder, data.Name)
		return control
	end

	Main.SetMainGuiOpen = function(val)
		Main.MainGuiOpen = val

		Main.MainGui.OpenButton.Text = val and "Close" or "OpenDex"
		if val then Main.MainGui.OpenButton.MainFrame.Visible = true end
		Main.MainGui.OpenButton.MainFrame:TweenSize(val and UDim2.new(0,224,0,200) or UDim2.new(0,0,0,0),Enum.EasingDirection.Out,Enum.EasingStyle.Quad,0.2,true)
		service.TweenService:Create(Main.MainGui.OpenButton,TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency = val and 0 or (Lib.CheckMouseInGui(Main.MainGui.OpenButton) and 0 or 0.2)}):Play()

		if Main.MainGuiMouseEvent then Main.MainGuiMouseEvent:Disconnect() end

		if not val then
			local startTime = tick()
			Main.MainGuiCloseTime = startTime
			coroutine.wrap(function()
				Lib.FastWait(0.2)
				if not Main.MainGuiOpen and startTime == Main.MainGuiCloseTime then Main.MainGui.OpenButton.MainFrame.Visible = false end
			end)()
		else
			Main.MainGuiMouseEvent = service.UserInputService.InputBegan:Connect(function(input)
				if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and not Lib.CheckMouseInGui(Main.MainGui.OpenButton) and not Lib.CheckMouseInGui(Main.MainGui.OpenButton.MainFrame) then

					Main.SetMainGuiOpen(false)
				end
			end)
		end
	end

	-- The palette's commands for windows, tools and layouts
	Main.WindowCommands = function()
		local list = {}
		for _, name in ipairs(Main.MenuAppOrder) do
			local control = Main.MenuApps[name]
			local open = control.IsOpen()
			local toggle = function()
				if open then control.Disable() else control.Enable() end
			end
			if control.HasWindow then
				list[#list+1] = {Name = (open and "Close " or "Open ")..name, Category = "Window", Run = toggle}
			else
				list[#list+1] = {Name = (open and "Turn off " or "Turn on ")..name, Category = "Tool", Run = toggle}
			end
		end

		list[#list+1] = {Name = "Open Settings", Category = "Window", Run = function() SettingsWindow.Window:Show() end}
		list[#list+1] = {Name = "Explore layout", Category = "Layout", Run = function() Main.ApplyPreset("Explore") end}
		list[#list+1] = {Name = "Scripts layout", Category = "Layout", Run = function() Main.ApplyPreset("Scripts") end}
		list[#list+1] = {Name = "Reset layout", Category = "Layout", Run = Main.ResetLayout}
		return list
	end

	Main.CreateMainGui = function()
		local gui = create({
			{1,"ScreenGui",{IgnoreGuiInset=true,Name="MainMenu",}},
			{2,"TextButton",{AnchorPoint=Vector2.new(0.5,0),AutoButtonColor=false,BackgroundColor3=Color3.new(0.17647059261799,0.17647059261799,0.17647059261799),BorderSizePixel=0,Font=4,Name="OpenButton",Parent={1},Position=UDim2.new(0.5,0,0,2),Size=UDim2.new(0,72,0,32),Text="OpenDex",TextColor3=Color3.new(1,1,1),TextSize=16,TextTransparency=0.20000000298023,}},
			{3,"UICorner",{CornerRadius=UDim.new(0,4),Parent={2},}},
			{4,"Frame",{AnchorPoint=Vector2.new(0.5,0),BackgroundColor3=Color3.new(0.17647059261799,0.17647059261799,0.17647059261799),ClipsDescendants=true,Name="MainFrame",Parent={2},Position=UDim2.new(0.5,0,1,-4),Size=UDim2.new(0,224,0,200),}},
			{5,"UICorner",{CornerRadius=UDim.new(0,4),Parent={4},}},
			{6,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),Name="BottomFrame",Parent={4},Position=UDim2.new(0,0,1,-24),Size=UDim2.new(1,0,0,24),}},
			{7,"UICorner",{CornerRadius=UDim.new(0,4),Parent={6},}},
			{8,"Frame",{BackgroundColor3=Color3.new(0.20392157137394,0.20392157137394,0.20392157137394),BorderSizePixel=0,Name="CoverFrame",Parent={6},Size=UDim2.new(1,0,0,4),}},
			{9,"Frame",{BackgroundColor3=Color3.new(0.1294117718935,0.1294117718935,0.1294117718935),BorderSizePixel=0,Name="Line",Parent={8},Position=UDim2.new(0,0,0,-1),Size=UDim2.new(1,0,0,1),}},
			{10,"TextButton",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Font=3,Name="Settings",Parent={6},Position=UDim2.new(1,-24,0,0),Size=UDim2.new(0,24,1,0),Text="",TextColor3=Color3.new(1,1,1),TextSize=14,}},
			{11,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://6578871732",ImageTransparency=0.20000000298023,Name="Icon",Parent={10},Position=UDim2.new(0,4,0,4),Size=UDim2.new(0,16,0,16),}},
			{14,"ScrollingFrame",{Active=true,AnchorPoint=Vector2.new(0.5,0),BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,BorderColor3=Color3.new(0.1294117718935,0.1294117718935,0.1294117718935),BorderSizePixel=0,Name="AppsFrame",Parent={4},Position=UDim2.new(0.5,0,0,0),ScrollBarImageColor3=Color3.new(0,0,0),ScrollBarThickness=4,Size=UDim2.new(0,222,1,-25),}},
			{15,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Name="Container",Parent={14},Position=UDim2.new(0,7,0,8),Size=UDim2.new(1,-14,0,2),}},
			{16,"UIGridLayout",{CellSize=UDim2.new(0,66,0,74),Parent={15},SortOrder=2,}},
			{17,"Frame",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Name="App",Parent={1},Size=UDim2.new(0,100,0,100),Visible=false,}},
			{18,"TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.new(0.2352941185236,0.2352941185236,0.2352941185236),BorderSizePixel=0,Font=3,Name="Main",Parent={17},Size=UDim2.new(1,0,0,60),Text="",TextColor3=Color3.new(0,0,0),TextSize=14,}},
			{19,"ImageLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,Image="rbxassetid://129589545519436",ImageRectSize=Vector2.new(32,32),Name="Icon",Parent={18},Position=UDim2.new(0.5,-16,0,4),ScaleType=4,Size=UDim2.new(0,32,0,32),}},
			{20,"TextLabel",{BackgroundColor3=Color3.new(1,1,1),BackgroundTransparency=1,BorderSizePixel=0,Font=3,Name="AppName",Parent={18},Position=UDim2.new(0,2,0,38),Size=UDim2.new(1,-4,1,-40),Text="Explorer",TextColor3=Color3.new(1,1,1),TextSize=14,TextTransparency=0.10000000149012,TextTruncate=1,TextWrapped=true,TextYAlignment=0,}},
			{21,"Frame",{BackgroundColor3=Color3.new(0,0.66666668653488,1),BorderSizePixel=0,Name="Highlight",Parent={18},Position=UDim2.new(0,0,1,-2),Size=UDim2.new(1,0,0,2),}},
		})
		Main.MainGui = gui
		Main.AppsFrame = gui.OpenButton.MainFrame.AppsFrame
		Main.AppsContainer = Main.AppsFrame.Container
		Main.AppsContainerGrid = Main.AppsContainer.UIGridLayout
		Main.AppTemplate = gui.App
		Main.MainGuiOpen = false

		local openButton = gui.OpenButton
		openButton.BackgroundTransparency = 0.2
		openButton.MainFrame.Size = UDim2.new(0,0,0,0)
		openButton.MainFrame.Visible = false
		openButton.MouseButton1Click:Connect(function()
			Main.SetMainGuiOpen(not Main.MainGuiOpen)
		end)

		openButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				service.TweenService:Create(Main.MainGui.OpenButton,TweenInfo.new(0,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency = 0}):Play()
			end
		end)

		openButton.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				service.TweenService:Create(Main.MainGui.OpenButton,TweenInfo.new(0,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{BackgroundTransparency = Main.MainGuiOpen and 0 or 0.2}):Play()
			end
		end)

		openButton.MainFrame.BottomFrame.Settings.MouseButton1Click:Connect(function()
			if not SettingsWindow.Window.Closed then
				SettingsWindow.Window:Hide()
			else
				SettingsWindow.Window:Show()
			end
		end)

		-- Bottom bar: the command palette and the layouts on the left, settings on the right
		local bottomBar = openButton.MainFrame.BottomFrame
		Lib.Tooltip.attach(bottomBar.Settings, "Settings")

		local function barButton(text, x, width, tip, onClick)
			local btn = createSimple("TextButton", {
				BackgroundTransparency = 1,
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = Settings.Theme.Text,
				TextTransparency = 0.2,
				Text = text,
				Position = UDim2.new(0, x, 0, 0),
				Size = UDim2.new(0, width, 1, 0),
				Parent = bottomBar,
			})
			btn.MouseEnter:Connect(function() btn.TextTransparency = 0 end)
			btn.MouseLeave:Connect(function() btn.TextTransparency = 0.2 end)
			btn.MouseButton1Click:Connect(onClick)
			Lib.Tooltip.attach(btn, tip)
			return btn
		end

		barButton("Commands", 4, 78, "Search every action", function()
			Main.SetMainGuiOpen(false)
			CommandPalette.Show()
		end)

		local layoutMenu = Lib.ContextMenu.new()
		layoutMenu.Iconless = true
		layoutMenu.Width = 210
		local layoutButton
		layoutButton = barButton("Layout", 82, 56, "Window layouts", function()
			layoutMenu:Clear()
			layoutMenu:Add({Name = "Explore: Explorer + Properties", OnClick = function() Main.ApplyPreset("Explore") end})
			layoutMenu:Add({Name = "Scripts: full-screen Script Viewer", OnClick = function() Main.ApplyPreset("Scripts") end})
			layoutMenu:AddDivider()
			layoutMenu:Add({Name = "Reset layout", OnClick = Main.ResetLayout})
			layoutMenu:Show(layoutButton.AbsolutePosition.X, layoutButton.AbsolutePosition.Y + layoutButton.AbsoluteSize.Y)
		end)

		-- Create Main Apps
		Main.CreateApp({Name = "Explorer", IconMap = Main.LargeIcons, Icon = "Explorer", Open = true, Window = Explorer.Window})

		Main.CreateApp({Name = "Properties", IconMap = Main.LargeIcons, Icon = "Properties", Open = true, Window = Properties.Window})

		local cptsOnMouseClick = nil
		Main.CreateApp({Name = "Click part to select", IconMap = Explorer.ClassIcons, Icon = "SelectionBox", OnClick = function(callback)
			if callback then
				local mouse = Main.Mouse
				cptsOnMouseClick = Main.Track(mouse.Button1Down:Connect(function()
					pcall(function()
						local object = mouse.Target
						if nodes[object] then
							selection:Set(nodes[object])
							Explorer.ViewNode(nodes[object])
						end
					end)
				end))
			else if cptsOnMouseClick ~= nil then cptsOnMouseClick:Disconnect() cptsOnMouseClick = nil end end
		end})

		Main.CreateApp({Name = "Script Viewer", IconMap = Main.LargeIcons, Icon = "Script_Viewer", Window = ScriptViewer.Window})
		
		Main.CreateApp({Name = "Console", IconMap = Main.LargeIcons, Icon = "Executor", Window = Console.Window})

		Main.CreateApp({Name = "Remote Spy", IconMap = Main.LargeIcons, Icon = "Watcher", Window = RemoteSpy.Window})

		Main.CreateApp({Name = "Save Instance", IconMap = Main.LargeIcons, Icon = "Book", Window = SaveInstance.Window})
		
		Main.CreateApp({Name = "3D Viewer", IconMap = Main.LargeIcons, Icon = "Object", Window = ModelViewer.Window})

		Main.CreateApp({Name = "AI", IconMap = Main.LargeIcons, Icon = "Output", Window = Agent.Window})

		
		for _, loadedplugin in pairs(Main.Plugins) do
			Main.CreateApp({Name = loadedplugin.PluginData.FriendlyName, IconMap = Explorer.ClassIcons, Icon = "Attachment", Window = loadedplugin.Window})
		end
		
		Lib.ShowGui(gui)
	end

	Main.SetupFilesystem = function()
		if not env.writefile or not env.makefolder then return end

		local makefolder = env.makefolder

		makefolder("dex")
		makefolder("dex/plugins")
		makefolder("dex/annotations")
	end

	Main.SaveCurrentSettings = function()
		local json = Main.ExportSettings()
		if writefile and json then
			writefile("OpenDexSettings.json", json)
			savedSettingsJson = json
		end
	end

	-- Once a second (on the layout's tick): writes the settings if anything changed them, so a change
	-- made anywhere is kept without a Save button
	Main.AutosaveSettings = function()
		if Main.ExportSettings() ~= savedSettingsJson then pcall(Main.SaveCurrentSettings) end
	end

	Main.LocalDepsUpToDate = function()
		return Main.DepsVersionData and Main.ClientVersion == Main.DepsVersionData[1]
	end

	Main.Init = function()
		-- OpenDex run again while it is running: the one before closes first (its layout saved, its windows,
		-- hooks and loops gone) and hands over what outlives it. It is found in the executor's globals.
		local globals = getgenv and getgenv()
		local before = globals and globals.OpenDex
		Main.Reloaded = type(before) == "table" -- (this very Main too: Reinit, from Apply Now, keeps the windows)
		if Main.Reloaded and before ~= Main then -- (Reinit has closed this one itself)
			pcall(function() before.Layout.Flush() end)
			pcall(before.Uninit)
			for _, key in ipairs({"RemoteHook", "SynSaveInstance", "AdvancedDecompiler"}) do
				if Main[key] == nil then Main[key] = before[key] end
			end
		end
		if globals then globals.OpenDex = Main end

		Main.Session = {} -- a new one per run: loops of an earlier run compare against it to know they should stop
		Main.Elevated = pcall(function() return game:GetService("CoreGui"):GetFullName() end)
		Main.RemoveGuis() -- (on an executor without getgenv the windows are all that can be found of a run before)

		-- saves new settings if does not exist (settings saved under the old name are carried over)
		if isfile and not isfile("OpenDexSettings.json") then
			if readfile and writefile and isfile("DexPlusPlusSettings.json") then
				writefile("OpenDexSettings.json", readfile("DexPlusPlusSettings.json"))
			else
				Main.SaveCurrentSettings()
			end
		end
		
		Main.InitEnv()
		Main.LoadSettings() -- loads the settings before init
		
		Main.SetupFilesystem()

		-- From here a failed step (a download, a module) is reported on the loading screen instead of
		-- leaving it up for good
		local intro = Main.CreateIntro("Initializing Library")
		local ok,err = pcall(Main.Load,intro)
		if not ok then
			intro.Fail(err)
			error(err,0)
		end
	end

	-- What Main.Init does once the loading screen is up
	Main.Load = function(intro)
		-- Load Lib
		Lib = Main.LoadModule("Lib")
		Main.Notify = Lib.Notify.show
		Main.Layout.Load()
		Lib.FastWait()

		-- Init other stuff
		-- Init icons
		Main.MiscIcons = Lib.IconMap.new("rbxassetid://6511490623",256,256,16,16)
		Main.MiscIcons:SetDict({
			Reference = 0,             Cut = 1,                         Cut_Disabled = 2,      Copy = 3,               Copy_Disabled = 4,    Paste = 5,                Paste_Disabled = 6,
			Delete = 7,                Delete_Disabled = 8,             Group = 9,             Group_Disabled = 10,    Ungroup = 11,         Ungroup_Disabled = 12,    TeleportTo = 13,
			Rename = 14,               JumpToParent = 15,               ExploreData = 16,      Save = 17,              CallFunction = 18,    CallRemote = 19,          Undo = 20,
			Undo_Disabled = 21,        Redo = 22,                       Redo_Disabled = 23,    Expand_Over = 24,       Expand = 25,          Collapse_Over = 26,       Collapse = 27,
			SelectChildren = 28,       SelectChildren_Disabled = 29,    InsertObject = 30,     ViewScript = 31,        AddStar = 32,         RemoveStar = 33,          Script_Disabled = 34,
			LocalScript_Disabled = 35, Play = 36,                       Pause = 37,            Rename_Disabled = 38,   Empty = 1000
		})
		Main.LargeIcons = Lib.IconMap.new("rbxassetid://129589545519436",256,256,32,32)
		Main.LargeIcons:SetDict({
			Explorer = 0, Properties = 1, Script_Viewer = 2, Watcher = 3, Output = 4, ScriptEdit = 5, Book = 6, Executor = 7, Object = 8, Honey = 9
		})
		
		-- Fetch version if needed
		intro.SetProgress("Fetching Roblox Version",0.3)
		local fileVer = Lib.ReadFile("dex/deps_version.dat")
		Main.ClientVersion = Version()
		if fileVer then
			Main.DepsVersionData = string.split(fileVer,"\n")
			if Main.LocalDepsUpToDate() then
				Main.RobloxVersion = Main.DepsVersionData[2]
			end
		end
		Main.RobloxVersion = Main.RobloxVersion or oldgame:HttpGet("https://clientsettings.roblox.com/v2/client-version/WindowsStudio64/channel/LIVE"):match("(version%-[%w]+)")

		-- Fetch external deps
		intro.SetProgress("Fetching API",0.35)
		API = Main.FetchAPI(function()
			intro.SetProgress("Fetching API: still downloading (it is a big file)",0.4)
		end)
		Lib.FastWait()
		intro.SetProgress("Fetching RMD",0.5)
		RMD = Main.FetchRMD()
		Lib.FastWait()

		-- Save external deps locally if needed
		if env.writefile and not Main.LocalDepsUpToDate() then
			env.writefile("dex/deps_version.dat",Main.ClientVersion.."\n"..Main.RobloxVersion)
			env.writefile("dex/rbx_api.dat",Main.RawAPI)
			env.writefile("dex/rbx_rmd.dat",Main.RawRMD)
		end
		Main.RawAPI,Main.RawRMD = nil,nil -- megabytes of text, kept only to be written above

		-- Load other modules
		intro.SetProgress("Loading Modules",0.75)
		Main.AppControls.Lib.InitDeps(Main.GetInitDeps()) -- Missing deps now available
		Main.LoadModules()
		Lib.FastWait()

		-- Init other modules
		intro.SetProgress("Initializing Modules",0.8)
		Explorer.Init()
		Properties.Init()
		ScriptViewer.Init()
		Console.Init()
		RemoteSpy.Init()
		SaveInstance.Init()
		ModelViewer.Init()
		SettingsWindow.Init()
		CommandPalette.Init()
		Agent.Init()
		
		
		-- (the listing fails where the folder could not be made: no plugins then, and OpenDex still starts)
		local listed, pluginFiles = pcall(env.listfiles or error, "dex/plugins")
		if env.readfile and listed and type(pluginFiles) == "table" then
			if #pluginFiles > 0 then
				intro.SetProgress("Loading Plugin Files",0.8)
				for _, pluginDir in pairs(pluginFiles) do
					local s, err = pcall(function()
						local moduleData = Main.LoadPluginFile(pluginDir)
						moduleData.PluginData = moduleData.PluginData or {}

						moduleData.Init()

						local pluginFriendlyName = moduleData.PluginData.FriendlyName or moduleData.Window.GuiElems.Title.Text or "Unnamed Plugin"
						local pluginName = moduleData.PluginData.Name or moduleData.Window.GuiElems.Title.Text:gsub(" ", "") or "unnamedPlugin"

						intro.SetProgress("Initializing Plugin: ".. pluginFriendlyName,0.9)

						moduleData.PluginData.Name = pluginName
						moduleData.PluginData.FriendlyName = pluginFriendlyName

						table.insert(Main.Plugins, moduleData)
					end)
					if not s then
						Main.Notify("The plugin "..tostring(pluginDir).." did not load: "..tostring(err),"error")
					end
				end
			end	
		end
		
		
		Lib.FastWait()

		-- Done
		intro.SetProgress("Complete",1)
		coroutine.wrap(function()
			Lib.FastWait(1.25)
			intro.Close()
		end)()

		-- Init window system, create main menu, show explorer and properties
		Lib.Window.Init()
		Main.CreateMainGui()
		Main.AddCommands(Main.WindowCommands)
		Main.Layout.Restore() -- Explorer and Properties on the right; a run again in the same game keeps the windows as they were
		Main.Layout.StartAutosave()
	end
	
	Main.Uninit = function()
		Main.Session = nil
		-- a module that has changed the running game (hooks on its functions, work in the background) undoes that
		for _, app in pairs(Apps) do
			if type(app) == "table" and type(app.Unload) == "function" then pcall(app.Unload) end
		end
		for _, conn in pairs(Main.Connections) do
			conn:Disconnect()
		end
		Main.Connections = {}
		Main.MenuApps = {}
		Main.MenuAppOrder = {}
		Main.CommandProviders = {}
		Main.Layout.Providers = {}
		Main.Layout.ResetHandlers = {}
		Main.AppControls = {}
		Main.Plugins = {}
		Main.RemoveGuis()
	end

	Main.RemoveGuis = function()
		for _, gui in pairs(Main.GetSecureContainer():GetChildren()) do
			if string.sub(gui.Name,1,5) == "_ODX_" then -- ODX stands for OpenDex
				gui:Destroy()
			end
		end
	end

	Main.Reinit = function()
		Main.Layout.Flush() -- the layout is saved a moment after it changes; make sure the last change is
		Main.Uninit()
		task.wait()
		Main.Init()
	end

	return Main
end)()

-- Start
Main.Init()

