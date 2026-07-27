--!nonstrict
--[[
	GateService.luau

	Gates are the one thing both content pillars need: combat rooms open when the
	arena is cleared, puzzle rooms open when the sockets are filled. Rather than
	two systems, a gate declares what opens it (`OpenByKind` / `OpenByGroup`) and
	this module subscribes to both sources.
]]

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Signal = require(Shared.Util.Signal)
local SoundKit = require(Shared.Util.SoundKit)

local EnemyService = require(script.Parent.Parent.Combat.EnemyService)
local PuzzleService = require(script.Parent.PuzzleService)

local GateService = {}

local GATE_TAG = GameConfig.Tags.Gate
local OPEN_TIME = 0.6

type GateState = {
	part: BasePart,
	stageId: string,
	gateId: string,
	openByKind: string,
	openByGroup: string,
	closedCFrame: CFrame,
	open: boolean,
	--- The in-flight open animation, kept so a reset can cancel it.
	tween: Tween?,
}

local gates: { [BasePart]: GateState } = {}

GateService.GateOpened = Signal.new() -- (stageId, gateId)

local function register(instance: Instance)
	if not instance:IsA("BasePart") or gates[instance] then
		return
	end

	local stageId = instance:GetAttribute("StageId")
	local gateId = instance:GetAttribute("GateId")
	if typeof(stageId) ~= "string" or typeof(gateId) ~= "string" then
		return
	end

	gates[instance] = {
		part = instance,
		stageId = stageId,
		gateId = gateId,
		openByKind = instance:GetAttribute("OpenByKind") or "Enemies",
		openByGroup = instance:GetAttribute("OpenByGroup") or "default",
		closedCFrame = instance.CFrame,
		open = false,
		tween = nil,
	}
end

local function openGate(state: GateState)
	if state.open or not state.part.Parent then
		return
	end
	state.open = true

	-- Sink into the floor rather than vanishing, so the change is legible from
	-- across the room.
	local target = state.closedCFrame - Vector3.new(0, state.part.Size.Y + 1, 0)
	state.part.CanCollide = false

	local tween = TweenService:Create(state.part, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad), {
		CFrame = target,
	})
	state.tween = tween
	tween:Play()

	SoundKit.PlayAt("GateOpen", state.part.Position)

	GateService.GateOpened:Fire(state.stageId, state.gateId)
end

local function closeGate(state: GateState)
	if not state.part.Parent then
		return
	end

	-- Cancel first. A stage reset that lands inside the 0.6s slide would otherwise
	-- leave the tween running after the CFrame was restored, dragging the gate
	-- back into the floor while this function has already marked it solid and
	-- closed — a barrier that is not there, which quietly skips a whole room.
	if state.tween then
		state.tween:Cancel()
		state.tween = nil
	end

	state.open = false
	state.part.CFrame = state.closedCFrame
	state.part.CanCollide = true
end

local function onCondition(kind: string, stageId: string, group: string)
	for _, state in gates do
		if state.stageId == stageId and state.openByKind == kind and state.openByGroup == group then
			openGate(state)
		end
	end
end

function GateService.CloseStage(stageId: string)
	for _, state in gates do
		if state.stageId == stageId then
			closeGate(state)
		end
	end
end

function GateService.Start()
	for _, instance in CollectionService:GetTagged(GATE_TAG) do
		register(instance)
	end
	CollectionService:GetInstanceAddedSignal(GATE_TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(GATE_TAG):Connect(function(instance)
		gates[instance :: BasePart] = nil
	end)

	EnemyService.GroupCleared:Connect(function(stageId: string, group: string)
		onCondition("Enemies", stageId, group)
	end)

	PuzzleService.GroupCompleted:Connect(function(stageId: string, group: string)
		onCondition("Sockets", stageId, group)
	end)
end

GateService.Tag = GATE_TAG

return GateService
