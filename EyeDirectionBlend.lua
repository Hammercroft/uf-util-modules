--!strict

-- EyeDirectionBlend Daemon (St0rmCast3r)

const NOTE=[[

PLACE AS A `Script` (any RunContext) INSIDE AN `EyeDirection` Vector3Value OF A CHARACTER MODEL!
You may also need to replace the asset ids (scroll down) with the ones of your own published animations.

]]

--[[
    ( PURPOSE )
    -> Drive the 9-way eye blend poses (Neutral + 8 directions) of the
       R15 character this script lives in, from the EyeDirection Vector3Value.
    -> Other scripts never touch AnimationTracks; they only write to the value.
    -> Nothing here cares about who is running it (server, client, or legacy
       context): it only talks to the character's own Animator. Whoever runs
       it decides who sees the result (server = replicated to everyone,
       client = only that client).

    ( INPUT )
    -> EyeDirection.Value is a Vector3:
           X: -1 = character's LEFT,  +1 = character's RIGHT   (clamped -1 to 1)
           Y: -1 = DOWN,              +1 = UP                  (clamped -1 to 1)
           Z: fade time in seconds for reaching this direction (clamped to >= 0)
       (Left/right is from the character's point of view, NOT the camera's.)
    -> Z = 0 snaps instantly, so Vector3.new(x, y, 0) means "no smoothing".
       Write e.g. Vector3.new(0.5, -1, 0.15) for a 0.15 s transition.

    ( HOW IT BLENDS )
    -> The pose animations sit on a 3x3 grid (-1, 0, +1 per axis). Each's weight is
       how close the input is to it on X, multiplied by how close it is on Y
       (1.0 when on its grid line, 0.0 at the next one over).
    -> Weights add up to 1.0 (bar the tiny WEIGHT_FLOOR), and a pose only
       reaches 1.0 when the input is exactly on it, e.g. UpRight at (+1, +1).
    -> All nine tracks play looped at one shared priority and are blended via
       AnimationTrack:AdjustWeight(weight, fade_time).
    -> Every frame the script also verifies that each track is actually playing
       and heading toward its target weight, and repairs it if not, so a track
       that started late, got dropped or ignored an adjustment recovers by itself.

    ( TWITCH PATH )
    -> While a NumberValue named "EyeTwitchScale" is a child of the EyeDirection
       value, the script uses an alternative path that adds a random jitter
       ("twitch") to the eye direction:
         * Every AdjustWeight call uses fade_time = 0. The Z fade of the
           input is simulated instead: a smoothed axis position is linearly
           interpolated toward the input over Z seconds, and the weights are
           derived from that position every frame. (Engine-side fading would
           otherwise smear the twitch away.)
         * A twitch offset (a Vector2) is kept, with each component in
           [-EyeTwitchScale.Value, +EyeTwitchScale.Value]. It is added to
           the smoothed axisX / axisY, and the sum is clamped to -1..1.
         * The offset is re-randomized every `twitchSecondsInterval` seconds.
           The interval defaults to INTERVAL_SECONDS_TWITCH_DEFAULT (0 = every
           frame). If a NumberValue named "EyeTwitchInterval" exists as a child
           of the EyeDirection value, its Value (clamped to >= 0) is used;
           if it does not exist, the interval falls back to the default.
       Remove "EyeTwitchScale" to return to the normal path (engine-side
       fading, no offset). The in-flight fade is picked up from the tracks'
       current weights when switching paths, so there is no visible jump.

    ( DISABLE FLAG )
    -> While ANY instance named "Disabled" (any class) is a child of the
       EyeDirection value, all eye blend tracks are stopped and dropped, so
       other animations (e.g. your own eye/face animations) can play freely.
    -> Remove the flag and the poses are loaded again and snap back to the
       current EyeDirection value. Changes to the value in between are ignored.
    -> If the flag already exists when the script starts, nothing is loaded
       until it is removed.

    ( RESPAWNING )
    -> A respawned character is a new Model, so keep this setup somewhere that
       gets cloned into every character (e.g. StarterCharacterScripts).

    ( DISABLING )
    -> A disabled script cannot clean up after itself. Tracks left over from a
       previous run are stopped automatically the next time the script starts.
]]

