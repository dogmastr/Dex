--[[
	Console Module

	The game's log output, and a one-line box that runs what you type (Up and Down bring back earlier
	commands). The output can be narrowed to kinds of message and to a text; the box is coloured with
	the Script Analysis lexer.
]]
-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Analysis, env, createSimple

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	env = data.env
	createSimple = data.createSimple
end

local function initAfterMain()
	Analysis = Apps.ScriptAnalysis
end

local function main()
	local Console = {}

	local OUTPUT_LIMIT = 500 -- Same as Roblox Console.
	local HISTORY_LIMIT = 50
	local theme = Settings.Theme

	local window = Lib.Window.new()
	window:SetTitle("Console")
	window:Resize(500,400)
	window:SetLayoutId("Console")
	Console.Window = window

	local function font(name)
		return Font.new("rbxasset://fonts/families/"..name..".json", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
	end

	local function pad(parent, props)
		props.Parent = parent
		return createSimple("UIPadding", props)
	end

	local function stroke(parent, props)
		props.Parent = parent
		return createSimple("UIStroke", props)
	end

	local ConsoleFrame = createSimple("ImageButton", {
		Name = "Console",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Selectable = false,
		Size = UDim2.new(1,0,1,0),
		Parent = window.GuiElems.Content,
	})

	-- The command line: a box that scrolls sideways, the text box, and the coloured copy of its text behind it
	local commandLine = createSimple("Frame", {
		Name = "CommandLine",
		BackgroundColor3 = theme.TextBox,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5,1),
		ClipsDescendants = true,
		Size = UDim2.new(1,-8,0,22),
		Position = UDim2.new(0.5,0,1,-5),
		Parent = ConsoleFrame,
	})
	stroke(commandLine, {Transparency = 0.65, Thickness = 1.25})

	local commandScroll = createSimple("ScrollingFrame", {
		Active = true,
		ScrollingDirection = Enum.ScrollingDirection.X,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0,0,0,0),
		ElasticBehavior = Enum.ElasticBehavior.Never,
		TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
		BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
		HorizontalScrollBarInset = Enum.ScrollBarInset.Always,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		Size = UDim2.new(1,0,1,0),
		ScrollBarImageColor3 = Color3.fromRGB(57,57,57),
		ScrollBarThickness = 2,
		BackgroundTransparency = 1,
		Parent = commandLine,
	})

	local commandBox = createSimple("TextBox", {
		CursorPosition = -1,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderColor3 = theme.ReadOnlyText,
		BorderSizePixel = 0,
		TextSize = 13,
		TextColor3 = theme.Syntax.Text,
		FontFace = font("Inconsolata"),
		AutomaticSize = Enum.AutomaticSize.X,
		ClearTextOnFocus = false,
		PlaceholderText = "Run a command (Up and Down: earlier commands)",
		Size = UDim2.new(0,246,0,22),
		Text = "",
		BackgroundTransparency = 1,
		Parent = commandScroll,
	})
	pad(commandBox, {PaddingLeft = UDim.new(0,7)})

	local commandColors = createSimple("TextLabel", {
		Name = "Highlight",
		Interactable = false,
		ZIndex = 2,
		BorderSizePixel = 0,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		FontFace = font("Inconsolata"),
		TextColor3 = Color3.new(1,1,1),
		BackgroundTransparency = 1,
		RichText = true,
		Size = UDim2.new(0,246,0,22),
		Text = "",
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = commandScroll,
	})
	pad(commandColors, {PaddingLeft = UDim.new(0,7)})

	-- The output area, under the two rows of the toolbar
	local OUTPUT_TOP = 54
	createSimple("Frame", {
		Name = "BackgroundOutput",
		BackgroundColor3 = theme.Syntax.Background,
		BorderSizePixel = 0,
		Size = UDim2.new(1,-8,1,-(OUTPUT_TOP + 32)),
		Position = UDim2.new(0,4,0,OUTPUT_TOP),
		ZIndex = 1,
		Parent = ConsoleFrame,
	})

	local output = createSimple("ScrollingFrame", {
		Name = "Output",
		Active = true,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(0,0,0,0),
		TopImage = "",
		BottomImage = "",
		BackgroundTransparency = 1,
		ScrollBarImageTransparency = 0,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1,-8,1,-(OUTPUT_TOP + 32)),
		Position = UDim2.new(0,4,0,OUTPUT_TOP),
		ScrollBarImageColor3 = theme.Highlight,
		ScrollBarThickness = 16,
		ZIndex = 1,
		Parent = ConsoleFrame,
	})
	createSimple("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = output})
	stroke(output, {Transparency = 0.7, Thickness = 1.25, Color = Color3.fromRGB(12,12,12)})
	pad(output, {PaddingTop = UDim.new(0,2)})

	-- A log line to clone for each message
	local template = createSimple("TextBox", {
		Name = "OutputTemplate",
		Visible = false,
		Active = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		BorderSizePixel = 0,
		TextEditable = false,
		TextWrapped = true,
		TextSize = 15,
		TextColor3 = theme.Syntax.Text,
		RichText = true,
		FontFace = font("SourceSansPro"),
		AutomaticSize = Enum.AutomaticSize.Y,
		Selectable = false,
		ClearTextOnFocus = false,
		Size = UDim2.new(1,0,0,1),
		Position = UDim2.new(0,20,0,0),
		BackgroundTransparency = 1,
		Parent = ConsoleFrame,
	})
	pad(template, {PaddingRight = UDim.new(0,6), PaddingLeft = UDim.new(0,6)})

	-- A box of the toolbar with a text box in it
	local function toolBox(name, placeholder, position, size)
		local frame = createSimple("Frame", {
			Name = name,
			BackgroundColor3 = theme.TextBox,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Size = size,
			Position = position,
			Parent = ConsoleFrame,
		})
		stroke(frame, {Transparency = 0.65, Thickness = 1.25})
		local box = createSimple("TextBox", {
			PlaceholderColor3 = theme.ReadOnlyText,
			BorderSizePixel = 0,
			TextSize = 14,
			TextColor3 = theme.Syntax.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			FontFace = font("Inconsolata"),
			ClearTextOnFocus = false,
			PlaceholderText = placeholder,
			Size = UDim2.new(1,0,1,0),
			Text = "",
			BackgroundTransparency = 1,
			Parent = frame,
		})
		pad(box, {PaddingRight = UDim.new(0,5), PaddingLeft = UDim.new(0,5)})
		return box
	end

	local function toolButton(name, text, position, width)
		local btn = createSimple("ImageButton", {
			Name = name,
			BorderSizePixel = 0,
			BackgroundColor3 = theme.Button,
			Size = UDim2.new(0,width,0,22),
			Position = position,
			Parent = ConsoleFrame,
		})
		local label = createSimple("TextLabel", {
			Interactable = false,
			BorderSizePixel = 0,
			TextSize = 14,
			FontFace = font("SourceSansPro"),
			TextColor3 = Color3.new(1,1,1),
			BackgroundTransparency = 1,
			Size = UDim2.new(1,0,1,0),
			Text = text,
			Parent = btn,
		})
		return btn, label
	end

	-- The toolbar. First row: text size, Ctrl Scroll, Auto Scroll, and at the right Copy all and Clear.
	local sizeBox = toolBox("TextSizeBox", "Size", UDim2.new(0,4,0,3), UDim2.new(0,46,0,22))
	sizeBox.TextXAlignment = Enum.TextXAlignment.Center
	local ctrlButton = toolButton("CtrlScroll", "Ctrl Scroll", UDim2.new(0,56,0,3), 74)
	local autoButton = toolButton("AutoScroll", "Auto Scroll", UDim2.new(0,134,0,3), 74)
	local copyButton = toolButton("CopyAll", "Copy all", UDim2.new(1,-116,0,3), 60)
	local clearButton = toolButton("Clear", "Clear", UDim2.new(1,-52,0,3), 48)

	-- Second row: a search of the output, and a switch for each kind of message with how many there are
	local LEVELS = {
		{Key = "out", Label = "Output", Type = Enum.MessageType.MessageOutput, Tip = "What the game prints"},
		{Key = "info", Label = "Info", Type = Enum.MessageType.MessageInfo, Tip = "Information messages"},
		{Key = "warn", Label = "Warn", Type = Enum.MessageType.MessageWarning, Tip = "Warnings"},
		{Key = "err", Label = "Error", Type = Enum.MessageType.MessageError, Tip = "Errors"},
	}
	local LEVEL_W = 62
	local searchBox = toolBox("Search", "Search the output", UDim2.new(0,4,0,28), UDim2.new(1,-(#LEVELS * (LEVEL_W + 4) + 8),0,22))
	for i,level in ipairs(LEVELS) do
		level.Button, level.Text = toolButton(level.Label, level.Label, UDim2.new(1,-(#LEVELS - i + 1) * (LEVEL_W + 4),0,28), LEVEL_W)
	end

	-- The command box's text, coloured: numbers, strings, keywords, calls and fields; a comment is what sits between tokens
	local function esc(s)
		return (s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"))
	end

	local function paint(text, color)
		if text == "" then return "" end
		return ('<font color="#%s">%s</font>'):format(color:ToHex(), esc(text))
	end

	local function highlight(text)
		local ok, R = pcall(Analysis.Analyze, text)
		if not ok then return esc(text) end

		local syn = theme.Syntax
		local tt, tv = R.tt, R.tv
		local out, last = {}, 0
		for i = 1, R.n do
			local gap = text:sub(last + 1, R.tp[i] - 1)
			out[#out+1] = paint(gap, gap:find("%S") and syn.Comment or syn.Text)

			local kind, value = tt[i], tv[i]
			local color = syn.Text
			if kind == "num" then
				color = syn.Number
			elseif kind == "str" or kind == "istr" then
				color = syn.String
			elseif kind == "op" then
				color = syn.Operator
			elseif kind == "kw" then
				color = value == "nil" and syn.Nil or (value == "true" or value == "false") and syn.Bool or syn.Keyword
			elseif tt[i + 1] == "op" and tv[i + 1] == "(" then
				color = syn.FunctionName
			elseif tt[i - 1] == "op" and (tv[i - 1] == "." or tv[i - 1] == ":") then
				color = syn.LocalProperty
			end
			out[#out+1] = paint(text:sub(R.tp[i], R.te[i]), color)
			last = R.te[i]
		end
		local rest = text:sub(last + 1)
		out[#out+1] = paint(rest, rest:find("%S") and syn.Comment or syn.Text)
		return table.concat(out)
	end

	Console.Init = function()
		local LogService = game:GetService("LogService")
		local UserInputService = game:GetService("UserInputService")

		local ctrlScroll, autoScroll = false, false
		local textSize = 15
		local shown = {out = true, info = true, warn = true, err = true} -- the kinds of message that are listed
		local needle = "" -- what the search box holds, in small letters
		local rows = {} -- the messages listed: {Gui, Level, Plain, Lower}, oldest first
		local focussedOutput

		-- as they were left last time (kept with the window layout)
		local saved = Main.Layout.Extra("Console")
		if type(saved) == "table" then
			if type(saved.size) == "number" and saved.size >= 1 and saved.size <= 100 then textSize = saved.size end
			ctrlScroll, autoScroll = saved.ctrl == true, saved.auto == true
			if type(saved.shown) == "table" then
				for key in pairs(shown) do
					if saved.shown[key] == false then shown[key] = false end
				end
			end
		end
		Main.Layout.Providers.Console = function()
			return {size = textSize, ctrl = ctrlScroll, auto = autoScroll, shown = shown}
		end

		local function rich(color)
			return ("rgb(%d, %d, %d)"):format(math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
		end
		local LOG = {
			[Enum.MessageType.MessageOutput] = {Key = "out", color = rich(theme.Syntax.Text)},
			[Enum.MessageType.MessageWarning] = {Key = "warn", color = rich(theme.Warning), bold = true},
			[Enum.MessageType.MessageError] = {Key = "err", color = rich(theme.Danger), bold = true},
			[Enum.MessageType.MessageInfo] = {Key = "info", color = rich(theme.Info)},
		}

		local function setToggle(btn, on)
			btn.BackgroundColor3 = on and theme.ListSelection or theme.Button
		end

		-- Whether a message is listed: its kind is switched on and it has the searched text
		local function passes(row)
			return shown[row.Level] and (needle == "" or row.Lower:find(needle, 1, true) ~= nil)
		end

		-- The switches say how many messages of their kind there are; a kind that is off is dim
		local function paintLevels()
			local counts = {}
			for _,row in ipairs(rows) do counts[row.Level] = (counts[row.Level] or 0) + 1 end
			for _,level in ipairs(LEVELS) do
				level.Text.Text = level.Label..(counts[level.Key] and (" "..counts[level.Key]) or "")
				setToggle(level.Button, shown[level.Key])
				level.Text.TextTransparency = shown[level.Key] and 0 or 0.4
			end
		end

		local function applyFilter()
			for _,row in ipairs(rows) do row.Gui.Visible = passes(row) end
			paintLevels()
			if autoScroll then output.CanvasPosition = Vector2.new(0, 9e9) end
		end

		local function setTextSize(n)
			textSize = n
			sizeBox.Text = tostring(n)
			for _,row in ipairs(rows) do
				row.Gui.TextSize = n
			end
		end

		-- Ctrl + wheel over the output changes the text size, once Ctrl Scroll is on
		ctrlButton.MouseButton1Click:Connect(function()
			ctrlScroll = not ctrlScroll
			setToggle(ctrlButton, ctrlScroll)
		end)

		autoButton.MouseButton1Click:Connect(function()
			autoScroll = not autoScroll
			setToggle(autoButton, autoScroll)
			if autoScroll then output.CanvasPosition = Vector2.new(0, 9e9) end
		end)
		setToggle(ctrlButton, ctrlScroll)
		setToggle(autoButton, autoScroll)

		sizeBox.Text = tostring(textSize)
		sizeBox:GetPropertyChangedSignal("Text"):Connect(function()
			local n = tonumber(sizeBox.Text)
			if n and n >= 1 and n <= 100 and n ~= textSize then setTextSize(n) end
		end)

		local scrollConsoleInput
		output.MouseEnter:Connect(function()
			if scrollConsoleInput then
				scrollConsoleInput:Disconnect()
			end
			scrollConsoleInput = UserInputService.InputChanged:Connect(function(input)
				if ctrlScroll and input.UserInputType == Enum.UserInputType.MouseWheel and Lib.IsCtrlDown() then
					output.ScrollingEnabled = false
					local newTextSize = textSize + input.Position.Z
					if newTextSize >= 1 then
						setTextSize(newTextSize)
					end
				else
					output.ScrollingEnabled = true
				end
			end)
		end)
		output.MouseLeave:Connect(function()
			if scrollConsoleInput then
				scrollConsoleInput:Disconnect()
				scrollConsoleInput = nil
			end
			if focussedOutput then
				focussedOutput:ReleaseFocus()
			end
		end)

		for _,level in ipairs(LEVELS) do
			level.Button.MouseButton1Click:Connect(function()
				shown[level.Key] = not shown[level.Key]
				applyFilter()
			end)
			Lib.Tooltip.attach(level.Button, level.Tip..": click to list or leave out")
		end
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			needle = searchBox.Text:lower()
			applyFilter()
		end)

		Lib.Tooltip.attach(sizeBox, "Text size of the output")
		Lib.Tooltip.attach(ctrlButton, "Hold Ctrl and scroll over the output to change the text size")
		Lib.Tooltip.attach(autoButton, "Keep the newest line in view")
		Lib.Tooltip.attach(clearButton, "Clear the output")
		Lib.Tooltip.attach(copyButton, "Copy the messages that are listed")
		Lib.Tooltip.attach(searchBox, "List only the messages that have this text")

		clearButton.MouseButton1Click:Connect(function()
			for _,row in ipairs(rows) do
				row.Gui:Destroy()
			end
			table.clear(rows)
			paintLevels()
		end)

		copyButton.MouseButton1Click:Connect(function()
			if not env.setclipboard then
				Main.Notify("Your executor has no setclipboard", "warn")
				return
			end
			local lines = {}
			for _,row in ipairs(rows) do
				if passes(row) then lines[#lines+1] = row.Plain end
			end
			env.setclipboard(table.concat(lines, "\n"))
			Main.Notify(("Copied %d message%s"):format(#lines, #lines == 1 and "" or "s"), "success")
		end)

		-- Builds the row for one message
		local function addLog(msg, msgtype, time)
			local style = LOG[msgtype] or LOG[Enum.MessageType.MessageOutput]
			local unformattedText = time.."   "..msg
			local formattedText = time..'   <font color="'..style.color..'">'..esc(msg)..'</font>'
			if style.bold then formattedText = time..'   <b><font color="'..style.color..'">'..esc(msg)..'</font></b>' end

			local newOutputText = template:Clone()
			local row = {Gui = newOutputText, Level = style.Key, Plain = unformattedText, Lower = unformattedText:lower()}
			table.insert(rows, row)
			if #rows > OUTPUT_LIMIT then
				table.remove(rows, 1).Gui:Destroy()
			end

			newOutputText.Text = formattedText
			newOutputText.TextSize = textSize

			newOutputText.Focused:Connect(function()
				focussedOutput = newOutputText
				newOutputText.Text = unformattedText
			end)
			newOutputText.FocusLost:Connect(function()
				focussedOutput = nil
				newOutputText.Text = formattedText
			end)

			newOutputText.Parent = output
			newOutputText.Visible = passes(row)

			if autoScroll then
				output.CanvasPosition = Vector2.new(0, 9e9)
			end
		end

		-- While the window is hidden a message only waits in this list (the newest OUTPUT_LIMIT of
		-- them); the rows are built when the window shows. A game that logs a lot costs nothing until then.
		local queued = {}
		local function onMessage(msg, msgtype, time)
			if window:IsContentVisible() then
				addLog(msg, msgtype, time)
				paintLevels()
			else
				queued[#queued+1] = {msg, msgtype, time}
				if #queued > OUTPUT_LIMIT then table.remove(queued, 1) end
			end
		end

		local function showQueued()
			if #queued == 0 or not window:IsContentVisible() then return end
			local list = queued
			queued = {}
			for _, entry in ipairs(list) do addLog(entry[1], entry[2], entry[3]) end
			paintLevels()
		end
		window.OnActivate:Connect(showQueued)
		window.OnRestore:Connect(showQueued)
		paintLevels()

		-- what was logged before OpenDex started
		local okHistory, history = pcall(LogService.GetLogHistory, LogService)
		if okHistory and type(history) == "table" then
			for i = math.max(1, #history - OUTPUT_LIMIT + 1), #history do
				local entry = history[i]
				onMessage(entry.message, entry.messageType, os.date("%H:%M:%S", entry.timestamp))
			end
		end

		Main.Track(LogService.MessageOut:Connect(function(msg, msgtype)
			onMessage(msg, msgtype, os.date("%H:%M:%S"))
		end))

		commandBox:GetPropertyChangedSignal("Text"):Connect(function()
			local oneliner = string.gsub(commandBox.Text, "\n", "    ")
			commandBox.Text = oneliner
			commandColors.Text = highlight(oneliner)
		end)

		-- The commands run before, newest last. Up and Down in the box go through them; at stands one past
		-- the newest while a new command is being typed, and that text comes back when Down gets there again.
		local commands, at, typed = {}, 1, ""
		Main.Track(UserInputService.InputBegan:Connect(function(input)
			local key = input.KeyCode
			if (key ~= Enum.KeyCode.Up and key ~= Enum.KeyCode.Down) or not commandBox:IsFocused() then return end
			if at > #commands then typed = commandBox.Text end
			at = math.clamp(at + (key == Enum.KeyCode.Up and -1 or 1), 1, #commands + 1)
			commandBox.Text = commands[at] or typed
			commandBox.CursorPosition = #commandBox.Text + 1
		end))

		commandBox.FocusLost:Connect(function(enterPressed)
			local command = commandBox.Text
			if not enterPressed or command == "" then return end

			if commands[#commands] ~= command then
				commands[#commands+1] = command
				if #commands > HISTORY_LIMIT then table.remove(commands, 1) end
			end
			at, typed = #commands + 1, ""
			commandBox.Text = "" -- (before it runs: a command may fail, or go on for a while)

			print("> "..command)
			assert(loadstring(command))()
		end)
	end

	return Console
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
