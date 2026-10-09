--[[
	Script Viewer App Module

	A read-only script viewer with tabs, find, an outline, flowcharts and a call
	graph (built on the ScriptAnalysis parser), remote/API listing, renames and notes that are
	saved per script, decompiler switching and diffs, and live tracing/watching of a script's functions.

	The window fills the screen beside the side panels. Its columns are the navigator, the code (tabs,
	find bar, editor) and the graph pane (which follows the cursor). The navigator has three scopes,
	each with its pages: Script (outline, calls, remotes, marks, and the lists that were asked for),
	Live (the running game: trace log, watch list, scanner, a module's value) and Game (every
	script: search, remote map, contents, changes). The toolbar has Back and Forward, where the cursor
	is (script > function > nested function), the toggles of the panes and the menus; a status bar runs
	along the bottom. Right-clicking the code opens a menu for what is under the pointer or selected. Typing on a line
	writes a note at its end; what stands for an instance of the game is underlined (Ctrl+click selects
	it in the Explorer).
	The running script's constants and upvalues are tinted on the code and edited there by hovering them.
]]
-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer -- Major Apps
local Analysis, Flowchart -- Script analysis and the flowchart pane
local API,env,service,createSimple -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	API = data.API
	env = data.env
	service = data.service
	createSimple = data.createSimple
end

local function initAfterMain()
	Explorer = Apps.Explorer
	Analysis = Apps.ScriptAnalysis
	Flowchart = Apps.Flowchart
end

local executorName = "Unknown"
local executorVersion = "???"
if identifyexecutor then
	local name,ver = identifyexecutor()
	executorName = name
	executorVersion = ver and tostring(ver) or "???"
end

local function getPath(obj)
	if obj.Parent == nil then
		return "Nil parented"
	else
		return Explorer.GetInstancePath(obj)
	end
end

