--!strict

-- BurstTransmission
-- Credits:
-- <> St0rmCast3r a.k.a. Hammercroft

-- A mechanism for transmitting and receiving multiple packets of the
-- same effective message over a period of time on a UnreliableRemoteEvent,
-- introducing reliability despite the unreliable nature of UDP transmissions.

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
	
-- TODO topical (pub-sub) variations
-- TODO document usage notes, gotchas, and side-effects
-- TODO document how to fine tune transmission options

local module = {}

local rng = Random.new()
local function randomInt32(): number
	return rng:NextInteger(0, 2_147_483_647)
end

export type BurstTransmitterOptions = {
	burst_duration : number,
	start_fire_rate : number,
	end_fire_rate : number,
	pre_ease_coverage : number,
	ease_to_post_ratio : number
}

export type BurstTransmitter = {
	target : UnreliableRemoteEvent,
	activeBursts : {[number]:boolean},
	options : BurstTransmitterOptions,
	transmit : (self : BurstTransmitter, targetPlayer:Player?, ...any) -> (number),
	stopTransmission : (self : BurstTransmitter, burstId:number) -> (),
	precalculated : {
		duration : number,
		preEaseCoverage : number,
		easeToPostRatio : number,
		startingFireRate : number,
		endingFireRate : number,
		startingInterval : number,
		endingInterval : number,
		preEaseDuration : number,
		easeDuration : number,
		--postEaseHoldDuration : number,
	},
	destroy : (self : BurstTransmitter) -> ()
}

-- Sends a burst transmission to a configured UnreliableRemoteEvent target.
-- @param targetPlayer a target player to send the transmission to. This argument is ignored when invoked in the client side.
-- @param ... A tuple of data to be transmitted
-- @return the numeric burst ID that was used for the transmission
local function func_transmit(self : BurstTransmitter, targetPlayer:Player?, ...) : number
	local data = {...}
	local id = randomInt32()   -- Unique identifier for this burst
	task.defer(@native function()
		local cache = self.precalculated

		-- timing values and phase schedules
		local startTime = tick()
		local burstEndTime = startTime + cache.duration
		local preEaseDuration = cache.duration * cache.preEaseCoverage
		local fireRateEaseStartTime = startTime + preEaseDuration
		local remainingDurationAfterPreEase = cache.duration - preEaseDuration
		local fireRateEaseEndTime = fireRateEaseStartTime + cache.easeDuration

		local burstPacketIndex = 1 -- Counter for the sequential packet index
		local currentTime = tick()
		local currentInterval = cache.startingInterval

		self.activeBursts[id] = true
		while tick() < burstEndTime and self.activeBursts[id] do
			-- Fire the shot to the server with burst ID, packet index, and data payload
			if game:GetService("RunService"):IsServer() then
				if targetPlayer then
					self.target:FireClient(
						targetPlayer,
						id,					-- Unique identifier for this burst instance
						burstPacketIndex,   -- Sequential index of this packet within the burst
						table.unpack(data)  -- The payload data to be sent
					)
				else
					error("Target player is required when transmitting bursts from the server.")
				end
			else
				self.target:FireServer(
					id,                 -- Unique identifier for this burst instance
					burstPacketIndex,   -- Sequential index of this packet within the burst
					table.unpack(data)  -- The payload data to be sent
				)
			end
			burstPacketIndex = burstPacketIndex + 1 -- Increment packet index for the next shot

			-- calculate wait time based on current phase
			if currentTime < fireRateEaseStartTime then
				-- Phase 1: Before easing begins, the fire rate is constant at the `startingFireRate`.
				--currentInterval = startingInterval
			elseif currentTime < fireRateEaseEndTime then
				-- Phase 2: During easing, linearly interpolate the interval between `startingInterval` and `endingInterval`.
				local alpha = (currentTime - fireRateEaseStartTime) / cache.easeDuration
				currentInterval = cache.startingInterval + (cache.endingInterval - cache.startingInterval) * alpha
			else
				-- Phase 3: After easing (and during the post-ease hold), the fire rate is constant at the `endingFireRate`.
				currentInterval = cache.endingInterval
			end
			task.wait(currentInterval)
		end
		if self.activeBursts[id] then
			self.activeBursts[id] = nil
		end
	end)		
	return id	
