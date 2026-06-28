io.stdout:setvbuf("no")
package.path = "./lua/?.lua;" .. package.path

-- 1. BEDROCK (Stateless APIs & Memory Layouts)
local ffi = require("ffi")
local core_abi = require("core_abi")
local structs = require("structs")
local cfg_gfx = require("config_gfx")
local cfg_sim = require("config_sim")
local cfg_net = require("config_net")

local WindowAPI = require("window_api")
local EngineAPI = require("engine_api")

-- Master App Context (Read-Only Configs for Factories)
local app_ctx = {
    cfg_gfx = cfg_gfx,
    cfg_sim = cfg_sim,
    cfg_net = cfg_net
}

-- 2. DECOUPLED MODULE FACTORIES
local math = require("math")
local vmath = require("vmath")
local net = require("network")
local NetUtils = require("net_utils")

local seq = require("sequence").init(app_ctx)
local render_queue = require("render_queue").init(app_ctx)
local InputCore = require("input_core")
local Raycast = require("raycast")

local Game = require("game_state").init(app_ctx)
local Pump = require("net_pump").init(app_ctx)
local FSM = require("fsm_core").init(app_ctx, Game)
local TenantRegistry = require("tenant_registry")

-- 3. TIMING SUBSYSTEM
local function sys_sleep(ms)
    if jit.os == "Windows" then ffi.C.Sleep(ms) else ffi.C.usleep(ms * 1000) end
end

local get_time_hires
if jit.os == "Windows" then
    local freq = ffi.new("int64_t[1]")
    ffi.C.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        ffi.C.QueryPerformanceCounter(count)
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

-- 4. BOOTSTRAP COROUTINE
local function boot_weaver()
    -- [PATCH]: Explicitly define win_id as 0 since the global is gone.
    -- I also added old_swapchain = nil just to explicitly define the schema
    -- before sequence.lua tries to read it in step 5.
    local boot_ctx = { win_id = 0, old_swapchain = nil }

    for i, stage in ipairs(seq.boot) do
        print(string.format("[WEAVER] Executing Stage %d: %s", i, stage.name))
        local signal = stage.action(boot_ctx)
        if signal == "AWAIT_SURFACE" then
            print("[WEAVER] Yielding execution, waiting for C-Core Surface...")
            while WindowAPI.get_surface(boot_ctx.win_id) == nil do
                sys_sleep(10)
                coroutine.yield()
            end
        end
    end
    return boot_ctx
end