local function main()
	local ScriptViewer = {}
	local window, codeFrame

	local editBack, editTitle, editList -- the sidebar's page: back button, title and rows

	local renderEdit, pushEdit, openPage, selectSideTab, setSideOpen, refreshSidebar, marksChanged
	local relayout, activateTab, renderTabs, refreshDecor, refreshMarkers, refreshToolbar, updateStatus
	local toast, analyze, tabAnalysis, jumpTo, showFlow, showCallGraph, refreshFlow, setFlowOpen

	local WHITE = Color3.new(1,1,1)
	local GREY = Settings.Theme.ReadOnlyText -- dim text that is still readable
	local TOOL_H, TAB_H, FIND_H, STATUS_H = 24, 22, 24, 22
	local MAX_MATCHES = 1000
	local NOTE_MARK = " -- >> " -- notes are appended to their line with this marker so they can be found again

	-- tabs: one per viewed script (or diff). tab = {Script, Name, Kind = "script" | "diff", Text, Failed, Loading,
	-- Raw (decompiler output without our header), Hash, Ann, DiffKinds, Analysis/AnText (cache),
	-- AnState, Path, ViewY, CursorX/Y}
	local tabs, activeTab = {}, nil
	local backStack, fwdStack = {}, {}
	local tabStrip, navButtons
	local renameTarget, flowRange, lastSyncLine

	-- What the graph pane shows. flowFn/flowR are a function and the analysis it came from; followFn
	-- is the function the cursor was last in, so the pane only switches when the cursor moves to a
	-- different function and a function opened by hand stays up until then.
	local flowOpen, flowRatio, flowMode = true, 0.45, "flow"
	local flowFn, flowR, followFn
	local SPLIT_W, MIN_PANE, SIDE_MIN = 4, 200, 260

	-- What getting around needs that is not a local of its own (Luau allows 200 in a function and main()
	-- is close): the navigator's width and what it is showing, the lists that were asked for, the tabs
	-- that were closed, where the cursor is for the toolbar, and the functions that go with them. Also
	-- the columns relayout places (toolbar, leftCol, flowPane, flowDivider, sideFrame, statusBar) and the
	-- find bar: its parts (findBar, findLabel, findBox, findCount, caseBtn), whether it is open, what it
	-- is asking for (findMode: "find", "line" or "rename"), and the matches of a find.
	local Nav = {W = 320, last = {}, scopeOf = {}, chips = {}, rowInfo = {}, jumps = {}, folded = {}, closed = {}, made = 0, hits = 0,
		findOpen = false, findMode = "find", findCase = false, matches = {}, matchIdx = 0}

	-- The navigator has three scopes, each with its pages. sideTab is the page that is showing. A page
	-- builds itself (rootPages, defined with the pages below) and has a stack of pages opened from it,
	-- with a Back button.
	local SCOPES = {
		{Key = "script", Title = "Script", Tip = "The open script: its functions, who calls what, its remotes, your marks, and the lists you asked for", Pages = {"outline", "calls", "remotes", "marks", "refs"}},
		{Key = "live", Title = "Live", Tip = "The running game: traced calls, watched values, the value scanner, what a module returned", Pages = {"trace", "watch", "scanner", "module"}},
		{Key = "game", Title = "Game", Tip = "Every script of the game: search them all, the remote map, scripts by what they contain, what changed since last time", Pages = {"search", "remotemap", "contents", "changes"}},
	}
	local sideStacks = {}
	for _,scope in ipairs(SCOPES) do
		for _,key in ipairs(scope.Pages) do
			sideStacks[key], Nav.scopeOf[key] = {}, scope.Key
		end
	end
	local sideButtons, sideKeys = {}, {}
	local sideTab, sideOpen = "outline", true
	local marksVersion = 0
	local outlineRows = {}
	local rootPages = {} -- the first page of each page key (defined with the pages below)

	local toolToggles = {} -- the toolbar's toggle buttons (find, flow, side), for refreshToolbar
	local statusParts = {} -- the status bar's labels, by key
	local function setFollow(R, fn)
		followFn = fn
		Nav.crumbR, Nav.crumbFn = R, fn -- the toolbar shows the functions around the cursor
	end

	-- The script whose live functions we can inspect (the active tab, if it decompiled).
	local function currentScript()
		local tab = tabs[activeTab]
		return tab and tab.Kind == "script" and not tab.Failed and tab.Script or nil
	end

	----------------------------------------------------------------------------------------------
	-- The navigator's pages
	----------------------------------------------------------------------------------------------

	-- Width of a text in the navigator's font
	Nav.textWidth = function(text, size)
		local ok, bounds = pcall(function()
			return service.TextService:GetTextSize(text, size or 14, Enum.Font.SourceSans, Vector2.new(2000, 30))
		end)
		return ok and bounds.X or #text * 7
	end

	renderEdit = function()
		for _,child in pairs(editList:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		local stack = sideStacks[sideTab]
		local deep = #stack > 0
		local page = stack[#stack] or rootPages[sideTab]
		-- the same page drawn again stays where it was scrolled to
		local keepY = page == Nav.page and editList.CanvasPosition.Y or 0
		Nav.page = page
		page.Tick = nil -- a page that updates itself (watch, trace) sets this while it builds
		Nav.rowInfo, Nav.jumps = {}, {}
		Nav.made, Nav.hits, Nav.dry, Nav.fold, Nav.section = 0, 0, false, false, ""
		local filter = not page.NoFilter and page.Filter or ""
		Nav.needle = filter ~= "" and filter:lower() or nil

		-- Back says where it goes: the page this one was opened from
		editBack.Visible = deep
		local titleX = 8
		if deep then
			local from = stack[#stack - 1] or rootPages[sideTab]
			local name = from.Chip or from.Title
			editBack.Text = "< "..(#name > 18 and (name:sub(1, 16).."..") or name)
			local width = math.ceil(Nav.textWidth(editBack.Text)) + 10
			editBack.Size = UDim2.new(0, width, 0, 22)
			titleX = width + 10
		end
		editTitle.Position = UDim2.new(0, titleX, 0, 48)
		editTitle.Size = UDim2.new(1, -(titleX + 4), 0, 22)
		editTitle.Text = page.Title
		page.Build(page)

		-- a long list, or one that is being filtered, has the filter box above it
		local box = Nav.filterBox
		local filtering = not page.NoFilter and (Nav.hits > 12 or filter ~= "")
		box.Gui.Visible = filtering
		if box:GetText() ~= filter then box:SetText(filter) end
		local top = filtering and 96 or 70
		editList.Position = UDim2.new(0, 4, 0, top)
		editList.Size = UDim2.new(1, -4, 1, -top)
		if keepY > 0 then
			task.defer(function() editList.CanvasPosition = Vector2.new(0, keepY) end)
		end
	end

	-- Opens a page from the one that is showing (Back returns to that one). With key it goes on that
	-- tab of the navigator instead, which is shown first. The navigator opens if it was closed.
	pushEdit = function(title, build, key)
		if key and key ~= sideTab then selectSideTab(key, true) end
		if not sideOpen then setSideOpen(true, true) end
		local stack = sideStacks[sideTab]
		stack[#stack+1] = {Title = title, Build = build}
		renderEdit()
	end

	-- Shows a tab of the navigator from its first page, or (with a title and a builder) with one page
	-- opened from that, in place of whatever the tab had open.
	openPage = function(key, title, build)
		sideStacks[key] = {}
		selectSideTab(key, true)
		if build then pushEdit(title, build) else renderEdit() end
		window:Show()
	end

	setSideOpen = function(on, quiet)
		sideOpen = on
		Nav.sideFrame.Visible = on
		relayout()
		if on and not quiet then renderEdit() end
	end

	-- Paints the navigator's two rows of tabs for the page that is showing.
	Nav.paintTabs = function()
		local scope = Nav.scopeOf[sideTab]
		Nav.last[scope] = sideTab
		for key, btn in pairs(sideButtons) do
			btn.BackgroundColor3 = key == scope and Settings.Theme.ListSelection or Settings.Theme.Button
		end
		for key, chip in pairs(Nav.chips) do
			chip.Visible = Nav.scopeOf[key] == scope
			chip.BackgroundColor3 = key == sideTab and Settings.Theme.ListSelection or Settings.Theme.Button
		end
	end

	-- The chips say how many their page holds (traced functions, watched values, marks, lists).
	Nav.paintChips = function()
		local scope = Nav.scopeOf[sideTab]
		for key, chip in pairs(Nav.chips) do
			if Nav.scopeOf[key] == scope then
				local page = rootPages[key]
				local n
				if page.Count then
					local ok, count = pcall(page.Count)
					n = ok and count or nil
				end
				local text = page.Chip..((n and n > 0) and (" "..n) or "")
				if chip.Text ~= text then
					chip.Text = text
					chip.Size = UDim2.new(0, math.ceil(Nav.textWidth(text, 13)) + 12, 1, -3)
				end
			end
		end
	end

	selectSideTab = function(key, skipRender)
		sideTab = key
		Nav.auto = false -- chosen, not just shown because no script is open
		Nav.paintTabs()
		if not sideOpen then setSideOpen(true, true) end
		local open = rootPages[key].Open
		if open then open() end -- a page that needs every script read starts that
		if not skipRender then renderEdit() end
	end

	-- Scrolls the navigator's list so that a row is in view.
	Nav.reveal = function(row)
		task.delay(0.05, function() -- the rows are laid out a moment after they are made
			if not row.Parent then return end
			local top = row.AbsolutePosition.Y - editList.AbsolutePosition.Y + editList.CanvasPosition.Y
			local view = editList.AbsoluteSize.Y
			if top < editList.CanvasPosition.Y then
				editList.CanvasPosition = Vector2.new(0, math.max(0, top - 22))
			elseif top + 22 > editList.CanvasPosition.Y + view then
				editList.CanvasPosition = Vector2.new(0, top + 44 - view)
			end
		end)
	end

	-- Paints a row for what it is: the current one of its list (or the function the cursor is in), under
	-- the mouse, or plain. One that was gone to already is dimmed.
	Nav.paint = function(row)
		local info = Nav.rowInfo[row]
		if not info then return end
		local lit = info.Cur or info.Lit
		local color = lit and Settings.Theme.ListSelection or (info.Hover and Settings.Theme.Button or Settings.Theme.Main2)
		row.BackgroundColor3 = color
		if info.Right then info.Right.BackgroundColor3 = color end
		row.TextTransparency = (info.Seen and not lit) and 0.45 or 0
	end

	-- A row was chosen (clicked, or stepped to): it is the current one of its page, and goes where
	-- it goes. The page may be drawn again on the way, so the rows it has afterwards are painted.
	Nav.take = function(jump, at)
		local page = Nav.page
		page.At, page.Cur = at, jump.Text
		page.Seen = page.Seen or {}
		page.Seen[jump.Text] = true
		jump.Go()
		if Nav.page ~= page then return end
		for i,j in ipairs(Nav.jumps) do
			local info = Nav.rowInfo[j.Row]
			if info then
				info.Cur = i == at and j.Text == page.Cur
				info.Seen = page.Seen[j.Text] or false
				Nav.paint(j.Row)
			end
		end
		if Nav.jumps[at] then Nav.reveal(Nav.jumps[at].Row) end
	end

	-- The next or the previous row of the list in the navigator that goes somewhere
	-- (a reference, a match in another script, a note, a call site).
	Nav.step = function(dir)
		local jumps = Nav.jumps
		if not sideOpen or #jumps == 0 then
			toast("No list to step through: open one in the navigator (references, a search, the marks)", "warn")
			return
		end
		local page = Nav.page
		local at = page.At
		if not (at and jumps[at] and jumps[at].Text == page.Cur) then
			at = nil
			for i,j in ipairs(jumps) do
				if j.Text == page.Cur then at = i break end
			end
		end
		at = at and ((at - 1 + dir) % #jumps + 1) or (dir > 0 and 1 or #jumps)
		Nav.take(jumps[at], at)
	end

	-- A list that was asked for (references, the matches of a find, how a function is reached, who
	-- requires a script) goes on the Refs page, on top of the lists asked for before: Back returns to
	-- those, and the last five are kept. They stay when another script is opened.
	Nav.showRefs = function(title, build)
		local stack = sideStacks.refs
		for i = #stack, 1, -1 do
			if stack[i].Title == title then table.remove(stack, i) end -- asked again: the new one takes its place
		end
		pushEdit(title, build, "refs")
		while #stack > 5 do table.remove(stack, 1) end
		window:Show()
	end

	-- Rebuilds the open tab's first page when what it shows has changed: the outline and remotes follow
	-- the analysis, the calls tab the function under the cursor, the marks the notes. A
	-- page opened from it stays put. force rebuilds regardless.
	refreshSidebar = function(force)
		if not sideOpen then return end
		if #sideStacks[sideTab] > 0 and not force then return end

		local key
		if sideTab == "outline" or sideTab == "remotes" then
			key = tabAnalysis()
		elseif sideTab == "calls" then
			local R = tabAnalysis()
			key = R and (tostring(R)..tostring(followFn))
		elseif sideTab == "marks" then
			key = tostring(activeTab)..":"..marksVersion
		end
		if not force and (key == nil or sideKeys[sideTab] == key) then return end
		sideKeys[sideTab] = key
		renderEdit()
	end

	-- The notes changed, which the marks tab lists and the scroll bar ticks
	marksChanged = function()
		marksVersion = marksVersion + 1
		refreshSidebar()
		refreshMarkers()
	end

	-- The pages about the open script start again with another script. The others (what the game is
	-- running, what all the scripts say, the lists that were asked for) stay as they are.
	local function resetSidebarPages()
		for _,key in ipairs({"outline", "calls", "remotes", "marks", "scanner", "module"}) do
			sideStacks[key], sideKeys[key] = {}, nil
			local page = rootPages[key]
			page.Filter, page.Seen, page.Cur, page.At = nil, nil, nil, nil
		end
	end

	-- Stands in for a row that is not made (the filter leaves it out, its section is folded, its list is
	-- past its limit): whatever is read from it, set on it or called on it does nothing.
	local NO_ROW = setmetatable({}, {__index = function(self) return self end, __newindex = function() end, __call = function(self) return self end})

	-- Whether a row with this text is to be made. Counts the rows that pass the filter (Nav.hits) and
	-- the ones made (Nav.made), for eachRow and for the filter box.
	local function rowShown(text)
		if Nav.fold then return false end
		if Nav.needle and not text:lower():find(Nav.needle, 1, true) then return false end
		Nav.hits = Nav.hits + 1
		if Nav.dry then return false end
		Nav.made = Nav.made + 1
		return true
	end

	local function newLabel(parent, text, position, size, color)
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Position = position
		lbl.Size = size
		lbl.Font = Enum.Font.SourceSans
		lbl.TextSize = 14
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextTruncate = Enum.TextTruncate.AtEnd
		lbl.TextColor3 = color
		lbl.Text = text
		lbl.Parent = parent
		return lbl
	end

	-- A hint or a message: grey text, wrapped when it is long.
	local function addTextRow(order, text)
		if Nav.dry or Nav.fold then return NO_ROW end
		local lbl = newLabel(editList, text, UDim2.new(0,0,0,0), UDim2.new(1,-10,0,22), GREY)
		lbl.LayoutOrder = order
		-- a long message wraps instead of being cut off
		local ok, size = pcall(function()
			return service.TextService:GetTextSize(text, 14, Enum.Font.SourceSans, Vector2.new(Nav.W - 30, 1000))
		end)
		if ok and size.Y > 22 then
			lbl.TextWrapped = true
			lbl.TextTruncate = Enum.TextTruncate.None
			lbl.TextYAlignment = Enum.TextYAlignment.Top
			lbl.Size = UDim2.new(1,-10,0,size.Y + 4)
		end
		return lbl
	end

	-- A row that goes somewhere when clicked: a line of the code, a script. right is drawn dim at the
	-- right edge (a line number); without it a text that starts with ":123  " or ends with "  :123" has
	-- that part put there. Nav.step goes through these rows. link is for a row that opens another
	-- page instead: it gets an arrow and is not one of the rows Nav.step goes to.
	local function addNavRow(order, text, onClick, right, link)
		if not rowShown(text) then return NO_ROW end
		local label = text
		if link then
			right = ">"
		elseif not right then
			local line, rest = text:match("^(:%d+)  (.*)$")
			if not line then rest, line = text:match("^(.-)  (:%d+)$") end
			if line then label, right = rest, line end
		end

		local btn = Instance.new("TextButton")
		btn.AutoButtonColor = false
		btn.BackgroundColor3 = Settings.Theme.Main2
		btn.BorderSizePixel = 0
		btn.Size = UDim2.new(1,-10,0,22)
		btn.LayoutOrder = order
		btn.Font = Enum.Font.SourceSans
		btn.TextSize = 14
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.TextTruncate = Enum.TextTruncate.AtEnd
		btn.TextColor3 = WHITE
		btn.Text = " "..label

		local page = Nav.page
		local info = {}
		Nav.rowInfo[btn] = info
		if right then
			-- on its own background, so a long text ends under it
			local width = #right * 7 + 10
			local lbl = newLabel(btn, right.." ", UDim2.new(1,-width,0,0), UDim2.new(0,width,1,0), GREY)
			lbl.BackgroundTransparency = 0
			lbl.BackgroundColor3 = Settings.Theme.Main2
			lbl.BorderSizePixel = 0
			lbl.TextSize = 13
			lbl.TextXAlignment = Enum.TextXAlignment.Right
			info.Right = lbl
		end

		if link then
			btn.MouseButton1Click:Connect(function() onClick() end)
		else
			local id = Nav.section..text..(right or "") -- what tells the row apart when the page is drawn again
			local jump = {Row = btn, Text = id, Go = onClick}
			Nav.jumps[#Nav.jumps+1] = jump
			local at = #Nav.jumps
			info.Cur = page.Cur == id and page.At == at
			info.Seen = page.Seen ~= nil and page.Seen[id] or false
			btn.MouseButton1Click:Connect(function() Nav.take(jump, at) end)
		end
		btn.MouseEnter:Connect(function()
			info.Hover = true
			Nav.paint(btn)
		end)
		btn.MouseLeave:Connect(function()
			info.Hover = false
			Nav.paint(btn)
		end)
		if info.Cur or info.Seen then Nav.paint(btn) end
		btn.Parent = editList
		return btn
	end

	-- Calls fn(order, key, value) per entry, for fn to add the entry's row. Past limit rows (default 200)
	-- no more are made, only counted: a line then says how many there are, and the filter above the list
	-- (which leaves rows out before they are counted) is the way to the rest. Returns the last order used.
	-- step is how many orders an entry gets (2 for a row with a line under it: order - 1 and order).
	local function eachRow(tbl, base, fn, limit, step)
		if Nav.fold then return base end -- in a folded section
		limit, step = limit or 200, step or 1
		local order, made, hits = base, Nav.made, Nav.hits
		for k, v in pairs(tbl) do
			if Nav.made - made < limit then
				order = order + step
				fn(order, k, v)
			elseif Nav.needle then
				Nav.dry = true -- past the limit: fn is only asked whether the entry passes the filter
				order = order + step
				fn(order, k, v)
			else
				Nav.hits = Nav.hits + 1 -- without a filter every entry counts, unseen
			end
		end
		Nav.dry = false
		local shown, matching = Nav.made - made, Nav.hits - hits
		if matching > shown then
			order = order + 1
			addTextRow(order, ("%d of %d shown: type in the filter above the list to narrow it"):format(shown, matching))
		end
		return order
	end

	-- The viewer's newer features hang off this table (one local instead of one per function: Luau
	-- allows 200 locals in a function and main() is close).
	local Tools = {}

	-- A row that opens another page of the navigator.
	Tools.link = function(order, text, onClick)
		return addNavRow(order, text, onClick, nil, true)
	end

	-- A row that does something when clicked and leaves you where you are: a real button. danger is for
	-- one that throws something away.
	Tools.action = function(order, text, onClick, danger)
		if Nav.dry or Nav.fold then return NO_ROW end
		local btn = Lib.Button.new()
		btn.Text = text
		btn.Size = UDim2.new(1,-10,0,22)
		btn.LayoutOrder = order
		btn.TextTruncate = Enum.TextTruncate.AtEnd
		if danger then btn.TextColor3 = Settings.Theme.Warning end
		btn.OnClick:Connect(function() onClick() end)
		btn.Gui.Parent = editList
		return btn
	end

	-- The title of a section of a page, with how many it holds. A click folds the section (the rows up
	-- to the next title are then not made) until it is clicked again.
	Tools.head = function(order, text, count)
		Nav.fold, Nav.section = false, text
		if Nav.dry then return NO_ROW end
		local key = tostring(Nav.page.Title)..":"..text
		local folded = Nav.folded[key] == true
		local btn = Instance.new("TextButton")
		btn.AutoButtonColor = false
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Size = UDim2.new(1,-10,0,22)
		btn.LayoutOrder = order
		btn.Font = Enum.Font.SourceSansBold
		btn.TextSize = 14
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.TextTruncate = Enum.TextTruncate.AtEnd
		btn.TextColor3 = WHITE
		btn.Text = (folded and "+ " or "- ")..text..(count and ("  ("..count..")") or "")
		btn.MouseButton1Click:Connect(function()
			Nav.folded[key] = (not folded) or nil
			renderEdit()
		end)
		btn.Parent = editList
		Nav.fold = folded
		return btn
	end

	-- A row with a label and a drop-down of options (texts); onSelect(option) is called after a choice.
	Tools.choice = function(order, label, options, selected, onSelect)
		if Nav.dry or Nav.fold then return NO_ROW end
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1,-10,0,22)
		row.LayoutOrder = order
		row.Parent = editList
		newLabel(row, label, UDim2.new(0,2,0,0), UDim2.new(0.38,-2,1,0), WHITE)
		local drop = Lib.DropDown.new()
		drop.CanBeEmpty = false
		drop:SetOptions(options)
		drop:SetSelected(selected)
		drop.Position = UDim2.new(0.38,0,0,1)
		drop.Size = UDim2.new(0.62,0,0,20)
		drop.Gui.Parent = row
		drop.OnSelect:Connect(function(option)
			if option then onSelect(option) end
		end)
		return row
	end

	-- A row with a label above a text box; Enter calls onSubmit(text). Returns the box.
	Tools.input = function(order, label, text, onSubmit)
		if Nav.dry or Nav.fold then return NO_ROW end
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1,-10,0,label and 44 or 24)
		row.LayoutOrder = order
		row.Parent = editList
		local y = 0
		if label then
			newLabel(row, label, UDim2.new(0,0,0,0), UDim2.new(1,0,0,18), WHITE)
			y = 20
		end
		local box = Lib.ViewportTextBox.new()
		box.Position = UDim2.new(0,0,0,y)
		box.Size = UDim2.new(1,0,0,22)
		box.Parent = row
		box:SetText(text or "")
		box.TextBox.FocusLost:Connect(function(enter)
			if enter then onSubmit(box:GetText()) end
		end)
		return box
	end

	-- A row with a check box and its label (clicking either flips it); onToggle(ticked) is called after.
	Tools.checkRow = function(order, text, ticked, onToggle)
		if Nav.dry or Nav.fold then return NO_ROW end
		-- a long label wraps onto more lines
		local okSize, size = pcall(function()
			return service.TextService:GetTextSize(text, 14, Enum.Font.SourceSans, Vector2.new(Nav.W - 66, 1000))
		end)
		local wrapped = okSize and size.Y > 18
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1,-10,0,wrapped and math.ceil(size.Y) + 6 or 24)
		row.LayoutOrder = order
		row.Parent = editList
		local current = ticked and true or false
		local box = Lib.Checkbox.new()
		box.Gui.Position = UDim2.new(0,2,0,4)
		box.Gui.Parent = row
		box:SetState(current)
		box.OnInput:Connect(function()
			current = box.Toggled
			onToggle(current)
		end)
		local label = Instance.new("TextButton")
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(0,26,0,0)
		label.Size = UDim2.new(1,-26,1,0)
		label.Font = Enum.Font.SourceSans
		label.TextSize = 14
		label.TextColor3 = WHITE
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = wrapped
		label.TextTruncate = wrapped and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd
		label.Text = text
		label.Parent = row
		label.MouseButton1Click:Connect(function()
			current = not current
			box:SetState(current)
			onToggle(current)
		end)
		return row
	end

	----------------------------------------------------------------------------------------------
	-- Running script: the watch list, live functions, tracepoints and connections. They sit in one block
	-- that exports a few names through Live: Luau allows 200 locals in a function and main() is close.
	----------------------------------------------------------------------------------------------

	local Live = {}
	do
		local traces, traceLog, traceSeq, traceStart = {}, {}, 0, os.clock()
		local watches = {}
		local liveCache = setmetatable({}, {__mode = "k"})
		local addValueRow
		local scanning = setmetatable({}, {__mode = "k"}) -- scripts that a background scan is running for

		-- A live value was changed: a later scan would no longer recognise the source's literals, so none is made.
		local function markEdited()
			local scr = currentScript()
			local rec = scr and liveCache[scr]
			if rec then rec.Edited = true end
		end

		local function parseEdit(text, kind)
			if kind == "number" then
				local n = tonumber(text)
				if not n then return nil, false end
				return n, true
			elseif kind == "boolean" then
				if text == "true" then
					return true, true
				elseif text == "false" then
					return false, true
				else
					return nil, false
				end
			else
				return text, true
			end
		end

		----------------------------------------------------------------------------------------------
		-- Watch list: pin a value (upvalue, constant, table field) and see it change
		----------------------------------------------------------------------------------------------

		-- Short text for a value in logs and the watch list.
		local function fmt(v)
			local t = typeof(v)
			if t == "string" then
				local s = #v > 30 and (v:sub(1,30).."...") or v
				return '"'..(s:gsub("%c"," "))..'"'
			elseif t == "number" or t == "boolean" or t == "nil" then
				return tostring(v)
			elseif t == "Instance" then
				local ok, name = pcall(function() return v.ClassName..":"..v.Name end)
				return ok and name or "Instance"
			end
			return t
		end

		local function addWatch(label, getter)
			for _,w in ipairs(watches) do
				if w.Label == label then return end
			end
			watches[#watches+1] = {Label = label, Get = getter}
			toast("Watching "..label)
		end

		-- The rows of a table's fields, edited in place on the live table (every other reference sees the
		-- change). watchLabel is the table's name in the watch list. order is the last row used.
		Live.tableRows = function(tbl, watchLabel, order)
			eachRow(tbl, order or 0, function(n, key, v)
				if type(v) == "function" then
					Tools.link(n, tostring(key).." (function)", function() Live.showFunction(key, v) end)
					return
				end
				addValueRow(n, tostring(key).." ("..typeof(v)..")", v, function(newValue)
					return (pcall(function() tbl[key] = newValue end))
				end, {Label = watchLabel.."."..tostring(key), Get = function() return tbl[key] end})
			end)
		end

		-- A page of a table's fields, opened from the page that is showing.
		local function showTable(label, tbl, watchLabel)
			pushEdit(label, function() Live.tableRows(tbl, watchLabel) end)
		end

		-- Only number/string/boolean round-trip through a text box losslessly. Tables drill into a
		-- view of their fields; functions/other types just show their value. watch = {Label, Get}
		-- adds a Watch button.
		addValueRow = function(order, label, value, onApply, watch)
			local kind = typeof(value)

			if kind == "table" then
				Tools.link(order, label, function() showTable(label, value, watch and watch.Label or label) end)
				return
			end
			if not rowShown(label) then return end

			local row = Instance.new("Frame")
			row.Name = "Row"
			row.BackgroundTransparency = 1
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1,-10,0,40)
			row.LayoutOrder = order
			row.Parent = editList

			local scalar = kind == "number" or kind == "string" or kind == "boolean"
			local pin = scalar and watch
			newLabel(row, label, UDim2.new(0,0,0,0), UDim2.new(1,pin and -44 or 0,0,18), Color3.new(1,1,1))

			if pin then
				local btn = Instance.new("TextButton")
				btn.BackgroundColor3 = Settings.Theme.Button
				btn.BorderSizePixel = 0
				btn.Position = UDim2.new(1,-42,0,0)
				btn.Size = UDim2.new(0,42,0,18)
				btn.Font = Enum.Font.SourceSans
				btn.TextSize = 13
				btn.TextColor3 = Color3.new(1,1,1)
				btn.Text = "Watch"
				btn.MouseButton1Click:Connect(function() addWatch(watch.Label, watch.Get) end)
				btn.Parent = row
			end

			if scalar then
				local current = value
				local box = Lib.ViewportTextBox.new()
				box.Position = UDim2.new(0,0,0,19)
				box.Size = UDim2.new(1,0,0,20)
				box.Parent = row
				box:SetText(tostring(current))

				box.TextBox.FocusLost:Connect(function()
					local parsed, ok = parseEdit(box:GetText(), kind)
					if ok and onApply(parsed) then
						current = parsed
					else
						box:SetText(tostring(current))
					end
				end)
			else
				newLabel(row, tostring(value), UDim2.new(0,0,0,19), UDim2.new(1,0,0,20), Color3.new(0.5,0.5,0.5))
			end
		end

		-- The upvalues and constants of a function (only a connection's handler is opened this way; the
		-- script's own are edited on the code)
		local function buildFunctionRows(func)
			local order = eachRow(env.getupvalues(func), 0, function(n, i, v)
				addValueRow(n, ("Upvalue [%d] (%s)"):format(i, typeof(v)), v, function(newValue)
					local ok = pcall(env.setupvalue, func, i, newValue)
					if ok then markEdited() end
					return ok
				end, {Label = ("function upvalue [%d]"):format(i), Get = function() return env.getupvalues(func)[i] end})
			end)
			eachRow(env.getconstants(func), order, function(n, i, v)
				addValueRow(n, ("Constant [%d] (%s)"):format(i, typeof(v)), v, function(newValue)
					local ok = pcall(env.setconstant, func, i, newValue)
					if ok then markEdited() end
					return ok
				end, {Label = ("function constant [%d]"):format(i), Get = function() return env.getconstants(func)[i] end})
			end)
		end

		rootPages.watch = {Title = "Watch list", Chip = "Watch", NoFilter = true, Tip = "Values you pinned (an upvalue, a constant, a field of a table), shown as they change", Count = function() return #watches end, Build = function(page)
				if #watches == 0 then
					addTextRow(1, "Nothing watched yet. Hover a tinted constant or upvalue in the code and press Watch on its card, or use Watch next to a field in a table.")
				end
				if currentScript() and env.getgc then
					addTextRow(1000, "On the code: amber is a constant, violet an upvalue (fainter when it is a guess), green one you changed. Hover one to see or change it.")
				end

				local rows = {}
				for i,w in ipairs(watches) do
					local row = Instance.new("Frame")
					row.BackgroundTransparency = 1
					row.BorderSizePixel = 0
					row.Size = UDim2.new(1,-10,0,22)
					row.LayoutOrder = i
					row.Parent = editList

					local lbl = newLabel(row, "", UDim2.new(0,0,0,0), UDim2.new(1,-24,1,0), WHITE)
					local remove = Instance.new("TextButton")
					remove.BackgroundColor3 = Settings.Theme.Button
					remove.BorderSizePixel = 0
					remove.Position = UDim2.new(1,-22,0,2)
					remove.Size = UDim2.new(0,20,0,18)
					remove.Font = Enum.Font.SourceSans
					remove.TextSize = 14
					remove.TextColor3 = Color3.new(1,1,1)
					remove.Text = "x"
					remove.MouseButton1Click:Connect(function()
						table.remove(watches, table.find(watches, w))
						renderEdit()
					end)
					remove.Parent = row
					rows[i] = {Watch = w, Label = lbl}
				end

				local function refresh()
					for _,r in ipairs(rows) do
						local ok, v = pcall(r.Watch.Get)
						local text = ok and fmt(v) or "<unavailable>"
						if text ~= r.Watch.LastText then
							if r.Watch.LastText then r.Watch.ChangedAt = tick() end
							r.Watch.LastText = text
						end
						r.Label.Text = r.Watch.Label.." = "..text
						r.Label.TextColor3 = (tick() - (r.Watch.ChangedAt or 0) < 1) and Color3.fromRGB(255,220,90) or WHITE
					end
				end
				refresh()
				page.Tick = refresh
		end}

		----------------------------------------------------------------------------------------------
		-- Live functions and tracepoints
		----------------------------------------------------------------------------------------------

		-- Every function in the game that belongs to a script, found by looking at their environments: one
		-- getgc scan. yield: let the game draw now and then (the background scan does).
		local function collectLive(scr, yield)
			local list, seen = {}, 0
			for _, f in pairs(env.getgc()) do
				if typeof(f) == "function" then
					local ok, fenv = pcall(getfenv, f)
					if ok and type(fenv) == "table" and fenv.script == scr then
						local okName, name = pcall(debug.info, f, "n")
						name = (okName and type(name) == "string" and name ~= "") and name or "anonymous"
						local okLine, line = pcall(debug.info, f, "l")
						list[#list+1] = {Func = f, Name = name, Label = ("[%d] %s  :%s"):format(#list+1, name, okLine and tostring(line) or "?")}
					end
				end
				seen = seen + 1
				if yield and seen % 4000 == 0 then task.wait() end
			end
			return list
		end

		-- The live functions that belong to a script: the last scan if it is recent (or if live values were
		-- edited since, which a new scan would no longer recognise, or keep is set), else a new one.
		local function liveFunctions(scr, keep)
			local rec = liveCache[scr]
			if rec and (keep or rec.Edited or tick() - rec.Time < 60) then return rec.List end
			rec = {Time = tick(), List = collectLive(scr, false)}
			liveCache[scr] = rec
			return rec.List
		end

		-- A scan that doesn't hold the game up: a few thousand objects at a time. Calls done(count) at the end.
		local function scanInBackground(scr, done)
			if scanning[scr] then return end
			scanning[scr] = true
			task.spawn(function()
				local ok, list = pcall(collectLive, scr, true)
				scanning[scr] = nil
				if not ok then
					warn("OpenDex: scanning the running script failed: "..tostring(list))
					list = {} -- an empty answer, so it isn't tried again every few frames
				end
				liveCache[scr] = {Time = tick(), List = list}
				if done then done(#list) end
			end)
		end

		-- Takes a hook off a function again: the executor's restorefunction, or the original put back over it
		local function unhook(func, old)
			if env.restorefunction then
				pcall(env.restorefunction, func)
			elseif old and env.hookfunction then
				pcall(env.hookfunction, func, old)
			end
		end

		local function logCall(rec, caller, ...)
			local n = select("#", ...)
			local args = {}
			for i = 1, math.min(n, 6) do
				args[i] = fmt((select(i, ...)))
			end
			if n > 6 then args[#args+1] = "..." end
			local entry = {Time = os.clock() - traceStart, Label = rec.Label, Args = table.concat(args, ", "), Caller = caller}
			traceLog[#traceLog+1] = entry
			if #traceLog > 200 then table.remove(traceLog, 1) end
			traceSeq = traceSeq + 1
			return entry
		end

		-- Text for a list of values, the first few
		local function fmtList(list, from, to)
			local parts = {}
			for i = from, math.min(to, from + 3) do parts[#parts+1] = fmt(list[i]) end
			return table.concat(parts, ", ")
		end

		-- What the user typed into a tracepoint's boxes, as a function of the names in vars; nil and the error
		-- when it doesn't compile.
		local function compileExpr(text, vars)
			if not env.loadstring then return nil, "your executor has no loadstring" end
			return env.loadstring(("local %s = ...\nreturn %s"):format(vars, text))
		end

		-- Break on call: the calling thread waits here until Continue is pressed (or a minute has passed).
		local function park(rec, args)
			local wait = {Args = args, Go = false, Since = os.clock()}
			rec.Waiting = wait
			traceSeq = traceSeq + 1
			while not wait.Go and rec.Active and rec.Break and os.clock() - wait.Since < 60 do task.wait() end
			rec.Waiting = nil
			traceSeq = traceSeq + 1
		end

		local function startTrace(entry, quiet)
			local func = entry.Func
			if traces[func] and traces[func].Active then return end

			local rec = {Label = entry.Name, Hits = 0, Active = true}
			local old
			local ok, err = pcall(function()
				old = env.hookfunction(func, function(...)
					if not rec.Active then return old(...) end
					rec.Hits = rec.Hits + 1
					local args = table.pack(...)
					if rec.Cond then
						local okCond, pass = pcall(rec.Cond, args, rec.Hits)
						if okCond and not pass then return old(...) end -- not a call the user asked about
					end
					rec.Last = args -- (its page can copy them as code)

					-- Who called: read here, in the hook. From inside logCall the same level is the pcall around it.
					-- ponytail: level 3 is pcall, this hook, then the caller; an executor that wraps the hook in a
					-- C function puts that one there instead ([C]:-1)
					local okInfo, source, line = pcall(debug.info, 3, "sl")
					local okLog, logged = pcall(logCall, rec, okInfo and source and (tostring(source)..":"..tostring(line)) or "?", ...)
					if not okLog then logged = nil end
					if rec.Break and coroutine.isyieldable() then park(rec, args) end
					if rec.Edit then
						local res = table.pack(pcall(rec.Edit, args))
						if res[1] then args = table.pack(table.unpack(res, 2, res.n)) end
					end
					if rec.Force then
						local res = table.pack(pcall(rec.Force, args))
						if res[1] then
							if logged then logged.Rets = "forced: " .. fmtList(res, 2, res.n) end
							return table.unpack(res, 2, res.n)
						end
					end

					local ret = table.pack(old(table.unpack(args, 1, args.n)))
					if logged then logged.Rets = fmtList(ret, 1, ret.n) end
					return table.unpack(ret, 1, ret.n)
				end)
			end)
			if not ok then
				toast("Could not trace: "..tostring(err), "warn")
				return
			end
			rec.Old = old
			traces[func] = rec
			if not quiet then toast("Tracing "..entry.Name) end
		end

		local function stopTrace(func)
			local rec = traces[func]
			if not rec then return end
			rec.Active = false -- the hook stays installed but passes calls straight through
			unhook(func, rec.Old)
		end

		-- Compiles a box's text into rec[field] (nothing, for an empty box) and remembers the text.
		local function setExpr(rec, field, text, vars)
			text = text:match("^%s*(.-)%s*$")
			rec[field], rec[field.."Text"] = nil, text ~= "" and text or nil
			if text == "" then return end
			local fn, err = compileExpr(text, vars)
			if fn then
				rec[field] = fn
				toast("Set")
			else
				rec[field.."Text"] = nil
				toast("That doesn't compile: "..tostring(err), "error")
			end
		end

		-- What can be done to the calls of a traced function: only some of them, a value returned instead of
		-- the real one, other arguments, or a stop at each call until Continue.
		local function showTracepoint(rec)
			pushEdit(rec.Label, function(page)
				local order = 1
				addTextRow(order, ("%d calls so far%s. The boxes take Lua; an empty box turns the option off."):format(rec.Hits, rec.Active and "" or " (stopped)"))
				order = order + 1
				Tools.input(order, "Only when (args: the arguments, calls: the call count)", rec.CondText, function(text) setExpr(rec, "Cond", text, "args, calls") end)
				order = order + 1
				Tools.input(order, "Return this instead of calling the function (args: the arguments)", rec.ForceText, function(text) setExpr(rec, "Force", text, "args") end)
				order = order + 1
				Tools.input(order, "Call it with these arguments (args: the original list)", rec.EditText, function(text) setExpr(rec, "Edit", text, "args") end)
				order = order + 1
				Tools.checkRow(order, "Stop at every call, until Continue", rec.Break, function(on)
					rec.Break = on
					if not on and rec.Waiting then rec.Waiting.Go = true end
					renderEdit()
				end)
				if rec.Last then
					order = order + 1
					Tools.action(order, "Copy the arguments of the last call, as code", function()
						if not env.setclipboard then toast("Your executor has no setclipboard", "warn") return end
						env.setclipboard((Lib.ToLua({table.unpack(rec.Last, 1, rec.Last.n)})))
						toast("Copied")
					end)
				end
				local wait = rec.Waiting
				if wait then
					order = order + 1
					addTextRow(order, ("Stopped in a call with (%s). It goes on by itself after a minute."):format(fmtList(wait.Args, 1, wait.Args.n)))
					order = order + 1
					Tools.action(order, "Continue", function() wait.Go = true end)
					order = order + 1
					Tools.action(order, "Continue and stop stopping", function()
						rec.Break = false
						wait.Go = true
						renderEdit()
					end)
				end
				local shown = traceSeq
				page.Tick = function()
					if traceSeq ~= shown then renderEdit() end
				end
			end)
		end

		rootPages.trace = {Title = "Trace log", Chip = "Trace", NoFilter = true, Tip = "The functions being traced and the calls that were logged. Right-click a function in the code and choose Trace calls", Count = function() return Live.traceCount() end, Build = function(page)
				local order = 0
				if not env.hookfunction then
					order = order + 1
					addTextRow(order, "Tracing needs hookfunction, which your executor doesn't have.")
				end
				local any = false
				for _,rec in pairs(traces) do
					any = true
					order = order + 1
					local flags = (rec.Cond and " if" or "")..(rec.Force and " forced" or "")..(rec.Edit and " edited" or "")..(rec.Break and " break" or "")
					Tools.link(order, ("%s  hits: %d%s%s"):format(rec.Label, rec.Hits, rec.Active and "" or " (stopped)", flags), function() showTracepoint(rec) end)
				end
				if not any then
					order = order + 1
					addTextRow(order, "No tracepoints. Right-click a function in the code and choose Trace calls.")
				else
					order = order + 1
					Tools.action(order, "Stop all tracing", function()
						for func in pairs(traces) do stopTrace(func) end
						traces = {}
						renderEdit()
					end)
				end
				if #traceLog > 0 then
					order = order + 1
					Tools.head(order, "Calls", #traceLog)
					order = order + 1
					Tools.action(order, "Clear log", function()
						traceLog = {}
						renderEdit()
					end)
				end
				for i = #traceLog, math.max(1, #traceLog - 99), -1 do
					local e = traceLog[i]
					order = order + 1
					addTextRow(order, ("%.1fs %s(%s)%s  < %s"):format(e.Time, e.Label, e.Args, e.Rets and (" -> "..e.Rets) or "", e.Caller))
				end

				local shown = traceSeq
				page.Tick = function()
					if traceSeq ~= shown then renderEdit() end
				end
		end}

		----------------------------------------------------------------------------------------------
		-- From the source to the running script (the editor's right-click menu opens these)
		----------------------------------------------------------------------------------------------

		-- The running functions that correspond to a function of the source: the same name and number of
		-- parameters, the one with the most constants in common first. certain is true when one stands out.
		-- An anonymous function has no name to go on, so its constants are all that tells it apart. The
		-- third value is how many fit best (the first ones of the list, with as many constants in common):
		-- the copies of the function that are running, when the constants tell it apart. scr is the script
		-- whose running functions are looked at (the one in front when it is not given).
		local function liveMatches(R, F, keep, scr)
			scr = scr or currentScript()
			if not scr or not env.getgc then return {}, false, 0 end

			local short, params = Analysis.ShortName(F), Analysis.ParamCount(F)
			local wanted = Analysis.Literals(R, F)
			local list = {}
			for _,entry in ipairs(liveFunctions(scr, keep)) do
				local okName, name = pcall(debug.info, entry.Func, "n")
				local okArity, arity = pcall(debug.info, entry.Func, "a")
				name = (okName and type(name) == "string") and name or ""
				if name == (short or "") and (not okArity or arity == params) then
					local score = 0
					local okConst, constants = pcall(env.getconstants, entry.Func)
					if okConst and type(constants) == "table" then
						for _,k in pairs(constants) do
							if wanted[k] then score = score + 1 end
						end
					end
					list[#list+1] = {Entry = entry, Score = score}
				end
			end
			table.sort(list, function(a, b) return a.Score > b.Score end)

			local entries, top = {}, 0
			for i,m in ipairs(list) do
				entries[i] = m.Entry
				if m.Score == list[1].Score then top = i end
			end
			return entries, #list == 1 or (#list > 1 and list[1].Score > list[2].Score), top
		end

		-- Starts tracing the running functions that fit a function of the source best, or stops tracing
		-- every one that fits it (a constant changed since may have moved the best fit). scr: see
		-- liveMatches. Returns how many it traces, or stopped.
		local function traceFunction(R, F, stop, scr)
			local entries, _, top = liveMatches(R, F, false, scr)
			local name = Analysis.ShortName(F) or Analysis.FunctionName(R, F)
			if #entries == 0 then
				toast(("No running function matches %s (it may not exist yet)"):format(name), "warn")
				return 0
			end
			local count = 0
			for i = 1, stop and #entries or top do
				local func = entries[i].Func
				if stop then stopTrace(func) else startTrace(entries[i], true) end
				if stop or (traces[func] and traces[func].Active) then count = count + 1 end
			end
			toast(("%s %s%s"):format(stop and "Stopped tracing" or "Tracing", name, count > 1 and (" ("..count.." functions)") or ""))
			if not stop then openPage("trace") end
			return count
		end

		----------------------------------------------------------------------------------------------
		-- Marks on the code: what can be edited in the running script, tinted and outlined, and a card to see
		-- and change it. A string or number that some running function holds as a constant (amber), and a local
		-- that a function captures (violet; a guess at which upvalue, see Analysis.UpvalueIndex, is fainter),
		-- get a mark, green once you have changed it. Hovering one brightens it (every use of the same upvalue
		-- on screen with it) and, after a moment, opens the card. Only the lines on screen are looked at.
		----------------------------------------------------------------------------------------------

		local MARK_LIMIT, CARD_W, CARD_H = 400, 300, 148
		local codeRef, contentRef -- the editor and the window's content, given to Live.Init
		local markFrames, marks, marksAt, drawnKey = {}, {}, {}, nil
		local card, cardStroke, cardTitle, cardSub, cardBox, cardInfo, cardRevert, cardBrowse
		local cardMark, cardKind -- the mark the card shows, and the type of the value in its box
				local litTarget -- the target of the mark under the mouse
		local UPVALUE_COLOR = Color3.fromRGB(190,130,255)

		local function isScalar(v)
			local t = type(v)
			return t == "number" or t == "string" or t == "boolean"
		end

		-- Every constant of the script's running functions, by value: {Entry, Index} lists, built once per scan.
		local function constantIndex(rec)
			if rec.ByValue then return rec.ByValue end
			local byValue = {}
			for _,entry in ipairs(rec.List) do
				local ok, constants = pcall(env.getconstants, entry.Func)
				if ok and type(constants) == "table" then
					for i,k in pairs(constants) do
						local t = type(k)
						if (t == "string" or t == "number") and k == k then
							local list = byValue[k]
							if not list then
								list = {}
								byValue[k] = list
							end
							if #list < 40 then list[#list+1] = {Entry = entry, Index = i} end
						end
					end
				end
			end
			rec.ByValue = byValue
			return byValue
		end

		local function readConstant(m)
			local ok, constants = pcall(env.getconstants, m.Entry.Func)
			if ok and type(constants) == "table" then return constants[m.Index] end
		end

		local function readUpvalue(t)
			local ok, ups = pcall(env.getupvalues, t.Entry.Func)
			if ok and type(ups) == "table" then return ups[t.Index] end
		end

		local function currentValue(t)
			if t.Kind == "constant" then return readConstant(t.Matches[1]) end
			return readUpvalue(t)
		end

		-- What the running script has behind a token, if that can be edited, else nil. A constant target is
		-- {Kind, Matches = {{Entry, Index}...}, Shown}; an upvalue target {Kind, Entry, Index, Func, Sym, Certain,
		-- Shown}. Worked out once per token and kept (so what was changed can be put back).
		local function liveTarget(R, ti)
			local scr = currentScript()
			local rec = scr and liveCache[scr]
			if not rec then return nil end
			if not rec.Targets then rec.Targets = setmetatable({}, {__mode = "k"}) end
			local cache = rec.Targets[R]
			if not cache then
				cache = {}
				rec.Targets[R] = cache
			end

			local kind = R.tt[ti]
			if kind == "str" or kind == "num" then
				local hit = cache[ti]
				if hit ~= nil then return hit or nil end
				local target
				local values = Analysis.ConstantValues(R, ti)
				if values then
					local byValue = constantIndex(rec)
					local matches = {}
					for _,v in ipairs(values) do
						for _,m in ipairs(byValue[v] or {}) do matches[#matches+1] = m end
					end
					if #matches > 0 then target = {Kind = "constant", Matches = matches, Shown = fmt(values[1])} end
				end
				cache[ti] = target or false
				return target
			elseif kind == "name" then
				local sym = R.symAt[ti]
				if not (sym and sym.decl) then return nil end
				local F = Analysis.UpvalueSite(R, ti)
				if not F then return nil end
				local bySym = cache[sym]
				if not bySym then
					bySym = {}
					cache[sym] = bySym
				end
				local hit = bySym[F]
				if hit ~= nil then return hit or nil end

				local target
				local entries, certain = liveMatches(R, F, true)
				local entry = entries[1]
				local index = entry and Analysis.UpvalueIndex(R, F, sym)
				if index then
					local ok, ups = pcall(env.getupvalues, entry.Func)
					local last = 0
					if ok and type(ups) == "table" then
						for k in pairs(ups) do
							if type(k) == "number" and k > last then last = k end
						end
					end
					if index <= last then
						target = {Kind = "upvalue", Entry = entry, Index = index, Func = F, Sym = sym, Certain = certain, Shown = sym.name}
					end
				end
				bySym[F] = target or false
				return target
			end
		end

		-- Sets a target's constants (all of them) or its upvalue. Returns how many were set and how many there are.
		-- The first value of each is kept so it can be put back.
		local function setTarget(t, value)
			local set, total = 0, 0
			local function one(holder, read, write)
				total = total + 1
				local before = read()
				pcall(write, value)
				if read() == value then
					set = set + 1
					if not holder.HasOrig then holder.HasOrig, holder.Orig = true, before end
				end
			end
			if t.Kind == "constant" then
				for _,m in ipairs(t.Matches) do
					one(m, function() return readConstant(m) end, function(v) env.setconstant(m.Entry.Func, m.Index, v) end)
				end
			else
				one(t, function() return readUpvalue(t) end, function(v) env.setupvalue(t.Entry.Func, t.Index, v) end)
			end
			if set > 0 then markEdited() end
			return set, total
		end

		local function revertTarget(t)
			local function back(holder, write)
				if not holder.HasOrig then return end
				pcall(write, holder.Orig)
				holder.HasOrig, holder.Orig = nil, nil
			end
			if t.Kind == "constant" then
				for _,m in ipairs(t.Matches) do back(m, function(v) env.setconstant(m.Entry.Func, m.Index, v) end) end
			else
				back(t, function(v) env.setupvalue(t.Entry.Func, t.Index, v) end)
			end
		end

		-- Whether it was changed, and what its value was before
		local function origOf(t)
			if t.Kind == "constant" then
				for _,m in ipairs(t.Matches) do
					if m.HasOrig then return true, m.Orig end
				end
				return false
			end
			return t.HasOrig == true, t.Orig
		end

		-- green once changed, else amber for a constant and violet for an upvalue
		local function markColor(t)
			if origOf(t) then return Settings.Theme.Success end
			return t.Kind == "constant" and Settings.Theme.Warning or UPVALUE_COLOR
		end

		local function hideMarks()
			for _,f in ipairs(markFrames) do f.Visible = false end
		end

		-- Tint and outline of a drawn mark: strongest while the mouse is on it or its card is open, faint for
		-- an upvalue that is only a guess
		local function styleMark(m)
			local t = m.Target
			local f = m.Frame
			local lit = t == litTarget or (cardMark ~= nil and cardMark.Target == t)
			local faint = t.Kind == "upvalue" and not t.Certain
			f.BackgroundColor3 = markColor(t)
			f.BackgroundTransparency = lit and 0.65 or (faint and 0.94 or 0.86)
			f.Stroke.Color = f.BackgroundColor3
			f.Stroke.Thickness = lit and 2 or 1
			f.Stroke.Transparency = lit and 0 or (faint and 0.65 or 0.3)
		end

		local function restyleMarks()
			for _,m in ipairs(marks) do styleMark(m) end
		end

		-- Outlines the marks that are on screen. Does nothing again until something it depends on changes.
		local function drawMarks(force)
			if not codeRef then return end
			local tab = tabs[activeTab]
			local R = tab and tab.Analysis
			local scr = currentScript()
			local rec = scr and liveCache[scr]
			local linesFrame = codeRef.GuiElems.LinesFrame
			local on = R and rec and tab.Kind == "script" and not tab.Loading and not tab.Failed

			local key = "off"
			if on then
				key = table.concat({tostring(R), tostring(rec), codeRef.ViewX, codeRef.ViewY, #codeRef.Lines, linesFrame.AbsoluteSize.X, linesFrame.AbsoluteSize.Y}, ":")
			end
			if key == drawnKey and not force then return end
			drawnKey = key
			marks, marksAt = {}, {}
			if not on then
				hideMarks()
				return
			end

			local cellW, cellH = math.ceil(codeRef.FontSize / 2), codeRef.FontSize
			local viewX, viewY = codeRef.ViewX, codeRef.ViewY
			local cols = math.ceil(linesFrame.AbsoluteSize.X / cellW) + 1
			local lastLine = math.min(#codeRef.Lines, viewY + math.ceil(linesFrame.AbsoluteSize.Y / cellH) + 1)
			for line = viewY + 1, lastLine do
				local first, last = Analysis.TokensOnLine(R, line)
				if first then
					local lineStart, text = Analysis.LineStart(R, line), codeRef.Lines[line]
					for ti = first, last do
						local kind = R.tt[ti]
						if #marks < MARK_LIMIT and (kind == "str" or kind == "num" or kind == "name") and R.tel[ti] == line then
							local from, to = R.tp[ti], R.te[ti]
							local startCol, length = from - lineStart, to - from + 1
							-- on screen, and still what the analysis saw
							if startCol + length > viewX and startCol < viewX + cols and text:sub(startCol + 1, startCol + length) == R.src:sub(from, to) then
								local target = liveTarget(R, ti)
								if target then marks[#marks+1] = {Line = line, Col = startCol, Len = length, Target = target} end
							end
						end
					end
				end
			end

			for i,m in ipairs(marks) do
				marksAt[m.Line..":"..m.Col] = m
				m.X, m.Y = (m.Col - viewX) * cellW, (m.Line - 1 - viewY) * cellH
				local f = markFrames[i]
				if not f then
					f = createSimple("Frame", {Name = "LiveMark", BorderSizePixel = 0, ZIndex = 4, Parent = linesFrame})
					createSimple("UIStroke", {Name = "Stroke", Parent = f})
					createSimple("UICorner", {CornerRadius = UDim.new(0,2), Parent = f})
					markFrames[i] = f
				end
				f.Position = UDim2.fromOffset(m.X, m.Y)
				f.Size = UDim2.fromOffset(m.Len * cellW, cellH)
				f.Visible = true
				m.Frame = f
				styleMark(m)
			end
			for i = #marks + 1, #markFrames do markFrames[i].Visible = false end
		end

		-- The card: what the mark is, its value now, a box to change it
		local function refreshCard()
			local m = cardMark
			if not m then return end
			local t = m.Target
			local value = currentValue(t)
			if t.Kind == "constant" then
				cardTitle.Text = "Constant "..t.Shown
				cardSub.Text = ("held by %d running function%s"):format(#t.Matches, #t.Matches == 1 and "" or "s")
			else
				cardTitle.Text = "Upvalue "..t.Shown
				cardSub.Text = ("%s upvalue %d of %s"):format(t.Certain and "probably" or "maybe", t.Index, t.Entry.Name)
			end
			local color = markColor(t)
			cardTitle.TextColor3, cardStroke.Color = color, color
			cardKind = typeof(value)
			local scalar = isScalar(value)
			local changed, before = origOf(t)
			cardBox.Visible = scalar
			cardBrowse.Visible = cardKind == "table"
			cardRevert.Visible = scalar and changed
			if scalar then
				cardBox:SetText(tostring(value))
				cardInfo.Text = changed and ("Changed from %s. Revert puts it back."):format(fmt(before)) or "Type a new value and press Enter."
			elseif cardKind == "table" then
				cardInfo.Text = "A table: Browse lists its fields in the sidebar, where they can be changed."
			else
				cardInfo.Text = ("%s: %s. It can't be changed here."):format(cardKind, fmt(value))
			end
			restyleMarks()
		end

		local function applyCard()
			local t = cardMark and cardMark.Target
			if not t then return end
			local parsed, ok = parseEdit(cardBox:GetText(), cardKind)
			if not ok then
				toast("That isn't a "..cardKind, "warn")
				refreshCard()
				return
			end
			if parsed ~= currentValue(t) then
				local set, total = setTarget(t, parsed)
				if set == total then
					toast(("Set %s%s"):format(t.Shown, total > 1 and (" in "..total.." functions") or ""), "success")
				elseif set > 0 then
					toast(("Set %d of %d"):format(set, total), "warn")
				else
					toast("Could not set it", "error")
				end
			end
			refreshCard()
		end

		local function showCard(mark)
			cardMark = mark
			refreshCard()
			local abs, origin, size = codeRef.GuiElems.LinesFrame.AbsolutePosition, contentRef.AbsolutePosition, contentRef.AbsoluteSize
			local x = math.clamp(abs.X + mark.X - origin.X, 4, math.max(4, size.X - CARD_W - 4))
			-- touching the mark, so the mouse goes straight from the mark onto the card
			local y = abs.Y + mark.Y + codeRef.FontSize - origin.Y
			if y + CARD_H > size.Y - 4 then y = abs.Y + mark.Y - origin.Y - CARD_H end
			card.Position = UDim2.fromOffset(x, math.max(4, y))
			card.Visible = true
		end

		Live.hideCard = function()
			if not card or not cardMark then return end
			cardMark = nil
			card.Visible = false
			cardBox.TextBox:ReleaseFocus()
			restyleMarks()
		end

		Live.cardOpen = function() return cardMark ~= nil end

		Live.overCard = function() return cardMark ~= nil and Lib.CheckMouseInGui(card) end

		Live.markAt = function(line, col) return marksAt[line..":"..col] end

		-- Told the mark under the mouse (or nil) as the mouse moves and a few times a second: opens the card the
		-- moment the mouse is on a mark, moves it to another mark, closes it as soon as the mouse is off both.
		Live.hover = function(mark)
			if not card then return end
			local lit = mark and mark.Target
			if lit ~= litTarget then
				litTarget = lit
				restyleMarks()
			end
			if cardMark and (Lib.CheckMouseInGui(card) or cardBox.TextBox:IsFocused() or mark == cardMark) then
				return
			elseif mark then
				showCard(mark)
			elseif cardMark then
				Live.hideCard()
			end
		end

		Live.draw = drawMarks

		-- A few times a second: starts the first scan of a script that has none. Scans after that are asked for
		-- (Live.rescan), because one forgets what was edited.
		Live.tick = function()
			if not card then return end
			local scr = currentScript()
			if scr and env.getgc and not liveCache[scr] and not scanning[scr] then
				scanInBackground(scr, function() drawMarks(true) end)
			end
		end

		Live.rescan = function()
			local scr = currentScript()
			if not scr or not env.getgc then
				toast("Open a decompiled script on an executor with getgc first", "warn")
				return
			end
			if scanning[scr] then return end
			Live.hideCard()
			liveCache[scr] = nil
			drawMarks(true)
			toast("Scanning the running script...")
			scanInBackground(scr, function(count)
				toast(("Found %d running functions"):format(count), "success")
				drawMarks(true)
			end)
		end

		-- For the status bar
		Live.statusText = function()
			local scr = currentScript()
			if not (scr and env.getgc) then return "" end
			if scanning[scr] then return "Live: scanning..." end
			local rec = liveCache[scr]
			return rec and ("Live: %d fn"):format(#rec.List) or "Live: ..."
		end

		-- Builds the card; the editor and the window's content are what the marks and the card sit in.
		Live.Init = function(cf, content)
			codeRef, contentRef = cf, content

			card = createSimple("Frame", {Name = "LiveCard", BackgroundColor3 = Settings.Theme.Menu, BorderSizePixel = 0, Size = UDim2.fromOffset(CARD_W, CARD_H), Visible = false, ZIndex = 20, Parent = content})
			cardStroke = createSimple("UIStroke", {Color = Settings.Theme.Outline2, Thickness = 2, Parent = card}) -- takes the mark's colour
			createSimple("UICorner", {CornerRadius = UDim.new(0,4), Parent = card})
			local function label(text, y, h, color)
				local l = newLabel(card, text, UDim2.new(0,8,0,y), UDim2.new(1,-16,0,h), color)
				l.ZIndex = 21
				return l
			end
			cardTitle = label("", 6, 18, WHITE)
			cardSub = label("", 24, 16, GREY)
			cardBox = Lib.ViewportTextBox.new()
			cardBox.Position = UDim2.new(0,8,0,46)
			cardBox.Size = UDim2.new(1,-16,0,22)
			cardBox.ZIndex = 21
			cardBox.TextBox.ZIndex = 22
			cardBox.Parent = card
			cardInfo = label("", 72, 32, GREY)
			cardInfo.TextWrapped = true
			cardInfo.TextTruncate = Enum.TextTruncate.None
			cardInfo.TextYAlignment = Enum.TextYAlignment.Top

			local function button(text, x, tip, onClick)
				local b = createSimple("TextButton", {
					AutoButtonColor = true,
					BackgroundColor3 = Settings.Theme.Button,
					BorderSizePixel = 0,
					Position = UDim2.new(0,x,1,-30),
					Size = UDim2.new(0,86,0,22),
					Font = Enum.Font.SourceSans,
					TextSize = 14,
					TextColor3 = WHITE,
					Text = text,
					ZIndex = 21,
					Parent = card,
				})
				b.MouseButton1Click:Connect(onClick)
				Lib.Tooltip.attach(b, tip)
				return b
			end
			button("Watch", 8, "Add its value to the watch list (Live tab)", function()
				local t = cardMark and cardMark.Target
				if t then addWatch(t.Kind == "constant" and ("constant "..t.Shown) or ("upvalue "..t.Shown), function() return currentValue(t) end) end
			end)
			-- Browse (a table) and Revert (a value you changed) never show together, so they share a place
			cardBrowse = button("Browse", 98, "List the table's fields in the sidebar", function()
				local t = cardMark and cardMark.Target
				local value = t and currentValue(t)
				if type(value) ~= "table" then return end
				Live.hideCard()
				openPage("watch", "Upvalue "..t.Shown, function() Live.tableRows(value, "upvalue "..t.Shown) end)
			end)
			cardRevert = button("Revert", 98, "Put the value back to what it was before you changed it", function()
				local t = cardMark and cardMark.Target
				if t then
					revertTarget(t)
					toast("Put back")
					refreshCard()
				end
			end)
			cardBox.TextBox.FocusLost:Connect(function(enterPressed)
				if enterPressed then applyCard() else refreshCard() end
			end)
		end

		----------------------------------------------------------------------------------------------
		-- A function picked out of a table (a module's value, an upvalue's fields)
		----------------------------------------------------------------------------------------------

		-- The function of the source a running function most likely is: the same name (the key it was found
		-- under, or its debug name) and, when known, the same number of parameters.
		local function sourceFunction(R, name, func)
			local okName, debugName = pcall(debug.info, func, "n")
			local okArity, arity = pcall(debug.info, func, "a")
			local best
			for _,f in ipairs(R.functions) do
				local short = f.parent and Analysis.ShortName(f)
				if short and (short == tostring(name) or (okName and short == debugName)) then
					if not best or (okArity and Analysis.ParamCount(f) == arity) then best = f end
				end
			end
			return best
		end

		Live.showFunction = function(name, func)
			pushEdit(tostring(name), function()
				local order = 0
				local R = tabAnalysis()
				local f = R and sourceFunction(R, name, func)
				if f then
					order = order + 1
					addNavRow(order, "Go to it in the source", function() jumpTo(f.line1, 0) end, ":"..f.line1)
				end
				if env.hookfunction then
					order = order + 1
					Tools.action(order, "Trace calls", function()
						startTrace({Func = func, Name = tostring(name)})
						openPage("trace")
					end)
				end
				if env.getupvalues and env.getconstants then
					order = order + 1
					Tools.link(order, "Upvalues and constants", function() pushEdit("Upvalues and constants", function() buildFunctionRows(func) end) end)
				end
				if order == 0 then
					order = order + 1
					addTextRow(order, "Nothing can be done with it on this executor.")
				end
			end)
		end

		-- The value a module in the game returned, if something has required it already (requiring it now
		-- would run its code): true and the value, or false and why there is none to read.
		Live.moduleValue = function(scr)
			local loaded = false
			if env.getloadedmodules then
				local okList, list = pcall(env.getloadedmodules)
				for _,m in ipairs(okList and type(list) == "table" and list or {}) do
					if m == scr then loaded = true break end
				end
			end
			if not loaded then
				return false, env.getloadedmodules and "Nothing has required this module yet, and requiring it now would run its code." or "Your executor has no getloadedmodules."
			end
			local ok, value = pcall(require, scr)
			if not ok then return false, "Could not read it: "..tostring(value) end
			return true, value
		end

		-- What the open module returned: a table of fields, each a value that can be changed or a function to open.
		rootPages.module = {Title = "What the module returned", Chip = "Module", Tip = "The value the open ModuleScript returned to the scripts that required it: its fields can be changed, its functions opened", Build = function()
			local scr = currentScript()
			if not (scr and scr:IsA("ModuleScript")) then
				addTextRow(1, "Open a ModuleScript to see the value it returned.")
				return
			end
			local ok, value = Live.moduleValue(scr)
			if not ok then
				addTextRow(1, value)
				return
			end
			editTitle.Text = "Returned by "..scr.Name
			if type(value) ~= "table" then
				addTextRow(1, ("It returns a %s: %s"):format(typeof(value), fmt(value)))
			else
				Live.tableRows(value, scr.Name)
			end
		end}
		Live.showModule = function() openPage("module") end

		----------------------------------------------------------------------------------------------
		-- Value scanner: every number, string and boolean the script's functions hold (in their upvalues and
		-- in the tables those lead to), narrowed by what happens to them between scans
		----------------------------------------------------------------------------------------------

		local scan = {List = {}, Round = 0, Busy = false}
		local SCAN_LIMIT = 30000

		local function readCandidate(c)
			if c.Func then
				local ok, ups = pcall(env.getupvalues, c.Func)
				if ok and type(ups) == "table" then return ups[c.Index] end
				return nil
			end
			local ok, v = pcall(function() return c.Tbl[c.Key] end)
			if ok then return v end
			return nil
		end

		local function startScan()
			local scr = currentScript()
			if not scr or scan.Busy or not (env.getgc and env.getupvalues) then return end
			scan.Busy, scan.List, scan.Round = true, {}, 0
			renderEdit()
			task.spawn(function()
				local ok, err = pcall(function()
					local functions = collectLive(scr, true) -- a fresh look (the marks' own scan is left as it is)
					local seenTables, steps, out = {}, 0, {}
					local function step()
						steps = steps + 1
						if steps % 3000 == 0 then task.wait() end
					end
					local function visit(tbl, path, depth)
						for k,v in pairs(tbl) do
							step()
							if #out >= SCAN_LIMIT then return end
							if isScalar(v) then
								out[#out+1] = {Tbl = tbl, Key = k, Last = v, Label = path.."."..tostring(k)}
							elseif type(v) == "table" and depth < 3 and not seenTables[v] then
								seenTables[v] = true
								visit(v, path.."."..tostring(k), depth + 1)
							end
						end
					end
					for _,entry in ipairs(functions) do
						local okUps, ups = pcall(env.getupvalues, entry.Func)
						if okUps and type(ups) == "table" then
							for i,v in pairs(ups) do
								step()
								if #out >= SCAN_LIMIT then break end
								if isScalar(v) then
									out[#out+1] = {Func = entry.Func, Index = i, Last = v, Label = ("%s upvalue [%s]"):format(entry.Name, tostring(i))}
								elseif type(v) == "table" and not seenTables[v] then
									seenTables[v] = true
									visit(v, ("%s up%s"):format(entry.Name, tostring(i)), 1)
								end
							end
						end
					end
					scan.List = out
				end)
				scan.Busy = false
				if not ok then toast("The scan failed: "..tostring(err), "error") end
				renderEdit()
			end)
		end

		-- Keeps the candidates whose value now relates to the one at the last scan the given way.
		local function nextScan(kind, target)
			local kept = {}
			for _,c in ipairs(scan.List) do
				local now, before = readCandidate(c), c.Last
				local keep
				if kind == "changed" then
					keep = now ~= before
				elseif kind == "unchanged" then
					keep = now == before
				elseif kind == "increased" then
					keep = type(now) == "number" and type(before) == "number" and now > before
				elseif kind == "decreased" then
					keep = type(now) == "number" and type(before) == "number" and now < before
				else
					keep = now == target
				end
				if keep and isScalar(now) then
					c.Last = now
					kept[#kept+1] = c
				end
			end
			scan.List, scan.Round = kept, scan.Round + 1
			renderEdit()
		end

		rootPages.scanner = {Title = "Value scanner", Chip = "Scanner", Tip = "Finds where the open script keeps a value: scan, change the value in the game, narrow the list", Build = function()
				local order = 0
				local function act(text, onClick)
					order = order + 1
					Tools.action(order, text, onClick)
				end
				local function note(text)
					order = order + 1
					addTextRow(order, text)
				end
				if not (env.getgc and env.getupvalues) then note("Your executor needs getgc and getupvalues.") return end
				if not currentScript() then note("Open a decompiled script first.") return end
				if scan.Busy then note("Looking through the script's functions...") return end

				note("Finds where the script keeps a value: scan, change the value in the game (spend a coin, take a hit), then narrow the list.")
				act("New scan: every number, string and boolean", startScan)
				if #scan.List == 0 then
					if scan.Round > 0 then note("Nothing is left. Start a new scan.") end
					return
				end
				note(("%d candidates after %d narrowing steps. Keep the ones that:"):format(#scan.List, scan.Round))
				act("changed", function() nextScan("changed") end)
				act("did not change", function() nextScan("unchanged") end)
				act("went up", function() nextScan("increased") end)
				act("went down", function() nextScan("decreased") end)
				order = order + 1
				Tools.input(order, "are equal to (a number, text, true or false)", "", function(text)
					local value = tonumber(text)
					if value == nil then
						value = text == "true" or (text ~= "false" and text)
					end
					nextScan("equals", value)
				end)
				order = eachRow(scan.List, order, function(n, _, c)
					local value = readCandidate(c)
					addValueRow(n, ("%s (%s)"):format(c.Label, typeof(value)), value, function(newValue)
						local okSet
						if c.Func then
							okSet = pcall(env.setupvalue, c.Func, c.Index, newValue)
						else
							okSet = pcall(function() c.Tbl[c.Key] = newValue end)
						end
						if okSet then markEdited() end
						return okSet
					end, {Label = c.Label, Get = function() return readCandidate(c) end})
				end, 40)
		end}
		Live.showScanner = function() openPage("scanner") end

		----------------------------------------------------------------------------------------------
		-- Coverage: count the calls of the script's running functions to see which ones ever run
		----------------------------------------------------------------------------------------------

		local coverage = {Hooks = {}, On = false, Map = setmetatable({}, {__mode = "k"})}
		local COVERAGE_LIMIT = 40

		Live.coverageOn = function() return coverage.On end

		-- The script whose calls are being counted, or nil
		Live.coverageScript = function() return coverage.On and coverage.Script or nil end

		-- Starts counting the calls of a script's running functions (the script in front, the first 40 of
		-- them, unless told otherwise), or stops the counting that is going on. Returns how many it counts.
		Live.toggleCoverage = function(scr, limit)
			if coverage.On then
				for func,rec in pairs(coverage.Hooks) do unhook(func, rec.Old) end
				coverage.Hooks, coverage.On, coverage.Script = {}, false, nil
				toast("No longer counting calls")
				return 0
			end
			scr = scr or currentScript()
			limit = limit or COVERAGE_LIMIT
			if not (scr and env.getgc and env.hookfunction) then
				toast("Open a decompiled script on an executor with getgc and hookfunction first", "warn")
				return 0
			end
			local list = liveFunctions(scr, true)
			local count = 0
			for _,entry in ipairs(list) do
				if count >= limit then break end
				local traced = traces[entry.Func]
				if not coverage.Hooks[entry.Func] and not (traced and traced.Active) then
					local rec = {Hits = 0}
					local old
					local ok = pcall(function()
						old = env.hookfunction(entry.Func, function(...)
							rec.Hits = rec.Hits + 1
							return old(...)
						end)
					end)
					if ok then
						rec.Old = old
						coverage.Hooks[entry.Func] = rec
						count = count + 1
					end
				end
			end
			coverage.On, coverage.Script = count > 0, count > 0 and scr or nil
			toast(count == 0 and "No running function could be hooked" or ("Counting the calls of %d running functions%s"):format(count, #list > limit and (" of "..#list.." (the first ones)") or ""), count == 0 and "warn" or "info")
			return count
		end

		-- How many calls the running copies of a function of the source have had since counting started, or
		-- nil when it is not being counted (or no running function matches it). The copies are the running
		-- functions that fit it best. The second value is true when those are not all one function (they
		-- were made on different lines, and neither name nor constants tell them apart): the count is then
		-- theirs together. scr: see liveMatches.
		Live.coverageHits = function(R, F, scr)
			if not coverage.On then return nil end
			local map = coverage.Map[R]
			if not map then
				map = {}
				coverage.Map[R] = map
			end
			local found = map[F]
			if not found then
				local entries, _, top = liveMatches(R, F, true, scr)
				local madeAt
				found = {Entries = entries, Top = top, Mixed = false}
				for i = 1, top do
					local ok, line = pcall(debug.info, entries[i].Func, "l")
					if ok and madeAt and line ~= madeAt then found.Mixed = true end
					madeAt = ok and line or madeAt
				end
				map[F] = found
			end
			local sum, any = 0, false
			for i = 1, found.Top do
				local rec = coverage.Hooks[found.Entries[i].Func]
				if rec then
					sum = sum + rec.Hits
					any = true
				end
			end
			return any and sum or nil, found.Mixed
		end

		-- "name  source:line" for a connection's handler. [exec] marks executor-made closures (OpenDex's own listeners).
		local function describeConnection(conn)
			local f = conn.Function
			if not f then return "<foreign>" end
			local ok, source, line, name = pcall(debug.info, f, "sln")
			if not ok then return "<unknown>" end
			local okExec, isExec = pcall(env.isexecutorclosure, f)
			return ("%s%s  %s:%s"):format((okExec and isExec) and "[exec] " or "", (name and name ~= "") and name or "anonymous", tostring(source), tostring(line))
		end

		local function connectionScript(conn)
			if not conn.Function then return nil end
			local ok, scr = pcall(function() return getfenv(conn.Function).script end)
			return ok and typeof(scr) == "Instance" and scr or nil
		end

		local function setConnections(conns, on)
			for _, conn in ipairs(conns) do
				pcall(function() if on then conn:Enable() else conn:Disable() end end)
			end
		end

		ScriptViewer.ViewConnections = function(obj)
			-- ponytail: named events only. GetPropertyChangedSignal connections need a probe per property, add if wanted
			local signals = {}
			local cls = API.Classes[obj.ClassName]
			while cls do
				for _, ev in ipairs(cls.Events) do
					local ok, conns = pcall(function() return env.getconnections(obj[ev.Name]) end)
					if ok and #conns > 0 then
						signals[#signals+1] = {Name = ev.Name, Conns = conns}
					end
				end
				cls = cls.Superclass
			end
			table.sort(signals, function(a, b) return a.Name < b.Name end)

			local function showConnection(conn)
				local scr = connectionScript(conn)
				pushEdit(describeConnection(conn), function()
					addValueRow(1, "Enabled", conn.Enabled, function(on)
						setConnections({conn}, on)
						return conn.Enabled == on
					end)
					if scr then
						Tools.action(2, "Select script in Explorer", function() Explorer.SelectObj(scr) end)
						Tools.action(3, "Open the script", function() ScriptViewer.ViewScript(scr) end)
					end
					if conn.Function and env.getupvalues and env.getconstants then
						Tools.link(4, "Upvalues and constants", function()
							pushEdit("Upvalues and constants", function() buildFunctionRows(conn.Function) end)
						end)
					end
				end)
			end

			local function showSignal(sig)
				pushEdit(sig.Name, function()
					Tools.action(1, "Disable all", function() setConnections(sig.Conns, false) renderEdit() end)
					Tools.action(2, "Enable all", function() setConnections(sig.Conns, true) renderEdit() end)
					eachRow(sig.Conns, 2, function(n, _, conn)
						Tools.link(n, ("[%s] %s"):format(conn.Enabled and "on" or "off", describeConnection(conn)), function() showConnection(conn) end)
					end)
				end)
			end

			-- a page opened from the Live pages, whichever of them was last showing
			openPage(Nav.last.live or "trace", "Connections: "..obj.Name, function()
				if #signals == 0 then addTextRow(1, "No connections found.") end
				eachRow(signals, 0, function(n, _, sig)
					Tools.link(n, ("%s (%d)"):format(sig.Name, #sig.Conns), function() showSignal(sig) end)
				end)
			end)
		end

		Live.showTrace = function() openPage("trace") end
		Live.showWatch = function() openPage("watch") end
		Live.traceFunction = traceFunction
		-- OpenDex is being reloaded or closed: every hook this viewer put on the game's functions comes off
		-- (tracepoints, call counters). A call that is stopped at a tracepoint goes on.
		Live.unload = function()
			for func in pairs(traces) do stopTrace(func) end
			for func,rec in pairs(coverage.Hooks) do unhook(func, rec.Old) end
			coverage.Hooks, coverage.On = {}, false
		end
		-- how many functions are being traced
		Live.traceCount = function()
			local count = 0
			for _,rec in pairs(traces) do
				if rec.Active then count = count + 1 end
			end
			return count
		end
		-- Opens the options of the tracepoint on a function of that name (the editor's right-click menu)
		Live.editTrace = function(name)
			for _,rec in pairs(traces) do
				if rec.Active and rec.Label == name then
					openPage("trace")
					showTracepoint(rec)
					return
				end
			end
		end
		-- whether a function with that name is being traced
		Live.isTracing = function(name)
			for _,rec in pairs(traces) do
				if rec.Active and rec.Label == name then return true end
			end
			return false
		end

		----------------------------------------------------------------------------------------------
		-- The AI window: the running script, for an agent (Tools.registerAgent calls this, with h: what
		-- finds the script, the decompile, the analysis and the function its arguments name). A function
		-- of the source is matched to the running ones as the right-click menu matches it, and the hooks
		-- are the viewer's own: they show in the Outline and on the Trace page, and come off when OpenDex
		-- closes.
		----------------------------------------------------------------------------------------------

		Live.agent = function(Agent, h)
			local reg = Agent.Register

			local function need(...)
				for _,name in ipairs({...}) do
					if not env[name] then error("Your executor has no "..name, 0) end
				end
			end

			-- A value on one line. A table is its fields, one level deep: written out in full it could be
			-- huge, and reading it that far would call into the game's own metamethods.
			local function brief(value, max)
				if type(value) ~= "table" then return Agent.Show(value, max or 200) end
				local parts, more = {}, 0
				for k,v in next, value do
					if #parts < 12 then
						parts[#parts+1] = ("%s = %s"):format(tostring(k), type(v) == "table" and "{...}" or Agent.Show(v, 60))
					else
						more = more + 1
					end
				end
				return "{"..table.concat(parts, ", ")..(more > 0 and (", and "..more.." more") or "").."}"
			end

			-- The function the arguments name, which has to be one that can be running (not the main chunk)
			local function namedFunction(R, args)
				local F = h.functionFor(R, args)
				if not F.parent then error("that line is in the main chunk, not in a function: give a line inside a function, or its name", 0) end
				return F
			end

			reg("coverage", function(args)
				need("getgc", "hookfunction")
				local action = args.action or "read"
				local counted = Live.coverageScript()
				if action == "stop" then
					if counted then Live.toggleCoverage() end
					return {counting = false, stopped = counted and h.whereIs(counted) or nil}
				end
				local scr = h.scriptFor(args.script)
				if action == "start" then
					if counted then error(("calls are being counted already, in %s: read them, or stop that first"):format(h.whereIs(counted)), 0) end
					local count = Live.toggleCoverage(scr, 200)
					if count == 0 then error("no running function of this script could be hooked (the script may not be running)", 0) end
					return {counting = true, script = Agent.IdOf(scr), functions = count, note = "Have the thing done in the game now, then read the counts (action = \"read\")."}
				elseif action ~= "read" then
					error("action is start, read or stop", 0)
				end
				if counted ~= scr then
					error(counted and ("calls are being counted in %s, not in this script"):format(h.whereIs(counted)) or "calls are not being counted: start it first (action = \"start\")", 0)
				end

				local R = h.analysisOf(h.rawOf(scr))
				local ran, idle, unmatched = {}, 0, 0
				for _,o in ipairs(Analysis.Outline(R)) do
					if o.fn.parent then
						local hits, mixed = Live.coverageHits(R, o.fn, scr)
						if not hits then
							unmatched = unmatched + 1
						elseif hits == 0 then
							idle = idle + 1
						else
							ran[#ran+1] = {name = o.name, line = o.line1, last = o.line2, calls = hits, shared = mixed or nil}
						end
					end
				end
				table.sort(ran, function(a, b)
					if a.calls ~= b.calls then return a.calls > b.calls end
					return a.line < b.line
				end)
				local total = #ran
				for i = #ran, 101, -1 do ran[i] = nil end
				return {script = Agent.IdOf(scr), path = Tools.fullName(scr), ranCount = total, ran = ran, notCalled = idle, notCounted = unmatched}
			end)

			reg("trace", function(args)
				local action = args.action or "read"
				if action == "start" or (action == "stop" and args.script ~= nil) then
					need("getgc", "hookfunction")
					local scr = h.scriptFor(args.script)
					local R = h.analysisOf(h.rawOf(scr))
					local F = namedFunction(R, args)
					local name = Analysis.FunctionName(R, F)
					local count = traceFunction(R, F, action == "stop", scr)
					if count == 0 then error(("no running function matches %s (the script may not be running, or the function is not made yet)"):format(name), 0) end
					return {[action == "stop" and "stopped" or "tracing"] = name, script = Agent.IdOf(scr), runningFunctions = count}
				elseif action == "stop" then
					local count = 0
					for func,rec in pairs(traces) do
						if rec.Active then count = count + 1 end
						stopTrace(func)
					end
					traces = {}
					return {stopped = count}
				elseif action ~= "read" then
					error("action is start, read or stop", 0)
				end

				local limit = math.clamp(math.floor(tonumber(args.limit) or 30), 1, 100)
				local out = {tracing = {}, calls = {}, logged = #traceLog}
				for _,rec in pairs(traces) do
					local last
					if rec.Last then
						last = {}
						for i = 1, math.min(rec.Last.n, 10) do last[i] = brief(rec.Last[i], 300) end
						last = table.concat(last, ", ")
					end
					out.tracing[#out.tracing+1] = {["function"] = rec.Label, calls = rec.Hits, stopped = not rec.Active or nil, lastArguments = last}
				end
				table.sort(out.tracing, function(a, b) return a["function"] < b["function"] end)
				for i = math.max(1, #traceLog - limit + 1), #traceLog do
					local e = traceLog[i]
					out.calls[#out.calls+1] = {at = math.floor(e.Time * 10) / 10, ["function"] = e.Label, arguments = e.Args, returned = e.Rets, caller = e.Caller}
				end
				return out
			end)

			reg("live", function(args)
				local scr = h.scriptFor(args.script)
				if args.line == nil and (type(args.name) ~= "string" or args.name == "") then
					if not scr:IsA("ModuleScript") then error("give a line or a name, for a function's running values (a ModuleScript by itself gives what it returned)", 0) end
					local ok, value = Live.moduleValue(scr)
					if not ok then error(value, 0) end
					if type(value) ~= "table" then return ("%s returned a %s: %s"):format(h.whereIs(scr), typeof(value), brief(value)) end
					local fields = {}
					for k,v in next, value do fields[#fields+1] = ("  %s = %s"):format(tostring(k), brief(v)) end
					table.sort(fields)
					local total = #fields
					for i = #fields, 101, -1 do fields[i] = nil end
					return ("%s returned a table with %d fields%s\n%s"):format(h.whereIs(scr), total, total > 100 and " (the first 100)" or "", table.concat(fields, "\n"))
				end

				need("getgc", "getupvalues", "getconstants")
				local R = h.analysisOf(h.rawOf(scr))
				local F = namedFunction(R, args)
				local entries, _, top = liveMatches(R, F, false, scr)
				if #entries == 0 then
					error(("no running function matches %s (the script may not be running, or the function is not made yet)"):format(Analysis.FunctionName(R, F)), 0)
				end
				local func = entries[1].Func
				local lines = {h.whereIs(scr), ("%s   (lines %d-%d)"):format(Analysis.Signature(R, F), F.line1, F.line2)}
				if top > 1 then lines[#lines+1] = ("%d running functions fit it: the first is shown"):format(top) end

				-- (a list with holes: a value that is nil has no entry)
				local function numbered(list)
					local last = 0
					for k in pairs(list) do
						if type(k) == "number" and k > last then last = k end
					end
					return last
				end
				local okUps, ups = pcall(env.getupvalues, func)
				ups = okUps and type(ups) == "table" and ups or {}
				local names = Analysis.Upvalues(R, F)
				local count = numbered(ups)
				lines[#lines+1] = ""
				if count == 0 then
					lines[#lines+1] = "Upvalues: none"
				else
					lines[#lines+1] = ("Upvalues (%d; the names are a guess from the order the code uses them%s):"):format(count, #names ~= count and (", and a weak one here: the source uses "..#names.." outside locals") or "")
					for i = 1, math.min(count, 60) do
						lines[#lines+1] = ("  [%d] %s = %s"):format(i, names[i] and names[i].name or "?", brief(ups[i]))
					end
				end
				local okConsts, consts = pcall(env.getconstants, func)
				consts = okConsts and type(consts) == "table" and consts or {}
				local shown = {}
				for i = 1, numbered(consts) do
					if consts[i] ~= nil and #shown < 60 then shown[#shown+1] = ("  [%d] %s"):format(i, brief(consts[i], 100)) end
				end
				lines[#lines+1] = ""
				lines[#lines+1] = #shown == 0 and "Constants: none" or "Constants:"
				for _,text in ipairs(shown) do lines[#lines+1] = text end
				return table.concat(lines, "\n")
			end)
		end
	end

	----------------------------------------------------------------------------------------------
	-- Messages, analysis cache, navigation
	----------------------------------------------------------------------------------------------

	-- A toast (see Main.Notify). kind: "info" (the default), "success", "warn" or "error".
	toast = function(text, kind)
		Main.Notify(text, kind)
	end

	-- Analysis of the current buffer, cached per tab until the text changes.
	analyze = function()
		if not Analysis then return nil, "The analysis module is not loaded" end

		local tab = tabs[activeTab]
		local text = codeFrame:GetText()
		if #text > 3000000 then
			if tab then tab.AnState = "too large" end
			return nil, "Script is too large to analyze"
		end

		if tab and tab.Analysis and tab.AnText == text then return tab.Analysis end

		local ok, R = pcall(Analysis.Analyze, text)
		if not ok then
			if tab then tab.AnState = "failed" end
			return nil, "Analysis failed: "..tostring(R)
		end
		if tab then tab.Analysis, tab.AnText, tab.AnState = R, text, "ready" end
		return R
	end

	-- Analysis of the active script tab, or nil and why there is none.
	tabAnalysis = function()
		local tab = tabs[activeTab]
		if not tab then return nil, "Open a script first." end
		if tab.Kind == "diff" then return nil, "Not available in a diff." end
		if tab.Loading then return nil, "Decompiling..." end
		if tab.Failed then return nil, "There is no source for this script." end
		return analyze()
	end

	local function cursorLine()
		return codeFrame.CursorY + 1
	end

	local function scrollToLine(line, center)
		local sv = codeFrame.ScrollV
		local top = line - 1
		local visible = math.max(1, sv.VisibleSpace - 1)
		if center or top < sv.Index or top >= sv.Index + visible then
			sv:ScrollTo(math.max(0, top - math.floor(visible / 3)))
		end
	end

	-- Cursor and scroll to a line (1-based) and column (0-based), without touching the history.
	local function showLine(line, col)
		codeFrame.SelectionRange = {{-1,-1},{-1,-1}}
		codeFrame.CursorX, codeFrame.CursorY = col or 0, line - 1
		codeFrame:UpdateCursor()
		scrollToLine(line, true)
		codeFrame:Refresh()
	end

	local function here()
		return {Tab = tabs[activeTab], Line = codeFrame.CursorY + 1}
	end

	-- Remembers where the cursor is, for Back. Whatever is about to take it somewhere else calls this
	-- first: a jump in the script, a link into another script, a click on a box of the graph or on a tab.
	local function record()
		local loc = here()
		if not loc.Tab or Nav.quiet then return end
		local last = backStack[#backStack]
		if last and last.Tab == loc.Tab and last.Line == loc.Line then return end
		backStack[#backStack+1] = loc
		if #backStack > 50 then table.remove(backStack, 1) end
		fwdStack = {}
	end

	jumpTo = function(line, col)
		record()
		showLine(line, col)
	end

	-- Shows a place of the history. A tab that was closed since has its script opened again. False when
	-- the place is gone (a diff or captured code that was closed).
	local function goToLocation(loc)
		local idx = table.find(tabs, loc.Tab)
		Nav.quiet = true -- getting there is not a place to come back to
		if idx then
			if idx ~= activeTab then activateTab(idx) end
		elseif loc.Tab.Kind == "script" and loc.Tab.Script then
			pcall(ScriptViewer.ViewScript, loc.Tab.Script)
		end
		Nav.quiet = false
		local tab = tabs[activeTab]
		if not tab or not (tab == loc.Tab or (loc.Tab.Script ~= nil and tab.Script == loc.Tab.Script)) then return false end
		showLine(math.clamp(loc.Line, 1, math.max(1, #codeFrame.Lines)), 0)
		return true
	end

	local function navBack()
		local from = here()
		while true do
			local loc = table.remove(backStack)
			if not loc then toast("No earlier location") return end
			if goToLocation(loc) then
				if from.Tab then fwdStack[#fwdStack+1] = from end
				return
			end
		end
	end

	local function navForward()
		local from = here()
		while true do
			local loc = table.remove(fwdStack)
			if not loc then toast("No later location") return end
			if goToLocation(loc) then
				if from.Tab then backStack[#backStack+1] = from end
				return
			end
		end
	end

	-- "Combat :120, in onHit(part)" for a place of the history.
	Nav.place = function(loc)
		local text = ("%s :%d"):format(loc.Tab.Name, loc.Line)
		local R = loc.Tab.Analysis
		if R and Analysis then
			local ok, fn = pcall(Analysis.FunctionAtLine, R, loc.Line)
			if ok and fn and fn.parent then text = text..", in "..Analysis.Signature(R, fn) end
		end
		return text
	end

	-- Back by several places at once (the list under the Back button): the ones passed over go to Forward.
	Nav.backTo = function(steps)
		local from = here()
		if from.Tab then fwdStack[#fwdStack+1] = from end
		for _ = 1, steps - 1 do fwdStack[#fwdStack+1] = table.remove(backStack) end
		local loc = table.remove(backStack)
		if loc and not goToLocation(loc) then toast("That place is gone: its tab was closed", "warn") end
	end

	-- Goes to a line of a tab that may not be the one showing, or may have been closed since (its script
	-- is opened again): what a row of a list that outlives its script does.
	Nav.go = function(tab, line, col)
		if tabs[activeTab] == tab then
			jumpTo(line, col)
			return
		end
		record()
		if goToLocation({Tab = tab, Line = line}) then
			showLine(line, col)
		else
			toast("That tab was closed", "warn")
		end
	end

	----------------------------------------------------------------------------------------------
	-- Line colors and scrollbar markers (notes, diffs, the flowchart selection, find matches)
	----------------------------------------------------------------------------------------------

	do
		local FLOW_COLOR = Color3.fromRGB(170,140,30)
		local LINE_COLORS = {add = Color3.fromRGB(40,160,70), del = Color3.fromRGB(190,60,60), hunk = Color3.fromRGB(70,70,120)}
		local MARKER_COLORS = {find = Color3.fromRGB(255,200,0), note = Color3.fromRGB(70,150,255), add = Color3.fromRGB(60,200,90), del = Color3.fromRGB(220,80,80), use = Color3.fromRGB(190,190,190), write = Color3.fromRGB(255,170,80)}

		refreshMarkers = function()
			local sv = codeFrame.ScrollV
			local map = {}
			local tab = tabs[activeTab]
			local count = 0

			-- where the name under the cursor is used (Nav.trackUses); the rest goes over these
			for i,u in ipairs(Nav.uses or {}) do
				if i > 400 then break end
				if map[u.Line - 1] ~= MARKER_COLORS.write then map[u.Line - 1] = u.Write and MARKER_COLORS.write or MARKER_COLORS.use end
			end
			if tab and tab.DiffKinds then
				for line, kind in pairs(tab.DiffKinds) do
					if count < 400 and MARKER_COLORS[kind] then
						map[line - 1] = MARKER_COLORS[kind]
						count = count + 1
					end
				end
			end
			for _,c in ipairs(tab and tab.Ann and tab.Ann.comments or {}) do map[c.line - 1] = MARKER_COLORS.note end
			for i, m in ipairs(Nav.matches) do
				if i > 400 then break end
				map[m[1] - 1] = MARKER_COLORS.find
			end

			sv.Markers = {}
			for index, color in pairs(map) do sv:AddMarker(index, color) end
			sv:UpdateMarkers()
		end

		refreshDecor = function()
			local colors = {}
			local tab = tabs[activeTab]
			if tab and tab.DiffKinds then
				for line, kind in pairs(tab.DiffKinds) do colors[line] = LINE_COLORS[kind] end
			end
			if flowRange and flowRange.Tab == tab then
				for line = flowRange.From, math.min(flowRange.To, flowRange.From + 200) do colors[line] = FLOW_COLOR end
			end
			codeFrame.LineColors = colors
			codeFrame:Refresh()
			refreshMarkers()
		end
	end

	----------------------------------------------------------------------------------------------
	-- Annotations (renames and notes) saved per script and per decompile
	----------------------------------------------------------------------------------------------

	local function checksum(text)
		local h = #text
		for i = 1, #text, 5 do
			h = (h * 31 + string.byte(text, i)) % 4294967291
		end
		return tostring(h)
	end

	local function annPath(scr)
		return "dex/annotations/"..env.parsefile(tostring(game.PlaceId).."_"..scr:GetFullName())
	end

	local function readAnnFile(scr)
		if not (env.isfile and env.readfile) then return nil end
		local path = annPath(scr)..".json"
		local okExists, exists = pcall(env.isfile, path)
		if not (okExists and exists) then return nil end
		local okRead, raw = pcall(env.readfile, path)
		if not okRead then return nil end
		local okJson, data = pcall(service.HttpService.JSONDecode, service.HttpService, raw)
		if not (okJson and type(data) == "table") then return nil end
		-- there are no bookmarks any more (a note marks a line as well): the ones saved before become notes
		for _,set in pairs(type(data.sets) == "table" and data.sets or {}) do
			if type(set) == "table" and type(set.bookmarks) == "table" then
				local comments = type(set.comments) == "table" and set.comments or {}
				local noted, anchors = {}, type(set.bookAnchors) == "table" and set.bookAnchors or {}
				for _,c in ipairs(comments) do noted[c.line] = true end
				for i,line in ipairs(set.bookmarks) do
					if not noted[line] then comments[#comments+1] = {line = line, text = "bookmark", a = anchors[i]} end
				end
				set.comments, set.bookmarks, set.bookAnchors = comments, nil, nil
			end
		end
		return data
	end

	-- How many lines a text has
	local function countLines(text)
		return select(2, text:gsub("\n", "\n"))
	end

	-- The lines of a tab's decompile as the decompiler wrote them (no header, notes or renames): what the
	-- anchors of its annotations are made from.
	local function rawLines(tab)
		if not tab.RawLines and tab.Raw then
			local lines = {}
			for line in (tab.Raw.."\n"):gmatch("(.-)\r?\n") do lines[#lines+1] = line end
			tab.RawLines = lines
		end
		return tab.RawLines or {}
	end

	local MAX_SETS = 6 -- versions of a script whose annotations are kept

	local function saveAnn(tab)
		if not (tab and tab.Script and tab.Hash and tab.Ann and env.writefile) then return end
		local ann = tab.Ann
		local file = tab.AnnFile or {v = 1, sets = {}}
		if type(file.sets) ~= "table" then file.sets = {} end
		tab.AnnFile = file

		-- what each note sits on, so that it can follow it into a later decompile
		if Analysis then
			local lines, offset = rawLines(tab), tab.Offset or 0
			for _,c in ipairs(ann.comments) do c.a = Analysis.Anchor(lines, c.line - offset) end
		end
		ann.off, ann.saved = tab.Offset or 0, os.time()
		-- (an empty set is kept too: with none for this version, the next visit would carry the notes of an
		-- older version over again, and deleting them would never hold)
		file.sets[tab.Hash] = ann

		-- earlier versions stay, to carry notes over from, but not forever
		local hashes = {}
		for hash,set in pairs(file.sets) do
			if type(set) == "table" then hashes[#hashes+1] = hash else file.sets[hash] = nil end
		end
		if #hashes > MAX_SETS then
			table.sort(hashes, function(a, b) return (file.sets[a].saved or 0) > (file.sets[b].saved or 0) end)
			for i = MAX_SETS + 1, #hashes do file.sets[hashes[i]] = nil end
		end

		local okJson, json = pcall(service.HttpService.JSONEncode, service.HttpService, file)
		if not okJson then return end
		pcall(env.makefolder, "dex/annotations")
		pcall(env.writefile, annPath(tab.Script)..".json", json)
	end

	-- The newest set of annotations saved for any version of a script that has anchors to carry them by.
	local function newestSet(file)
		local best
		for _,set in pairs(file.sets) do
			if type(set) == "table" and set.saved and (not best or set.saved > best.saved) then best = set end
		end
		return best
	end

	-- A later decompile of a script whose annotations were saved for an earlier one: puts the notes
	-- and renames where the same code is now (Analysis.Reanchor). What can't be found goes to
	-- ann.lost. Returns the new annotations and how many of each were carried.
	local function carryOver(tab, old, text)
		local lines, offset = rawLines(tab), tab.Offset or 0
		local ann = {renames = {}, comments = {}, lost = {}}
		local anchors, owners = {}, {}
		local function add(anchor, kind, item)
			local n = #anchors + 1
			anchors[n], owners[n] = anchor, {kind = kind, item = item}
		end
		for _,c in ipairs(old.comments or {}) do
			if type(c.a) == "table" then add(c.a, "note", c) end
		end
		for _,r in ipairs(old.renames or {}) do
			if type(r.a) == "table" and r.slot then add(r.a, "rename", r) end
		end
		local at = Analysis.Reanchor(lines, anchors)

		-- the local variables declared on each line, for finding a renamed one again
		local declared
		local function declaredOn(line)
			if not declared then
				declared = {}
				local ok, R = pcall(Analysis.Analyze, text)
				for i,sym in ipairs(ok and R.syms or {}) do
					if sym.decl then
						local l = R.tl[sym.decl]
						declared[l] = declared[l] or {}
						table.insert(declared[l], {Sym = sym, Index = i})
					end
				end
			end
			return declared[line] or {}
		end

		local counts = {note = 0, rename = 0, lost = 0}
		for n,owner in ipairs(owners) do
			local rawLine = at[n]
			local line = rawLine and rawLine + offset
			local item = owner.item
			local placed = false
			if line and owner.kind == "note" then
				ann.comments[#ann.comments+1] = {line = line, text = item.text}
				placed = true
			elseif line then
				local at2 = declaredOn(line)[item.slot]
				if at2 then
					ann.renames[#ann.renames+1] = {index = at2.Index, orig = at2.Sym.name, name = item.name, a = Analysis.Anchor(lines, rawLine), slot = item.slot}
					placed = true
				end
			end
			if placed then
				counts[owner.kind] = counts[owner.kind] + 1
			else
				counts.lost = counts.lost + 1
				ann.lost[#ann.lost+1] = {kind = owner.kind, text = owner.kind == "note" and item.text or (item.orig.." -> "..item.name)}
			end
		end
		return ann, counts
	end

	-- Loads the saved annotations that match this exact decompile and applies the renames to the text. When
	-- the script has changed since they were saved they are carried over to where the same code is now.
	local function attachAnnotations(tab, text, raw)
		tab.Hash = checksum(raw)
		tab.Offset = countLines(text) - countLines(raw) -- the header lines in front of the decompile
		tab.RawLines, tab.Carried = nil, nil
		local file = readAnnFile(tab.Script) or {v = 1, sets = {}}
		if type(file.sets) ~= "table" then file.sets = {} end
		tab.AnnFile = file
		local ann = type(file.sets[tab.Hash]) == "table" and file.sets[tab.Hash] or nil
		local carried
		if ann then
			-- the header changes length with the "more info" setting, which moves every line
			local shift = tab.Offset - (ann.off or tab.Offset)
			if shift ~= 0 then
				for _,c in ipairs(ann.comments or {}) do c.line = c.line + shift end
				ann.off = tab.Offset
			end
		else
			local old = Analysis and newestSet(file)
			if old then ann, carried = carryOver(tab, old, text) end
			ann = ann or {}
		end
		ann.renames, ann.comments, ann.lost = ann.renames or {}, ann.comments or {}, ann.lost or {}
		tab.Ann = ann
		tab.PendingNotes = #ann.comments > 0
		if carried and carried.note + carried.rename + carried.lost > 0 then
			tab.Carried = carried
			saveAnn(tab) -- under this version's hash, so the next visit finds it directly
		end

		if #ann.renames > 0 and Analysis then
			local ok, R = pcall(Analysis.Analyze, text)
			if ok then
				local list = {}
				for _,r in ipairs(ann.renames) do
					local sym = R.syms[r.index]
					if sym and sym.name == r.orig then list[#list+1] = {tok = sym.decl, name = r.name} end
				end
				text = Analysis.RenameMany(R, list)
			end
		end
		return text
	end

	-- Appends the saved notes to their lines (call right after the text is in the editor).
	local function applyNotes(tab)
		tab.PendingNotes = false
		if not tab.Ann then return end
		for _,c in ipairs(tab.Ann.comments) do
			local line = codeFrame.Lines[c.line]
			if line and not line:find(NOTE_MARK, 1, true) then
				codeFrame.Lines[c.line] = line..NOTE_MARK..c.text
			end
		end
		codeFrame:ProcessTextChange()
	end

	-- Compares a script with the decompile kept from the last time it was opened here: when it differs,
	-- that one is kept as the previous version (for a diff) and the tab says the script has changed.
	local function trackVisit(tab, raw)
		if not (env.readfile and env.writefile and env.isfile) then return end
		local base = annPath(tab.Script)
		local ok, last = pcall(function() return env.isfile(base..".last.lua") and env.readfile(base..".last.lua") end)
		pcall(env.makefolder, "dex/annotations")
		if ok and last then
			if last ~= raw then
				pcall(env.writefile, base..".prev.lua", last)
				pcall(env.writefile, base..".last.lua", raw)
				tab.Changed = true
			end
		else
			pcall(env.writefile, base..".last.lua", raw)
		end
	end

	local function scriptTab()
		local tab = tabs[activeTab]
		if tab and tab.Kind == "script" and tab.Ann then return tab end
		toast("Open a script first", "warn")
		return nil
	end

	-- Remembers a rename of a local (changing one made before keeps the name the variable started with),
	-- with where its declaration is so that it can follow the variable into a later decompile.
	local function recordRename(tab, R, sym, newName)
		local index
		for i,s in ipairs(R.syms) do
			if s == sym then index = i break end
		end
		if not index then return end
		for i,r in ipairs(tab.Ann.renames) do
			if r.index == index then
				if newName == r.orig then table.remove(tab.Ann.renames, i) else r.name = newName end
				return
			end
		end
		local line = Analysis.TokenPos(R, sym.decl)
		local slot = 0
		for _,s in ipairs(R.syms) do
			if s.decl and R.tl[s.decl] == line then
				slot = slot + 1
				if s == sym then break end
			end
		end
		tab.Ann.renames[#tab.Ann.renames+1] = {index = index, orig = sym.name, name = newName, a = Analysis.Anchor(rawLines(tab), line - (tab.Offset or 0)), slot = slot}
	end

	local function setNote(line, text)
		local tab = scriptTab()
		if not tab or not codeFrame.Lines[line] then return end

		codeFrame.Lines[line] = codeFrame.Lines[line]:gsub("%s%-%-%s>>%s.*$", "")
		local kept = {}
		for _,c in ipairs(tab.Ann.comments) do
			if c.line ~= line then kept[#kept+1] = c end
		end
		if text ~= "" then
			kept[#kept+1] = {line = line, text = text}
			codeFrame.Lines[line] = codeFrame.Lines[line]..NOTE_MARK..text
		end
		tab.Ann.comments = kept
		codeFrame:ProcessTextChange()
		saveAnn(tab)
		marksChanged()
	end

	-- The note already on a line, for editing.
	local function noteOn(line)
		local text = codeFrame.Lines[line]
		return text and text:match("%s%-%-%s>>%s(.*)$") or ""
	end

	local function commitRename(newName)
		local t = renameTarget
		renameTarget = nil
		local tab = scriptTab()
		if not t or not tab then return end

		local ok, reason = Analysis.CanRename(t.R, t.Tok, newName)
		if not ok then toast("Can't rename: "..reason, "warn") return end

		-- patch the lines in place, right to left so earlier columns stay valid
		local R = t.R
		local toks = Analysis.References(R, t.Tok)
		for i = #toks, 1, -1 do
			local line, col = Analysis.TokenPos(R, toks[i])
			local text = codeFrame.Lines[line]
			if text then
				codeFrame.Lines[line] = text:sub(1, col)..newName..text:sub(col + #R.tv[toks[i]] + 1)
			end
		end
		codeFrame:ProcessTextChange()

		recordRename(tab, R, t.Sym, newName)
		saveAnn(tab)
		refreshFlow() -- the boxes show the old name
		refreshSidebar()
		toast(("Renamed %s to %s"):format(t.Sym.name, newName))
	end

	-- The navigator is the first column, with a divider to drag. In the code column the tabs, the find
	-- bar and the editor stack from the top. Beside it the graph pane takes flowRatio of the width the
	-- navigator leaves, with a divider between. The toolbar runs above all of it and the status bar below.
	relayout = function()
		local top = 0
		tabStrip.Visible = #tabs > 0
		Nav.tabList.Visible = #tabs > 0
		if tabStrip.Visible then
			tabStrip.Position = UDim2.new(0,0,0,top)
			Nav.tabList.Position = UDim2.new(1,-22,0,top)
			top = top + TAB_H
		end
		Nav.findBar.Visible = Nav.findOpen
		if Nav.findOpen then
			Nav.findBar.Position = UDim2.new(0,0,0,top)
			top = top + FIND_H
		end
		codeFrame.Frame.Position = UDim2.new(0,0,0,top)
		codeFrame.Frame.Size = UDim2.new(1,0,1,-top)
		Nav.hint.Visible = #tabs == 0 -- how to open a script, while none is open

		local left = sideOpen and (Nav.W + SPLIT_W) or 0 -- where the code column starts
		local r = flowOpen and flowRatio or 0
		local bodyH = -(TOOL_H + STATUS_H) -- between the toolbar and the status bar

		Nav.sideFrame.Position = UDim2.new(0,0,0,TOOL_H)
		Nav.sideFrame.Size = UDim2.new(0,Nav.W,1,bodyH)
		Nav.sideDivider.Visible = sideOpen
		Nav.sideDivider.Position = UDim2.new(0,Nav.W,0,TOOL_H)
		Nav.sideDivider.Size = UDim2.new(0,SPLIT_W,1,bodyH)
		Nav.leftCol.Position = UDim2.new(0,left,0,TOOL_H)
		Nav.leftCol.Size = UDim2.new(1 - r,-math.ceil(left * (1 - r)),1,bodyH)
		Nav.flowPane.Visible, Nav.flowDivider.Visible = flowOpen, flowOpen
		Nav.flowDivider.Position = UDim2.new(1 - r,math.floor(left * r),0,TOOL_H)
		Nav.flowDivider.Size = UDim2.new(0,SPLIT_W,1,bodyH)
		Nav.flowPane.Position = UDim2.new(1 - r,math.floor(left * r) + SPLIT_W,0,TOOL_H)
		Nav.flowPane.Size = UDim2.new(r,-math.floor(left * r) - SPLIT_W,1,bodyH)
		refreshToolbar()
	end

	local function showMatch()
		local m = Nav.matches[Nav.matchIdx]
		if not m then return end
		local line, col, len = m[1], m[2], m[3]
		codeFrame.SelectionRange = {{col, line - 1}, {col + len, line - 1}}
		codeFrame.CursorX, codeFrame.CursorY = col, line - 1 -- at the start, so a longer search keeps this match
		codeFrame:UpdateCursor()
		scrollToLine(line, false)
		codeFrame:Refresh()
	end

	local function recomputeFind(jump)
		Nav.matches, Nav.matchIdx = {}, 0
		Nav.findWhy = nil
		local needle = Nav.findBox:GetText()

		if Nav.findMode == "find" and needle ~= "" and Analysis then
			-- the search the Game pages use: plain text, a whole word or a Lua pattern (Nav.findKind)
			local lines = codeFrame.Lines
			local found, why = Analysis.SearchText(table.concat(lines, "\n"), needle, Nav.findKind or "text", Nav.findCase, MAX_MATCHES)
			if not found then
				Nav.findCount.Text = "invalid"
				Nav.findWhy = why
				refreshMarkers()
				return
			end
			for i,m in ipairs(found) do
				Nav.matches[i] = {m.line, m.col, math.min(m.len, math.max(1, #(lines[m.line] or "") - m.col)), m.text}
			end

			if #Nav.matches > 0 then
				Nav.matchIdx = 1
				local cy, cx = codeFrame.CursorY + 1, codeFrame.CursorX
				for i,m in ipairs(Nav.matches) do
					if m[1] > cy or (m[1] == cy and m[2] >= cx) then Nav.matchIdx = i break end
				end
				if jump then showMatch() end
			end
			Nav.findCount.Text = #Nav.matches > 0 and (Nav.matchIdx.."/"..#Nav.matches..(#Nav.matches >= MAX_MATCHES and "+" or "")) or "none"
		else
			Nav.findCount.Text = ""
		end
		refreshMarkers()
	end

	local function stepMatch(dir)
		if #Nav.matches == 0 then recomputeFind(true) return end
		Nav.matchIdx = (Nav.matchIdx - 1 + dir) % #Nav.matches + 1
		Nav.findCount.Text = Nav.matchIdx.."/"..#Nav.matches..(#Nav.matches >= MAX_MATCHES and "+" or "")
		showMatch()
	end

	-- Opens the bar above the code to find text, or for a line number or a new name. quiet is for
	-- a search that comes back by itself: it takes neither the keyboard nor the cursor.
	local function openBar(mode, prefill, quiet)
		-- a rename or a line number borrows the bar from a search, which comes back after it
		if Nav.findOpen and Nav.findMode == "find" and mode ~= "find" then Nav.findKeep = Nav.findBox:GetText() end
		Nav.findQuiet = quiet and os.clock() or nil
		Nav.findOpen, Nav.findMode = true, mode
		Nav.findLabel.Text = ({find = "Find", line = "Line", rename = "Rename"})[mode]
		Nav.findCount.Text = ""
		Nav.matches, Nav.matchIdx = {}, 0
		for _,b in ipairs(navButtons) do b.Visible = mode == "find" end
		Nav.findBox:SetText(prefill or "")
		relayout()
		if quiet then
			Nav.findBox.TextBox:ReleaseFocus()
			recomputeFind(false)
			return
		end
		task.defer(function()
			Nav.findBox.TextBox:CaptureFocus()
			local len = #Nav.findBox:GetText()
			if len > 0 then
				Nav.findBox.TextBox.SelectionStart = 1
				Nav.findBox.TextBox.CursorPosition = len + 1
			end
		end)
	end

	local function closeBar()
		if not Nav.findOpen then return end
		local keep = Nav.findMode ~= "find" and Nav.findKeep
		Nav.findKeep = nil
		if keep and keep ~= "" then
			openBar("find", keep, true) -- back to the search the bar was borrowed from
			return
		end
		Nav.findOpen = false
		Nav.matches, Nav.matchIdx = {}, 0
		Nav.findBox.TextBox:ReleaseFocus()
		relayout()
		refreshMarkers()
	end

	-- Every match of the find in this script as a list in the navigator.
	Nav.listMatches = function()
		local tab = tabs[activeTab]
		if not tab or #Nav.matches == 0 then toast("Nothing found to list", "warn") return end
		local list, needle = table.clone(Nav.matches), Nav.findBox:GetText()
		Nav.showRefs(('"%s" in %s (%d%s)'):format(#needle > 20 and (needle:sub(1, 18).."..") or needle, tab.Name, #list, #list >= MAX_MATCHES and "+" or ""), function()
			eachRow(list, 0, function(n, _, m)
				addNavRow(n, m[4] or "", function() Nav.go(tab, m[1], m[2]) end, ":"..m[1])
			end, 1000)
		end)
	end

	local function openFind()
		local selected = codeFrame:IsValidRange() and codeFrame:GetSelectionText() or ""
		if selected == "" or selected:find("\n") or #selected > 100 then
			selected = (Nav.findOpen and Nav.findMode == "find") and Nav.findBox:GetText() or ""
		end
		openBar("find", selected)
	end

	local function submitBar()
		local text = Nav.findBox:GetText()
		if Nav.findMode == "find" then
			stepMatch(1)
			task.defer(function() Nav.findBox.TextBox:CaptureFocus() end) -- keep stepping with Enter
		elseif Nav.findMode == "line" then
			local n = tonumber(text:match("%d+"))
			if n then jumpTo(math.clamp(n, 1, #codeFrame.Lines), 0) end
			closeBar()
		elseif Nav.findMode == "rename" then
			commitRename(text)
			closeBar()
		end
	end

	----------------------------------------------------------------------------------------------
	-- Symbols at the cursor
	----------------------------------------------------------------------------------------------

	-- The token a selection covers when it sits on one line inside one token (blanks after it are fine),
	-- else the one under the cursor. nil when there is none.
	local function targetToken(R)
		if codeFrame:IsValidRange() then
			local from, to = codeFrame.SelectionRange[1], codeFrame.SelectionRange[2]
			if from[2] ~= to[2] then return nil end
			local line = from[2] + 1
			local ti = Analysis.TokenAt(R, line, from[1])
			if not ti or R.tl[ti] ~= line or R.tel[ti] ~= line then return nil end
			local after = R.te[ti] - Analysis.LineStart(R, line) + 1 -- the column after the token
			if to[1] <= after or (codeFrame.Lines[line] or ""):sub(after + 1, to[1]):match("^%s*$") then return ti end
			return nil
		end
		return Analysis.TokenAt(R, cursorLine(), codeFrame.CursorX)
	end

	-- Analysis plus the name the selection or the cursor is on, or nil with a message.
	local function atCursor()
		local R, why = analyze()
		if not R then toast(why, "warn") return nil end
		local ti = targetToken(R)
		if not ti or R.tt[ti] ~= "name" then toast("Put the cursor on a name", "warn") return nil end
		return R, ti
	end

	local function gotoDefinition()
		local R, ti = atCursor()
		if not R then return end
		if Tools.gotoModuleMember(R, ti) then return end -- fn of M.fn, M being a required module: its function in that module
		local def = Analysis.Definition(R, ti)
		if not def then toast("No definition for "..R.tv[ti].." in this script", "warn") return end
		local line, col = Analysis.TokenPos(R, def)
		jumpTo(line, col)
	end

	-- Where a name is used, each use marked W (assigned: declared, set, += ...) or R (read). With writesOnly
	-- only the writes are listed.
	-- The list goes on the Refs page and stays there while its rows are followed, into other scripts too.
	Nav.refsOf = function(R, ti, tab, writesOnly)
		local all, exact = Analysis.Accesses(R, ti)
		local list, writes = {}, 0
		for _,a in ipairs(all) do
			if a.write then writes = writes + 1 end
			if a.write or not writesOnly then list[#list+1] = a end
		end
		local title = writesOnly and ("Writes to %s in %s (%d%s)"):format(R.tv[ti], tab.Name, #list, exact and "" or ", by name") or ("Uses of %s in %s (%d, %d writes%s)"):format(R.tv[ti], tab.Name, #list, writes, exact and "" or ", by name")
		Nav.showRefs(title, function(page)
			Tools.action(1, writesOnly and "Show every use" or "Show only the writes", function() Nav.refsOf(R, ti, tab, not writesOnly) end)
			local last = eachRow(list, 1, function(n, _, a)
				local line, col = Analysis.TokenPos(R, a.tok)
				local row = addNavRow(n, (a.write and "W  " or "R  ")..Analysis.LineText(R, line):sub(1, 200), function() Nav.go(tab, line, col) end, ":"..line)
				if a.write then row.TextColor3 = Color3.fromRGB(255,190,110) end
			end, 1000)
			Tools.moduleUsers(R, ti, last, page, tab.Script) -- and in the other scripts, for a member of a module
		end)
	end

	local function showReferences(writesOnly)
		local R, ti = atCursor()
		if R then Nav.refsOf(R, ti, tabs[activeTab], writesOnly) end
	end

	local function renameSymbol()
		local R, ti = atCursor()
		if not R then return end
		local sym = R.symAt[ti]
		if not sym or not sym.decl then toast("Only local variables and parameters can be renamed", "warn") return end
		if not scriptTab() then return end
		renameTarget = {R = R, Tok = ti, Sym = sym}
		openBar("rename", sym.name)
	end

	-- A note is typed on its line: a box (Nav.noteBox) opens where the note is, or goes, at the end of the
	-- cursor's line. Typing in the code opens it with what was typed, and so do the menus; Backspace on a
	-- line with a note opens it with its last character gone (erase). Enter or a click elsewhere keeps the
	-- note, Escape leaves it as it was, and an emptied note is removed.
	local function addNote(typed, erase)
		local tab = tabs[activeTab]
		if not (tab and tab.Kind == "script" and tab.Ann) then return end
		local line = cursorLine()
		local note = noteOn(line)
		if erase and note == "" then return end
		scrollToLine(line) -- (the cursor's line may have been scrolled out of sight)
		local cellW, cellH = math.ceil(codeFrame.FontSize / 2), codeFrame.FontSize
		local code = (codeFrame.Lines[line] or ""):gsub("%s%-%-%s>>%s.*$", "")
		-- where the note's text starts, kept on screen when the line runs past the edge
		local markW = #NOTE_MARK * cellW
		local x = math.clamp((#code - codeFrame.ViewX) * cellW + markW, markW, math.max(markW, codeFrame.GuiElems.LinesFrame.AbsoluteSize.X - 240))
		local box = Nav.noteBox
		Nav.noteLine, Nav.noteTab = line, tab
		box.Text = erase and note:sub(1, (utf8.offset(note, -1) or #note) - 1) or note..(typed and typed:gsub("%c", "") or "")
		box.Position = UDim2.fromOffset(x, (line - 1 - codeFrame.ViewY) * cellH)
		box.Size = UDim2.new(1, -x, 0, cellH)
		box.Visible = true
		task.defer(function()
			box:CaptureFocus()
			box.CursorPosition = #box.Text + 1
		end)
	end

	----------------------------------------------------------------------------------------------
	-- The pages about the open script: outline, calls, remotes, marks, and the lists asked for
	----------------------------------------------------------------------------------------------

	-- Marks the outline row of the function under the cursor, and brings it into view.
	local function highlightOutline()
		for fn, row in pairs(outlineRows) do
			local info = Nav.rowInfo[row]
			if info then
				info.Lit = fn == followFn
				Nav.paint(row)
				if info.Lit and sideTab == "outline" and #sideStacks.outline == 0 then Nav.reveal(row) end
			end
		end
	end

	rootPages.outline = {Title = "Outline", Chip = "Outline", Tip = "The functions of this script (the one the cursor is in is highlighted) and the modules around it", Build = function(page)
		outlineRows = {}
		local R, why = tabAnalysis()
		if not R then addTextRow(1, why) return end

		local order = 0
		local scr = currentScript()
		if scr and env.getgc and env.hookfunction then
			order = order + 1
			local box = Tools.checkRow(order, "Count the calls of each function", Live.coverageOn(), function()
				Live.toggleCoverage()
				renderEdit()
			end)
			Lib.Tooltip.attach(box, "Counts the calls of the script's running functions (at most 40): the rows here and the call graph then show which ones ever run")
		end

		local outline = Analysis.Outline(R)
		order = order + 1
		Tools.head(order, "Functions", #outline)
		local counted = {} -- {Row, Fn, Base}: rows that show how often the running function was called
		order = eachRow(outline, order, function(n, _, o)
			local base = ("  "):rep(o.depth)..o.name
			local row = addNavRow(n, base, function() jumpTo(o.line1, 0) end, ":"..o.line1)
			outlineRows[o.fn] = row
			if o.fn.parent then counted[#counted+1] = {Row = row, Fn = o.fn, Base = base} end
		end, 1000)
		highlightOutline()

		-- this script and the others
		if scr then
			order = order + 1
			Tools.head(order, "Modules")
			order = order + 1
			Tools.link(order, ("Requires (%d)"):format(#Analysis.Requires(R)), function() Tools.showRequires() end)
			order = order + 1
			Tools.link(order, "Required by", function() Tools.showRequiredBy() end)
			order = order + 1
			Tools.action(order, "Graph of the modules around it", function() Tools.showModules() end)
		end

		-- while calls are being counted: how many each function has had, dim for the ones that never ran
		if Live.coverageOn() then
			local nextAt = 0
			local function paint()
				for _,c in ipairs(counted) do
					local hits = Live.coverageHits(R, c.Fn)
					c.Row.Text = " "..c.Base..(hits and ("   x"..hits) or "")
					c.Row.TextColor3 = hits == 0 and Color3.fromRGB(120,120,120) or WHITE
				end
			end
			paint()
			page.Tick = function()
				if os.clock() < nextAt then return end
				nextAt = os.clock() + 1
				paint()
			end
		end
	end}

	rootPages.calls = {Title = "Calls", Chip = "Calls", Tip = "What calls the function the cursor is in, and what it calls", Build = function()
		local R, why = tabAnalysis()
		if not R then addTextRow(1, why) return end
		local fn = Analysis.FunctionAtLine(R, cursorLine())

		local callers, callees = {}, {}
		for _,c in ipairs(R.calls) do
			for _,target in ipairs(Analysis.CallTargets(R, c) or {}) do
				if target == fn and c.ctxFn ~= fn then callers[#callers+1] = c end
				if c.ctxFn == fn and target ~= fn then callees[#callees+1] = {Call = c, Target = target} end
			end
		end

		editTitle.Text = "Calls: "..Analysis.Signature(R, fn)
		Tools.link(1, "How is this function reached?", function() Tools.showChains(fn) end)
		local order = 2
		Tools.head(order, "Called by", #callers)
		for _,c in ipairs(callers) do
			order = order + 1
			local line = R.tl[c.s]
			addNavRow(order, Analysis.Signature(R, c.ctxFn), function() jumpTo(line, 0) end, ":"..line)
		end
		order = order + 1
		Tools.head(order, "Calls", #callees)
		for _,e in ipairs(callees) do
			order = order + 1
			local line = R.tl[e.Call.s]
			addNavRow(order, Analysis.Signature(R, e.Target), function() jumpTo(line, 0) end, ":"..line)
		end
	end}

	-- Instance for a resolved path (game.X.Y or script.Parent.X), if it exists right now.
	local function resolveInstance(path, scr)
		if not path or not path.root then return nil end
		local obj = path.root == "game" and game or scr
		for _,step in ipairs(path.steps) do
			if not obj then return nil end
			-- what obj.Step gives in the game: a property that holds an instance (Parent, LocalPlayer,
			-- CurrentCamera), else the child of that name
			local ok, value = pcall(function() return obj[step] end)
			obj = ok and typeof(value) == "Instance" and value or obj:FindFirstChild(step)
		end
		return obj
	end

	-- The instance a token of the code stands for (Analysis.PathAt), if it exists right now. The game
	-- itself is left out: there is nothing to select.
	Tools.instanceAt = function(R, ti)
		local path = Analysis.PathAt(R, ti)
		local inst = path and resolveInstance(path, currentScript())
		return inst ~= game and inst or nil
	end

	rootPages.remotes = {Title = "Remotes & APIs", Chip = "Remotes", Tip = "The remote, HTTP and loadstring calls in this script", Count = function()
		-- (counted once per analysis)
		local tab = tabs[activeTab]
		local R = tab and tab.Kind ~= "diff" and tab.Analysis
		if not R then return nil end
		if R.remoteCount == nil then R.remoteCount = #Analysis.Remotes(R) end
		return R.remoteCount
	end, Build = function()
		local REMOTE_KIND = {remote = "[remote]", listen = "[listen]", http = "[http]", dynamic = "[loadstring]"}
		local R, why = tabAnalysis()
		if not R then addTextRow(1, why) return end
		local list = Analysis.Remotes(R)
		local scr = currentScript()

		local function showRemote(r)
			pushEdit(r.method, function()
				addTextRow(1, ("In %s"):format(Analysis.Signature(R, r.fn)))
				addTextRow(2, r.path and ("Path: "..r.path.text) or "Path: (not a plain path)")
				addTextRow(3, ("Args (%d): %s"):format(r.argCount, table.concat(r.args, ", ")))
				addNavRow(4, "Go to the call", function() jumpTo(r.line, 0) end, ":"..r.line)
				local inst = scr and resolveInstance(r.path, scr)
				if inst then Tools.action(5, "Select in Explorer", function() Explorer.SelectObj(inst) end) end
				Tools.action(6, "Flowchart of that function", function() showFlow(r.fn) end)
				if r.kind ~= "listen" then
					Tools.link(7, "How is this reached?", function()
						Tools.showChains(r.fn, {text = ("%s%s"):format(r.method, r.path and (" "..r.path.text) or ""), line = r.line})
					end)
				end
			end)
		end

		editTitle.Text = ("Remotes & APIs (%d)"):format(#list)
		if #list == 0 then addTextRow(1, "No remote, http or loadstring calls found.") end
		eachRow(list, 0, function(n, _, r)
			Tools.link(n, ("%s %s%s  :%d"):format(REMOTE_KIND[r.kind], r.method, r.path and (" "..r.path.text) or "", r.line), function() showRemote(r) end)
		end, 1000)
	end}

	rootPages.marks = {Title = "Notes", Chip = "Marks", Tip = "Your notes in this script, and suggested names for its variables", Count = function()
		local tab = tabs[activeTab]
		if not (tab and tab.Kind == "script" and tab.Ann) then return nil end
		return #tab.Ann.comments
	end, Build = function()
		local tab = tabs[activeTab]
		if not tab or tab.Kind ~= "script" or not tab.Ann then addTextRow(1, "Open a script first.") return end

		local notes = {}
		for _,c in ipairs(tab.Ann.comments) do notes[#notes+1] = c end
		table.sort(notes, function(a, b) return a.line < b.line end)

		Tools.link(1, "Suggest names for the variables", function() Tools.suggestNames() end)
		local order = 2
		Tools.head(order, "Notes", #notes)
		if #notes == 0 then
			order = order + 1
			addTextRow(order, "Click a line of the code and type: the note goes at the end of the line.")
		end
		for _,c in ipairs(notes) do
			order = order + 1
			addNavRow(order, c.text:sub(1, 200), function() jumpTo(c.line, 0) end, ":"..c.line)
		end

		-- what came from an earlier version of the script and has no place in this one
		local lost = tab.Ann and tab.Ann.lost or {}
		if #lost > 0 then
			order = order + 1
			Tools.head(order, "Could not be placed in this version", #lost)
			for _,l in ipairs(lost) do
				order = order + 1
				addTextRow(order, ("%s: %s"):format(l.kind, l.text:sub(1, 200)))
			end
			order = order + 1
			Tools.action(order, "Forget these", function()
				tab.Ann.lost = {}
				saveAnn(tab)
				renderEdit()
			end, true)
		end
	end}

	-- The lists that were asked for stack up on this page (Nav.showRefs); this is what it says with none.
	rootPages.refs = {Title = "Lists you asked for", Chip = "Refs", Tip = "The lists you asked for: uses of a name, the matches of a find, how a function is reached, who requires a script. They stay while you follow them", Count = function() return #sideStacks.refs end, Build = function()
		addTextRow(1, "Lists you ask for come here and stay while you follow their rows, into other scripts too:")
		addTextRow(2, "- the uses of a name: right-click it")
		addTextRow(3, "- every match of a find: the List button of the find bar")
		addTextRow(4, "- how a function is reached, what a script requires and what requires it")
		addTextRow(5, "Back returns to the list before this one (five are kept).")
	end}

	----------------------------------------------------------------------------------------------
	-- The graph pane: a function's flowchart, the script's call graph, the modules around it
	----------------------------------------------------------------------------------------------

	local function functionEntries(R)
		local list = {}
		for _,o in ipairs(Analysis.Outline(R)) do
			list[#list+1] = {label = ("  "):rep(o.depth)..o.name.."  :"..o.line1, fn = o.fn}
		end
		return list
	end

	-- Clicking a box jumps to its code and shades its lines.
	local function flowSelect(node)
		if not node.line1 then return end
		flowRange = {Tab = tabs[activeTab], From = node.line1, To = node.line2}
		lastSyncLine = node.line1
		-- the cursor is about to move into that code, so the pane already shows what it should
		if flowR then setFollow(flowR, Analysis.FunctionAtLine(flowR, node.line1)) end
		record() -- Back returns to where the cursor was
		showLine(node.line1, 0)
		refreshDecor()
		highlightOutline()
		refreshSidebar()
	end

	local function flowOptions(R, title, viewKey)
		return {
			Title = title,
			ViewKey = viewKey,
			Functions = function() return functionEntries(R) end,
			OnSelect = flowSelect,
			OnOpenFunction = function(f) showFlow(f) end,
			OnPickFunction = function(entry) showFlow(entry.fn) end,
		}
	end

	-- Redraws the pane for the active tab: the flowchart of fn (the function under the cursor by
	-- default), the script's call graph or the modules around it, as flowMode says.
	refreshFlow = function(fn)
		if not flowOpen or not Flowchart then return end
		Flowchart.SetMode(flowMode) -- the pane's switch shows which of the three it is

		local R, why = tabAnalysis()
		if not R then
			flowR, flowFn = nil, nil
			Flowchart.Clear(tabs[activeTab] and why or "Open a script to see its flowchart.")
			return
		end

		local line = cursorLine()
		local cursorFn = Analysis.FunctionAtLine(R, line)
		local ok, G, title, viewKey
		if flowMode == "calls" then
			ok, G = pcall(Analysis.CallGraph, R)
			if ok and Live.coverageOn() then Tools.countCalls(R, G) end
			title, fn, viewKey = "Call graph", nil, R
		elseif flowMode == "modules" then
			ok, G = pcall(Tools.moduleGraph, R)
			R.moduleView = R.moduleView or {}
			local scr = currentScript()
			title, fn, viewKey = "Modules around "..(scr and scr.Name or "this script"), nil, R.moduleView
		else
			-- a function from an older analysis (the text has changed since) isn't part of this one
			if not fn or not table.find(R.functions, fn) then fn = cursorFn end
			ok, G = pcall(Analysis.BuildFlow, R, fn)
			title, viewKey = Analysis.Signature(R, fn), fn
		end
		if not ok then
			flowR, flowFn = nil, nil
			Flowchart.Clear("Could not build the graph: "..tostring(G))
			return
		end

		flowR, flowFn, lastSyncLine = R, fn, line
		setFollow(R, cursorFn)
		local options = flowOptions(R, title, viewKey)
		if flowMode == "modules" then
			-- a box is a script: clicking it opens it
			options.OnSelect = function(node)
				if node.script and node.script ~= currentScript() then ScriptViewer.ViewScript(node.script) end
			end
		end
		local drawn, err = pcall(Flowchart.Show, G, options)
		if not drawn then
			flowR, flowFn = nil, nil
			Flowchart.Clear("Could not draw the graph: "..tostring(err))
			return
		end
		if G.mode == "flow" then
			local node = Analysis.NodeAtLine(G, line)
			Flowchart.Highlight(node and node.id, true)
		end
	end

	-- A few times a second, once the cursor has moved to another line: the function it is in is worked
	-- out (for the status bar, the outline and the calls tab), the flowchart pane switches to it if it
	-- isn't showing it, and the box under the cursor is selected.
	local function followCursor()
		local line = cursorLine()
		if line == lastSyncLine then return end
		lastSyncLine = line

		local R = tabAnalysis()
		if not R then return end
		if flowOpen and flowR and R ~= flowR then refreshFlow() end -- the text changed since the pane was drawn

		local fn = Analysis.FunctionAtLine(R, line)
		if fn ~= followFn then
			setFollow(R, fn)
			highlightOutline()
			refreshSidebar()
			if flowOpen and flowMode == "flow" and flowR == R and fn ~= flowFn then refreshFlow(fn) end
		end

		local G = flowOpen and flowMode == "flow" and flowR == R and Flowchart.GetGraph()
		if G then
			local node = Analysis.NodeAtLine(G, line)
			Flowchart.Highlight(node and node.id, true)
		end
	end

	setFlowOpen = function(on, quiet)
		if on == flowOpen then return end
		if on and not Flowchart then toast("The flowchart module is not loaded", "warn") return end
		flowOpen = on
		relayout()
		if on and not quiet then refreshFlow() end
	end

	-- Explicit requests open the pane if it was hidden. fn is the function to chart.
	showFlow = function(fn)
		if not Flowchart then toast("The flowchart module is not loaded", "warn") return end
		flowMode = "flow"
		setFlowOpen(true, true)
		refreshFlow(fn)
		window:Show()
	end

	showCallGraph = function()
		if not Flowchart then toast("The flowchart module is not loaded", "warn") return end
		flowMode = "calls"
		setFlowOpen(true, true)
		refreshFlow()
		window:Show()
	end

	----------------------------------------------------------------------------------------------
	-- Decompilers, diffs, snapshots
	----------------------------------------------------------------------------------------------

	-- Decompiles a script (with a specific decompiler, or the configured one) and returns the text for
	-- the viewer (with its header), whether it worked, and the raw decompiler output. With known (a
	-- decompile there already is, see Tools.textOf) nothing is decompiled: it only gets the header.
	local function decompileScript(scr, decompiler, known)
		local oldtick = tick()
		local s,source,why = true,known,nil
		if not known then s,source,why = pcall(decompiler or env.decompile or function() end,scr) end

		if not s or type(source) ~= "string" then
			local text = "-- Unable to view source.\n"

			if Settings.ScriptViewer.ShowMoreInfo then
				text = text .. "-- Script Path: "..getPath(scr).."\n"
				if not env.isViableDecompileScript(scr) then
					text = text .. "-- Reason: The script is not running on client. (attempt to decompile ServerScript or 'Script' with RunContext Server)\n"
				elseif not env.isdecompile() then
					text = text .. "-- Reason: Your executor does not support decompiler. (missing 'decompile' function and 'getscriptbytecode' function as fallback)\n"
				else
					-- what the decompiler said (a fallback returns nil and why), or the error it raised
					local reason = (s and why) or (not s and source) or nil
					text = text .. "-- Reason: "..(reason and tostring(reason):gsub("%s+", " "):sub(1, 300) or "Unknown Error.").."\n"
				end
				text = text .. "-- Executor: "..executorName.." ("..executorVersion..")"
			end
			return text, false
		end

		local text = "-- Script Path: "..getPath(scr).."\n"

		if Settings.ScriptViewer.ShowMoreInfo then
			if known then
				text = text .. "-- From the decompile cache (Decompiler > Decompile with... makes a new one).\n"
			else
				text = text .. "-- Took "..tostring(math.floor( (tick() - oldtick) * 100) / 100).."s to decompile.\n"
			end
			text = text .. "-- Executor: "..executorName.." ("..executorVersion..")\n\n"
		end

		return text .. source, true, source
	end

	local function decompilerNames()
		local names = {}
		for name in pairs(env.decompilers or {}) do names[#names+1] = name end
		table.sort(names)
		return names
	end

	-- Puts decompiled text into a tab (and into the editor if it is the active tab).
	local function fillTab(tab, text, ok, raw, decompiler, track)
		tab.Loading = false
		tab.Failed = not ok
		tab.Raw = raw
		tab.RawLines = nil
		tab.Decompiler = decompiler
		tab.Analysis = nil
		tab.Ann, tab.AnnFile = nil, nil
		if ok then
			local patched = attachAnnotations(tab, text, raw)
			text = patched
			if track then trackVisit(tab, raw) end
		end
		tab.Text = text

		local c = tab.Carried
		if c then
			toast(("The script has changed since you annotated it: %d notes and %d renames carried over%s"):format(c.note, c.rename, c.lost > 0 and (", "..c.lost.." could not be placed (see the Marks tab)") or ""), c.lost > 0 and "warn" or "info")
		end
		if tab.Changed and track then
			toast("The script has changed since you last opened it. Decompiler > Diff against the previous version shows how")
		end

		local idx = table.find(tabs, tab)
		if idx and idx == activeTab then -- idx is nil if the tab was closed while it decompiled
			codeFrame:SetText(text)
			if tab.PendingNotes then applyNotes(tab) end
			refreshDecor()
			updateStatus()
			-- analyzing a big script takes a moment: let the source show first
			task.delay(0.05, function()
				if tabs[activeTab] == tab then
					refreshFlow()
					marksVersion = marksVersion + 1 -- the saved notes were just loaded
					refreshSidebar(true)
				end
			end)
		end
	end

	local function redecompile(name)
		local tab = tabs[activeTab]
		if not tab or tab.Kind ~= "script" then return end
		toast("Decompiling with "..name.."...")
		local text, ok, raw = decompileScript(tab.Script, env.decompilers[name])
		if not ok then toast(name.." could not decompile this script", "warn") return end
		fillTab(tab, text, ok, raw, name)
		toast("Decompiled with "..name)
	end

	----------------------------------------------------------------------------------------------
	-- Tabs
	----------------------------------------------------------------------------------------------

	local function saveTabState()
		local tab = tabs[activeTab]
		if not tab then return end
		if tab.Kind ~= "diff" and not tab.Loading then tab.Text = codeFrame:GetText() end
		tab.ViewY, tab.CursorX, tab.CursorY = codeFrame.ViewY, codeFrame.CursorX, codeFrame.CursorY
	end

	activateTab = function(i)
		if i == activeTab or not tabs[i] then return end
		saveTabState()
		activeTab = i
		local tab = tabs[i]

		-- an analysis takes some fifty times the room of its script: the three tabs used last keep theirs,
		-- the others are analysed again when they are next shown
		tab.Used = os.clock()
		local byUse = table.clone(tabs)
		table.sort(byUse, function(a, b) return (a.Used or 0) > (b.Used or 0) end)
		for n = 4, #byUse do
			byUse[n].Analysis, byUse[n].AnText, byUse[n].AnState = nil, nil, nil
		end

		setFollow(nil, nil) -- worked out again for this script a moment later
		lastSyncLine = nil
		resetSidebarPages()
		-- the navigator was on the Game pages only because no script was open: back to the script's pages
		if Nav.auto then
			Nav.auto = false
			sideTab = Nav.home or "outline"
			Nav.paintTabs()
		end
		codeFrame:SetText(tab.Text)
		if tab.PendingNotes then applyNotes(tab) end

		codeFrame.ScrollV:ScrollTo(tab.ViewY or 0)
		codeFrame.CursorX, codeFrame.CursorY = tab.CursorX or 0, tab.CursorY or 0
		codeFrame:UpdateCursor()

		renderTabs()
		relayout()
		refreshDecor()
		refreshFlow()
		refreshSidebar(true)
		updateStatus()
		Live.hideCard()
		Live.draw()
		if Nav.findOpen and Nav.findMode == "find" then recomputeFind(false) end
	end

	local function closeTab(i)
		local tab = tabs[i]
		if not tab then return end

		table.remove(tabs, i)
		-- a script's tab can be opened again from the list at the end of the tab strip
		if tab.Kind == "script" and tab.Script then
			for n = #Nav.closed, 1, -1 do
				if Nav.closed[n].Script == tab.Script then table.remove(Nav.closed, n) end
			end
			table.insert(Nav.closed, 1, {Script = tab.Script, Name = tab.Name, Path = tab.Path})
			while #Nav.closed > 10 do table.remove(Nav.closed) end
		end
		if i == activeTab then
			activeTab = nil
			if #tabs > 0 then
				activateTab(math.min(i, #tabs))
			else
				setFollow(nil, nil)
				lastSyncLine = nil
				codeFrame:SetText("")
				resetSidebarPages()
				-- nothing is open: the Game pages are where a script is found
				if Nav.scopeOf[sideTab] == "script" and sideTab ~= "refs" then
					Nav.home, sideTab, Nav.auto = sideTab, "search", true
					Nav.paintTabs()
				end
				refreshDecor()
				refreshFlow()
				refreshSidebar(true)
				updateStatus()
				Live.hideCard()
				Live.draw()
			end
		elseif activeTab and i < activeTab then
			activeTab = activeTab - 1
		end
		renderTabs()
		relayout()
	end

	local function closeTabObject(tab)
		local idx = table.find(tabs, tab)
		if idx then closeTab(idx) end
	end

	local function tabWidth(text)
		local ok, size = pcall(function()
			return service.TextService:GetTextSize(text, 14, Enum.Font.SourceSans, Vector2.new(1000, 20))
		end)
		return math.min(180, (ok and size.X or #text * 7) + 32)
	end

	-- Right-click on a tab
	local tabMenu
	local function showTabMenu(tab)
		tabMenu = tabMenu or Lib.ContextMenu.new()
		tabMenu.Iconless = true
		tabMenu.Width = 190
		tabMenu:Clear()

		local isScript = tab.Kind == "script"
		tabMenu:Add({Name = "Close", OnClick = function() closeTabObject(tab) end})
		tabMenu:Add({Name = "Close other tabs", Disabled = #tabs < 2, Reason = "This is the only tab", OnClick = function()
			for i = #tabs, 1, -1 do
				if tabs[i] ~= tab then closeTab(i) end
			end
			local idx = table.find(tabs, tab)
			if idx then activateTab(idx) end
		end})
		tabMenu:Add({Name = "Close all tabs", OnClick = function()
			for i = #tabs, 1, -1 do closeTab(i) end
		end})
		tabMenu:AddDivider()
		tabMenu:Add({Name = "Copy script path", Disabled = not isScript or env.setclipboard == nil, Reason = isScript and "Your executor has no setclipboard" or "A diff has no script", OnClick = function()
			env.setclipboard(tab.Path or getPath(tab.Script))
			toast("Copied the script's path")
		end})
		tabMenu:Add({Name = "Select in Explorer", Disabled = not isScript, Reason = "A diff has no script", OnClick = function()
			Explorer.SelectObj(tab.Script)
		end})
		tabMenu:Show()
	end

	-- What a tab is called on the strip: its script's name, with the parent's in front when another open
	-- tab has the same name (games are full of scripts called Client or Main).
	Nav.tabLabel = function(tab)
		if tab.Kind == "script" then
			for _,other in ipairs(tabs) do
				if other ~= tab and other.Kind == "script" and other.Name == tab.Name then
					local ok, parent = pcall(function() return tab.Script.Parent end)
					return (ok and parent) and (parent.Name.."/"..tab.Name) or tab.Name
				end
			end
		end
		return tab.Short or tab.Name
	end

	-- Shows another tab (a click on it): Back returns to the one that was showing.
	Nav.switchTab = function(idx)
		if tabs[idx] and idx ~= activeTab then
			record()
			activateTab(idx)
		end
	end

	-- The list at the end of the tab strip: every open tab with where its script is, then the tabs
	-- closed lately, which a click opens again.
	Nav.showTabList = function(button)
		tabMenu = tabMenu or Lib.ContextMenu.new()
		tabMenu.Iconless = true
		tabMenu.Width = 440
		tabMenu.MaxHeight = 420
		tabMenu:Clear()
		for i,tab in ipairs(tabs) do
			local where = tab.Kind == "script" and (tab.Path or "") or (tab.Kind == "diff" and tab.Name or "captured code")
			tabMenu:Add({Name = ("%s%s    %s"):format(i == activeTab and "> " or "", Nav.tabLabel(tab), where), OnClick = function()
				Nav.switchTab(table.find(tabs, tab))
			end})
		end
		if #Nav.closed > 0 then
			tabMenu:AddDivider("Closed lately")
			for _,c in ipairs(Nav.closed) do
				tabMenu:Add({Name = ("%s    %s"):format(c.Name, c.Path or ""), OnClick = function() ScriptViewer.ViewScript(c.Script) end})
			end
		end
		tabMenu:Show(math.max(0, button.AbsolutePosition.X + button.AbsoluteSize.X - 440), button.AbsolutePosition.Y + button.AbsoluteSize.Y)
	end

	Nav.reopenTab = function()
		local last = Nav.closed[1]
		if not last then toast("No closed tab to open again") return end
		ScriptViewer.ViewScript(last.Script)
	end

	local tabButtons = {}

	renderTabs = function()
		for _,child in ipairs(tabStrip:GetChildren()) do
			if not child:IsA("UIListLayout") then child:Destroy() end
		end
		tabButtons = {}

		for i,tab in ipairs(tabs) do
			local active = i == activeTab
			local color = active and Settings.Theme.ListSelection or Settings.Theme.Button
			local label = (tab.Changed and "* " or "")..Nav.tabLabel(tab)
			local btn = createSimple("TextButton", {
				Name = "Tab",
				LayoutOrder = i,
				AutoButtonColor = false,
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Size = UDim2.new(0, tabWidth(label), 1, 0),
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = WHITE,
				Text = "  "..label,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = tabStrip,
			})
			tabButtons[tab] = btn
			btn.MouseButton1Click:Connect(function()
				Nav.switchTab(table.find(tabs, tab))
			end)
			btn.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton3 then
					closeTabObject(tab)
				elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
					showTabMenu(tab)
				end
			end)
			Lib.Tooltip.attach(btn, function() return (tab.Path or tab.Name)..(tab.Changed and "   (* changed since you last opened it)" or "").."   (right-click for more)" end)

			local close = createSimple("TextButton", {
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Position = UDim2.new(1,-18,0,0),
				Size = UDim2.new(0,18,1,0),
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = Color3.new(0.8,0.8,0.8),
				Text = "x",
				Parent = btn,
			})
			close.MouseButton1Click:Connect(function() closeTabObject(tab) end)
			Lib.Tooltip.attach(close, "Close this tab (middle-click also closes)")
		end

		-- keep the active tab in view; the buttons are laid out a moment later
		task.delay(0.05, function()
			local btn = tabs[activeTab] and tabButtons[tabs[activeTab]]
			if not btn or not btn.Parent then return end
			local view = tabStrip.AbsoluteSize.X
			local left = btn.AbsolutePosition.X - tabStrip.AbsolutePosition.X + tabStrip.CanvasPosition.X
			local right = left + btn.AbsoluteSize.X
			if left < tabStrip.CanvasPosition.X then
				tabStrip.CanvasPosition = Vector2.new(left, 0)
			elseif right > tabStrip.CanvasPosition.X + view then
				tabStrip.CanvasPosition = Vector2.new(right - view, 0)
			end
		end)
	end

	-- Adds a tab, closing the oldest one (never the active tab) when there are too many.
	local function newTab(data)
		local MAX_TABS = 12
		tabs[#tabs+1] = data
		while #tabs > MAX_TABS do
			local victim = activeTab == 1 and 2 or 1
			toast(("Closed %s: the viewer keeps %d tabs"):format(tabs[victim].Name, MAX_TABS))
			closeTab(victim)
		end
		return data
	end

	local function findTab(scr)
		for i,tab in ipairs(tabs) do
			if tab.Kind == "script" and tab.Script == scr then return i end
		end
	end

	-- Diffs match lines up by what they say apart from the names of local variables (two decompiles
	-- never agree on those), unless Tools.ExactDiff is set.
	-- name is the script's (the tab is called "diff: name"), detail what is compared with what.
	local function openDiffTab(name, detail, aText, bText)
		local exact = Tools.ExactDiff
		local text, kinds, stats = Analysis.DiffText(aText, bText, 3, not exact)
		if stats.added == 0 and stats.removed == 0 then
			toast(aText == bText and "The two versions are identical" or "The two versions differ only in the names of local variables")
			return
		end

		local diffKinds = {}
		for i,kind in ipairs(kinds) do
			if kind ~= "same" then diffKinds[i] = kind end
		end

		record()
		local tab = newTab({Name = ("Diff: %s (%s)"):format(name, detail), Short = "diff: "..name, Kind = "diff", Text = text, DiffKinds = diffKinds})
		activateTab(table.find(tabs, tab))
		toast(("%d lines added, %d removed%s"):format(stats.added, stats.removed, exact and "" or " (names of local variables ignored)"))
	end

	local function diffPrevious()
		local tab = tabs[activeTab]
		if not tab or tab.Kind ~= "script" or not tab.Raw then return end
		local path = annPath(tab.Script)..".prev.lua"
		local ok, prev = pcall(function() return env.isfile(path) and env.readfile(path) end)
		if not ok or not prev then toast("No earlier version of this script is kept yet", "warn") return end
		openDiffTab(tab.Name, "previous version vs now", prev, tab.Raw)
	end

	local function diffTab(other)
		local tab = tabs[activeTab]
		if not tab or not tab.Raw or not other.Raw then return end
		openDiffTab(tab.Name, "against "..other.Name, other.Raw, tab.Raw)
	end

	local function diffAgainst(name)
		local tab = tabs[activeTab]
		if not tab or tab.Kind ~= "script" or not tab.Raw then return end
		toast("Decompiling with "..name.."...")
		local _, ok, raw = decompileScript(tab.Script, env.decompilers[name])
		if not ok then toast(name.." could not decompile this script", "warn") return end
		openDiffTab(tab.Name, ("%s vs %s"):format(tab.Decompiler or "default", name), tab.Raw, raw)
	end

	local function saveSnapshot()
		local tab = tabs[activeTab]
		if not tab or tab.Kind ~= "script" or not tab.Raw then return end
		if not env.writefile then toast("Your executor does not support writefile", "warn") return end
		pcall(env.makefolder, "dex/annotations")
		local ok, err = pcall(env.writefile, annPath(tab.Script)..".snap.lua", tab.Raw)
		toast(ok and "Snapshot saved" or ("Could not save: "..tostring(err)), ok and "success" or "error")
	end

	local function diffSnapshot()
		local tab = tabs[activeTab]
		if not tab or tab.Kind ~= "script" or not tab.Raw then return end
		local path = annPath(tab.Script)..".snap.lua"
		local ok, snap = pcall(function() return env.isfile(path) and env.readfile(path) end)
		if not ok or not snap then toast("No snapshot saved for this script (Save snapshot first)", "warn") return end
		openDiffTab(tab.Name, "snapshot vs now", snap, tab.Raw)
	end

	----------------------------------------------------------------------------------------------
	-- Suggested names, call chains, the other scripts of the game, captured code and what hovering says.
	-- All of it hangs off Tools (see there).
	----------------------------------------------------------------------------------------------

	do
		local function fullName(scr)
			local ok, name = pcall(scr.GetFullName, scr)
			return ok and name or tostring(scr)
		end
		Tools.fullName = fullName

		-- A tab of text that is not a script of the game (what a loadstring was given, say): it can be read,
		-- searched and analysed but has no notes or running functions.
		Tools.openChunk = function(name, text)
			record()
			local tab = newTab({Name = name, Short = "code: "..name, Kind = "chunk", Text = text, Raw = text, Path = name})
			activateTab(table.find(tabs, tab))
			window:Show()
		end

		----------------------------------------------------------------------------------------------
		-- Suggested names
		----------------------------------------------------------------------------------------------

		local eventIndex
		-- The parameter names the Roblox API gives an event (InputBegan: input, gameProcessedEvent), when every
		-- class that has an event of that name with at least that many parameters agrees on them.
		local function eventNames(event, count)
			if not eventIndex then
				eventIndex = {}
				for _,cls in pairs(API.Classes) do
					for _,ev in ipairs(cls.Events) do
						local names = {}
						for i,p in ipairs(ev.Parameters) do names[i] = p.Name end
						local list = eventIndex[ev.Name]
						if not list then
							list = {}
							eventIndex[ev.Name] = list
						end
						list[#list+1] = names
					end
				end
			end
			local found
			for _,names in ipairs(eventIndex[event] or {}) do
				if #names >= count then
					if found then
						for i = 1, count do
							if found[i] ~= names[i] then return nil end
						end
					else
						found = names
					end
				end
			end
			return found
		end

		-- Renames every variable in list ({tok, sym, name}, from Analysis.SuggestNames) in the text, and remembers them.
		local function applyNames(R, list)
			local tab = scriptTab()
			if not tab then return end
			local new = {}
			for _,s in ipairs(list) do
				for _,t in ipairs((Analysis.References(R, s.tok))) do new[t] = s.name end
			end
			-- from the end of the text backwards, so the columns of the places still to patch don't move
			local toks = {}
			for t in pairs(new) do toks[#toks+1] = t end
			table.sort(toks, function(a, b) return a > b end)
			for _,t in ipairs(toks) do
				local line, col = Analysis.TokenPos(R, t)
				local text = codeFrame.Lines[line]
				if text then codeFrame.Lines[line] = text:sub(1, col)..new[t]..text:sub(col + #R.tv[t] + 1) end
			end
			codeFrame:ProcessTextChange()
			for _,s in ipairs(list) do recordRename(tab, R, s.sym, s.name) end
			saveAnn(tab)
			refreshFlow()
			sideStacks.marks = {}
			renderEdit()
			toast(("Renamed %d variables"):format(#list), "success")
		end
		Tools.applyNames = applyNames -- (the AI window's apply_names uses it too)

		Tools.suggestNames = function()
			local R, why = tabAnalysis()
			if not R then toast(why, "warn") return end
			if not scriptTab() then return end
			local list = Analysis.SuggestNames(R, eventNames)
			openPage("marks", ("Suggested names (%d)"):format(#list), function()
				if #list == 0 then
					addTextRow(1, "Nothing to suggest: no variable with a made-up name (v12, p3, l_Players_0) is set from something that says what it is.")
					return
				end
				Tools.action(1, ("Apply all %d"):format(#list), function() applyNames(R, list) end)
				eachRow(list, 1, function(n, _, s)
					local line, col = Analysis.TokenPos(R, s.tok)
					addNavRow(n, ("%s -> %s   %s"):format(s.from, s.name, s.why or ""), function() jumpTo(line, col) end, ":"..line)
				end, 1000)
			end)
		end

		----------------------------------------------------------------------------------------------
		-- Call chains
		----------------------------------------------------------------------------------------------

		-- Outlines the functions of the chains in the call graph.
		local function markChains(chains)
			showCallGraph()
			local G = Flowchart and Flowchart.GetGraph()
			if not G or G.mode ~= "calls" then return end
			local ids = {}
			for _,c in ipairs(chains) do
				for _,step in ipairs(c.steps) do
					for _,nd in ipairs(G.nodes) do
						if nd.fn == step.fn then ids[nd.id] = true end
					end
				end
			end
			Flowchart.Mark(ids)
		end

		-- The ways execution gets to fn: from where something starts down to it. last ({text, line}) is a
		-- call in fn that is the point of asking, shown after the last step.
		Tools.showChains = function(fn, last)
			local R = tabAnalysis()
			if not R then return end
			local tab = tabs[activeTab]
			local chains = Analysis.CallChains(R, fn, 20)
			Nav.showRefs(("How %s is reached, in %s"):format(last and last.text or Analysis.Signature(R, fn), tab.Name), function()
				Tools.action(1, "Show these in the call graph", function()
					if tabs[activeTab] == tab then markChains(chains) else toast("Go back to "..tab.Name.." first", "warn") end
				end)
				local order = 1
				for i,c in ipairs(chains) do
					order = order + 1
					addTextRow(order, ("%d. %s"):format(i, c.entry or "Nothing in this script calls it (a module's function, or something called from another script)"))
					for _,step in ipairs(c.steps) do
						order = order + 1
						local at = step.line or step.fn.line1
						-- (the chain's number keeps the same step of two chains apart, for Nav.step)
						addNavRow(order, ("%d. %s%s"):format(i, Analysis.Signature(R, step.fn), step.line and "   calls on" or ""), function() Nav.go(tab, at, 0) end, ":"..at)
					end
					if last then
						order = order + 1
						addNavRow(order, ("%d. %s"):format(i, last.text), function() Nav.go(tab, last.line, 0) end, ":"..last.line)
					end
				end
			end)
		end

		-- Shows how many calls each function of a call graph has had (nodes with a counted running function).
		Tools.countCalls = function(R, G)
			for _,nd in ipairs(G.nodes) do
				if nd.fn and nd.fn.parent then
					local hits = Live.coverageHits(R, nd.fn)
					if hits then
						nd.label = nd.label.."\n"..hits.." calls"
						if hits == 0 then nd.tint = "unused" end
					end
				end
			end
		end

	end

	-- This part is a block of its own: Luau allows 200 live locals in a function and the one before it
	-- leaves no room. What other parts need from here hangs off Tools.
	do
		----------------------------------------------------------------------------------------------
		-- The other scripts of the game: the list, a search through all their decompiles, require,
		-- and what can be told from all of them together (remotes, modules, functions, changes)
		----------------------------------------------------------------------------------------------

		local fullName = Tools.fullName
		local K, D = {}, {} -- constants; the helpers for the files on disk
		local memory = {} -- script -> entry {Text, Hash, D (what Analysis.Digest said, once parsed)}: what has been read (scripts with the same code share one entry)
		local byHash = {} -- getscripthash -> entry, so scripts with the same code are read once
		local hashOf = setmetatable({}, {__mode = "k"}) -- script -> its getscripthash
		local resultOf = {} -- hash (or script) -> its place in results, or false when the query is not in it
		local results, matchTotal = {}, 0
		local state = {Running = false, Cancel = false, Stale = false, Done = 0, Total = 0, Failed = 0, Skipped = 0, Version = 0, Scanned = false,
			Failures = {}, Added = 0, Indexing = false, Retrying = false, Want = false, Gen = 0, IndexDone = 0, IndexTotal = 0}
		local query, mode, matchCase = "", "text", false
		K.MODES = {"text", "word", "pattern", "ident", "string", "call"}
		K.MODE_NAMES = {text = "text", word = "whole word", pattern = "Lua pattern", ident = "a name in the code", string = "a string in the code", call = "a call of a function"}
		K.TOKEN_MODES = {ident = true, string = true, call = true} -- these read the code, not the text: only scripts that have the text somewhere are parsed
		K.CACHE_DIR = "dex/cache"
		K.PER_SCRIPT, K.MAX_MATCHES_ALL, K.MAX_ROWS = 30, 2000, 300
		K.BUDGET, K.WORKERS = 0.006, 3 -- seconds of work before the game gets its frame back; scripts decompiled at once

		-- Scripts that are Roblox's own, or another player's copy of the game's, can be left out of the list, the
		-- search and the palette: they are most of the scripts there are (CoreGui alone has over a thousand
		-- modules) and say nothing about the game. Tools.Skip says which kinds are (a check box for each in the
		-- Scripts tab); all of them are at first.
		K.SKIP_KINDS = {
			{Key = "core", Label = "CoreGui: Roblox's own interface scripts (over a thousand modules)"},
			{Key = "packages", Label = "CorePackages: Roblox's own libraries"},
			{Key = "internal", Label = "RobloxPluginGuiService and RobloxReplicatedStorage"},
			{Key = "chat", Label = "Chat: the default chat scripts"},
			{Key = "playerscripts", Label = "Default player scripts: PlayerModule, RbxCharacterSounds, PlayerScriptsLoader"},
			{Key = "animate", Label = "The default Animate script"},
			{Key = "others", Label = "Other players and their characters"},
			{Key = "copies", Label = "Copies: scripts with the same code as one read already (shown once, \"and N copies\")"},
		}
		Tools.Skip = {}
		for _,kind in ipairs(K.SKIP_KINDS) do Tools.Skip[kind.Key] = true end
		K.SERVICE_KIND = {CoreGui = "core", CorePackages = "packages", RobloxPluginGuiService = "internal", RobloxReplicatedStorage = "internal", Chat = "chat"}
		K.PLAYER_DEFAULTS = {PlayerModule = true, RbxCharacterSounds = true, PlayerScriptsLoader = true}
		local skipKinds = setmetatable({}, {__mode = "k"})

		-- Which kind of script to leave out this is (a Key of K.SKIP_KINDS, "copies" aside), or false. Whether that
		-- kind is left out is up to Tools.Skip.
		local function skipKind(scr)
			local cached = skipKinds[scr]
			if cached ~= nil then return cached end
			local kind = false
			local players = game:GetService("Players")
			local me = players.LocalPlayer
			local node, steps = scr, 0
			while node and steps < 80 do
				local parent = node.Parent
				local class, name = node.ClassName, node.Name
				if parent and parent.ClassName == "DataModel" and K.SERVICE_KIND[class] then
					kind = K.SERVICE_KIND[class]
				elseif K.PLAYER_DEFAULTS[name] and parent and (parent.Name == "PlayerScripts" or parent.Name == "StarterPlayerScripts") then
					kind = "playerscripts"
				elseif node == scr and name == "Animate" and parent and (parent.Name == "StarterCharacterScripts" or (parent.ClassName == "Model" and parent:FindFirstChildOfClass("Humanoid"))) then
					kind = "animate"
				elseif class == "Model" then
					local plr = players:GetPlayerFromCharacter(node)
					if plr and plr ~= me then kind = "others" end
				elseif class == "Player" and node ~= me then
					kind = "others"
				end
				if kind then break end
				node, steps = parent, steps + 1
			end
			skipKinds[scr] = kind
			return kind
		end

		local function skipped(scr)
			local ok, kind = pcall(skipKind, scr)
			return ok and kind and Tools.Skip[kind] and true or false
		end

		local listCache, listTime
		-- Every script the viewer can decompile (client scripts and modules) that is not left out, cached for a few seconds.
		Tools.scriptList = function()
			if listCache and tick() - listTime < 10 then return listCache end
			local source
			if env.getscripts then
				local ok, list = pcall(env.getscripts)
				source = ok and type(list) == "table" and list or nil
			end
			if not source then
				local ok, list = pcall(game.GetDescendants, game)
				source = ok and list or {}
			end
			local out, left = {}, 0
			for _,s in ipairs(source) do
				if typeof(s) == "Instance" and s:IsA("LuaSourceContainer") then
					local okViable, viable = pcall(env.isViableDecompileScript, s)
					if okViable and viable then
						if skipped(s) then left = left + 1 else out[#out+1] = s end
					end
				end
			end
			state.Skipped = left
			listCache, listTime = out, tick()
			return out
		end

		-- The end of a text that is too long for a row (the end of a path says the most). max is the room at
		-- the navigator's usual width: a wider one shows more.
		local function tail(text, max)
			max = math.floor(max * Nav.W / 320)
			return #text > max and ("..."..text:sub(-(max - 3))) or text
		end

		----------------------------------------------------------------------------------------------
		-- The decompile cache on disk. A file is named by the script's hash (getscripthash), so scripts that
		-- are renamed, moved or cloned, and libraries that many games share, are decompiled once.
		----------------------------------------------------------------------------------------------

		function D.cachePath(hash, ext)
			return K.CACHE_DIR.."/"..env.parsefile(hash).."."..ext
		end

		function D.scriptHash(scr)
			if not env.getscripthash then return nil end
			local ok, hash = pcall(env.getscripthash, scr)
			return ok and type(hash) == "string" and hash or nil
		end

		-- The decompile the disk has for a hash, or nil and whether a decompile failed lately (a note of that
		-- is kept for a day, so the same timeouts are not waited for in every session).
		function D.cachedRead(hash)
			if not (hash and env.isfile and env.readfile) then return nil end
			local ok, text, failedEarlier = pcall(function()
				if env.isfile(D.cachePath(hash, "lua")) then return env.readfile(D.cachePath(hash, "lua")) end
				if env.isfile(D.cachePath(hash, "fail")) then
					local at = tonumber(env.readfile(D.cachePath(hash, "fail")))
					if at and os.time() - at < 86400 then return nil, true end
				end
				return nil
			end)
			if not ok then return nil end
			return text, failedEarlier
		end

		function D.cacheWrite(hash, raw)
			if not (hash and env.writefile) then return end
			pcall(env.makefolder, "dex")
			pcall(env.makefolder, K.CACHE_DIR)
			pcall(env.writefile, D.cachePath(hash, "lua"), raw)
			if env.delfile then pcall(env.delfile, D.cachePath(hash, "fail")) end
		end

		function D.cacheFailed(hash)
			if not (hash and env.writefile) then return end
			pcall(env.makefolder, "dex")
			pcall(env.makefolder, K.CACHE_DIR)
			pcall(env.writefile, D.cachePath(hash, "fail"), tostring(os.time()))
		end

		-- The files of the cache that hold decompiles or notes of failures.
		function D.cacheFiles()
			if not env.listfiles then return {} end
			local ok, files = pcall(env.listfiles, K.CACHE_DIR)
			local out = {}
			for _,f in ipairs(ok and type(files) == "table" and files or {}) do
				if not f:match("%.index%.json$") then out[#out+1] = f end
			end
			return out
		end

		Tools.clearCache = function()
			if not (env.listfiles and env.delfile) then toast("Your executor cannot list or delete files", "warn") return end
			local n = 0
			for _,f in ipairs(D.cacheFiles()) do
				if pcall(env.delfile, f) then n = n + 1 end
			end
			state.CacheCount = 0
			state.Version = state.Version + 1
			toast(("Deleted %d files from the decompile cache"):format(n), "success")
		end

		-- Reads a script: from the scripts read already, the disk, or the decompiler. force skips the disk (and a
		-- failure noted there), decompiler is a function to use instead of the default one. Returns the entry, or
		-- nil and why. ponytail: one decompile per hash on disk, whichever decompiler made it; key it by decompiler
		-- too if switching the default decompiler should not reuse the old output.
		local function readScript(scr, force, decompiler)
			local hash = D.scriptHash(scr)
			hashOf[scr] = hash
			if hash and Tools.Skip.copies and byHash[hash] then return byHash[hash] end -- a copy of a script that was read already
			local entry
			if hash and not force then
				local text, failedEarlier = D.cachedRead(hash)
				if text then
					entry = {Text = text}
				elseif failedEarlier then
					return nil, "failed to decompile earlier"
				end
			end
			if not entry then
				local _, ok, raw = decompileScript(scr, decompiler)
				if not ok or not raw then
					D.cacheFailed(hash)
					return nil, "the decompiler gave no source"
				end
				D.cacheWrite(hash, raw)
				entry = {Text = raw}
			end
			entry.Hash = hash
			if hash then byHash[hash] = entry end
			return entry
		end

		-- The decompile there is of a script, without asking the decompiler: what was read in this session,
		-- else what the disk has under its hash. nil when there is none.
		Tools.textOf = function(scr)
			local entry = memory[scr]
			if entry then return entry.Text end
			local hash = D.scriptHash(scr)
			if not hash then return nil end
			if byHash[hash] then return byHash[hash].Text end
			return (D.cachedRead(hash))
		end

		-- OpenDex is being reloaded or closed: the reading, parsing and searching in the background stop
		Tools.unload = function()
			state.Dead, state.Cancel, state.Want = true, true, false
		end

		----------------------------------------------------------------------------------------------
		-- Searching what has been read
		----------------------------------------------------------------------------------------------

		-- The matches of a text in an entry, searched for in one of K.MODES. The token modes parse the scripts
		-- that have the text in them.
		local function searchEntry(entry, text, how, case)
			if not K.TOKEN_MODES[how] then
				return Analysis.SearchText(entry.Text, text, how, case, K.PER_SCRIPT)
			end
			local head = text:match("^%s*([^%(]-)%s*%(") or text
			local needle = how == "call" and head:match("([%w_]+)%s*$") or text
			if not needle then return {} end
			if not (case and entry.Text or entry.Text:lower()):find(case and needle or needle:lower(), 1, true) then return {} end
			local ok, R = pcall(Analysis.Analyze, entry.Text)
			if not ok then return {} end
			return Analysis.SearchTokens(R, text, how, case, K.PER_SCRIPT)
		end

		-- Lists the matches of the query in a script; a script whose code was listed already (a copy) only counts.
		local function matchScript(scr, entry)
			local key = (Tools.Skip.copies and hashOf[scr]) or scr
			local listed = resultOf[key]
			if listed ~= nil then
				if listed and not listed.Seen[scr] then
					listed.Seen[scr] = true
					listed.Copies = listed.Copies + 1
				end
				return
			end
			if matchTotal >= K.MAX_MATCHES_ALL then return end
			local found = searchEntry(entry, query, mode, matchCase)
			if found and #found > 0 then
				matchTotal = matchTotal + #found
				resultOf[key] = {Script = scr, Path = fullName(scr), Matches = found, Copies = 1, Seen = {[scr] = true}}
				results[#results+1] = resultOf[key]
			else
				resultOf[key] = false
			end
		end

		-- The query (or how it is read) changed: the scripts read so far are searched again. Searching the
		-- text is done at once. The searches of the code parse every script that has the word, so they are
		-- done a few milliseconds at a time, and a newer search stops one that is still going.
		local function rematch()
			results, resultOf, matchTotal, state.Error = {}, {}, 0, nil
			state.MatchGen = (state.MatchGen or 0) + 1
			state.Matching = false
			if query == "" then return end
			if mode == "pattern" then
				local ok, why = Analysis.SearchText("", query, mode, matchCase, 1)
				if not ok then
					state.Error = why
					return
				end
			elseif mode == "call" and not (query:match("([%w_]+)%s*%(") or query:match("([%w_]+)%s*$")) then
				state.Error = "Write the name of a function, or name(text in its arguments)"
				return
			end

			local todo = {}
			for scr,entry in pairs(memory) do
				if not skipped(scr) then todo[#todo+1] = {scr, entry} end
			end
			if not K.TOKEN_MODES[mode] then
				for _,item in ipairs(todo) do matchScript(item[1], item[2]) end
				return
			end

			local gen = state.MatchGen
			state.Matching = true
			task.spawn(function()
				local frameStart = os.clock()
				for _,item in ipairs(todo) do
					if gen ~= state.MatchGen or state.Dead then return end
					pcall(matchScript, item[1], item[2])
					state.Version = state.Version + 1
					if os.clock() - frameStart > K.BUDGET then
						task.wait()
						frameStart = os.clock()
					end
				end
				if gen == state.MatchGen then
					state.Matching = false
					state.Version = state.Version + 1
				end
			end)
		end

		----------------------------------------------------------------------------------------------
		-- Reading every script in the background
		----------------------------------------------------------------------------------------------

		function D.indexPath()
			return K.CACHE_DIR.."/place_"..game.PlaceId..".index.json"
		end

		-- What the last session saw (path -> hash), loaded when the first scan starts.
		function D.loadBaseline()
			if state.BaselineLoaded then return end
			state.BaselineLoaded = true
			if not (env.isfile and env.readfile) then return end
			local ok, data = pcall(function()
				if env.isfile(D.indexPath()) then return service.HttpService:JSONDecode(env.readfile(D.indexPath())) end
			end)
			if ok and type(data) == "table" and type(data.scripts) == "table" then
				state.Baseline, state.BaselineTime, state.BaselineSkip = data.scripts, data.time, data.skip
			end
		end

		function D.saveIndex(map)
			if not env.writefile then return end
			pcall(function()
				pcall(env.makefolder, "dex")
				pcall(env.makefolder, K.CACHE_DIR)
				env.writefile(D.indexPath(), service.HttpService:JSONEncode({time = os.time(), skip = Tools.Skip, scripts = map}))
			end)
		end

		-- Deletes the files of the cache that no saved index (this place's or another's) and not the baseline of this
		-- session refers to: the scripts of the last two sessions stay, older ones go.
		function D.prune(current)
			if not (env.listfiles and env.delfile and env.readfile and env.isfile and next(current)) then return end
			task.spawn(function()
				pcall(function()
					local keep = {}
					for _,hash in pairs(current) do keep[env.parsefile(hash)] = true end
					for _,hash in pairs(state.Baseline or {}) do keep[env.parsefile(hash)] = true end
					local files = env.listfiles(K.CACHE_DIR)
					for _,f in ipairs(files) do
						if f:match("%.index%.json$") then
							local ok, data = pcall(function() return service.HttpService:JSONDecode(env.readfile(f)) end)
							if ok and type(data) == "table" and type(data.scripts) == "table" then
								for _,hash in pairs(data.scripts) do keep[env.parsefile(hash)] = true end
							end
						end
					end
					local n = 0
					for _,f in ipairs(files) do
						local base, ext = f:match("([^/\\]+)%.(%w+)$")
						if base and (ext == "lua" or ext == "fail") and not keep[base] then
							pcall(env.delfile, f)
							n = n + 1
							if n % 50 == 0 then task.wait() end
						end
					end
				end)
				state.CacheCount = #D.cacheFiles()
				state.Version = state.Version + 1
			end)
		end

		function D.sameSkips(saved)
			if type(saved) ~= "table" then return false end
			for key,on in pairs(Tools.Skip) do
				if (saved[key] and true or false) ~= on then return false end
			end
			return true
		end

		-- The end of a scan: what the scripts' hashes say has changed since the last session, the index saved for
		-- the next one, the files nobody needs any more.
		function D.afterScan(list, incremental, newlyRead)
			local items = {}
			for _,scr in ipairs(list) do
				local hash = hashOf[scr]
				if hash then items[#items+1] = {path = fullName(scr), hash = hash, scr = scr} end
			end
			local map, keys = Analysis.IndexMap(items)
			state.KeyScript = {}
			for i,key in ipairs(keys) do state.KeyScript[key] = items[i].scr end
			state.Changes, state.ChangesNote = nil, nil
			if state.Baseline then
				if D.sameSkips(state.BaselineSkip) then
					state.Changes = Analysis.ChangeSet(state.Baseline, map)
				else
					state.ChangesNote = "The kinds of script left out were different last time, so the scripts cannot be compared."
				end
			end
			if next(map) then
				D.saveIndex(map)
				D.prune(map)
			end
			state.CacheCount = #D.cacheFiles()

			if not incremental then
				local text = ("%d scripts read"):format(state.Total - state.Failed)
				if state.Failed > 0 then text = text..(", %d could not be decompiled"):format(state.Failed) end
				local c = state.Changes
				if c and (#c.changed + #c.added + #c.removed) > 0 then
					text = text..(". Since last time: %d changed, %d new, %d gone (Scripts tab)"):format(#c.changed, #c.added, #c.removed)
				end
				toast(text, state.Failed > 0 and "warn" or "success")
			end
		end

		-- Reads the scripts that have not been read: a few at a time, giving the game its frame back after
		-- a few milliseconds of work. fresh forgets what was read (and the failures) first.
		Tools.scan = function(fresh)
			if state.Running or state.Dead then return end
			D.loadBaseline()
			local incremental = state.Scanned and not fresh
			state.Running, state.Cancel, state.Scanned = true, false, false
			if fresh then
				memory, byHash, state.Failures = {}, {}, {}
			end
			if not incremental then state.Added = 0 end
			local list = Tools.scriptList()
			local inList = {}
			for _,s in ipairs(list) do inList[s] = true end
			local gone = 0
			for scr in pairs(memory) do
				if not inList[scr] then
					memory[scr] = nil
					gone = gone + 1
				end
			end
			for scr in pairs(state.Failures) do
				if not inList[scr] then state.Failures[scr] = nil end
			end
			state.Total, state.Done, state.Failed = #list, 0, 0

			local nextIndex, active, newlyRead = 1, K.WORKERS, 0
			local frameStart, statusAt = os.clock(), 0
			local function pace()
				state.Version = state.Version + 1
				if os.clock() - frameStart > K.BUDGET then
					if os.clock() > statusAt then
						statusAt = os.clock() + 0.25
						updateStatus()
					end
					task.wait()
					frameStart = os.clock()
				end
			end

			local function readOne(scr)
				if memory[scr] or state.Failures[scr] then return end
				local ok, entry, why = pcall(readScript, scr, false)
				if ok and not entry and fresh and why == "failed to decompile earlier" then
					ok, entry, why = pcall(readScript, scr, true) -- asked to read them again: try the ones that failed lately too
				end
				if ok and entry then
					memory[scr] = entry
					newlyRead = newlyRead + 1
					if query ~= "" and not state.Error then pcall(matchScript, scr, entry) end
				else
					state.Failures[scr] = ok and why or tostring(entry)
				end
			end

			local function finish()
				state.Running = false
				state.Scanned = not state.Cancel
				local failed = 0
				for _ in pairs(state.Failures) do failed = failed + 1 end
				state.Failed = failed
				state.Version = state.Version + 1
				if not state.Cancel then
					if incremental then state.Added = state.Added + newlyRead end
					if gone > 0 then rematch() end
					local ok, err = pcall(D.afterScan, list, incremental, newlyRead)
					if not ok then warn("Script Viewer: "..tostring(err)) end
					Tools.watch()
				end
				updateStatus()
				if state.Stale and not state.Cancel then -- the kinds to leave out changed on the way
					state.Stale = false
					Tools.scan()
				elseif state.Want and not state.Cancel then
					Tools.index()
				end
			end

			local function worker()
				while not state.Cancel do
					local i = nextIndex
					if i > #list then break end
					nextIndex = i + 1
					local ok, err = pcall(readOne, list[i])
					if not ok then state.Failures[list[i]] = tostring(err) end
					state.Done = state.Done + 1
					pace()
				end
				active = active - 1
				if active == 0 then finish() end
			end
			for _ = 1, K.WORKERS do task.spawn(worker) end
		end

		-- Keeps the scripts read up to date: a script that appears or goes is noticed (a couple of seconds after
		-- the last one) and read, or dropped, without reading the rest again.
		Tools.watch = function()
			if state.Watching then return end
			state.Watching = true
			local function changed(d)
				if not d:IsA("LuaSourceContainer") then return end
				local ok, viable = pcall(env.isViableDecompileScript, d)
				if not (ok and viable) or skipped(d) then return end
				state.Gen = state.Gen + 1
				local gen = state.Gen
				task.delay(2, function()
					if gen ~= state.Gen then return end
					listCache = nil
					if state.Running then
						state.Stale = true
					elseif state.Scanned then
						Tools.scan()
					end
				end)
			end
			Main.Track(game.DescendantAdded:Connect(changed)) -- (tracked: a reload of OpenDex disconnects them)
			Main.Track(game.DescendantRemoving:Connect(changed))
		end

		-- Searches every script for text (reading them first if that hasn't been done).
		Tools.search = function(text)
			query = text
			rematch()
			if query ~= "" and not state.Scanned and not state.Running then Tools.scan() end
			state.Version = state.Version + 1
			renderEdit()
		end

		-- A kind of script was ticked or unticked: the list, the search and the palette follow.
		local function skipsChanged()
			listCache = nil
			rematch()
			if state.Running then
				state.Stale = true -- the reading going on uses the old list: it starts again when it is done
			else
				state.Scanned = false
				if query ~= "" or state.Want then Tools.scan() end
			end
			state.Version = state.Version + 1
		end

		-- The Search page with a search for text already run. kind ("text", "word", "pattern") and case are
		-- how the find bar was searching, when it comes from there.
		Tools.openSearch = function(text, kind, case)
			if kind then mode = kind end
			if case ~= nil then matchCase = case end
			sideStacks.search = {}
			selectSideTab("search", true)
			Tools.search(text)
			window:Show()
		end

		-- What the status bar says while the background work goes on.
		Tools.scanStatus = function()
			if state.Running then return ("Reading %d/%d"):format(state.Done, state.Total) end
			if state.Indexing then return ("Parsing %d/%d"):format(state.IndexDone, state.IndexTotal) end
			return ""
		end

		local function countRead()
			local n = 0
			for _ in pairs(memory) do n = n + 1 end
			return n
		end

		-- A page that shows what the background work makes redraws itself as that goes on (not while a text box has the focus).
		local function follow(page, box)
			local shown, lastDraw = state.Version, os.clock()
			page.Tick = function()
				-- drawn again now and then while the work goes on, and once more when it is over
				local busy = state.Running or state.Indexing or state.Retrying or state.Matching
				if state.Version ~= shown and (not busy or os.clock() - lastDraw > 0.75) and not (box and box.TextBox:IsFocused()) then
					renderEdit()
				end
			end
		end

		----------------------------------------------------------------------------------------------
		-- Parsing what has been read: one digest per script
		----------------------------------------------------------------------------------------------

		-- What Analysis.Digest says about an entry (false when the script does not parse at all). Parsed on first use.
		local function digestOf(entry)
			if entry.D == nil then
				local ok, R = pcall(Analysis.Analyze, entry.Text)
				local good, d
				if ok then good, d = pcall(Analysis.Digest, R) end
				entry.D = good and d or false
			end
			return entry.D
		end

		-- Each distinct script read, sorted by path: {Script (the first of the scripts that share the code), Entry,
		-- Path, Copies}.
		Tools.entries = function()
			local count, first = {}, {}
			for scr,entry in pairs(memory) do
				if not skipped(scr) then
					count[entry] = (count[entry] or 0) + 1
					local prev = first[entry]
					if not prev or fullName(scr) < fullName(prev) then first[entry] = scr end
				end
			end
			local out = {}
			for entry,scr in pairs(first) do out[#out+1] = {Script = scr, Entry = entry, Path = fullName(scr), Copies = count[entry]} end
			table.sort(out, function(a, b) return a.Path < b.Path end)
			return out
		end

		-- Parses every script read, in the background; whatever needs the digests calls this first. Starts the
		-- reading too if that has not been done.
		Tools.index = function()
			if state.Dead then return end
			state.Want = true
			if state.Running or not state.Scanned then
				if not state.Running then Tools.scan() end
				return -- the end of the scan comes back here
			end
			if state.Indexing then return end
			local todo = {}
			for _,entry in pairs(memory) do
				if entry.D == nil then todo[#todo+1] = entry end
			end
			if #todo == 0 then
				state.Version = state.Version + 1
				return
			end
			state.Indexing, state.IndexDone, state.IndexTotal = true, 0, #todo
			task.spawn(function()
				local frameStart = os.clock()
				for _,entry in ipairs(todo) do
					if state.Dead then return end
					digestOf(entry)
					state.IndexDone = state.IndexDone + 1
					state.Version = state.Version + 1
					if os.clock() - frameStart > K.BUDGET then
						task.wait()
						frameStart = os.clock()
					end
				end
				state.Indexing = false
				state.Version = state.Version + 1
				updateStatus()
				if state.Want and not state.Running then Tools.index() end -- scripts that came meanwhile
			end)
		end

		-- How many of the scripts read have no digest yet.
		local function unparsed()
			local n = 0
			for _,e in ipairs(Tools.entries()) do
				if e.Entry.D == nil then n = n + 1 end
			end
			return n
		end

		Tools.indexComplete = function()
			return state.Scanned and not state.Running and not state.Indexing and unparsed() == 0
		end

		-- One line about the background work, or nil when everything has been read and parsed.
		local function workNote()
			if state.Running then return ("Reading the scripts: %d of %d"):format(state.Done, state.Total) end
			if state.Indexing then return ("Parsing the scripts: %d of %d"):format(state.IndexDone, state.IndexTotal) end
			if not state.Scanned then return "The scripts have not been read yet" end
			local n = unparsed()
			if n > 0 then return ("%d scripts are not parsed yet"):format(n) end
			return nil
		end

		-- The text of a line (trimmed) of a script's text.
		local function lineOf(text, n)
			local pos = 1
			for _ = 2, n do pos = (text:find("\n", pos, true) or #text) + 1 end
			local stop = text:find("\n", pos, true) or #text + 1
			return Analysis.Trim(text:sub(pos, stop - 1))
		end

		----------------------------------------------------------------------------------------------
		-- require: which scripts a script requires and which require it
		----------------------------------------------------------------------------------------------

		-- The scripts that have been read and require target.
		local function requiredBy(target)
			local out = {}
			for scr,entry in pairs(memory) do
				if scr ~= target and not skipped(scr) and entry.Text:find("require", 1, true) and entry.Text:find(target.Name, 1, true) then
					local d = digestOf(entry)
					for _,req in ipairs(d and d.requires or {}) do
						if req.path.root and resolveInstance(req.path, scr) == target then
							out[#out+1] = {Script = scr, Line = req.line}
							break
						end
					end
				end
			end
			table.sort(out, function(a, b) return fullName(a.Script) < fullName(b.Script) end)
			return out
		end

		-- The scripts a script requires that exist now: {Script, Line}. reqs is a list of {path, line}.
		local function requiresOf(scr, reqs)
			local out = {}
			for _,req in ipairs(reqs) do
				local inst = req.path.root and resolveInstance(req.path, scr)
				if typeof(inst) == "Instance" and inst:IsA("LuaSourceContainer") then out[#out+1] = {Script = inst, Line = req.line} end
			end
			return out
		end

		-- These two are lists that lead into other scripts: they go on the Refs page, which keeps them.
		Tools.showRequires = function()
			local R, why = tabAnalysis()
			local scr = currentScript()
			if not (R and scr) then toast(why or "Open a decompiled script first", "warn") return end
			local tab = tabs[activeTab]
			local list = Analysis.Requires(R)
			Nav.showRefs(("%s requires (%d)"):format(scr.Name, #list), function()
				if #list == 0 then addTextRow(1, "This script requires nothing.") end
				eachRow(list, 0, function(n, _, req)
					local inst = req.path.root and resolveInstance(req.path, scr)
					local isScript = typeof(inst) == "Instance" and inst:IsA("LuaSourceContainer")
					addNavRow(n, req.path.text..(isScript and "" or (inst and "  (not a script)" or "  (not found now)")), function()
						if isScript then ScriptViewer.ViewScript(inst) else Nav.go(tab, req.line, 0) end
					end, ":"..req.line)
				end, 500)
			end)
		end

		Tools.showRequiredBy = function()
			local scr = currentScript()
			if not scr then toast("Open a decompiled script first", "warn") return end
			Nav.showRefs("Required by "..scr.Name, function(page)
				if next(memory) == nil then
					addTextRow(1, "No script has been read yet. Reading them lets this find the scripts that require this one.")
					Tools.action(2, "Read all scripts now", function()
						Tools.scan()
						renderEdit()
					end)
					follow(page)
					return
				end
				local list = requiredBy(scr)
				addTextRow(1, ("%d of the %d scripts read so far require it%s"):format(#list, countRead(), state.Running and " (still reading)" or ""))
				eachRow(list, 1, function(n, _, r)
					addNavRow(n, fullName(r.Script), function() ScriptViewer.ViewScript(r.Script, r.Line) end, ":"..r.Line)
				end, 500)
				follow(page)
			end)
		end

		-- The graph of modules around the current script: what it requires (and, for the scripts read so far,
		-- what those require) and which scripts read so far require it. A box is a script.
		Tools.moduleGraph = function(R)
			local scr = currentScript()
			if not scr then error("open a decompiled script first") end
			local nodes, edges, idOf, linked = {}, {}, {}, {}
			local function node(s, kind)
				local id = idOf[s]
				if not id and #nodes < 60 then
					id = #nodes + 1
					idOf[s] = id
					nodes[id] = {id = id, kind = kind, label = s.Name.."\n"..s.ClassName, script = s, stmts = {}, funcs = {}, calls = {}}
				end
				return nodes[id or 0]
			end
			local function link(a, b)
				if a and b and a ~= b and not linked[a.id..">"..b.id] then
					linked[a.id..">"..b.id] = true
					edges[#edges+1] = {from = a.id, to = b.id, kind = "call", count = 1}
				end
			end
			local root = node(scr, "root")
			for _,req in ipairs(requiresOf(scr, Analysis.Requires(R))) do
				local child = node(req.Script, "func")
				link(root, child)
				local entry = memory[req.Script]
				local d = entry and digestOf(entry)
				for _,deeper in ipairs(d and requiresOf(req.Script, d.requires) or {}) do
					link(child, node(deeper.Script, "func"))
				end
			end
			for _,r in ipairs(requiredBy(scr)) do link(node(r.Script, "func"), root) end
			return {nodes = nodes, edges = edges, mode = "modules", R = R}
		end

		Tools.showModules = function()
			if not Flowchart then toast("The flowchart module is not loaded", "warn") return end
			if not currentScript() then toast("Open a decompiled script first", "warn") return end
			flowMode = "modules"
			setFlowOpen(true, true)
			refreshFlow()
			window:Show()
		end

		-- The places where the other scripts use a member of a module (M.fn, M:fn(), M.field after M = require(module)):
		-- {Script, Line, Call, Write}. Only the scripts that have the name in them are parsed.
		Tools.usersOf = function(module, member)
			local out = {}
			for _,e in ipairs(Tools.entries()) do
				local text = e.Entry.Text
				if e.Script ~= module and text:find("require", 1, true) and text:find(member, 1, true) then
					local d = digestOf(e.Entry)
					for _,u in ipairs(d and d.uses or {}) do
						if u.member == member then
							local req = d.requires[u.req]
							if req and req.path.root and resolveInstance(req.path, e.Script) == module then
								out[#out+1] = {Script = e.Script, Entry = e.Entry, Line = u.line, Call = u.call, Write = u.write}
							end
						end
					end
				end
			end
			return out
		end

		-- Under the references of a name: the uses of it in other scripts, when it is a member of a module that was
		-- required here (M.fn), or a name in a module (the uses of its fn elsewhere). order is the last row used.
		Tools.moduleUsers = function(R, ti, order, page, scr)
			if not scr then return end
			local module, member
			local info = Analysis.ModuleMember(R, ti)
			if info then
				module, member = info.path.root and resolveInstance(info.path, scr), info.member
			elseif scr:IsA("ModuleScript") and R.tt[ti] == "name" and not R.symAt[ti] then
				module, member = scr, R.tv[ti]
			end
			if typeof(module) ~= "Instance" or not module:IsA("ModuleScript") then return end
			order = order + 1
			if not state.Scanned then
				addTextRow(order, ("%s.%s may be used in other scripts. They have not been read yet."):format(module.Name, member))
				order = order + 1
				Tools.action(order, "Read all scripts to find them", function()
					Tools.scan()
					renderEdit()
				end)
				follow(page)
				return
			end
			local users = Tools.usersOf(module, member)
			Tools.head(order, ("%s.%s in the other scripts, of %d read"):format(module.Name, member, countRead()), #users)
			eachRow(users, order, function(n, _, u)
				local row = addNavRow(n, ("%s  %s  %s"):format(u.Write and "W" or (u.Call and "call" or "R"), tail(fullName(u.Script), 30), lineOf(u.Entry.Text, u.Line):sub(1, 200)), function() ScriptViewer.ViewScript(u.Script, u.Line) end, ":"..u.Line)
				if u.Write then row.TextColor3 = Color3.fromRGB(255,190,110) end
			end, 300)
			follow(page)
		end

		-- Go to definition on the fn of M.fn, M being a module that was required here: the function in that module. false when
		-- the name is not that (the caller goes on with the definition in this script).
		Tools.gotoModuleMember = function(R, ti)
			local info = Analysis.ModuleMember(R, ti)
			local scr = currentScript()
			if not (info and scr and info.path.root) then return false end
			local module = resolveInstance(info.path, scr)
			if typeof(module) ~= "Instance" or not module:IsA("LuaSourceContainer") then return false end
			local entry = memory[module]
			if not entry then
				toast("Reading "..module.Name.."...")
				local ok, read = pcall(readScript, module, false)
				entry = ok and read or nil
				if not entry then toast("Could not decompile "..module.Name, "warn") return true end
				memory[module] = entry
			end
			local d = digestOf(entry)
			local found
			for _,f in ipairs(d and d.funcs or {}) do
				-- written as Module.fn or Module:fn (a field) before a local function of that name
				if f.short == info.member and (not found or (f.name:find("[%.:]") and not found.name:find("[%.:]"))) then found = f end
			end
			if not found then toast(("%s has no function called %s"):format(module.Name, info.member), "warn") return true end
			ScriptViewer.ViewScript(module, found.line)
			return true
		end

		----------------------------------------------------------------------------------------------
		-- Remotes of the whole game
		----------------------------------------------------------------------------------------------

		-- Every remote the scripts read mention, as {Inst (when the path leads to one now), Text, Fire, Listen}; Fire and
		-- Listen are the places {Script, Path, Line, Method, Args, ArgCount, Fn, Copies}.
		Tools.remoteSites = function()
			local byKey, list = {}, {}
			for _,e in ipairs(Tools.entries()) do
				local d = e.Entry.D
				for _,r in ipairs(d and d.remotes or {}) do
					if r.kind == "remote" or r.kind == "listen" then
						local inst = r.path and resolveInstance(r.path, e.Script)
						if typeof(inst) ~= "Instance" then inst = nil end
						local key = inst or ("text:"..(r.path and r.path.text or "?"))
						local site = byKey[key]
						if not site then
							site = {Inst = inst, Text = inst and fullName(inst) or (r.path and r.path.text or "?"), Fire = {}, Listen = {}}
							byKey[key] = site
							list[#list+1] = site
						end
						table.insert(r.kind == "remote" and site.Fire or site.Listen, {Script = e.Script, Path = e.Path, Line = r.line, Method = r.method, Args = r.args, ArgCount = r.argCount, Fn = r.fname, Copies = e.Copies})
					end
				end
			end
			table.sort(list, function(a, b) return a.Text:lower() < b.Text:lower() end)
			return list
		end

		K.REMOTE_CLASSES = {RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true}
		K.NO_REMOTES = {CoreGui = true, CorePackages = true, RobloxPluginGuiService = true}

		-- The remotes in the game that none of the scripts read mention (by path, or by name when the path could not be followed).
		Tools.unusedRemotes = function(sites)
			local usedInst, usedName = {}, {}
			for _,s in ipairs(sites) do
				if s.Inst then usedInst[s.Inst] = true else usedName[s.Text:match("[^%.]+$") or s.Text] = true end
			end
			local out = {}
			for _,svc in ipairs(game:GetChildren()) do
				if not K.NO_REMOTES[svc.ClassName] then
					local ok, all = pcall(svc.GetDescendants, svc)
					for _,o in ipairs(ok and all or {}) do
						if K.REMOTE_CLASSES[o.ClassName] and not usedInst[o] and not usedName[o.Name] then out[#out+1] = o end
					end
				end
			end
			table.sort(out, function(a, b) return fullName(a) < fullName(b) end)
			return out
		end

		-- One remote: who fires it and who listens.
		Tools.showRemoteSite = function(site)
			pushEdit(tail(site.Text, 30), function()
				local order = 1
				addTextRow(order, site.Text)
				if site.Inst then
					order = order + 1
					Tools.action(order, "Select in Explorer", function() Explorer.SelectObj(site.Inst) end)
				end
				for _,group in ipairs({{"Fired by", site.Fire}, {"Listened to by", site.Listen}}) do
					table.sort(group[2], function(a, b)
						if a.Path ~= b.Path then return a.Path < b.Path end
						return a.Line < b.Line
					end)
					order = order + 1
					Tools.head(order, group[1], #group[2])
					order = eachRow(group[2], order, function(n, _, s)
						local args = table.concat(s.Args, ", ")
						addNavRow(n, ("%s  %s(%s)%s"):format(tail(s.Path, 28), s.Method, args, s.Copies > 1 and ("  and "..(s.Copies - 1).." copies") or ""), function() ScriptViewer.ViewScript(s.Script, s.Line) end, ":"..s.Line)
					end, 200)
				end
			end, "remotemap")
		end

		-- Reads every script for a page that needs them all, when that page is chosen.
		K.needAll = function() Tools.index() end

		rootPages.remotemap = {Title = "Remote map of the game", Chip = "Remotes", Open = K.needAll, Tip = "Every remote the scripts fire or listen to, and which scripts do; and the remotes none of them mention", Build = function(page)
				local order = 0
				local function note(text)
					order = order + 1
					return addTextRow(order, text)
				end
				local work = workNote()
				if work then note(work) end
				if not state.Scanned and not state.Running then
					order = order + 1
					Tools.action(order, "Read all scripts now", function()
						Tools.index()
						renderEdit()
					end)
				end
				-- (worked out once for what has been read and parsed so far: typing in the filter draws the page again)
				if state.SitesAt ~= state.Version then
					state.Sites, state.SitesAt, state.Unused = Tools.remoteSites(), state.Version, nil
				end
				local sites = state.Sites
				order = eachRow(sites, order, function(n, _, s)
					Tools.link(n, ("%s   fire %d, listen %d"):format(tail(s.Text, 34), #s.Fire, #s.Listen), function() Tools.showRemoteSite(s) end)
				end, 300)
				if #sites == 0 and not work then note("No script read fires or listens to a remote.") end

				if not work then
					state.Unused = state.Unused or Tools.unusedRemotes(sites)
					order = order + 1
					Tools.head(order, "Remotes that no script read mentions", #state.Unused)
					note("The server may use them, or nothing does. A click selects one in the Explorer.")
					eachRow(state.Unused, order, function(n, _, o)
						addNavRow(n, tail(fullName(o), 44), function() Explorer.SelectObj(o) end)
					end, 150)
				end
				follow(page)
		end}

		-- The remote map, showing the remotes with a text in their path.
		Tools.openRemoteMap = function(filter)
			rootPages.remotemap.Filter = (filter and filter ~= "") and filter or nil
			openPage("remotemap")
		end

		-- Explorer: "Where is this used?" on a remote.
		ScriptViewer.WhereUsed = function(inst)
			Tools.openRemoteMap(inst and inst.Name or "")
		end

		----------------------------------------------------------------------------------------------
		-- Functions of the whole game (the command palette goes to them) and the table of scripts
		----------------------------------------------------------------------------------------------

		-- The named functions of the scripts parsed so far: {Label, Script, Line} (the palette asks when it opens).
		Tools.functions = function()
			local out = {}
			for _,e in ipairs(Tools.entries()) do
				for _,f in ipairs(e.Entry.D and e.Entry.D.funcs or {}) do
					if #out >= 8000 then break end
					out[#out+1] = {Label = ("%s  (%s:%d)"):format(f.name, tail(e.Path, 40), f.line), Script = e.Script, Line = f.line}
				end
			end
			return out
		end

		K.TRIAGE = {
			{Label = "lines", Get = function(s) return s.lines end},
			{Label = "functions", Get = function(s) return s.sig.functions end},
			{Label = "remote calls", Get = function(s) return s.sig.fire + s.sig.listen end},
			{Label = "http and loadstring", Get = function(s) return s.sig.http + s.sig.loadstring end},
			{Label = "words like kick, ban, detect", Get = function(s) return s.sig.words end},
			{Label = "signs of obfuscation", Get = function(s) return s.sig.obf * 100000 + s.sig.longest end},
		}

		rootPages.contents = {Title = "Scripts by what they contain", Chip = "Contents", Open = K.needAll, Tip = "Every script with what is in it (lines, functions, remote calls, HTTP, signs of obfuscation), sorted by the one you pick", Build = function(page)
				local order = 0
				local function note(text)
					order = order + 1
					return addTextRow(order, text)
				end
				state.TriageBy = state.TriageBy or 1
				local by = K.TRIAGE[state.TriageBy]
				local labels = {}
				for i,t in ipairs(K.TRIAGE) do labels[i] = t.Label end
				order = order + 1
				Tools.choice(order, "Most of", labels, by.Label, function(label)
					state.TriageBy = table.find(labels, label) or 1
					renderEdit()
				end)
				local work = workNote()
				if work then note(work) end
				if not state.Scanned and not state.Running then
					order = order + 1
					Tools.action(order, "Read all scripts now", function()
						Tools.index()
						renderEdit()
					end)
				end
				local rows = {}
				for _,e in ipairs(Tools.entries()) do
					local d = e.Entry.D
					if d then rows[#rows+1] = {E = e, D = d, Score = by.Get(d)} end
				end
				table.sort(rows, function(a, b)
					if a.Score ~= b.Score then return a.Score > b.Score end
					return a.E.Path < b.E.Path
				end)
				eachRow(rows, order, function(n, _, r)
					local s = r.D.sig
					local row = addNavRow(n - 1, tail(r.E.Path, 44), function() ScriptViewer.ViewScript(r.E.Script) end)
					if row == NO_ROW then return end -- (left out by the filter: no line of numbers either)
					if s.obf >= 2 then row.TextColor3 = Color3.fromRGB(255,190,110) end
					addTextRow(n, ("%d lines, %d functions, fire %d, listen %d, http %d, loadstring %d, kick/ban/detect %d%s%s"):format(r.D.lines, s.functions, s.fire, s.listen, s.http, s.loadstring, s.words, s.obf >= 2 and ", looks obfuscated" or "", r.E.Copies > 1 and (", and "..(r.E.Copies - 1).." copies") or ""))
				end, 100, 2)
				follow(page)
		end}

		----------------------------------------------------------------------------------------------
		-- Scripts that could not be decompiled, and what changed since the last session
		----------------------------------------------------------------------------------------------

		-- Reads again the scripts that failed, with a decompiler of the executor (by name) or the default one.
		Tools.retryFailed = function(name)
			if state.Running or state.Retrying then return end
			local decompiler = name and env.decompilers[name] or nil
			local todo = {}
			for scr in pairs(state.Failures) do todo[#todo+1] = scr end
			if #todo == 0 then return end
			table.sort(todo, function(a, b) return fullName(a) < fullName(b) end)
			state.Retrying = true
			task.spawn(function()
				local fixed = 0
				for _,scr in ipairs(todo) do
					if state.Dead then return end
					local ok, entry = pcall(readScript, scr, true, decompiler)
					if ok and entry then
						memory[scr] = entry
						state.Failures[scr] = nil
						fixed = fixed + 1
						if query ~= "" and not state.Error then matchScript(scr, entry) end
					end
					state.Version = state.Version + 1
					task.wait()
				end
				local failed = 0
				for _ in pairs(state.Failures) do failed = failed + 1 end
				state.Failed, state.Retrying = failed, false
				state.Version = state.Version + 1
				toast(("%d of %d scripts could be decompiled%s"):format(fixed, #todo, name and (" with "..name) or ""), fixed > 0 and "success" or "warn")
				if state.Want then Tools.index() end
			end)
		end

		Tools.showFailed = function()
			pushEdit("Scripts that could not be decompiled", function(page)
				local order = 1
				local list = {}
				for scr,why in pairs(state.Failures) do list[#list+1] = {Script = scr, Why = why} end
				table.sort(list, function(a, b) return fullName(a.Script) < fullName(b.Script) end)
				addTextRow(order, ("%d scripts. A failure is not tried again for a day unless you ask here."):format(#list))
				if #list > 0 then
					order = order + 1
					Tools.action(order, state.Retrying and "Trying again..." or "Try all again with the default decompiler", function() Tools.retryFailed(nil) renderEdit() end)
					for _,name in ipairs(decompilerNames()) do
						order = order + 1
						Tools.action(order, "Try all again with "..name, function() Tools.retryFailed(name) renderEdit() end)
					end
				end
				eachRow(list, order, function(n, _, f)
					addNavRow(n, ("%s  (%s)"):format(tail(fullName(f.Script), 40), f.Why), function() ScriptViewer.ViewScript(f.Script) end)
				end, 300)
				follow(page)
			end, "search")
		end

		-- Opens the difference between the last session's version of a changed script and this one.
		local function diffChanged(key)
			local scr = state.KeyScript and state.KeyScript[key]
			local entry = scr and memory[scr]
			if not entry then toast("That script was not read (it could not be decompiled)", "warn") return end
			local old = D.cachedRead(state.Baseline[key])
			if not old then toast("The old version is no longer on disk", "warn") return end
			openDiffTab(scr.Name, "last time vs now", old, entry.Text)
		end

		rootPages.changes = {Title = "Changed since last time", Chip = "Changes", Tip = "The scripts that are new, gone or different since the last session in this place read them", Count = function()
			local c = state.Changes
			return c and (#c.changed + #c.added + #c.removed) or nil
		end, Build = function(page)
				local order = 0
				local function note(text)
					order = order + 1
					return addTextRow(order, text)
				end
				local c = state.Changes
				if not c then
					note(state.ChangesNote or (state.Baseline and "Read the scripts to compare them." or (state.Scanned and "There is no earlier read of this place to compare with. The next session will have this one." or "The scripts are compared with the last session's once they have been read.")))
					if not state.Scanned and not state.Running then
						order = order + 1
						Tools.action(order, "Read all scripts now", function()
							Tools.scan()
							renderEdit()
						end)
					end
					follow(page)
					return
				end
				note(("Compared with the read of %s. Scripts that other players' characters and the game make while it runs show up as new or gone."):format(state.BaselineTime and os.date("%Y-%m-%d %H:%M", state.BaselineTime) or "an earlier session"))
				local function section(title, keys, onClick)
					order = order + 1
					Tools.head(order, title, #keys)
					order = eachRow(keys, order, function(n, _, key)
						addNavRow(n, tail(key, 46), function() onClick(key) end)
					end, 200)
				end
				section("Changed (a click shows the difference)", c.changed, diffChanged)
				section("New (a click opens it)", c.added, function(key)
					local scr = state.KeyScript[key]
					if scr then ScriptViewer.ViewScript(scr) end
				end)
				section("Gone (a click shows the old version)", c.removed, function(key)
					local old = D.cachedRead(state.Baseline[key])
					if old then Tools.openChunk(key.." (last time)", old) else toast("The old version is no longer on disk", "warn") end
				end)
		end}

		----------------------------------------------------------------------------------------------
		-- The scripts opened lately and the ones with notes: where the Search page starts from
		----------------------------------------------------------------------------------------------

		-- The paths of the scripts opened lately in this place, newest first. They are kept in
		-- dex/recent.json, a list per place. ponytail: a place never visited again keeps its list; prune by
		-- date if the file ever grows.
		function D.recent()
			if state.Recent then return state.Recent end
			state.Recent, state.RecentAll, state.RecentScripts = {}, {}, {}
			pcall(function()
				if env.isfile and env.readfile and env.isfile("dex/recent.json") then
					local data = service.HttpService:JSONDecode(env.readfile("dex/recent.json"))
					if type(data) == "table" then
						state.RecentAll = data
						local mine = data[tostring(game.PlaceId)]
						if type(mine) == "table" then state.Recent = mine end
					end
				end
			end)
			return state.Recent
		end

		-- A script was opened: it goes to the front of the list.
		Tools.addRecent = function(scr)
			local list = D.recent()
			local path = fullName(scr)
			state.RecentScripts[path] = scr -- this session's, so that they open without being looked for
			local at = table.find(list, path)
			if at == 1 then return end
			if at then table.remove(list, at) end
			table.insert(list, 1, path)
			while #list > 20 do table.remove(list) end
			if not env.writefile then return end
			state.RecentAll[tostring(game.PlaceId)] = list
			pcall(function()
				pcall(env.makefolder, "dex")
				env.writefile("dex/recent.json", service.HttpService:JSONEncode(state.RecentAll))
			end)
		end

		-- The script a path of the list leads to now, if it is in the game.
		function D.findScript(path)
			local scr = state.RecentScripts[path]
			if scr then return scr end
			local list = Tools.scriptList()
			if state.ByPathFor ~= list then -- (a map of the list, made once per list)
				state.ByPath, state.ByPathFor = {}, list
				for _,s in ipairs(list) do state.ByPath[fullName(s)] = s end
			end
			if state.ByPath[path] then return state.ByPath[path] end
			local obj = game -- a script of a kind that is left out of the list
			for name in path:gmatch("[^%.]+") do
				obj = obj and obj:FindFirstChild(name)
			end
			return (typeof(obj) == "Instance" and obj ~= game and obj:IsA("LuaSourceContainer")) and obj or nil
		end

		-- The scripts of the game that have notes or renames saved: {Script, Path, Text}. Looked up
		-- again after a quarter of a minute.
		Tools.annotated = function()
			if state.Annotated and os.clock() - state.AnnotatedAt < 15 then return state.Annotated end
			local out = {}
			state.Annotated, state.AnnotatedAt = out, os.clock()
			if not (env.listfiles and env.readfile) then return out end
			local ok, files = pcall(env.listfiles, "dex/annotations")
			local have = {}
			for _,f in ipairs(ok and type(files) == "table" and files or {}) do
				local base = tostring(f):match("([^/\\]+)%.json$")
				if base then have[base] = true end
			end
			if next(have) == nil then return out end
			for _,scr in ipairs(Tools.scriptList()) do
				local okPath, path = pcall(annPath, scr)
				if okPath and have[path:match("([^/\\]+)$")] then
					local file = readAnnFile(scr)
					local set = file and type(file.sets) == "table" and newestSet(file)
					if set then
						local parts = {}
						for _,kind in ipairs({{"comments", "notes"}, {"renames", "renames"}}) do
							local n = #(type(set[kind[1]]) == "table" and set[kind[1]] or {})
							if n > 0 then parts[#parts+1] = n.." "..kind[2] end
						end
						if #parts > 0 then out[#out+1] = {Script = scr, Path = fullName(scr), Text = table.concat(parts, ", ")} end
					end
				end
			end
			table.sort(out, function(a, b) return a.Path < b.Path end)
			return out
		end

		----------------------------------------------------------------------------------------------
		-- The Search page, and the settings of the reading behind it
		----------------------------------------------------------------------------------------------

		-- What the reading of the scripts does: which kinds it leaves out, reading again, the scripts that
		-- failed, the files it keeps on disk.
		Tools.showScanSettings = function()
			pushEdit("Scan settings", function(page)
				local order = 0
				local function act(text, onClick, danger)
					order = order + 1
					return Tools.action(order, text, onClick, danger)
				end
				if state.Running then
					act("Stop reading", function() state.Cancel = true end)
				elseif state.Scanned then
					act("Read the scripts again", function()
						state.Scanned = false
						Tools.scan(true)
						rematch() -- after the scan has forgotten what it had read, so the old matches go
						renderEdit()
					end)
				else
					act(("Read all scripts now (%d found)"):format(#Tools.scriptList()), function()
						Tools.scan()
						renderEdit()
					end)
				end
				if state.Failed > 0 then
					order = order + 1
					Tools.link(order, ("Scripts that could not be decompiled (%d)"):format(state.Failed), Tools.showFailed)
				end
				if env.listfiles then
					if not state.CacheCount then state.CacheCount = #D.cacheFiles() end
					local cache = act(("Clear the decompile cache (%d files)"):format(state.CacheCount), function()
						Tools.clearCache()
						renderEdit()
					end, true)
					Lib.Tooltip.attach(cache, "Deletes the decompiled scripts kept on disk (named by their hash). They are decompiled again when needed")
				end

				order = order + 1
				Tools.head(order, "Scripts to leave out")
				order = order + 1
				addTextRow(order, "The kinds that are ticked are not read, searched or offered in the command palette.")
				for _,kind in ipairs(K.SKIP_KINDS) do
					order = order + 1
					Tools.checkRow(order, kind.Label, Tools.Skip[kind.Key], function(on)
						Tools.Skip[kind.Key] = on
						skipsChanged()
					end)
				end
				for _,all in ipairs({true, false}) do
					act(all and "Tick all" or "Untick all", function()
						for key in pairs(Tools.Skip) do Tools.Skip[key] = all end
						skipsChanged()
						renderEdit()
					end)
				end
				follow(page)
			end, "search")
		end

		rootPages.search = {Title = "Search all scripts", Chip = "Search", NoFilter = true, Tip = "Search the text or the code of every script of the game; with nothing typed, the scripts you opened lately and the ones you annotated", Count = function() return #results end, Build = function(page)
			local order = 0
			local function nav(text, onClick, right)
				order = order + 1
				return addNavRow(order, text, onClick, right)
			end
			local function note(text)
				order = order + 1
				return addTextRow(order, text)
			end

			order = order + 1
			local box = Tools.input(order, "Search every script (Enter)", query, function(text) Tools.search(text) end)
			local names = {}
			for i,m in ipairs(K.MODES) do names[i] = K.MODE_NAMES[m] end
			order = order + 1
			Tools.choice(order, "Search for", names, K.MODE_NAMES[mode], function(name)
				mode = K.MODES[table.find(names, name) or 1]
				rematch()
				renderEdit()
			end)
			order = order + 1
			Tools.checkRow(order, "Match case", matchCase, function(on)
				matchCase = on
				rematch()
				renderEdit()
			end)

			local status = note("")
			local function paint()
				if state.Error then
					status.Text = state.Error
				elseif state.Running then
					status.Text = ("Reading the scripts: %d of %d.  %d have matches"):format(state.Done, state.Total, #results)
				elseif state.Matching then
					status.Text = ("Searching the code of the scripts read.  %d have matches so far"):format(#results)
				elseif state.Indexing then
					status.Text = ("Parsing the scripts: %d of %d.  %d have matches"):format(state.IndexDone, state.IndexTotal, #results)
				elseif state.Scanned then
					status.Text = ("%d scripts read (%d could not be decompiled, %d left out)%s.  %d have matches"):format(state.Total - state.Failed, state.Failed, state.Skipped, state.Added > 0 and (", "..state.Added.." new since") or "", #results)
				else
					status.Text = "Searching reads every script first (decompiling takes a while the first time; later it is kept on disk)."
				end
			end
			paint()
			if state.Running then
				order = order + 1
				Tools.action(order, "Stop reading", function() state.Cancel = true end)
			elseif not state.Scanned then
				order = order + 1
				Tools.action(order, "Read all scripts now", function()
					Tools.scan()
					renderEdit()
				end)
			end
			local ticked = 0
			for _,kind in ipairs(K.SKIP_KINDS) do
				if Tools.Skip[kind.Key] then ticked = ticked + 1 end
			end
			order = order + 1
			local settings = Tools.link(order, ("Scan settings (%d of %d kinds of script left out)"):format(ticked, #K.SKIP_KINDS), Tools.showScanSettings)
			Lib.Tooltip.attach(settings, "Which scripts are not read (CoreGui, CorePackages, Chat, the default player scripts, other players, copies), reading them again, the ones that could not be decompiled, the cache on disk")

			-- the scripts with matches: a section each (a click on its title folds it), a row per match
			table.sort(results, function(a, b) return a.Path < b.Path end)
			local rows = 0
			for _,r in ipairs(results) do
				if rows >= K.MAX_ROWS then
					note("... more scripts are not shown: make the search narrower")
					break
				end
				order = order + 1
				Tools.head(order, tail(r.Path, 38)..(r.Copies > 1 and (", and "..(r.Copies - 1).." copies") or ""), #r.Matches..(#r.Matches >= K.PER_SCRIPT and "+" or ""))
				rows = rows + 1
				for i = 1, math.min(#r.Matches, 4) do
					local m = r.Matches[i]
					rows = rows + 1
					nav(m.text, function() ScriptViewer.ViewScript(r.Script, m.line) end, ":"..m.line)
				end
				if #r.Matches > 4 then
					rows = rows + 1
					order = order + 1
					Tools.link(order, ("%d more in this script: open it with the find bar"):format(#r.Matches - 4), function()
						ScriptViewer.ViewScript(r.Script, r.Matches[5].line)
						Nav.findKind, Nav.findCase = (mode == "word" or mode == "pattern") and mode or "text", matchCase
						Nav.paintFind()
						openBar("find", query)
					end)
				end
			end

			-- nothing asked for: the scripts opened lately in this place, and the ones with notes
			if query == "" then
				local recent = D.recent()
				if #recent > 0 then
					order = order + 1
					Tools.head(order, "Opened lately", #recent)
					for _,path in ipairs(recent) do
						nav(tail(path, 46), function()
							local scr = D.findScript(path)
							if scr then ScriptViewer.ViewScript(scr) else toast("That script is not in the game now", "warn") end
						end)
					end
				end
				order = order + 1
				Tools.head(order, "More")
				order = order + 1
				Tools.link(order, "Scripts with your notes or renames", function()
					pushEdit("Scripts with your notes", function()
						local list = Tools.annotated()
						if #list == 0 then addTextRow(1, "No script of this game has notes or renames saved (or your executor cannot list files).") end
						eachRow(list, 1, function(n, _, a)
							addNavRow(n, ("%s  (%s)"):format(tail(a.Path, 34), a.Text), function() ScriptViewer.ViewScript(a.Script) end)
						end, 300)
					end, "search")
				end)
			end

			follow(page, box) -- the rows, as the work in the background goes on
			local redraw = page.Tick
			page.Tick = function()
				paint()
				redraw()
			end
		end}

		----------------------------------------------------------------------------------------------
		-- The AI window: what the scripts say together, for an agent (Tools.registerAgent calls this, with
		-- h: what finds the script an argument names, its decompile and its analysis). A tool that needs
		-- every script read starts that, as the pages here do, waits a while for it, and says so when it
		-- answers from a part of the scripts.
		----------------------------------------------------------------------------------------------

		Tools.agentScan = function(Agent, h)
			local reg = Agent.Register
			local WAIT = 45 -- seconds a tool waits for the reading before it answers from what there is

			-- Has the scripts read (and parsed, when the digests are needed). nil when that is done, else
			-- what to tell the agent about its answer.
			local function ready(parsed)
				if parsed then
					Tools.index()
				elseif not state.Scanned and not state.Running then
					Tools.scan()
				end
				local started = os.clock()
				while (state.Running or (parsed and state.Indexing)) and not state.Dead and os.clock() - started < WAIT do task.wait(0.25) end
				if state.Scanned and not state.Running and not (parsed and (state.Indexing or unparsed() > 0)) then return nil end
				return (workNote() or "The scripts have not all been read")..". This answer is from the ones read so far: ask again for the rest."
			end

			-- What a digest counts, by the name an agent filters and sorts with
			local FACETS = {
				lines = function(d) return d.lines end,
				functions = function(d) return d.sig.functions end,
				remotes = function(d) return d.sig.fire + d.sig.listen end,
				http = function(d) return d.sig.http end,
				loadstring = function(d) return d.sig.loadstring end,
				suspicious = function(d) return d.sig.words end,
				obfuscated = function(d) return d.sig.obf >= 2 and d.sig.obf * 100000 + d.sig.longest or 0 end,
			}

			reg("scripts", function(args)
				local limit = math.clamp(math.floor(tonumber(args.limit) or 50), 1, 200)
				local query = type(args.query) == "string" and args.query ~= "" and args.query:lower() or nil
				local has, sort = args.has, args.sort
				if has ~= nil and not (FACETS[has] or has == "changed" or has == "notes") then error("has is one of: remotes, http, loadstring, suspicious, obfuscated, changed, notes", 0) end
				if sort ~= nil and not FACETS[sort] then error("sort is one of: lines, functions, remotes, http, loadstring, suspicious, obfuscated", 0) end
				local note
				if has == "changed" then
					note = ready(false)
				elseif sort or (has and has ~= "notes") then
					note = ready(true)
				end

				local changed, noted = {}, {}
				for _,key in ipairs(state.Changes and state.Changes.changed or {}) do
					local scr = state.KeyScript[key]
					if scr then changed[scr] = true end
				end
				for _,a in ipairs(Tools.annotated()) do noted[a.Script] = a.Text end

				local rows = {}
				for _,scr in ipairs(Tools.scriptList()) do
					local path = fullName(scr)
					if not query or path:lower():find(query, 1, true) then
						local entry = memory[scr]
						local d = entry and entry.D or nil -- (nothing before it is parsed, and when it does not parse)
						local keep = true
						if has == "changed" then
							keep = changed[scr] == true
						elseif has == "notes" then
							keep = noted[scr] ~= nil
						elseif has then
							keep = d ~= nil and FACETS[has](d) > 0
						end
						if keep then rows[#rows+1] = {Script = scr, Path = path, D = d, Score = sort and d and FACETS[sort](d) or 0} end
					end
				end
				if sort then
					table.sort(rows, function(a, b)
						if a.Score ~= b.Score then return a.Score > b.Score end
						return a.Path < b.Path
					end)
				end

				local function some(n) return n > 0 and n or nil end
				local out = {}
				for i = 1, math.min(#rows, limit) do
					local r = rows[i]
					local item = {id = Agent.IdOf(r.Script), path = r.Path, class = r.Script.ClassName, changed = changed[r.Script], notes = noted[r.Script]}
					if r.D then
						local s = r.D.sig
						item.lines, item.functions = r.D.lines, s.functions
						item.fire, item.listen, item.http, item.loadstring, item.suspicious = some(s.fire), some(s.listen), some(s.http), some(s.loadstring), some(s.words)
						item.obfuscated = s.obf >= 2 or nil
					end
					out[i] = item
				end
				return {total = #rows, shown = #out, scripts = out, note = note}
			end)

			reg("search", function(args)
				local text = args.query
				if type(text) ~= "string" or text == "" then error("query is needed: what to look for", 0) end
				local how = args.mode or "text"
				if not table.find(K.MODES, how) then error("mode is one of: "..table.concat(K.MODES, ", "), 0) end
				local case = args.case == true
				if how == "pattern" then
					local ok, why = Analysis.SearchText("", text, how, case, 1)
					if not ok then error(why, 0) end
				elseif how == "call" and not (text:match("([%w_]+)%s*%(") or text:match("([%w_]+)%s*$")) then
					error("Write the name of a function, or name(text in its arguments)", 0)
				end
				local limit = math.clamp(math.floor(tonumber(args.limit) or 50), 1, 200)
				local within = type(args.path) == "string" and args.path ~= "" and args.path:lower() or nil
				local note = ready(false)

				-- (the user's own search, on the Search page, is not touched: this goes through the scripts itself)
				local lines, matches, hit, searched = {}, 0, 0, 0
				local frameStart = os.clock()
				for _,e in ipairs(Tools.entries()) do
					if not within or e.Path:lower():find(within, 1, true) then
						searched = searched + 1
						local ok, found = pcall(searchEntry, e.Entry, text, how, case)
						if ok and found and #found > 0 then
							hit = hit + 1
							if matches < limit then lines[#lines+1] = ("%s (%s)%s"):format(e.Path, Agent.IdOf(e.Script), e.Copies > 1 and (", and "..(e.Copies - 1).." copies") or "") end
							for _,m in ipairs(found) do
								matches = matches + 1
								if matches <= limit then lines[#lines+1] = ("  %d: %s"):format(m.line, m.text) end
							end
						end
						if os.clock() - frameStart > K.BUDGET then
							task.wait()
							frameStart = os.clock()
						end
					end
				end
				local head = ("%d match%s in %d of %d scripts%s"):format(matches, matches == 1 and "" or "es", hit, searched, matches > limit and (", the first "..limit.." shown") or "")
				if note then head = head.."\n"..note end
				return #lines > 0 and (head.."\n"..table.concat(lines, "\n")) or head
			end)

			reg("remote_map", function(args)
				local limit = math.clamp(math.floor(tonumber(args.limit) or 100), 1, 500)
				local want = type(args.remote) == "string" and args.remote ~= "" and args.remote:lower() or nil
				local note = ready(true)
				local sites = Tools.remoteSites()
				local lines = {}

				if args.unused == true then
					if note then error(("which remotes no script mentions is known once every script is read (%s): ask again"):format(workNote() or "they are not"), 0) end
					local unused = Tools.unusedRemotes(sites)
					lines[1] = ("%d remotes of the game are mentioned by none of its scripts (the server may use them, or nothing does)"):format(#unused)
					for i = 1, math.min(#unused, limit) do lines[#lines+1] = ("  %s (%s)"):format(fullName(unused[i]), unused[i].ClassName) end
					return table.concat(lines, "\n")
				end

				local matched = {}
				for _,s in ipairs(sites) do
					if not want or s.Text:lower():find(want, 1, true) then matched[#matched+1] = s end
				end
				if note then lines[1] = note end
				if not want then
					lines[#lines+1] = ("%d remotes are fired or listened to by the scripts"):format(#matched)
					for i = 1, math.min(#matched, limit) do
						local s = matched[i]
						lines[#lines+1] = ("  %s%s   fire %d, listen %d"):format(s.Text, s.Inst and "" or " (not followed to an object)", #s.Fire, #s.Listen)
					end
					return table.concat(lines, "\n")
				end
				if #matched == 0 then
					error(("no script fires or listens to a remote with '%s' in its path (remote_map without a remote lists the ones they do)%s"):format(args.remote, note and (". "..note) or ""), 0)
				end
				for i = 1, math.min(#matched, 10) do
					local s = matched[i]
					lines[#lines+1] = s.Text..(s.Inst and (" ("..s.Inst.ClassName..")") or " (not followed to an object)")
					for _,group in ipairs({{"fired by", s.Fire}, {"listened to by", s.Listen}}) do
						lines[#lines+1] = ("  %s (%d):"):format(group[1], #group[2])
						for j = 1, math.min(#group[2], 30) do
							local p = group[2][j]
							lines[#lines+1] = ("    %s (%s) line %d%s: %s(%s)%s"):format(p.Path, Agent.IdOf(p.Script), p.Line, (p.Fn and p.Fn ~= "<main>") and (", in "..p.Fn) or "",
								tostring(p.Method), table.concat(p.Args or {}, ", "), p.Copies > 1 and (", and "..(p.Copies - 1).." copies") or "")
						end
						if #group[2] > 30 then lines[#lines+1] = ("    and %d more"):format(#group[2] - 30) end
					end
				end
				if #matched > 10 then lines[#lines+1] = ("and %d more remotes have that in their path: give more of it"):format(#matched - 10) end
				return table.concat(lines, "\n")
			end)

			reg("usage", function(args)
				local scr = h.scriptFor(args.script)
				local note = ready(true)
				local lines = {h.whereIs(scr)}
				if note then lines[#lines+1] = note end

				if type(args.member) == "string" and args.member ~= "" then
					if not scr:IsA("ModuleScript") then error("member is for a ModuleScript: the uses of one of its functions or fields in the scripts that require it", 0) end
					local users = Tools.usersOf(scr, args.member)
					lines[#lines+1] = ("%s.%s is used in %d place%s of the other scripts%s"):format(scr.Name, args.member, #users, #users == 1 and "" or "s", #users > 100 and " (the first 100)" or "")
					for i = 1, math.min(#users, 100) do
						local u = users[i]
						lines[#lines+1] = ("  %s  %s (%s) line %d: %s"):format(u.Write and "write" or (u.Call and "call" or "read"), fullName(u.Script), Agent.IdOf(u.Script), u.Line, lineOf(u.Entry.Text, u.Line):sub(1, 160))
					end
					return table.concat(lines, "\n")
				end

				local reqs = Analysis.Requires(h.analysisOf(h.rawOf(scr)))
				lines[#lines+1] = ("Requires (%d):"):format(#reqs)
				for i = 1, math.min(#reqs, 100) do
					local req = reqs[i]
					local inst = req.path.root and resolveInstance(req.path, scr)
					local what
					if typeof(inst) == "Instance" and inst:IsA("LuaSourceContainer") then
						what = ("%s (%s)"):format(fullName(inst), Agent.IdOf(inst))
					else
						what = req.path.text..(inst and "  (not a script)" or "  (not found in the game now)")
					end
					lines[#lines+1] = ("  line %d: %s"):format(req.line, what)
				end
				local by = requiredBy(scr)
				lines[#lines+1] = ("Required by (%d of the %d scripts read):"):format(#by, countRead())
				for i = 1, math.min(#by, 100) do
					lines[#lines+1] = ("  %s (%s) line %d"):format(fullName(by[i].Script), Agent.IdOf(by[i].Script), by[i].Line)
				end
				return table.concat(lines, "\n")
			end)

			reg("changes", function(args)
				local note = ready(false)
				local c = state.Changes
				-- (why there is nothing to compare, as the Changes page says it)
				local function none()
					return note or state.ChangesNote or (state.Baseline and "Read the scripts to compare them." or (state.Scanned and "There is no earlier read of this place to compare with. The next session will have this one." or "The scripts are compared with the last session's once they have been read."))
				end

				if args.script ~= nil then
					local scr = h.scriptFor(args.script)
					if not c then error(none(), 0) end
					local key
					for _,k in ipairs(c.changed) do
						if state.KeyScript[k] == scr then key = k break end
					end
					if not key then error("that script is not one of the changed ones (changes without a script lists them)", 0) end
					local entry = memory[scr]
					if not entry then error("that script was not read (it could not be decompiled)", 0) end
					local old = D.cachedRead(state.Baseline[key])
					if not old then error("the old version is no longer on disk", 0) end
					local text, _, stats = Analysis.DiffText(old, entry.Text, 3, not Tools.ExactDiff)
					if stats.added == 0 and stats.removed == 0 then
						return ("%s: the two versions differ only in the names of local variables"):format(h.whereIs(scr))
					end
					if #text > 40000 then text = text:sub(1, 40000).."\n... cut here: the difference is longer" end
					return ("%s, last time vs now: %d lines added, %d removed%s\n%s"):format(h.whereIs(scr), stats.added, stats.removed, Tools.ExactDiff and "" or " (names of local variables ignored)", text)
				end

				if not c then return {note = none()} end
				local limit = math.clamp(math.floor(tonumber(args.limit) or 100), 1, 500)
				local out = {comparedWith = state.BaselineTime and os.date("%Y-%m-%d %H:%M", state.BaselineTime) or nil, note = note,
					counts = {changed = #c.changed, added = #c.added, removed = #c.removed}, changed = {}, added = {}, removed = {}}
				for _,kind in ipairs({"changed", "added"}) do
					for i = 1, math.min(#c[kind], limit) do
						local scr = state.KeyScript[c[kind][i]]
						out[kind][i] = {path = c[kind][i], script = scr and Agent.IdOf(scr) or nil}
					end
				end
				for i = 1, math.min(#c.removed, limit) do out.removed[i] = c.removed[i] end
				return out
			end)
		end
	end

	do

		----------------------------------------------------------------------------------------------
		-- Hovering a token: what is known about it
		----------------------------------------------------------------------------------------------

		local function securityText(sec)
			if type(sec) == "table" then
				if sec.Read == sec.Write then return tostring(sec.Read) end
				return ("read %s, write %s"):format(tostring(sec.Read), tostring(sec.Write))
			end
			return sec and tostring(sec) or nil
		end

		local function tagText(tags)
			local list = {}
			for tag in pairs(tags or {}) do list[#list+1] = tag end
			table.sort(list)
			return #list > 0 and table.concat(list, ", ") or nil
		end

		-- A member of a Roblox class, from the API dump.
		local function describeMember(info)
			local m = info.member
			local lines = {}
			local function add(text) if text then lines[#lines+1] = text end end
			local title
			if info.kind == "property" then
				title = ("%s.%s: %s"):format(info.class, m.Name, m.ValueType and m.ValueType.Name or "?")
				add("Property"..(info.declared ~= info.class and (" of "..info.declared) or "")..(m.Category and (", "..m.Category) or ""))
			elseif info.kind == "function" then
				local params = {}
				for _,p in ipairs(m.Parameters or {}) do params[#params+1] = p.Name..": "..p.Type end
				title = ("%s:%s(%s) -> %s"):format(info.class, m.Name, table.concat(params, ", "), m.ReturnType or "?")
				add("Method"..(info.declared ~= info.class and (" of "..info.declared) or ""))
			else
				local params = {}
				for _,p in ipairs(m.Parameters or {}) do params[#params+1] = p.Name..": "..p.Type end
				title = ("%s.%s(%s)"):format(info.class, m.Name, table.concat(params, ", "))
				add("Event: use :Connect(function(...) end)"..(info.declared ~= info.class and (" (of "..info.declared..")") or ""))
			end
			local security = securityText(m.Security)
			add(security and security ~= "None" and ("Security: "..security) or nil)
			add(tagText(m.Tags) and ("Tags: "..tagText(m.Tags)) or nil)
			return {Title = title, Lines = lines}
		end

		local function describeNumber(text)
			local v = Analysis.NumberValue(text)
			if not v then return nil end
			local lines = {}
			if v == math.floor(v) and math.abs(v) < 2^53 then
				if v >= 0 then
					lines[#lines+1] = ("%d = 0x%X"):format(v, v)
					if v <= 0xFFFFFF then lines[#lines+1] = ("Color3.fromRGB(%d, %d, %d)"):format(v // 65536, v // 256 % 256, v % 256) end
					if v >= 1.2e9 and v <= 2.5e9 then
						local ok, date = pcall(os.date, "!%Y-%m-%d %H:%M UTC", v)
						if ok then lines[#lines+1] = "As a time: "..date end
					end
				end
			end
			if #lines == 0 then return nil end
			return {Title = text, Lines = lines}
		end

		local function describeFunction(R, f)
			local counts = {}
			if not R.remoteList then R.remoteList = Analysis.Remotes(R) end
			for _,r in ipairs(R.remoteList) do
				if r.fn == f and r.kind ~= "listen" then counts[r.kind] = (counts[r.kind] or 0) + 1 end
			end
			local reach = {}
			for kind,n in pairs(counts) do reach[#reach+1] = ("%s x%d"):format(kind, n) end
			table.sort(reach)
			local lines = {("Lines %d-%d"):format(f.line1, f.line2)}
			if #reach > 0 then lines[#lines+1] = "Makes: "..table.concat(reach, ", ") end
			return {Title = Analysis.Signature(R, f), Lines = lines}
		end

		-- What to tell about token ti under the pointer: {Title, Lines}, or nil when there is nothing to say.
		Tools.infoFor = function(R, ti)
			local kind = R.tt[ti]
			if kind == "num" then return describeNumber(R.tv[ti]) end
			local inst = Tools.instanceAt(R, ti)
			if inst then return {Title = inst.ClassName.." "..Tools.fullName(inst), Lines = {"Ctrl+click selects it in the Explorer"}} end
			if kind ~= "name" then return nil end

			-- the method of a remote or http call: where it points
			local node = R.members[ti]
			if node and node.k == "Call" and node.kind then
				local path = Analysis.ResolvePath(R, node.fn)
				local scr = currentScript()
				local inst = scr and resolveInstance(path, scr)
				local lines = {}
				if path.root then
					lines[1] = typeof(inst) == "Instance" and ("Exists now: "..inst.ClassName.." "..Tools.fullName(inst)) or "Not found right now"
				end
				return {Title = ("%s %s"):format(R.tv[ti], path.text), Lines = lines}
			end

			local member = API and Analysis.MemberAt(R, ti, API.Classes)
			if member then return describeMember(member) end

			local sym = R.symAt[ti]
			local f = sym and sym.fn
			if not f and not sym then
				for _,g in ipairs(R.functions) do
					if g.parent and Analysis.ShortName(g) == R.tv[ti] then f = g break end
				end
			end
			if f then return describeFunction(R, f) end
			if sym and sym.init and API then
				local cls = Analysis.ClassOf(R, sym.init, API.Classes)
				local init = Analysis.Text(R, sym.init.s, sym.init.e, 60)
				return {Title = cls and ("%s: %s"):format(sym.name, cls) or sym.name, Lines = {"= "..init}}
			end
			return nil
		end
	end

	----------------------------------------------------------------------------------------------
	-- Menus (the toolbar's and the editor's right-click menu) and the actions behind them
	----------------------------------------------------------------------------------------------

	-- Why an action that needs a script can't run right now, or false.
	local function needsScript()
		local tab = tabs[activeTab]
		if not tab then return "Open a script first" end
		if tab.Kind ~= "script" then return tab.Kind == "diff" and "Not available in a diff" or "Not available for captured code" end
		if tab.Loading then return "Still decompiling" end
		if tab.Failed then return "There is no source for this script" end
		return false
	end

	-- Why the running script can't be inspected right now, or false.
	local function liveReason()
		if not env.getgc then return "Your executor has no getgc" end
		if not currentScript() then return "Open a decompiled script first" end
		return false
	end

	local function copyAll()
		env.setclipboard(codeFrame:GetText())
		toast("Copied to the clipboard")
	end

	local function saveFile()
		local source = codeFrame:GetText()
		local filename = "Place_"..game.PlaceId.."_Script_"..os.time()..".txt"
		Lib.SaveAsPrompt(filename, source)
	end

	local function executeText()
		local fn, err = env.loadstring(codeFrame:GetText())
		if not fn then toast("Can't run it: "..tostring(err), "error") return end
		local ok, runErr = pcall(fn)
		if not ok then toast("The script errored: "..tostring(runErr), "error") end
	end

	-- A menu object kept between openings and cleared each time, so its items follow the viewer's state.
	local function freshMenu(menu, width)
		menu = menu or Lib.ContextMenu.new()
		menu.Iconless = true
		menu.Width = width
		menu.MaxHeight = 420
		menu:Clear()
		return menu
	end

	-- Under a button of the toolbar; over one of the status bar (the menu opens upwards from that y).
	local function showUnder(menu, button)
		local y = button.AbsolutePosition.Y
		menu:Show(button.AbsolutePosition.X, button.Parent == Nav.statusBar and y or (y + button.AbsoluteSize.Y))
	end

	local fileMenu, decompilerMenu, codeMenu

	local function showFileMenu(button)
		fileMenu = freshMenu(fileMenu, 190)
		fileMenu:Add({Name = "Copy to Clipboard", Disabled = env.setclipboard == nil, Reason = "Your executor has no setclipboard", OnClick = copyAll})
		fileMenu:Add({Name = "Save to File...", Disabled = env.writefile == nil, Reason = "Your executor has no writefile", OnClick = saveFile})
		showUnder(fileMenu, button)
	end

	local function decompilerItems()
		local tab = tabs[activeTab]
		local names = decompilerNames()
		local noRaw = "There is no decompile to compare yet"
		local with, against = {}, {}
		for _,name in ipairs(names) do
			with[#with+1] = {Name = name..(name == tab.Decompiler and "  (in use)" or ""), OnClick = function() redecompile(name) end}
			if name ~= tab.Decompiler then
				against[#against+1] = {Name = "The decompile by "..name, OnClick = function() diffAgainst(name) end}
			end
		end
		local okPrev, hasPrev = pcall(function() return env.isfile(annPath(tab.Script)..".prev.lua") end)
		against[#against+1] = {Name = "The previous version", Disabled = not (okPrev and hasPrev), Reason = "No earlier version is kept yet (one is kept when the script has changed between two visits)", OnClick = diffPrevious}
		against[#against+1] = {Name = "The snapshot", OnClick = diffSnapshot}
		for _,other in ipairs(tabs) do
			if other ~= tab and other.Kind == "script" and other.Raw then
				against[#against+1] = {Name = "The tab "..Nav.tabLabel(other):sub(1, 30), OnClick = function() diffTab(other) end}
			end
		end
		return {
			{Name = "Decompile with", Submenu = with},
			{Name = "Diff against", Disabled = not tab.Raw, Reason = noRaw, Submenu = against},
			{Divider = true},
			{Name = "Save snapshot", Disabled = not tab.Raw, Reason = "There is no decompile to save yet", OnClick = saveSnapshot},
			{Name = (Tools.ExactDiff and "[x]" or "[  ]").." Diffs compare the names of locals", Tooltip = "Not ticked: lines that differ only in the names of local variables count as equal, so two decompilers or two versions can be compared", OnClick = function()
				Tools.ExactDiff = not Tools.ExactDiff
				toast(Tools.ExactDiff and "Diffs now compare local names too" or "Diffs now ignore the names of local variables")
			end},
		}
	end

	-- Adds items ({Name, OnClick, ...} or {Divider = true}) to a menu.
	local function addItems(menu, items)
		for _,item in ipairs(items) do
			if item.Divider then menu:AddDivider(item.Text) else menu:Add(item) end
		end
	end

	local function showDecompilerMenu(button)
		decompilerMenu = freshMenu(decompilerMenu, 230)
		local scriptReason = needsScript()
		if scriptReason or #decompilerNames() == 0 then
			decompilerMenu:Add({Name = "Decompile again", Disabled = true, Reason = scriptReason or "No decompiler is available"})
		else
			addItems(decompilerMenu, decompilerItems())
		end
		showUnder(decompilerMenu, button)
	end

	-- Text for a menu label, cut short.
	local function clip(text, max)
		text = text:gsub("%s+", " ")
		return #text > max and (text:sub(1, max - 3).."...") or text
	end

	-- The editor's right-click menu: navigate, annotate and, for the running script, trace the function
	-- around what is selected or under the pointer. (Upvalues and constants are edited on the code itself:
	-- hover a mark.) A click inside the selection keeps it (the menu is then about the selected name,
	-- string or number); anywhere else it moves the cursor there, as a left click does. The labels say
	-- what they act on.
	local function showCodeMenu()
		local cellX, cellY = codeFrame:MouseCell() -- the character that was clicked
		local y = math.clamp(cellY, 0, #codeFrame.Lines - 1)
		local x = math.clamp(cellX, 0, #codeFrame.Lines[y + 1])
		if codeFrame:IsValidRange() then
			local from, to = codeFrame.SelectionRange[1], codeFrame.SelectionRange[2]
			local inside = (y > from[2] or (y == from[2] and x >= from[1])) and (y < to[2] or (y == to[2] and x < to[1]))
			if not inside then codeFrame.SelectionRange = {{-1,-1},{-1,-1}} end
		end
		local selecting = codeFrame:IsValidRange()
		if not selecting then
			codeFrame:MoveCursor(x, y)
			codeFrame.FloatCursorX = x
		end

		codeMenu = freshMenu(codeMenu, 290)
		local menu = codeMenu
		local R, why = tabAnalysis()
		local scriptReason = needsScript()
		local line = cursorLine()
		-- the selected token, else the one the click was on: the one the outline showed, not the one just before it
		local ti
		if R then
			if selecting then
				ti = targetToken(R)
			elseif cellY == y then
				ti = Analysis.TokenAtCell(R, y + 1, cellX)
			end
		end
		local kind = ti and R.tt[ti]
		local sym = ti and R.symAt[ti]

		if codeFrame:IsValidRange() then
			local selected = codeFrame:GetSelectionText()
			menu:Add({Name = "Copy", Disabled = env.setclipboard == nil, Reason = "Your executor has no setclipboard", OnClick = function()
				env.setclipboard(selected)
				toast("Copied the selection")
			end})
		end

		menu:AddDivider("Navigate")
		local noName = (not R and why) or (kind ~= "name" and "Right-click a name") or false
		menu:Add({Name = "Go to definition   Ctrl+click", Disabled = noName ~= false or not Analysis.Definition(R, ti), Reason = noName or "Nothing in this script defines it", OnClick = gotoDefinition})
		menu:Add({Name = "Find references", Disabled = noName ~= false, Reason = noName or nil, OnClick = function() showReferences() end})
		menu:Add({Name = "Find writes (assignments)", Disabled = noName ~= false, Reason = noName or nil, OnClick = function() showReferences(true) end})
		local okInst, inst = pcall(Tools.instanceAt, R, ti) -- (fails with no analysis or no token)
		if okInst and inst then
			menu:Add({Name = ("Select %s in Explorer   Ctrl+click"):format(clip(inst.Name, 22)), OnClick = function() Explorer.SelectObj(inst) end})
		end
		-- what to look for in every script: the selection, else the name or string clicked
		local searchFor
		if selecting then
			local selected = codeFrame:GetSelectionText()
			if selected ~= "" and not selected:find("\n") and #selected <= 100 then searchFor = selected end
		end
		if not searchFor and ti then
			if kind == "name" then searchFor = R.tv[ti] elseif kind == "str" then searchFor = Analysis.StringValue(R, ti) end
		end
		menu:Add({Name = searchFor and ('Find "%s" in all scripts'):format(clip(searchFor, 22)) or "Search all scripts...", OnClick = function() Tools.openSearch(searchFor or "") end})

		menu:AddDivider("Annotate")
		local isLocal = sym and sym.decl
		local renameReason = scriptReason or (kind ~= "name" and "Right-click a variable") or (not isLocal and "Only local variables and parameters can be renamed") or false
		menu:Add({Name = isLocal and ("Rename '%s'..."):format(clip(sym.name, 20)) or "Rename variable...", Disabled = renameReason ~= false, Reason = renameReason or nil, OnClick = renameSymbol})
		local note = scriptReason == false and noteOn(line) or ""
		menu:Add({Name = (note ~= "" and "Edit the note on line " or "Add a note to line ")..line, Disabled = scriptReason ~= false, Reason = scriptReason or nil, Tooltip = "Or click the line and type", OnClick = function() addNote() end})
		if note ~= "" then
			menu:Add({Name = "Remove the note", OnClick = function() setNote(line, "") end})
		end

		if scriptReason == false then
			menu:AddDivider("Running script")
			local live = liveReason() or (not R and why) or false
			if live then
				menu:Add({Name = "Trace calls", Disabled = true, Reason = live})
			else
				-- the function the name stands for, else the one the cursor is in
				local F
				if kind == "name" then
					if sym then
						F = sym.fn
					else
						for _,f in ipairs(R.functions) do
							if f.parent and Analysis.ShortName(f) == R.tv[ti] then F = f break end
						end
					end
				end
				if not F then
					local around = Analysis.FunctionAtLine(R, line)
					F = around.parent and around or nil
				end
				if F then
					local short = Analysis.ShortName(F)
					if short then
						local tracing = Live.isTracing(short)
						menu:Add({Name = (tracing and "Stop tracing " or "Trace calls to ")..clip(short, 26), Disabled = env.hookfunction == nil, Reason = "Your executor has no hookfunction", Tooltip = "Logs every call to it with its arguments, in the Live tab", OnClick = function() Live.traceFunction(R, F, tracing) end})
						if tracing then
							menu:Add({Name = "Force a return value, change arguments, stop at calls...", Tooltip = "The options of the tracepoint on "..short, OnClick = function() Live.editTrace(short) end})
						end
					end
				end
			end
		end

		menu:Show()
	end

	-- The menus of the toolbar's "where the cursor is": the script's, the list of its functions (with a
	-- search box), and the places Back can return to.
	Nav.scriptMenu = function(tab, button)
		Nav.menu = freshMenu(Nav.menu, 240)
		local isScript = tab.Kind == "script"
		local why = isScript and needsScript() or "Only for a script of the game"
		Nav.menu:Add({Name = "Copy script path", Disabled = not isScript or env.setclipboard == nil, Reason = isScript and "Your executor has no setclipboard" or why, OnClick = function()
			env.setclipboard(tab.Path or getPath(tab.Script))
			toast("Copied the script's path")
		end})
		Nav.menu:Add({Name = "Select in Explorer", Disabled = not isScript, Reason = why, OnClick = function() Explorer.SelectObj(tab.Script) end})
		Nav.menu:AddDivider()
		Nav.menu:Add({Name = "Scripts it requires", Disabled = why ~= false, Reason = why or nil, OnClick = function() Tools.showRequires() end})
		Nav.menu:Add({Name = "Scripts that require it", Disabled = why ~= false, Reason = why or nil, OnClick = function() Tools.showRequiredBy() end})
		Nav.menu:Add({Name = "Graph of the modules around it", Disabled = why ~= false, Reason = why or nil, OnClick = function() Tools.showModules() end})
		showUnder(Nav.menu, button)
	end

	Nav.pickFunction = function(button)
		local R, why = tabAnalysis()
		if not R then toast(why, "warn") return end
		Nav.fnMenu = freshMenu(Nav.fnMenu, 320)
		Nav.fnMenu.SearchEnabled = true
		for _,entry in ipairs(functionEntries(R)) do
			Nav.fnMenu:Add({Name = entry.label, OnClick = function() jumpTo(entry.fn.line1, 0) end})
		end
		showUnder(Nav.fnMenu, button)
	end

	Nav.showHistory = function(button)
		if #backStack == 0 then return end
		Nav.menu = freshMenu(Nav.menu, 360)
		for steps = 1, math.min(15, #backStack) do
			Nav.menu:Add({Name = clip(Nav.place(backStack[#backStack - steps + 1]), 60), OnClick = function() Nav.backTo(steps) end})
		end
		showUnder(Nav.menu, button)
	end

	----------------------------------------------------------------------------------------------
	-- Command palette: the viewer's actions, listed with what the state of the viewer allows
	----------------------------------------------------------------------------------------------

	local function getCommands()
		local list = {}
		local function add(name, run, disabled)
			list[#list+1] = {Name = name, Category = "Script Viewer", Disabled = disabled or false, Run = function()
				window:Show()
				run()
			end}
		end

		local scriptReason = needsScript()
		local live = liveReason()
		local tab = tabs[activeTab]

		add("Find in script", openFind)
		add("Go to line", function() openBar("line", "") end)
		add(flowOpen and "Hide graph pane" or "Show graph pane", function() setFlowOpen(not flowOpen) end, not Flowchart and "The flowchart module is not loaded")
		add(sideOpen and "Hide navigator" or "Show navigator", function() setSideOpen(not sideOpen) end)
		add("Flowchart of the current function", function() showFlow() end, scriptReason)
		add("Call graph of the script", showCallGraph, scriptReason)
		for _,scope in ipairs(SCOPES) do
			for _,key in ipairs(scope.Pages) do
				add(("Navigator: %s > %s"):format(scope.Title, rootPages[key].Chip), function() openPage(key) end)
			end
		end
		add("Next row of the list in the navigator", function() Nav.step(1) end)
		add("Previous row of the list in the navigator", function() Nav.step(-1) end)

		add("Go to definition", gotoDefinition)
		add("Find references", function() showReferences() end)
		add("Find writes (assignments)", function() showReferences(true) end)
		add("Rename variable", renameSymbol, scriptReason)
		add("Add or edit note", function() addNote() end, scriptReason)
		add("Back to the previous location", navBack)
		add("Forward to the next location", navForward)

		add("Copy script to clipboard", copyAll, env.setclipboard == nil and "Your executor has no setclipboard")
		add("Save script to file", saveFile, env.writefile == nil and "Your executor has no writefile")
		add("Execute script", executeText, env.loadstring == nil and "Your executor has no loadstring")
		add("Rescan the running functions", function() Live.rescan() end, live)
		add("Trace log", function() Live.showTrace() end, env.hookfunction == nil and "Your executor has no hookfunction")
		add("Watch list", function() Live.showWatch() end)
		add("Value scanner", function() Live.showScanner() end, live or (env.getupvalues == nil and "Your executor has no getupvalues"))
		add(Live.coverageOn() and "Stop counting calls" or "Count which functions run", function() Live.toggleCoverage() end, live or (env.hookfunction == nil and "Your executor has no hookfunction"))
		add("The value this module returned", function() Live.showModule() end, live)

		add("Search all scripts", function() Tools.openSearch("") end)
		add("Suggest names for the variables", function() Tools.suggestNames() end, scriptReason)
		add("Graph of the modules around this script", function() Tools.showModules() end, scriptReason)
		add("Scripts this script requires", function() Tools.showRequires() end, scriptReason)
		add("Scripts that require this script", function() Tools.showRequiredBy() end, scriptReason)

		if tab then
			add("Close tab", function() closeTabObject(tab) end)
			add("Close other tabs", function()
				for i = #tabs, 1, -1 do
					if tabs[i] ~= tab then closeTab(i) end
				end
			end, #tabs < 2 and "This is the only tab")
			add("Next tab", function() Nav.switchTab(activeTab % #tabs + 1) end, #tabs < 2 and "This is the only tab")
		end
		add("Reopen closed tab", function() Nav.reopenTab() end, #Nav.closed == 0 and "No tab was closed")

		if tab and tab.Kind == "script" then
			for _,name in ipairs(decompilerNames()) do
				add("Decompile with "..name, function() redecompile(name) end, scriptReason)
				if name ~= tab.Decompiler then
					add("Diff against "..name, function() diffAgainst(name) end, scriptReason or (not tab.Raw and "There is no decompile to compare yet"))
				end
			end
			add("Save snapshot of this decompile", saveSnapshot, not tab.Raw and "There is no decompile to save yet")
			add("Diff against the saved snapshot", diffSnapshot, not tab.Raw and "There is no decompile to compare yet")
			add("Diff against the previous version", diffPrevious, not tab.Raw and "There is no decompile to compare yet")
		end

		-- every function of the open script, and every script of the game
		local R = not scriptReason and tabAnalysis()
		if R then
			for _,o in ipairs(Analysis.Outline(R)) do
				if o.fn.parent then add("Go to: "..o.name:sub(1, 60), function() jumpTo(o.line1, 0) end) end
			end
		end
		for _,scr in ipairs(Tools.scriptList()) do
			add("Open script: "..Tools.fullName(scr), function() ScriptViewer.ViewScript(scr) end)
		end

		-- what the scripts of the game say together
		add("Remote map of the game", function() Tools.openRemoteMap("") end)
		add("Scripts by what they contain", function() openPage("contents") end)
		add("Changed since last time", function() openPage("changes") end)
		add("Scripts that could not be decompiled", function() Tools.showFailed() end)
		add("Scan settings: scripts left out, the decompile cache", function() Tools.showScanSettings() end)
		local okFns, functions = pcall(Tools.functions) -- (a failure here must not take the viewer's other commands with it)
		if not okFns then functions = {} end
		if not Tools.indexComplete() then -- the functions of the scripts parsed so far are listed below; this parses the rest
			add("Go to a function in any script (parses all scripts first)", function()
				Tools.index()
				toast("Parsing the scripts. Open the palette again when it is done: it will list all their functions")
			end)
		end
		for _,f in ipairs(functions) do
			add("Go to function: "..f.Label, function() ScriptViewer.ViewScript(f.Script, f.Line) end)
		end
		return list
	end

	----------------------------------------------------------------------------------------------
	-- Toolbar state and the status bar
	----------------------------------------------------------------------------------------------

	-- A toolbar button's look: lit while the pane or bar it toggles is open, a hover tint otherwise.
	local function paintToolButton(info)
		info.Gui.BackgroundColor3 = info.Active and Settings.Theme.ListSelection or Settings.Theme.ButtonHover
		info.Gui.BackgroundTransparency = (info.Active or info.Hover) and 0 or 1
	end

	refreshToolbar = function()
		if not toolToggles.find then return end
		toolToggles.find.Active = Nav.findOpen and Nav.findMode == "find"
		toolToggles.flow.Active = flowOpen
		toolToggles.side.Active = sideOpen
		for _,info in pairs(toolToggles) do paintToolButton(info) end
	end

	local lastStatus = {}
	local function setStatus(key, text)
		if lastStatus[key] == text then return end
		lastStatus[key] = text
		statusParts[key].Text = text
	end

	-- Where the cursor is, in the toolbar: the script, then the functions around the cursor from the
	-- outside in, each one a button, and the list of the script's functions at the end. Drawn again only
	-- when one of them, or the room there is for them, has changed.
	Nav.paintCrumbs = function()
		local bar = Nav.crumbBar
		local tab = tabs[activeTab]
		local R, fn = Nav.crumbR, Nav.crumbFn
		local width = bar.AbsoluteSize.X
		local key = table.concat({tostring(tab), tab and Nav.tabLabel(tab) or "", tostring(R), tostring(fn), width}, ":")
		if key == Nav.crumbKey then return end
		Nav.crumbKey = key
		bar:ClearAllChildren()
		if not tab then return end

		local parts = {}
		local head = tab.Short or tab.Name
		if tab.Kind == "script" then
			local ok, parent = pcall(function() return tab.Script.Parent end)
			if ok and parent then head = parent.Name.." > "..tab.Name end
		end
		parts[1] = {Text = head, Tip = (tab.Path or tab.Name).."   (click for more)", OnClick = function(btn) Nav.scriptMenu(tab, btn) end}
		local pickable = R ~= nil and tab.Kind ~= "diff"
		if pickable and fn then
			while fn and fn.parent do
				local f = fn
				table.insert(parts, 2, {Text = clip(Analysis.Signature(R, f), 44), Tip = "Go to the start of this function (line "..f.line1..")", OnClick = function() jumpTo(f.line1, 0) end})
				fn = fn.parent
			end
		end
		for _,p in ipairs(parts) do p.Width = math.ceil(Nav.textWidth(p.Text)) + 10 end

		-- what does not fit goes from the front: the function the cursor is in says the most
		local SEP, PICK, MORE = 14, 20, 18
		local function room(first)
			local total = (first > 1 and MORE or 0) + (pickable and PICK or 0)
			for i = first, #parts do total = total + parts[i].Width + (i > first and SEP or 0) end
			return total
		end
		local first = 1
		while first < #parts and room(first) > width do first = first + 1 end

		local x = 0
		local function label(text, w)
			newLabel(bar, text, UDim2.new(0,x,0,0), UDim2.new(0,w,1,0), GREY).TextXAlignment = Enum.TextXAlignment.Center
			x = x + w
		end
		if first > 1 then label("...", MORE) end
		for i = first, #parts do
			local p = parts[i]
			if i > first then label(">", SEP) end
			local btn = createSimple("TextButton", {
				BackgroundColor3 = Settings.Theme.Main2,
				BorderSizePixel = 0,
				Position = UDim2.new(0,x,0,3),
				Size = UDim2.new(0,p.Width,1,-7),
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = i == #parts and WHITE or GREY,
				Text = p.Text,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = bar,
			})
			btn.MouseButton1Click:Connect(function() p.OnClick(btn) end)
			Lib.Tooltip.attach(btn, p.Tip)
			x = x + p.Width
		end
		if pickable then
			local pick = createSimple("TextButton", {BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, Position = UDim2.new(0,x + 2,0,3), Size = UDim2.new(0,PICK - 2,1,-7), Text = "", Parent = bar})
			local arrow = Lib.CreateArrow(9, 4, "down")
			arrow.Position = UDim2.new(0.5,-5,0.5,-4)
			arrow.Parent = pick
			pick.MouseButton1Click:Connect(function() Nav.pickFunction(pick) end)
			Lib.Tooltip.attach(pick, "Every function of this script: type to search, click to go there")
		end
	end

	-- The toolbar's Back and Forward and where the cursor is; in the status bar the cursor's line and
	-- column, the selection, the reading of the scripts or the running script, and how the script was
	-- decompiled and analysed.
	updateStatus = function()
		if not statusParts.pos then return end
		local tab = tabs[activeTab]

		Nav.backBtn.Gui.TextColor3 = #backStack > 0 and WHITE or Settings.Theme.PlaceholderText
		Nav.fwdBtn.Gui.TextColor3 = #fwdStack > 0 and WHITE or Settings.Theme.PlaceholderText
		Nav.paintCrumbs()

		setStatus("pos", ("Ln %d, Col %d"):format(codeFrame.CursorY + 1, codeFrame.CursorX + 1))

		local selection = ""
		if codeFrame:IsValidRange() then
			local range = codeFrame.SelectionRange
			if range[1][2] == range[2][2] then
				selection = ("Sel %d"):format(range[2][1] - range[1][1])
			else
				selection = ("Sel %d lines"):format(range[2][2] - range[1][2] + 1)
			end
		end
		setStatus("sel", selection)

		local decompiler, state = "", ""
		if tab then
			if tab.Kind == "script" then
				decompiler = tab.Loading and "Decompiling..." or (tab.Failed and "No source") or (tab.Decompiler or "Default decompiler")
				state = "Analysis: "..(tab.AnState or "not run")
			elseif tab.Kind == "chunk" then
				decompiler, state = "Captured code", "Analysis: "..(tab.AnState or "not run")
			else
				decompiler = "Diff"
			end
		end
		setStatus("decompiler", decompiler)
		setStatus("state", state)
		local work = Tools.scanStatus() -- reading or parsing the scripts of the game, whatever tab is open
		setStatus("live", work ~= "" and work or (tab and tab.Kind == "script" and Live.statusText() or ""))
	end

	ScriptViewer.Init = function()
		window = Lib.Window.new()
		window:SetTitle("Script Viewer")
		window:SetLayoutId("Notepad")
		window:SetFill(true) -- the whole screen but the side panels, so the flowchart and sidebar stay docked in view
		ScriptViewer.Window = window

		local content = window.GuiElems.Content
		local uis = service.UserInputService

		-- what was open last time, and how the panes were sized
		local saved = Main.Layout.Extra("Notepad")
		if type(saved) == "table" then
			if saved.flow ~= nil then flowOpen = saved.flow and true or false end
			if tonumber(saved.ratio) then flowRatio = math.clamp(saved.ratio, 0.2, 0.8) end
			if saved.side ~= nil then sideOpen = saved.side and true or false end
			if type(saved.skip) == "table" then
				for key in pairs(Tools.Skip) do
					if saved.skip[key] ~= nil then Tools.Skip[key] = saved.skip[key] and true or false end
				end
			end
			-- (the pages had other names before the navigator had scopes)
			local page = ({live = "trace", scripts = "search"})[saved.tab] or saved.tab
			if Nav.scopeOf[page] then sideTab = page end
			if tonumber(saved.width) then Nav.W = math.clamp(saved.width, SIDE_MIN, 800) end
		end
		if not Flowchart then flowOpen = false end
		-- no script is open yet: the Game pages are where one is found. The page chosen comes back with the first script.
		if Nav.scopeOf[sideTab] == "script" and sideTab ~= "refs" then
			Nav.home, sideTab, Nav.auto = sideTab, "search", true
		end
		Main.Layout.Providers.Notepad = function()
			return {flow = flowOpen, ratio = flowRatio, side = sideOpen, tab = Nav.auto and Nav.home or sideTab, width = Nav.W, skip = table.clone(Tools.Skip)}
		end
		table.insert(Main.Layout.ResetHandlers, function()
			flowOpen, flowRatio, sideOpen = Flowchart ~= nil, 0.45, true
			Nav.W = 320
			for key in pairs(Tools.Skip) do Tools.Skip[key] = true end
			relayout()
			refreshFlow()
			refreshSidebar(true)
		end)

		-- Toolbar: Back, Forward, where the cursor is | Find, Navigator, Graph | File, Execute, Decompiler
		Nav.toolbar = createSimple("Frame", {Name = "Toolbar", BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, Size = UDim2.new(1,0,0,TOOL_H), Parent = content})
		createSimple("Frame", {BackgroundColor3 = Settings.Theme.Outline1, BorderSizePixel = 0, Position = UDim2.new(0,0,1,-1), Size = UDim2.new(1,0,0,1), Parent = Nav.toolbar})

		local toolX, toolParent = 4, Nav.toolbar
		local function toolButton(text, tip, onClick, isMenu)
			local ok, size = pcall(function()
				return service.TextService:GetTextSize(text, 14, Enum.Font.SourceSans, Vector2.new(400, 20))
			end)
			local width = (ok and size.X or #text * 7) + 20 + (isMenu and 12 or 0)
			local info = {Active = false, Hover = false}
			local btn = createSimple("TextButton", {
				Name = text,
				AutoButtonColor = false,
				BackgroundColor3 = Settings.Theme.ButtonHover,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.new(0,toolX,0,2),
				Size = UDim2.new(0,width,1,-5),
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = WHITE,
				Text = text,
				TextXAlignment = isMenu and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center,
				Parent = toolParent,
			})
			createSimple("UICorner", {CornerRadius = UDim.new(0,3), Parent = btn})
			if isMenu then
				createSimple("UIPadding", {PaddingLeft = UDim.new(0,9), Parent = btn})
				local arrow = Lib.CreateArrow(9, 4, "down")
				arrow.Position = UDim2.new(1,-15,0.5,-4)
				arrow.Parent = btn
			end
			info.Gui = btn
			btn.MouseEnter:Connect(function()
				info.Hover = true
				paintToolButton(info)
			end)
			btn.MouseLeave:Connect(function()
				info.Hover = false
				paintToolButton(info)
			end)
			btn.MouseButton1Click:Connect(function() onClick(btn) end)
			Lib.Tooltip.attach(btn, tip)
			toolX = toolX + width + 2
			return info
		end
		local function toolSeparator()
			createSimple("Frame", {BackgroundColor3 = Settings.Theme.Outline2, BorderSizePixel = 0, Position = UDim2.new(0,toolX + 3,0,5), Size = UDim2.new(0,1,1,-11), Parent = toolParent})
			toolX = toolX + 8
		end

		-- on the left: Back and Forward, greyed when there is nowhere to go (updateStatus)
		Nav.backBtn = toolButton("<", function()
			local loc = backStack[#backStack]
			return loc and ("Back to "..Nav.place(loc).."   (right-click for the places before it)") or "Back: no earlier place"
		end, navBack)
		Nav.backBtn.Gui.MouseButton2Click:Connect(function() Nav.showHistory(Nav.backBtn.Gui) end)
		Nav.fwdBtn = toolButton(">", function()
			local loc = fwdStack[#fwdStack]
			return loc and ("Forward to "..Nav.place(loc)) or "Forward: no later place"
		end, navForward)
		local crumbX = toolX + 6

		-- on the right: the search, the panes, the menus
		local group = createSimple("Frame", {Name = "Right", AnchorPoint = Vector2.new(1,0), BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.new(1,-4,0,0), Size = UDim2.new(0,0,1,0), Parent = Nav.toolbar})
		toolX, toolParent = 0, group
		toolToggles.find = toolButton("Find", "Find in this script", function()
			if Nav.findOpen and Nav.findMode == "find" then closeBar() else openFind() end
		end)
		toolSeparator()
		toolToggles.side = toolButton("Navigator", "Show or hide the navigator: the script's outline, calls, remotes and marks, the running game, and every script of the game", function() setSideOpen(not sideOpen) end)
		toolToggles.flow = toolButton("Graph", "Show or hide the graph pane: a function's flowchart, the call graph, the modules around the script", function() setFlowOpen(not flowOpen) end)
		toolSeparator()
		toolButton("File", "Copy the text or save it to a file", showFileMenu, true)
		local execute = toolButton("Execute", env.loadstring and "Run the text in the viewer" or "Your executor has no loadstring", function()
			if env.loadstring then executeText() end
		end)
		if not env.loadstring then execute.Gui.TextColor3 = Settings.Theme.PlaceholderText end -- greyed, like Back with nowhere to go
		toolButton("Decompiler", "Decompile again with another decompiler, compare two decompiles, snapshots", showDecompilerMenu, true)
		group.Size = UDim2.new(0,toolX,1,0)

		-- between them: where the cursor is (Nav.paintCrumbs)
		Nav.crumbBar = createSimple("Frame", {Name = "Where", BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.new(0,crumbX,0,0), Size = UDim2.new(1,-(crumbX + toolX + 16),1,0), Parent = Nav.toolbar})

		-- The code column: tabs, find bar and editor (relayout places them)
		Nav.leftCol = createSimple("Frame", {Name = "Code", BackgroundTransparency = 1, BorderSizePixel = 0, Parent = content})

		codeFrame = Lib.CodeFrame.new() -- shows text: select, copy and move the cursor, but nothing can be typed
		codeFrame.Frame.Parent = Nav.leftCol
		Live.Init(codeFrame, content)

		-- With no script open the code area says how to open one
		Nav.hint = createSimple("TextLabel", {
			Name = "Hint",
			BackgroundTransparency = 1,
			Position = UDim2.new(0.1,0,0,0),
			Size = UDim2.new(0.8,0,1,0),
			Font = Enum.Font.SourceSans,
			TextSize = 16,
			TextColor3 = GREY,
			TextWrapped = true,
			Text = "No script is open.\n\nRight-click a script in the Explorer and choose View Script,\nopen one by name from Commands in the OpenDex menu,\nor search every script on the Game pages of the navigator.",
			ZIndex = 6,
			Parent = Nav.leftCol,
		})

		-- The box a note is typed in, on its line (addNote), with the marker of a note in front of it
		local noteMarkW = #NOTE_MARK * math.ceil(codeFrame.FontSize / 2)
		Nav.noteBox = createSimple("TextBox", {
			Name = "Note",
			BackgroundColor3 = Settings.Theme.Syntax.Background,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Enum.Font.Code,
			TextSize = codeFrame.FontSize,
			TextColor3 = Settings.Theme.Syntax.Note,
			PlaceholderText = "note: Enter keeps it, Escape does not",
			PlaceholderColor3 = Settings.Theme.PlaceholderText,
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
			Visible = false,
			ZIndex = 6,
			Parent = codeFrame.GuiElems.LinesFrame,
		})
		createSimple("TextLabel", {
			Name = "Mark",
			BackgroundColor3 = Settings.Theme.Syntax.Background,
			BorderSizePixel = 0,
			Position = UDim2.new(0,-noteMarkW,0,0),
			Size = UDim2.new(0,noteMarkW,1,0),
			Font = Enum.Font.Code,
			TextSize = codeFrame.FontSize,
			TextColor3 = Settings.Theme.Syntax.Note,
			Text = NOTE_MARK,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 6,
			Parent = Nav.noteBox,
		})
		Nav.noteBox.FocusLost:Connect(function(_, input)
			local line, tab = Nav.noteLine, Nav.noteTab
			Nav.noteLine, Nav.noteTab = nil, nil
			Nav.noteBox.Visible = false
			if not line or tabs[activeTab] ~= tab or (input and input.KeyCode == Enum.KeyCode.Escape) then return end
			local text = Nav.noteBox.Text:gsub("%c", " "):gsub("%s+$", "")
			if text ~= noteOn(line) then setNote(line, text) end
		end)
		codeFrame.OnTyped = addNote -- typing in the code starts a note on the cursor's line
		codeFrame.OnBackspace = function() addNote(nil, true) end

		-- Right-click on the code: navigate, annotate and look at the running script, for what is under the
		-- pointer. Ctrl+click on what stands for an instance selects it in the Explorer, on another name it
		-- goes to its definition.
		codeFrame.GuiElems.LinesFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				showCodeMenu()
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 and Lib.IsCtrlDown() then
				local tab = tabs[activeTab]
				local R = tab and tab.Kind ~= "diff" and tab.Analysis
				local col, row = codeFrame:MouseCell()
				local ti = R and Analysis.TokenAtCell(R, row + 1, col)
				local ok, inst = pcall(Tools.instanceAt, R, ti)
				if ti and ok and inst then
					Explorer.SelectObj(inst)
				elseif ti and R.tt[ti] == "name" then
					task.defer(gotoDefinition) -- once the editor has put the cursor where the click was
				end
			end
		end)

		-- An outline on the name, string or number under the mouse when right-clicking it offers something: a
		-- name always (definition, references, rename), a string or number when the running script can be
		-- inspected (it is a constant there). It follows the tokens of the last analysis, so after an edit it
		-- keeps away from tokens whose text moved until the script is analysed again. While Ctrl is held a
		-- name is underlined instead: a click then goes to its definition.
		local outline = createSimple("Frame", {Name = "HoverOutline", BackgroundColor3 = Settings.Theme.Info, BackgroundTransparency = 0.88, BorderSizePixel = 0, Visible = false, ZIndex = 5, Parent = codeFrame.GuiElems.LinesFrame})
		local outlineStroke = createSimple("UIStroke", {Color = Settings.Theme.Info, Thickness = 1, Parent = outline})
		createSimple("UICorner", {CornerRadius = UDim.new(0,2), Parent = outline})
		local underline = createSimple("Frame", {Name = "Link", BackgroundColor3 = Settings.Theme.Info, BorderSizePixel = 0, Position = UDim2.new(0,0,1,-2), Size = UDim2.new(1,0,0,2), Visible = false, ZIndex = 5, Parent = outline})

		-- line, column and length of the token to outline, or nothing
		local function tokenUnderMouse()
			local tab = tabs[activeTab]
			if not (Analysis and tab and (tab.Kind == "script" or tab.Kind == "chunk") and not tab.Loading and not tab.Failed) then return end
			if not window:IsContentVisible() or (codeMenu and codeMenu.Gui.Parent) or Live.overCard() then return end
			if uis:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or not Lib.CheckMouseInGui(codeFrame.GuiElems.LinesFrame) then return end

			local col, row = codeFrame:MouseCell()
			local line = row + 1
			local lineText = codeFrame.Lines[line]
			if not lineText or col < 0 or col >= #lineText then return end

			local R = tab.Analysis
			if not R and not tab.AnState then R = tabAnalysis() end -- the first time: analyse now
			if not R then return end
			local ti = Analysis.TokenAtCell(R, line, col)
			if not ti then return end
			local kind = R.tt[ti]
			if kind ~= "name" and not ((kind == "str" or kind == "num") and liveReason() == false) then return end

			local first, last = R.tp[ti], R.te[ti]
			local startCol = first - Analysis.LineStart(R, line)
			if lineText:sub(startCol + 1, startCol + last - first + 1) ~= R.src:sub(first, last) then
				-- the text has changed since the analysis: look again soon, but not on every mouse move
				if os.clock() - (tab.OutlineCheck or 0) > 1 then
					tab.OutlineCheck = os.clock()
					tabAnalysis()
				end
				return
			end
			return line, startCol, last - first + 1, ti, R
		end

		-- A card under a token that has been hovered for a moment: what the API says about a member, where a
		-- remote points, what a function does, what a number is (Tools.infoFor).
		local infoCard = createSimple("Frame", {Name = "InfoCard", BackgroundColor3 = Settings.Theme.Menu, BorderSizePixel = 0, Visible = false, ZIndex = 18, Parent = content})
		createSimple("UIStroke", {Color = Settings.Theme.Outline2, Thickness = 1, Parent = infoCard})
		createSimple("UICorner", {CornerRadius = UDim.new(0,4), Parent = infoCard})
		local infoTitle = newLabel(infoCard, "", UDim2.new(0,8,0,5), UDim2.new(1,-16,0,18), WHITE)
		infoTitle.ZIndex = 19
		local infoBody = newLabel(infoCard, "", UDim2.new(0,8,0,25), UDim2.new(1,-16,0,16), GREY)
		infoBody.ZIndex = 19
		infoBody.TextWrapped = true
		infoBody.TextTruncate = Enum.TextTruncate.None
		infoBody.TextYAlignment = Enum.TextYAlignment.Top
		local INFO_W = 360
		local hoverKey, hoverSince, infoShown

		local function hideInfo()
			if infoShown then
				infoShown = false
				infoCard.Visible = false
			end
		end

		local function showInfo(info, line, startCol)
			local ok, size = pcall(function()
				return service.TextService:GetTextSize(table.concat(info.Lines, "\n"), 14, Enum.Font.SourceSans, Vector2.new(INFO_W - 16, 1000))
			end)
			local bodyH = (#info.Lines > 0 and ok) and size.Y or 0
			infoTitle.Text = info.Title
			infoBody.Text = table.concat(info.Lines, "\n")
			infoBody.Size = UDim2.new(1,-16,0,bodyH)
			local height = 30 + bodyH + (bodyH > 0 and 6 or 0)
			infoCard.Size = UDim2.fromOffset(INFO_W, height)
			local abs, origin, space = codeFrame.GuiElems.LinesFrame.AbsolutePosition, content.AbsolutePosition, content.AbsoluteSize
			local cellW, cellH = math.ceil(codeFrame.FontSize / 2), codeFrame.FontSize
			local x = math.clamp(abs.X + (startCol - codeFrame.ViewX) * cellW - origin.X, 4, math.max(4, space.X - INFO_W - 4))
			local y = abs.Y + (line - codeFrame.ViewY) * cellH - origin.Y -- just under the line
			if y + height > space.Y - 4 then y = abs.Y + (line - 1 - codeFrame.ViewY) * cellH - origin.Y - height end
			infoCard.Position = UDim2.fromOffset(x, math.max(4, y))
			infoCard.Visible = true
			infoShown = true
		end

		-- Called with the token under the mouse (or nothing): after a moment on the same token it gets a card.
		local function updateInfo(line, startCol, ti, R, mark)
			if not line or mark or Live.cardOpen() or uis:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				hoverKey = nil
				hideInfo()
				return
			end
			local key = line..":"..startCol
			if key ~= hoverKey then
				hoverKey, hoverSince = key, os.clock()
				hideInfo()
			elseif hoverSince and not infoShown and os.clock() - hoverSince > 0.45 then
				hoverSince = false -- asked once for this token
				local ok, info = pcall(Tools.infoFor, R, ti)
				if ok and info then showInfo(info, line, startCol) end
			end
		end

		local outlined -- where the outline is now, so it is only moved when that changes
		local function updateOutline()
			local line, startCol, length, ti, R = tokenUnderMouse()
			local mark = line and Live.markAt(line, startCol) or nil
			Live.hover(mark)
			updateInfo(line, startCol, ti, R, mark)
			if not line or mark then -- a mark brightens itself
				if outlined then
					outlined = nil
					outline.Visible = false
				end
				return
			end
			local cellW, cellH = math.ceil(codeFrame.FontSize / 2), codeFrame.FontSize
			local x, y = (startCol - codeFrame.ViewX) * cellW, (line - 1 - codeFrame.ViewY) * cellH
			local link = Lib.IsCtrlDown() and R.tt[ti] == "name" -- a click would go to its definition
			local key = x..":"..y..":"..length..(link and ":link" or "")
			if key == outlined then return end
			outlined = key
			outline.Position = UDim2.fromOffset(x, y)
			outline.Size = UDim2.fromOffset(length * cellW, cellH)
			outline.BackgroundTransparency = link and 1 or 0.88
			outlineStroke.Enabled = not link
			underline.Visible = link
			outline.Visible = true
		end
		Main.Track(uis.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				updateOutline()
			elseif input.UserInputType == Enum.UserInputType.MouseWheel then
				task.defer(updateOutline) -- the editor scrolls after this event
			end
		end))
		Main.Track(uis.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and Live.cardOpen() and not Live.overCard() then Live.hideCard() end
		end))
		-- Every use of the local, parameter or function the cursor is on is tinted in the code and ticked on
		-- the scroll bar (the writes in orange): the quickest way to follow a value through decompiled code.
		local useFrames = {}
		local usesKey, usesName, usesDrawn = false, nil, nil
		Nav.drawUses = function(force)
			local uses = Nav.uses or {}
			local linesFrame = codeFrame.GuiElems.LinesFrame
			local key = #uses == 0 and "none" or table.concat({tostring(usesKey), codeFrame.ViewX, codeFrame.ViewY, linesFrame.AbsoluteSize.X, linesFrame.AbsoluteSize.Y}, ":")
			if key == usesDrawn and not force then return end
			usesDrawn = key
			local cellW, cellH = math.ceil(codeFrame.FontSize / 2), codeFrame.FontSize
			local viewX, viewY = codeFrame.ViewX, codeFrame.ViewY
			local rows = math.ceil(linesFrame.AbsoluteSize.Y / cellH) + 1
			local n = 0
			for _,u in ipairs(uses) do
				local text = u.Line > viewY and u.Line <= viewY + rows and codeFrame.Lines[u.Line]
				-- on screen, and still what the analysis saw
				if text and text:sub(u.Col + 1, u.Col + #usesName) == usesName then
					n = n + 1
					local f = useFrames[n]
					if not f then
						f = createSimple("Frame", {Name = "Use", BorderSizePixel = 0, BackgroundTransparency = 0.78, ZIndex = 3, Parent = linesFrame})
						useFrames[n] = f
					end
					f.BackgroundColor3 = u.Write and Color3.fromRGB(255,170,80) or Color3.fromRGB(200,200,200)
					f.Position = UDim2.fromOffset((u.Col - viewX) * cellW, (u.Line - 1 - viewY) * cellH)
					f.Size = UDim2.fromOffset(#usesName * cellW, cellH)
					f.Visible = true
				end
			end
			for i = n + 1, #useFrames do useFrames[i].Visible = false end
		end
		-- A few times a second: which name the cursor is on, and where else it is.
		Nav.trackUses = function()
			local tab = tabs[activeTab]
			local R = tab and tab.Kind ~= "diff" and not tab.Loading and tab.Analysis
			local ti = R and Analysis.TokenAt(R, codeFrame.CursorY + 1, codeFrame.CursorX)
			local sym = ti and R.tt[ti] == "name" and R.symAt[ti] or nil
			local key = sym and (tostring(R)..tostring(sym)) or false
			if key == usesKey then return end
			usesKey, usesName = key, sym and R.tv[ti] or nil
			local uses = {}
			if sym then
				local ok, all = pcall(Analysis.Accesses, R, ti)
				for _,a in ipairs(ok and all or {}) do
					if #uses >= 400 then break end
					local line, col = Analysis.TokenPos(R, a.tok)
					uses[#uses+1] = {Line = line, Col = col, Write = a.write}
				end
			end
			Nav.uses = #uses > 1 and uses or {} -- a name used once has nowhere else to show
			Nav.drawUses(true)
			refreshMarkers()
		end

		-- What stands for an instance that is in the game right now is tinted and underlined: the names of a
		-- path (game.A.B, script.Parent), the string of :GetService("A") or :WaitForChild("B"), a local set
		-- from one of these. Ctrl+click (or the right-click menu) selects it in the Explorer. Only the lines
		-- on screen are looked at, and again every two seconds, as instances come and go.
		local instFrames, instDrawn = {}, nil
		local INSTANCE_COLOR = Color3.fromRGB(80,210,190)
		Nav.drawInstances = function()
			local tab = tabs[activeTab]
			local R = tab and (tab.Kind == "script" or tab.Kind == "chunk") and not tab.Loading and tab.Analysis
			local linesFrame = codeFrame.GuiElems.LinesFrame
			local key = R and table.concat({tostring(R), codeFrame.ViewX, codeFrame.ViewY, linesFrame.AbsoluteSize.X, linesFrame.AbsoluteSize.Y, os.clock() // 2}, ":") or "none"
			if key == instDrawn then return end
			instDrawn = key
			local cellW, cellH = math.ceil(codeFrame.FontSize / 2), codeFrame.FontSize
			local viewX, viewY = codeFrame.ViewX, codeFrame.ViewY
			local n = 0
			for line = viewY + 1, R and math.min(#codeFrame.Lines, viewY + math.ceil(linesFrame.AbsoluteSize.Y / cellH) + 1) or 0 do
				local first, last = Analysis.TokensOnLine(R, line)
				local lineStart, text = Analysis.LineStart(R, line), codeFrame.Lines[line]
				for ti = first or 1, last or 0 do
					local kind, from, to = R.tt[ti], R.tp[ti], R.te[ti]
					local col, length = from - lineStart, to - from + 1
					-- a name or a string on this line that is still what the analysis saw
					if n < 400 and (kind == "name" or kind == "str") and R.tel[ti] == line and text:sub(col + 1, col + length) == R.src:sub(from, to) then
						local ok, inst = pcall(Tools.instanceAt, R, ti)
						if ok and inst then
							n = n + 1
							local f = instFrames[n]
							if not f then
								f = createSimple("Frame", {Name = "Instance", BackgroundColor3 = INSTANCE_COLOR, BackgroundTransparency = 0.96, BorderSizePixel = 0, ZIndex = 3, Parent = linesFrame})
								createSimple("Frame", {Name = "Line", BackgroundColor3 = INSTANCE_COLOR, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = UDim2.new(0,0,1,-1), Size = UDim2.new(1,0,0,1), ZIndex = 3, Parent = f})
								instFrames[n] = f
							end
							f.Position = UDim2.fromOffset((col - viewX) * cellW, (line - 1 - viewY) * cellH)
							f.Size = UDim2.fromOffset(length * cellW, cellH)
							f.Visible = true
						end
					end
				end
			end
			for i = n + 1, #instFrames do instFrames[i].Visible = false end
		end

		-- the marks move with the text, and a note being typed is kept where it was
		local function scrolled()
			if Nav.noteLine then Nav.noteBox:ReleaseFocus() end
			Live.draw()
			Nav.drawUses()
			Nav.drawInstances()
		end
		Main.Track(codeFrame.ScrollV.Scrolled:Connect(scrolled))
		Main.Track(codeFrame.ScrollH.Scrolled:Connect(scrolled))

		-- Tab strip, and at its end the list of the tabs (open, and closed lately)
		Nav.tabList = createSimple("TextButton", {Name = "TabList", BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, Size = UDim2.new(0,22,0,TAB_H), Text = "", Visible = false, Parent = Nav.leftCol})
		local listArrow = Lib.CreateArrow(9, 4, "down")
		listArrow.Position = UDim2.new(0.5,-5,0.5,-4)
		listArrow.Parent = Nav.tabList
		Nav.tabList.MouseButton1Click:Connect(function() Nav.showTabList(Nav.tabList) end)
		Lib.Tooltip.attach(Nav.tabList, "Every open tab with its script's path, and the tabs closed lately")
		tabStrip = createSimple("ScrollingFrame", {
			Name = "Tabs",
			BackgroundColor3 = Settings.Theme.Main2,
			BorderSizePixel = 0,
			Size = UDim2.new(1,-22,0,TAB_H),
			CanvasSize = UDim2.new(0,0,0,0),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = Settings.Theme.Highlight,
			Visible = false,
			Parent = Nav.leftCol,
		})
		createSimple("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0,1), Parent = tabStrip})
		tabStrip.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				tabStrip.CanvasPosition = Vector2.new(math.max(0, tabStrip.CanvasPosition.X - input.Position.Z * 60), 0)
			end
		end)

		-- Find / line / rename / note bar
		Nav.findBar = createSimple("Frame", {Name = "Bar", BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, Size = UDim2.new(1,0,0,FIND_H), Visible = false, Parent = Nav.leftCol})
		Nav.findLabel = newLabel(Nav.findBar, "Find", UDim2.new(0,6,0,0), UDim2.new(0,44,1,0), WHITE)
		Nav.findBox = Lib.ViewportTextBox.new()
		Nav.findBox.Position = UDim2.new(0,50,0,3)
		Nav.findBox.Size = UDim2.new(1,-334,0,FIND_H - 6)
		Nav.findBox.Parent = Nav.findBar
		Nav.findCount = newLabel(Nav.findBar, "", UDim2.new(1,-190,0,0), UDim2.new(0,54,1,0), GREY)
		Lib.Tooltip.attach(Nav.findCount, function() return Nav.findWhy end) -- why a pattern is no good

		-- from the right edge: close, all scripts, list, next, previous, (the count), pattern, whole word, case
		local function barButton(text, x, width, tip, onClick)
			local btn = Instance.new("TextButton")
			btn.BackgroundTransparency = 1
			btn.Position = UDim2.new(1,x,0,0)
			btn.Size = UDim2.new(0,width,1,0)
			btn.Font = Enum.Font.SourceSans
			btn.TextSize = 14
			btn.TextColor3 = WHITE
			btn.Text = text
			btn.MouseButton1Click:Connect(onClick)
			btn.Parent = Nav.findBar
			Lib.Tooltip.attach(btn, tip)
			return btn
		end
		local wordBtn, patternBtn
		-- The toggles show how the bar searches (the Search page can set that too, when it hands a search over).
		Nav.paintFind = function()
			local on = Color3.fromRGB(255,220,90)
			Nav.caseBtn.TextColor3 = Nav.findCase and on or WHITE
			wordBtn.TextColor3 = Nav.findKind == "word" and on or WHITE
			patternBtn.TextColor3 = Nav.findKind == "pattern" and on or WHITE
		end
		local function setKind(kind)
			Nav.findKind = Nav.findKind ~= kind and kind or "text"
			Nav.paintFind()
			recomputeFind(true)
		end
		Nav.caseBtn = barButton("Aa", -278, 24, "Match case", function()
			Nav.findCase = not Nav.findCase
			Nav.paintFind()
			recomputeFind(true)
		end)
		wordBtn = barButton("Word", -252, 36, "Whole words only", function() setKind("word") end)
		patternBtn = barButton(".*", -214, 22, "The text is a Lua pattern (%d+, [%w_]+ ...)", function() setKind("pattern") end)
		navButtons = {
			Nav.caseBtn, wordBtn, patternBtn,
			barButton("<", -134, 22, "Previous match", function() stepMatch(-1) end),
			barButton(">", -112, 22, "Next match", function() stepMatch(1) end),
			barButton("List", -88, 32, "List every match in this script in the navigator", function() Nav.listMatches() end),
			barButton("All", -54, 30, "Search every script of the game for this, the same way", function()
				Tools.openSearch(Nav.findBox:GetText(), Nav.findKind or "text", Nav.findCase)
			end),
		}
		barButton("x", -22, 22, "Close (Esc)", closeBar)

		Nav.findBox.TextBox:GetPropertyChangedSignal("Text"):Connect(function()
			-- (a search that came back by itself after a rename or a note leaves the cursor where it is)
			if Nav.findOpen and Nav.findMode == "find" then recomputeFind(not (Nav.findQuiet and os.clock() - Nav.findQuiet < 0.3)) end
		end)
		Nav.findBox.TextBox.FocusLost:Connect(function(enterPressed)
			if enterPressed and Nav.findOpen then submitBar() end
		end)

		-- The navigator. From the top: the scopes, the pages of the scope that is showing, the page's title
		-- (with Back once a page was opened from another), the filter of a long list, the page's rows.
		Nav.sideFrame = createSimple("Frame", {Name = "Sidebar", BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, ClipsDescendants = true, Visible = sideOpen, Parent = content})
		Nav.sideDivider = createSimple("TextButton", {Name = "SideDivider", AutoButtonColor = false, BackgroundColor3 = Settings.Theme.Outline1, BorderSizePixel = 0, Text = "", Parent = content})
		Lib.Tooltip.attach(Nav.sideDivider, "Drag to resize the navigator")

		local scopeStrip = createSimple("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1,0,0,24), Parent = Nav.sideFrame})
		for i,scope in ipairs(SCOPES) do
			local btn = createSimple("TextButton", {
				AutoButtonColor = false,
				BackgroundColor3 = Settings.Theme.Button,
				BorderSizePixel = 0,
				Position = UDim2.new((i - 1) / #SCOPES,2,0,3),
				Size = UDim2.new(1 / #SCOPES,-4,1,-5),
				Font = Enum.Font.SourceSans,
				TextSize = 14,
				TextColor3 = WHITE,
				Text = scope.Title,
				Parent = scopeStrip,
			})
			sideButtons[scope.Key] = btn
			btn.MouseButton1Click:Connect(function() selectSideTab(Nav.last[scope.Key] or scope.Pages[1]) end)
			Lib.Tooltip.attach(btn, scope.Tip)
		end

		local chipStrip = createSimple("ScrollingFrame", {
			Name = "Pages",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.new(0,2,0,24),
			Size = UDim2.new(1,-4,0,22),
			CanvasSize = UDim2.new(0,0,0,0),
			AutomaticCanvasSize = Enum.AutomaticSize.X,
			ScrollingDirection = Enum.ScrollingDirection.X,
			ScrollBarThickness = 0,
			Parent = Nav.sideFrame,
		})
		createSimple("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0,2), Parent = chipStrip})
		chipStrip.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				chipStrip.CanvasPosition = Vector2.new(math.max(0, chipStrip.CanvasPosition.X - input.Position.Z * 40), 0)
			end
		end)
		local chipOrder = 0
		for _,scope in ipairs(SCOPES) do
			for _,key in ipairs(scope.Pages) do
				chipOrder = chipOrder + 1
				local chip = createSimple("TextButton", {
					Name = key,
					AutoButtonColor = false,
					BackgroundColor3 = Settings.Theme.Button,
					BorderSizePixel = 0,
					LayoutOrder = chipOrder,
					Size = UDim2.new(0,40,1,-3),
					Font = Enum.Font.SourceSans,
					TextSize = 13,
					TextColor3 = WHITE,
					Text = "",
					Visible = false,
					Parent = chipStrip,
				})
				Nav.chips[key] = chip
				chip.MouseButton1Click:Connect(function() selectSideTab(key) end)
				Lib.Tooltip.attach(chip, rootPages[key].Tip)
			end
		end

		editBack = Instance.new("TextButton")
		editBack.BackgroundTransparency = 1
		editBack.Position = UDim2.new(0,4,0,48)
		editBack.Size = UDim2.new(0,60,0,22)
		editBack.Font = Enum.Font.SourceSans
		editBack.TextSize = 14
		editBack.Text = "< Back"
		editBack.TextColor3 = WHITE
		editBack.TextXAlignment = Enum.TextXAlignment.Left
		editBack.Visible = false
		editBack.Parent = Nav.sideFrame
		Lib.Tooltip.attach(editBack, "Back to the page this one was opened from")
		editBack.MouseButton1Click:Connect(function()
			local stack = sideStacks[sideTab]
			if #stack > 0 then
				stack[#stack] = nil
				renderEdit()
			end
		end)

		editTitle = newLabel(Nav.sideFrame, "", UDim2.new(0,8,0,48), UDim2.new(1,-12,0,22), WHITE)

		-- typing in it leaves out the rows without that text, before a long list is cut
		Nav.filterBox = Lib.ViewportTextBox.new()
		Nav.filterBox.Position = UDim2.new(0,6,0,72)
		Nav.filterBox.Size = UDim2.new(1,-14,0,20)
		Nav.filterBox.Visible = false
		Nav.filterBox.Parent = Nav.sideFrame
		Nav.filterBox.TextBox.PlaceholderText = "Filter this list"
		Nav.filterBox.TextBox.PlaceholderColor3 = Settings.Theme.PlaceholderText
		Nav.filterBox.TextBox:GetPropertyChangedSignal("Text"):Connect(function()
			local page, text = Nav.page, Nav.filterBox:GetText()
			if not page or page.NoFilter or (page.Filter or "") == text then return end
			page.Filter = text
			renderEdit()
		end)

		editList = Instance.new("ScrollingFrame")
		editList.BackgroundTransparency = 1
		editList.BorderSizePixel = 0
		editList.Position = UDim2.new(0,4,0,70)
		editList.Size = UDim2.new(1,-4,1,-70)
		editList.CanvasSize = UDim2.new(0,0,0,0)
		editList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		editList.ScrollBarThickness = 8
		editList.Parent = Nav.sideFrame

		local editListLayout = Instance.new("UIListLayout")
		editListLayout.SortOrder = Enum.SortOrder.LayoutOrder
		editListLayout.Padding = UDim.new(0,2)
		editListLayout.Parent = editList

		-- The graph pane, and the divider between it and the code
		Nav.flowPane = createSimple("Frame", {Name = "Flowchart", BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, ClipsDescendants = true, Parent = content})
		Nav.flowDivider = createSimple("TextButton", {Name = "Divider", AutoButtonColor = false, BackgroundColor3 = Settings.Theme.Outline1, BorderSizePixel = 0, Text = "", Parent = content})
		Lib.Tooltip.attach(Nav.flowDivider, "Drag to resize the graph pane")
		if Flowchart then
			-- the pane's switch: the flowchart of a function, the script's call graph, the modules around it
			Flowchart.Attach(Nav.flowPane, function() return flowOpen and window:IsContentVisible() end, function(mode)
				if mode == "calls" then
					showCallGraph()
				elseif mode == "modules" then
					Tools.showModules()
				else
					showFlow()
				end
			end)
			Flowchart.Clear("Open a script to see its flowchart.")
		end

		-- The status bar
		Nav.statusBar = createSimple("Frame", {Name = "Status", BackgroundColor3 = Settings.Theme.Main2, BorderSizePixel = 0, Position = UDim2.new(0,0,1,-STATUS_H), Size = UDim2.new(1,0,0,STATUS_H), Parent = content})
		createSimple("Frame", {BackgroundColor3 = Settings.Theme.Outline1, BorderSizePixel = 0, Size = UDim2.new(1,0,0,1), Parent = Nav.statusBar})

		-- x is from the left edge, or from the right one when it is negative. With onClick it is a button.
		local function statusLabel(key, tip, x, width, onClick)
			local lbl = createSimple(onClick and "TextButton" or "TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.new(x < 0 and 1 or 0,x,0,0),
				Size = UDim2.new(0,width,1,0),
				Font = Enum.Font.SourceSans,
				TextSize = 13,
				TextColor3 = GREY,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = "",
				Parent = Nav.statusBar,
			})
			if onClick then lbl.MouseButton1Click:Connect(function() onClick(lbl) end) end
			Lib.Tooltip.attach(lbl, tip)
			statusParts[key] = lbl
		end
		statusLabel("pos", "Line and column of the cursor. Click to go to a line", 8, 96, function() openBar("line", "") end)
		statusLabel("sel", "How much is selected", 112, 90)
		statusLabel("live", "The reading of the game's scripts while it goes on; else the running script: how many of its functions the last scan found. Hover a tinted constant (amber) or upvalue (violet; fainter when it is a guess) in the code to see or change it; green is one you changed. Click for the pages about it", -438, 170, function()
			openPage(Tools.scanStatus() ~= "" and "search" or (Nav.last.live or "trace"))
		end)
		statusLabel("decompiler", "Which decompiler produced this text. Click for the Decompiler menu", -260, 116, showDecompilerMenu)
		statusLabel("state", "Whether the script could be analysed: the outline, the graphs, rename and references all depend on it", -136, 128)

		-- initial look of everything
		Nav.paintTabs()
		Nav.paintChips()
		relayout()
		renderEdit()
		updateStatus()

		-- Dragging a divider resizes the navigator, or the graph pane
		local dragging -- "side" or "flow"
		Nav.sideDivider.MouseButton1Down:Connect(function()
			dragging = "side"
			Nav.sideDivider.BackgroundColor3 = Settings.Theme.ListSelection
		end)
		Nav.flowDivider.MouseButton1Down:Connect(function()
			dragging = "flow"
			Nav.flowDivider.BackgroundColor3 = Settings.Theme.ListSelection
		end)
		Main.Track(uis.InputEnded:Connect(function(input)
			if dragging and input.UserInputType == Enum.UserInputType.MouseButton1 then
				local was = dragging
				dragging = nil
				Nav.sideDivider.BackgroundColor3 = Settings.Theme.Outline1
				Nav.flowDivider.BackgroundColor3 = Settings.Theme.Outline1
				if was == "side" then renderEdit() end -- its texts wrap to the new width
			end
		end))
		Main.Track(uis.InputChanged:Connect(function(input)
			if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			local x = Main.Mouse.X - content.AbsolutePosition.X
			if dragging == "side" then
				Nav.W = math.clamp(x, SIDE_MIN, math.max(SIDE_MIN, content.AbsoluteSize.X - MIN_PANE * 2))
			else
				local left = sideOpen and (Nav.W + SPLIT_W) or 0
				local free = content.AbsoluteSize.X - left
				if free < MIN_PANE * 2 then return end
				flowRatio = 1 - math.clamp(x - left, MIN_PANE, free - MIN_PANE) / free
			end
			relayout()
		end))

		-- Escape while the viewer is in use (typing in it, or the mouse over it)
		Main.Track(uis.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard or not window:IsContentVisible() then return end
			local barFocused = Nav.findOpen and Nav.findBox.TextBox:IsFocused()
			if not (codeFrame.Editing or barFocused or Lib.CheckMouseInGui(window.GuiElems.Main)) then return end

			local key = input.KeyCode
			if key == Enum.KeyCode.Escape and Live.cardOpen() then Live.hideCard()
			elseif key == Enum.KeyCode.Escape and Nav.findOpen then closeBar() end
		end))

		-- A few times a second: live pages (watch, trace) update, the toolbar and the status bar follow the
		-- cursor, and so do the graph pane, the outline, the calls page and the uses of the name it is on
		local acc, countsDrawn = 0, 0
		Main.Track(service.RunService.Heartbeat:Connect(function(dt)
			acc = acc + dt
			if acc < 0.25 then return end
			acc = 0
			if not window:IsContentVisible() then return end

			local stack = sideStacks[sideTab]
			local page = sideOpen and (stack[#stack] or rootPages[sideTab])
			if page and page.Tick then page.Tick() end
			if sideOpen then Nav.paintChips() end

			followCursor() -- first, so the toolbar has the function the cursor is in now
			Live.tick()
			Live.draw()
			Nav.trackUses()
			Nav.drawUses()
			Nav.drawInstances()
			updateStatus()
			updateOutline()
			-- the call graph shows how often each function was called while that is being counted
			if flowOpen and flowMode == "calls" and Live.coverageOn() and os.clock() - countsDrawn > 2 then
				countsDrawn = os.clock()
				refreshFlow()
			end
		end))

		if Apps.Agent then Tools.registerAgent(Apps.Agent) end
		Main.AddCommands(getCommands)
	end

	-- Opens a script in a tab, at a line of its decompile when one is given (the line as the decompiler
	-- wrote it, before the header the viewer puts in front).
	ScriptViewer.ViewScript = function(scr, line)
		local existing = findTab(scr)
		if existing ~= activeTab or line then record() end -- Back returns to where this was asked from
		pcall(Tools.addRecent, scr)
		if existing then
			activateTab(existing)
			window:Show()
			if line then showLine(line + (tabs[existing].Offset or 0), 0) end
			return
		end

		for n = #Nav.closed, 1, -1 do
			if Nav.closed[n].Script == scr then table.remove(Nav.closed, n) end -- open again: no longer a closed tab
		end
		local tab = newTab({Script = scr, Name = scr.Name, Kind = "script", Text = "-- Decompiling "..scr.Name.."...", Loading = true, Path = getPath(scr)})
		activateTab(table.find(tabs, tab))
		window:Show()

		-- what the reading of all scripts has of it is shown as it is: at once, and with the lines that the
		-- search results and the lists made from it point at (it may come from another decompiler)
		local okKnown, known = pcall(Tools.textOf, scr)
		known = okKnown and type(known) == "string" and known or nil
		local text, ok, raw = decompileScript(scr, nil, known)
		fillTab(tab, text, ok, raw, known and "Decompile cache" or nil, true)
		if line and ok and tabs[activeTab] == tab then showLine(line + (tab.Offset or 0), 0) end
	end

	-- Remote Spy: opens a script at a call it made. Of its calls of that method, the one whose path leads to
	-- that remote, or failing that the one in a function of that name, is gone to; with neither, the function
	-- of that name, or the script's only call of the method. Else the script opens at its top.
	ScriptViewer.ViewCall = function(scr, remote, method, fname)
		ScriptViewer.ViewScript(scr)
		local tab = tabs[activeTab]
		local R = tab and tab.Script == scr and tabAnalysis()
		if not R then return end

		local best, score, only, count = nil, 0, nil, 0
		for _, r in ipairs(Analysis.Remotes(R)) do
			if r.kind == "remote" and r.method == method then
				count, only = count + 1, r.line
				local s = (resolveInstance(r.path, scr) == remote and 2 or 0) + (fname ~= "" and r.fn and Analysis.FunctionName(R, r.fn) == fname and 1 or 0)
				if s > score then best, score = r.line, s end
			end
		end
		if not best and fname and fname ~= "" then
			for _, f in ipairs(R.functions) do
				if f.name == fname then best = f.line1 break end
			end
		end
		best = best or (count == 1 and only)
		if best then showLine(best, 0) end
	end

	-- Called by Main.Uninit (Reload OpenDex, in the settings): what this viewer changed in the running game
	-- is undone, and its work in the background stops.
	ScriptViewer.Unload = function()
		pcall(Live.unload)
		pcall(Tools.unload)
	end

	-- Explorer: "Find in Scripts" on an object: every script that has its name as a word
	ScriptViewer.FindInScripts = function(inst)
		Tools.openSearch(inst.Name, "word")
	end

	----------------------------------------------------------------------------------------------
	-- The AI window: what an agent can ask of the viewer (Agent.lua runs the calls, mcp/tools.json says
	-- what the agent is told). Lines are lines of the raw decompile, as ViewScript and the search
	-- results use them. Reading never changes what the user sees; apply_names, note and open show the
	-- script in the viewer, because that is where their result is. The tools about every script together
	-- are with the scan (Tools.agentScan), the ones about the running script with Live (Live.agent).
	----------------------------------------------------------------------------------------------

	Tools.registerAgent = function(Agent)
		local reg = Agent.Register
		local MAX_LINES, MAX_CHARS = 400, 40000
		local analyses, analysisOrder = {}, {}

		-- the script an id or a path stands for
		local function scriptFor(ref)
			if type(ref) ~= "string" or ref == "" then
				error("script is needed: an id such as s17 (from scripts or context), or a full path", 0)
			end
			local known = Agent.Lookup(ref)
			if known then return known end
			local want = ref:lower():gsub("^game%.", "")
			local matches = {}
			for _,scr in ipairs(Tools.scriptList()) do
				if Tools.fullName(scr):lower() == want then matches[#matches+1] = scr end
			end
			if #matches == 1 then return matches[1] end
			if #matches == 0 then error(("no script has the id or path '%s' (scripts lists them)"):format(ref), 0) end
			local ids = {}
			for i = 1, math.min(#matches, 5) do ids[i] = Agent.IdOf(matches[i]) end
			error(("%d scripts have that path (%s): use an id"):format(#matches, table.concat(ids, ", ")), 0)
		end

		-- the raw decompile of a script: what its tab has, else what has been read, else a fresh decompile
		local function rawOf(scr)
			local i = findTab(scr)
			if i and tabs[i].Raw then return tabs[i].Raw end
			local ok, known = pcall(Tools.textOf, scr)
			if ok and type(known) == "string" then return known end
			local text, good, raw = decompileScript(scr)
			if good then return raw end
			error("the script could not be decompiled: "..(text:match("%-%- Reason: ([^\n]*)") or "no reason given"), 0)
		end

		-- the last few analyses, so that asking about several functions of a script parses it once
		local function analysisOf(raw)
			local R = analyses[raw]
			if R then return R end
			if #raw > 3000000 then error("the script is too large to analyze", 0) end
			local ok, result = pcall(Analysis.Analyze, raw)
			if not ok then error("analysis failed: "..tostring(result), 0) end
			analyses[raw] = result
			analysisOrder[#analysisOrder+1] = raw
			if #analysisOrder > 6 then analyses[table.remove(analysisOrder, 1)] = nil end
			return result
		end

		local function whereIs(scr)
			return ("%s (%s)"):format(Tools.fullName(scr), Agent.IdOf(scr))
		end

		-- shows a script in the viewer and returns its tab, which has to be the one in front with its source in
		local function openTab(scr)
			ScriptViewer.ViewScript(scr)
			local i = findTab(scr)
			local tab = i and tabs[i]
			if not tab or tabs[activeTab] ~= tab then error("the script could not be opened in the viewer", 0) end
			if tab.Loading or tab.Failed or not tab.Ann then error("the script has no source to work in (it could not be decompiled)", 0) end
			return tab
		end

		reg("context", function()
			local out = {tabs = {}, selected = {}}
			for _,tab in ipairs(tabs) do
				if tab.Kind == "script" and tab.Script then
					out.tabs[#out.tabs+1] = {script = Agent.IdOf(tab.Script), path = Tools.fullName(tab.Script), active = tabs[activeTab] == tab or nil}
				end
			end
			local tab = tabs[activeTab]
			if tab and tab.Kind == "script" and tab.Script then
				out.script, out.path = Agent.IdOf(tab.Script), Tools.fullName(tab.Script)
				if tab.Raw and not tab.Loading and not tab.Failed then
					local offset = tab.Offset or 0
					local line = cursorLine() - offset
					if line >= 1 then
						out.line = line
						local text = rawLines(tab)[line]
						out.lineText = text and text:gsub("^%s+", ""):sub(1, 200)
					end
					local R = tabAnalysis()
					local fn = R and Analysis.FunctionAtLine(R, cursorLine())
					if fn and fn.parent then
						out["function"] = Analysis.FunctionName(R, fn)
						out.functionLines = {fn.line1 - offset, fn.line2 - offset}
					end
				end
			end
			for _,node in ipairs(selection.List) do
				if #out.selected >= 10 then
					out.moreSelected = true
					break
				end
				local obj = node.Obj
				local ok, path = pcall(obj.GetFullName, obj)
				local entry = {path = ok and path or tostring(obj), class = obj.ClassName}
				local isScript, yes = pcall(obj.IsA, obj, "LuaSourceContainer")
				if isScript and yes then entry.script = Agent.IdOf(obj) end
				out.selected[#out.selected+1] = entry
			end
			return out
		end)

		-- The function of a script that the arguments name: by a line inside it, or by its name
		local function functionFor(R, args)
			if args.line ~= nil then
				local line = math.floor(tonumber(args.line) or 0)
				if line < 1 or line > #R.nl + 1 then error(("line %s is outside the script (it has %d lines)"):format(tostring(args.line), #R.nl + 1), 0) end
				return Analysis.FunctionAtLine(R, line)
			elseif type(args.name) == "string" and args.name ~= "" then
				local found = {}
				for _,fn in ipairs(R.functions) do
					if fn.parent and (Analysis.FunctionName(R, fn) == args.name or Analysis.ShortName(fn) == args.name or Analysis.Signature(R, fn) == args.name) then found[#found+1] = fn end
				end
				if #found == 0 then error(("no function is called '%s' in this script (outline lists them)"):format(args.name), 0) end
				if #found > 1 then
					local at = {}
					for i = 1, math.min(#found, 8) do at[i] = tostring(found[i].line1) end
					error(("%d functions are called '%s' (they start on lines %s): give a line"):format(#found, args.name, table.concat(at, ", ")), 0)
				end
				return found[1]
			end
			error("give a line inside the function, or its name (outline lists the functions)", 0)
		end

		-- the tools of the parts that keep their data to themselves: every script together, the running script
		local shared = {scriptFor = scriptFor, rawOf = rawOf, analysisOf = analysisOf, whereIs = whereIs, functionFor = functionFor}
		Tools.agentScan(Agent, shared)
		Live.agent(Agent, shared)

		reg("outline", function(args)
			local scr = scriptFor(args.script)
			local R = analysisOf(rawOf(scr))
			local out, more = {}, false
			for _,o in ipairs(Analysis.Outline(R)) do
				if o.fn.parent then
					if #out >= 400 then
						more = true
						break
					end
					out[#out+1] = {name = o.name, line = o.line1, last = o.line2, depth = o.depth}
				end
			end
			return {script = Agent.IdOf(scr), path = Tools.fullName(scr), lines = #R.nl + 1, functions = out, truncated = more or nil}
		end)

		reg("source", function(args)
			local scr = scriptFor(args.script)
			local lines = {}
			for line in (rawOf(scr).."\n"):gmatch("(.-)\r?\n") do lines[#lines+1] = line end
			if lines[#lines] == "" then lines[#lines] = nil end
			local from = math.max(1, math.floor(tonumber(args.from) or 1))
			if from > #lines then error(("the script has %d lines"):format(#lines), 0) end
			local to = math.min(math.floor(tonumber(args.to) or (from + 199)), #lines, from + MAX_LINES - 1)
			if to < from then error("to is before from", 0) end
			local out, size = {}, 0
			for n = from, to do
				size = size + #lines[n] + 8
				if size > MAX_CHARS and n > from then
					to = n - 1
					break
				end
				out[#out+1] = n..": "..lines[n]
			end
			local more = to < #lines and ("\n... more follows: ask again with from=%d"):format(to + 1) or ""
			return ("%s, lines %d-%d of %d\n%s%s"):format(whereIs(scr), from, to, #lines, table.concat(out, "\n"), more)
		end)

		reg("function", function(args)
			local scr = scriptFor(args.script)
			local R = analysisOf(rawOf(scr))
			return Analysis.BundleText(Analysis.FunctionBundle(R, functionFor(R, args)), whereIs(scr))
		end)

		reg("annotations", function(args)
			local scr = scriptFor(args.script)
			local i = findTab(scr)
			local tab = i and tabs[i]
			local ann, current
			if tab and tab.Ann then
				ann, current = tab.Ann, true
			else
				local file = readAnnFile(scr)
				if file and type(file.sets) == "table" then
					ann = file.sets[checksum(rawOf(scr))]
					current = ann ~= nil
					ann = ann or newestSet(file)
				end
			end
			local out = {script = Agent.IdOf(scr), path = Tools.fullName(scr), renames = {}, notes = {}}
			if not ann then return out end
			local offset = (tab and tab.Ann == ann and tab.Offset) or ann.off or 0
			for _,r in ipairs(ann.renames or {}) do out.renames[#out.renames+1] = {from = r.orig, to = r.name} end
			for _,c in ipairs(ann.comments or {}) do out.notes[#out.notes+1] = {line = c.line - offset, text = c.text} end
			if not current then out.note = "these were saved for an earlier version of the script" end
			return out
		end)

		reg("apply_names", function(args)
			local scr = scriptFor(args.script)
			if type(args.names) ~= "table" or #args.names == 0 then error("names is needed: a list of {from, name}", 0) end
			if #args.names > 60 then error("at most 60 names at a time", 0) end
			local tab = openTab(scr)
			local R, why = tabAnalysis()
			if not R then error(why, 0) end
			local offset = tab.Offset or 0
			local requests = {}
			for _,n in ipairs(args.names) do
				requests[#requests+1] = {from = type(n) == "table" and n.from or nil, name = type(n) == "table" and n.name or nil, line = type(n) == "table" and tonumber(n.line) and (math.floor(n.line) + offset) or nil}
			end
			local plan = Analysis.PlanRenames(R, requests, {maxLen = 40})
			if #plan.ok > 0 then Tools.applyNames(R, plan.ok) end
			local applied = {}
			for _,o in ipairs(plan.ok) do applied[#applied+1] = {from = o.from, name = o.name, line = o.line - offset} end
			return {script = Agent.IdOf(scr), applied = applied, rejected = plan.rejected}
		end)

		reg("note", function(args)
			local scr = scriptFor(args.script)
			local line = math.floor(tonumber(args.line) or 0)
			local text = type(args.text) == "string" and args.text:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""
			if text == "" then error("text is needed", 0) end
			if #text > 300 then error("the note is longer than 300 characters", 0) end
			local tab = openTab(scr)
			local viewerLine = line + (tab.Offset or 0)
			if line < 1 or not codeFrame.Lines[viewerLine] then error(("line %d is outside the script"):format(line), 0) end
			local existing = noteOn(viewerLine)
			if existing ~= "" and existing:sub(1, 3) ~= "AI:" then
				error(("line %d already has a note of the user's (%s): pick another line"):format(line, existing:sub(1, 40)), 0)
			end
			setNote(viewerLine, "AI: "..text)
			return {script = Agent.IdOf(scr), line = line, note = "AI: "..text}
		end)

		reg("open", function(args)
			local scr = scriptFor(args.script)
			local line = args.line ~= nil and math.floor(tonumber(args.line) or 0) or nil
			if line and line < 1 then error("line has to be 1 or more", 0) end
			ScriptViewer.ViewScript(scr, line)
			return {opened = whereIs(scr), line = line}
		end)
	end

	return ScriptViewer
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
