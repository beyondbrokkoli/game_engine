package.path = "./lua/?.lua;" .. package.path
local ffi = require("ffi")
local json_util = require("json_util")
-- 1. BOOTSTRAP SSOT MEMORY LAYOUTS FIRST
-- This registers RenderPacket, PushConstants, and RollbackBuffer into the FFI
-- so that the C-function declarations below don't crash on unknown types.
local structs = require("structs")
local reg_vk  = require("registry_vk")

-- 2. STANDARD MODULES
local math = require("math")
local bit = require("bit")
local vmath = require("vmath")
local seq = require("sequence")
local cfg = require("config_engine")
local manifest = require("pipeline_manifest")
local arena_mgr = require("arena_manager")
local render_queue = require("render_queue")

-- 3. C-CORE INTERFACES
ffi.cdef[[
    void* vx_sys_get_surface();
    void vx_sys_set_cmd(int cmd, int w, int h);
    void Sleep(uint32_t dwMilliseconds);
    int usleep(uint32_t usec);
    int vx_core_is_running();
    void vx_core_shutdown();
    void vx_core_mark_finished();

    int QueryPerformanceCounter(int64_t *lpPerformanceCount);
    int QueryPerformanceFrequency(int64_t *lpFrequency);
    typedef struct { long tv_sec; long tv_nsec; } timespec;
    int clock_gettime(int clk_id, timespec *tp);

    int vx_input_last_key();
    uint32_t vx_input_wasd();
    float vx_input_mouse_dx();
    float vx_input_mouse_dy();
    float vx_input_mouse_x();
    float vx_input_mouse_y();
    float vx_input_click_x();
    float vx_input_click_y();
    int vx_input_is_captured();
    int vx_sys_resize_flag();
    void vx_sys_window_size(int* w, int* h);
    int vx_input_mouse_btn(int btn);
    int vx_input_spacebar();

    int vx_stream_acquire();
    RenderPacket* vx_stream_packet(int idx);
    void vx_stream_commit(int idx);
    void vx_thread_kill();

    typedef struct __attribute__((aligned(16))) { float x, y, z, w; } vec4_t;
]]

local function sys_sleep(ms)
    if jit.os == "Windows" then ffi.C.Sleep(ms) else ffi.C.usleep(ms * 1000) end
end

local get_time_hires
if jit.os == "Windows" then
    local kernel32 = ffi.load("kernel32")
    local freq = ffi.new("int64_t[1]")
    kernel32.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        kernel32.QueryPerformanceCounter(count)
        return tonumber(count[0]) * inv_freq
    end
else
    local CLOCK_MONOTONIC = 1
    get_time_hires = function()
        local ts = ffi.new("timespec")
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) + (tonumber(ts.tv_nsec) * 1e-9)
    end
end

local function boot_weaver()
    local ctx = {}
    for i, stage in ipairs(seq.boot) do
        print(string.format("[WEAVER] Executing Stage %d: %s", i, stage.name))
        local signal = stage.action(ctx)
        if signal == "AWAIT_SURFACE" then
            print("[WEAVER] Yielding execution, waiting for C-Core Surface...")
            while ffi.C.vx_sys_get_surface() == nil do
                sys_sleep(10)
                coroutine.yield()
            end
        end
    end
    return ctx
end