-- 5. THE MASTER ORCHESTRATOR
local function main()
    print("Enter Node ID (0-7) OR Preferred Local Port (e.g., 50000): ")
    io.write("> ")
    local local_port = tonumber(io.read("*l")) or 50000
    if local_port < 1000 then local_port = 50000 + local_port end

    assert(net.Host(local_port), "FATAL: Failed to bind local socket port " .. local_port)

    -- Network topology handled cleanly via external module
    local my_local_ip = "127.0.0.1"
    local session_token, local_id, p2p_established, active_peers, status_data = NetUtils.BootstrapNetworkTopology(local_port, my_local_ip)

    local ctx = {
        session_token = session_token,
        net_identity = local_id,
        sim_tick_count = 1,
        accumulator = 0.0,
        net_accumulator = 0.0,
        total_tiles = cfg_sim.world.map_width * cfg_sim.world.map_height,
        p2p_established = p2p_established,
        peer_active = ffi.new(string.format("bool[%d]", cfg_net.MAX_PLAYERS)),
        peer_highest_tick = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        peer_ack_of_me = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        rts_grid = Game.InitState(session_token),
        rollback_arena = ffi.new("RollbackBuffer"),
        snapshot_ring = ffi.new(string.format("%s[%d]", Game.GetStateName(), cfg_net.RING_SIZE))
    }

    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        ctx.peer_active[p] = (p < #status_data.players)
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
    local sc = engine_ctx.sc_state     -- ALERT: This is Tenant 0's Swapchain!
    local desc = engine_ctx.desc_state -- Shared Descriptor State
    local gfx = engine_ctx.gfx_state   -- Shared Graphics State
    local sync = engine_ctx.sync_state -- ALERT: This is Tenant 0's Sync!
    local memory = require("memory")

    -- [PHASE 1: MULTIPLEXER TENANT REGISTRY INITIATION]
    local TenantRegistry = require("tenant_registry")
    local camera_mod = require("camera")

    -- 1. Adopt the Primary Tenant (Bootstrapped by Weaver Coroutine)
    TenantRegistry.active[0] = {
        win_id = 0,
        suspended = false,
        width = cfg_gfx.win.w,
        height = cfg_gfx.win.h,
        sc = sc,      -- Inherited directly from C-Core boot sequence
        sync = sync,  -- Inherited directly from C-Core boot sequence
        cam = camera_mod.new(),
        pc = ffi.new("PushConstants"),
        inv_vp = ffi.new("mat4_t")
    }
    TenantRegistry.active[0].pc.aos_current_idx = 0
    TenantRegistry.active[0].pc.aos_prev_idx = 0
    TenantRegistry.active[0].pc.dt = 0.0

    -- 2. Boot the Secondary Editor Tenant dynamically
    TenantRegistry.boot_tenant(vk_rt, 1, 800, 600, cfg_gfx.cfg.frame_slots)
    print("[LUA CO] Multi-Tenant Registry Online.")

    print("[LUA CO] Initializing VRAM Index Buffer with Strict Topology...")
    local index_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])
    local iso_indices = ffi.new("uint32_t[36]", {
        0, 2, 3,  0, 3, 4,  0, 4, 5,  0, 5, 2,
        2, 6, 7,  2, 7, 3,  3, 7, 11, 3, 11, 4,
        4, 11, 10, 4, 10, 5, 5, 10, 6, 5, 6, 2
    })
    ffi.copy(index_ptr, iso_indices, 36 * 4)

    local MAX_DRAW_COMMANDS = 1024
    -- Rename the game state to `sim_ctx` to violently enforce the separation.
    local sim_ctx = ctx
    -- [ARMOR PATCH]: Anchor to sim_ctx to survive GC, and size by RING_SIZE (4)
    -- to prevent out-of-bounds pointer arithmetic when write_idx hits 3.
    sim_ctx.render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * cfg_net.RING_SIZE * 2)
    local render_queues = sim_ctx.render_queues

    local frame_count = 0

    -- [ANNIHILATED]: pc_primary, pc_editor, cam_primary, cam_editor, inv_vp_primary, inv_vp_editor.
    -- These are now securely encapsulated within TenantRegistry.active[win_id].

    local total_time = 0.0
    local wants_hotswap = false
    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local active_render_mode = cfg_gfx.mode.dual

    -- [ANNIHILATED]: Global is_resizing, last_resize_time, and RESIZE_COOLDOWN.
    -- WSI OS Interrupt state is now evaluated natively per-tenant inside the Orchestrator loop.

    local TICK_RATE = cfg_net.TICK_RATE
    local FIXED_DT = 1.0 / TICK_RATE

    local staging_ptr = ffi.cast("float*", memory.Mapped["PALETTE_STAGING"])
    staging_ptr[0] = 0.2; staging_ptr[1] = 0.8; staging_ptr[2] = 0.2; staging_ptr[3] = 1.0
    staging_ptr[4] = 0.2; staging_ptr[5] = 0.5; staging_ptr[6] = 1.0; staging_ptr[7] = 1.0
    staging_ptr[8] = 1.0; staging_ptr[9] = 0.2; staging_ptr[10] = 0.2; staging_ptr[11] = 1.0
    staging_ptr[40] = 1.0; staging_ptr[41] = 1.0; staging_ptr[42] = 1.0; staging_ptr[43] = 1.0
    staging_ptr[44] = 1.0; staging_ptr[45] = 0.0; staging_ptr[46] = 0.0; staging_ptr[47] = 1.0
    staging_ptr[48] = 0.0; staging_ptr[49] = 0.0; staging_ptr[50] = 1.0; staging_ptr[51] = 1.0
    staging_ptr[52] = 1.0; staging_ptr[53] = 0.0; staging_ptr[54] = 0.0; staging_ptr[55] = 1.0

    local palette_job_id = memory.TransferAsync(0, "PALETTE_STAGING", "PALETTE_HAVEN", 16384)
    local palette_ready = false

    local prev_mouse_left = false

    local vram_template = ffi.new("RtsTileInstance[?]", ctx.total_tiles)
    for z = 0, cfg_sim.world.map_height - 1 do
        for x = 0, cfg_sim.world.map_width - 1 do
            local i = z * cfg_sim.world.map_width + x
            vram_template[i].px = (x * cfg_sim.world.spacing) - cfg_sim.world.offset_x
            vram_template[i].pz = (z * cfg_sim.world.spacing) - cfg_sim.world.offset_z
        end
    end

    local gfx_pipeline_module = require("graphics_pipeline")
    local pump_deletion_queue = gfx_pipeline_module.PumpDeletionQueue

    print("[NET] Scene loaded. Cameras unlocked. Awaiting Timeline Synchronization...")
    local last_time = get_time_hires()
    local last_heartbeat = get_time_hires()

    -- 6. THE DETERMINISTIC RENDER LOOP
    while EngineAPI.is_running() do
        local current_time = get_time_hires()
        local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
        last_time = current_time

        -- A. DETERMINISTIC SIMULATION PHASE (The Headless Truth)
        sim_ctx.accumulator = sim_ctx.accumulator + frame_time
        sim_ctx.net_accumulator = sim_ctx.net_accumulator + frame_time

        Pump.intercept_network(sim_ctx, sim_ctx.sim_tick_count)
        FSM.tick_playing_state(sim_ctx, FIXED_DT)

        if sim_ctx.net_accumulator >= FIXED_DT then
            Pump.send_dynamic_history(sim_ctx)
            sim_ctx.net_accumulator = sim_ctx.net_accumulator % FIXED_DT
        end

        -- Simulation Input Routing (Only route if Window 0 is focused and clicked)
        if WindowAPI.is_mouse_down(0, 0) and not prev_mouse_left then
            local click_x, click_y = WindowAPI.get_click_pos(0)
            local primary_tenant = TenantRegistry.active[0]
            local clicked_idx = Raycast.matrix_raycast_terrain(
                click_x, click_y,
                primary_tenant.width, primary_tenant.height,
                primary_tenant.inv_vp,
                sim_ctx.rts_grid, sim_ctx.net_identity
            )
            if clicked_idx ~= 65535 then
                InputCore.SubmitCommand(sim_ctx, 1, 0, 0, clicked_idx)
            end
        end
        prev_mouse_left = WindowAPI.is_mouse_down(0, 0)

        -- B. MULTI-TENANT ORCHESTRATION PHASE (The Visuals)
        total_time = total_time + frame_time

        -- Determine which window actually has OS focus so we don't spin both cameras at once
        local active_win_id = ffi.C.vx_input_get_active_window()

        for win_id, tenant in pairs(TenantRegistry.active) do

            -- 1. Phase 2 WSI State Machine (OS Resize Interrupts)
            if WindowAPI.get_resize_state(win_id) then
                if not tenant.suspended then
                    WindowAPI.trigger_wsi_rebuild(win_id)
                    tenant.suspended = true
                end
                goto continue_tenant
            end

            if tenant.suspended then
                local new_w, new_h = WindowAPI.get_window_size(win_id)
                if new_w > 0 and new_h > 0 then
                    tenant.width, tenant.height = new_w, new_h
                    tenant.suspended = false

                    -- WSI rebuild requires updating the swapchain struct pointers
                    require("swapchain").Destroy(vk_rt.vk, vk_rt, tenant.sc)
                    tenant.sc = swapchain.Init(vk_rt.vk, vk_rt, new_w, new_h, nil, WindowAPI.get_surface(win_id))
                    -- Trigger C-Core re-arm (similar to your rearm_secondary_wsi, but streamlined)
                    EngineAPI.init_stream(win_id, tenant.sc.handle)
                end
                goto continue_tenant
            end

            -- 2. Input Isolation & Camera Update
            -- Only update the camera if this specific tenant's window is active
            if win_id == active_win_id then
                local mouse_x, mouse_y = WindowAPI.get_mouse_pos(win_id)
                camera_mod.update(tenant.cam, frame_time, mouse_x, mouse_y, tenant.width, tenant.height, win_id)
            end

            camera_mod.get_matrices(tenant.cam, tenant.width, tenant.height, tenant.pc.viewProj, tenant.inv_vp)

            -- 3. Zero-Trust Ring Buffer Handshake
            local write_idx = EngineAPI.acquire_render_packet()
            if write_idx == -1 then
                goto continue_tenant
            end

            -- 4. Pack & Commit
            tenant.pc.total_time = total_time
            tenant.pc.dt = sim_ctx.accumulator / FIXED_DT

            -- Passing the specific `tenant` object handles isolation natively.
            render_queue.PackFrame(tenant, write_idx, tenant.pc, sim_ctx.rts_grid, vram_template,
                                   render_queues, active_render_mode, master_ptr, memory,
                                   gfx, desc, tenant.sc, sim_ctx.total_tiles, sim_ctx.net_identity)

            EngineAPI.commit_render_packet(write_idx)

            ::continue_tenant::
        end

        sys_sleep(1)
    end

    print("\n[LUA IO] Render Loop Terminated. Commencing Teardown...")
    EngineAPI.kill_thread()
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
    require("compute_pipeline").Destroy(vk_rt.vk, vk_rt, engine_ctx.comp_state)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)
    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync)

    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)
    memory.DestroyBuffer("PALETTE_STAGING", vk_rt)
    memory.DestroyBuffer("PALETTE_HAVEN", vk_rt)

    net.Shutdown()
    memory.DestroyTransferSubsystem(vk_rt)

    require("vulkan_core").Destroy(vk_rt, cfg_gfx.cfg)
    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
EngineAPI.mark_finished()
