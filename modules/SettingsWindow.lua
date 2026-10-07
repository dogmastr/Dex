--[[
	Settings Window App Module

	The settings form (built with Lib.Form). Changes apply to the running session and are saved to
	OpenDexSettings.json as they are made; the Reload button restarts OpenDex for the ones that need it.
]]

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer, Properties -- Major Apps

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings
end

local function initAfterMain()
	Explorer = Apps.Explorer
	Properties = Apps.Properties
end

local function main()
	local SettingsWindow = {}
	local window

	SettingsWindow.ReloadPrompt = function()
		local win = SettingsWindow.ReloadPromptWindow
		if not win then
			win = Lib.Window.new()
			win.Alignable = false
			win.Resizable = false
			win:SetTitle("Apply Current Settings")
			win:SetSize(300,115)

			local reloadButton = Lib.Button.new()
			local nameLabel = Lib.Label.new()
			nameLabel.Text = "By applying current settings requires reload.\nAny unsaved progress will be lost.\nAre you sure?"
			nameLabel.Position = UDim2.new(0,30,0,20)
			nameLabel.Size = UDim2.new(0,40,0,20)
			win:Add(nameLabel)

			local cancelButton = Lib.Button.new()
			cancelButton.AnchorPoint = Vector2.new(1,1)
			cancelButton.Text = "Apply Later"
			cancelButton.Position = UDim2.new(1,-5,1,-5)
			cancelButton.Size = UDim2.new(0.5,-10,0,20)
			cancelButton.OnClick:Connect(function()
				win:Close()
			end)
			win:Add(cancelButton)

			reloadButton.Text = "Apply Now"
			reloadButton.AnchorPoint = Vector2.new(0,1)
			reloadButton.Position = UDim2.new(0,5,1,-5)
			reloadButton.Size = UDim2.new(0.5,-5,0,20)
			reloadButton.OnClick:Connect(function()
				Main.Reinit()
			end)

			win:Add(reloadButton,"reloadButton")

			SettingsWindow.ReloadPromptWindow = win
		end
		win:Show()
	end

	SettingsWindow.Init = function()
		window = Lib.Window.new()
		window:SetTitle("Settings")
		window:SetLayoutId("Settings")
		window:Resize(320,440)
		SettingsWindow.Window = window

		local content = window.GuiElems.Content
		local defaults = Main.DefaultSettings

		local form = Lib.Form.new(content)
		form.Gui.Size = UDim2.new(1,0,1,-30)

		-- A checkbox bound to Settings[group][key]
		local function checkbox(label,group,key,description)
			form:AddCheckbox(label,Settings[group][key],function(v)
				Settings[group][key] = v
			end,{Default = defaults[group][key],Description = description})
		end

		-- A whole-number box bound to Settings[group][key]
		local function number(label,group,key,min,max,description)
			form:AddNumber(label,Settings[group][key],function(v)
				Settings[group][key] = v
			end,{Integer = true,Min = min,Max = max,Width = 60,Default = defaults[group][key],Description = description})
		end

		-- UI
		form:AddHeading("UI")

		checkbox("Window title on middle","Window","TitleOnMiddle","Centre the title in each window's title bar. Windows opened after a restart use it.")

		form:AddSlider("Window transparency",Settings.Window.Transparency,function(v)
			Lib.Window.SetTransparency(v)
		end,{Min = 0,Max = 0.8,Step = 0.05,Default = defaults.Window.Transparency,Description = "How see-through window backgrounds are. Windows change as you drag; the rows of the Explorer and Properties follow after a restart."})

		form:AddDropdown("Class icons",{"Old","NewDark","Vanilla3"},Settings.ClassIcon,function(v)
			Settings.ClassIcon = v
		end,{Default = defaults.ClassIcon,Width = 100,Description = "The icon set shown in the Explorer. Needs a restart."})

		-- Layout
		form:AddHeading("Layout")
		form:AddNote("Window positions, sizes and which windows are open are remembered between sessions.")
		form:AddButton("Reset layout",function() Main.ResetLayout() end,{Width = 120,Description = "Dock Explorer and Properties on the right again and close the other windows."})

		-- Explorer
		form:AddHeading("Explorer")

		checkbox("Click to rename","Explorer","ClickToRename","Click an item that is already selected to rename it.")

		checkbox("Part selection box","Explorer","PartSelectionBox","Outline the selected parts in the 3D view.")

		checkbox("GUI selection box","Explorer","GuiSelectionBox","Outline the selected GUI objects on screen.")

		checkbox("Use GetChildren to copy path","Explorer","CopyPathUseGetChildren","Copy Path picks siblings that share a name by index (GetChildren()[n]) instead of by name.")

		checkbox("Sort objects","Explorer","Sorting","List each object's children by class, then by name. Needs a restart.")

		checkbox("Add new matches to a search","Explorer","AutoUpdateSearch","While a search is showing, list new objects that match it as they appear. Needs a restart.")

		checkbox("Fit width to names","Explorer","UseNameWidth","Scroll sideways as far as the longest name instead of cutting long names off. Needs a restart.")

		form:AddCheckbox("Mark blocked remotes",Settings.RemoteBlockWriteAttribute,function(v)
			Settings.RemoteBlockWriteAttribute = v
		end,{Default = defaults.RemoteBlockWriteAttribute,Description = "Set the attribute IsBlocked on a remote when you block or unblock it. The game's own scripts can read that attribute."})

		-- Properties
		form:AddHeading("Properties")

		checkbox("Show deprecated","Properties","ShowDeprecated","List properties Roblox has deprecated.")

		checkbox("Show hidden","Properties","ShowHidden","List properties Roblox hides from Studio's Properties window.")

		checkbox("Show attributes","Properties","ShowAttributes","List the attributes of the selected objects.")

		checkbox("Clear on focus","Properties","ClearOnFocus","Empty a value's text box when you click into it.")

		number("Decimal places shown","Properties","NumberRounding",0,10,"How many decimals numbers are rounded to in the list. Editing a value shows all of it.")

		number("Most attributes listed","Properties","MaxAttributes",1,1000,"The most attributes listed for the selected objects.")

		number("Multi-select compare limit","Properties","MaxConflictCheck",2,10000,"With several objects selected, how many are compared to tell whether they share a value. More is slower.")

		local nameColumns = {"Full names","Equal halves"} -- Settings.Properties.ScaleType 0 and 1
		form:AddDropdown("Name column width",nameColumns,nameColumns[Settings.Properties.ScaleType == 1 and 2 or 1],function(v)
			Settings.Properties.ScaleType = v == nameColumns[2] and 1 or 0
		end,{Default = nameColumns[defaults.Properties.ScaleType + 1],Width = 110,Description = "Full names: the name column is as wide as its longest name. Equal halves: names and values share the width evenly."})

		-- Script Viewer
		form:AddHeading("Script Viewer")

		checkbox("Show decompiled script info","ScriptViewer","ShowMoreInfo","Add the script path, decompile time and executor to the top of a decompiled script.")

		-- Decompiler
		form:AddHeading("Decompiler")
		form:AddNote("If the executor can't decompile, this fallback is used. The fallbacks need getscriptbytecode.")

		form:AddDropdown("Decompiler fallback",{"Konstant","AdvancedDecompiler","Shiny"},Settings.Decompiler.DecompilerFallback,function(v)
			Settings.Decompiler.DecompilerFallback = v
		end,{Default = defaults.Decompiler.DecompilerFallback,Width = 130})

		form:AddNumber("Shiny decompiler port",Settings.Decompiler.ShinyDecompilerPort,function(v)
			Settings.Decompiler.ShinyDecompilerPort = v
		end,{Integer = true,Min = 1,Max = 65535,Width = 60,Default = defaults.Decompiler.ShinyDecompilerPort,Description = "The local port the Shiny decompiler listens on."})

		checkbox("Prefer fallback decompiler","Decompiler","PreferDecompilerFallback","Use the fallback even when the executor has its own decompiler.")

		-- Settings are saved as they change (Main.AutosaveSettings); this offers the reload some of them need
		local restart = Lib.Button.new()
		restart.Text = "Reload OpenDex"
		restart.Position = UDim2.new(0,6,1,-26)
		restart.Size = UDim2.new(1,-12,0,22)
		restart.OnClick:Connect(function()
			Main.SaveCurrentSettings() -- now, not on the next autosave tick
			SettingsWindow.ReloadPrompt()
		end)
		restart.Gui.Parent = content
		Lib.Tooltip.attach(restart.Gui,"Settings are saved as you change them. This reloads OpenDex so the ones that need a restart apply")
	end

	return SettingsWindow
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
