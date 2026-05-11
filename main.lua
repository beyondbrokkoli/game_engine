local ffi = require("ffi")

-- Clean, simple C89 API. No compiler magic exposed.
ffi.cdef[[
    int vibe_get_is_running();
    int vibe_publish_and_get_next_buffer();
    void vibe_trigger_shutdown();
    void vibe_mark_lua_finished();
]]

print("[LUA VM] Entering Lock-Free Horizon.")

local active_coroutines = {}
local function start_coroutine(func) table.insert(active_coroutines, coroutine.create(func)) end

local current_write_idx = 2 -- Matches C initialization

-- The Workload
local function dummy_behavior()
    local i = 0
    while ffi.C.vibe_get_is_running() == 1 do
        i = i + 1

        -- Exchange buffers with C
        current_write_idx = ffi.C.vibe_publish_and_get_next_buffer()

        -- THE LUA TIME BOMB
        if i == 200 then
            print("\n[LUA CO] Reached 200 iterations! Triggering C-Side Teardown...")
            ffi.C.vibe_trigger_shutdown()
        end

        coroutine.yield()
    end
    print("[LUA CO] Engine Shutdown Detected. Coroutine Terminating.")
end

start_coroutine(dummy_behavior)

-- The Coroutine Dispatcher Loop
while ffi.C.vibe_get_is_running() == 1 do
    for i = #active_coroutines, 1, -1 do
        local co = active_coroutines[i]

        if coroutine.status(co) ~= "dead" then
            local success, err = coroutine.resume(co)
            assert(success, "FATAL: COROUTINE CRASHED: " .. tostring(err))
        else
            table.remove(active_coroutines, i)
        end
    end

    -- In a real engine, we might yield the OS thread briefly here,
    -- but for this test, we let it scream at max CPU speed.
end

print("[LUA VM] Exiting gracefully...")

-- THE SHAKEHAND FIX
-- Tell C we are completely done and it can safely join the thread.
ffi.C.vibe_mark_lua_finished()
