--[[
	Command Palette App Module

	One searchable list of the actions in every app. Modules add providers with Main.AddCommands
	(see main.lua) and the palette asks each of them whenever it opens, so the list can follow the
	selection, the open script and so on. Open it with Commands in the OpenDex menu;
	Up/Down choose, Enter runs, Esc closes.
]]
-- Common Locals
local Main,Lib,Settings -- Main Containers
local service,createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Settings = data.Settings

	service = data.service
	createSimple = data.createSimple
end

local function initAfterMain()
end

local function main()
	local Palette = {}

	local WIDTH,ROW_H,MAX_ROWS,MAX_SHOWN = 520,24,12,80
	local gui,frame,box,list,hint,emptyLabel
	local entries,shown,rows = {},{},{}
	local selected = 0
	local open = false
	local recent = {} -- names of the commands run lately, listed first while the box is empty

	local function theme(key)
		return Settings.Theme[key]
	end

	-- Every command from every provider. Disabled can be true or the reason (a string). Lower and Hay are
	-- what a search looks in, made once here: a game has thousands of entries (a script each, and every
	-- function of the scripts that were parsed) and every key typed looks at all of them.
	local function collect()
		local all = {}
		for _,provider in ipairs(Main.CommandProviders) do
			local ok,commands = pcall(provider)
			if ok and type(commands) == "table" then
				for _,c in ipairs(commands) do
					if c.Name and c.Run then
						local category = c.Category or ""
						local lower = c.Name:lower()
						all[#all+1] = {
							Name = c.Name,
							Category = category,
							Lower = lower,
							Hay = category:lower().." "..lower,
							Run = c.Run,
							Disabled = c.Disabled and true or false,
							Reason = type(c.Disabled) == "string" and c.Disabled or nil,
							Order = #all + 1,
						}
					end
				end
			end
		end
		return all
	end

	-- Lower is better: every word must be in the category or name; names that start with it come first.
	local function score(entry,terms)
		local name,haystack = entry.Lower,entry.Hay
		local total = 0
		for _,term in ipairs(terms) do
			if not haystack:find(term,1,true) then return nil end
			local at = name:find(term,1,true)
			total = total + (at == 1 and 0 or at and 1 or 2)
		end
		return total
	end

	local function highlight()
		for i,row in ipairs(rows) do
			row.BackgroundTransparency = i == selected and 0 or 1
		end
	end

	local function scrollToSelected()
		local top = (selected - 1) * ROW_H
		local view = list.AbsoluteSize.Y
		if top < list.CanvasPosition.Y then
			list.CanvasPosition = Vector2.new(0,top)
		elseif top + ROW_H > list.CanvasPosition.Y + view then
			list.CanvasPosition = Vector2.new(0,top + ROW_H - view)
		end
	end

	local function run(entry)
		if not entry then return end
		if entry.Disabled then
			Main.Notify(entry.Name..": "..(entry.Reason or "not available right now"),"warn")
			return
		end

		local at = table.find(recent,entry.Name)
		if at then table.remove(recent,at) end
		table.insert(recent,1,entry.Name)
		while #recent > 8 do table.remove(recent) end

		Palette.Hide()
		task.defer(function() -- the palette is gone first, for commands that open windows or menus
			local ok,err = pcall(entry.Run)
			if not ok then Main.Notify(entry.Name.." failed: "..tostring(err),"error") end
		end)
	end

	local function render()
		for _,child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		rows = {}

		local count = math.min(#shown,MAX_SHOWN)
		for i = 1,count do
			local entry = shown[i]
			local dim = entry.Disabled
			local row = createSimple("TextButton",{
				Name = "Row",
				AutoButtonColor = false,
				BackgroundColor3 = theme("ListSelection"),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.new(1,0,0,ROW_H),
				Text = "",
				LayoutOrder = i,
				Parent = list,
			})
			createSimple("TextLabel",{
				BackgroundTransparency = 1,
				Font = Enum.Font.SourceSans,
				TextSize = 12,
				TextColor3 = theme("ReadOnlyText"),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = entry.Category,
				Position = UDim2.new(0,10,0,0),
				Size = UDim2.new(0,76,1,0),
				Parent = row,
			})
			local reasonWidth = (dim and entry.Reason) and 190 or 0
			createSimple("TextLabel",{
				BackgroundTransparency = 1,
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = dim and theme("ReadOnlyText") or theme("Text"),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = entry.Name,
				Position = UDim2.new(0,92,0,0),
				Size = UDim2.new(1,-(102 + reasonWidth),1,0),
				Parent = row,
			})
			if reasonWidth > 0 then
				createSimple("TextLabel",{
					BackgroundTransparency = 1,
					Font = Enum.Font.SourceSans,
					TextSize = 12,
					TextColor3 = theme("ReadOnlyText"),
					TextXAlignment = Enum.TextXAlignment.Right,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Text = entry.Reason,
					AnchorPoint = Vector2.new(1,0),
					Position = UDim2.new(1,-10,0,0),
					Size = UDim2.new(0,reasonWidth - 6,1,0),
					Parent = row,
				})
			end

			row.MouseEnter:Connect(function()
				selected = i
				highlight()
			end)
			row.MouseButton1Click:Connect(function() run(entry) end)
			rows[i] = row
		end

		if count > 0 then
			selected = math.clamp(selected,1,count)
		else
			selected = 0
		end
		highlight()

		local visible = math.min(count,MAX_ROWS)
		emptyLabel.Visible = count == 0
		list.Size = UDim2.new(1,0,0,visible * ROW_H)
		list.CanvasSize = UDim2.new(0,0,0,count * ROW_H)
		hint.Text = #shown > MAX_SHOWN and (#shown - MAX_SHOWN).." more: keep typing to narrow it down" or "Up/Down to choose, Enter to run, Esc to close"
		frame.Size = UDim2.new(0,WIDTH,0,46 + math.max(visible,count == 0 and 1 or 0) * ROW_H + 22)
		hint.Position = UDim2.new(0,10,1,-18)
		emptyLabel.Position = UDim2.new(0,10,0,46)
	end

	local function refresh()
		local terms = {}
		for term in box.Text:lower():gmatch("%S+") do terms[#terms+1] = term end

		shown = {}
		if #terms == 0 then
			-- the commands run lately first, then the rest in the order they were given
			local listed = {}
			for _,name in ipairs(recent) do
				for _,e in ipairs(entries) do
					if e.Name == name then
						shown[#shown+1] = e
						listed[e] = true
					end
				end
			end
			for _,e in ipairs(entries) do
				if not listed[e] then shown[#shown+1] = e end
			end
		else
			local scored = {}
			for _,e in ipairs(entries) do
				local s = score(e,terms)
				if s then scored[#scored+1] = {e,s} end
			end
			table.sort(scored,function(a,b)
				if a[2] ~= b[2] then return a[2] < b[2] end
				if a[1].Disabled ~= b[1].Disabled then return not a[1].Disabled end
				return a[1].Order < b[1].Order
			end)
			for _,pair in ipairs(scored) do shown[#shown+1] = pair[1] end
		end
		render()
	end

	local function build()
		if gui and gui.Parent then return end

		gui = Instance.new("ScreenGui")
		gui.DisplayOrder = Main.DisplayOrders.Palette
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Enabled = false

		frame = createSimple("Frame",{
			Name = "Palette",
			AnchorPoint = Vector2.new(0.5,0),
			BackgroundColor3 = theme("Menu"),
			BorderSizePixel = 0,
			Position = UDim2.new(0.5,0,0,70),
			Size = UDim2.new(0,WIDTH,0,70),
			ClipsDescendants = true,
			Parent = gui,
		})
		createSimple("UICorner",{CornerRadius = UDim.new(0,6),Parent = frame})
		createSimple("UIStroke",{Color = theme("Outline2"),Thickness = 1,Parent = frame})

		box = createSimple("TextBox",{
			BackgroundColor3 = theme("TextBox"),
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Enum.Font.SourceSans,
			TextSize = 16,
			TextColor3 = theme("Text"),
			PlaceholderText = "Type a command...",
			PlaceholderColor3 = theme("PlaceholderText"),
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.new(0,8,0,8),
			Size = UDim2.new(1,-16,0,28),
			Parent = frame,
		})
		createSimple("UICorner",{CornerRadius = UDim.new(0,4),Parent = box})
		createSimple("UIPadding",{PaddingLeft = UDim.new(0,8),Parent = box})

		list = createSimple("ScrollingFrame",{
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.new(0,0,0,46),
			Size = UDim2.new(1,0,0,0),
			CanvasSize = UDim2.new(0,0,0,0),
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = theme("Highlight"),
			Parent = frame,
		})
		createSimple("UIListLayout",{SortOrder = Enum.SortOrder.LayoutOrder,Parent = list})

		emptyLabel = createSimple("TextLabel",{
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
			TextColor3 = theme("ReadOnlyText"),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "No command matches that.",
			Size = UDim2.new(1,-20,0,ROW_H),
			Visible = false,
			Parent = frame,
		})
		hint = createSimple("TextLabel",{
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			TextSize = 12,
			TextColor3 = theme("ReadOnlyText"),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
			Size = UDim2.new(1,-20,0,16),
			Parent = frame,
		})

		box:GetPropertyChangedSignal("Text"):Connect(function()
			selected = 1
			refresh()
		end)
		box.FocusLost:Connect(function(enterPressed)
			if enterPressed and open then run(shown[selected]) end
		end)

		Lib.ShowGui(gui)
	end

	-- prefill is text to start with: the palette opens narrowed to the commands that have it (the Script
	-- Viewer opens it on "Open script: " or "Go to: " this way), and typing goes on from there.
	function Palette.Show(prefill)
		build()
		entries = collect()
		box.Text = type(prefill) == "string" and prefill or ""
		selected = 1
		open = true
		gui.Enabled = true
		refresh()
		task.spawn(function()
			task.wait() -- after this frame's key press, or its letter would land in the box
			if open then
				box:CaptureFocus()
				box.CursorPosition = #box.Text + 1
			end
		end)
	end

	function Palette.Hide()
		open = false
		if gui then
			gui.Enabled = false
			box:ReleaseFocus()
		end
	end

	function Palette.IsOpen()
		return open
	end

	function Palette.Init()
		local uis = service.UserInputService
		Main.Track(uis.InputBegan:Connect(function(input)
			local key = input.KeyCode
			if open then
				if key == Enum.KeyCode.Escape then
					Palette.Hide()
				elseif (key == Enum.KeyCode.Down or key == Enum.KeyCode.Up) and #rows > 0 then
					selected = (selected - 1 + (key == Enum.KeyCode.Down and 1 or -1)) % #rows + 1
					highlight()
					scrollToSelected()
				elseif input.UserInputType == Enum.UserInputType.MouseButton1 and not Lib.CheckMouseInGui(frame) then
					Palette.Hide()
				end
			end
		end))
	end

	return Palette
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
