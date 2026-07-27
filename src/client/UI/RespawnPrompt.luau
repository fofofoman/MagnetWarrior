--!nonstrict
--[[
	RespawnPrompt.luau

	The death overlay: a countdown, and the button that spends a 즉시 재시도
	ticket to skip it.

	The countdown shown here is cosmetic. RespawnService holds the real timer and
	respawns on its own schedule whether or not this UI exists; pressing the
	button only asks the server to spend a ticket, and the server refuses if
	there is none. Skipping the wait cannot improve a time either way — the run
	clock does not start until the player re-enters the start volume.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local Net = require(Shared.Net)

local ShopPanel = require(script.Parent.ShopPanel)
local Theme = require(script.Parent.Theme)

local RespawnPrompt = {}

local create = Theme.create
local player = Players.LocalPlayer

local PRODUCT_KEY = "SkipRetryWait"

local frame: Frame
local countdownLabel: TextLabel
local skipButton: TextButton
local deadUntil = 0
local visible = false

local function refreshButton()
	local tickets = ShopPanel.ConsumableCount(PRODUCT_KEY)
	local product = MonetizationConfig.DeveloperProductByKey[PRODUCT_KEY]

	if tickets > 0 then
		skipButton.Text = `즉시 재시도 (보유 {tickets})`
		skipButton.BackgroundColor3 = Theme.Colors.Accent
		skipButton.TextColor3 = Theme.Colors.Background
	elseif product and product.assetId ~= 0 then
		skipButton.Text = "즉시 재시도 구매"
		skipButton.BackgroundColor3 = Theme.Colors.PanelRaised
		skipButton.TextColor3 = Theme.Colors.Text
	else
		skipButton.Text = "잠시 후 부활합니다"
		skipButton.BackgroundColor3 = Theme.Colors.PanelRaised
		skipButton.TextColor3 = Theme.Colors.TextDim
	end
end

local function show()
	deadUntil = os.clock() + GameConfig.RespawnDelay
	visible = true
	frame.Visible = true
	refreshButton()
end

local function hide()
	visible = false
	frame.Visible = false
end

local function build()
	local gui = create("ScreenGui", {
		Name = "MagnetWarriorRespawn",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Parent = player:WaitForChild("PlayerGui"),
	})

	frame = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -110),
		Size = UDim2.fromOffset(280, 96),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	})
	Theme.decorate(frame, 12)

	countdownLabel = create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 12),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "부활까지 3.0초",
		TextColor3 = Theme.Colors.Text,
		TextSize = 18,
		Parent = frame,
	})

	skipButton = create("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(1, -28, 0, 34),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Font = Theme.FontBold,
		Text = "즉시 재시도",
		TextColor3 = Theme.Colors.Text,
		TextSize = 14,
		Parent = frame,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = skipButton })

	skipButton.Activated:Connect(function()
		if ShopPanel.ConsumableCount(PRODUCT_KEY) > 0 then
			Net.RequestRespawn:FireServer()
		else
			Net.RequestPurchase:FireServer({ productKey = PRODUCT_KEY })
		end
	end)
end

local function watchCharacter(character: Model)
	hide()

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	humanoid.Died:Connect(show)
end

function RespawnPrompt.Start()
	build()

	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)

	Net.EntitlementsChanged.OnClientEvent:Connect(function()
		if visible then
			-- A ticket bought from the death screen should light the button up
			-- immediately.
			task.defer(refreshButton)
		end
	end)

	RunService.Heartbeat:Connect(function()
		if not visible then
			return
		end
		local remaining = math.max(deadUntil - os.clock(), 0)
		countdownLabel.Text = if remaining > 0
			then string.format("부활까지 %.1f초", remaining)
			else "부활 중…"
	end)
end

return RespawnPrompt
