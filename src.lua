--[[
	* Zappy
	
	Simple and robust reactive state container
	
	@ Reflinders
]]

--[[
	Version => 1.0 (Release)
]]

local OBSV_HEAD_NODE = "obsvhead"
local OBSV_TAIL_NODE = "obsvtail"

local WEAK_KEYS = { __mode = "k" }

--@@ Fn

function decompose(val)
	--@ if tuple, then return as table
	--@ if not tuple, return as single value

	local is_tbl = type(val) == "table"

	if is_tbl and #val == 1 then
		return val[1]
	end	

	return val
end

function isEqual(var1, var2)
	local t1, t2 = type(var1), type(var2)

	if t1 ~= t2 then
		return false
	end

	if t1 ~= "table" then
		return var1 == var2
	end

	for key, v in pairs(var1) do
		if v ~= var2[key] then
			return false
		end
	end

	for key, v in pairs(var2) do
		if v ~= var1[key] then
			return false
		end
	end

	return true
end

function isTuple(obj)
	return type(obj) == "table"
end

function getStateType(state)
	if isTuple(state) then
		return typeof(state[1])
	end

	return typeof(state)
end

--@@ Class `Observer`

local Observer = {}
do
	Observer.__index = Observer

	function Observer:Unsubscribe()
		if (self.fn==nil) then
			return
		end

		if self.prev then
			--@ this is a trailing node
			-- therefore, detachment is affordable
			
			self.prev.next = self.next -- connects the previous node to the next
			
			if self.next then
				self.next.prev = self.prev -- connects the next node to the previous
			end
			
			self.prev = nil
			self.next = nil
		end

		self.fn = nil
	end

	function Observer.new(fn, prev)
		return setmetatable({ 
			fn = fn;
			prev = prev;
			next = nil;
		}, Observer)
	end
end

--@@ Class `Zappy`

local Zappy = {}
Zappy.__index = Zappy

do
	--@static
	
	function Zappy.is(obj)
		return type(obj) == "table" 
			and getmetatable(obj) == Zappy
	end

	function Zappy:isTuple()
		return isTuple(self.state)
	end
	
	--@private
	
	function Zappy:_hasObservers()
		local _, catch = next(self.catchers)

		return self[OBSV_HEAD_NODE] ~= nil
			or catch ~= nil
	end
	
	function Zappy:_getSetter(fn)
		--@ mainly used for observers
		-- arg passed into observer is the literal
		-- so no need to decompose!

		if fn then
			return function(val)
				val = fn(val)

				self:Set(val)
			end
		end

		return function(val)
			self:Set(val)
		end
	end
end

do
	local freeThread

	local function runThread(fn, ...)
		local temp = freeThread
		freeThread = nil
		fn(...)
		freeThread = temp
	end

	local function threadYielder(observers)
		while true do
			runThread(coroutine.yield())
		end 
	end

	local function spawnThread(fn, ...)
		if not freeThread then
			freeThread = coroutine.create(threadYielder)
			coroutine.resume(freeThread)
		end

		task.spawn(freeThread, fn, ...)	
	end
	
	function Zappy:_runWatcherThread(state)
		local node = self[OBSV_HEAD_NODE]
		local catchers = self.catchers

		for key, catcher in catchers do
			if catcher.fn then
				spawnThread(catcher.fn, state)
			else
				catchers[key] = nil
			end
		end
		
		if node and (node.fn==nil) then
			--@ since the head-node cannot detach itself without reference to the zap-state
			-- we have to remove it ourselves
			
			node = node.next
			self[OBSV_HEAD_NODE] = node
		end
		
		while (node) do	
			spawnThread(node.fn, state)

			node = node.next
		end
	end
end

--@pub methods

function Zappy:Destroy()
	self.state = nil
	self.const = nil
	self.catchers = nil
	
	self[OBSV_HEAD_NODE] = nil
	self[OBSV_TAIL_NODE] = nil
	
	setmetatable(self, nil)
end

function Zappy:Observe(fn)
	local tail = self[OBSV_TAIL_NODE]
	local node = Observer.new(fn, tail)

	if tail then
		tail.next = node
		
		self[OBSV_TAIL_NODE] = node
	else
		self[OBSV_HEAD_NODE] = node
		self[OBSV_TAIL_NODE] = node
	end

	return node
end

function Zappy:Catch(key, fn)
	local node = Observer.new(fn)
	
	self.catchers[key] = node
	
	return node
end

function Zappy:Reduce(fn)
	local success, val = pcall(fn, self.state)
	
	if (not success) then
		warn("Couldn't set as reducer by reason of the following error ... ", val)	
		
		return	
	end
	
	self.reducer = fn
	self:Set(
		val, true)
	
	return self
end

function Zappy:Slice(start, terminate)
	local isTuple = self:isTuple()
	local isString = (self.const == "string")

	if (not isTuple) and isString then
		return self.state:sub(start, terminate)
	end

	assert(isTuple, "Attempt to slice a non-tuple")
	assert(start <= terminate and terminate <= #self.state, "Attempt to cross tuple boundaries with the start and terminate args!")
	
	local slice = {}

	for i = start or 1, terminate or #self.state do
		table.insert(slice, self.state[i])
	end

	return slice
end

function Zappy:Unpack()
	local isTuple = self:isTuple()
	local isString = (self.const == "string")
	
	if (not isTuple) and isString then
		return self.state:split("")
	end
	
	assert(isTuple, "Attempt to unpack an object that isn't a tuple or string")
	
	return unpack(self.state)
end

--@{ get }
function Zappy:Peek()
	return self.state
end

--@{ set }
function Zappy:Set(val, bypass)
	val = decompose(val) -- automatically decomposes the value

	local reducer = self.reducer

	if (not bypass) and reducer then
		local success, transformed = pcall(reducer, val)
		
		if (not success) then
			warn("Reducer encountered error ...", transformed)
			
			return
		end
		
		return self:Set(transformed, true)
	end

	if isEqual(self.state, val) then
		return self
	end
	
	local assigned = (self.const ~= "nil")
	local isMutated = (val~=nil) and assigned 
		and (self.const ~= getStateType(val))

	if isMutated then
		error("Cannot change state type of zap container!")
	else
		if not assigned then
			self.const = getStateType(val)
		end
	end
	
	self.state = val

	if self:_hasObservers() then
		self:_runWatcherThread(val)
	end

	return self
end

--@constructors

function Zappy.dep(super, fn)
	local self = Zappy.new()
	local setter = self:_getSetter(fn)

	super:Catch(self, setter)
	setter(super:Peek())

	return self
end

function Zappy.new(init)
	if Zappy.is(init) then
		local self = Zappy.new()

		init:Catch(self, self:_getSetter())

		return self
	end

	return setmetatable({
		state = init;
		const = getStateType(init);
		catchers = setmetatable({}, WEAK_KEYS);
		
		[OBSV_HEAD_NODE] = nil;
		[OBSV_TAIL_NODE] = nil;
	}, Zappy)
end

return Zappy
