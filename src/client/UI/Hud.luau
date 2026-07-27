--!nonstrict
--[[
	Hud.luau

	The in-run display: timer, checkpoint progress, split flashes, and a medal
	pace chip.

	The pace chip is the piece that makes medals feel like a goal rather than a
	result. It reads the stage's thresholds from StageConfig and shows the best
	medal still reachable *right now*, downgrading live as the clock passes each
	one. Because the thresholds are shared config, the chip and the server's
	award can never disagree.

	Once every medal is out of reach it switches to the player's own personal
	best instead of announcing failure. Telling someone mid-run that they have
	already lost is the fastest way to make them stop running; a live gap to
	their own record is something they can still act on, and for a player with no
	medal yet it is the only goal that exists.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local StageConfig = require(Shared.Config.StageConfig)
local TimeFormat = require(Shared.Util.TimeFormat)

local MagnetEffects = require(script.Parent.Parent.Effects.MagnetEffects)
local MagnetController = require(script.Parent.Parent.MagnetController)
local RunState = require(script.Parent.Parent.State.RunState)
local Theme = require(script.Parent.Theme)

local Hud = {}

local create = Theme.create
local player = Players.LocalPlayer

local gui: ScreenGui
local timerLabel: TextLabel
local paceLabel: TextLabel
local checkpointLabel: TextLabel
local splitLabel: TextLabel
local stageLabel: TextLabel
local pullBar: Frame
local pushBar: Frame
local runFrame: Frame
local crosshair: Frame

--- Personal bests, so the pace chip has something to fall back on. Refreshed on
--- start and after every finish.
local records: { [string]: any } = {}

local CROSSHAIR_BASE = 6
local CROSSHAIR_SPREAD = 10 -- extra pixels at full speed

--- Best medal still achievable at this elapsed time, or — once they are all
--- gone — the live gap to the player's own record.
local function paceFor(stageId: string?, elapsedMs: number): (string, Color3)
	local definition = stageId and StageConfig.Get(stageId)
	if not definition then
		return "", Theme.Medal.None
	end

	if elapsedMs <= definition.medals.Gold then
		return `골드 페이스 · {TimeFormat.Short(definition.medals.Gold - elapsedMs)} 남음`, Theme.Medal.Gold
	elseif elapsedMs <= definition.medals.Silver then
		return `실버 페이스 · {TimeFormat.Short(definition.medals.Silver - elapsedMs)} 남음`, Theme.Medal.Silver
	elseif elapsedMs <= definition.medals.Bronze then
		return `브론즈 페이스 · {TimeFormat.Short(definition.medals.Bronze - elapsedMs)} 남음`, Theme.Medal.Bronze
	end

	local record = records[stageId]
	local best = record and record.bestTimeMs
	if typeof(best) == "number" and best > 0 then
		if elapsedMs < best then
			return `개인기록까지 {TimeFormat.Short(best - elapsedMs)} 남음`, Theme.Colors.Good
		end
		return `개인기록 {TimeFormat.Delta(elapsedMs - best)}`, Theme.Colors.TextDim
	end

	return "완주 목표", Theme.Colors.TextDim
end

local function refreshRecords()
	task.spawn(function()
		local ok, result = pcall(function()
			return Net.GetRecords:InvokeServer()
		end)
		if ok and typeof(result) == "table" then
			records = result
		end
	end)
end

local function buildGui()
	gui = create("ScreenGui", {
		Name = "MagnetWarriorHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Crosshair. The magnet aims from the head toward this point, so it needs to
	-- be exactly centred.
	crosshair = create("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(CROSSHAIR_BASE, CROSSHAIR_BASE),
		BackgroundColor3 = Theme.Colors.Text,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Parent = gui,
	}, {
		create("UICorner", { CornerRadius = UDim.new(1, 0) }),
	})

	runFrame = create("Frame", {
		Name = "RunPanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 18),
		Size = UDim2.fromOffset(320, 118),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Visible = false,
		Parent = gui,
	})
	Theme.decorate(runFrame, 12)

	stageLabel = create("TextLabel", {
		Name = "Stage",
		Position = UDim2.new(0, 0, 0, 8),
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 14,
		Parent = runFrame,
	})

	timerLabel = create("TextLabel", {
		Name = "Timer",
		Position = UDim2.new(0, 0, 0, 26),
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "0.000",
		TextColor3 = Theme.Colors.Text,
		TextSize = 36,
		Parent = runFrame,
	})

	paceLabel = create("TextLabel", {
		Name = "Pace",
		Position = UDim2.new(0, 0, 0, 68),
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Medal.Gold,
		TextSize = 14,
		Parent = runFrame,
	})

	checkpointLabel = create("TextLabel", {
		Name = "Checkpoints",
		Position = UDim2.new(0, 0, 0, 88),
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 13,
		Parent = runFrame,
	})

	splitLabel = create("TextLabel", {
		Name = "Split",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 142),
		Size = UDim2.fromOffset(300, 26),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "",
		TextColor3 = Theme.Colors.Accent,
		TextSize = 20,
		TextTransparency = 1,
		Parent = gui,
	})

	-- Hand cooldown readouts.
	local handFrame = create("Frame", {
		Name = "Hands",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -20),
		Size = UDim2.fromOffset(190, 46),
		BackgroundTransparency = 1,
		Parent = gui,
	})

	local function makeHand(name: string, label: string, color: Color3, y: number): Frame
		local row = create("Frame", {
			Name = name,
			Position = UDim2.new(0, 0, 0, y),
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundTransparency = 1,
			Parent = handFrame,
		})

		create("TextLabel", {
			Size = UDim2.fromOffset(74, 20),
			BackgroundTransparency = 1,
			Font = Theme.Font,
			Text = label,
			TextColor3 = Theme.Colors.TextDim,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})

		local track = create("Frame", {
			Name = "Track",
			Position = UDim2.new(0, 78, 0, 7),
			Size = UDim2.new(1, -78, 0, 6),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Parent = row,
		})
		create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })

		local fill = create("Frame", {
			Name = "Fill",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = track,
		})
		create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })

		return fill
	end

	pullBar = makeHand("Pull", "왼손 PULL", Theme.Colors.Accent, 0)
	pushBar = makeHand("Push", "오른손 PUSH", Theme.Colors.AccentWarm, 24)
