--[[
	@@ Zappy
	
	Simple and robust reactive state container
	
	~ Reflinders
]]

--[[
	Version => 0.1
]]

local OBSV_HEAD_NODE = "obsvnode"
local TEMP_KEYS = { __mode = "k" }

local freeThread

function runThread(fn, ...)
	local temp = freeThread
	freeThread = nil
	fn(...)
	freeThread = temp
end

function threadYielder(observers)
	while true do
		runThread(coroutine.yield())
	end 
end

function spawnThread(fn, ...)
	if not freeThread then
		freeThread = coroutine.create(threadYielder)
		coroutine.resume(freeThread)
	end

	task.spawn(freeThread, fn, ...)	
end

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

function hasObservers(obj)
	local _, catch = next(obj.catchers)
	
	return obj[OBSV_HEAD_NODE] ~= nil
		or catch ~= nil
end

--[[
	@
	@
	@
]]

--@ Class `Observer`

local Observer = {}
do
	Observer.__index = Observer

	function Observer:unsubscribe()
		if not self.active then
			return
		end

		if self.prev then
			self.prev.next = self.next
			self.prev = nil
		end

		self.next = nil
		self.fn = nil
	end

	function Observer.new(fn, prev)
		return setmetatable({ 
			fn = fn;
			prev = prev;
			--@
			--@ next = nil;
		}, Observer)
	end
end

--@ Class `Zappy`

local Zappy = {}
Zappy.__index = Zappy

function Zappy:Destroy()
	table.clear(self)
	setmetatable(self, nil)
end

function Zappy.is(obj)
	return type(obj) == "table" 
		and getmetatable(obj) == Zappy
end

function Zappy.isTuple(obj)
	return isTuple(obj.state)
end

function Zappy.observe(zap_state, fn)
	local head = zap_state[OBSV_HEAD_NODE]
	local node = Observer.new(fn, head)
	
	if head then
		head.next = node
	else
		zap_state[OBSV_HEAD_NODE] = node
	end
	
	return node
end

function Zappy.catch(zap_state, key, fn)
	local node = Observer.new(fn)
	zap_state.catchers[key] = node
	return node
end

function Zappy.reduce(zap_state, fn)
	zap_state.reducer = fn
	zap_state:set(
		fn(zap_state.state), true)
end

function Zappy.getSetter(zap_state, fn)
	--@ mainly used for observers
	-- arg passed into observer is the literal
	-- so no need to decompose!
	
	if fn then
		return function(val)
			val = fn(val)
			
			zap_state:set(val)
		end
	end
	
	return function(val)
		zap_state:set(val)
	end
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

	while node do
		spawnThread(node.fn, state)

		node = node.next
	end
end

function Zappy:slice(start, terminate)
	local isString = (type(self.state) == "string")
	
	if isString then
		return self.state:sub(start, terminate)
	end
	
	assert(self:isTuple(), "Attempt to slice a non-tuple")

	local slice = {}

	for i = start or 1, terminate or #self.state do
		table.insert(slice, self.state[i])
	end

	return slice
end

function Zappy:unpack()
	assert(self:isTuple(), "Attempt to slice a non-tuple")

	return unpack(self.state)
end

--@ get
function Zappy:peek()
	return self.state
end

--@ set
function Zappy:set(val, bypass)
	val = decompose(val) -- automatically decomposes the value
	
	local reducer = self.reducer
	
	if (not bypass) and reducer then
		return self:set(reducer(val), true)
	end
	
	if isEqual(self.state, val) then
		return self
	end
	
	local is_mutated = (self.const ~= "nil") and (self.const ~= getStateType(val))
	
	if is_mutated then
		error("Cannot change state type of zap container!")
	end
	
	self.const = getStateType(val)
	self.state = val
	
	if hasObservers(self) then
		self:_runWatcherThread(val)
	end
	
	return self
end

--@ Constructors

function Zappy.dep(to_dep, fn)
	local self = Zappy.new()
	local setter = Zappy.getSetter(self, fn)
	
	to_dep:catch(self, setter)
	setter(to_dep:peek())
	
	return self
end

function Zappy.new(init)
	if Zappy.is(init) then
		local self = Zappy.new()
		
		init:catch(self, Zappy.getSetter(self))
		
		return self
	end
	
	return setmetatable({
		state = init;
		const = getStateType(init);
		catchers = setmetatable({}, TEMP_KEYS);
	}, Zappy)
end

return Zappy
