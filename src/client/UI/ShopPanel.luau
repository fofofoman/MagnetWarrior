--!nonstrict
--[[
	ShopPanel.luau — 상점 & 외형

	Two tabs over the same entitlement state:

	  • **상점** — every game pass and developer product from MonetizationConfig,
	    with what it does. Owned passes say so instead of offering a second sale.
	  • **외형** — the cosmetic slots. Options the player owns are selectable;
	    the rest are shown greyed with the pass that unlocks them, and clicking
	    one opens that purchase rather than silently doing nothing.

	The options offered here come from `MonetizationConfig.CosmeticOptions`, the
	same table the server validates against, so the UI cannot drift into offering
	something the server would refuse. Nothing sold here touches gameplay — see
	docs/MONETIZATION.md.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local Net = require(Shared.Net)

local SoundKit = require(Shared.Util.SoundKit)
local Theme = require(script.Parent.Theme)

local ShopPanel = {}

local create = Theme.create
local player = Players.LocalPlayer

local gui: ScreenGui
local contentList: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}

local entitlements = { passes = {}, consumables = {} }
local activeTab = "Shop"
local isOpen = false

local function owns(key: string): boolean
	return entitlements.passes[key] == true
end

local function clear()
	for _, child in contentList:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function makeCard(height: number): Frame
	local frame = create("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Parent = contentList,
	})
	Theme.decorate(frame, 8)
	return frame
end

local function addTitle(parent: Instance, text: string, subtitle: string)
	create("TextLabel", {
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.new(1, -150, 0, 20),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = text,
		TextColor3 = Theme.Colors.Text,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	})

	create("TextLabel", {
		Position = UDim2.fromOffset(14, 30),
		Size = UDim2.new(1, -150, 0, 32),
		BackgroundTransparency = 1,
		Font = Theme.Font,
		Text = subtitle,
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Parent = parent,
	})
end

local function addActionButton(parent: Instance, text: string, enabled: boolean, onClick: () -> ())
	local button = create("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(112, 32),
		BackgroundColor3 = if enabled then Theme.Colors.Accent else Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
		AutoButtonColor = enabled,
		Font = Theme.FontBold,
		Text = text,
		TextColor3 = if enabled then Theme.Colors.Background else Theme.Colors.TextDim,
		TextSize = 13,
		Parent = parent,
	})
	create("UICorner", { CornerRadius = UDim.new(0, 7), Parent = button })

	if enabled then
		Theme.clickable(button)
		button.Activated:Connect(onClick)
	end
	return button
end

local function renderShop()
	local function section(products, isPass: boolean)
		for _, product in products do
			local card = makeCard(76)

			local suffix = if product.assetId == 0 then "  (판매 준비 중)" else ""
			addTitle(card, product.displayName .. suffix, product.description)

			if isPass and owns(product.key) then
				addActionButton(card, "보유 중", false, function() end)
			else
				local count = entitlements.consumables[product.key]
				local label = if isPass
					then "구매"
					elseif count and count > 0 then `구매 (보유 {count})`
					else "구매"

				addActionButton(card, label, product.assetId ~= 0, function()
					Net.RequestPurchase:FireServer({ productKey = product.key })
				end)
			end
		end
	end

	create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "게임패스",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = contentList,
	})
	section(MonetizationConfig.GamePasses, true)

	create("TextLabel", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "아이템",
		TextColor3 = Theme.Colors.TextDim,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Parent = contentList,
	})
	section(MonetizationConfig.DeveloperProducts, false)
end

local function renderCosmetics()
	for _, slotName in MonetizationConfig.OrderedCosmeticSlots() do
		local slot = MonetizationConfig.CosmeticSlots[slotName]
		local options = MonetizationConfig.CosmeticOptions(slotName)
		local unlocked = owns(slot.passKey)
		local current = player:GetAttribute(slot.attribute)

		local rows = math.ceil(#options / 4)
		local card = makeCard(40 + rows * 34)

		create("TextLabel", {
			Position = UDim2.fromOffset(14, 8),
			Size = UDim2.new(1, -28, 0, 20),
			BackgroundTransparency = 1,
			Font = Theme.FontBold,
			Text = slot.displayName,
			TextColor3 = Theme.Colors.Text,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})

		local grid = create("Frame", {
			Position = UDim2.fromOffset(14, 32),
			Size = UDim2.new(1, -28, 1, -40),
			BackgroundTransparency = 1,
			Parent = card,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.fromOffset(112, 28),
				CellPadding = UDim2.fromOffset(6, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})

		for index, value in options do
			local isDefault = value == slot.default
			local available = isDefault or unlocked
			local selected = current == value

			local button = create("TextButton", {
				LayoutOrder = index,
				BackgroundColor3 = if selected
					then Theme.Colors.Accent
					elseif available then Theme.Colors.PanelRaised
					else Theme.Colors.Panel,
				BackgroundTransparency = if available then 0 else 0.4,
				BorderSizePixel = 0,
				Font = Theme.Font,
				Text = if available then value else `{value} 🔒`,
				TextColor3 = if selected
					then Theme.Colors.Background
					elseif available then Theme.Colors.Text
					else Theme.Colors.TextDim,
				TextSize = 12,
				Parent = grid,
			})
			create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = button })
			Theme.clickable(button)

			button.Activated:Connect(function()
				if available then
					Net.SetCosmetic:FireServer({ slot = slotName, value = value })
				else
					-- A locked swatch is the most honest place to offer the pack
					-- that unlocks it.
					Net.RequestPurchase:FireServer({ productKey = slot.passKey })
				end
			end)
		end
	end