local temp_vec_near = ffi.new("vec4_t")
local temp_vec_far = ffi.new("vec4_t")
local function matrix_raycast_terrain(mouse_x, mouse_y, screen_w, screen_h, viewProj_inv, grid)
    local nx = (mouse_x / screen_w) * 2.0 - 1.0
    local ny = (mouse_y / screen_h) * 2.0 - 1.0

    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 0.0, 1.0, temp_vec_near)
    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 1.0, 1.0, temp_vec_far)

    local near_w = 1.0 / temp_vec_near.w
    local ox, oy, oz = temp_vec_near.x * near_w, temp_vec_near.y * near_w, temp_vec_near.z * near_w

    local far_w = 1.0 / temp_vec_far.w
    local fx, fy, fz = temp_vec_far.x * far_w, temp_vec_far.y * far_w, temp_vec_far.z * far_w

    local dx, dy, dz = fx - ox, fy - oy, fz - oz
    local inv_mag = 1.0 / math.sqrt(dx^2 + dy^2 + dz^2)
    dx, dy, dz = dx * inv_mag, dy * inv_mag, dz * inv_mag

    local t = 0.0

    -- [THE FAST-FORWARD MANEUVER]
    -- Warp the ray past the 10,000 units of empty Orthographic space
    -- directly to an elevation of 10.0 (just above your terrain).
    if dy < 0.0 then
        local dist_to_ceiling = (10.0 - oy) / dy
        if dist_to_ceiling > 0.0 then
            t = dist_to_ceiling
        end
    end

    -- Because we warped to the surface, we only need 100 iterations
    -- and we can use a much tighter step size for pinpoint accuracy.
    for i = 1, 100 do
        local px = ox + dx * t
        local py = oy + dy * t
        local pz = oz + dz * t

        local grid_x = math.floor((px + cfg.world.offset_x) / cfg.world.spacing + 0.5)
        local grid_z = math.floor((pz + cfg.world.offset_z) / cfg.world.spacing + 0.5)

        if grid_x >= 0 and grid_x < cfg.world.map_width and grid_z >= 0 and grid_z < cfg.world.map_height then
            local idx = grid_z * cfg.world.map_width + grid_x

            -- Add a tiny vertical padding (0.1) to ensure the click hits the top surface
            if py <= grid.elevation[idx] + 0.1 then
                return idx
            end
        end
        t = t + (cfg.world.spacing * 0.1) -- Step tightly (2.0 units per check)
    end

    return -1
end

local function http_post(url, json_payload)
    -- 1. Write the payload to a temporary file to bypass Windows/Linux quote parsing
    local payload_path = "matchmaker_payload.json"
    local f = assert(io.open(payload_path, "w"), "Failed to open temporary payload file")
    f:write(json_payload)
    f:close()

    -- 2. Use double quotes for headers, and the @ syntax to tell curl to read the file
    local cmd = string.format('curl -s -X POST -H "Content-Type: application/json" -d "@%s" %s', payload_path, url)
    local pf = io.popen(cmd)
    local res = pf:read("*a")
    pf:close()

    -- 3. Clean up the temp file
    os.remove(payload_path)

    -- 4. The Smoking Gun Logger: If it fails again, print exactly what FastAPI is complaining about
    if not res:match("session_token") then
        print("\n[DEBUG] API REJECTED PAYLOAD! RAW SERVER RESPONSE:")
        print(res .. "\n")
    end

    return res
end

local function http_get(url)
    -- Wrap the URL in double quotes to protect it from Windows cmd.exe parsing rules.
    -- This shields any unexpected characters from breaking the terminal execution.
    local cmd = string.format('curl -s "%s"', url)

    local f = io.popen(cmd)
    if not f then return "" end

    local res = f:read("*a")
    f:close()

    -- The Smoking Gun Logger (GET Edition)
    -- If FastAPI throws a 404 or 422, it usually packs it inside a "detail" JSON key.
    if res:match('"detail"') then
        print("\n[DEBUG] API GET REJECTED! RAW SERVER RESPONSE:")
        print("Target URL: " .. url)
        print("Response: " .. res .. "\n")
    end

    return res
end

-- Robust, Language-Agnostic Local IP Discovery
local function get_local_ip()
    local cmd = ""
    if jit.os == "Windows" then
        -- Grab the first active IPv4 address that is not loopback or a wild card
        cmd = 'powershell -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike \'127.*\' -and $_.IPAddress -notlike \'169.254.*\' } | Select-Object -First 1).IPAddress"'
    else
        -- Linux standard route discovery
        cmd = "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"src\") print $(i+1)}'"
    end

    local f = io.popen(cmd)
    if not f then return "127.0.0.1" end

    local res = f:read("*a")
    f:close()

    -- Strip whitespaces, newlines, and carriage returns
    res = res:gsub("%s+", "")

    -- Validation fallback: If it's not a clean IPv4, default to loopback
    if not res:match("^%d+%.%d+%.%d+%.%d+$") then
        return "127.0.0.1"
    end

    return res
end

