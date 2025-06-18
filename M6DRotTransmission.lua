--!strict

-- M6DRotTransmission
-- Credits:
-- <> St0rmCast3r a.k.a. Hammercroft

-- A mechanism for efficiently transmitting and receiving Motor6D rotation 
-- data from a client to the server. Transmissions can occur on either
-- RemoteEvents and UnreliableRemoteEvents, and are delta-encoded to save
-- on client upload bandwidth.

--[[
MIT License

Copyright (c) 2025 Hammercroft

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

--================================================================================--

local module = {}

export type AbstractRemote = {
	FireServer: (self: AbstractRemote, ...any) -> (),
	OnServerEvent: RBXScriptSignal,

	FireClient: (self: AbstractRemote, player: Player, ...any) -> (),
	FireAllClients: (self: AbstractRemote, ...any) -> (),
	OnClientEvent: RBXScriptSignal,
} & Instance

export type M6DRotTransmitter ={
	_active : boolean,
	_lifetimeTokenInstance : Instance,
	_tokenDestructionConnection : RBXScriptConnection,
	_socket : AbstractRemote,
	_socketDestructionConnection : RBXScriptConnection,
	_motor : Motor6D,
	_motorDestructionConnection : RBXScriptConnection,
	maximumTransmissionRate : number, -- 60 by default
	cyclesBetweenKeyframes : number , -- 29 by default
	deltaAngleThresholdRadians : number, -- 2 degrees by default
	
	start : (self : M6DRotTransmitter) -> (),
	stop : (self : M6DRotTransmitter) -> (),
	close : (self : M6DRotTransmitter) -> ()
}

--[[
	Transmission payload
	boolean (whether if this is delta or keyframe)
	3 numbers, representing C0 XYZ
	3 numbers, representing C1 XYZ
]]

--- Checks if any component (X, Y, or Z) of a Vector3 exceeds a given absolute threshold. 
-- @param vec Vector3 The vector to check. 
-- @param abs_threshold number The absolute threshold to compare against. 
-- @return boolean True if any component's absolute value is greater than the threshold, false otherwise. 
function module.isAnyComponentPastAbsThreshold(vec:Vector3, abs_threshold:number) : boolean
	if math.abs(vec.X) > abs_threshold or 
		math.abs(vec.Y) > abs_threshold or
		math.abs(vec.Z) > abs_threshold
	then
		return true
	end
	return false
end

--- Starts the transmission of Motor6D rotation data for the transmitter. 
-- If the transmitter is already active, this function does nothing. 
-- It sends an initial keyframe and then enters a loop to periodically transmit 
-- either delta updates or full keyframes based on `maximumTransmissionRate`, 
-- `cyclesBetweenKeyframes`, and `deltaAngleThresholdRadians`. 
-- @param self M6DRotTransmitter The M6DRotTransmitter instance. 
function transmitter_start(self : M6DRotTransmitter)
	if self._active then return end
	self._active = true
	if not self._active then return end -- Type checker appeasement : _active will never be false at this point
	
	local interval : number = 1 / self.maximumTransmissionRate
	-- init
	local shouldTransmitDelta : boolean = true
	local cyclesUntilKeyframeCounter : number = self.cyclesBetweenKeyframes
	local lastC0 : CFrame = self._motor.C0
	local lastC1 : CFrame = self._motor.C1
	local c0 : Vector3 = Vector3.new(self._motor.C0:ToEulerAnglesXYZ())
	local c1 : Vector3 = Vector3.new(self._motor.C1:ToEulerAnglesXYZ())
	local preTransmitTick : number = 0
	local postTransmitTick : number = 0
	-- first fire
	do
		self._socket:FireServer(
			false, -- false denotes key / full orientation transmission
			c0.X,c0.Y,c0.Z,
			c1.X,c1.Y,c1.Z
		)
		lastC0 = self._motor.C0
		lastC1 = self._motor.C1
	end
	local preDeferTick = tick()
	task.defer(function()
		task.wait(interval - (tick()-preDeferTick))
		-- transmission loop
		while self._active do
			preTransmitTick = tick()

			if cyclesUntilKeyframeCounter <= 0 then
				-- transmit keyframe
				c0 = Vector3.new(self._motor.C0:ToEulerAnglesXYZ())
				c1 = Vector3.new(self._motor.C1:ToEulerAnglesXYZ())
				self._socket:FireServer(
					false, -- false denotes keyframe / full orientation transmission
					c0.X,c0.Y,c0.Z,
					c1.X,c1.Y,c1.Z
				)
				lastC0 = self._motor.C0
				lastC1 = self._motor.C1
				cyclesUntilKeyframeCounter = self.cyclesBetweenKeyframes
			else
				-- attempt to transmit delta
				if self._motor.C0 ~= lastC0 or
					self._motor.C1 ~= lastC1 then
					shouldTransmitDelta = false
					c0 = Vector3.new((lastC0:Inverse() * self._motor.C0):ToEulerAnglesXYZ())
					c1 = Vector3.new((lastC1:Inverse() * self._motor.C1):ToEulerAnglesXYZ())
					if module.isAnyComponentPastAbsThreshold(c0, self.deltaAngleThresholdRadians) or
						module.isAnyComponentPastAbsThreshold(c1, self.deltaAngleThresholdRadians)
					then
						self._socket:FireServer(
							true, -- true denotes delta / difference transmission
							c0.X,c0.Y,c0.Z,
							c1.X,c1.Y,c1.Z
						)
						lastC0 = self._motor.C0
						lastC1 = self._motor.C1
					end
					cyclesUntilKeyframeCounter -= 1
				end
			end

			postTransmitTick = tick()
			task.wait(interval - (postTransmitTick-preTransmitTick))
		end
	end)
end

--- Stops the transmission of Motor6D rotation data for the transmitter. 
-- If the transmitter is not active, this function does nothing. 
-- @param self M6DRotTransmitter The M6DRotTransmitter instance. 
function transmitter_stop(self : M6DRotTransmitter)
	if not self._active then return end
	self._active = false
end

--- Cleans up the M6DRotTransmitter instance. 
-- Disconnects all associated `RBXScriptConnection`s and nilifies references 
-- to prevent memory leaks. 
-- @param self M6DRotTransmitter The M6DRotTransmitter instance. 
function transmitter_close(self : M6DRotTransmitter)
	if not self then return end
	if self._active then
		self:stop()
	end
	if self._motorDestructionConnection then
		self._motorDestructionConnection:Disconnect()
		self._motorDestructionConnection = nil :: any
	end
	if self._tokenDestructionConnection then
		self._tokenDestructionConnection:Disconnect()
		self._tokenDestructionConnection = nil :: any
	end
	if self._socketDestructionConnection then
		self._socketDestructionConnection:Disconnect()
		self._socketDestructionConnection = nil :: any
	end
	self._motor = nil :: any
	self._socket = nil :: any
	self._lifetimeTokenInstance = nil :: any
	self._active = nil :: any
	self.start = nil :: any
	self.stop = nil :: any
	self.close = nil :: any
end

--- Creates a new M6DRotTransmitter instance. 
-- This transmitter sends Motor6D C0 and C1 rotation data over a specified remote event. 
-- The transmitter's lifecycle is tied to `lifetime_token_instance`, `dedicated_remote_event`, and `target_motor6d`. 
-- @param lifetime_token_instance Instance An instance whose destruction will cause the transmitter to close. 
-- @param dedicated_remote_event AbstractRemote The RemoteEvent or UnreliableRemoteEvent to use for sending data. 
-- @param target_motor6d Motor6D The Motor6D whose rotations will be transmitted. 
-- @param max_transmission_rate number? The maximum rate (in Hz) at which data will be transmitted. Defaults to 60. 
-- @param delta_angle_threshold_radians number? The minimum angular change (in radians) in any rotational component to trigger a delta transmission. Defaults to 2 degrees (math.rad(2)). 
-- @param cycles_between_keyframes number? The number of delta transmissions that occur before a full keyframe is sent. Defaults to 29. 
-- @param disable_parameter_validation boolean? If true, skips runtime parameter validation for performance. 
-- @return M6DRotTransmitter A new M6DRotTransmitter instance. 
function module.newTransmitter(
	lifetime_token_instance : Instance,
	dedicated_remote_event : AbstractRemote,
	target_motor6d : Motor6D,
	max_transmission_rate : number?,
	delta_angle_threshold_radians : number?,
	cycles_between_keyframes : number?,
	disable_parameter_validation : boolean?
) : M6DRotTransmitter
	-- (end of parameters)
	local transmitter : M6DRotTransmitter = {
		_active = false,
		_lifetimeTokenInstance = lifetime_token_instance,
		_tokenDestructionConnection = nil :: any, -- assigned later
		_socket = dedicated_remote_event,
		_socketDestructionConnection = nil :: any, -- ditto
		_motor = target_motor6d,
		_motorDestructionConnection = nil :: any, -- ditto
		maximumTransmissionRate = max_transmission_rate and max_transmission_rate or 60,
		cyclesBetweenKeyframes = cycles_between_keyframes and cycles_between_keyframes or 29,
		deltaAngleThresholdRadians = delta_angle_threshold_radians and delta_angle_threshold_radians or math.rad(2),
		start = transmitter_start,
		stop = transmitter_stop,
		close = transmitter_close
	}
	if not disable_parameter_validation then -- parameter validation, optional for speed
		assert(lifetime_token_instance, "A lifetime token instance is required")
		assert(typeof(lifetime_token_instance) == "Instance", `Lifetime token must be an Instance, got type: {typeof(lifetime_token_instance)}`)

		assert(dedicated_remote_event, "A dedicated remote event is required")
		assert(typeof(dedicated_remote_event) == "Instance", `Expected dedicated remote to be an Instance, got: {typeof(dedicated_remote_event)}`)
		assert(
			dedicated_remote_event:IsA("UnreliableRemoteEvent") or dedicated_remote_event:IsA("RemoteEvent"),
			`Dedicated remote must be a RemoteEvent or UnreliableRemoteEvent, got: {dedicated_remote_event.ClassName} ("{dedicated_remote_event.Name}")`
		)

		assert(target_motor6d, "A target Motor6D is required")
		assert(typeof(target_motor6d) == "Instance", `Target must be an Instance, got type: {typeof(target_motor6d)}`)
		assert(target_motor6d:IsA("Motor6D"), `Target instance must be a Motor6D, got: {target_motor6d.ClassName} ("{target_motor6d.Name}")`)

		if max_transmission_rate ~= nil then
			assert(typeof(max_transmission_rate) == "number", `maximumTransmissionRate must be a number, got: {typeof(max_transmission_rate)}`)
			assert(max_transmission_rate > 0, `maximumTransmissionRate must be > 0, got: {max_transmission_rate}`)
		end

		if delta_angle_threshold_radians ~= nil then
			assert(typeof(delta_angle_threshold_radians) == "number", `deltaAngleThresholdRadians must be a number, got: {typeof(delta_angle_threshold_radians)}`)
			assert(delta_angle_threshold_radians >= 0, `deltaAngleThresholdRadians must be >= 0, got: {delta_angle_threshold_radians}`)
		end

		if cycles_between_keyframes ~= nil then
			assert(typeof(cycles_between_keyframes) == "number", `cyclesBetweenKeyframes must be a number, got: {typeof(cycles_between_keyframes)}`)
			assert(cycles_between_keyframes >= 0, `cyclesBetweenKeyframes must be >= 0, got: {cycles_between_keyframes}`)
		end
	end
	
	transmitter._motorDestructionConnection = transmitter._motor.Destroying:Connect(function()
		transmitter:close()
	end)
	transmitter._tokenDestructionConnection = transmitter._lifetimeTokenInstance.Destroying:Connect(function()
		transmitter:close()
	end)
	transmitter._socketDestructionConnection = transmitter._socket.Destroying:Connect(function()
		transmitter:close()
	end)
	
	return transmitter
end

export type M6DRotReceiver = {
	_motor:Motor6D,
	_motorDestructionConnection:RBXScriptConnection,
	_socket:AbstractRemote,
	_socketDestructionConnection:RBXScriptConnection,
	senderFilter:Player|nil|(plr:Player,this_socket:AbstractRemote)->(boolean),
	_lifetimeTokenInstance : Instance,
	_lifetimeTokenDestructionConnection:RBXScriptConnection,
	active : boolean,
	_socketConnection : RBXScriptConnection,
	close : (self:M6DRotReceiver)->()
}

local function shouldAcceptEvent(
	senderFilter: Player | nil | (plr: Player, this_socket: AbstractRemote) -> boolean,
	sender: Player,
	socket: AbstractRemote
): boolean
	if senderFilter == nil then
		return true
	elseif typeof(senderFilter) == "Instance" and senderFilter:IsA("Player") then
		return sender == senderFilter
	elseif typeof(senderFilter) == "function" then
		return senderFilter(sender, socket)
	else
		warn("Invalid senderFilter type. Rejecting event.")
		return false
	end
end

--- Cleans up the M6DRotReceiver instance. 
-- Disconnects all associated `RBXScriptConnection`s and nilifies references 
-- to prevent memory leaks. 
-- @param self M6DRotReceiver The M6DRotReceiver instance. 
function receiver_close(self:M6DRotReceiver)
	if self.active then
		self.active = false
	end
	if self._motorDestructionConnection then
		self._motorDestructionConnection:Disconnect()
		self._motorDestructionConnection = nil :: any
	end
	if self._socketDestructionConnection then
		self._socketDestructionConnection:Disconnect()
		self._socketDestructionConnection = nil :: any
	end
	if self._lifetimeTokenDestructionConnection then
		self._lifetimeTokenDestructionConnection:Disconnect()
		self._lifetimeTokenDestructionConnection = nil :: any
	end
	self._motor = nil :: any
	self._socket = nil :: any
	self.senderFilter = nil :: any
	self._lifetimeTokenInstance = nil :: any
end

--- Validates the `senderFilter` parameter for the M6DRotReceiver. 
-- This function asserts if the filter is not a Player instance, a function, or nil. 
-- It does not return anything but may throw assertion errors if validation fails. 
-- @param filter Player|nil|(plr:Player,socket:AbstractRemote)->boolean The filter to validate. 
-- @param contextName string? An optional name for the validation context, used in assertion messages. 
-- @returns nothing 
function module.validateSenderFilter(
	filter: Player | nil | (plr: Player, socket: AbstractRemote) -> boolean,
	contextName: string?
)
	if filter == nil then return end

	local filterType = typeof(filter)
	assert(
		filterType == "Instance" or filterType == "function",
		`senderFilter must be a Player, a function, or nil; got: {filterType}`
	)
	-- filterType is not used beyond this point as Luau can't use it for type inference =(

	if typeof(filter) == "Instance" then
		assert(filter:IsA("Player"), `senderFilter as Instance must be a Player, got: {filter.ClassName} ("{filter.Name}")`)
	elseif typeof(filter) == "function" then
		-- TODO do we incorporate runtime test for senderFilter callbacks?
		--[[
		local testPlayer = game:GetService("Players"):FindFirstChildOfClass("Player")
		if testPlayer then
			local ok, result = pcall(function()
				return filter(testPlayer, {} :: any)
			end)
			if not ok then
				warn(`[validateSenderFilter] senderFilter function errored during test: {result}`)
			elseif typeof(result) ~= "boolean" then
				warn(`[validateSenderFilter] senderFilter function returned non-boolean: {typeof(result)}`)
			end
		end
		]]
	end
end

--- Creates a new M6DRotReceiver instance. 
-- This receiver listens for Motor6D C0 and C1 rotation data on a specified remote event 
-- and applies it to a target Motor6D. 
-- The receiver's lifecycle is tied to `the_lifetime_token`, `the_socket`, and `the_motor`. 
-- @param the_motor Motor6D The Motor6D that will have its rotations updated by incoming data. 
-- @param the_socket AbstractRemote The RemoteEvent or UnreliableRemoteEvent to listen on for incoming data. 
-- @param the_filter Player|nil|(plr:Player,this_socket:AbstractRemote)->boolean An optional filter to control which sender's events are processed. 
-- @param the_lifetime_token Instance An instance whose destruction will cause the receiver to close. 
-- @param starts_active boolean? If true or non-nil, the receiver will start in an active state and immediately process events. Defaults to false. 
-- @param disable_parameter_validation boolean? If true, skips runtime parameter validation for performance. 
-- @return M6DRotReceiver A new M6DRotReceiver instance. 
function module.newReceiver(
	the_motor : Motor6D,
	the_socket : AbstractRemote,
	the_filter : Player|nil|(plr:Player,this_socket:AbstractRemote)->(boolean),
	the_lifetime_token : Instance,
	starts_active : boolean?,
	disable_parameter_validation : boolean?
) : M6DRotReceiver
	local receiver : M6DRotReceiver = {
		_motor = the_motor,
		_socket = the_socket,
		_socketConnection = nil :: any, -- set later
		senderFilter = the_filter,
		_lifetimeTokenInstance = the_lifetime_token,
		active = starts_active and true or false, -- Ternary : active == true if starts_active is true or non-nil
		_motorDestructionConnection = nil :: any, -- set later
		_socketDestructionConnection = nil :: any, -- set later
		_lifetimeTokenDestructionConnection = nil :: any, -- set later
		close = receiver_close -- set later
	}
	if not disable_parameter_validation then
		if not disable_parameter_validation then
			assert(the_motor, "Motor6D is required")
			assert(typeof(the_motor) == "Instance", `Expected Motor6D to be an Instance, got: {typeof(the_motor)}`)
			assert(the_motor:IsA("Motor6D"), `Expected Motor6D, got: {the_motor.ClassName} ("{the_motor.Name}")`)

			assert(the_socket, "Socket (AbstractRemote) is required")
			assert(typeof(the_socket) == "Instance", `Expected socket to be an Instance, got: {typeof(the_socket)}`)
			assert(
				the_socket:IsA("RemoteEvent") or the_socket:IsA("UnreliableRemoteEvent"),
				`Socket must be a RemoteEvent or UnreliableRemoteEvent, got: {the_socket.ClassName} ("{the_socket.Name}")`
			)

			assert(the_lifetime_token, "Lifetime token is required")
			assert(typeof(the_lifetime_token) == "Instance", `Expected lifetime token to be an Instance, got: {typeof(the_lifetime_token)}`)

			module.validateSenderFilter(the_filter)
		end

	end
	receiver._socketConnection = receiver._socket.OnServerEvent:Connect(
		function(player: Player, isDeltaTransmission : boolean, ...)
			if not receiver.active then return end
			if not shouldAcceptEvent(receiver.senderFilter,player,receiver._socket) then return end
			
			if not isDeltaTransmission then
				-- keyframe / full transmission of neck orientation
				local c0AngleX:number,c0AngleY:number,c0AngleZ:number,c1AngleX:number,c1AngleY:number,c1AngleZ:number = ...
				receiver._motor.C0 = CFrame.new(receiver._motor.C0.Position) * CFrame.Angles(c0AngleX,c0AngleY,c0AngleZ)
				receiver._motor.C1 = CFrame.new(receiver._motor.C1.Position) * CFrame.Angles(c1AngleX,c1AngleY,c1AngleZ)
			else
				-- delta / difference transmission of neck orientation
				local deltaC0AngleX:number,deltaC0AngleY:number,deltaC0AngleZ:number,deltaC1AngleX:number,deltaC1AngleY:number?,deltaC1AngleZ:number? = ...
				local deltaC0 = CFrame.Angles(deltaC0AngleX,deltaC0AngleY,deltaC0AngleZ)
				local deltaC1 = CFrame.Angles(deltaC1AngleX,deltaC1AngleY or 0,deltaC1AngleZ or 0)
				receiver._motor.C0 = receiver._motor.C0 * deltaC0
				receiver._motor.C1 = receiver._motor.C1 * deltaC1
			end
		end
	)
	receiver._motorDestructionConnection = receiver._motor.Destroying:Connect(function()
		receiver:close()
	end)
	receiver._lifetimeTokenDestructionConnection = receiver._lifetimeTokenInstance.Destroying:Connect(function()
		receiver:close()
	end)
	receiver._socketDestructionConnection = receiver._socket.Destroying:Connect(function()
		receiver:close()
	end)
	return receiver
end

------------------------ MOTOR UTILS -----------------------

--- Returns the Motor6D for the Right Arm in an R6 rig. 
-- It searches for a Motor6D under the character's "Torso" named "Right Arm" in its Part1 property. 
-- @param character Model The R6 character model. 
-- @return Motor6D? The Right Arm Motor6D if found, otherwise nil. 
function module.getRightArmMotor(character: Model): Motor6D?
	local torso = character:FindFirstChild("Torso")
	if not torso then return nil end

	for _, child in torso:GetChildren() do
		if child:IsA("Motor6D") and child.Part1 and child.Part1.Name == "Right Arm" then
			return child
		end
	end

	return nil
end

--- Returns the Motor6D for the Left Arm in an R6 rig. 
-- It searches for a Motor6D under the character's "Torso" named "Left Arm" in its Part1 property. 
-- @param character Model The R6 character model. 
-- @return Motor6D? The Left Arm Motor6D if found, otherwise nil. 
function module.getLeftArmMotor(character: Model): Motor6D?
	local torso = character:FindFirstChild("Torso")
	if not torso then return nil end

	for _, child in torso:GetChildren() do
		if child:IsA("Motor6D") and child.Part1 and child.Part1.Name == "Left Arm" then
			return child
		end
	end

	return nil
end

------------------ REPLICATION DECOUPLERS ------------------

--- Creates a local copy of a server-to-client replicated instance.
-- The original instance is DESTROYED.
--
-- This pattern is commonly applied when the local state is transmitted to the server
-- at regular intervals, and you need to isolate the instance from future server changes.
--
-- Optionally, a unique suffix can be appended to the cloned instance’s name to help
-- distinguish it from its original source.
--
-- @param originalReplicatedInstance Instance The replicated instance to localise.
-- @param do_not_generate_unique_suffix boolean? If true, skips appending a unique name suffix to the clone.
-- @return Instance The locally cloned instance.
function module.localinator(originalReplicatedInstance: Instance, do_not_generate_unique_suffix:boolean?): Instance
	assert(typeof(originalReplicatedInstance) == "Instance", "localinator an Instance.")

	local parent = originalReplicatedInstance.Parent
	if not parent then
		warn("Instance has no parent and thus cannot be replicated - localinator is not needed.")
		return originalReplicatedInstance
	end

	local localInstance = originalReplicatedInstance:Clone()
	if not do_not_generate_unique_suffix then
		local uniqueSuffix = game.HttpService:GenerateGUID(false):gsub("%-", "")
		localInstance.Name = originalReplicatedInstance.Name .. "_" .. uniqueSuffix
	end
	localInstance.Parent = parent

	originalReplicatedInstance:Destroy()

	return localInstance
end

--- A non-destructive alternative of localinator() for Motor6Ds.
-- Originally made by dthecoolest.
-- https://devforum.roblox.com/t/client-replicate-motor6d-offset-to-server/1081351
-- 
-- The original Motor6D is disabled, and a uniquely named, enabled clone is created
-- and parented to the same parent for decoupled replication. After using the cloned
-- Motor6D, it may be necessary to destroy it and re-enable the original Motor6D.
-- 
-- @function replicationDecoupledMotor6D
-- @param originalReplicatedMotor Motor6D The Motor6D to be safely cloned for replication.
-- @treturn Motor6D A new enabled clone of the original Motor6D, suitable for independent use.
function module.replicationDecoupledMotor6D(originalReplicatedMotor: Motor6D): Motor6D
	assert(typeof(originalReplicatedMotor) == "Instance", "replicationDecoupledMotor6D provided argument is not even an instance!")
	assert(originalReplicatedMotor:IsA("Motor6D"), "replicationDecoupledMotor6D expects a Motor6D Instance.")
	originalReplicatedMotor.Enabled = false
	local clone = originalReplicatedMotor:Clone()
	clone.Enabled = true
	clone.Parent = originalReplicatedMotor.Parent
	local uniqueSuffix = game.HttpService:GenerateGUID(false):gsub("%-", "")
	clone.Name = originalReplicatedMotor.Name .. "_" .. uniqueSuffix
	return clone
end

return module