end

local function render()
	clear()
	if activeTab == "Shop" then
		renderShop()
	else
		renderCosmetics()
	end
end

local function setTab(tab: string)
	activeTab = tab
	for id, button in tabButtons do
		local isActive = id == tab
		button.BackgroundColor3 = if isActive then Theme.Colors.Accent else Theme.Colors.PanelRaised
		button.TextColor3 = if isActive then Theme.Colors.Background else Theme.Colors.TextDim
	end
	render()
end

local function build()
	gui = create("ScreenGui", {
		Name = "MagnetWarriorShop",
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
		ShopPanel.Toggle(false)
	end)

	local root = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(520, 440),
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		Parent = gui,
	})
	Theme.decorate(root, 14)

	create("TextLabel", {
		Position = UDim2.fromOffset(20, 16),
		Size = UDim2.new(1, -60, 0, 26),
		BackgroundTransparency = 1,
		Font = Theme.FontBold,
		Text = "상점",
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
		ShopPanel.Toggle(false)
	end)

	local tabRow = create("Frame", {
		Position = UDim2.fromOffset(20, 50),
		Size = UDim2.new(1, -40, 0, 28),
		BackgroundTransparency = 1,
		Parent = root,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
		}),
	})

	for _, tab in { { id = "Shop", label = "상점" }, { id = "Cosmetics", label = "외형" } } do
		local button = create("TextButton", {
			Size = UDim2.fromOffset(80, 28),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Font = Theme.Font,
			Text = tab.label,
			TextColor3 = Theme.Colors.TextDim,
			TextSize = 13,
			Parent = tabRow,
		})
		create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = button })
		Theme.clickable(button)
		tabButtons[tab.id] = button
		button.Activated:Connect(function()
			setTab(tab.id)
		end)
	end

	contentList = create("ScrollingFrame", {
		Position = UDim2.fromOffset(20, 88),
		Size = UDim2.new(1, -40, 1, -108),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Stroke,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = root,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
end

function ShopPanel.Toggle(open: boolean?)
	isOpen = if open == nil then not isOpen else open
	gui.Enabled = isOpen
	if isOpen then
		SoundKit.PlayLocal("PanelOpen")
		render()
	end
end

--- Consumable count, so other UI (the retry prompt) can show what is banked.
function ShopPanel.ConsumableCount(key: string): number
	return entitlements.consumables[key] or 0
end

function ShopPanel.Start()
	build()
	setTab("Shop")

	Net.EntitlementsChanged.OnClientEvent:Connect(function(snapshot)
		if typeof(snapshot) ~= "table" then
			return
		end
		entitlements = snapshot
		if isOpen then
			render()
		end
	end)

	-- Cosmetics are published as Player attributes, so a change made anywhere
	-- (including a server-side reset after a refund) refreshes the swatches.
	for _, slotName in MonetizationConfig.OrderedCosmeticSlots() do
		local slot = MonetizationConfig.CosmeticSlots[slotName]
		player:GetAttributeChangedSignal(slot.attribute):Connect(function()
			if isOpen and activeTab == "Cosmetics" then
				render()
			end
		end)
	end

	task.spawn(function()
		local ok, snapshot = pcall(function()
			return Net.GetEntitlements:InvokeServer()
		end)
		if ok and typeof(snapshot) == "table" then
			entitlements = snapshot
			if isOpen then
				render()
			end
		end
	end)

	ContextActionService:BindAction("ToggleShop", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			ShopPanel.Toggle()
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.B, Enum.KeyCode.ButtonY)

	ContextActionService:SetTitle("ToggleShop", "상점")
	ContextActionService:SetPosition("ToggleShop", UDim2.new(1, -180, 1, -280))
end

return ShopPanel