--     Character Model         (Model with a Humanoid or AnimationController)
--     └── EyeDirection        (Vector3Value)
--         ├── EyeDirectionBlend   (this Script)
--         ├── EyeTwitchScale      (NumberValue, optional)
--         └── EyeTwitchInterval   (NumberValue, optional)
--
-- This script waits (coarsely polling) while NOT a descendant of Workspace, 
-- e.g. when placed in StarterCharacterScripts or ReplicatedStorage.
-- Once in Workspace, if placed anywhere else than shown above, the script
-- warns and disables itself.

--[[
    MIT License
    
    Copyright (c) 2026 Hammercroft
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
    
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]




--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

const POSES_EYE_BLEND = { -- axisX: -1 = character's left, +1 = character's right; axisY: -1 = down, +1 = up
	{ name = "Neutral",   id = 72561964099195,  axisX =  0, axisY =  0 },
	{ name = "Up",        id = 92037023769012,  axisX =  0, axisY =  1 },
	{ name = "UpRight",   id = 101465814791231, axisX =  1, axisY =  1 },
	{ name = "Right",     id = 117843245557714, axisX =  1, axisY =  0 },
	{ name = "DownRight", id = 90896924970166,  axisX =  1, axisY = -1 },
	{ name = "Down",      id = 92937941595196,  axisX =  0, axisY = -1 },
	{ name = "DownLeft",  id = 109322139371538, axisX = -1, axisY = -1 },
	{ name = "Left",      id = 101584275329278, axisX = -1, axisY =  0 },
	{ name = "UpLeft",    id = 95476337814982,  axisX = -1, axisY =  1 },
}
const PRIORITY_EYE_BLEND = Enum.AnimationPriority.Action -- All nine tracks share this priority
const INTERVAL_SECONDS_TWITCH_DEFAULT = 0.02 -- 0 = re-randomize the twitch offset every frame
const WAIT_SECONDS_WORKSPACE = 1 -- coarse polling interval while waiting to enter Workspace
const DELAY_SECONDS_RELOAD = 0.25 -- settle time before reloading after a face rig (re)appears


--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------



const NAME_EYE_DIRECTION_VALUE = "EyeDirection"
const NAME_FLAG_DISABLED = "Disabled" -- child of EyeDirection; while it exists, the poses are released
const NAME_EYE_TWITCH_SCALE_VALUE = "EyeTwitchScale" -- child NumberValue of EyeDirection; its existence enables the twitch path
const NAME_EYE_TWITCH_INTERVAL_VALUE = "EyeTwitchInterval" -- child NumberValue of EyeDirection; optional
const PREFIX_NAME_ANIMATION = "EyeBlend" -- Animation instances are named PREFIX + pose name
const TIMEOUT_SECONDS_LOAD = 10
-- Poses never go to exactly 0, so the engine always keeps every track alive
-- and "ready to blend". (Eight floors add ~0.8% total; the engine normalizes it.)
const WEIGHT_FLOOR = 0.001
const EPSILON_WEIGHT_TARGET = 0.0005 -- how far a track's target may drift before it is corrected

const SERVICE_WORKSPACE = game:GetService("Workspace")
const SERVICE_PLAYERS = game:GetService("Players")
const SERVICE_CONTENT_PROVIDER = game:GetService("ContentProvider")
const SERVICE_RUN = game:GetService("RunService")


-- Workspace wait
-- Setups parked outside the world (ReplicatedStorage, StarterCharacterScripts,
-- ...) are not ready to be validated or animated yet, so check back at a
-- coarse interval until they have been placed in Workspace.
if not script:IsDescendantOf(SERVICE_WORKSPACE) then
	repeat
		task.wait(WAIT_SECONDS_WORKSPACE)
	until script:IsDescendantOf(SERVICE_WORKSPACE)
end

-- Placement validation
local function disableScriptMisplaced(reason: string)
	warn(`[EyeDirectionBlend] Disabled: {reason} ({script:GetFullName()})`)
	script.Enabled = false
end

const parentScript = script.Parent
if not parentScript
	or not parentScript:IsA("Vector3Value")
	or parentScript.Name ~= NAME_EYE_DIRECTION_VALUE
then
	disableScriptMisplaced(`parent must be a Vector3Value named "{NAME_EYE_DIRECTION_VALUE}"`)
	return
end
const eyeDirectionValue = parentScript :: Vector3Value

const parentEyeDirection = eyeDirectionValue.Parent
if not parentEyeDirection or not parentEyeDirection:IsA("Model") then
	disableScriptMisplaced(`"{NAME_EYE_DIRECTION_VALUE}" must be a child of a character Model`)
	return
end
const characterModel = parentEyeDirection :: Model

local function hasFlagDisabled(): boolean
	return eyeDirectionValue:FindFirstChild(NAME_FLAG_DISABLED) ~= nil
end

-- Returns the named child of the EyeDirection value if it exists AND is a NumberValue.
local function findValueNumberChild(name_child: string): NumberValue?
	const child = eyeDirectionValue:FindFirstChild(name_child)
	if child and child:IsA("NumberValue") then
		return child
	end
	return nil
end

-- Animator lookup (polls instead of assuming replication has finished)
local function findControllerCharacter(character_model: Model): (Humanoid | AnimationController)?
	const deadline = os.clock() + TIMEOUT_SECONDS_LOAD
	repeat
		const controller = character_model:FindFirstChildOfClass("Humanoid")
			or character_model:FindFirstChildOfClass("AnimationController")
		if controller then return controller end
		task.wait()
	until os.clock() >= deadline
	return nil
end

local function findAnimatorController(animation_controller: Humanoid | AnimationController): Animator
	const animatorExisting = animation_controller:FindFirstChildOfClass("Animator")
		or animation_controller:WaitForChild("Animator", 2)
	if animatorExisting and animatorExisting:IsA("Animator") then
		return animatorExisting
	end

	-- Nobody made one; Roblox recommends creating it when it's missing.
	const animatorNew = Instance.new("Animator")
	animatorNew.Parent = animation_controller
	return animatorNew
end

-- Readiness wait: the face animations drive the head's FaceControls, so the
-- tracks should not be loaded/played until the character's appearance (and
-- therefore its face rig) exists. Returns false if that timed out.
local function waitUntilReadyCharacter(character_model: Model): boolean
	const player = SERVICE_PLAYERS:GetPlayerFromCharacter(character_model) -- nil for NPCs
	const deadline = os.clock() + TIMEOUT_SECONDS_LOAD
	repeat
		const isAppearanceReady = player == nil or player:HasAppearanceLoaded()
		const isFaceReady = character_model:FindFirstChildWhichIsA("FaceControls", true) ~= nil
		if isAppearanceReady and isFaceReady then return true end
		task.wait()
	until os.clock() >= deadline
	return false