local function main()
    local VPS_IP = "138.199.152.240" -- Hetzner VPS
    local MATCHMAKER_URL = "http://" .. VPS_IP -- .. ":8080"

    -- Inside your Host/Join matchmaker logic in main.lua:
    local RELAY_IP = "138.199.152.240" -- Hetzner IP
    local RELAY_PORT = 49152
    local connection_timeout = 180 -- ~3 seconds at 60Hz
    -- Put this near the top of main(), before the user inputs 1 or 2
    _G.ice_fuse = -1

    print("========================================")
    print(" WEAVER ENGINE: HYBRID WAN/LAN PLAY     ")
    print("========================================")
    print("1. Host Public Lobby")
    print("2. Join Public Lobby")
    io.write("> ")
    local user_input = io.read("*l")

    local net = require("network")

    -- 1. Bind to a random local ephemeral port to avoid conflicts
    math.randomseed(os.time())
    local local_port = math.random(49152, 65535)
    assert(net.Host(local_port), "FATAL: Failed to bind local network port!")

    -- 2. Pre-Flight: Execute STUN & Local IP Discovery
    print("[STUN] Querying Coturn for NAT translation...")
    -- (Ensure Network.StunPunch is restored in network.lua and vx_net.c)
    local pub_ip, pub_port = net.StunPunch(VPS_IP, 3478)
    assert(pub_ip, "FATAL: STUN Hole Punch failed! Check router or firewall.")

    local my_local_ip = get_local_ip()
    print(string.format("[NETWORK] Local LAN: %s:%d | WAN: %s:%d", my_local_ip, local_port, pub_ip, pub_port))

    local target_ip, target_port
    -- [UPDATED] Payload now includes local_port to match your new Python server!
    local payload = string.format('{"public_ip":"%s","public_port":%d,"local_ip":"%s","local_port":%d}',
                                  pub_ip, pub_port, my_local_ip, local_port)

    -- 3. Execute Matchmaking Handshake
    if user_input == "1" then
        local res = http_post(MATCHMAKER_URL .. "/host", payload)
        local data = json_util.decode(res)
        local lobby_id = data.lobby_id
        assert(lobby_id, "FATAL: Server response did not contain a 'lobby_id'!")

        -- [NEW SECURITY] Extract and Lock Session Token
        local runtime_token = tonumber(data.session_token) or 0
        net.SetSession(runtime_token)

        print(string.format("[LOBBY] Session Hosted! Invite Code: [%s]", lobby_id))
        print(string.format("[SECURITY] Session Token Locked: %016X", runtime_token))
        print("[LOBBY] Booting engine immediately. Map will render smoothly while waiting...")

        -- The Keep-Alive Blind Pivot
        target_ip = VPS_IP
        target_port = 3478

        -- [QoL UPGRADE] Non-Blocking Background Polling Coroutine
        local host_poll_co = coroutine.create(function()
            local last_poll_time = 0
            while true do
                local current_time = get_time_hires()

                -- Only hit the API once per second, without freezing the thread
                if (current_time - last_poll_time) >= 1.0 then
                    last_poll_time = current_time
                    local s_res = http_get(MATCHMAKER_URL .. "/status/" .. lobby_id)
                    local success, s_data = pcall(json_util.decode, s_res)

                    if success and s_data.status == "ready" then
                        local guest_pub_ip = s_data.opponent_ip
                        local guest_local_ip = s_data.opponent_local_ip
                        local guest_port = tonumber(s_data.opponent_port)
                        local guest_local_port = tonumber(s_data.opponent_local_port)

                        -- [QoL UPGRADE] The 3-Tier Routing Protocol
                        if guest_pub_ip == pub_ip then
                            if guest_local_ip == my_local_ip then
                                print("\n[ICE] Same-machine detected! Bypassing NIC entirely...")
                                net.Connect("127.0.0.1", guest_local_port)
                            else
                                print("\n[ICE] LAN Hairpin detected! Hot-swapping crosshairs to local network...")
                                net.Connect(guest_local_ip, guest_local_port)
                            end
                        else
                            print("\n[MATCHMAKER] Guest joined via WAN! Locking crosshairs...")
                            net.Connect(guest_pub_ip, guest_port)
                        end

                        -- 🚨 THE GUEST HAS ARRIVED. LIGHT THE 3-SECOND FUSE!
                        _G.ice_fuse = 480
                        break
                    end
                end

                -- Yield immediately so the render loop hits maximum FPS
                coroutine.yield()
            end
        end)

        _G.MatchmakerPoller = host_poll_co

    else
        print("Enter Lobby Code:")
        io.write("> ")
        local code = io.read("*l"):upper()

        local res = http_post(MATCHMAKER_URL .. "/join/" .. code, payload)
        local data = json_util.decode(res)

        target_ip = data.opponent_ip
        target_port = tonumber(data.opponent_port)
        assert(target_ip, "FATAL: Lobby not found or full!")

        -- [NEW SECURITY] Extract and Lock Session Token
        local runtime_token = tonumber(data.session_token) or 0
        net.SetSession(runtime_token)
        print(string.format("[SECURITY] Session Token Locked: %016X", runtime_token))

        -- [QoL UPGRADE] The 3-Tier Routing Protocol (Joiner Side)
        if target_ip == pub_ip then
            if data.opponent_local_ip == my_local_ip then
                print("\n[ICE] Same-machine detected! Bypassing NIC entirely...")
                target_ip = "127.0.0.1"
                target_port = tonumber(data.opponent_local_port)
            else
                print("\n[ICE] LAN Hairpin detected! Bypassing external router...")
                target_ip = data.opponent_local_ip
                target_port = tonumber(data.opponent_local_port)
            end
        end

        print(string.format("\n[MATCHMAKER] Crosshairs setting to %s:%d", target_ip, target_port))
        assert(net.Connect(target_ip, target_port), "FATAL: Failed to set remote target!")

        -- 🚨 TARGET ACQUIRED. LIGHT THE 3-SECOND FUSE!
        _G.ice_fuse = 480
    end

    print("[LUA IO] Booting Headless Weaver (LABORATORY)...")
    local co = coroutine.create(boot_weaver)

    local status, engine_ctx
    while coroutine.status(co) ~= "dead" do
        status, engine_ctx = coroutine.resume(co)
        if not status then error("Fatal Weaver Crash: " .. tostring(engine_ctx)) end
    end

    print("[LUA IO] Weaver sequence complete! Unpacking Context...")

    local vk_rt = engine_ctx.vk_runtime
    local sc = engine_ctx.sc_state
    local desc = engine_ctx.desc_state
    local gfx = engine_ctx.gfx_state
    local sync = engine_ctx.sync_state
    local memory = require("memory")

    print("[LUA CO] Forging Data-Driven Pizza World Tilemap...")

    local total_tiles = cfg.world.map_width * cfg.world.map_height
    memory.AllocateSoA("uint16_t", total_tiles, {"terrain_id", "elevation", "entity_id"})

    local rts_grid = {
        terrain = memory.AVX_Arrays["terrain_id"],
        elevation = memory.AVX_Arrays["elevation"],
        entity = memory.AVX_Arrays["entity_id"]
    }

    local cx, cz = math.floor(cfg.world.map_width  / 2), math.floor(cfg.world.map_height  / 2)

    for z = 0, cfg.world.map_height - 1 do
        for x = 0, cfg.world.map_width  - 1 do
            local idx = z * cfg.world.map_width  + x
            rts_grid.elevation[idx] = 0.0
            rts_grid.terrain[idx] = 0 -- Grass Canvas
        end
    end

    -- Paint the Crosshair
    rts_grid.terrain[cz * cfg.world.map_width  + cx] = 10 -- CENTER (White)
    for x = cx + 1, cx + 5 do rts_grid.terrain[cz * cfg.world.map_width  + x] = 11 end -- X-Axis (Red)
    for z = cz + 1, cz + 5 do rts_grid.terrain[z * cfg.world.map_width  + cx] = 12 end -- Z-Axis (Blue)

    -- Paint the Bounding Box Corners
    rts_grid.terrain[(cz - 5) * cfg.world.map_width  + (cx - 5)] = 13 -- Top Left (Magenta)
    rts_grid.terrain[(cz - 5) * cfg.world.map_width  + (cx + 5)] = 13 -- Top Right (Magenta)
    rts_grid.terrain[(cz + 5) * cfg.world.map_width  + (cx - 5)] = 13 -- Bottom Left (Magenta)
    rts_grid.terrain[(cz + 5) * cfg.world.map_width  + (cx + 5)] = 13 -- Bottom Right (Magenta)

    print("[LUA CO] Initializing VRAM Index Buffer with Strict Topology...")
    local index_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])

    local iso_indices = ffi.new("uint32_t[36]", {
        0, 2, 3,
        0, 3, 4,
        0, 4, 5,
        0, 5, 2,
        2, 6, 7,
        2, 7, 3,
        3, 7, 11,
        3, 11, 4,
        4, 11, 10,
        4, 10, 5,
        5, 10, 6,
        5, 6, 2
    })

    ffi.copy(index_ptr, iso_indices, 36 * 4)

    local render_queues = arena_mgr.AllocateRenderQueues()

    local frame_count = 0
    local vmath = require("vmath")

    local pc = ffi.new("PushConstants")
    pc.aos_current_idx, pc.aos_prev_idx = 0, 0
    pc.dt = 0.0

    -- [ATTACK VECTOR 3] INITIALIZE GENERALIZED CAMERA
    local camera_mod = require("camera")
    local cam = camera_mod.new()
    local inv_vp = ffi.new("mat4_t")

    local total_time = 0.0
    local wants_hotswap = false

    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local active_render_mode = cfg.mode.dual

    local is_resizing = false
    local last_resize_time = get_time_hires()
    local RESIZE_COOLDOWN = 0.25

    local last_time = get_time_hires()
    local accumulator = 0.0
    local TICK_RATE = 60
    local FIXED_DT = 1.0 / TICK_RATE
    local sim_tick_count = 0

    print("[LUA CO] Packing Data-Driven Color Palette...")
    local staging_ptr = ffi.cast("float*", memory.Mapped["PALETTE_STAGING"])

    -- Default/Player Colors
    staging_ptr[0] = 0.2; staging_ptr[1] = 0.8; staging_ptr[2] = 0.2; staging_ptr[3] = 1.0
    staging_ptr[4] = 0.2; staging_ptr[5] = 0.5; staging_ptr[6] = 1.0; staging_ptr[7] = 1.0
    staging_ptr[8] = 1.0; staging_ptr[9] = 0.2; staging_ptr[10] = 0.2; staging_ptr[11] = 1.0

    -- Calibration Colors (Offsets: ID * 4)
    staging_ptr[40] = 1.0; staging_ptr[41] = 1.0; staging_ptr[42] = 1.0; staging_ptr[43] = 1.0 -- 10: White (Center)
    staging_ptr[44] = 1.0; staging_ptr[45] = 0.0; staging_ptr[46] = 0.0; staging_ptr[47] = 1.0 -- 11: Red (+X)
    staging_ptr[48] = 0.0; staging_ptr[49] = 0.0; staging_ptr[50] = 1.0; staging_ptr[51] = 1.0 -- 12: Blue (+Z)
    staging_ptr[52] = 1.0; staging_ptr[53] = 0.0; staging_ptr[54] = 1.0; staging_ptr[55] = 1.0 -- 13: Magenta (Corners)

    local palette_job_id = memory.TransferAsync("PALETTE_STAGING", "PALETTE_HAVEN", 16384)
    local palette_ready = false

    print("[LUA CO] Entering Deterministic Rollback Render Loop...")

    local rollback_arena = net.GetArena()
    local bytes_per_layer = total_tiles * ffi.sizeof("uint16_t")

    local snapshot_ring = {
        terrain = ffi.new("uint16_t[128][" .. total_tiles .. "]"),
        elevation = ffi.new("uint16_t[128][" .. total_tiles .. "]")
    }

    local function update_simulation(grid, tick, frame_data)
        -- Evaluate Local Click
        if frame_data.local_click ~= -1 then
            print(string.format("[LUA] Tick %d | Local Toggle -> %d", tick, frame_data.local_click))
            local c_idx = frame_data.local_click
            if grid.terrain[c_idx] == 0 then
                grid.terrain[c_idx] = 1 -- ID 1 for Host/Local
                grid.elevation[c_idx] = 15.0 -- [FIXED] Visible Elevation
            else
                grid.terrain[c_idx] = 0
                grid.elevation[c_idx] = 0.0
            end
        end

        -- Evaluate Remote Click
        if frame_data.remote_click ~= -1 then
            print(string.format("[LUA] Tick %d | Remote Toggle -> %d", tick, frame_data.remote_click))
            local c_idx = frame_data.remote_click
            if grid.terrain[c_idx] == 0 then
                grid.terrain[c_idx] = 2 -- ID 2 for Client/Remote
                grid.elevation[c_idx] = 15.0 -- [FIXED] Visible Elevation
            else
                grid.terrain[c_idx] = 0
                grid.elevation[c_idx] = 0.0
            end
        end
    end

    local prev_mouse_left = 0
    local pending_click = -1

    -- [ATTACK VECTOR 1] PRE-COMPUTED VRAM TEMPLATE
    print("[LUA CO] Pre-computing Universal Geometry Template...")
    local vram_template = ffi.new("RtsTileInstance[?]", total_tiles)
    for z = 0, cfg.world.map_height - 1 do
        for x = 0, cfg.world.map_width - 1 do
            local i = z * cfg.world.map_width + x
            vram_template[i].px = (x * cfg.world.spacing) - cfg.world.offset_x
            vram_template[i].pz = (z * cfg.world.spacing) - cfg.world.offset_z
        end
    end

    -- [NEW] Define the lock state, but DO NOT freeze the thread
    local network_locked = false
    sim_tick_count = 1

    local gfx_pipeline_module = require("graphics_pipeline")
    local pump_deletion_queue = gfx_pipeline_module.PumpDeletionQueue

    print("[NET] Scene loaded. Camera unlocked. Awaiting Timeline Synchronization...")

    -- We must initialize the clocks out here so the camera has a delta-time immediately
    local last_time = get_time_hires()
    local accumulator = 0.0

    while ffi.C.vx_core_is_running() == 1 do

        if _G.MatchmakerPoller and coroutine.status(_G.MatchmakerPoller) ~= "dead" then
            coroutine.resume(_G.MatchmakerPoller)
        end

        if ffi.C.vx_sys_resize_flag() == 1 then
            is_resizing = true
            last_resize_time = get_time_hires()
        end

        if is_resizing then
            if (get_time_hires() - last_resize_time) > RESIZE_COOLDOWN then
                local new_w, new_h = ffi.new("int[1]"), ffi.new("int[1]")
                ffi.C.vx_sys_window_size(new_w, new_h)

                if new_w[0] > 0 and new_h[0] > 0 then
                    print("\n[LUA CO] Window Stable. Initiating Mini-Weaver Rebuild...")
                    ffi.C.vx_thread_kill()
                    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

                    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
                    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg.cfg.frame_slots)

                    cfg.win.w = new_w[0]
                    cfg.win.h = new_h[0]

                    local mini_ctx = {
                        vk_runtime = vk_rt,
                        desc_state = desc,
                        old_swapchain = sc.handle
                    }

                    local resize_co = coroutine.create(function()
                        for _, stage in ipairs(seq.resize) do
                            print(string.format("[MINI-WEAVER] Executing: %s", stage.name))
                            stage.action(mini_ctx)
                        end
                        return mini_ctx
                    end)

                    local status, new_ctx
                    while coroutine.status(resize_co) ~= "dead" do
                        status, new_ctx = coroutine.resume(resize_co)
                        if not status then error("Mini-Weaver Crash: " .. tostring(new_ctx)) end
                    end

                    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
                    sc = new_ctx.sc_state
                    gfx = new_ctx.gfx_state
                    sync = new_ctx.sync_state
                    seq.boot[10].action(new_ctx)

                    print("[LUA CO] Mini-Weaver Rebuild Complete.\n")
                    is_resizing = false
                    last_time = get_time_hires()
                else
                    last_resize_time = get_time_hires() - (RESIZE_COOLDOWN * 0.9)
                end
            end
        else
            if not palette_ready and palette_job_id ~= -1 then
                if memory.IsTransferComplete(vk_rt, palette_job_id) then
                    print("[LUA CO] Async Transfer Complete! Palette Haven Online.")
                    palette_ready = true
                end
            end

            local current_time = get_time_hires()
            local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
            last_time = current_time
            accumulator = accumulator + frame_time

            -- [NEW] THE TIME HEALER: Eliminate Asymmetric Lag
            if network_locked then
                local remote_highest = rollback_arena.confirmed_tick
                if remote_highest > sim_tick_count + 2 then
                    -- We are in the past! Force the accumulator to swallow the time gap
                    accumulator = accumulator + ((remote_highest - sim_tick_count) * FIXED_DT)
                end
            else
                -- [NEW] ICE FALLBACK TIMEOUT
                -- Only count down if the fuse has been explicitly lit!
                if not network_locked and _G.ice_fuse > 0 then
                    _G.ice_fuse = _G.ice_fuse - 1

                    if _G.ice_fuse == 0 then
                        print("\n[ICE] P2P Hole Punch Failed! Initiating Cloud Relay Fallback...")
                        local RELAY_IP = "138.199.152.240" -- Hetzner IP
                        local RELAY_PORT = 49152
                        net.Connect(RELAY_IP, RELAY_PORT)
                    end
                end
            end

            local mouse_left = ffi.C.vx_input_mouse_btn(0)
            local mouse_x = ffi.C.vx_input_mouse_x()
            local mouse_y = ffi.C.vx_input_mouse_y()

            if mouse_left == 1 and prev_mouse_left == 0 then
                local click_x = ffi.C.vx_input_click_x()
                local click_y = ffi.C.vx_input_click_y()

                local clicked_idx = matrix_raycast_terrain(
                    click_x, click_y, sc.extent.width, sc.extent.height,
                    inv_vp, rts_grid
                )
                if clicked_idx ~= -1 then pending_click = clicked_idx end
            end
            prev_mouse_left = mouse_left

            -- THE TEMPORAL ENGINE
            while accumulator >= FIXED_DT do
                local current_local_input = ffi.C.vx_input_wasd()
                local local_click = pending_click

                -- ✅ THE FFI MIRROR: Bind inputs directly to the timeline memory
                local current_idx = bit.band(sim_tick_count, 127)
                local current_frame = rollback_arena.frames[current_idx]

                -- Native Lua Purge
                if current_frame.tick ~= sim_tick_count then
                    current_frame.state = cfg.net_state.empty
                    current_frame.remote_input = 0
                    current_frame.remote_click = -1
                end

                current_frame.tick = sim_tick_count
                current_frame.local_input = current_local_input
                current_frame.local_click = local_click
                rollback_arena.head_tick = sim_tick_count

                if not network_locked then
                    pending_click = -1 -- Consume click during handshake

                    -- Spam Tick 0 to wake up the other instance
                    rollback_arena.frames[0].tick = 0
                    rollback_arena.frames[0].local_input = 0
                    rollback_arena.frames[0].local_click = -1
                    rollback_arena.head_tick = 0

                    net.Pump() -- [UPDATED] Fire the network

                    -- [FIXED] If we receive ANY tick (0 or higher), the lock is secured.
                    if rollback_arena.frames[0].state == cfg.net_state.confirmed or rollback_arena.confirmed_tick > 0 then
                        print("[NET] Handshake successful! Timelines locked.")
                        network_locked = true
                        sim_tick_count = math.max(1, rollback_arena.confirmed_tick)
                        accumulator = 0.0
                    end
                else
                    -- ✅ THE TEMPORAL TETHER
                    local remote_highest = rollback_arena.confirmed_tick

                    if sim_tick_count > remote_highest + 4 then
                        -- STALL MODE: We are in the future!
                        -- Pump the network to receive packets, but DO NOT advance the simulation.
                        net.Pump() -- [UPDATED]

                        -- Note: We intentionally do NOT reset pending_click to -1 here.
                    else
                        -- LIVE GAME STATE: We are within the safe window.
                        pending_click = -1 -- Consume the click
                        net.Pump() -- [UPDATED]

                        if rollback_arena.is_rollback_active == 1 then
                            local t_target = rollback_arena.rollback_target
                            print("[ROLLBACK] Quantum Fracture! Rewinding from " .. sim_tick_count .. " to " .. t_target)

                            local rewind_idx = bit.band(t_target, 127)
                            ffi.copy(rts_grid.terrain, snapshot_ring.terrain[rewind_idx], bytes_per_layer)
                            ffi.copy(rts_grid.elevation, snapshot_ring.elevation[rewind_idx], bytes_per_layer)

                            for t = t_target, sim_tick_count do
                                local ff_idx = bit.band(t, 127)
                                local frame = rollback_arena.frames[ff_idx]

                                -- 1. ALWAYS save the snapshot BEFORE simulating the frame
                                ffi.copy(snapshot_ring.terrain[ff_idx], rts_grid.terrain, bytes_per_layer)
                                ffi.copy(snapshot_ring.elevation[ff_idx], rts_grid.elevation, bytes_per_layer)

                                -- 2. Simulate the frame
                                update_simulation(rts_grid, t, frame)
                            end

                            rollback_arena.is_rollback_active = 0
                        else
                            local current_idx_ff = bit.band(sim_tick_count, 127)
                            ffi.copy(snapshot_ring.terrain[current_idx_ff], rts_grid.terrain, bytes_per_layer)
                            ffi.copy(snapshot_ring.elevation[current_idx_ff], rts_grid.elevation, bytes_per_layer)

                            local frame = rollback_arena.frames[current_idx_ff]
                            update_simulation(rts_grid, sim_tick_count, frame)
                        end

                        -- Only advance the simulation tick if we were NOT stalled
                        sim_tick_count = sim_tick_count + 1
                    end
                end

                -- We always consume the accumulator so the game loop doesn't freeze
                accumulator = accumulator - FIXED_DT
            end

            local last_key = ffi.C.vx_input_last_key()
            if last_key == cfg.key.esc then ffi.C.vx_core_shutdown()
            elseif last_key == cfg.key.f5 then wants_hotswap = true
            elseif last_key == cfg.key.num1 then active_render_mode = cfg.mode.dual
            elseif last_key == cfg.key.num2 then active_render_mode = cfg.mode.geom
            elseif last_key == cfg.key.num3 then active_render_mode = cfg.mode.points
            end

            total_time = total_time + frame_time
            pc.total_time = total_time

            -- [ATTACK VECTOR 3] COMPACT CAM AND PROJECTION COUPLING
            camera_mod.update(cam, frame_time, mouse_x, mouse_y, sc.extent.width, sc.extent.height)
            camera_mod.get_matrices(cam, sc.extent.width, sc.extent.height, pc.viewProj, inv_vp)

            local write_idx = ffi.C.vx_stream_acquire()
            if write_idx ~= -1 then
                local alpha = accumulator / FIXED_DT
                pc.dt = alpha

                render_queue.PackFrame(write_idx, pc, rts_grid, vram_template, render_queues, active_render_mode, master_ptr, memory, gfx, desc, sc, total_tiles)

                if wants_hotswap then
                    print("\n[LUA] Initiating Lock-Free Shader Hotswap...")
                    require("graphics_pipeline").HotReloadShaders(vk_rt.vk, vk_rt, gfx, frame_count)
                    wants_hotswap = false
                    print("[LUA] Hotswap Complete. New pipelines active.\n")
                end

                ffi.C.vx_stream_commit(write_idx)
                pump_deletion_queue(vk_rt.vk, vk_rt, frame_count)
                frame_count = frame_count + 1
            end
        end
        sys_sleep(1)
    end

    print("\n[LUA IO] Render Loop Terminated. Commencing Teardown...")
    print("[TEARDOWN] Terminating Async Render Thread and Worker Pool...")
    ffi.C.vx_thread_kill()
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
    require("compute_pipeline").Destroy(vk_rt.vk, vk_rt, engine_ctx.comp_state)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)
    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg.cfg.frame_slots)

    print("[TEARDOWN] Freeing VRAM and CPU Memory Arenas...")
    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)

    memory.DestroyBuffer("PALETTE_STAGING", vk_rt)
    memory.DestroyBuffer("PALETTE_HAVEN", vk_rt)

    net.Shutdown()
    memory.DestroyTransferSubsystem(vk_rt)

    require("vulkan_core").Destroy(vk_rt)

    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
ffi.C.vx_core_mark_finished()