end

local function flashSplit(text: string, color: Color3)
	splitLabel.Text = text
	splitLabel.TextColor3 = color
	splitLabel.TextTransparency = 0
	splitLabel.Position = UDim2.new(0.5, 0, 0, 142)

	TweenService:Create(splitLabel, TweenInfo.new(1.4, Enum.EasingStyle.Quad), {
		TextTransparency = 1,
		Position = UDim2.new(0.5, 0, 0, 122),
	}):Play()
end

local function onRunUpdate(update)
	if update.kind == "Started" then
		local definition = StageConfig.Get(update.stageId)
		stageLabel.Text = if definition then definition.displayName else update.stageId
		runFrame.Visible = true
		checkpointLabel.Text = ""
	elseif update.kind == "Checkpoint" then
		flashSplit(
			`체크포인트 {update.checkpointIndex}/{update.checkpointTotal} · {TimeFormat.Clock(update.elapsedMs or 0)}`,
			Theme.Colors.Accent
		)
	elseif update.kind == "Aborted" then
		runFrame.Visible = false
		if update.rejectReason == "died" then
			flashSplit("기록 무효 · 사망", Theme.Colors.Bad)
		end
	elseif update.kind == "Finished" then
		runFrame.Visible = false
		if update.rejected then
			flashSplit(`기록 무효 · {update.rejectReason or "검증 실패"}`, Theme.Colors.Bad)
		end
		-- A new personal best changes what the pace chip should aim at next run.
		refreshRecords()
	end
end

function Hud.Start()
	buildGui()

	RunState.Changed:Connect(onRunUpdate)

	refreshRecords()

	RunService.RenderStepped:Connect(function()
		pullBar.Size = UDim2.fromScale(1 - MagnetController.CooldownAlpha("Pull"), 1)
		pushBar.Size = UDim2.fromScale(1 - MagnetController.CooldownAlpha("Push"), 1)

		-- The crosshair opens up with speed. It carries no mechanical meaning —
		-- aim assist is server-side and unchanged — but it puts the speed cue in
		-- the one place the player is already looking.
		local spread = CROSSHAIR_BASE + CROSSHAIR_SPREAD * MagnetEffects.SpeedAlpha()
		crosshair.Size = UDim2.fromOffset(spread, spread)

		if not RunState.IsActive() then
			return
		end

		local elapsed = RunState.Elapsed()
		timerLabel.Text = TimeFormat.Clock(elapsed)

		local text, color = paceFor(RunState.StageId(), elapsed)
		paceLabel.Text = text
		paceLabel.TextColor3 = color

		local index, total = RunState.Checkpoints()
		checkpointLabel.Text = if total > 0 then `체크포인트 {index}/{total}` else ""
	end)
end

return Hud
