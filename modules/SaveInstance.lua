--[[
	Save Instance App Module

	Revival of the old dex's Save Instance
]]

-- Common Locals
local Main,Lib,Settings -- Main Containers
local env -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Settings = data.Settings

	env = data.env
end

local function initAfterMain()
end

local function main()
	local SaveInstance = {}
	local window
	local fileName = "Place_"..game.PlaceId.."_{TIMESTAMP}" -- the place's name is added when the window first opens
	local Saving = false

	local DEFAULTS = {
		Decompile = true,
		DecompileTimeout = 10,
		DecompileIgnore = {"Chat", "CoreGui", "CorePackages"},
		NilInstances = false,
		RemovePlayerCharacters = true,
		SavePlayers = false,
		ShowStatus = true,
		IgnoreDefaultProps = true,
		IsolateStarterPlayer = true
	}

	local SaveInstanceArgs = {}
	for k, v in pairs(DEFAULTS) do
		SaveInstanceArgs[k] = type(v) == "table" and table.clone(v) or v
	end

	-- "Chat, CoreGui" <-> {"Chat", "CoreGui"}
	local function parseList(text)
		local list = {}
		for _, item in ipairs(string.split(text, ",")) do
			local trimmed = item:match("^%s*(.-)%s*$")
			if trimmed ~= "" then table.insert(list, trimmed) end
		end
		return list
	end

	SaveInstance.Init = function()
		window = Lib.Window.new()
		window:SetTitle("Save Instance")
		window:SetLayoutId("SaveInstance")
		window:Resize(350, 400)
		SaveInstance.Window = window

		-- The options as they were left last time (kept with the window layout). The file name is not: it
		-- names the place.
		local saved = Main.Layout.Extra("SaveInstance")
		if type(saved) == "table" and type(saved.args) == "table" then
			for key, default in pairs(DEFAULTS) do
				local value = saved.args[key]
				if type(default) == "table" then
					if type(value) == "table" then
						local list = {}
						for _, item in ipairs(value) do
							if type(item) == "string" then list[#list+1] = item end
						end
						SaveInstanceArgs[key] = list
					end
				elseif type(value) == type(default) then
					SaveInstanceArgs[key] = value
				end
			end
		end

		local content = window.GuiElems.Content

		local form = Lib.Form.new(content)
		form.Gui.Size = UDim2.new(1, 0, 1, -62)

		local function checkbox(text, key, description)
			form:AddCheckbox(text, SaveInstanceArgs[key], function(v)
				SaveInstanceArgs[key] = v
			end, {Default = DEFAULTS[key], Description = description})
		end

		form:AddHeading("Scripts")
		checkbox("Decompile scripts (LocalScript and ModuleScript)", "Decompile", "Decompile client scripts into the saved file. Slower, and the result is only as good as the decompiler.")
		form:AddNumber("Decompile timeout (s)", SaveInstanceArgs.DecompileTimeout, function(v)
			SaveInstanceArgs.DecompileTimeout = v
		end, {Integer = true, Min = 1, Max = 600, Width = 60, Default = DEFAULTS.DecompileTimeout, Description = "How long to wait for one script before leaving it undecompiled."})
		form:AddInput("Decompile ignore", table.concat(SaveInstanceArgs.DecompileIgnore, ","), function(v)
			SaveInstanceArgs.DecompileIgnore = parseList(v)
		end, {Width = 150, Default = table.concat(DEFAULTS.DecompileIgnore, ","), Description = "Services whose scripts are not decompiled, separated by commas."})

		form:AddHeading("Contents")
		checkbox("Save nil instances", "NilInstances", "Also save instances that have no parent.")
		checkbox("Remove player characters", "RemovePlayerCharacters", "Leave the players' characters out of the file.")
		checkbox("Save player instance", "SavePlayers", "Save the Player objects themselves.")
		checkbox("Isolate StarterPlayer", "IsolateStarterPlayer", "Keep StarterPlayer's contents apart from what your own character got copied into.")
		checkbox("Ignore default properties", "IgnoreDefaultProps", "Only write properties that differ from their defaults. Smaller files.")
		checkbox("Show status", "ShowStatus", "Show the saver's own progress messages.")

		-- File name and the Save button
		local nameBox = Lib.ViewportTextBox.new()
		nameBox.Position = UDim2.new(0, 6, 1, -56)
		nameBox.Size = UDim2.new(1, -12, 0, 22)
		nameBox.TextBox.PlaceholderText = "File name ({TIMESTAMP} becomes the date and time)"
		nameBox.TextBox.PlaceholderColor3 = Settings.Theme.PlaceholderText
		nameBox.Gui.Parent = content
		nameBox.TextBox.Text = fileName
		Lib.Tooltip.attach(nameBox.TextBox, "The saved file's name. {TIMESTAMP} is replaced with the date and time. It goes in your executor's workspace folder.")

		Main.Layout.Providers.SaveInstance = function()
			return {args = SaveInstanceArgs}
		end

		-- The place's name is asked for over the web, so only once the window is opened, and from a thread of
		-- its own. It goes into the file name unless another one was typed in meanwhile.
		local named = false
		window.OnActivate:Connect(function()
			if named then return end
			named = true
			task.spawn(function()
				local marketplaceService = game:GetService("MarketplaceService")
				local ok, info = pcall(marketplaceService.GetProductInfo, marketplaceService, game.PlaceId)
				if ok and type(info) == "table" and info.Name and nameBox.TextBox.Text == fileName then
					nameBox.TextBox.Text = "Place_"..game.PlaceId.."_"..env.parsefile(info.Name).."_{TIMESTAMP}"
				end
			end)
		end)

		local save = Lib.Button.new()
		save.Text = "Save"
		save.Position = UDim2.new(0, 6, 1, -28)
		save.Size = UDim2.new(1, -12, 0, 22)
		save.Gui.Parent = content

		save.OnClick:Connect(function()
			if Saving then return end
			Saving = true
			save:SetDisabled(true)
			save.Text = "Saving..."

			local name = (nameBox.TextBox.Text:gsub("{TIMESTAMP}", os.date("%d-%m-%Y_%H-%M-%S")))
			local toast = Main.Notify("Saving "..name.." (this can take a while)", "info", {Persist = true})
			local ok, result = pcall(env.saveinstance, workspace.Parent, name, SaveInstanceArgs)
			if ok then
				toast:Set("Saved "..name.." to your executor's workspace folder", "success")
			else
				toast:Set("Failed to save the game: "..tostring(result), "error", {Details = tostring(result)})
			end

			Saving = false
			save:SetDisabled(false)
			save.Text = "Save"
		end)
	end

	return SaveInstance
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