end

-- Stops a transmission burst with the given burstId.
-- @param burstId The unique identifier of the burst transmission to stop.
local function func_stopTransmission(self:BurstTransmitter, burstId:number)
	if self.activeBursts[burstId] then
		self.activeBursts[burstId] = nil
	end
end

-- Destroys the BurstTransmitter object, cleaning up any resources.
local function func_destroy(self:BurstTransmitter)
	self.activeBursts = nil :: any
	self.precalculated = nil :: any
	self.target = nil :: any
	self.options = nil :: any
	self.destroy = nil :: any
	self.transmit = nil :: any
	self = nil :: any
end

-- Constructs a new BurstTransmitter object.
-- @param target_unreliable_remote_event The UnreliableRemoteEvent to transmit bursts on.
-- @param options? An OPTIONAL table of configuration values for the BurstTransmitter. If nil, a default configuration is used.
-- @returns A new BurstTransmitter object.
function module.newBurstTransmitter(target_unreliable_remote_event : UnreliableRemoteEvent, passed_options : BurstTransmitterOptions?) : BurstTransmitter
	local btTable : BurstTransmitter = {
		target = target_unreliable_remote_event,
		activeBursts = {},
		options = passed_options and passed_options or { -- TERNARY : passed options or default options
			burst_duration = 0.5,
			start_fire_rate = 44,
			end_fire_rate = 16,
			pre_ease_coverage = 0.1,
			ease_to_post_ratio = 0.3
		},
		transmit = func_transmit,
		stopTransmission = func_stopTransmission,
		precalculated = nil :: any, -- to be set later
		destroy = func_destroy,
	}
	
	-- Precalculate and cache burst timing values
	local opts = btTable.options
	local duration = opts.burst_duration
	local preEase = opts.pre_ease_coverage
	local easeRatio = opts.ease_to_post_ratio
	local startRate = opts.start_fire_rate
	local endRate = opts.end_fire_rate

	local startInt = 1 / startRate
	local endInt = 1 / endRate
	local preEaseDur = duration * preEase
	local easeDur = (duration - preEaseDur) / (1 + easeRatio)
	--local postHoldDur = easeDur * easeRatio

	btTable.precalculated = {
		duration = duration,
		preEaseCoverage = preEase,
		easeToPostRatio = easeRatio,
		startingFireRate = startRate,
		endingFireRate = endRate,
		startingInterval = startInt,
		endingInterval = endInt,
		preEaseDuration = preEaseDur,
		easeDuration = easeDur,
		--postEaseHoldDuration = postHoldDur,
	}
	
	return btTable
end

export type BurstReceiver = {
	source : UnreliableRemoteEvent,
	ignoredIds : {number},
	ignoredIdsTableSize : number,
	sourceConnection : RBXScriptConnection,
	dataHandlingCallback : ((...any)->())|nil,
	close : (self:BurstReceiver)->(),
}

-- Stops listening for bursts and destroys this BurstReceiver.
local function func_close(self:BurstReceiver)
	if self.sourceConnection then
		self.sourceConnection:Disconnect()
		self.sourceConnection = nil :: any
	end
	-- destroy!
	self.source = nil :: any
	self.close = nil :: any
	self.ignoredIds = nil :: any
	self.dataHandlingCallback = nil :: any
	self.ignoredIdsTableSize = nil :: any
	self = nil :: any
end

