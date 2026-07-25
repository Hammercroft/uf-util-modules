--!nonstrict

--[[
ISC License

Copyright 2026 Hammercroft

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is
hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE 
INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM 
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
]]

-- FastAnimate

-- Simplified vanilla-style R6 animator: idle / walk / run / tool anims only.
-- No emotes, no Humanoid state event hooks, no Value-instance animation configs.
-- Pose is inferred from horizontal displacement sampling (works as Script or
-- Made to be executed as a Script, either Client or Server RunContext.

local RunService = game:GetService("RunService")

local Figure = script.Parent
local Humanoid = Figure:WaitForChild("Humanoid")
local RootPart = Figure:WaitForChild("HumanoidRootPart")
local Animator = Humanoid:WaitForChild("Animator")

-- ============================================================
-- CONFIG (edit here -- this is the only place animation data lives)
-- ============================================================

-- Hysteresis banding: the "exit idle" bar sits above the "return to idle" bar
-- so noise sitting right on one threshold can't cause rapid re-triggering.
local IDLE_SPEED_THRESHOLD = 0.5      -- studs/s; drop to idle once below this
local WALK_EXIT_SPEED_THRESHOLD = 0.9 -- studs/s; must clear this to leave idle
local RUN_SPEED_THRESHOLD = 10        -- studs/s; at/above this => run, else walk

local WALK_SPEED_REFERENCE = 14.5     -- tuned so AdjustSpeed(1.0) matches the default walk cycle
local RUN_SPEED_REFERENCE = 22        -- same idea, tuned for the run cycle

local SPEED_SMOOTHING_ALPHA = 0.35    -- EMA factor; lower = smoother/slower to react, higher = snappier/noisier

local BODY_ANIM_TRANSITION_TIME = 0.1
local TOOL_ANIM_TRANSITION_TIME = 0.1
local TOOL_ANIM_HOLD_TIME = 0.3       -- how long a Slash/Lunge signal stays "active"
local SAMPLE_INTERVAL = 1 / 30        -- displacement sampling rate, in seconds

local ANIM_SET_CONFIG = {
	idle = {
		{ id = 180435571, weight = 9 },
		{ id = 180435792, weight = 1 },
	},
	walk = {
		{ id = 116435573388269, weight = 10 },
	},
	run = {
		{ id = 116435573388269, weight = 10 },
	},
	toolNone = {
		{ id = 182393478, weight = 10 },
	},
	toolSlash = {
		{ id = 129967390, weight = 10 },
	},
	toolLunge = {
		{ id = 129967478, weight = 10 },
	},
}

-- ============================================================
-- ANIM SET LOADING
-- ============================================================

local function buildAnimSetFromConfig(config_entries)
	local anim_set = { totalWeight = 0, tracks = {} }
	for index, entry in ipairs(config_entries) do
		local animation = Instance.new("Animation")
		animation.AnimationId = "rbxassetid://" .. entry.id
		anim_set.tracks[index] = { track = Animator:LoadAnimation(animation), weight = entry.weight }
		anim_set.totalWeight += entry.weight
	end
	return anim_set
end

local animSetsByName = {}
for name, entries in pairs(ANIM_SET_CONFIG) do
	animSetsByName[name] = buildAnimSetFromConfig(entries)
end

local function pickTrackFromSet(anim_set)
	local roll = math.random() * anim_set.totalWeight
	local cumulativeWeight = 0
	for _, item in ipairs(anim_set.tracks) do
		cumulativeWeight += item.weight
		if roll <= cumulativeWeight then
			return item.track
		end
	end
	return anim_set.tracks[#anim_set.tracks].track
end

-- ============================================================
-- BODY ANIMATION (idle / walk / run)
-- ============================================================

local animBodyNameCurrent = ""
local animBodyTrackCurrent = nil

local function playBodyAnimation(anim_name, transition_time)
	if anim_name == animBodyNameCurrent then
		return
	end
	if animBodyTrackCurrent then
		animBodyTrackCurrent:Stop(transition_time)
	end
	animBodyTrackCurrent = pickTrackFromSet(animSetsByName[anim_name])
	animBodyTrackCurrent:Play(transition_time)
	animBodyNameCurrent = anim_name
end

local function updateBodyAnimationSpeed(speed_value)
	if animBodyNameCurrent == "walk" then
		animBodyTrackCurrent:AdjustSpeed(speed_value / WALK_SPEED_REFERENCE)
	elseif animBodyNameCurrent == "run" then
		animBodyTrackCurrent:AdjustSpeed(speed_value / RUN_SPEED_REFERENCE)
	end
end

-- ============================================================
-- TOOL ANIMATION
-- ============================================================

local animToolNameCurrent = ""
local animToolTrackCurrent = nil
local animToolHoldUntil = 0

local function playToolAnimation(anim_name, transition_time)
	if anim_name == animToolNameCurrent and animToolTrackCurrent then
		return
	end
	if animToolTrackCurrent then
		animToolTrackCurrent:Stop()
	end
	animToolTrackCurrent = pickTrackFromSet(animSetsByName[anim_name])
	animToolTrackCurrent:Play(transition_time)
	animToolNameCurrent = anim_name
end

local function stopToolAnimation()
	if animToolTrackCurrent then
		animToolTrackCurrent:Stop()
	end
	animToolTrackCurrent = nil
	animToolNameCurrent = ""
end

local function getEquippedTool()
	for _, child in ipairs(Figure:GetChildren()) do
		if child:IsA("Tool") then
			return child
		end
	end
	return nil
end

-- Tools signal Slash/Lunge by dropping a StringValue named "toolanim" under
-- themselves (the standard vanilla Tool-script protocol) -- this is a
-- messaging convention, not an animation-config override, so it stays.
local function sampleToolState(time_current)
	local tool = getEquippedTool()
	local handle = tool and tool:FindFirstChild("Handle")

	if not (tool and handle) then
		stopToolAnimation()
		return
	end

	local toolAnimSignal = tool:FindFirstChild("toolanim")
	if toolAnimSignal and toolAnimSignal:IsA("StringValue") then
		if toolAnimSignal.Value == "Slash" then
			playToolAnimation("toolSlash", 0)
			animToolHoldUntil = time_current + TOOL_ANIM_HOLD_TIME
		elseif toolAnimSignal.Value == "Lunge" then
			playToolAnimation("toolLunge", 0)
			animToolHoldUntil = time_current + TOOL_ANIM_HOLD_TIME
		end
		toolAnimSignal:Destroy()
	end

	if time_current > animToolHoldUntil then
		playToolAnimation("toolNone", TOOL_ANIM_TRANSITION_TIME)
	end
end

-- ============================================================
-- DISPLACEMENT SAMPLING (replaces Humanoid state event hooks)
-- ============================================================

-- IMPORTANT: sample HumanoidRootPart, not Torso. Torso is animated (idle/walk
-- tracks can include root-sway/breathing motion via RootJoint), so reading its
-- position creates a feedback loop -- the animation itself gets read back as
-- "movement," which can prevent the pose from ever settling on idle.
-- HumanoidRootPart only moves from actual physics motion, never from playing
-- an AnimationTrack on the rig.

local positionSamplePrevious = RootPart.Position
local sampleTimeAccumulated = 0
local speedSampledSmoothed = 0

local function samplePoseFromDisplacement(delta_time)
	local positionCurrent = RootPart.Position
	local displacement = positionCurrent - positionSamplePrevious
	positionSamplePrevious = positionCurrent

	-- horizontal-only, so falling/jumping doesn't get misread as running
	local speedSampled = Vector3.new(displacement.X, 0, displacement.Z).Magnitude / delta_time

	-- light exponential smoothing to reject residual physics jitter
	speedSampledSmoothed += (speedSampled - speedSampledSmoothed) * SPEED_SMOOTHING_ALPHA

	if animBodyNameCurrent == "idle" then
		if speedSampledSmoothed >= WALK_EXIT_SPEED_THRESHOLD then
			playBodyAnimation("walk", BODY_ANIM_TRANSITION_TIME)
			updateBodyAnimationSpeed(speedSampledSmoothed)
		end
	elseif speedSampledSmoothed < IDLE_SPEED_THRESHOLD then
		playBodyAnimation("idle", BODY_ANIM_TRANSITION_TIME)
	elseif speedSampledSmoothed < RUN_SPEED_THRESHOLD then
		playBodyAnimation("walk", BODY_ANIM_TRANSITION_TIME)
		updateBodyAnimationSpeed(speedSampledSmoothed)
	else
		playBodyAnimation("run", BODY_ANIM_TRANSITION_TIME)
		updateBodyAnimationSpeed(speedSampledSmoothed)
	end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================

playBodyAnimation("idle", 0)

RunService.Heartbeat:Connect(function(deltaTime)
	sampleTimeAccumulated += deltaTime
	if sampleTimeAccumulated >= SAMPLE_INTERVAL then
		samplePoseFromDisplacement(sampleTimeAccumulated)
		sampleTimeAccumulated = 0
	end
	sampleToolState(os.clock())
end)
