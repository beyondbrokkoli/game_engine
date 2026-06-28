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

local primary_win_id = 0
-- local tenant_ctx = core_abi.create_tenant_context(primary_win_id)
local tenant_ctx = { window_id = primary_win_id }

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
    local boot_ctx = { win_id = primary_win_id }
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
local function boot_secondary_tenant(vk_rt, win_id, width, height, frame_slots)
    print(string.format("[UI BOOTSTRAP] Booting Secondary Tenant %d...", win_id))
    WindowAPI.boot(win_id, width, height)

    local surface = nil
    while surface == nil do
        surface = WindowAPI.get_surface(win_id)
        sys_sleep(10)
    end

    local swapchain = require("swapchain")
    local renderer = require("renderer")

    local sc = swapchain.Init(vk_rt.vk, vk_rt, width, height, nil, surface)
    local sync = renderer.InitSync(vk_rt.vk, vk_rt.device, frame_slots)

    local wsi = ffi.new("RenderThreadInit")
    wsi.device = vk_rt.device
    wsi.queue = vk_rt.queue
    wsi.transfer_queue = vk_rt.transferQueue
    wsi.swapchain = sc.handle

    for i = 0, sc.imageCount - 1 do
        wsi.swapchain_images[i] = ffi.cast("uint64_t", sc.images[i])
        wsi.swapchain_views[i]  = ffi.cast("uint64_t", sc.imageViews[i])
    end
    for i = 0, frame_slots - 1 do
        wsi.image_available[i] = sync.imageAvailable[i]
        wsi.render_finished[i] = sync.renderFinished[i]
        wsi.in_flight[i]       = sync.inFlight[i]
    end

    local dev = vk_rt.device
    local vk = vk_rt.vk
    wsi.vkWaitForFences         = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkWaitForFences"))
    wsi.vkAcquireNextImageKHR   = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkAcquireNextImageKHR"))
    wsi.vkResetFences           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkResetFences"))
    wsi.vkQueueSubmit           = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueueSubmit"))
    wsi.vkQueuePresentKHR       = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkQueuePresentKHR"))
    wsi.pfnBegin                = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdBeginRenderingKHR"))
    wsi.pfnEnd                  = ffi.cast("void*", vk.vkGetDeviceProcAddr(dev, "vkCmdEndRenderingKHR"))
    wsi.pfnSetCullMode          = vk.vkGetDeviceProcAddr(dev, "vkCmdSetCullModeEXT")
    wsi.pfnSetFrontFace         = vk.vkGetDeviceProcAddr(dev, "vkCmdSetFrontFaceEXT")
    wsi.pfnSetPrimitiveTopology = vk.vkGetDeviceProcAddr(dev, "vkCmdSetPrimitiveTopologyEXT")
    wsi.pfnSetDepthTestEnable   = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthTestEnableEXT")
    wsi.pfnSetDepthWriteEnable  = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthWriteEnableEXT")
    wsi.pfnSetDepthCompareOp    = vk.vkGetDeviceProcAddr(dev, "vkCmdSetDepthCompareOpEXT")

    -- Allocate and start the stream for the new tenant
    EngineAPI.allocate_tenant(win_id, wsi, vk_rt.qIndex, vk_rt.tIndex)
    EngineAPI.init_stream(win_id, wsi)

    return sc, sync
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
    local sc = engine_ctx.sc_state
    local desc = engine_ctx.desc_state
    local gfx = engine_ctx.gfx_state
    local sync = engine_ctx.sync_state
    local memory = require("memory")

    -- [PHASE 1: MULTIPLEXER TENANT BOOT]
    local editor_win_id = 1
    local tenant_ctx_editor = core_abi.create_tenant_context(editor_win_id)

    -- Boot the second WSI (Window, Swapchain, and Sync Primitives)
    local editor_sc, editor_sync = boot_secondary_tenant(vk_rt, editor_win_id, 800, 600, cfg_gfx.cfg.frame_slots)
    print("[LUA CO] Editor Tenant Mapped and Async Stream Allocated.")
    -- ====================================================================

    print("[LUA CO] Initializing VRAM Index Buffer with Strict Topology...")
    local index_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])
    local iso_indices = ffi.new("uint32_t[36]", {
        0, 2, 3,  0, 3, 4,  0, 4, 5,  0, 5, 2,
        2, 6, 7,  2, 7, 3,  3, 7, 11, 3, 11, 4,
        4, 11, 10, 4, 10, 5, 5, 10, 6, 5, 6, 2
    })
    ffi.copy(index_ptr, iso_indices, 36 * 4)

    local MAX_DRAW_COMMANDS = 1024
    -- We double the allocation here because we are now pushing TWO packets per frame.
    local render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * cfg_gfx.cfg.frame_slots * 2)
    local frame_count = 0

    -- [PHASE 1: DUAL CAMERA & STATE SEPARATION]
    local pc_primary = ffi.new("PushConstants")
    pc_primary.aos_current_idx, pc_primary.aos_prev_idx, pc_primary.dt = 0, 0, 0.0

    local pc_editor = ffi.new("PushConstants")
    pc_editor.aos_current_idx, pc_editor.aos_prev_idx, pc_editor.dt = 0, 0, 0.0

    local camera_mod = require("camera")
    local cam_primary = camera_mod.new()
    local cam_editor = camera_mod.new()

    local inv_vp_primary = ffi.new("mat4_t")
    local inv_vp_editor = ffi.new("mat4_t")

    local total_time = 0.0
    local wants_hotswap = false
    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local active_render_mode = cfg_gfx.mode.dual

    local is_resizing = false
    local last_resize_time = get_time_hires()
    local RESIZE_COOLDOWN = 0.25
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

    local palette_job_id = memory.TransferAsync("PALETTE_STAGING", "PALETTE_HAVEN", 16384)
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

        if WindowAPI.was_resized(primary_win_id) then
            is_resizing = true
            last_resize_time = get_time_hires()
        end

        local current_time = get_time_hires()
        local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
        last_time = current_time

        local mouse_left = WindowAPI.is_mouse_down(primary_win_id, 0)
        local mouse_x, mouse_y = WindowAPI.get_mouse_pos(primary_win_id)

        if mouse_left and not prev_mouse_left then
            local click_x, click_y = WindowAPI.get_click_pos(primary_win_id)
            local clicked_idx = Raycast.matrix_raycast_terrain(click_x, click_y, sc.extent.width, sc.extent.height, inv_vp, ctx.rts_grid, ctx.net_identity)

            if clicked_idx ~= 65535 then
                local is_elevated = false
                for peer = 0, cfg_net.MAX_PLAYERS - 1 do
                    if ctx.rts_grid.elevation[peer][clicked_idx] > 0 then
                        is_elevated = true; break
                    end
                end
                local op = is_elevated and 2 or 1
                InputCore.SubmitCommand(ctx, op, 0, 0, clicked_idx)
            end
        end
        prev_mouse_left = mouse_left

        Pump.intercept_network(ctx, ctx.sim_tick_count)
        ctx.accumulator = ctx.accumulator + frame_time
        ctx.net_accumulator = ctx.net_accumulator + frame_time

        FSM.tick_playing_state(ctx, FIXED_DT)

        if ctx.net_accumulator >= FIXED_DT then
            Pump.send_dynamic_history(ctx)
            ctx.net_accumulator = ctx.net_accumulator % FIXED_DT
        end

        if current_time - last_heartbeat >= 1.0 then
            last_heartbeat = current_time
            print(string.format("\n[HEARTBEAT] Sim Tick: %d | Confirmed: %d | Accum: %.4f", ctx.sim_tick_count, ctx.rollback_arena.confirmed_tick, ctx.accumulator))
        end

        local last_key = WindowAPI.get_last_key(primary_win_id)
        if last_key == cfg_gfx.key.esc then EngineAPI.shutdown()
        elseif last_key == cfg_gfx.key.f5 then wants_hotswap = true
        elseif last_key == cfg_gfx.key.num1 then active_render_mode = cfg_gfx.mode.dual
        elseif last_key == cfg_gfx.key.num2 then active_render_mode = cfg_gfx.mode.geom
        elseif last_key == cfg_gfx.key.num3 then active_render_mode = cfg_gfx.mode.points
        end

        -- Mini-Weaver Rebuild (Resizing)
        if is_resizing then
            if (get_time_hires() - last_resize_time) > RESIZE_COOLDOWN then
                local new_w, new_h = WindowAPI.get_window_size(primary_win_id)
                if new_w > 0 and new_h > 0 then
                    print("\n[LUA CO] Window Stable. Initiating Mini-Weaver Rebuild...")
                    EngineAPI.kill_thread()
                    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)

                    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
                    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg_gfx.cfg.frame_slots)

                    cfg_gfx.win.w = new_w
                    cfg_gfx.win.h = new_h

                    local mini_ctx = {
                        vk_runtime = vk_rt,
                        desc_state = desc,
                        old_swapchain = sc.handle,
                        win_id = primary_win_id
                    }

                    local resize_co = coroutine.create(function()
                        for _, stage in ipairs(seq.resize) do
                            print(string.format("[MINI-WEAVER] Executing: %s", stage.name))
                            stage.action(mini_ctx)
                        end
                        return mini_ctx
                    end)

                    local r_status, new_ctx
                    while coroutine.status(resize_co) ~= "dead" do
                        r_status, new_ctx = coroutine.resume(resize_co)
                        if not r_status then error("Mini-Weaver Crash: " .. tostring(new_ctx)) end
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
            -- 1. Ensure the unified color stream is verified (Happens once for the whole engine)
            if not palette_ready and palette_job_id ~= -1 then
                if memory.IsTransferComplete(vk_rt, palette_job_id) then
                    print("[LUA CO] Async Transfer Complete! Unified Palette Haven Online.")
                    palette_ready = true
                end
            end

            -- 2. Sync Universal Time
            total_time = total_time + frame_time
            pc_primary.total_time = total_time
            pc_editor.total_time = total_time

            -- 3. Update Primary Camera
            camera_mod.update(cam_primary, frame_time, mouse_x, mouse_y, sc.extent.width, sc.extent.height, primary_win_id)

            -- 4. Sync Editor Camera State (Visual Mirroring)
            cam_editor.pos.x = cam_primary.pos.x
            cam_editor.pos.y = cam_primary.pos.y
            cam_editor.pos.z = cam_primary.pos.z
            cam_editor.yaw = cam_primary.yaw
            cam_editor.pitch = cam_primary.pitch
            cam_editor.ortho_zoom = cam_primary.ortho_zoom

            -- 5. Calculate Independent Matrices based on distinct Window Aspect Ratios
            camera_mod.get_matrices(cam_primary, sc.extent.width, sc.extent.height, pc_primary.viewProj, inv_vp_primary)
            camera_mod.get_matrices(cam_editor, editor_sc.extent.width, editor_sc.extent.height, pc_editor.viewProj, inv_vp_editor)

            local current_dt = ctx.accumulator / FIXED_DT

            -- 6. Acquire & Pack Primary Viewport
            local write_idx_0 = EngineAPI.acquire_render_packet()
            if write_idx_0 ~= -1 then
                pc_primary.dt = current_dt
                render_queue.PackFrame(tenant_ctx, write_idx_0, pc_primary, ctx.rts_grid, vram_template, render_queues, active_render_mode, master_ptr, memory, gfx, desc, sc, ctx.total_tiles, ctx.net_identity)
                EngineAPI.commit_render_packet(write_idx_0)
            end

            -- 7. Acquire & Pack Editor Viewport
            local write_idx_1 = EngineAPI.acquire_render_packet()
            if write_idx_1 ~= -1 then
                pc_editor.dt = current_dt
                render_queue.PackFrame(tenant_ctx_editor, write_idx_1, pc_editor, ctx.rts_grid, vram_template, render_queues, active_render_mode, master_ptr, memory, gfx, desc, editor_sc, ctx.total_tiles, ctx.net_identity)
                EngineAPI.commit_render_packet(write_idx_1)
            end

            -- 8. Global State & Deletion Queue Sync
            if wants_hotswap then
                print("\n[LUA] Initiating Lock-Free Shader Hotswap...")
                require("graphics_pipeline").HotReloadShaders(vk_rt.vk, vk_rt, gfx, frame_count)
                wants_hotswap = false
            end

            if write_idx_0 ~= -1 or write_idx_1 ~= -1 then
                pump_deletion_queue(vk_rt.vk, vk_rt, frame_count)
                frame_count = frame_count + 1
            end
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
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg_gfx.cfg.frame_slots)

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
