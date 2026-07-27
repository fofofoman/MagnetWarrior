--!strict
--[[
	Theme.luau
	Colours, fonts and the small `create` helper every panel is built with.
	The UI is written in code rather than stored as .rbxmx so it stays diffable
	alongside the rest of the project.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SoundKit = require(Shared.Util.SoundKit)

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(16, 18, 24),
	Panel = Color3.fromRGB(26, 30, 38),
	PanelRaised = Color3.fromRGB(36, 41, 51),
	Stroke = Color3.fromRGB(58, 66, 80),
	Text = Color3.fromRGB(236, 240, 246),
	TextDim = Color3.fromRGB(150, 160, 176),
	Accent = Color3.fromRGB(64, 156, 255),
	AccentWarm = Color3.fromRGB(255, 96, 88),
	Good = Color3.fromRGB(88, 224, 132),
	Warn = Color3.fromRGB(255, 196, 76),
	Bad = Color3.fromRGB(255, 96, 88),
}

Theme.Medal = {
	Gold = Color3.fromRGB(255, 205, 84),
	Silver = Color3.fromRGB(198, 208, 220),
	Bronze = Color3.fromRGB(205, 133, 78),
	None = Color3.fromRGB(96, 104, 118),
}

Theme.MedalLabel = {
	Gold = "골드",
	Silver = "실버",
	Bronze = "브론즈",
	None = "기록",
}

--- Beam colour names sold by MagnetColorPack, resolved for rendering.
Theme.BeamColors = {
	Default = Color3.fromRGB(64, 156, 255),
	Crimson = Color3.fromRGB(255, 72, 84),
	Azure = Color3.fromRGB(76, 190, 255),
	Toxic = Color3.fromRGB(150, 255, 96),
	Violet = Color3.fromRGB(186, 120, 255),
	Solar = Color3.fromRGB(255, 186, 64),
	Frost = Color3.fromRGB(180, 240, 255),
	Void = Color3.fromRGB(122, 96, 200),
	Chrome = Color3.fromRGB(226, 232, 240),
}

Theme.Font = Enum.Font.GothamMedium
Theme.FontBold = Enum.Font.GothamBold

--- Minimal declarative instance builder: `create("TextLabel", { ... }, { ... })`.
function Theme.create(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local instance = Instance.new(className)

	if props then
		for key, value in props do
			if key ~= "Parent" then
				(instance :: any)[key] = value
			end
		end
	end

	if children then
		for _, child in children do
			child.Parent = instance
		end
	end

	if props and props.Parent then
		instance.Parent = props.Parent
	end

	return instance
end

--- Gives a button its click sound. Applied at construction so no call site has
--- to remember, and so the click is heard even when the handler is slow.
function Theme.clickable<T>(button: T): T
	local instance = button :: any
	instance.Activated:Connect(function()
		SoundKit.PlayLocal("ButtonClick")
	end)
	return button
end

--- Rounded corners + a hairline stroke, applied to a frame.
function Theme.decorate(frame: GuiObject, radius: number?, strokeColor: Color3?)
	Theme.create("UICorner", {
		CornerRadius = UDim.new(0, radius or 8),
		Parent = frame,
	})
	Theme.create("UIStroke", {
		Color = strokeColor or Theme.Colors.Stroke,
		Thickness = 1,
		Transparency = 0.35,
		Parent = frame,
	})
end

return Theme
