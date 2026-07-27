--!nonstrict
--[[
	Toast.luau
	Transient server messages — purchase confirmations, locked-stage refusals.
	The server is the only source; the client never invents one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local Theme = require(script.Parent.Theme)

local Toast = {}

local create = Theme.create
local player = Players.LocalPlayer

local MAX_VISIBLE = 4
local LIFETIME = 3.5

local container: Frame

local toneColors = {
	Good = Theme.Colors.Good,
	Warn = Theme.Colors.Warn,
	Bad = Theme.Colors.Bad,
	Info = Theme.Colors.Accent,
}

local function push(text: string, tone: string?)
	if #container:GetChildren() > MAX_VISIBLE + 1 then
		-- Drop the oldest so a burst of messages cannot fill the screen.
		for _, child in container:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
				break
			end
		end
	end

	local frame = create("Frame", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Parent = container,
	})
	Theme.decorate(frame, 8)

	create("Frame", {
		Size = UDim2.fromOffset(4, 34),
		BackgroundColor3 = toneColors[tone or "Info"] or Theme.Colors.Accent,
		BorderSizePixel = 0,
		Parent = frame,
	}, {
		create("UICorner", { CornerRadius = UDim.new(0, 4) }),
	})

	local label = create("TextLabel", {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -24, 1, 0),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = text,
		TextColor3 = Theme.Colors.Text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})

	task.delay(LIFETIME, function()
		if not frame.Parent then
			return
		end
		TweenService:Create(frame, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(label, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
		task.delay(0.4, function()
			frame:Destroy()
		end)
	end)
end

function Toast.Start()
	local gui = create("ScreenGui", {
		Name = "MagnetWarriorToasts",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Parent = player:WaitForChild("PlayerGui"),
	})

	container = create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 20),
		Size = UDim2.fromOffset(300, 200),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		create("UIListLayout", {
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Top,
		}),
	})

	Net.Notify.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or typeof(payload.text) ~= "string" then
			return
		end
		push(payload.text, payload.tone)
	end)
end

Toast.Push = push

return Toast