end

-- FaceControls existing does not mean the head's mesh (which carries the
-- facial rig data) has finished loading, so fetch it too before animating.
local function preloadHeadCharacter(character_model: Model)
	const faceControls = character_model:FindFirstChildWhichIsA("FaceControls", true)
	const head = if faceControls then faceControls.Parent else nil
	if head then
		SERVICE_CONTENT_PROVIDER:PreloadAsync({ head })
	end
end

-- Track cache. (`const` locks the binding, not the table contents.)
const tracksEyeBlend: { [string]: AnimationTrack } = {}

-- Twitch path state. Only meaningful while an EyeTwitchScale NumberValue exists.
const randomTwitch = Random.new()
local isTwitchActive = false
local twitchOffsetAxis = Vector2.zero -- each component within +/- EyeTwitchScale.Value
local twitchSecondsInterval = INTERVAL_SECONDS_TWITCH_DEFAULT
local twitchSecondsElapsed = 0 -- time since the offset was last randomized

-- Simulated fade (twitch path only): fadeAxisCurrent travels linearly from
-- fadeAxisStart to fadeAxisTarget over fadeSecondsTotal seconds.
local fadeAxisStart = Vector2.zero
local fadeAxisTarget = Vector2.zero
local fadeAxisCurrent = Vector2.zero
local fadeSecondsTotal = 0
local fadeSecondsElapsed = 0

