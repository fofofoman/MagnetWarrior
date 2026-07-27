--!nonstrict
--[[
	MotionService.luau — 움직이는 자석 벽 / 극성 전환

	Two behaviours on one primitive, because the timing stages want them
	combined: a wall that travels back and forth, and a wall whose magnetism
	switches on and off on a cycle.

	Both are driven from a single phase value, so a stage author gets
	predictable, learnable rhythm by giving several walls the same `period` and
	different `phase` offsets. That is the whole design of stage 7 — the walls
	are not random, they are a bar of music you have to read.

	Two details make this work with the rest of the magnet system:

	  • **Travel uses CFrame on anchored parts.** These are walls you *cling* to,
	    not floors you stand on. ClingController stores its latch point in the
	    wall's object space and re-projects it every frame, so a clinging player
	    is carried along for free. An anchored part moved by CFrame does *not*
	    carry a player standing on top of it — that is a Roblox behaviour, and it
	    is why these are walls.

	  • **Losing polarity drops whoever is holding on.** Otherwise a player would
	    ride an inert wall, which contradicts everything the stage just taught
	    them.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)

local ClingController = require(script.Parent.Parent.Magnet.ClingController)

local MotionService = {}

local LIVE_COLOR = Color3.fromRGB(64, 156, 255)
local DEAD_COLOR = Color3.fromRGB(58, 62, 70)

type KineticState = {
	part: BasePart,
	home: CFrame,
	travel: Vector3?,
	period: number,
	phase: number,
	--- Offset for the polarity window only. A wall that both travels and pulses
	--- usually wants its live window centred on the useful half of its sweep,
	--- which is a different offset from the one that positions the sweep itself.
	pulsePhase: number,
	pulses: boolean,
	dutyCycle: number,
	isSurface: boolean,
	live: boolean,
}

local states: { [BasePart]: KineticState } = {}
local heartbeat: RBXScriptConnection?

local function setPolarity(state: KineticState, live: boolean)
	if state.live == live then
		return
	end
	state.live = live

	local part = state.part

	if live then
		CollectionService:AddTag(part, GameConfig.Tags.Magnetic)
		if state.isSurface then
			CollectionService:AddTag(part, GameConfig.Tags.MagneticSurface)
		end
		part.Color = LIVE_COLOR
		part.Material = Enum.Material.Neon
	else
		-- Order matters: drop the riders before the wall stops being a wall, so
		-- they are released against a surface that still exists.
		ClingController.ReleaseFromSurface(part, false)
		CollectionService:RemoveTag(part, GameConfig.Tags.Magnetic)
		CollectionService:RemoveTag(part, GameConfig.Tags.MagneticSurface)
		part.Color = DEAD_COLOR
		part.Material = Enum.Material.Metal
	end
end

local function register(instance: Instance)
	if not instance:IsA("BasePart") or states[instance] then
		return
	end

	local period = instance:GetAttribute("Period")
	if typeof(period) ~= "number" or period <= 0 then
		warn(`[MotionService] {instance:GetFullName()} has no usable Period attribute`)
		return
	end

	local travel = instance:GetAttribute("Travel")
	local pulses = instance:GetAttribute("Pulses") == true
	local duty = instance:GetAttribute("DutyCycle")
	local phase = instance:GetAttribute("Phase")
	local pulsePhase = instance:GetAttribute("PulsePhase")

	local state: KineticState = {
		part = instance,
		home = instance.CFrame,
		travel = if typeof(travel) == "Vector3" and travel.Magnitude > 0 then travel else nil,
		period = period,
		phase = if typeof(phase) == "number" then phase else 0,
		pulsePhase = if typeof(pulsePhase) == "number" then pulsePhase else 0,
		pulses = pulses,
		dutyCycle = if typeof(duty) == "number" then math.clamp(duty, 0.05, 0.95) else 0.5,
		isSurface = instance:GetAttribute("IsSurface") == true,
		-- Assume live so the first setPolarity call for a pulsing wall actually
		-- applies; StageBuilder tags it live at build time.
		live = true,
	}

	states[instance] = state
end

local function unregister(instance: Instance)
	states[instance :: BasePart] = nil
end

local function step()
	local now = os.clock()

	for part, state in states do
		if not part.Parent then
			states[part] = nil
			continue
		end

		local base = now / state.period

		if state.travel then
			-- Sine rather than a linear sweep: the wall eases at each end, which
			-- gives the player a readable window to jump for. alpha runs
			-- 0 → +1 → 0 → -1 over the cycle, so `travel` is a half-amplitude
			-- either side of `position`.
			local alpha = math.sin(((base + state.phase) % 1) * math.pi * 2)
			part.CFrame = state.home + state.travel * alpha
		end

		if state.pulses then
			setPolarity(state, ((base + state.phase + state.pulsePhase) % 1) < state.dutyCycle)
		end
	end
end

--- True while the wall is magnetic. Layout authors can use this from other
--- systems; the stages themselves rely on the visual instead.
function MotionService.IsLive(part: BasePart): boolean
	local state = states[part]
	return state == nil or state.live
end

function MotionService.Start()
	for _, instance in CollectionService:GetTagged(GameConfig.Tags.Kinetic) do
		register(instance)
	end
	CollectionService:GetInstanceAddedSignal(GameConfig.Tags.Kinetic):Connect(register)
	CollectionService:GetInstanceRemovedSignal(GameConfig.Tags.Kinetic):Connect(unregister)

	if heartbeat then
		return
	end
	heartbeat = RunService.Heartbeat:Connect(step)
end

return MotionService
