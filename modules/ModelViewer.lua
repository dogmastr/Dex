--[[
	Model Viewer App Module
	
	A model viewer :3
]]

-- Common Locals
local Main,Lib,Apps,Settings -- Main Containers
local Explorer -- Major Apps
local env -- Main Locals

local function initDeps(data)
	Main = data.Main
	Lib = data.Lib
	Apps = data.Apps
	Settings = data.Settings

	env = data.env
end

local function initAfterMain()
	Explorer = Apps.Explorer
end

local function getPath(obj)
	if obj.Parent == nil then
		return "Nil parented"
	else
		return Explorer.GetInstancePath(obj)
	end
end

local function main()
	local RunService = game:GetService("RunService")

	local ModelViewer = {
		EnableInputCamera = true,
		IsViewing = false,
		AutoRefresh = false,
		ZoomMultiplier = 2,
		AutoRotate = true,
		RotationSpeed = 0.01,
		RefreshRate = 4 -- hertz
	}
	
	local window, viewportFrame, pathLabel, settingsButton
	local model, camera, originalModel
	local distance, center = 10, Vector3.zero -- how far out the camera orbits, and around which point
	local refreshLoopRunning = false
	
	
	ModelViewer.StopViewModel = function(updating)
		if updating then
			local existing = viewportFrame:FindFirstChildOfClass("Model")
			if existing then existing:Destroy() end
		else
			if camera then camera = nil end
			if model then model = nil end
			viewportFrame:ClearAllChildren()
			
			ModelViewer.IsViewing = false
			window:SetTitle("3D Preview")
			pathLabel.Gui.Text = ""
		end
	end

	ModelViewer.ViewModel = function(item, updating)
		if not item then return end

		-- workspace would mean cloning the whole place, and Terrain can't be cloned
		if item == workspace or item:IsA("Terrain") then
			Main.Notify(item.Name.." can't be previewed: pick a model or a part", "warn")
			return
		end
		ModelViewer.StopViewModel(updating)

		local wasArchivable = item.Archivable
		item.Archivable = true
		local clone = item:Clone()
		item.Archivable = wasArchivable

		-- a Model is shown as it is; anything else (a part, an Accessory, a Folder) goes inside one
		if clone and not clone:IsA("Model") then
			local holder = Instance.new("Model")
			clone.Parent = holder
			clone = holder
		end
		if not clone or not clone:FindFirstChildWhichIsA("BasePart", true) then
			if clone then clone:Destroy() end
			model = nil
			if not updating then Main.Notify(item.Name.." has no parts to preview", "warn") end
			return
		end
		model = clone
		model.Parent = viewportFrame

		-- orbit the middle of the model, from far enough out to see all of it (60 degree view: the
		-- diagonal of its bounding box). A refresh keeps the zoom the user has set.
		local boxCFrame, boxSize = model:GetBoundingBox()
		center = boxCFrame.Position
		if not updating then distance = math.max(boxSize.Magnitude, 2) end

		originalModel = item
		
		if ModelViewer.AutoRefresh and not updating and not refreshLoopRunning then
			refreshLoopRunning = true
			local session = Main.Session
			task.spawn(function()
				while model and ModelViewer.AutoRefresh and Main.Session == session do -- (a reload starts a new session)
					-- (a copy of the model each time: only while there is a window to see it in)
					if window:IsContentVisible() then ModelViewer.ViewModel(originalModel, true) end
					task.wait(1 / ModelViewer.RefreshRate)
				end
				refreshLoopRunning = false
			end)
		end
		
		if not updating then
			camera = Instance.new("Camera")
			viewportFrame.CurrentCamera = camera

			camera.Parent = viewportFrame
			camera.FieldOfView = 60
			
			window:SetTitle(item.Name.." - 3D Preview")
			pathLabel.Gui.Text = "path: " .. getPath(originalModel)
			window:Show()
			ModelViewer.IsViewing = true
		end
	end

	ModelViewer.Init = function()
		window = Lib.Window.new()
		window:SetTitle("3D Preview")
		window:Resize(350,200)
		window:SetLayoutId("ModelViewer")
		ModelViewer.Window =  window
		
		viewportFrame = Instance.new("ViewportFrame")
		viewportFrame.Parent = window.GuiElems.Content
		viewportFrame.BackgroundTransparency = 1
		viewportFrame.Size = UDim2.new(1,0,1,0)
		
		pathLabel = Lib.Label.new()
		pathLabel.Gui.Parent = window.GuiElems.Content
		pathLabel.Gui.AnchorPoint = Vector2.new(0,1)
		pathLabel.Gui.Text = ""
		pathLabel.Gui.TextSize = 12
		pathLabel.Gui.TextColor3 = Settings.Theme.ReadOnlyText -- it was 80% see-through, about 1.9:1
		pathLabel.Gui.TextTransparency = 0
		pathLabel.Gui.Position = UDim2.new(0,1,1,0)
		pathLabel.Gui.Size = UDim2.new(1,-1,0,15)
		pathLabel.Gui.BackgroundTransparency = 1
		
		settingsButton = Instance.new("ImageButton",window.GuiElems.Content)
		settingsButton.AnchorPoint = Vector2.new(1,0)
		settingsButton.BackgroundTransparency = 1
		settingsButton.Size = UDim2.new(0,15,0,15)
		settingsButton.Position = UDim2.new(1,-3,0,3)
		settingsButton.Image = "rbxassetid://6578871732"
		settingsButton.ImageTransparency = 0.5
		Lib.Tooltip.attach(settingsButton, "Viewer options")
		settingsButton.Visible = env.isonmobile -- (with a mouse, a right-click on the view opens the same menu)

		local rotationX, rotationY = math.rad(-15), math.pi -- a little above the model, facing its front
		local dragging = false
		local hovering = false
		local lastpos = Vector2.zero

		viewportFrame.InputBegan:Connect(function(input)
			if not ModelViewer.EnableInputCamera then return end
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				lastpos = input.Position
			elseif input.KeyCode == Enum.KeyCode.LeftShift then
				ModelViewer.ZoomMultiplier = 10
			end
		end)
		

		viewportFrame.MouseEnter:Connect(function()
			hovering = true
		end)
		viewportFrame.MouseLeave:Connect(function()
			hovering = false
		end)

		viewportFrame.InputEnded:Connect(function(input)
			if not ModelViewer.EnableInputCamera then return end
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			elseif input.KeyCode == Enum.KeyCode.LeftShift then
				ModelViewer.ZoomMultiplier = 2
			end
		end)

		viewportFrame.InputChanged:Connect(function(input)
			if not ModelViewer.EnableInputCamera then return end
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - lastpos
				lastpos = input.Position

				rotationY -= delta.X * 0.01
				rotationX -= delta.Y * 0.01
				rotationX = math.clamp(rotationX, -math.pi/2 + 0.1, math.pi/2 - 0.1)
			end

			if input.UserInputType == Enum.UserInputType.MouseWheel and hovering then
				-- a share of the distance per notch, so a map and a single part both zoom at a usable speed
				distance = math.clamp(distance * (1 - input.Position.Z * 0.05 * ModelViewer.ZoomMultiplier), 0.1, math.huge)
			end
		end)

		Main.Track(RunService.RenderStepped:Connect(function(dt)
			if camera and model then
				if not dragging and ModelViewer.AutoRotate then
					rotationY += ModelViewer.RotationSpeed * dt * 60
				end

				local offset = CFrame.new(0, 0, distance)
				local rotation = CFrame.Angles(0, rotationY, 0) * CFrame.Angles(rotationX, 0, 0)

				local camCF = CFrame.new(center) * rotation * offset

				camera.CFrame = CFrame.lookAt(camCF.Position, center)

			end
		end))

		-- context stuffs
		local context = Lib.ContextMenu.new()
		
		local absoluteSize = context.Gui.AbsoluteSize
		context.MaxHeight = (absoluteSize.Y <= 600 and (absoluteSize.Y - 40)) or nil

		-- Registers
		context:Register("STOP",{Name = "Stop Viewing", OnClick = function()
			ModelViewer.StopViewModel()
		end})
		context:Register("EXIT",{Name = "Exit", OnClick = function()
			ModelViewer.StopViewModel()
			context:Hide()
			window:Hide()
		end})
		context:Register("COPY_PATH",{Name = "Copy Path", OnClick = function()
			if model and env.setclipboard then
				env.setclipboard(getPath(originalModel))
			end
		end})
		context:Register("REFRESH",{Name = "Refresh", OnClick = function()
			if originalModel then
				ModelViewer.ViewModel(originalModel)
			end
		end})
		context:Register("ENABLE_AUTO_REFRESH",{Name = "Enable Auto Refresh", OnClick = function()
			if originalModel then
				ModelViewer.AutoRefresh = true
				ModelViewer.ViewModel(originalModel)
			end
		end})
		context:Register("DISABLE_AUTO_REFRESH",{Name = "Disable Auto Refresh", OnClick = function()
			if originalModel then
				ModelViewer.AutoRefresh = false
				ModelViewer.ViewModel(originalModel)
			end
		end})
		context:Register("SAVE_INST",{Name = "Save to File", OnClick = function()
			if model then Lib.SaveObjectPrompt(originalModel) end
		end})
		
		context:Register("ENABLE_AUTO_ROTATE",{Name = "Enable Auto Rotate", OnClick = function()
			ModelViewer.AutoRotate = true
			
		end})
		context:Register("DISABLE_AUTO_ROTATE",{Name = "Disable Auto Rotate", OnClick = function()
			ModelViewer.AutoRotate = false
		end})
		context:Register("LOCK_CAM",{Name = "Lock Camera", OnClick = function()
			ModelViewer.EnableInputCamera = false
		end})
		context:Register("UNLOCK_CAM",{Name = "Unlock Camera", OnClick = function()
			ModelViewer.EnableInputCamera = true
		end})
		
		context:Register("ZOOM_IN",{Name = "Zoom In", OnClick = function()
			distance = math.max(distance * 0.8, 0.1)
		end})

		context:Register("ZOOM_OUT",{Name = "Zoom Out", OnClick = function()
			distance = distance * 1.25
		end})
		
		local function ShowContext()
			context:Clear()

			context:AddRegistered("STOP", not ModelViewer.IsViewing)	
			context:AddRegistered("REFRESH", not ModelViewer.IsViewing)
			context:AddRegistered("COPY_PATH", not ModelViewer.IsViewing or not env.setclipboard)
			context:AddRegistered("SAVE_INST", not ModelViewer.IsViewing)
			context:AddDivider()
			
			if env.isonmobile then
				context:AddRegistered("ZOOM_IN")
				context:AddRegistered("ZOOM_OUT")
				context:AddDivider()
			end

			if ModelViewer.AutoRotate then
				context:AddRegistered("DISABLE_AUTO_ROTATE")
			else
				context:AddRegistered("ENABLE_AUTO_ROTATE")
			end
			if ModelViewer.AutoRefresh then
				context:AddRegistered("DISABLE_AUTO_REFRESH")
			else
				context:AddRegistered("ENABLE_AUTO_REFRESH")
			end
			if ModelViewer.EnableInputCamera then
				context:AddRegistered("LOCK_CAM")
			else
				context:AddRegistered("UNLOCK_CAM")
			end

			context:AddDivider()

			context:AddRegistered("EXIT")

			context:Show()
		end
		
		local function HideContext()
			context:Hide()
		end
		
		viewportFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				ShowContext()
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 and Lib.CheckMouseInGui(context.Gui) then
				HideContext()
			end
		end)
		settingsButton.MouseButton1Click:Connect(function()
			ShowContext()
		end)
	end

	return ModelViewer
end

return {InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main}