-- Per-axis tent weight: 1.0 at the pole, falling to 0.0 at the neighbouring
-- poles. Pole 0 peaks at the axis centre; poles +/-1 only exist on their side.
local function computeWeightTentAxis(axis_value: number, axis_pole: number): number
	if axis_pole == 0 then
		return 1 - math.abs(axis_value)
	end
	return math.max(axis_value * axis_pole, 0)
end

-- Reconciles every track with the given axis position: starts tracks
-- that are not playing (at their correct weight, never at a stale one) and
-- corrects any track whose target weight has drifted. Cheap to call every
-- frame, since it only touches tracks that are actually wrong.
local function applyWeightsAxisEyeBlend(axis_x: number, axis_y: number, fade_time: number)
	const axisX = math.clamp(axis_x, -1, 1)
	const axisY = math.clamp(axis_y, -1, 1)

	for _, pose in POSES_EYE_BLEND do
		const track = tracksEyeBlend[pose.name]
		if not track then continue end

		const weightPose = math.max(
			computeWeightTentAxis(axisX, pose.axisX) * computeWeightTentAxis(axisY, pose.axisY),
			WEIGHT_FLOOR
		)
		if not track.IsPlaying then
			track:Play(0, weightPose, 1)
		elseif math.abs(track.WeightTarget - weightPose) > EPSILON_WEIGHT_TARGET then
			track:AdjustWeight(weightPose, fade_time)
		end
	end
end

local function getFadeTimeValue(): number
	return math.max(eyeDirectionValue.Value.Z, 0)
end

-- NORMAL PATH: weights follow the EyeDirection value, fading engine-side.
local function applyWeightsEyeBlend(fade_time: number)
	const direction = eyeDirectionValue.Value
	applyWeightsAxisEyeBlend(direction.X, direction.Y, fade_time)
end

-- Recovers the axis position the tracks are currently at from their live
-- weights (the weighted centroid of the poses on the grid). Used when
-- switching to the twitch path mid-fade so the simulated fade picks up where
-- the engine's fade is. Falls back if no track is playing yet.
local function estimateAxisTracksEyeBlend(axis_fallback: Vector2): Vector2
	local weightSum = 0
	local weightedX = 0
	local weightedY = 0
	for _, pose in POSES_EYE_BLEND do
		const track = tracksEyeBlend[pose.name]
		if track and track.IsPlaying then
			const weightTrack = track.WeightCurrent
			weightSum += weightTrack
			weightedX += weightTrack * pose.axisX
			weightedY += weightTrack * pose.axisY
		end
	end
	if weightSum <= 0 then return axis_fallback end
	return Vector2.new(weightedX / weightSum, weightedY / weightSum)
end

