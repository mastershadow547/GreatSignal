-- Roblox Username: dragon33233 | Discord Username: biggiecheese13
--[=[ 
    GREATSIGNAL API
    
    STRUCTURE OVERVIEW:
    This system utilizes a Doubly Linked List to manage connections. 
    Unlike standard arrays where removing an index causes an expensive shift operation 
    a Doubly Linked List allows for instantaneous insertion and deletion. 
    It achieves this by updating the next and previous pointers of the adjacent nodes.
    
    COMPONENT INTERACTION:
    The Signal Object acts as the manager. It holds references to the Head and Tail connections.
    The Connection Object acts as a node within the list.
    Memory Management uses weak tables to prevent memory leaks when threads or external connections are collected by the garbage collector.
    
    SECURITY WARNINGS:
    1. CONTEXT ISOLATION: This cannot communicate across client to server or server to client.
    2. METATABLE HOOKING: On the Client define important functions as locals at the top of your script to prevent exploiter interception.
    3. SPOOFING: Never trust data fired from a Client side signal for important logic.
    4. SERVER SECURITY: Server side is secure from external memory tampering.
]=]

--!strict
local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

-- Defining types provides strict Luau type checking for better performance and predictability
type PackedArgs = { n: number, [number]: any }

-- The Connection type defines the structure of a single node in our linked list
export type Connection = {
	Connected: boolean,
	_signal: Signal?,
	_callback: ((...any) -> ())?,
	_next: Connection?,
	_prev: Connection?,
	_parallel: boolean,
	_traceback: string?,
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> ()
}

