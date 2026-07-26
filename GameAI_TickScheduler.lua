--[[
	TickScheduler (for St0rmCast3r's GameAI)

	Initially made with the purpose to evenly spread tick jobs for NPCs / preventing
	GameAI step tasks from bunching up on the Roblox task scheduler.

	Expects two BindableEvent children on this script:
		subscribe   : Fire(tick_event : BindableEvent, lifeline_instance : Instance)
		unsubscribe : Fire(lifeline_instance : Instance)

	Subscriber contract:
		- tick_event is a BindableEvent dedicated solely to receiving tick
		  notifications from this scheduler. The scheduler fires it with no payload;
		  every fire means exactly one thing: "a tick happened."
		- lifeline_instance is any Instance that identifies this subscription.
		  It doubles as the unsubscribe fingerprint (pass the same instance back
		  to the "unsubscribe" event) AND as an automatic cleanup trigger: if
		  lifeline_instance is destroyed, the subscription is dropped for you.
		- The scheduler draws from a fixed-size pool of SUBSCRIPTION_POOL_SIZE
		  slots. If the pool is full, subscribe is silently ignored (aside from
		  a warn()). To find out whether your subscription actually landed,
		  check lifeline_instance for the SCHEDULER_MANAGED_TAG CollectionService
		  tag a frame or two after firing subscribe - its absence means you were
		  ignored (pool full, or since evicted by the janitor sweep).

	Example subscriber snippet:

		local scheduler = workspace.CentralScheduler -- wherever it's parented
		local tickEvent = Instance.new("BindableEvent")

		tickEvent.Event:Connect(function()
			stepPedestrian(data)
		end)

		scheduler.subscribe:Fire(tickEvent, data.stateFolder)
		-- later, to stop early: scheduler.unsubscribe:Fire(data.stateFolder)

	Alternatively, use the provided subscribeToTickScheduler() and unsubscribeFromTickScheduler()
	functions from the GameAICommon module for the same effect.
	
	The HumanoidRootParts of characters are the expected lifeline instance.
]]

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local SUBSCRIPTION_POOL_SIZE = 1024 -- fixed capacity; configurable. Subscriptions beyond this are dropped (see subscribeLifeline)
local SCHEDULER_MANAGED_TAG = "GameAITickSchedulerManaged" -- CollectionService tag applied to a lifeline_instance while its subscription is live
local TARGET_TICK_RATE_HZ = 8 -- DO NOT CHANGE; every subscriber should be ticked about this many times per second
local TARGET_TICK_INTERVAL_SECONDS = 1 / TARGET_TICK_RATE_HZ
local FRAME_TIME_BUDGET_SECONDS = 0.004 -- safety valve: stop ticking early if a frame runs long
local WATCHDOG_INTERVAL_SECONDS = 10 -- how often the load watchdog evaluates and (if bogged) reports
local DEBT_ALERT_THRESHOLD_RATIO = 0.07 -- tolerate this much of a full sweep's worth of debt before the watchdog barks
local JANITOR_SWEEP_INTERVAL_SECONDS = 1 -- deliberately slow/background - this is a lazy sweep, not a fast path
local JANITOR_SWEEP_FRACTION = 0.03 -- process at least this fraction of the pool per batch (min 1)
local MAX_MISSED_TICKS_TO_CATCH_UP = 3 -- backlog that a stall/lagspike is allowed to leave behind for the scheduler to speed through afterwards. 

--[[
	With a sparse pool, the tick/janitor loops still scan dead slots each pass.
	Why bother having to iterate through mostly dead slots whenever the pool is mostly unfilled?
	
	1. This script will produce far less garbage collection pressure.
	
	2. The scheduler was built to expect wild fluctuations in subscriber population. 
	   With a resizing subscription table, there would be extreme GC thrashing.
	   
	3. If the worst case scenario for iteration performance should happen (almost all slots are unfilled), 
	   the game probably has spare CPU resources from the absence of GameAI agents.
	   
	Though, if someone were to address this, I'd suggest they look into swap-and-pop dense packing.
]]

type SubscriptionT = {
	lifeline : Instance?,
	lifelineParentName : string,
	tickEvent : BindableEvent?,
	destroyingConn : RBXScriptConnection?,
	active : boolean,
	slotIndex : number,
}

local subscribeEvent = script:WaitForChild("subscribe") :: BindableEvent
local unsubscribeEvent = script:WaitForChild("unsubscribe") :: BindableEvent

local subscriptionsByLifeline : {[Instance]: SubscriptionT} = {}

-- Fixed-size slot pool. tickQueue is always exactly SUBSCRIPTION_POOL_SIZE
-- entries long, pre-allocated once at startup; subscribe/unsubscribe never
-- grow or shrink it, they only flip slots between free and active via
-- freeSlotStack. This keeps steady-state churn allocation-free regardless
-- of how wildly the live population fluctuates.
local tickQueue : {SubscriptionT} = table.create(SUBSCRIPTION_POOL_SIZE)
local freeSlotStack : {number} = table.create(SUBSCRIPTION_POOL_SIZE)

for slotIndex = SUBSCRIPTION_POOL_SIZE, 1, -1 do
	tickQueue[slotIndex] = {
		lifeline = nil,
		lifelineParentName = "",
		tickEvent = nil,
		destroyingConn = nil,
		active = false,
		slotIndex = slotIndex,
	} :: SubscriptionT
	table.insert(freeSlotStack, slotIndex)
end

local queueCursor = 0
local janitorCursor = 0
local liveSubscriptionCount = 0 -- authoritative count of active slots; #tickQueue is always SUBSCRIPTION_POOL_SIZE and can't be used for this
local tickBudgetAccumulator = 0 -- fractional count of ticks owed, paid off in whole units per frame

-- Watchdog bookkeeping, accumulated per-frame and drained by printLoadReport() every WATCHDOG_INTERVAL_SECONDS
local watchdogFramesObserved = 0
local watchdogFramesTimeCapped = 0 -- frames where FRAME_TIME_BUDGET_SECONDS cut the tick loop short
local watchdogFramesDebtOverThreshold = 0 -- frames where owed debt exceeded DEBT_ALERT_THRESHOLD_RATIO of a full sweep
local watchdogTicksFired = 0
local watchdogPeakSubscriptionCount = 0
local watchdogWasBogged = false

-- Shared teardown for a subscription entry - marks it dead, disconnects its
-- lifeline watch, removes the managed tag, and returns its slot to the
-- freelist for reuse. Does not warn; callers decide whether this removal
-- deserves a complaint.
local function deactivateSubscription(subscriptionEntry : SubscriptionT)
	subscriptionEntry.active = false
	if subscriptionEntry.destroyingConn then
		subscriptionEntry.destroyingConn:Disconnect()
		subscriptionEntry.destroyingConn = nil
	end
	if subscriptionEntry.lifeline then
		CollectionService:RemoveTag(subscriptionEntry.lifeline, SCHEDULER_MANAGED_TAG)
		subscriptionsByLifeline[subscriptionEntry.lifeline] = nil
	end
	subscriptionEntry.lifeline = nil
	subscriptionEntry.tickEvent = nil
	liveSubscriptionCount -= 1
	table.insert(freeSlotStack, subscriptionEntry.slotIndex)
end

local function unsubscribeLifeline(lifeline_instance : Instance)
	local subscriptionEntry = subscriptionsByLifeline[lifeline_instance]
	if not subscriptionEntry or not subscriptionEntry.active then
		return
	end
	deactivateSubscription(subscriptionEntry)
end

-- Forced removal by the janitor sweep, for subscribers that never properly
-- unsubscribed. Unlike unsubscribeLifeline, this one is loud about it.
local function evictSubscriptionEntry(subscriptionEntry : SubscriptionT, reason : string)
	local lifelineInstance = subscriptionEntry.lifeline :: Instance
	local lifelineName = lifelineInstance.Name
	local lifelineParentName = if subscriptionEntry.lifelineParentName then subscriptionEntry.lifelineParentName else "<nil>"

	deactivateSubscription(subscriptionEntry)

	warn(string.format(
		"CentralScheduler: Had to clean up after '%s' myself (%s) - some subscriber forgot to unsubscribe.",
		lifelineName.." child of "..lifelineParentName,
		reason
		))
end

local function subscribeLifeline(tick_event : BindableEvent, lifeline_instance : Instance)
	if typeof(tick_event) ~= "Instance" or not tick_event:IsA("BindableEvent") then
		warn("CentralScheduler: subscribe fired without a valid BindableEvent tick_event")
		return
	end
	if typeof(lifeline_instance) ~= "Instance" then
		warn("CentralScheduler: subscribe fired without a valid lifeline instance")
		return
	end
	if subscriptionsByLifeline[lifeline_instance] then
		warn("CentralScheduler: lifeline instance is already subscribed, ignoring duplicate", lifeline_instance:GetFullName())
		return
	end
	if not lifeline_instance.Parent and lifeline_instance ~= game then
		-- already torn down before it even got here
		return
	end

	local freeSlot = table.remove(freeSlotStack)
	if not freeSlot then
		warn(string.format(
			"CentralScheduler: subscription pool exhausted (%d/%d slots in use) - dropping subscribe for '%s'",
			SUBSCRIPTION_POOL_SIZE, SUBSCRIPTION_POOL_SIZE, lifeline_instance:GetFullName()
			))
		return
	end

	local subscriptionEntry = tickQueue[freeSlot]
	subscriptionEntry.lifeline = lifeline_instance
	subscriptionEntry.lifelineParentName = if lifeline_instance.Parent then lifeline_instance.Parent.Name else "nil"
	subscriptionEntry.tickEvent = tick_event
	subscriptionEntry.active = true

	subscriptionEntry.destroyingConn = lifeline_instance.Destroying:Connect(function()
		unsubscribeLifeline(lifeline_instance)
	end)

	subscriptionsByLifeline[lifeline_instance] = subscriptionEntry
	CollectionService:AddTag(lifeline_instance, SCHEDULER_MANAGED_TAG)
	liveSubscriptionCount += 1
end

local function onHeartbeatStep(delta_time : number)
	if liveSubscriptionCount == 0 then
		tickBudgetAccumulator = 0
		return
	end

	watchdogFramesObserved += 1
	watchdogPeakSubscriptionCount = math.max(watchdogPeakSubscriptionCount, liveSubscriptionCount)

	local maxCatchUpDebt = math.max(1, liveSubscriptionCount * MAX_MISSED_TICKS_TO_CATCH_UP)
	tickBudgetAccumulator = math.min(tickBudgetAccumulator, maxCatchUpDebt)

	local entriesOwedPerSecond = liveSubscriptionCount / TARGET_TICK_INTERVAL_SECONDS
	tickBudgetAccumulator += entriesOwedPerSecond * delta_time

	local entriesToTickThisFrame = math.floor(tickBudgetAccumulator)

	if entriesToTickThisFrame > 0 then
		local deadlineClock = os.clock() + FRAME_TIME_BUDGET_SECONDS
		local tickedCount = 0
		local scannedCount = 0

		while tickedCount < entriesToTickThisFrame and scannedCount < SUBSCRIPTION_POOL_SIZE and os.clock() < deadlineClock do
			scannedCount += 1
			queueCursor += 1
			if queueCursor > SUBSCRIPTION_POOL_SIZE then
				queueCursor = 1
			end

			local subscriptionEntry = tickQueue[queueCursor]
			if subscriptionEntry.active then
				(subscriptionEntry.tickEvent :: BindableEvent):Fire()
				tickedCount += 1
			end
		end

		-- Only pay off debt for ticks that actually fired. Whatever the time
		-- cap prevented stays owed and carries into the next frame, instead
		-- of being silently forgiven.
		tickBudgetAccumulator -= tickedCount

		if tickedCount < entriesToTickThisFrame and os.clock() >= deadlineClock then
			watchdogFramesTimeCapped += 1
		end

		watchdogTicksFired += tickedCount
	end

	-- Real backlog check: debt still sitting in the accumulator after this
	-- frame paid what it could, as a fraction of a full sweep. Every frame
	-- naturally accrues some debt before paying it off - that's not backlog,
	-- it's just the cycle. Only alert once leftover debt persists past the
	-- threshold, which only happens when payment can't keep up with accrual.
	if tickBudgetAccumulator / liveSubscriptionCount > DEBT_ALERT_THRESHOLD_RATIO then
		watchdogFramesDebtOverThreshold += 1
	end
end

-- Evaluates the last WATCHDOG_INTERVAL_SECONDS of bookkeeping, prints a load
-- report if the scheduler is bogged down (or just recovered), then resets.
local function printLoadReport()
	local isBogged = watchdogFramesTimeCapped > 0 or watchdogFramesDebtOverThreshold > 0

	if isBogged then
		local timestamp = DateTime.now():ToIsoDate()
		local achievedTickRateHz = watchdogTicksFired / WATCHDOG_INTERVAL_SECONDS

		warn(string.format(
			"CentralScheduler [%s]: bogging down - target %dHz, achieved ~%.1f ticks/s | "
				.. "subscribers=%d peakSubscribers=%d pool=%d | framesObserved=%d timeCapped=%d (%.0f%%) debtOverThreshold=%d (%.0f%%, >%.0f%% of a sweep) | "
				.. "currentDebt=%.1f/%d",
			timestamp,
			TARGET_TICK_RATE_HZ,
			achievedTickRateHz,
			liveSubscriptionCount,
			watchdogPeakSubscriptionCount,
			SUBSCRIPTION_POOL_SIZE,
			watchdogFramesObserved,
			watchdogFramesTimeCapped,
			watchdogFramesObserved > 0 and (watchdogFramesTimeCapped / watchdogFramesObserved * 100) or 0,
			watchdogFramesDebtOverThreshold,
			watchdogFramesObserved > 0 and (watchdogFramesDebtOverThreshold / watchdogFramesObserved * 100) or 0,
			DEBT_ALERT_THRESHOLD_RATIO * 100,
			tickBudgetAccumulator,
			liveSubscriptionCount
			))
	elseif watchdogWasBogged then
		local timestamp = DateTime.now():ToIsoDate()
		print(string.format("CentralScheduler [%s]: load recovered, back to target %dHz", timestamp, TARGET_TICK_RATE_HZ))
	end

	watchdogWasBogged = isBogged
	watchdogFramesObserved = 0
	watchdogFramesTimeCapped = 0
	watchdogFramesDebtOverThreshold = 0
	watchdogTicksFired = 0
	watchdogPeakSubscriptionCount = 0
end

-- Returns a reason string if lifeline_instance looks stale/abandoned, or nil if it's fine.
-- Assumes lifeline_instance's parent is the owning character (e.g. a state
-- folder or part parented directly under a character Model).
local function getEvictionReason(lifeline_instance : Instance?) : string?
	if not lifeline_instance then
		return "lifeline instance is nil"
	end

	local character = lifeline_instance.Parent
	if not character or not character:IsDescendantOf(workspace) then
		return "lifeline's parent is no longer in the workspace"
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return "lifeline's parent has no Humanoid"
	end

	if humanoid.Health <= 0 then
		return "lifeline's character Humanoid has 0 health"
	end

	return nil