-- TWITCH PATH: all AdjustWeight calls use fade_time = 0; the Z fade is
-- simulated here and the randomized offset is added on top. delta_time = 0
-- (e.g. from the Changed signal) re-applies without advancing any timer.
local function applyWeightsTwitchEyeBlend(delta_time: number, scale_value: NumberValue)
	const direction = eyeDirectionValue.Value
	const axisTarget = Vector2.new(math.clamp(direction.X, -1, 1), math.clamp(direction.Y, -1, 1))

	-- 1) Simulated fade
	if not isTwitchActive then
		-- Just switched over from the normal path: continue from wherever the tracks are.
		isTwitchActive = true
		twitchSecondsElapsed = 0
		fadeAxisCurrent = estimateAxisTracksEyeBlend(axisTarget)
		fadeAxisStart = fadeAxisCurrent
		fadeAxisTarget = axisTarget
		fadeSecondsTotal = getFadeTimeValue()
		fadeSecondsElapsed = 0
	elseif axisTarget ~= fadeAxisTarget then
		-- New destination: restart the fade from wherever we are right now.
		fadeAxisStart = fadeAxisCurrent
		fadeAxisTarget = axisTarget
		fadeSecondsTotal = getFadeTimeValue()
		fadeSecondsElapsed = 0
	end

	fadeSecondsElapsed += delta_time
	const fadeAlpha = if fadeSecondsTotal > 0 then math.min(fadeSecondsElapsed / fadeSecondsTotal, 1) else 1
	fadeAxisCurrent = fadeAxisStart:Lerp(fadeAxisTarget, fadeAlpha)

	-- 2) Twitch interval (falls back to the default when the value is absent)
	const intervalValue = findValueNumberChild(NAME_EYE_TWITCH_INTERVAL_VALUE)
	twitchSecondsInterval = if intervalValue
		then math.max(intervalValue.Value, 0)
		else INTERVAL_SECONDS_TWITCH_DEFAULT

	-- 3) Twitch offset, re-randomized once per interval
	if delta_time > 0 then
		twitchSecondsElapsed += delta_time
		if twitchSecondsElapsed >= twitchSecondsInterval then
			twitchSecondsElapsed = 0
			const scaleTwitch = math.max(scale_value.Value, 0)
			twitchOffsetAxis = Vector2.new(
				randomTwitch:NextNumber(-scaleTwitch, scaleTwitch),
				randomTwitch:NextNumber(-scaleTwitch, scaleTwitch)
			)
		end
	end

	-- 4) Offset is added to the (simulated-fade) axis; the core function clamps the sum.
	applyWeightsAxisEyeBlend(
		fadeAxisCurrent.X + twitchOffsetAxis.X,
		fadeAxisCurrent.Y + twitchOffsetAxis.Y,
		0
	)
end

-- Picks the path for this update. Cheap to call every frame.
local function updateEyeBlend(delta_time: number)
	if hasFlagDisabled() then return end

	const scaleValue = findValueNumberChild(NAME_EYE_TWITCH_SCALE_VALUE)
	if scaleValue then
		applyWeightsTwitchEyeBlend(delta_time, scaleValue)
		return
	end

	-- EyeTwitchScale absent: leave the twitch path cleanly.
	if isTwitchActive then
		isTwitchActive = false
		twitchOffsetAxis = Vector2.zero
		twitchSecondsElapsed = 0
		twitchSecondsInterval = INTERVAL_SECONDS_TWITCH_DEFAULT
	end
	applyWeightsEyeBlend(getFadeTimeValue())
end

local function loadTracksEyeBlend(animator_character: Animator)
	const animations: { Animation } = {}
	for _, pose in POSES_EYE_BLEND do
		const animation = Instance.new("Animation")
		animation.Name = PREFIX_NAME_ANIMATION .. pose.name
		animation.AnimationId = "rbxassetid://" .. tostring(pose.id)
		table.insert(animations, animation)
	end

	-- Animation assets load asynchronously; fetch them first so the tracks
	-- start with real data.
	SERVICE_CONTENT_PROVIDER:PreloadAsync(animations)

	for index, pose in POSES_EYE_BLEND do
		const track = animator_character:LoadAnimation(animations[index])
		track.Priority = PRIORITY_EYE_BLEND
		track.Looped = true
		-- Not played here: updateEyeBlend() starts each track at its real weight.
		tracksEyeBlend[pose.name] = track
	end
end