-- The Signal type defines the structure of the list manager
export type Signal = {
	_head: Connection?,
	_tail: Connection?,
	_count: number,
	_name: string,
	_isDestroyed: boolean,
	_debugMode: boolean,
	_proxyConns: {[RBXScriptConnection]: true},
	_waiters: {[thread]: true},
	Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
	ConnectParallel: (self: Signal, callback: (...any) -> ()) -> Connection,
	Once: (self: Signal, callback: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	FireImmediate: (self: Signal, ...any) -> (),
	FireDeferred: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	GetCount: (self: Signal) -> number,
	IsDestroyed: (self: Signal) -> boolean,
	DisconnectAll: (self: Signal) -> (),
	Proxy: (self: Signal, otherSignal: RBXScriptSignal) -> RBXScriptConnection,
	Destroy: (self: Signal) -> (),
	Diagnose: (self: Signal) -> ()
}

--[=[ 
    INTERNAL UTILITIES
    These functions encapsulate logic for executing callbacks safely across different task schedulers.
]=]

-- The packArgs function safely packages arguments including potential nil values to ensure data integrity
local function packArgs(...): PackedArgs
	return table.pack(...)
end

-- The runCallback function wraps the execution in a pcall to prevent yielding or erroring threads from breaking the signal chain
local function runCallback(cb: (...any) -> (), name: string, tb: string?, args: PackedArgs)
	local ok, err = pcall(function()
		cb(table.unpack(args, 1, args.n))
	end)

	if not ok then
		warn(string.format("Signal '%s' Error: %s\nTraceback: %s", name, tostring(err), tb or "N/A"))
	end
end

-- The runParallel function safely transitions the thread into a parallel execution context before running the callback
local function runParallel(cb: (...any) -> (), name: string, tb: string?, args: PackedArgs)
	local success = pcall(task.desynchronize)
	if not success then
		warn("There was a problem during function runParallel")
	end
	runCallback(cb, name, tb, args)
end

-- The weakSet function creates a table with weak keys
-- This ensures that if the keys are destroyed elsewhere they are automatically removed from this table
local function weakSet<T>(): {[T]: true}
	return (setmetatable({}, { __mode = "k" }) :: any)
end

--[=[ 
    CONNECTION LOGIC
    This section handles the node state and pointer reassignment during the connection lifecycle.
]=]

-- Creates a new node and initializes its pointers to nil
function Connection.new(signal: Signal, callback: (...any)->(), parallel: boolean?): Connection
	local self = (setmetatable({
		Connected = true,
		_signal = signal,
		_callback = callback,
		_next = nil,
		_prev = nil,
		_parallel = parallel or false,
		_traceback = if signal._debugMode then debug.traceback(nil, 3) else nil
	}, Connection) :: any)

	return self :: Connection
end

-- Disconnect severs the connection from the linked list
function Connection:Disconnect()
	local self = self :: Connection
	if not self.Connected then return end

	local signal = self._signal
	if not signal then return end

	self.Connected = false
	signal._count -= 1

	-- Cache the adjacent nodes to update their pointers
	local nextNode = self._next
	local prevNode = self._prev

	-- If a previous node exists we link it directly to the next node
	if prevNode then
		prevNode._next = nextNode
	else
		-- If no previous node exists this must be the head node so we update the signal manager
		signal._head = nextNode
	end

	-- If a next node exists we link it directly to the previous node
	if nextNode then
		nextNode._prev = prevNode
	else
		-- If no next node exists this must be the tail node so we update the signal manager
		signal._tail = prevNode
	end

	-- Clear internal references to allow the garbage collector to free memory
	self._signal = nil
	self._callback = nil
	self._next = nil
	self._prev = nil
end

-- Destroy acts as an alias for Disconnect to maintain naming consistency with the Roblox API
function Connection:Destroy()
	(self :: Connection):Disconnect()
end

--[=[ 
    SIGNAL LOGIC
    This section represents the primary interface for creating and firing event streams.
]=]

-- Instantiates a new signal manager and sets up the internal weak tables
function Signal.new(name: string?, debugMode: boolean?): Signal
	local self = (setmetatable({
		_head = nil,
		_tail = nil,
		_count = 0,
		_name = name or "Signal",
		_isDestroyed = false,
		_debugMode = debugMode or false,
		_proxyConns = weakSet(),
		_waiters = weakSet()
	}, Signal) :: any)

	return self :: Signal
end

-- Connect creates a new node and appends it to the end of the linked list
function Signal:Connect(cb: (...any) -> ()): Connection
	local self = self :: Signal
	assert(not self._isDestroyed, "Signal destroyed")
	local conn = Connection.new(self, cb, false)

	-- If a tail already exists we link the new node to it and set the new node as the tail
	if self._tail then
		self._tail._next = conn
		conn._prev = self._tail
		self._tail = conn
	else
		-- If the list is empty we set the new node as both the head and the tail
		self._head = conn
		self._tail = conn
	end

	self._count += 1
	return conn :: any
end

-- ConnectParallel flags the node to be executed in a parallel context when fired
function Signal:ConnectParallel(cb: (...any) -> ()): Connection
	local self = self :: Signal
	assert(not self._isDestroyed, "Signal destroyed")
	local conn = Connection.new(self, cb, true)

	if self._tail then
		self._tail._next = conn
		conn._prev = self._tail
		self._tail = conn
	else
		self._head = conn
		self._tail = conn
	end

	self._count += 1
	return conn :: any
end

-- Fire spawns a new thread for each connection to prevent one failing callback from halting the entire loop
function Signal:Fire(...)
	local self = self :: Signal
	if self._isDestroyed then return end
	local args = packArgs(...)
	local current = self._head

	-- We iterate through the list until we hit a nil pointer
	while current do
		-- We cache the next node immediately in case the current node is disconnected during its callback
		local nextNode = current._next
		
		if current.Connected and current._callback then
			if current._parallel then
				task.spawn(runParallel, current._callback, self._name, current._traceback, args)
			else
				task.spawn(runCallback, current._callback, self._name, current._traceback, args)
			end
		end
		current = nextNode
	end
end

-- FireImmediate runs synchronously on the current thread
-- This method blocks the current thread until all callbacks finish executing
function Signal:FireImmediate(...)
	local self = self :: Signal
	if self._isDestroyed then return end
	local args = packArgs(...)
	local current = self._head

	while current do
		local nextNode = current._next
		if current.Connected and current._callback then
			runCallback(current._callback, self._name, current._traceback, args)
		end
		current = nextNode
	end
end

-- FireDeferred schedules the callbacks to run at the end of the current resume cycle
-- This is useful for avoiding immediate thread blocking while still guaranteeing execution
function Signal:FireDeferred(...)
	local self = self :: Signal
	if self._isDestroyed then return end
	local args = packArgs(...)
	local current = self._head

	while current do
		local nextNode = current._next
		if current.Connected and current._callback then
			task.defer(runCallback, current._callback, self._name, current._traceback, args)
		end
		current = nextNode
	end
end

-- GetCount retrieves the current number of active connections in the linked list
function Signal:GetCount(): number
	return (self :: Signal)._count
end

-- IsDestroyed returns a boolean indicating whether the signal manager has been permanently disabled
function Signal:IsDestroyed(): boolean
	return (self :: Signal)._isDestroyed
end

-- DisconnectAll severs every connection in the list without destroying the signal itself
function Signal:DisconnectAll()
	local self = self :: Signal
	local current = self._head
	
	while current do
		local nextNode = current._next
		current:Disconnect()
		current = nextNode
	end
end

-- Once creates a connection that automatically disconnects itself the first time it is fired
function Signal:Once(callback: (...any) -> ()): Connection
	local self = self :: Signal
	local conn: Connection
	
	conn = self:Connect(function(...)
		if conn.Connected then 
			conn:Disconnect() 
		end
		callback(...)
	end)
	
	return conn
end

-- Wait yields the current thread until the signal is fired returning the arguments passed to the signal
function Signal:Wait(): ...any
	local self = self :: Signal
	local thread = coroutine.running()
	self._waiters[thread] = true

	local conn: Connection
	
	-- We create a temporary connection that resumes the yielded thread and immediately disconnects itself
	conn = self:Connect(function(...)
		if self._waiters[thread] then
			self._waiters[thread] = nil
			conn:Disconnect()
			coroutine.resume(thread, ...) 
		end
	end)

	return coroutine.yield()
end

-- Proxy wraps a native Roblox event like Part.Touched into this custom signal system
function Signal:Proxy(otherSignal: RBXScriptSignal): RBXScriptConnection
	local self = self :: Signal
	local conn = (otherSignal:Connect(function(...)
		self:Fire(...)
	end) :: RBXScriptConnection)
	
	-- We store the native connection in our weak table to clean it up when the signal is destroyed
	self._proxyConns[conn] = true
	return conn
end

-- Destroy permanently disables the signal and cleans up all memory references
function Signal:Destroy()
	local self = self :: Signal
	if self._isDestroyed then return end
	self._isDestroyed = true

	self:DisconnectAll()

	-- We clean up any native proxied connections
	for c in pairs(self._proxyConns) do
		c:Disconnect()
	end

	-- We resume any threads that were perpetually waiting for this signal to fire
	for t in pairs(self._waiters) do
		task.spawn(t)
	end

	self._head = nil
	self._tail = nil
	self._count = 0
end

--[=[ 
    DIAGNOSTIC SYSTEM
    This function verifies the integrity of the signal system by running an automated test suite.
    It checks for proper firing disconnection and proxying behavior.
]=]
function Signal:Diagnose()
	local RunService = game:GetService("RunService")
	
	-- We restrict diagnostics to the server side to maintain security and prevent client spam
	if not RunService:IsServer() then
		warn("[Signal Diagnosis] Access Denied: Diagnose can only be called from a Server Script.")
		return
	end

	local self = self :: Signal

	print("\n--- [SIGNAL SYSTEM DIAGNOSIS] ---")
	print(string.format("Signal Name: %s", self._name))
	print(string.format("Current Connections: %d", self._count))
	print(string.format("Is Destroyed: %s", tostring(self._isDestroyed)))
	print(string.format("Debug Mode: %s", tostring(self._debugMode)))

	local testsPassed = 0
	local totalTests = 5

	-- Test 1 evaluates if immediate firing properly executes the connected callback synchronously
	local immediateCheck: any = false
	local conn = self:Connect(function(val: any)
		immediateCheck = val
	end)

	self:FireImmediate(true)

	if immediateCheck == true then 
		print("✅ [1/5] FireImmediate: Success") 
		testsPassed += 1
	end
	conn:Disconnect()

	-- Test 2 ensures the Once method automatically unlinks itself after a single execution
	local onceCount = 0
	self:Once(function()
		onceCount += 1
	end)
	
	self:FireImmediate(nil)
	self:FireImmediate(nil)

	if onceCount == 1 then
		print("✅ [2/5] Once: Success (Fired exactly once)")
		testsPassed += 1
	else
		warn("❌ [2/5] Once: Failed")
	end

	-- Test 3 verifies that disconnecting a node prevents it from receiving future events
	local disconnectCheck = true
	local conn2 = self:Connect(function()
		disconnectCheck = false
	end)
	
	conn2:Disconnect()
	self:FireImmediate(nil)

	if disconnectCheck then
		print("✅ [3/5] Disconnect: Success (Link severed)")
		testsPassed += 1
	else
		warn("❌ [3/5] Disconnect: Failed")
	end

	-- Test 4 evaluates the yielding functionality of the Wait method
	local waitSuccess = false
	task.spawn(function()
		local val: any = self:Wait()
		if typeof(val) == "string" and val == "WaitTest" then
			waitSuccess = true
		end
	end)
	
	task.wait(0.1) 
	self:FireImmediate("WaitTest")

	if waitSuccess then
		print("✅ [4/5] Wait: Success")
		testsPassed += 1
	else
		warn("❌ [4/5] Wait: Failed")
	end

	-- Test 5 ensures that a standard Roblox BindableEvent can be successfully proxied into the custom system
	local proxySuccess = false
	local bindable = Instance.new("BindableEvent")
	self:Proxy(bindable.Event)

	local conn3 = self:Connect(function(val: any)
		if typeof(val) == "string" and val == "ProxyTest" then 
			proxySuccess = true 
		end
	end)

	bindable:Fire("ProxyTest")

	task.defer(function()
		if proxySuccess then
			print("✅ [5/5] Proxy: Success")
			testsPassed += 1
		else
			warn("❌ [5/5] Proxy: Failed")
		end

		conn3:Disconnect()
		bindable:Destroy()

		print(string.format("--- DIAGNOSIS COMPLETE: %d/%d PASSED ---\n", testsPassed, totalTests))
	end)
end

return Signal
