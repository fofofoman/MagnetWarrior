--!strict
--[[
	RateLimiter.luau
	Token bucket, one bucket per player, used in front of every remote the
	client can fire. Cooldowns are a game-design tool; this is a security tool,
	and the two are kept separate on purpose — an exploiter who removes the
	client-side cooldown still hits this.

		local limiter = RateLimiter.new(12, 6) -- 12/s sustained, burst of 6
		if not limiter:Consume(player) then return end
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = {
	tokens: number,
	lastRefill: number,
}

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_ratePerSecond: number,
		_burst: number,
		_buckets: { [Player]: Bucket },
		_violations: { [Player]: number },
	},
	RateLimiter
))

function RateLimiter.new(ratePerSecond: number, burst: number?): RateLimiter
	return setmetatable({
		_ratePerSecond = ratePerSecond,
		_burst = burst or ratePerSecond,
		_buckets = {},
		_violations = {},
	}, RateLimiter)
end

--- Returns true if the caller may proceed, false if it is being throttled.
function RateLimiter:Consume(player: Player, cost: number?): boolean
	local now = os.clock()
	local bucket = self._buckets[player]

	if not bucket then
		bucket = { tokens = self._burst, lastRefill = now }
		self._buckets[player] = bucket
	end

	local elapsed = now - bucket.lastRefill
	bucket.lastRefill = now
	bucket.tokens = math.min(self._burst, bucket.tokens + elapsed * self._ratePerSecond)

	local price = cost or 1
	if bucket.tokens < price then
		self._violations[player] = (self._violations[player] or 0) + 1
		return false
	end

	bucket.tokens -= price
	return true
end

--- How many times this player has been throttled. Feeds the anti-cheat report;
--- a legitimate player brushes this occasionally, a macro pegs it.
function RateLimiter:ViolationCount(player: Player): number
	return self._violations[player] or 0
end

function RateLimiter:Release(player: Player)
	self._buckets[player] = nil
	self._violations[player] = nil
end

return RateLimiter
