--!nonstrict
--[[
	MedalPopup.luau

	The end-of-run card: medal earned, final time, and the delta against the
	previous personal best.

	Every value shown here comes from the server's Finished update. The client
	does not compute the medal, the time, or whether it was a record — it renders
	the verdict it was given. A rejected run gets the same card with the reason
	instead of a medal, so a filtered run is visible rather than silently
	discarded.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local StageConfig = require(Shared.Config.StageConfig)
local TimeFormat = require(Shared.Util.TimeFormat)

local RunState = require(script.Parent.Parent.State.RunState)
local Theme = require(script.Parent.Theme)

local MedalPopup = {}

local create = Theme.create
local player = Players.LocalPlayer

local HOLD_SECONDS = 6

local card: Frame
local medalLabel: TextLabel
local titleLabel: TextLabel
local timeLabel: TextLabel
local deltaLabel: TextLabel
local hideToken = 0

local function build()
	local gui = create("ScreenGui", {
		Name = "MagnetWarriorResult",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Parent = player:WaitForChild("PlayerGui"),
	})

	card = create("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(380, 230),
		BackgroundColor3 = Theme.Colors.Panel,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	})
	Theme.decorate(card, 16)

	medalLabel = create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "GOLD",
		TextColor3 = Theme.Medal.Gold,
		TextSize = 38,
		Parent = card,
	})

	titleLabel = create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 66),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 14,
		Parent = card,
	})

	timeLabel = create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 92),
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "0.000",
		TextColor3 = Theme.Colors.Text,
		TextSize = 44,
		Parent = card,
	})

	deltaLabel = create("TextLabel", {
		Position = UDim2.new(0, 0, 0, 142),
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Colors.Good,
		TextSize = 16,
		Parent = card,
	})

	local buttonRow = create("Frame", {
		Position = UDim2.new(0, 20, 1, -56),
		Size = UDim2.new(1, -40, 0, 38),
		BackgroundTransparency = 1,
		Parent = card,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 10),
		}),
	})

	local function makeButton(text: string, color: Color3, onClick: () -> ())
		local button = create("TextButton", {
			Size = UDim2.fromOffset(150, 34),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Font = Theme.FontBold,
			Text = text,
			TextColor3 = Theme.Colors.Background,
			TextSize = 15,
			Parent = buttonRow,
		})
		create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = button })
		button.Activated:Connect(onClick)
	end

	makeButton("다시 도전", Theme.Colors.Accent, function()
		local stageId = RunState.StageId()
		if stageId then
			Net.RequestStageTeleport:FireServer({ stageId = stageId })
		end
		MedalPopup.Hide()
	end)

	makeButton("허브로", Theme.Colors.PanelRaised, function()
		Net.RequestStageTeleport:FireServer({ stageId = "hub" })
		MedalPopup.Hide()
	end)
end

function MedalPopup.Hide()
	hideToken += 1
	card.Visible = false
end

local function show(update)
	local definition = StageConfig.Get(update.stageId)
	local stageName = if definition then definition.displayName else update.stageId

	if update.rejected then
		medalLabel.Text = "기록 무효"
		medalLabel.TextColor3 = Theme.Colors.Bad
		titleLabel.Text = `{stageName} · {update.rejectReason or "검증 실패"}`
		timeLabel.Text = TimeFormat.Clock(update.elapsedMs or 0)
		timeLabel.TextColor3 = Theme.Colors.TextDim
		deltaLabel.Text = "정상적인 주행만 기록에 반영됩니다"
		deltaLabel.TextColor3 = Theme.Colors.TextDim
	else
		local medal = update.medal or "None"
		medalLabel.Text = if medal == "None" then "완주" else string.upper(medal)
		medalLabel.TextColor3 = Theme.Medal[medal] or Theme.Medal.None
		titleLabel.Text = stageName
		timeLabel.Text = TimeFormat.Clock(update.elapsedMs or 0)
		timeLabel.TextColor3 = Theme.Colors.Text

		if update.isPersonalBest then
			if update.previousBestMs then
				deltaLabel.Text = `개인 최고 기록 경신! {TimeFormat.Delta((update.elapsedMs or 0) - update.previousBestMs)}`
			else
				deltaLabel.Text = "첫 클리어 · 개인 기록 등록"
			end
			deltaLabel.TextColor3 = Theme.Colors.Good
		elseif update.previousBestMs then
			deltaLabel.Text = `개인 최고 {TimeFormat.Clock(update.previousBestMs)} · {TimeFormat.Delta((update.elapsedMs or 0) - update.previousBestMs)}`
			deltaLabel.TextColor3 = Theme.Colors.TextDim
		else
			deltaLabel.Text = ""
		end
	end

	card.Visible = true
	card.Position = UDim2.fromScale(0.5, 0.46)
	TweenService:Create(card, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(0.5, 0.42),
	}):Play()

	hideToken += 1
	local token = hideToken
	task.delay(HOLD_SECONDS, function()
		if hideToken == token then
			card.Visible = false
		end
	end)
end

function MedalPopup.Start()
	build()

	RunState.Finished:Connect(function(update)
		-- Aborts are already communicated by the HUD flash; only a completed
		-- attempt (clean or rejected) earns a card.
		if update.kind ~= "Finished" then
			return
		end
		show(update)
	end)
end

return MedalPopup