local function stopTracksEyeBlend()
	for pose_name, track in tracksEyeBlend do
		track:Stop(0)
		tracksEyeBlend[pose_name] = nil
	end
end

-- Tracks started by a previous run of this script (e.g. before a manual
-- disable/re-enable) are still playing on the Animator and would fight the
-- new ones, so stop every playing track that belongs to us.
local function stopOrphanTracksEyeBlend(animator_character: Animator)
	for _, track in animator_character:GetPlayingAnimationTracks() do
		const animation = track.Animation
		if animation and string.sub(animation.Name, 1, #PREFIX_NAME_ANIMATION) == PREFIX_NAME_ANIMATION then
			track:Stop(0)
		end
	end
end

-- Main

const controllerFound = findControllerCharacter(characterModel)
if not controllerFound then
	disableScriptMisplaced("character Model has no Humanoid or AnimationController")
	return
end
const controllerCharacter = controllerFound :: Humanoid | AnimationController

local function reloadTracksEyeBlend()
	stopTracksEyeBlend()
	if hasFlagDisabled() then return end

	if not waitUntilReadyCharacter(characterModel) then
		warn(`[EyeDirectionBlend] Character not ready after {TIMEOUT_SECONDS_LOAD}s (no FaceControls / appearance). `
			.. `Loading anyway; tracks reload if a FaceControls appears later. ({script:GetFullName()})`)
	end
	preloadHeadCharacter(characterModel)

	const animator = findAnimatorController(controllerCharacter)
	stopOrphanTracksEyeBlend(animator)
	loadTracksEyeBlend(animator)

	-- The flag may have appeared while the slow steps above were yielding.
	if hasFlagDisabled() then
		stopTracksEyeBlend()
		return
	end

	-- Fresh tracks aren't playing, so they start straight at their real weight
	-- (no fade involved). Re-entering the twitch path then also snaps the
	-- simulated fade to the current value, since no track weights exist to resume from.
	isTwitchActive = false
	updateEyeBlend(0)
end

-- Debounced, so a burst of triggers (face rig parts appearing, flag removed,
-- ...) results in a single reload.
local isReloadPendingEyeBlend = false
local function requestReloadTracksEyeBlend()
	if isReloadPendingEyeBlend then return end
	isReloadPendingEyeBlend = true
	task.delay(DELAY_SECONDS_RELOAD, function()
		reloadTracksEyeBlend()
		isReloadPendingEyeBlend = false
	end)
end

reloadTracksEyeBlend()

-- If the face rig is (re)applied later (e.g. HumanoidDescription changes),
-- tracks loaded against the old one go stale, so reload them.
characterModel.DescendantAdded:Connect(function(descendant: Instance)
	if descendant:IsA("FaceControls") then
		requestReloadTracksEyeBlend()
	end
end)

-- Disable flag: release every pose while it exists, restore once all are gone.
eyeDirectionValue.ChildAdded:Connect(function(child: Instance)
	if child.Name == NAME_FLAG_DISABLED then
		stopTracksEyeBlend()
	end
end)
eyeDirectionValue.ChildRemoved:Connect(function(child: Instance)
	if child.Name == NAME_FLAG_DISABLED and not hasFlagDisabled() then
		requestReloadTracksEyeBlend()
	end
end)

-- Changes apply immediately (no time passes, so twitch/fade timers hold still);
-- the per-frame pass below is the safety net that repairs any track that did not follow.
eyeDirectionValue.Changed:Connect(function()
	updateEyeBlend(0)
end)

SERVICE_RUN.Heartbeat:Connect(function(delta_time: number)
	updateEyeBlend(delta_time)
end)

-- If the setup is moved out of the character (or destroyed), let go of the poses.
script.AncestryChanged:Connect(function()
	if script.Parent ~= eyeDirectionValue
		or eyeDirectionValue.Parent ~= characterModel
	then
		stopTracksEyeBlend()
	end
end)
