--[[
	Flowchart App Module

	A pane that draws a graph from ScriptAnalysis (a function's flowchart or the script's call
	graph): a box per node, bars for the edges. Drag to pan, wheel to zoom, click a node to jump
	to its code. The Script Viewer docks the pane (Flowchart.Attach) and feeds it graphs with
	Flowchart.Show.

	Boxes that call the script's own functions, or define nested ones, carry a button per kind that
	opens them. The pane has a switch between the graphs (a function's flowchart, the call graph,
	the modules around the script), a legend, a node search, arrow-key navigation (while the mouse
	is over it and no text box has focus) and remembers the pan and zoom of every graph it has shown.
]]
-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local service,createSimple -- Main Locals
local Analysis

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	service = data.service
	createSimple = data.createSimple
end

local function initAfterMain()
	Analysis = Apps.ScriptAnalysis
end

local function main()
	local Flowchart = {}

	local FONT, TEXT_SIZE, LINE_H = Enum.Font.Code, 13, 15
	local BADGE_H = 18
	local MIN_ZOOM, MAX_ZOOM = 0.15, 2.5
	local HEADER_H = 44

	local FILL = {
		start = Color3.fromRGB(38,92,60), root = Color3.fromRGB(38,92,60),
		block = Color3.fromRGB(62,62,62), func = Color3.fromRGB(58,74,92),
		cond = Color3.fromRGB(56,70,106), loop = Color3.fromRGB(86,62,106),
		ret = Color3.fromRGB(106,52,52), ["break"] = Color3.fromRGB(74,74,74), continue = Color3.fromRGB(74,74,74),
		remote = Color3.fromRGB(122,80,36), http = Color3.fromRGB(122,80,36), dynamic = Color3.fromRGB(112,42,92),
	}
	-- nodes that contain such a call, or call the script's own functions
	local TINT = {remote = FILL.remote, http = FILL.http, dynamic = FILL.dynamic, calls = Color3.fromRGB(46,76,104), unused = Color3.fromRGB(44,44,44)}
	local PILL = {cond = true, loop = true, start = true, root = true, ["break"] = true, continue = true}
	local CENTERED = {cond = true, loop = true, start = true, root = true, ret = true, ["break"] = true, continue = true, func = true, remote = true, http = true, dynamic = true}
	local EDGE = {
		next = Color3.fromRGB(110,150,230), ["true"] = Color3.fromRGB(80,200,100), ["false"] = Color3.fromRGB(230,90,90),
		back = Color3.fromRGB(240,170,60), ["break"] = Color3.fromRGB(160,160,160),
		call = Color3.fromRGB(110,150,230), def = Color3.fromRGB(150,150,150),
		remote = Color3.fromRGB(240,150,60), http = Color3.fromRGB(240,150,60), dynamic = Color3.fromRGB(220,90,190),
	}
	local STROKE, SELECTED, MATCH = Color3.fromRGB(150,150,150), Color3.fromRGB(255,220,90), Color3.fromRGB(80,200,255)
	local OPEN_COLOR, CALLS_COLOR = Color3.fromRGB(120,200,255), Color3.fromRGB(150,230,170)

	local LEGEND_NODES = {
		{FILL.start,"Start of the function"},
		{FILL.block,"Plain statements"},
		{TINT.calls,"Statements that call the script's own functions"},
		{FILL.cond,"Condition (if / elseif)"},
		{FILL.loop,"Loop"},
		{FILL.ret,"Return"},
		{FILL["break"],"break / continue"},
		{FILL.func,"A function (call graph)"},
		{FILL.remote,"Remote, HTTP or loadstring call"},
	}
	local LEGEND_EDGES = {
		{EDGE.next,"Next statement"},
		{EDGE["true"],"Condition is true"},
		{EDGE["false"],"Condition is false"},
		{EDGE.back,"Back to the top of a loop"},
		{EDGE["break"],"Leaves a loop"},
		{EDGE.call,"Calls (call graph)"},
		{EDGE.def,"Defined here, as a callback (call graph)"},
		{EDGE.remote,"Remote or HTTP call (call graph)"},
	}
	local LEGEND_BUTTONS = {
		{OPEN_COLOR,"open ...  opens a function defined in the box"},
		{CALLS_COLOR,"calls ...  opens a function the box calls"},
	}

	-- The three graphs the pane shows, for its switch: key, label, width of the button, tooltip.
	local MODES = {
		{"flow","Function",58,"The flowchart of one function: the one the cursor is in, or one picked on the left"},
		{"calls","Calls",42,"The call graph of the script: which function calls which"},
		{"modules","Modules",58,"The modules around the script: what it requires and what requires it"},
	}

	local pane, viewport, panFrame, canvas, uiScale
	local edgeLayer, nodeLayer, labelLayer
	local titleButton, infoLabel, emptyLabel
	local modeButtons, onMode = {}, nil
	local searchBox, searchCount, legendButton, legend
	local active = function() return true end
	local graph, opts = nil, {}
	local nodeFrames, selectedId = {}, nil
	local matchSet, matchList, matchIdx = {}, {}, 0
	local zoom, panX, panY = 1, 0, 0
	local pendingFit = false
	local panning, panStart, panOrigin, panMoved = false, nil, nil, 0
	local lastClick = {}
	local functionMenu, badgeMenu
	local views = setmetatable({},{__mode = "k"}) -- pan and zoom of each graph shown, by opts.ViewKey
	local viewKey

	local textService = service.TextService

	-- Box size for a node: its widest label line and the number of lines (and a row per kind of button).
	local function measure(nd)
		local widest, lines = 0, 0
		for line in ((nd.label or "").."\n"):gmatch("(.-)\n") do
			lines = lines + 1
			local ok, size = pcall(function()
				return textService:GetTextSize(line,TEXT_SIZE,FONT,Vector2.new(10000,100))
			end)
			widest = math.max(widest,ok and size.X or #line*7)
		end
		local rows = ((nd.funcs and #nd.funcs > 0) and 1 or 0) + ((nd.calls and #nd.calls > 0) and 1 or 0)
		local w = math.clamp(widest+20,70,420)
		if rows > 0 then w = math.max(w,150) end
		return w, math.max(1,lines)*LINE_H + 12 + rows*BADGE_H
	end

	local function applyView()
		panFrame.Position = UDim2.fromOffset(panX,panY)
		uiScale.Scale = zoom
		if viewKey then views[viewKey] = {zoom = zoom, panX = panX, panY = panY} end
	end

	local function fit()
		if not graph or not graph.w then return end
		local vw,vh = viewport.AbsoluteSize.X,viewport.AbsoluteSize.Y
		if vw < 10 or vh < 10 then
			pendingFit = true -- the pane isn't laid out yet, the AbsoluteSize listener retries
			return
		end
		pendingFit = false
		zoom = math.clamp(math.min((vw-24)/graph.w,(vh-24)/graph.h,1),0.35,1)
		panX = math.max(12,(vw-graph.w*zoom)/2)
		panY = 12
		applyView()
	end

	-- Zoom keeping the point under (cx, cy) (viewport pixels) where it is.
	local function zoomAt(factor,cx,cy)
		local newZoom = math.clamp(zoom*factor,MIN_ZOOM,MAX_ZOOM)
		if newZoom == zoom then return end
		cx = cx or viewport.AbsoluteSize.X/2
		cy = cy or viewport.AbsoluteSize.Y/2
		local px,py = (cx-panX)/zoom,(cy-panY)/zoom
		zoom = newZoom
		panX,panY = cx-px*zoom,cy-py*zoom
		applyView()
	end

	-- Pans so the node is in view (only if it isn't), or always centred when centre is true.
	local function reveal(nd,centre)
		local vw,vh = viewport.AbsoluteSize.X,viewport.AbsoluteSize.Y
		local left,top = panX+nd.x*zoom,panY+nd.y*zoom
		if centre or left < 0 or top < 0 or left+nd.w*zoom > vw or top+nd.h*zoom > vh then
			panX = vw/2 - (nd.x+nd.w/2)*zoom
			panY = vh/2 - (nd.y+nd.h/2)*zoom
			applyView()
		end
	end

	-- Outline of a node: selected (yellow), found by the search (blue), or plain.
	local function applyStroke(id)
		local f = nodeFrames[id]
		if not f then return end
		if id == selectedId then
			f.Stroke.Color,f.Stroke.Thickness = SELECTED,2
		elseif matchSet[id] then
			f.Stroke.Color,f.Stroke.Thickness = MATCH,2
		else
			f.Stroke.Color,f.Stroke.Thickness = STROKE,1
		end
	end

	local function setSelected(id)
		local old = selectedId
		selectedId = id
		applyStroke(old)
		applyStroke(id)
	end

	-- A straight, axis-aligned edge piece.
	local function bar(x1,y1,x2,y2,color)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		if y1 == y2 then
			f.Position = UDim2.fromOffset(math.min(x1,x2)-1,y1-1)
			f.Size = UDim2.fromOffset(math.abs(x2-x1)+2,2)
		else
			f.Position = UDim2.fromOffset(x1-1,math.min(y1,y2)-1)
			f.Size = UDim2.fromOffset(2,math.abs(y2-y1)+2)
		end
		f.Parent = edgeLayer
	end

	-- Every edge ends going down into the top of a node: a V made of two rotated bars.
	local function arrow(x,y,color)
		for _,side in ipairs({-1,1}) do
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.new(0.5,0.5)
			f.BackgroundColor3 = color
			f.BorderSizePixel = 0
			f.Size = UDim2.fromOffset(9,2)
			f.Position = UDim2.fromOffset(x+side*2.83,y-2.83)
			f.Rotation = -side*45
			f.Parent = edgeLayer
		end
	end

	-- Menu of the functions a box opens, when it has more than one.
	local function showBadgeMenu(list)
		badgeMenu = badgeMenu or Lib.ContextMenu.new()
		badgeMenu.Iconless = true
		badgeMenu.Width = 260
		badgeMenu:Clear()
		for _,f in ipairs(list) do
			badgeMenu:Add({Name = Analysis.Signature(graph.R,f), OnClick = function()
				if opts.OnOpenFunction then opts.OnOpenFunction(f) end
			end})
		end
		badgeMenu:Show()
	end

	local function onNodeClick(nd)
		if panMoved > 4 then return end -- that was a drag, not a click

		setSelected(nd.id)
		local now = tick()
		local double = lastClick.id == nd.id and now - lastClick.time < 0.4
		lastClick = {id = nd.id, time = now}

		if opts.OnSelect then opts.OnSelect(nd) end
		if double and nd.fn and opts.OnOpenFunction then opts.OnOpenFunction(nd.fn) end
	end

	-- A button along the bottom of a box that opens one function, or a menu of several.
	local function badgeButton(parent,y,text,color,list)
		local btn = createSimple("TextButton",{
			AutoButtonColor = false,
			BackgroundColor3 = Color3.fromRGB(28,28,28),
			BackgroundTransparency = 0.3,
			BorderSizePixel = 0,
			Position = UDim2.new(0,4,1,y),
			Size = UDim2.new(1,-8,0,BADGE_H - 4),
			Font = Enum.Font.SourceSans,
			TextSize = 13,
			TextColor3 = color,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = text,
			Parent = parent,
		})
		btn.MouseButton1Click:Connect(function()
			if panMoved > 4 then return end
			if #list == 1 then
				if opts.OnOpenFunction then opts.OnOpenFunction(list[1]) end
			else
				showBadgeMenu(list)
			end
		end)
		return btn
	end

	local function makeNode(nd)
		local base = TINT[nd.tint] or FILL[nd.kind] or FILL.block
		local funcs,calls = nd.funcs or {},nd.calls or {}
		local rows = (#funcs > 0 and 1 or 0) + (#calls > 0 and 1 or 0)

		local b = createSimple("TextButton",{
			Name = "N"..nd.id,
			AutoButtonColor = false,
			BackgroundColor3 = base,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Position = UDim2.fromOffset(nd.x,nd.y),
			Size = UDim2.fromOffset(nd.w,nd.h),
			Font = FONT,
			TextSize = TEXT_SIZE,
			TextColor3 = Color3.fromRGB(232,232,232),
			Text = nd.label or "",
			TextXAlignment = CENTERED[nd.kind] and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
		})
		createSimple("UICorner",{CornerRadius = PILL[nd.kind] and UDim.new(0.5,0) or UDim.new(0,4), Parent = b})
		local stroke = createSimple("UIStroke",{ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = STROKE, Thickness = 1, Parent = b})
		createSimple("UIPadding",{PaddingLeft = UDim.new(0,8), PaddingRight = UDim.new(0,8), PaddingBottom = UDim.new(0,rows*BADGE_H), Parent = b})

		-- buttons stack up from the bottom: definitions at the very bottom, calls above them
		local y = -(BADGE_H - 1)
		if #funcs > 0 then
			local text = #funcs == 1 and ("open "..Analysis.Signature(graph.R,funcs[1])) or ("open "..#funcs.." functions")
			badgeButton(b,y,text,OPEN_COLOR,funcs)
			y = y - BADGE_H
		end
		if #calls > 0 then
			local text = #calls == 1 and ("calls "..Analysis.Signature(graph.R,calls[1])) or ("calls "..#calls.." functions")
			badgeButton(b,y,text,CALLS_COLOR,calls)
		end

		b.MouseEnter:Connect(function() b.BackgroundColor3 = base:Lerp(Color3.new(1,1,1),0.12) end)
		b.MouseLeave:Connect(function() b.BackgroundColor3 = base end)
		b.MouseButton1Click:Connect(function() onNodeClick(nd) end)

		b.Parent = nodeLayer
		nodeFrames[nd.id] = {Frame = b, Stroke = stroke}
	end

	-- Text the node search looks in: the box's lines and the names of the functions it opens.
	local function searchText(nd)
		local parts = {nd.label or ""}
		for _,f in ipairs(nd.funcs or {}) do parts[#parts+1] = Analysis.Signature(graph.R,f) end
		for _,f in ipairs(nd.calls or {}) do parts[#parts+1] = Analysis.Signature(graph.R,f) end
		return table.concat(parts," "):lower()
	end

	local function centreOn(nd)
		reveal(nd,true)
	end

	-- Marks the nodes that contain the search text; the first one is brought into view when asked.
	local function runSearch(bringIntoView)
		matchSet,matchList,matchIdx = {},{},0
		local needle = searchBox.Text:lower()
		if needle ~= "" and graph then
			for _,nd in ipairs(graph.nodes) do
				if nd.search and nd.search:find(needle,1,true) then
					matchSet[nd.id] = true
					matchList[#matchList+1] = nd
				end
			end
		end
		for id in pairs(nodeFrames) do applyStroke(id) end

		searchCount.Text = needle == "" and "" or (#matchList == 0 and "none" or (#matchList.." found"))
		if bringIntoView and #matchList > 0 then
			matchIdx = 1
			centreOn(matchList[1])
		end
	end

	local function nextMatch(step)
		if #matchList == 0 then return end
		matchIdx = (matchIdx - 1 + step) % #matchList + 1
		centreOn(matchList[matchIdx])
		searchCount.Text = ("%d of %d"):format(matchIdx,#matchList)
	end

	local function render()
		for _,layer in ipairs({edgeLayer,nodeLayer,labelLayer}) do
			layer:ClearAllChildren()
		end
		nodeFrames = {}
		selectedId = nil
		canvas.Size = UDim2.fromOffset(graph.w,graph.h)

		for _,e in ipairs(graph.edges) do
			if e.pts and #e.pts >= 2 then
				local color = EDGE[e.kind] or EDGE.next
				for i = 1,#e.pts-1 do
					local p,q = e.pts[i],e.pts[i+1]
					bar(p[1],p[2],q[1],q[2],color)
				end
				local last = e.pts[#e.pts]
				arrow(last[1],last[2],color)

				if e.label and e.label ~= "" and e.lx then
					createSimple("TextLabel",{
						BackgroundTransparency = 1,
						Position = UDim2.fromOffset(e.lx,e.ly),
						Size = UDim2.fromOffset(60,12),
						Font = FONT,
						TextSize = 11,
						TextColor3 = color,
						TextXAlignment = Enum.TextXAlignment.Left,
						Text = e.label,
						Parent = labelLayer,
					})
				end
			end
		end
		for _,nd in ipairs(graph.nodes) do
			nd.search = searchText(nd)
			makeNode(nd)
		end
		runSearch(false)
	end

	local function showFunctionMenu()
		local list = opts.Functions
		if type(list) == "function" then list = list() end -- built only when the picker is opened
		if not list or #list == 0 then return end

		functionMenu = functionMenu or Lib.ContextMenu.new()
		functionMenu.Iconless = true
		functionMenu.SearchEnabled = true
		functionMenu.Width = 280
		functionMenu.MaxHeight = 320
		functionMenu:Clear()
		for _,entry in ipairs(list) do
			functionMenu:Add({Name = entry.label, OnClick = function()
				if opts.OnPickFunction then opts.OnPickFunction(entry) end
			end})
		end
		functionMenu:Show()
	end

	-- The key legend: what the colours of boxes, edges and buttons mean.
	local function buildLegend()
		legend = createSimple("Frame",{
			Name = "Legend",
			AnchorPoint = Vector2.new(1,0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Settings.Theme.Menu,
			BackgroundTransparency = 0.05,
			BorderSizePixel = 0,
			Position = UDim2.new(1,-8,0,8),
			Size = UDim2.new(0,300,0,0),
			Visible = false,
			ZIndex = 6,
			Parent = viewport,
		})
		createSimple("UICorner",{CornerRadius = UDim.new(0,4),Parent = legend})
		createSimple("UIStroke",{Color = Settings.Theme.Outline2,Thickness = 1,Parent = legend})
		createSimple("UIPadding",{PaddingLeft = UDim.new(0,8),PaddingRight = UDim.new(0,8),PaddingTop = UDim.new(0,6),PaddingBottom = UDim.new(0,6),Parent = legend})
		createSimple("UIListLayout",{SortOrder = Enum.SortOrder.LayoutOrder,Padding = UDim.new(0,2),Parent = legend})

		local order = 0
		local function line(color,text,isEdge,heading)
			order = order + 1
			local row = createSimple("Frame",{BackgroundTransparency = 1,Size = UDim2.new(1,0,0,heading and 18 or 16),LayoutOrder = order,ZIndex = 6,Parent = legend})
			if heading then
				createSimple("TextLabel",{BackgroundTransparency = 1,Size = UDim2.new(1,0,1,0),Font = Enum.Font.SourceSansBold,TextSize = 13,TextColor3 = Settings.Theme.Text,TextXAlignment = Enum.TextXAlignment.Left,Text = text,ZIndex = 6,Parent = row})
				return
			end
			createSimple("Frame",{
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Position = UDim2.new(0,0,0,isEdge and 7 or 3),
				Size = UDim2.new(0,22,0,isEdge and 2 or 10),
				ZIndex = 6,
				Parent = row,
			})
			createSimple("TextLabel",{BackgroundTransparency = 1,Position = UDim2.new(0,30,0,0),Size = UDim2.new(1,-30,1,0),Font = Enum.Font.SourceSans,TextSize = 12,TextColor3 = Settings.Theme.Text,TextXAlignment = Enum.TextXAlignment.Left,TextTruncate = Enum.TextTruncate.AtEnd,Text = text,ZIndex = 6,Parent = row})
		end

		line(nil,"Boxes",false,true)
		for _,item in ipairs(LEGEND_NODES) do line(item[1],item[2]) end
		line(nil,"Buttons on a box",false,true)
		for _,item in ipairs(LEGEND_BUTTONS) do line(item[1],item[2]) end
		line(nil,"Arrows",false,true)
		for _,item in ipairs(LEGEND_EDGES) do line(item[1],item[2],true) end
		line(nil,"Outlines: yellow is selected, blue is a search match",false,true)
	end

	-- Builds the pane inside parent, a Frame the host sizes. isActive() says whether the pane is on
	-- screen: while it isn't (hidden, or its window closed) the mouse is ignored. pickMode(key) is
	-- called when one of the three graphs is chosen with the switch (Flowchart.SetMode shows which is on).
	function Flowchart.Attach(parent,isActive,pickMode)
		active = isActive or active
		onMode = pickMode

		pane = createSimple("Frame",{
			Name = "Flowchart",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1,0,1,0),
			Parent = parent,
		})

		local function toolButton(text,position,size,onClick,tip)
			local btn = Lib.Button.new()
			btn.Text = text
			btn.Position = position
			btn.Size = size
			btn.OnClick:Connect(onClick)
			btn.Gui.Parent = pane
			if tip then Lib.Tooltip.attach(btn.Gui,tip) end
			return btn
		end

		-- row 1: which graph (a click picks another function), and the switch between the three kinds
		local switchWidth = 0
		for _,m in ipairs(MODES) do switchWidth = switchWidth + m[3] + 2 end
		titleButton = toolButton("",UDim2.new(0,2,0,2),UDim2.new(1,-(switchWidth + 6),0,18),showFunctionMenu,"Pick another function to chart")
		titleButton.TextXAlignment = Enum.TextXAlignment.Left
		titleButton.TextTruncate = Enum.TextTruncate.AtEnd
		local x = -switchWidth
		for _,m in ipairs(MODES) do
			local key = m[1]
			modeButtons[key] = toolButton(m[2],UDim2.new(1,x,0,2),UDim2.new(0,m[3],0,18),function()
				if onMode then onMode(key) end
			end,m[4])
			x = x + m[3] + 2
		end

		-- row 2: search the nodes, how the graph is drawn, and the legend
		toolButton("Fit",UDim2.new(1,-158,0,23),UDim2.new(0,40,0,18),fit,"Fit the whole graph in the pane (F)")
		toolButton("-",UDim2.new(1,-116,0,23),UDim2.new(0,24,0,18),function() zoomAt(1/1.25) end,"Zoom out (mouse wheel)")
		toolButton("+",UDim2.new(1,-90,0,23),UDim2.new(0,24,0,18),function() zoomAt(1.25) end,"Zoom in (mouse wheel)")
		searchBox = createSimple("TextBox",{
			BackgroundColor3 = Settings.Theme.TextBox,
			BorderColor3 = Settings.Theme.Outline3,
			ClearTextOnFocus = false,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
			TextColor3 = Settings.Theme.Text,
			PlaceholderText = "Search the boxes (Enter: next match)",
			PlaceholderColor3 = Settings.Theme.ReadOnlyText,
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.new(0,2,0,23),
			Size = UDim2.new(1,-230,0,18),
			Parent = pane,
		})
		createSimple("UIPadding",{PaddingLeft = UDim.new(0,4),Parent = searchBox})
		searchCount = createSimple("TextLabel",{
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			TextSize = 13,
			TextColor3 = Settings.Theme.ReadOnlyText,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "",
			Position = UDim2.new(1,-226,0,23),
			Size = UDim2.new(0,64,0,18),
			Parent = pane,
		})
		legendButton = toolButton("Legend",UDim2.new(1,-62,0,23),UDim2.new(0,60,0,18),function()
			if not legend then buildLegend() end
			legend.Visible = not legend.Visible
		end,"What the colours of the boxes, arrows and buttons mean")

		searchBox:GetPropertyChangedSignal("Text"):Connect(function() runSearch(true) end)
		searchBox.FocusLost:Connect(function(enterPressed)
			if enterPressed then nextMatch(1) end
		end)

		viewport = createSimple("Frame",{
			Name = "Viewport",
			BackgroundColor3 = Settings.Theme.Syntax.Background,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Position = UDim2.new(0,0,0,HEADER_H),
			Size = UDim2.new(1,0,1,-HEADER_H),
			Parent = pane,
		})
		-- the pan frame is moved; the canvas inside it is scaled, so zoom never fights with position
		panFrame = createSimple("Frame",{BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromOffset(0,0), Parent = viewport})
		canvas = createSimple("Frame",{BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromOffset(10,10), Parent = panFrame})
		uiScale = createSimple("UIScale",{Parent = canvas})
		edgeLayer = createSimple("Frame",{Name = "Edges", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1,0,1,0), ZIndex = 1, Parent = canvas})
		nodeLayer = createSimple("Frame",{Name = "Nodes", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1,0,1,0), ZIndex = 2, Parent = canvas})
		labelLayer = createSimple("Frame",{Name = "Labels", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1,0,1,0), ZIndex = 3, Parent = canvas})

		infoLabel = createSimple("TextLabel",{
			BackgroundTransparency = 1,
			Position = UDim2.new(0,6,1,-16),
			Size = UDim2.new(1,-12,0,14),
			Font = Enum.Font.SourceSans,
			TextSize = 12,
			TextColor3 = Settings.Theme.ReadOnlyText,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 5,
			Parent = viewport,
		})
		-- shown instead of a graph, when there isn't one to draw
		emptyLabel = createSimple("TextLabel",{
			BackgroundTransparency = 1,
			Size = UDim2.new(1,0,1,0),
			Font = Enum.Font.SourceSans,
			TextSize = 14,
			TextColor3 = Settings.Theme.ReadOnlyText,
			TextWrapped = true,
			Text = "",
			ZIndex = 5,
			Parent = viewport,
		})

		viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if pendingFit then fit() end
		end)

		-- Dragging and the wheel are read globally (and checked against the viewport) so they work
		-- while the mouse is over a node, which would otherwise swallow them.
		local uis = service.UserInputService
		local mouse = Main.Mouse
		local function dragButton(input)
			return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton3
		end
		Main.Track(uis.InputBegan:Connect(function(input)
			if not dragButton(input) or not active() or not Lib.CheckMouseInGui(viewport) then return end
			panning = true
			panMoved = 0
			panStart = Vector2.new(mouse.X,mouse.Y)
			panOrigin = Vector2.new(panX,panY)
		end))
		Main.Track(uis.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				if not panning then return end
				local delta = Vector2.new(mouse.X,mouse.Y) - panStart
				panMoved = math.max(panMoved,delta.Magnitude)
				if panMoved > 3 then
					panX,panY = panOrigin.X+delta.X,panOrigin.Y+delta.Y
					applyView()
				end
			elseif input.UserInputType == Enum.UserInputType.MouseWheel then
				if not active() or not Lib.CheckMouseInGui(viewport) then return end
				local pos = viewport.AbsolutePosition
				zoomAt(input.Position.Z > 0 and 1.15 or 1/1.15,mouse.X-pos.X,mouse.Y-pos.Y)
			end
		end))
		Main.Track(uis.InputEnded:Connect(function(input)
			if dragButton(input) then panning = false end
		end))
	end

	-- Shows on the switch which of the three graphs is on ("flow", "calls" or "modules").
	function Flowchart.SetMode(mode)
		for key,button in pairs(modeButtons) do
			button.TextColor3 = key == mode and SELECTED or Settings.Theme.Text
			button.Font = key == mode and Enum.Font.SourceSansBold or Enum.Font.SourceSans
		end
	end

	-- G is a graph from ScriptAnalysis (BuildFlow or CallGraph). options:
	--   Title, Functions ({label, ...} for the picker, or a function returning it), OnSelect(node),
	--   OnOpenFunction(fn), OnPickFunction(entry), ViewKey (any table: graphs shown again with the same
	--   key come back with the pan and zoom they had)
	function Flowchart.Show(G,options)
		if not pane then return end
		opts = options or {}
		graph = G
		if not G.w then Analysis.Layout(G,measure) end

		titleButton.Text = " "..(opts.Title or "")
		emptyLabel.Text = ""
		local info = ("%d nodes"):format(#G.nodes)
		if G.truncated then info = info.." (large function, graph cut short)" end
		if G.hidden and G.hidden > 0 then info = info..(", %d functions without static calls not shown"):format(G.hidden) end
		infoLabel.Text = info.."   |   drag to pan, wheel to zoom, click a box to jump to its code"

		render()

		viewKey = opts.ViewKey
		local saved = viewKey and views[viewKey]
		if saved then
			zoom,panX,panY = saved.zoom,saved.panX,saved.panY
			applyView()
		else
			fit()
		end
	end

	-- Empties the pane and says why there is no graph.
	function Flowchart.Clear(message)
		if not pane then return end
		graph,opts,viewKey = nil,{},nil
		for _,layer in ipairs({edgeLayer,nodeLayer,labelLayer}) do
			layer:ClearAllChildren()
		end
		nodeFrames,selectedId = {},nil
		matchSet,matchList,matchIdx = {},{},0
		searchCount.Text = ""
		titleButton.Text = ""
		infoLabel.Text = ""
		emptyLabel.Text = message or ""
	end

	-- Marks a node as selected (without calling OnSelect); reveal pans it into view if needed.
	function Flowchart.Highlight(id,doReveal)
		if not pane or not graph or id == selectedId then return end
		setSelected(id)
		local nd = id and graph.nodes[id]
		if nd and doReveal then reveal(nd) end
	end

	function Flowchart.GetGraph()
		return graph
	end

	-- Outlines a set of nodes ({[id] = true}) the way search matches are, until the next search or graph.
	function Flowchart.Mark(ids)
		if not pane or not graph then return end
		matchSet,matchList,matchIdx = {},{},0
		for id in pairs(ids) do
			local nd = graph.nodes[id]
			if nd then
				matchSet[id] = true
				matchList[#matchList+1] = nd
			end
		end
		table.sort(matchList,function(a,b) return a.id < b.id end)
		for id in pairs(nodeFrames) do applyStroke(id) end
		searchCount.Text = #matchList.." marked"
	end

	return Flowchart
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
