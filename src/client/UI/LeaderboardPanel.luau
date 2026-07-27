--!nonstrict
--[[
	LeaderboardPanel.luau — 랭킹판 + 스테이지 선택

	Left: the twelve-stage roster with each stage's personal best and best medal.
	Right: the ranking board for the selected stage, in three scopes.

	The scopes mirror the rollout order. 개인 and 친구 are live. 글로벌 is present
	and selectable, but the server answers it with `unavailableReason` while
	GameConfig.Features.GlobalLeaderboard is off, and this panel renders that
	reason rather than hiding the tab — so phase 2 is a server-side flag flip,
	not a client change.

	Lock state is shown here as a courtesy. The server independently refuses a
	teleport to a locked stage, so a modified client that enables every button
	gains nothing.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local StageConfig = require(Shared.Config.StageConfig)
local TimeFormat = require(Shared.Util.TimeFormat)

local Theme = require(script.Parent.Theme)

local LeaderboardPanel = {}

local create = Theme.create
local player = Players.LocalPlayer

local SCOPES = { { id = "Personal", label = "개인" }, { id = "Friends", label = "친구" }, { id = "Global", label = "글로벌" } }

local gui: ScreenGui
local root: Frame
local stageList: ScrollingFrame
local entryList: ScrollingFrame
local headerLabel: TextLabel
local medalLabel: TextLabel
local statusLabel: TextLabel
local teleportButton: TextButton
local scopeButtons: { [string]: TextButton } = {}

local roster: { any } = {}
local records: { [string]: any } = {}
local selectedStageId: string? = nil
local selectedScope = "Personal"
local requestToken = 0
local isOpen = false

-- ─────────────────────────────────────────────────────────────────────────────
-- Rendering
-- ─────────────────────────────────────────────────────────────────────────────

local function clear(container: Instance)
	for _, child in container:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function renderEntries(payload: any)
	clear(entryList)

	if not payload then
		statusLabel.Text = "랭킹을 불러오지 못했습니다."
		return
	end

	if payload.unavailableReason then
		statusLabel.Text = payload.unavailableReason
		return
	end

	if #payload.entries == 0 then
		statusLabel.Text = if payload.scope == "Personal"
			then "아직 이 스테이지를 클리어하지 않았습니다."
			else "표시할 기록이 없습니다."
		return
	end

	statusLabel.Text = ""

	for _, entry in payload.entries do
		local row = create("Frame", {
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = if entry.userId == player.UserId
				then Theme.Colors.PanelRaised
				else Theme.Colors.Panel,
			BackgroundTransparency = if entry.userId == player.UserId then 0 else 0.4,
			BorderSizePixel = 0,
			Parent = entryList,
		})
		create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = row })

		create("TextLabel", {
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.fromOffset(34, 34),
			BackgroundTransparency = 1,
			Font = Theme.FontBold,
			Text = `{entry.rank}`,
			TextColor3 = Theme.Colors.TextDim,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})

		create("TextLabel", {
			Position = UDim2.fromOffset(48, 0),
			Size = UDim2.new(1, -190, 1, 0),
			BackgroundTransparency = 1,
			Font = Theme.Font,
			Text = entry.displayName,
			TextColor3 = Theme.Colors.Text,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})

		create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -74, 0, 0),
			Size = UDim2.fromOffset(60, 34),
			BackgroundTransparency = 1,
			Font = Theme.Font,
			Text = Theme.MedalLabel[entry.medal] or "",
			TextColor3 = Theme.Medal[entry.medal] or Theme.Medal.None,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})

		create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.fromOffset(64, 34),
			BackgroundTransparency = 1,
			Font = Theme.FontBold,
			Text = TimeFormat.Short(entry.timeMs),
			TextColor3 = Theme.Colors.Text,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})
	end

	entryList.CanvasSize = UDim2.fromOffset(0, #payload.entries * 38)
end

local function requestBoard()
	local stageId = selectedStageId
	if not stageId then
		return
	end

	requestToken += 1
	local token = requestToken

	clear(entryList)
	statusLabel.Text = "불러오는 중…"

	task.spawn(function()
		local ok, payload = pcall(function()
			return Net.GetLeaderboard:InvokeServer(stageId, selectedScope)
		end)

		-- A slower earlier request must not overwrite a newer selection.
		if token ~= requestToken then
			return
		end

		renderEntries(if ok then payload else nil)
	end)
end

local function selectStage(stageId: string)
	selectedStageId = stageId

	local definition = StageConfig.Get(stageId)
	if definition then
		headerLabel.Text = definition.displayName
		medalLabel.Text = string.format(
			"골드 %s   실버 %s   브론즈 %s",
			TimeFormat.Short(definition.medals.Gold),
			TimeFormat.Short(definition.medals.Silver),
			TimeFormat.Short(definition.medals.Bronze)
		)
	end

	local entry
	for _, candidate in roster do
		if candidate.id == stageId then
			entry = candidate
			break
		end
	end

	local canPlay = entry ~= nil and entry.playable and entry.unlocked
	teleportButton.Text = if entry == nil
		then "이동"
		elseif not entry.playable then "준비 중"
		elseif not entry.unlocked then "잠김"
		else "이 스테이지로 이동"
	teleportButton.BackgroundColor3 = if canPlay then Theme.Colors.Accent else Theme.Colors.PanelRaised
	teleportButton.TextColor3 = if canPlay then Theme.Colors.Background else Theme.Colors.TextDim
	teleportButton:SetAttribute("Enabled", canPlay)

	requestBoard()
end

local function renderRoster()
	clear(stageList)

	for _, entry in roster do
		local record = records[entry.id]
		local locked = not entry.unlocked or not entry.playable

		local row = create("TextButton", {
			Size = UDim2.new(1, 0, 0, 46),
			BackgroundColor3 = Theme.Colors.Panel,
			BackgroundTransparency = if locked then 0.6 else 0.25,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Text = "",
			Parent = stageList,
		})
		create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = row })

		create("TextLabel", {
			Position = UDim2.fromOffset(10, 4),
			Size = UDim2.new(1, -80, 0, 20),
			BackgroundTransparency = 1,
			Font = Theme.FontBold,
			Text = `{entry.order}. {entry.displayName}`,
			TextColor3 = if locked then Theme.Colors.TextDim else Theme.Colors.Text,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})

		local subtitle
		if not entry.playable then
			subtitle = "준비 중"
		elseif not entry.unlocked then
			subtitle = "잠김"
		elseif record then
			subtitle = `최고 {TimeFormat.Short(record.bestTimeMs)}`
		else
			subtitle = "미클리어"
		end

		create("TextLabel", {
			Position = UDim2.fromOffset(10, 24),
			Size = UDim2.new(1, -80, 0, 16),
			BackgroundTransparency = 1,
			Font = Theme.Font,
			Text = subtitle,
			TextColor3 = Theme.Colors.TextDim,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})

		local medal = if record then record.medal else "None"
		create("TextLabel", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(60, 20),
			BackgroundTransparency = 1,
			Font = Theme.FontBold,
			Text = if medal == "None" then "" else Theme.MedalLabel[medal],
			TextColor3 = Theme.Medal[medal] or Theme.Medal.None,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})

		row.Activated:Connect(function()
			selectStage(entry.id)
		end)
	end

	stageList.CanvasSize = UDim2.fromOffset(0, #roster * 50)
end

local function refresh()
	task.spawn(function()
		local okRoster, rosterResult = pcall(function()
			return Net.GetStageRoster:InvokeServer()
		end)
		local okRecords, recordResult = pcall(function()
			return Net.GetRecords:InvokeServer()
		end)

		roster = if okRoster and typeof(rosterResult) == "table" then rosterResult else {}
		records = if okRecords and typeof(recordResult) == "table" then recordResult else {}

		renderRoster()

		if selectedStageId then
			selectStage(selectedStageId)
		elseif #roster > 0 then
			selectStage(roster[1].id)
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────────────────────────

local function build()
	gui = create("ScreenGui", {
		Name = "MagnetWarriorBoard",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})

	create("TextButton", {
		Name = "Scrim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Background,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Parent = gui,
	}).Activated:Connect(function()
		LeaderboardPanel.Toggle(false)
	end)

	root = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 460),
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		Parent = gui,
	})
	Theme.decorate(root, 14)

	create("TextLabel", {
		Position = UDim2.fromOffset(24, 16),
		Size = UDim2.new(1, -48, 0, 26),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "스테이지 & 랭킹",
		TextColor3 = Theme.Colors.Text,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = root,
	})

	local closeButton = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 16),
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		Font = Theme.FontBold,
		Text = "×",
		TextColor3 = Theme.Colors.Text,
		TextSize = 18,
		Parent = root,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = closeButton })
	closeButton.Activated:Connect(function()
		LeaderboardPanel.Toggle(false)
	end)

	-- Left: stage roster.
	stageList = create("ScrollingFrame", {
		Name = "Stages",
		Position = UDim2.fromOffset(20, 56),
		Size = UDim2.new(0, 320, 1, -76),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Stroke,
		CanvasSize = UDim2.new(),
		Parent = root,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	-- Right: board.
	local boardFrame = create("Frame", {
		Name = "Board",
		Position = UDim2.fromOffset(356, 56),
		Size = UDim2.new(1, -376, 1, -76),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Parent = root,
	})
	Theme.decorate(boardFrame, 10)

	headerLabel = create("TextLabel", {
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 22),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "",
		TextColor3 = Theme.Colors.Text,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = boardFrame,
	})

	medalLabel = create("TextLabel", {
		Position = UDim2.fromOffset(16, 34),
		Size = UDim2.new(1, -32, 0, 16),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = boardFrame,
	})

	local tabRow = create("Frame", {
		Position = UDim2.fromOffset(16, 58),
		Size = UDim2.new(1, -32, 0, 28),
		BackgroundTransparency = 1,
		Parent = boardFrame,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
		}),
	})

	local function setScope(scope: string)
		selectedScope = scope
		for id, button in scopeButtons do
			local activeTab = id == scope
			button.BackgroundColor3 = if activeTab then Theme.Colors.Accent else Theme.Colors.PanelRaised
			button.TextColor3 = if activeTab then Theme.Colors.Background else Theme.Colors.TextDim
		end
		requestBoard()
	end

	for _, scope in SCOPES do
		local button = create("TextButton", {
			Size = UDim2.fromOffset(72, 28),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Font = Theme.Font,
			Text = scope.label,
			TextColor3 = Theme.Colors.TextDim,
			TextSize = 13,
			Parent = tabRow,
		})
		create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = button })
		scopeButtons[scope.id] = button
		button.Activated:Connect(function()
			setScope(scope.id)
		end)
	end

	entryList = create("ScrollingFrame", {
		Name = "Entries",
		Position = UDim2.fromOffset(16, 94),
		Size = UDim2.new(1, -32, 1, -152),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Stroke,
		CanvasSize = UDim2.new(),
		Parent = boardFrame,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	statusLabel = create("TextLabel", {
		Position = UDim2.fromOffset(16, 100),
		Size = UDim2.new(1, -32, 0, 20),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = boardFrame,
	})

	teleportButton = create("TextButton", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -32, 0, 34),
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		Font = Theme.FontBold,
		Text = "이 스테이지로 이동",
		TextColor3 = Theme.Colors.Background,
		TextSize = 14,
		Parent = boardFrame,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = teleportButton })

	teleportButton.Activated:Connect(function()
		if not selectedStageId or teleportButton:GetAttribute("Enabled") ~= true then
			return
		end
		Net.RequestStageTeleport:FireServer({ stageId = selectedStageId })
		LeaderboardPanel.Toggle(false)
	end)

	setScope("Personal")
end

function LeaderboardPanel.Toggle(open: boolean?)
	isOpen = if open == nil then not isOpen else open
	gui.Enabled = isOpen
	if isOpen then
		refresh()
	end
end

function LeaderboardPanel.Start()
	build()

	ContextActionService:BindAction("ToggleBoard", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			LeaderboardPanel.Toggle()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.Tab, Enum.KeyCode.ButtonSelect)

	ContextActionService:SetTitle("ToggleBoard", "랭킹")
	ContextActionService:SetPosition("ToggleBoard", UDim2.new(1, -100, 1, -280))

	-- Records change the moment a run is stored, so refresh while open.
	Net.RunUpdate.OnClientEvent:Connect(function(update)
		if isOpen and typeof(update) == "table" and update.kind == "Finished" then
			refresh()
		end
	end)
end

return LeaderboardPanel
