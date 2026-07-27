--!nonstrict
--[[
	Net.luau
	Single source of truth for every remote in the game.

	The server creates the instances at boot; the client waits for them. Both
	sides index the same names, so a typo becomes a nil-index at startup rather
	than a silently dead feature.

		local Net = require(ReplicatedStorage.Shared.Net)
		Net.MagnetAction:FireServer(payload)

	Direction is documented per remote below. Nothing here validates payloads —
	that is the receiving server system's job, and every server handler in this
	project treats the payload as hostile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Net"
local WAIT_TIMEOUT = 30

type RemoteKind = "Event" | "Function"

local definitions: { [string]: RemoteKind } = {
	-- client → server
	MagnetAction = "Event", -- { action, phase, origin, direction }
	SetCosmetic = "Event", -- { slot, value }
	RequestPurchase = "Event", -- { productKey }
	RequestRespawn = "Event", -- {}
	RequestStageTeleport = "Event", -- { stageId }

	-- server → client
	MagnetFeedback = "Event", -- { hand, action, outcome, targetPart?, hitPosition? }
	RunUpdate = "Event", -- Types.RunUpdate
	Notify = "Event", -- { text, tone }
	EntitlementsChanged = "Event", -- { [productKey]: boolean }

	-- client → server, blocking
	GetStageRoster = "Function",
	GetRecords = "Function",
	GetLeaderboard = "Function", -- (stageId, scope) -> Types.LeaderboardPayload
	GetEntitlements = "Function",
}

local Net = {}

local folder: Folder

if RunService:IsServer() then
	folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	for name, kind in definitions do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new(if kind == "Event" then "RemoteEvent" else "RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT) :: Folder
	assert(folder, "Net folder never replicated — is the server bootstrap running?")
end

local cache: { [string]: Instance } = {}

--- Resolves a remote by name, yielding on the client until it replicates.
function Net.Get(name: string): Instance
	local cached = cache[name]
	if cached then
		return cached
	end

	assert(definitions[name], `unknown remote "{name}" — add it to Net.luau's definitions table`)

	local remote: Instance?
	if RunService:IsServer() then
		remote = folder:FindFirstChild(name)
	else
		remote = folder:WaitForChild(name, WAIT_TIMEOUT)
	end

	assert(remote, `remote "{name}" was never created`)
	cache[name] = remote
	return remote
end

setmetatable(Net, {
	__index = function(_, key: string)
		return Net.Get(key)
	end,
})

return Net