end

-- Lazy background sweep: each call only inspects a small slice of the pool
-- (3% of it, or 1 slot, whichever is larger), so this never competes
-- meaningfully with the tick path for frame time.
local function sweepJanitorBatch()
	if liveSubscriptionCount == 0 then
		janitorCursor = 0
		return
	end

	local batchSize = math.max(1, math.ceil(SUBSCRIPTION_POOL_SIZE * JANITOR_SWEEP_FRACTION))
	local scannedCount = 0

	while scannedCount < batchSize and scannedCount < SUBSCRIPTION_POOL_SIZE do
		scannedCount += 1
		janitorCursor += 1
		if janitorCursor > SUBSCRIPTION_POOL_SIZE then
			janitorCursor = 1
		end

		local subscriptionEntry = tickQueue[janitorCursor]
		if subscriptionEntry.active then
			local evictionReason = getEvictionReason(subscriptionEntry.lifeline)
			if evictionReason then
				--evictSubscriptionEntry(subscriptionEntry, evictionReason)
				pcall(function()
					evictSubscriptionEntry(subscriptionEntry, evictionReason)
				end)
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(WATCHDOG_INTERVAL_SECONDS)
		printLoadReport()
	end
end)

task.spawn(function()
	while true do
		task.wait(JANITOR_SWEEP_INTERVAL_SECONDS)
		sweepJanitorBatch()
	end
end)

subscribeEvent.Event:Connect(subscribeLifeline)
unsubscribeEvent.Event:Connect(unsubscribeLifeline)
RunService.Heartbeat:Connect(onHeartbeatStep)

-- Studio testing fix / ensure that this script is ready before any relying scripts try to subscribe
task.wait(1)
local readyFlag = Instance.new("Folder")
readyFlag.Name = "Ready"
readyFlag.Parent = script