local function setupServerReceiver(brTable : BurstReceiver, includeBurstTransportInfoAlongData)
	if includeBurstTransportInfoAlongData then
		brTable.sourceConnection = brTable.source.OnServerEvent:Connect(function(player: Player, id: number, seq: number, ...)
			local data = {...}
			task.defer(function()
				if table.find(brTable.ignoredIds, id) then return end
				table.insert(brTable.ignoredIds, id)

				if brTable.dataHandlingCallback then
					brTable.dataHandlingCallback(id, seq, player, table.unpack(data))
				end

				if #brTable.ignoredIds > brTable.ignoredIdsTableSize then
					table.remove(brTable.ignoredIds, 1)
				end
			end)
		end)
	else
		brTable.sourceConnection = brTable.source.OnServerEvent:Connect(function(player: Player, id: number, seq: number, ...)
			local data = {...}
			task.defer(function()
				if table.find(brTable.ignoredIds, id) then return end
				table.insert(brTable.ignoredIds, id)

				if brTable.dataHandlingCallback then
					brTable.dataHandlingCallback(player, table.unpack(data))
				end

				if #brTable.ignoredIds > brTable.ignoredIdsTableSize then
					table.remove(brTable.ignoredIds, 1)
				end
			end)
		end)
	end
end

local function setupClientReceiver(brTable : BurstReceiver, includeBurstTransportInfoAlongData)
	if includeBurstTransportInfoAlongData then
		brTable.sourceConnection = brTable.source.OnClientEvent:Connect(function(id: number, seq: number, ...)
			local data = {...}
			task.defer(function()
				if table.find(brTable.ignoredIds, id) then return end
				table.insert(brTable.ignoredIds, id)

				if brTable.dataHandlingCallback then
					brTable.dataHandlingCallback(id, seq, table.unpack(data))
				end

				if #brTable.ignoredIds > brTable.ignoredIdsTableSize then
					table.remove(brTable.ignoredIds, 1)
				end
			end)
		end)
	else
		brTable.sourceConnection = brTable.source.OnClientEvent:Connect(function(id: number, seq: number, ...)
			local data = {...}
			task.defer(function()
				if table.find(brTable.ignoredIds, id) then return end
				table.insert(brTable.ignoredIds, id)

				if brTable.dataHandlingCallback then
					brTable.dataHandlingCallback(table.unpack(data))
				end

				if #brTable.ignoredIds > brTable.ignoredIdsTableSize then
					table.remove(brTable.ignoredIds, 1)
				end
			end)
		end)
	end
end

-- Constructs a new BurstReceiver object.
-- @param source_unreliable_remote_event The UnreliableRemoteEvent to listen to for bursts.
-- @param data_handler? A function that handles incoming burst data. Can be nil.
-- @param includeBurstTransportInfoAlongData? If true, the first value passed unto the data_handler will be the burst id, the second value will be the sequence number, and the rest will be the data. If false, only the data will be passed.
-- @param ignoredIdsTableSize? The size of the table that holds burst ids to be ignored. If not provided, it will default to 64.
-- @NOTE If constructed on the server, all incoming data tuples will include the player as the first value of the tuple.
function module.newBurstReceiver(source_unreliable_remote_event : UnreliableRemoteEvent, dataHandler : ((...any)->())|nil, includeBurstTransportInfoAlongData : boolean?, ignoredIdsTableSize: number?) : BurstReceiver
	local brTable : BurstReceiver = {
		source = source_unreliable_remote_event,
		ignoredIds = {},
		ignoredIdsTableSize = ignoredIdsTableSize and ignoredIdsTableSize or 64, -- TERNARY : parameter or default
		sourceConnection = nil :: any, -- to be set later
		dataHandlingCallback = dataHandler,
		close = func_close,
	}
	
	if game:GetService("RunService"):IsServer() then
		setupServerReceiver(brTable, includeBurstTransportInfoAlongData)
	else
		setupClientReceiver(brTable, includeBurstTransportInfoAlongData)
	end
	return brTable
end

return module
