--!nonstrict
--[[
	StageActivity.luau

	Answers one question: is anybody near this stage?

	All twelve stages are built into the same place and simulated at once, so
	without this the server spends most of its budget moving walls nobody is
	looking at and flying drones toward players who are 20,000 studs away. Enemy
	AI, kinetic walls and boss patterns all check here before doing work.

	It is deliberately a leaf module with no dependencies beyond Players, so
	every system that needs it can require it without creating a cycle —
	StageService already requires most of them.

	The radius is generous on purpose. A wall that starts moving only once a
	player can see it would visibly snap into place; waking a stage well before
	it comes into view means the phase has always been running by the time anyone
	looks at it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local StageActivity = {}

local WAKE_RADIUS = 900 -- studs from the stage origin
local CHECK_RATE = 2 -- Hz; stages are 2000 studs apart, nobody crosses that fast

--- Stages are spaced along X, so a scalar origin is all the comparison needs.
local origins: { [string]: number } = {}
local awake: { [string]: boolean } = {}
local anyPlayers = false

--- Registered by StageService as it builds each stage.
function StageActivity.Register(stageId: string, originX: number)
	origins[stageId] = originX
	awake[stageId] = false
end

--- True when a player is close enough for this stage's simulation to matter.
--- Unknown stages report awake: a system that has not registered its origin
--- should keep working rather than silently freeze.
function StageActivity.IsAwake(stageId: string?): boolean
	if not stageId then
		return true
	end
	if origins[stageId] == nil then
		return true
	end
	return awake[stageId] == true
end

--- For systems that know a world position but not which stage it belongs to.
function StageActivity.IsPositionAwake(position: Vector3): boolean
	if not anyPlayers then
		return false
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and math.abs(root.Position.X - position.X) <= WAKE_RADIUS then
			return true
		end
	end
	return false
end

local function refresh()
	local positions: { number } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			table.insert(positions, root.Position.X)
		end
	end

	anyPlayers = #positions > 0

	for stageId, originX in origins do
		local near = false
		for _, x in positions do
			if math.abs(x - originX) <= WAKE_RADIUS then
				near = true
				break
			end
		end
		awake[stageId] = near
	end
end

--- Diagnostic: which stages are currently simulating.
function StageActivity.AwakeStages(): { string }
	local list = {}
	for stageId, isAwake in awake do
		if isAwake then
			table.insert(list, stageId)
		end
	end
	table.sort(list)
	return list
end

function StageActivity.Start()
	local accumulator = 0
	local interval = 1 / CHECK_RATE

	RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < interval then
			return
		end
		accumulator = 0
		refresh()
	end)
end

return StageActivity
