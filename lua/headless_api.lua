-- lua/headless_api.lua
-- A sterile, C-Core bypass for running Weaver Engine purely in LuaJIT.

local ffi = require("ffi")

-- 1. Essential OS & Timing Bedrock
ffi.cdef[[
// OS & Time (Required by net_utils & main)
void Sleep(uint32_t dwMilliseconds);
int usleep(uint32_t usec);
int QueryPerformanceCounter(int64_t *lpPerformanceCount);
int QueryPerformanceFrequency(int64_t *lpFrequency);
typedef struct { long tv_sec; long tv_nsec; } timespec;
int clock_gettime(int clk_id, timespec *tp);

// Math / Structs (Just in case a stray decoupled module references it)
typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;
]]

-- 2. Mock core_abi
-- FFI bindings will naturally resolve OS calls from the standard C library
package.loaded["core_abi"] = ffi.C

-- 3. Mock window_api
local WindowAPI = {}
-- Metatable magic: Any function called on WindowAPI returns a dummy function
-- that simply returns 0. This stops nil errors dead in their tracks.
setmetatable(WindowAPI, {
    __index = function(t, key)
        return function() return 0 end
    end
})
package.loaded["window_api"] = WindowAPI

-- 4. Mock engine_api
local EngineAPI = {}
function EngineAPI.is_running()
    return true
end
function EngineAPI.shutdown()
    print("[HEADLESS API] Engine shutdown signal received.")
    os.exit(0)
end
-- Catch-all for any other EngineAPI calls
setmetatable(EngineAPI, {
    __index = function(t, key)
        return function() return nil end
    end
})
package.loaded["engine_api"] = EngineAPI

print("[HEADLESS API] C-Core Bypassed. Mock Environment Locked.")

return true
