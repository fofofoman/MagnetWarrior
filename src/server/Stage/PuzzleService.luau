--!nonstrict
--[[
	PuzzleService.luau — 철제 블록 조립

	Sockets are the puzzle primitive. A socket declares a group; a block declares
	the same group; drop the block close enough to the socket and it locks in.
	Fill every socket in a group and the group completes, which is what GateService
	watches to open a door or solidify a bridge.

	Placement is checked on the server against the block's real position, so
	"assembling" a puzzle by telling the server a block is somewhere it is not is
	not a thing a client can do.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Signal = require(Shared.Util.Signal)

local PuzzleService = {}

local CHECK_RATE = 10 -- Hz
local SNAP_RADIUS = 6.5 -- studs from socket centre
local SNAP_MAX_SPEED = 26 -- a block still flying past does not count as placed

type SocketState = {
	part: BasePart,
	stageId: string,
	group: string,
	filledBy: BasePart?,
}

type BlockState = {
	part: BasePart,
	stageId: string,
	group: string,
	homeCFrame: CFrame,
	placed: boolean,
}

local sockets: { [BasePart]: SocketState } = {}
local blocks: { [BasePart]: BlockState } = {}
local completedGroups: { [string]: boolean } = {}

PuzzleService.SocketFilled = Signal.new() -- (stageId, group, filled, total)
PuzzleService.GroupCompleted = Signal.new() -- (stageId, group)

local function groupKey(stageId: string, group: string): string
	return `{stageId}::{group}`
end

local function registerSocket(instance: Instance)
	if not instance:IsA("BasePart") or sockets[instance] then
		return
	end
	local stageId = instance:GetAttribute("StageId")
	local group = instance:GetAttribute("PuzzleGroup")
	if typeof(stageId) ~= "string" or typeof(group) ~= "string" then
		warn(`[PuzzleService] socket {instance:GetFullName()} is missing StageId/PuzzleGroup`)
		return
	end
	sockets[instance] = { part = instance, stageId = stageId, group = group, filledBy = nil }
end

local function registerBlock(instance: Instance)
	if not instance:IsA("BasePart") or blocks[instance] then
		return
	end
	local stageId = instance:GetAttribute("StageId")
	local group = instance:GetAttribute("PuzzleGroup")
	if typeof(stageId) ~= "string" or typeof(group) ~= "string" then
		warn(`[PuzzleService] block {instance:GetFullName()} is missing StageId/PuzzleGroup`)
		return
	end
	blocks[instance] = {
		part = instance,
		stageId = stageId,
		group = group,
		homeCFrame = instance.CFrame,
		placed = false,
	}
end

local function groupCounts(stageId: string, group: string): (number, number)
	local filled, total = 0, 0
	for _, socket in sockets do
		if socket.stageId == stageId and socket.group == group then
			total += 1
			if socket.filledBy then
				filled += 1
			end
		end
	end
	return filled, total
end

local function place(socket: SocketState, block: BlockState)
	socket.filledBy = block.part
	block.placed = true

	local part = block.part
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.CFrame = CFrame.new(socket.part.Position + Vector3.new(0, part.Size.Y / 2, 0))
	part.Anchored = true

	-- Locked in: a placed block is no longer magnetic, so a later Push cannot
	-- knock a finished puzzle apart.
	CollectionService:RemoveTag(part, GameConfig.Tags.Magnetic)

	socket.part.Transparency = 0.15
	socket.part.Color = Color3.fromRGB(120, 255, 168)

	local filled, total = groupCounts(socket.stageId, socket.group)
	PuzzleService.SocketFilled:Fire(socket.stageId, socket.group, filled, total)

	if filled == total and total > 0 then
		local key = groupKey(socket.stageId, socket.group)
		if not completedGroups[key] then
			completedGroups[key] = true
			PuzzleService.GroupCompleted:Fire(socket.stageId, socket.group)
		end
	end
end

local function step()
	for _, socket in sockets do
		if socket.filledBy then
			if socket.filledBy.Parent then
				continue
			end
			socket.filledBy = nil -- block was destroyed; socket opens back up
		end

		local socketPosition = socket.part.Position

		for _, block in blocks do
			if
				block.placed
				or block.stageId ~= socket.stageId
				or block.group ~= socket.group
				or not block.part.Parent
			then
				continue
			end

			if (block.part.Position - socketPosition).Magnitude > SNAP_RADIUS then
				continue
			end
			if block.part.AssemblyLinearVelocity.Magnitude > SNAP_MAX_SPEED then
				continue
			end

			place(socket, block)
			break
		end
	end
end

--- Returns a stage's puzzles to their starting state.
function PuzzleService.ResetStage(stageId: string)
	for _, socket in sockets do
		if socket.stageId ~= stageId then
			continue
		end
		socket.filledBy = nil
		socket.part.Transparency = 0.55
		socket.part.Color = Color3.fromRGB(255, 206, 84)
		completedGroups[groupKey(stageId, socket.group)] = nil
	end

	for _, block in blocks do
		if block.stageId ~= stageId or not block.part.Parent then
			continue
		end
		block.placed = false
		block.part.Anchored = false
		block.part.AssemblyLinearVelocity = Vector3.zero
		block.part.AssemblyAngularVelocity = Vector3.zero
		block.part.CFrame = block.homeCFrame
		if not CollectionService:HasTag(block.part, GameConfig.Tags.Magnetic) then
			CollectionService:AddTag(block.part, GameConfig.Tags.Magnetic)
		end
	end
end

function PuzzleService.IsGroupComplete(stageId: string, group: string): boolean
	return completedGroups[groupKey(stageId, group)] == true
end

function PuzzleService.Start()
	for _, instance in CollectionService:GetTagged(GameConfig.Tags.PuzzleSocket) do
		registerSocket(instance)
	end
	for _, instance in CollectionService:GetTagged(GameConfig.Tags.PuzzleBlock) do
		registerBlock(instance)
	end

	CollectionService:GetInstanceAddedSignal(GameConfig.Tags.PuzzleSocket):Connect(registerSocket)
	CollectionService:GetInstanceAddedSignal(GameConfig.Tags.PuzzleBlock):Connect(registerBlock)
	CollectionService:GetInstanceRemovedSignal(GameConfig.Tags.PuzzleSocket):Connect(function(instance)
		sockets[instance :: BasePart] = nil
	end)
	CollectionService:GetInstanceRemovedSignal(GameConfig.Tags.PuzzleBlock):Connect(function(instance)
		blocks[instance :: BasePart] = nil
	end)

	local accumulator = 0
	local interval = 1 / CHECK_RATE
	RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < interval then
			return
		end
		accumulator = 0
		step()
	end)
end

return PuzzleService
