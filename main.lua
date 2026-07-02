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

-- Master App Context
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

local graphics_mod = require("graphics_pipeline")
local manifest = require("pipeline_manifest")

local renderer_mod = require("renderer")
local swapchain_mod = require("swapchain")

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

    local my_local_ip = NetUtils.get_local_ip()
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

    ffi.copy(ctx.snapshot_ring[0], ctx.rts_grid, Game.GetStateSize())

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
    local sc = engine_ctx.sc_state
    local desc = engine_ctx.desc_state
    local gfx = engine_ctx.gfx_state
    local sync = engine_ctx.sync_state
    local memory = require("memory")

    local graphics_mod = require("graphics_pipeline")
    local manifest = require("pipeline_manifest")

    -- [PHASE 1: MULTIPLEXER TENANT REGISTRY INITIATION]
    local TenantRegistry = require("tenant_registry")
    local camera_mod = require("camera")

    -- 1. Adopt the Primary Tenant
    TenantRegistry.active[0] = {
        win_id = 0,
        suspended = false,
        width = cfg_gfx.win.w,
        height = cfg_gfx.win.h,
        sc = sc,
        sync = sync,
        gfx = gfx,
        cam = camera_mod.new(),
        pc = ffi.new("PushConstants"),
        inv_vp = ffi.new("mat4_t")
    }
    TenantRegistry.active[0].pc.aos_current_idx = 0
    TenantRegistry.active[0].pc.aos_prev_idx = 0
    TenantRegistry.active[0].pc.dt = 0.0

    -- 2. Boot the Secondary Editor Tenant
    TenantRegistry.boot_tenant(vk_rt, 1, 800, 600, cfg_gfx.cfg.frame_slots)

    TenantRegistry.active[1].gfx = graphics_mod.Init(
        vk_rt.vk, vk_rt,
        800, 600,
        desc.pipelineLayout,
        TenantRegistry.active[1].sc.format,
        manifest.graphics
    )

    -- 3. Boot Tenant 2
    TenantRegistry.boot_tenant(vk_rt, 2, 800, 600, cfg_gfx.cfg.frame_slots)
    TenantRegistry.active[2].gfx = graphics_mod.Init(
        vk_rt.vk, vk_rt,
        800, 600,
        desc.pipelineLayout,
        TenantRegistry.active[2].sc.format,
        manifest.graphics
    )

    -- 4. Boot Tenant 3
    TenantRegistry.boot_tenant(vk_rt, 3, 800, 600, cfg_gfx.cfg.frame_slots)
    TenantRegistry.active[3].gfx = graphics_mod.Init(
        vk_rt.vk, vk_rt,
        800, 600,
        desc.pipelineLayout,
        TenantRegistry.active[3].sc.format,
        manifest.graphics
    )

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
    local sim_ctx = ctx

    sim_ctx.render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * cfg_net.RING_SIZE * 2)
    local render_queues = sim_ctx.render_queues

    local total_time = 0.0
    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local active_render_mode = cfg_gfx.mode.dual

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

    -- Upgrade prev_mouse_left to track per-tenant
    --local prev_mouse_left = { [0] = false, [1] = false }
    local prev_mouse_left = { [0] = false, [1] = false, [2] = false, [3] = false }

    local vram_template = ffi.new("RtsTileInstance[?]", ctx.total_tiles)
    for z = 0, cfg_sim.world.map_height - 1 do
        for x = 0, cfg_sim.world.map_width - 1 do
            local i = z * cfg_sim.world.map_width + x
            vram_template[i].px = (x * cfg_sim.world.spacing) - cfg_sim.world.offset_x
            vram_template[i].pz = (z * cfg_sim.world.spacing) - cfg_sim.world.offset_z
        end
    end

    local function execute_heartbeat_diagnostic(ctx)
        local RING_MASK = cfg_net.RING_MASK
        local MAX_PLAYERS = cfg_net.MAX_PLAYERS

        -- Scan the unconfirmed horizon for discrepancies
        local start_tick = ctx.rollback_arena.confirmed_tick + 1
        local end_tick = ctx.rollback_arena.head_tick

        for t = start_tick, end_tick do
            local idx = bit.band(t, RING_MASK)
            local frame = ctx.rollback_arena.frames[idx]

            -- Check if we have received a validation hash from a remote peer for this historical tick
            if frame.tick == t and frame.remote_checksum ~= 0 and frame.state_checksum ~= 0 then
                if frame.state_checksum ~= frame.remote_checksum then
                    print("\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
                    print(string.format("[CRITICAL DESYNC DETECTED] Tick: %d | Slot: %d", t, idx))
                    print(string.format("  Local Hash:  0x%08X", frame.state_checksum))
                    print(string.format("  Remote Hash: 0x%08X (Verified by Peer ID: %d)", frame.remote_checksum, frame.remote_peer_id))
                    print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
                    print("DUMPING TIMELINE INPUT MATRIX FOR CORRUPTED TICK:")

                    for p = 0, MAX_PLAYERS - 1 do
                        print(string.format("  Player [%d]:", p))
                        for c = 0, 1 do
                            local cmd = frame.commands[p][c]
                            print(string.format("    Command [%d] -> Opcode: %d | Flags: %d | TargetPos: %d",
                                c, cmd.opcode, cmd.flags, cmd.target_pos))
                        end
                    end
                    print("--------------------------------------------------------------")
                    print("[FATAL INVARIANT] Halting engine loop to preserve memory state.")
                    -- Force a clean crash to let you inspect logs
                    error("[DESYNC] Memory boundary desynchronized across target environments.")
                end
            end
        end
    end

    print("[NET] Scene loaded. Cameras unlocked. Awaiting Timeline Synchronization...")
    local last_time = get_time_hires()
    local last_heartbeat = get_time_hires() -- [!] Restored from legacy build

    while EngineAPI.is_running() do
        local current_time = get_time_hires()
        local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
        last_time = current_time

        -- A. DETERMINISTIC SIMULATION PHASE
        sim_ctx.accumulator = sim_ctx.accumulator + frame_time
        sim_ctx.net_accumulator = sim_ctx.net_accumulator + frame_time

        Pump.intercept_network(sim_ctx, sim_ctx.sim_tick_count)
        FSM.tick_playing_state(sim_ctx, FIXED_DT)

        -- [!] INJECTED: The Desync Trap (Checks every single frame for hash divergence)
        execute_heartbeat_diagnostic(sim_ctx)

        if sim_ctx.net_accumulator >= FIXED_DT then
            Pump.send_dynamic_history(sim_ctx)
            sim_ctx.net_accumulator = sim_ctx.net_accumulator % FIXED_DT
        end

        -- [!] INJECTED: The Golden Diagnostic Pulse (Fires every 1.0 real-time seconds)
        if current_time - last_heartbeat >= 1.0 then
            last_heartbeat = current_time
            print(string.format("\n[HEARTBEAT] Sim Tick: %d | Confirmed: %d | Accum: %.4f",
                sim_ctx.sim_tick_count, sim_ctx.rollback_arena.confirmed_tick, sim_ctx.accumulator))

            for p = 0, cfg_net.MAX_PLAYERS - 1 do
                if sim_ctx.peer_active[p] then
                    print(string.format("  -> [DIAGNOSTIC] Peer %d | Highest Tick: %d | AckOfMe: %d",
                        p, sim_ctx.peer_highest_tick[p], sim_ctx.peer_ack_of_me[p]))
                end
            end
        end

        -- 1. Get the single, authoritative focused window from the OS
        local active_win_id = ffi.C.vx_input_get_active_window()

        -- Engine Shutdown Hook
        if active_win_id >= 0 and WindowAPI.get_last_key(active_win_id) == cfg_gfx.key.esc then
            EngineAPI.shutdown()
        end

        -- 2. Clear mouse state for any window that DOES NOT have focus
        for win_id in pairs(TenantRegistry.active) do
            if win_id ~= active_win_id then
                prev_mouse_left[win_id] = false
            end
        end

        -- 3. Only process input for the definitively active window
        if active_win_id >= 0 and TenantRegistry.active[active_win_id] then
            local tenant = TenantRegistry.active[active_win_id]
            local is_down = WindowAPI.is_mouse_down(active_win_id, 0)

            if is_down and not prev_mouse_left[active_win_id] then
                local click_x, click_y = WindowAPI.get_click_pos(active_win_id)

                -- UNIFIED ROUTER: Both windows interact with the same 2.5D RTS Grid!
                -- The raycast uses the specific window's isolated camera matrix and resolution.
                local clicked_idx = Raycast.matrix_raycast_terrain(
                    click_x, click_y,
                    tenant.width, tenant.height,
                    tenant.inv_vp,
                    sim_ctx.rts_grid, sim_ctx.net_identity
                )

                if clicked_idx ~= 65535 then
                    InputCore.HandleTerrainClick(sim_ctx, clicked_idx)
                    print(string.format("[INPUT] Window %d clicked tile %d", active_win_id, clicked_idx))
                end
            end

            prev_mouse_left[active_win_id] = is_down
        end

        -- B. MULTI-TENANT ORCHESTRATION PHASE
        total_time = total_time + frame_time

        for win_id, tenant in pairs(TenantRegistry.active) do

            -- [PHASE 3]: THE PURGE (Frame N+1)
            if tenant.dying then
                print(string.format("[TEARDOWN] Tenant %d: Executing Surgical Fence Wait...", win_id))

                -- 1. MATHEMATICAL GUARANTEE: Wait for this specific tenant's GPU workload to finish
                for i = 0, tenant.sync.safe_frames - 1 do
                    if tenant.sync.inFlight[i] ~= nil then
                        local fence_ptr = ffi.new("VkFence[1]", tenant.sync.inFlight[i])
                        vk_rt.vk.vkWaitForFences(vk_rt.device, 1, fence_ptr, 1, 2000000000)
                    end
                end

                -- 2. It is now 100% safe to dismantle Vulkan objects.
                print(string.format("[TEARDOWN] Tenant %d: GPU idled. Purging Vulkan resources...", win_id))

                graphics_mod.Destroy(vk_rt.vk, vk_rt, tenant.gfx)
                renderer_mod.Destroy(vk_rt.vk, vk_rt.device, tenant.sync)
                swapchain_mod.Destroy(vk_rt.vk, vk_rt, tenant.sc)

                local surface_ptr = WindowAPI.get_surface(win_id)
                if surface_ptr ~= nil then
                    local vk_surface = ffi.cast("VkSurfaceKHR", surface_ptr)
                    vk_rt.vk.vkDestroySurfaceKHR(vk_rt.instance, vk_surface, nil)
                end

                TenantRegistry.active[win_id] = nil
                goto continue_tenant
            end

            -- [PHASE 1]: THE REQUEST (Frame N)
            -- Check if the 'X' was clicked. If so, suspend Lua operations for
            -- this tenant and ship the kill command to the C-Core mailbox.
            if WindowAPI.close_requested(win_id) then
                if win_id == 0 then
                    -- If the primary window is closed, bring down the whole engine
                    EngineAPI.shutdown()
                else
                    print(string.format("[TEARDOWN] Tenant %d close requested. Suspending Lua and notifying C-Core.", win_id))
                    tenant.dying = true
                    WindowAPI.destroy(win_id) -- Ships CMD_KILL_WINDOW to the mailbox
                    goto continue_tenant
                end
            end

            -- STANDARD TENANT ORCHESTRATION (Resizes, Inputs, Rendering)
            if WindowAPI.is_key_down(win_id, cfg_gfx.key.f5) then
                ffi.C.vx_sys_dump_ring_state(win_id)
            end

            if WindowAPI.get_resize_state(win_id) and not tenant.suspended then
                WindowAPI.trigger_wsi_rebuild(win_id)
                tenant.suspended = true
                goto continue_tenant
            end

            if tenant.suspended then
            -- ... (Rest of your existing WSI rebuild and camera logic continues here) ...
                if WindowAPI.get_resize_state(win_id) then
                    WindowAPI.trigger_wsi_rebuild(win_id)
                    goto continue_tenant
                end

                local new_w, new_h = WindowAPI.get_window_size(win_id)

                if new_w > 0 and new_h > 0 then
                    print(string.format("[LUA CO] Tenant %d: GPU Idled. Executing WSI Rebuild...", win_id))
                    tenant.width, tenant.height = new_w, new_h
                    tenant.suspended = false

                    local swapchain_mod = require("swapchain")
                    local graphics_mod = require("graphics_pipeline")
                    local renderer_mod = require("renderer")

                    graphics_mod.Destroy(vk_rt.vk, vk_rt, tenant.gfx)
                    renderer_mod.Destroy(vk_rt.vk, vk_rt.device, tenant.sync)

                    local old_sc_handle = tenant.sc.handle

                    for i = 0, tenant.sc.imageCount - 1 do
                        vk_rt.vk.vkDestroyImageView(vk_rt.device, tenant.sc.imageViews[i], nil)
                    end

                    tenant.sc = swapchain_mod.Init(vk_rt.vk, vk_rt, new_w, new_h, old_sc_handle, WindowAPI.get_surface(win_id))
                    tenant.gfx = graphics_mod.Init(vk_rt.vk, vk_rt, new_w, new_h, desc.pipelineLayout, tenant.sc.format, manifest.graphics)

                    tenant.sync = renderer_mod.InitSync(vk_rt.vk, vk_rt.device, tenant.sc.imageCount)

                    vk_rt.vk.vkDestroySwapchainKHR(vk_rt.device, old_sc_handle, nil)

                    local wsi = ffi.new("RenderThreadInit")
                    wsi.device = vk_rt.device
                    wsi.queue = vk_rt.queue
                    wsi.transfer_queue = vk_rt.transferQueue
                    wsi.swapchain = tenant.sc.handle
                    wsi.max_frames_in_flight = tenant.sc.imageCount

                    for i = 0, tenant.sc.imageCount - 1 do
                        wsi.swapchain_images[i] = ffi.cast("uint64_t", tenant.sc.images[i])
                        wsi.swapchain_views[i]  = ffi.cast("uint64_t", tenant.sc.imageViews[i])
                    end

                    for i = 0, tenant.sc.imageCount - 1 do
                        wsi.image_available[i] = tenant.sync.imageAvailable[i]
                        wsi.render_finished[i] = tenant.sync.renderFinished[i]
                        wsi.in_flight[i]       = tenant.sync.inFlight[i]
                    end

                    local vk, dev = vk_rt.vk, vk_rt.device
                    wsi.vkWaitForFences = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
                    wsi.vkAcquireNextImageKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
                    wsi.vkResetFences = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
                    wsi.vkQueueSubmit = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
                    wsi.vkQueuePresentKHR = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
                    wsi.pfnBegin = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
                    wsi.pfnEnd = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
                    wsi.pfnSetCullMode = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
                    wsi.pfnSetFrontFace = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
                    wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
                    wsi.pfnSetDepthTestEnable = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
                    wsi.pfnSetDepthWriteEnable = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
                    wsi.pfnSetDepthCompareOp = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

                    EngineAPI.init_stream(win_id, wsi);
                    print(string.format("[LUA CO] Tenant %d: WSI Stream Resumed.", win_id))
                end
                goto continue_tenant
            end

            if win_id == active_win_id then
                local mouse_x, mouse_y = WindowAPI.get_mouse_pos(win_id)
                camera_mod.update(tenant.cam, frame_time, mouse_x, mouse_y, tenant.width, tenant.height, win_id)
            end

            camera_mod.get_matrices(tenant.cam, tenant.width, tenant.height, tenant.pc.viewProj, tenant.inv_vp)

            local write_idx = EngineAPI.acquire_render_packet(win_id)
            if write_idx == -1 then
                goto continue_tenant
            end

            tenant.pc.total_time = total_time
            tenant.pc.dt = sim_ctx.accumulator / FIXED_DT

            render_queue.PackFrame(tenant, write_idx, tenant.pc, sim_ctx.rts_grid, vram_template,
                render_queues, active_render_mode, master_ptr, memory,
                tenant.gfx, desc, tenant.sc, sim_ctx.total_tiles, sim_ctx.net_identity)

            EngineAPI.commit_render_packet(win_id, write_idx)

            ::continue_tenant::
        end

        sys_sleep(1)
    end

    print("\n[LUA IO] Render Loop Terminated. Commencing Teardown...")
    EngineAPI.kill_thread()
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

    -- [NEW]: 1. Cleanly burn down every active tenant's resources
    local graphics_mod = require("graphics_pipeline")
    local renderer_mod = require("renderer")
    local swapchain_mod = require("swapchain")

    for win_id, tenant in pairs(TenantRegistry.active) do
        print(string.format("[TEARDOWN] Purging Tenant %d...", win_id))

        -- Destroy the active pipelines, swapchains, and sync primitives
        graphics_mod.Destroy(vk_rt.vk, vk_rt, tenant.gfx)
        renderer_mod.Destroy(vk_rt.vk, vk_rt.device, tenant.sync)
        swapchain_mod.Destroy(vk_rt.vk, vk_rt, tenant.sc)

        -- [THE FINAL FIX]: Explicitly destroy the surface in Lua
        local surface_ptr = WindowAPI.get_surface(win_id)
        if surface_ptr ~= nil then
            local vk_surface = ffi.cast("VkSurfaceKHR", surface_ptr)
            vk_rt.vk.vkDestroySurfaceKHR(vk_rt.instance, vk_surface, nil)
        end

        -- NOW instruct the C-Core to destroy the GLFW OS window
        WindowAPI.destroy(win_id)
    end

    -- 2. Destroy the Global / Shared Engine State
    require("compute_pipeline").Destroy(vk_rt.vk, vk_rt, engine_ctx.comp_state)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)

    -- [DELETED]: The old global gfx, sc, and sync destroy calls were removed from here!

    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)
    memory.DestroyBuffer("PALETTE_STAGING", vk_rt)
    memory.DestroyBuffer("PALETTE_HAVEN", vk_rt)

    net.Shutdown()
    memory.DestroyTransferSubsystem(vk_rt)

    -- 3. Shut down the core Vulkan Instance and Device
    require("vulkan_core").Destroy(vk_rt, cfg_gfx.cfg)
    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
EngineAPI.mark_finished()
